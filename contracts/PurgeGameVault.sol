// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Minimal ERC20 used for vault share classes (coin-only and eth-only).
contract PurgeVaultShare {
    error Unauthorized();
    error ZeroAddress();
    error Insufficient();

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable vault;

    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address vault_,
        uint256 initialSupply,
        address initialHolder
    ) {
        if (vault_ == address(0) || initialHolder == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        vault = vault_;
        totalSupply = initialSupply;
        balanceOf[initialHolder] = initialSupply;
        emit Transfer(address(0), initialHolder, initialSupply);
    }

    // --- ERC20 surface ---
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert Insufficient();
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    // --- Vault-controlled mint/burn ---
    function vaultMint(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function vaultBurn(address from, uint256 amount) external onlyVault {
        uint256 bal = balanceOf[from];
        if (amount == 0 || amount > bal) revert Insufficient();
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    // --- Internal helpers ---
    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (amount == 0 || amount > bal) revert Insufficient();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}

/// @title PurgeStonkShare
/// @notice Vault that holds ETH, stETH, and PURGE. Two share classes:
///         - coinShare: claims PURGE only
///         - ethShare: claims ETH/stETH only
///         Each class has independent supply and retains the "burn all, mint a new billion" behavior.
contract PurgeStonkNFT {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error ZeroAddress();
    error Insufficient();
    error TransferFailed();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Deposit(address indexed from, uint256 ethAmount, uint256 stEthAmount, uint256 coinAmount);
    event Claim(
        address indexed from,
        address indexed to,
        uint256 sharesBurned,
        uint256 ethOut,
        uint256 stEthOut,
        uint256 coinOut
    );

    // ---------------------------------------------------------------------
    // ERC20 metadata/state
    // ---------------------------------------------------------------------
    string public constant name = "Purge Game Vault";
    string public constant symbol = "PGV";
    uint8 public constant decimals = 18;
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18; // 1 billion
    uint256 public constant REFILL_SUPPLY = 1_000_000_000 * 1e18; // 1 billion (used if final share is burned)

    // Share classes
    PurgeVaultShare public immutable coinShare; // PURGE-only claims
    PurgeVaultShare public immutable ethShare; // ETH/stETH-only claims

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    address public immutable coin; // PURGE coin (or compatible)
    IStETH public immutable steth; // stETH token
    address public immutable bonds; // trusted bond contract for deposits

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address coin_, address stEth_, address bonds_) {
        if (coin_ == address(0) || stEth_ == address(0) || bonds_ == address(0)) revert ZeroAddress();

        coin = coin_;
        steth = IStETH(stEth_);
        bonds = bonds_;

        coinShare = new PurgeVaultShare("Purge Vault Coin", "PGVCOIN", address(this), INITIAL_SUPPLY, msg.sender);
        ethShare = new PurgeVaultShare("Purge Vault Eth", "PGVETH", address(this), INITIAL_SUPPLY, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Deposits (bond-only)
    // ---------------------------------------------------------------------
    /// @notice Pull ETH (msg.value), stETH, and/or coin from the caller (caller must approve this contract).
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable {
        _pullToken(coin, msg.sender, coinAmount);
        _pullToken(address(steth), msg.sender, stEthAmount);
        emit Deposit(msg.sender, msg.value, stEthAmount, coinAmount);
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value, 0, 0);
    }

    /// @notice Swap ETH <-> stETH with the bond contract to rebalance liquidity.
    /// @dev stEthForEth=true pulls stETH from bonds and sends back ETH. Otherwise stakes inbound ETH and returns minted stETH.
    function swapWithBonds(bool stEthForEth, uint256 amount) external payable {
        if (msg.sender != bonds) revert Unauthorized();
        if (amount == 0) revert Insufficient();

        if (stEthForEth) {
            if (msg.value != 0) revert Insufficient();
            if (!steth.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
            if (address(this).balance < amount) revert Insufficient();
            _payEth(msg.sender, amount);
        } else {
            if (msg.value != amount) revert Insufficient();
            uint256 minted;
            try steth.submit{value: amount}(address(0)) returns (uint256 m) {
                minted = m;
            } catch {
                revert TransferFailed();
            }
            if (minted != 0 && !steth.transfer(msg.sender, minted)) revert TransferFailed();
        }
    }

    // ---------------------------------------------------------------------
    // Claims via burn
    // ---------------------------------------------------------------------
    /// @notice Burn coin-share tokens to redeem the proportional slice of PURGE.
    function purgeCoin(uint256 amount, address to) external returns (uint256 coinOut) {
        if (to == address(0)) revert ZeroAddress();
        PurgeVaultShare share = coinShare;
        uint256 bal = share.balanceOf(msg.sender);
        if (amount == 0 || amount > bal) revert Insufficient();

        uint256 supplyBefore = share.totalSupply();
        uint256 coinBal = _tokenBalance(coin);
        coinOut = (coinBal * amount) / supplyBefore;

        // Burn caller shares; if caller is burning the entire supply, refill to keep token alive.
        share.vaultBurn(msg.sender, amount);
        if (supplyBefore == amount) {
            share.vaultMint(msg.sender, REFILL_SUPPLY);
        }

        emit Claim(msg.sender, to, amount, 0, 0, coinOut);
        if (coinOut != 0) _payToken(coin, to, coinOut);
    }

    /// @notice Burn eth-share tokens to redeem the proportional slice of ETH and stETH.
    function purgeEth(uint256 amount, address to) external returns (uint256 ethOut, uint256 stEthOut) {
        if (to == address(0)) revert ZeroAddress();
        PurgeVaultShare share = ethShare;
        uint256 bal = share.balanceOf(msg.sender);
        if (amount == 0 || amount > bal) revert Insufficient();

        uint256 supplyBefore = share.totalSupply();
        uint256 ethBal = address(this).balance;
        uint256 stBal = _tokenBalance(address(steth));
        uint256 combined = ethBal + stBal;
        uint256 claimValue = (combined * amount) / supplyBefore;

        if (claimValue <= ethBal) {
            ethOut = claimValue;
        } else {
            ethOut = ethBal;
            stEthOut = claimValue - ethBal;
            if (stEthOut > stBal) revert Insufficient();
        }

        share.vaultBurn(msg.sender, amount);
        if (supplyBefore == amount) {
            share.vaultMint(msg.sender, REFILL_SUPPLY);
        }

        emit Claim(msg.sender, to, amount, ethOut, stEthOut, 0);
        if (ethOut != 0) _payEth(to, ethOut);
        if (stEthOut != 0) _payToken(address(steth), to, stEthOut);
    }

    /// @notice View helper to preview a claim without burning.
    function previewCoin(uint256 amount) external view returns (uint256 coinOut) {
        uint256 supply = coinShare.totalSupply();
        if (amount == 0 || amount > supply) revert Insufficient();
        uint256 coinBal = _tokenBalance(coin);
        coinOut = (coinBal * amount) / supply;
    }

    /// @notice View helper to preview an ETH/stETH claim without burning.
    function previewEth(uint256 amount) external view returns (uint256 ethOut, uint256 stEthOut) {
        uint256 supply = ethShare.totalSupply();
        if (amount == 0 || amount > supply) revert Insufficient();
        uint256 ethBal = address(this).balance;
        uint256 stBal = _tokenBalance(address(steth));
        uint256 combined = ethBal + stBal;
        uint256 claimValue = (combined * amount) / supply;

        if (claimValue <= ethBal) {
            ethOut = claimValue;
        } else {
            ethOut = ethBal;
            stEthOut = claimValue - ethBal;
        }
    }

    function _tokenBalance(address token) private view returns (uint256) {
        return IERC20Minimal(token).balanceOf(address(this));
    }

    function _payEth(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _payToken(address token, address to, uint256 amount) private {
        if (!IERC20Minimal(token).transfer(to, amount)) revert TransferFailed();
    }

    function _pullToken(address token, address from, uint256 amount) private {
        if (amount == 0) return;
        if (!IERC20Minimal(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }
}
