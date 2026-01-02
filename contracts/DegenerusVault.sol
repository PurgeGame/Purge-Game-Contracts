// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                        DegenerusVault                                                 ║
║                     Multi-Asset Vault with Independent Share Classes                                  ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                       ║
║  ARCHITECTURE OVERVIEW                                                                                ║
║  ─────────────────────                                                                                ║
║  DegenerusVault holds four asset types with four independent share classes for claims:                ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              ASSET & SHARE MAPPING                                               │ ║
║  │                                                                                                  │ ║
║  │   ┌─────────────────┐     ┌─────────────────┐                                                   │ ║
║  │   │  ASSETS HELD    │     │  SHARE CLASSES  │                                                   │ ║
║  │   ├─────────────────┤     ├─────────────────┤                                                   │ ║
║  │   │  ETH            │────►│  ethShare       │  DGVE - Claims ETH + stETH proportionally         │ ║
║  │   │  stETH          │────►│  (combined)     │                                                   │ ║
║  │   ├─────────────────┤     ├─────────────────┤                                                   │ ║
║  │   │  BURNIE (coin)  │────►│  coinShare      │  DGVB - Claims BURNIE only (80% of deposits)     │ ║
║  │   ├─────────────────┤     ├─────────────────┤                                                   │ ║
║  │   │  DGNRS          │────►│  dgnrsShare     │  DGVD - Claims DGNRS only (80% of deposits)      │ ║
║  │   └─────────────────┘     └─────────────────┘                                                   │ ║
║  │                                                                                                  │ ║
║  │   DGVA (allShare) claims 20% of combined ETH+stETH deposits and 20% of                           │ ║
║  │   BURNIE/DGNRS virtual deposits. ETH and stETH are interchangeable for DGVE/DGVA.               │ ║
║  │   stETH rebase yield accrues to DGVE only (DGVA does not earn yield).                             │ ║
║  │   Each share class has independent supply and proportional claim rights.                        │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              DEPOSIT FLOW (Bond-Only)                                            │ ║
║  │                                                                                                  │ ║
║  │   DegenerusBonds ────► deposit() ────► Pulls ETH/stETH, escrows BURNIE mint allowance           │ ║
║  │        │                                                                                         │ ║
║  │        └────────────► depositDgnrs() ► Escrows DGNRS mint allowance                             │ ║
║  │                                                                                                  │ ║
║  │   Split: 20% of ETH+stETH and virtual deposits accrue to DGVA; 80% to existing classes.         │ ║
║  │   stETH rebase yield accrues to DGVE only.                                                        │ ║
║  │                                                                                                  │ ║
║  │   Note: BURNIE and DGNRS use "virtual" deposits via vaultEscrow() - no token transfer,          │ ║
║  │         just increases the vault's mint allowance on those contracts.                           │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              CLAIM FLOW (Burn Shares)                                            │ ║
║  │                                                                                                  │ ║
║  │   User ────► burnCoin(amount) ────► Burns coinShare ────► Mints BURNIE to user                  │ ║
║  │   User ────► burnDgnrs(amount) ───► Burns dgnrsShare ───► Mints DGNRS to user                   │ ║
║  │   User ────► burnEth(amount) ─────► Burns ethShare ─────► Sends ETH + stETH to user             │ ║
║  │   User ────► burnAll(amount) ─────► Burns allShare ─────► Sends ETH + stETH + BURNIE + DGNRS    │ ║
║  │                                                                                                  │ ║
║  │   Formula: claimAmount = (reserveBalance * sharesBurned) / totalShareSupply                     │ ║
║  │                                                                                                  │ ║
║  │   REFILL MECHANISM: If user burns ALL shares, 1B new shares are minted to them.                 │ ║
║  │   This prevents division-by-zero and keeps the share token alive.                               │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  KEY INVARIANTS                                                                                       ║
║  ──────────────                                                                                       ║
║  • Share supply can never reach zero (refill mechanism)                                               ║
║  • Only the bonds contract can deposit assets                                                         ║
║  • Only this vault can mint/burn share tokens                                                         ║
║  • ETH and stETH are combined for DGVE/DGVA claims (ETH preferred, then stETH)                         ║
║  • DGVE claims exclude DGVA's reserved share of the combined pool                                     ║
║  • All wiring is immutable after construction                                                         ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  SECURITY CONSIDERATIONS                                                                              ║
║  ───────────────────────                                                                              ║
║                                                                                                       ║
║  1. REENTRANCY PROTECTION                                                                             ║
║     • Burn functions follow CEI: state changes (burn/mint) before external calls (payouts)            ║
║     • ETH transfer via .call{} happens after balance is calculated from current state                 ║
║     • address(this).balance decreases atomically with ETH send (before callback)                      ║
║                                                                                                       ║
║  2. ACCESS CONTROL                                                                                    ║
║     • deposits: onlyBonds modifier (immutable bonds address)                                          ║
║     • share mint/burn: onlyVault modifier on DegenerusVaultShare                                      ║
║     • no admin functions, no upgrade path                                                             ║
║                                                                                                       ║
║  3. OVERFLOW SAFETY                                                                                   ║
║     • Solidity 0.8+ automatic checks on most operations                                               ║
║     • unchecked blocks only where underflow is impossible (balance >= amount verified)                ║
║     • Share supply bounded by refill mechanism (min 1B after full burn)                               ║
║                                                                                                       ║
║  4. ROUNDING                                                                                          ║
║     • Claims use floor division - small dust may remain in vault                                      ║
║     • Preview functions use ceiling for "burn required" calculations                                  ║
║     • stETH has known 1-2 wei rounding on transfers (Lido limitation)                                 ║
║                                                                                                       ║
║  5. stETH REBASE                                                                                      ║
║     • stETH is a rebasing token - balances increase over time                                         ║
║     • Yield is attributed to DGVE only (DGVA only earns explicit deposits)                            ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  TRUST ASSUMPTIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. Bonds contract is trusted to deposit correctly                                                    ║
║  2. BURNIE coin implements vaultEscrow/vaultMintTo correctly                                          ║
║  3. DGNRS token implements vaultEscrow/vaultMintTo correctly                                          ║
║  4. stETH (Lido) behaves according to its specification                                               ║
║  5. Initial share holder (deployer) is trusted with initial 1B shares per class                       ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  GAS OPTIMIZATIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. Share classes are separate contracts (avoids complex accounting in one contract)                  ║
║  2. Virtual deposits for BURNIE/DGNRS (no token transfers, just mint allowance bumps)                 ║
║  3. Custom errors instead of require strings                                                          ║
║  4. unchecked blocks for safe arithmetic                                                              ║
║  5. Immutable for all wiring addresses                                                                ║
║  6. ETH preferred over stETH in claims (avoids stETH transfer gas when possible)                      ║
║                                                                                                       ║
╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝
*/

// ─────────────────────────────────────────────────────────────────────────────
// EXTERNAL INTERFACES
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Minimal ERC20 interface for token interactions
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice stETH interface with Lido submit function
interface IStETH {
    /// @notice Stake ETH and receive stETH
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Interface for tokens with vault mint allowance (BURNIE, DGNRS)
interface IVaultCoin {
    /// @notice Increase the vault's mint allowance without transferring tokens
    function vaultEscrow(uint256 amount) external;
    /// @notice Mint tokens to recipient from vault's allowance
    function vaultMintTo(address to, uint256 amount) external;
    /// @notice View the vault's remaining mint allowance
    function vaultMintAllowance() external view returns (uint256);
}

/// @notice Interface to read DGNRS token address from bonds contract
interface IDegenerusBondsDgnrs {
    function dgnrsToken() external view returns (address);
}

// ─────────────────────────────────────────────────────────────────────────────
// VAULT SHARE TOKEN
// ─────────────────────────────────────────────────────────────────────────────

/// @title DegenerusVaultShare
/// @notice Minimal ERC20 for vault share classes (DGVB, DGVD, DGVE, DGVA)
/// @dev Only the parent vault can mint/burn. Standard ERC20 transfer/approve for users.
contract DegenerusVaultShare {
    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Caller is not the authorized vault contract
    error Unauthorized();
    /// @dev Address parameter is zero when non-zero required
    error ZeroAddress();
    /// @dev Insufficient balance or allowance for operation
    error Insufficient();

    // ─────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Standard ERC20 Transfer event
    event Transfer(address indexed from, address indexed to, uint256 amount);
    /// @dev Standard ERC20 Approval event
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────
    // ERC20 STATE
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Token name (e.g., "Degenerus Vault Burnie")
    string public name;
    /// @notice Token symbol (e.g., "DGVB")
    string public symbol;
    /// @notice Token decimals (always 18)
    uint8 public constant decimals = 18;

    /// @notice Total supply of shares
    uint256 public totalSupply;
    /// @notice Balance of shares per address
    mapping(address => uint256) public balanceOf;
    /// @notice Allowance mapping for transferFrom
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev The vault contract authorized to mint/burn shares
    address private immutable vault;

    // ─────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Restricts function to the parent vault contract
    modifier onlyVault() {
        if (msg.sender != vault) revert Unauthorized();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Deploy a new share token with initial supply
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param vault_ Parent vault address (immutable, sole mint/burn authority)
    /// @param initialSupply Initial supply to mint (typically 1B)
    /// @param initialHolder Address to receive initial supply
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

    // ─────────────────────────────────────────────────────────────────────
    // ERC20 STANDARD FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Approve spender to transfer tokens on behalf of caller
    /// @param spender Address to approve
    /// @param amount Amount to approve (type(uint256).max for unlimited)
    /// @return success Always true
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer tokens to recipient
    /// @param to Recipient address
    /// @param amount Amount to transfer
    /// @return success Always true (reverts on failure)
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer tokens from one address to another (requires allowance)
    /// @param from Source address
    /// @param to Destination address
    /// @param amount Amount to transfer
    /// @return success Always true (reverts on failure)
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

    // ─────────────────────────────────────────────────────────────────────
    // VAULT-CONTROLLED MINT/BURN
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Mint new shares to recipient (vault only)
    /// @dev Used for refill mechanism when all shares are burned
    /// @param to Recipient address
    /// @param amount Amount to mint
    function vaultMint(address to, uint256 amount) external onlyVault {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        unchecked {
            balanceOf[to] += amount; // Safe: totalSupply checked, so this can't overflow
        }
        emit Transfer(address(0), to, amount);
    }

    /// @notice Burn shares from holder (vault only)
    /// @dev Used when users claim underlying assets
    /// @param from Address to burn from
    /// @param amount Amount to burn
    function vaultBurn(address from, uint256 amount) external onlyVault {
        uint256 bal = balanceOf[from];
        if (amount == 0 || amount > bal) revert Insufficient();
        unchecked {
            balanceOf[from] = bal - amount; // Safe: amount <= bal verified above
            totalSupply -= amount;          // Safe: sum(balances) == totalSupply invariant
        }
        emit Transfer(from, address(0), amount);
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Internal transfer logic with balance checks
    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (amount == 0 || amount > bal) revert Insufficient();
        unchecked {
            balanceOf[from] = bal - amount; // Safe: amount <= bal verified above
            balanceOf[to] += amount;        // Safe: total supply is constant, can't overflow
        }
        emit Transfer(from, to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN VAULT CONTRACT
// ─────────────────────────────────────────────────────────────────────────────

/// @title DegenerusVault
/// @notice Multi-asset vault with four independent share classes for claiming different assets
/// @dev See contract header for full architecture documentation
contract DegenerusVault {
    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Caller is not authorized (not bonds contract)
    error Unauthorized();
    /// @dev Address parameter is zero when non-zero required
    error ZeroAddress();
    /// @dev Insufficient balance, allowance, or reserve for operation
    error Insufficient();
    /// @dev ETH or token transfer failed
    error TransferFailed();

    // ─────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Legacy ERC20 Transfer event (vault itself is not ERC20, but kept for compatibility)
    event Transfer(address indexed from, address indexed to, uint256 amount);
    /// @dev Legacy ERC20 Approval event
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    /// @notice Emitted when assets are deposited into the vault
    /// @param from Depositor address (typically bonds contract)
    /// @param ethAmount ETH deposited (via msg.value)
    /// @param stEthAmount stETH pulled from depositor
    /// @param coinAmount BURNIE mint allowance escrowed (virtual deposit)
    event Deposit(address indexed from, uint256 ethAmount, uint256 stEthAmount, uint256 coinAmount);
    /// @notice Emitted when DGNRS mint allowance is escrowed
    /// @param from Depositor address (bonds contract)
    /// @param dgnrsAmount DGNRS mint allowance escrowed (virtual deposit)
    event DepositDgnrs(address indexed from, uint256 dgnrsAmount);
    /// @notice Emitted when user burns shares to claim ETH/stETH/BURNIE
    /// @param from User who burned shares
    /// @param sharesBurned Amount of shares burned
    /// @param ethOut ETH sent to user
    /// @param stEthOut stETH sent to user
    /// @param coinOut BURNIE minted to user
    event Claim(address indexed from, uint256 sharesBurned, uint256 ethOut, uint256 stEthOut, uint256 coinOut);
    /// @notice Emitted when user burns DGNRS shares to claim DGNRS
    /// @param from User who burned shares
    /// @param sharesBurned Amount of DGNRS shares burned
    /// @param dgnrsOut DGNRS minted to user
    event ClaimDgnrs(address indexed from, uint256 sharesBurned, uint256 dgnrsOut);
    /// @notice Emitted when user burns DGVA shares to claim ETH/stETH/BURNIE/DGNRS
    /// @param from User who burned shares
    /// @param sharesBurned Amount of DGVA shares burned
    /// @param ethOut ETH sent to user
    /// @param stEthOut stETH sent to user
    /// @param coinOut BURNIE minted to user
    /// @param dgnrsOut DGNRS minted to user
    event ClaimAll(
        address indexed from,
        uint256 sharesBurned,
        uint256 ethOut,
        uint256 stEthOut,
        uint256 coinOut,
        uint256 dgnrsOut
    );

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Vault metadata name
    string public constant name = "Degenerus Vault";
    /// @notice Vault metadata symbol
    string public constant symbol = "DGV";
    /// @notice Vault metadata decimals
    uint8 public constant decimals = 18;
    /// @dev Initial supply minted to deployer for each share class (1 billion tokens)
    uint256 private constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    /// @dev Supply minted when all shares are burned (keeps token alive)
    uint256 private constant REFILL_SUPPLY = 1_000_000_000 * 1e18;
    /// @dev DGVA share of deposits: 20% (amount / 5)
    uint256 private constant DGVA_SPLIT_DIVISOR = 5;

    // ─────────────────────────────────────────────────────────────────────
    // SHARE CLASS TOKENS (Immutable)
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Share token for BURNIE claims (symbol: DGVB)
    DegenerusVaultShare private immutable coinShare;
    /// @notice Share token for DGNRS claims (symbol: DGVD)
    DegenerusVaultShare private immutable dgnrsShare;
    /// @notice Share token for ETH+stETH claims (symbol: DGVE)
    DegenerusVaultShare private immutable ethShare;
    /// @notice Share token for 20% multi-asset claims (symbol: DGVA)
    DegenerusVaultShare private immutable allShare;

    // ─────────────────────────────────────────────────────────────────────
    // WIRING (Immutable)
    // ─────────────────────────────────────────────────────────────────────
    /// @dev BURNIE token address (implements IVaultCoin)
    address private immutable coin;
    /// @dev DGNRS token address (implements IVaultCoin)
    address private immutable dgnrs;
    /// @dev stETH token address (Lido)
    IStETH private immutable steth;
    /// @dev Bonds contract - sole depositor authority
    address private immutable bonds;

    // ─────────────────────────────────────────────────────────────────────
    // RESERVE TRACKING (DGVA SPLIT)
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Combined ETH+stETH reserved for DGVA claims (20% of deposits)
    uint256 private dgvaEthReserve;
    /// @dev BURNIE reserved for DGVA claims (20% of virtual deposits)
    uint256 private dgvaCoinReserve;
    /// @dev DGNRS reserved for DGVA claims (20% of virtual deposits)
    uint256 private dgvaDgnrsReserve;
    /// @dev Tracked total BURNIE allowance (for split accounting)
    uint256 private coinTracked;
    /// @dev Tracked total DGNRS allowance (for split accounting)
    uint256 private dgnrsTracked;

    // ─────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Restricts function to the bonds contract
    modifier onlyBonds() {
        if (msg.sender != bonds) revert Unauthorized();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Deploy the vault with all required addresses
    /// @dev Deploys four share tokens and reads DGNRS address from bonds contract
    /// @param coin_ BURNIE token address
    /// @param stEth_ stETH (Lido) token address
    /// @param bonds_ DegenerusBonds contract address (sole depositor)
    constructor(address coin_, address stEth_, address bonds_) {
        if (coin_ == address(0) || stEth_ == address(0) || bonds_ == address(0)) revert ZeroAddress();

        coin = coin_;
        steth = IStETH(stEth_);
        bonds = bonds_;

        // Read DGNRS token address from bonds contract
        address dgnrsToken = IDegenerusBondsDgnrs(bonds_).dgnrsToken();
        if (dgnrsToken == address(0)) revert ZeroAddress();
        dgnrs = dgnrsToken;

        // Deploy share class tokens - deployer receives initial 1B supply of each
        coinShare = new DegenerusVaultShare(
            "Degenerus Vault Burnie",
            "DGVB",
            address(this),
            INITIAL_SUPPLY,
            msg.sender
        );
        dgnrsShare = new DegenerusVaultShare(
            "Degenerus Vault DGNRS",
            "DGVD",
            address(this),
            INITIAL_SUPPLY,
            msg.sender
        );
        ethShare = new DegenerusVaultShare(
            "Degenerus Vault Eth",
            "DGVE",
            address(this),
            INITIAL_SUPPLY,
            msg.sender
        );
        allShare = new DegenerusVaultShare(
            "Degenerus Vault All",
            "DGVA",
            address(this),
            INITIAL_SUPPLY,
            msg.sender
        );

        uint256 coinAllowance = IVaultCoin(coin_).vaultMintAllowance();
        coinTracked = coinAllowance;
        dgvaCoinReserve = coinAllowance / DGVA_SPLIT_DIVISOR;

        uint256 dgnrsAllowance = IVaultCoin(dgnrsToken).vaultMintAllowance();
        dgnrsTracked = dgnrsAllowance;
        dgvaDgnrsReserve = dgnrsAllowance / DGVA_SPLIT_DIVISOR;

        uint256 combined = address(this).balance + _tokenBalance(address(steth));
        dgvaEthReserve = combined / DGVA_SPLIT_DIVISOR;
    }

    // ─────────────────────────────────────────────────────────────────────
    // DEPOSITS (Bond-Only)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Deposit ETH, stETH, and/or BURNIE mint allowance into the vault
    /// @dev Bonds contract only. BURNIE uses virtual deposit (escrows mint allowance, no transfer).
    ///      ETH is received via msg.value, stETH is pulled via transferFrom.
    ///      20% of ETH+stETH and virtual deposits accrue to DGVA; ETH/stETH interchangeable for DGVE/DGVA.
    /// @param coinAmount BURNIE mint allowance to escrow (virtual deposit)
    /// @param stEthAmount stETH to pull from caller
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable onlyBonds {
        if (coinAmount != 0) {
            _syncCoinReserves();
            IVaultCoin(coin).vaultEscrow(coinAmount);
            uint256 dgvaShare = coinAmount / DGVA_SPLIT_DIVISOR;
            dgvaCoinReserve += dgvaShare;
            coinTracked += coinAmount;
        }
        _pullToken(address(steth), msg.sender, stEthAmount);
        uint256 combinedIn = msg.value + stEthAmount;
        if (combinedIn != 0) {
            dgvaEthReserve += combinedIn / DGVA_SPLIT_DIVISOR;
        }
        emit Deposit(msg.sender, msg.value, stEthAmount, coinAmount);
    }

    /// @notice Deposit DGNRS mint allowance into the vault
    /// @dev Bonds contract only. Virtual deposit - escrows mint allowance, no token transfer.
    /// @param dgnrsAmount DGNRS mint allowance to escrow
    function depositDgnrs(uint256 dgnrsAmount) external onlyBonds {
        if (dgnrsAmount == 0) return;
        _syncDgnrsReserves();
        IVaultCoin(dgnrs).vaultEscrow(dgnrsAmount);
        uint256 dgvaShare = dgnrsAmount / DGVA_SPLIT_DIVISOR;
        dgvaDgnrsReserve += dgvaShare;
        dgnrsTracked += dgnrsAmount;
        emit DepositDgnrs(msg.sender, dgnrsAmount);
    }

    /// @notice Receive ETH deposits (e.g., from game contract)
    /// @dev Anyone can send ETH; splits 20% to DGVA and 80% to DGVE (combined pool)
    receive() external payable {
        if (msg.value != 0) {
            dgvaEthReserve += msg.value / DGVA_SPLIT_DIVISOR;
        }
        emit Deposit(msg.sender, msg.value, 0, 0);
    }

    /// @notice Swap ETH <-> stETH with the bonds contract for liquidity rebalancing
    /// @dev Bonds contract only. Used to convert between ETH and stETH as needed.
    ///      stEthForEth=true: Bonds sends stETH, receives ETH back
    ///      stEthForEth=false: Bonds sends ETH, receives freshly staked stETH back
    /// @param stEthForEth Direction of swap (true = stETH→ETH, false = ETH→stETH)
    /// @param amount Amount to swap
    function swapWithBonds(bool stEthForEth, uint256 amount) external payable {
        if (msg.sender != bonds) revert Unauthorized();
        if (amount == 0) revert Insufficient();

        if (stEthForEth) {
            // Bonds sends stETH, receives ETH
            if (msg.value != 0) revert Insufficient();
            if (!steth.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
            if (address(this).balance < amount) revert Insufficient();
            _payEth(msg.sender, amount);
        } else {
            // Bonds sends ETH, receives stETH (freshly staked via Lido)
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

    // ─────────────────────────────────────────────────────────────────────
    // CLAIMS (Burn Shares to Redeem Assets)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Burn DGVB (coinShare) tokens to redeem proportional BURNIE
    /// @dev Formula: coinOut = (DGVB reserve * sharesBurned) / totalSupply
    ///      If burning entire supply, caller receives new 1B shares (refill mechanism).
    /// @param amount Amount of DGVB shares to burn
    /// @return coinOut Amount of BURNIE minted to caller
    function burnCoin(uint256 amount) external returns (uint256 coinOut) {
        DegenerusVaultShare share = coinShare;
        uint256 bal = share.balanceOf(msg.sender);
        if (amount == 0 || amount > bal) revert Insufficient();

        _syncCoinReserves();
        uint256 supplyBefore = share.totalSupply();
        uint256 coinBal = coinTracked;
        if (coinBal < dgvaCoinReserve) revert Insufficient();
        coinBal -= dgvaCoinReserve;
        coinOut = (coinBal * amount) / supplyBefore; // Floor division - dust remains

        // CEI: State changes before external calls
        share.vaultBurn(msg.sender, amount);
        if (supplyBefore == amount) {
            // Refill: burning entire supply grants new 1B shares to prevent division-by-zero
            share.vaultMint(msg.sender, REFILL_SUPPLY);
        }
        if (coinOut != 0) {
            coinTracked -= coinOut;
        }

        emit Claim(msg.sender, amount, 0, 0, coinOut);
        if (coinOut != 0) IVaultCoin(coin).vaultMintTo(msg.sender, coinOut);
    }

    /// @notice Burn DGVD (dgnrsShare) tokens to redeem proportional DGNRS
    /// @dev Formula: dgnrsOut = (DGVD reserve * sharesBurned) / totalSupply
    ///      If burning entire supply, caller receives new 1B shares (refill mechanism).
    /// @param amount Amount of DGVD shares to burn
    /// @return dgnrsOut Amount of DGNRS minted to caller
    function burnDgnrs(uint256 amount) external returns (uint256 dgnrsOut) {
        DegenerusVaultShare share = dgnrsShare;
        uint256 bal = share.balanceOf(msg.sender);
        if (amount == 0 || amount > bal) revert Insufficient();

        _syncDgnrsReserves();
        uint256 supplyBefore = share.totalSupply();
        uint256 dgnrsBal = dgnrsTracked;
        if (dgnrsBal < dgvaDgnrsReserve) revert Insufficient();
        dgnrsBal -= dgvaDgnrsReserve;
        dgnrsOut = (dgnrsBal * amount) / supplyBefore; // Floor division

        // CEI: State changes before external calls
        share.vaultBurn(msg.sender, amount);
        if (supplyBefore == amount) {
            share.vaultMint(msg.sender, REFILL_SUPPLY);
        }
        if (dgnrsOut != 0) {
            dgnrsTracked -= dgnrsOut;
        }

        emit ClaimDgnrs(msg.sender, amount, dgnrsOut);
        if (dgnrsOut != 0) IVaultCoin(dgnrs).vaultMintTo(msg.sender, dgnrsOut);
    }

    /// @notice Burn DGVE (ethShare) tokens to redeem proportional ETH and stETH
    /// @dev ETH is preferred over stETH (uses ETH first, then stETH for remainder).
    ///      Formula: claimValue = (combinedReserve) * sharesBurned / totalSupply
    ///      If burning entire supply, caller receives new 1B shares (refill mechanism).
    /// @param amount Amount of DGVE shares to burn
    /// @return ethOut Amount of ETH sent to caller
    /// @return stEthOut Amount of stETH sent to caller
    function burnEth(uint256 amount) external returns (uint256 ethOut, uint256 stEthOut) {
        DegenerusVaultShare share = ethShare;
        uint256 bal = share.balanceOf(msg.sender);
        if (amount == 0 || amount > bal) revert Insufficient();

        (uint256 ethBal, uint256 stBal, uint256 combined) = _syncEthReserves();
        uint256 supplyBefore = share.totalSupply();
        uint256 dgvaReserve = dgvaEthReserve;
        if (combined < dgvaReserve) revert Insufficient();
        uint256 reserve = combined - dgvaReserve;
        uint256 claimValue = (reserve * amount) / supplyBefore; // Floor division

        // ETH-first payout strategy (saves gas vs stETH transfer)
        if (claimValue <= ethBal) {
            ethOut = claimValue;
        } else {
            ethOut = ethBal;
            stEthOut = claimValue - ethBal;
            if (stEthOut > stBal) revert Insufficient();
        }

        // CEI: State changes before external calls (ETH send has callback risk)
        share.vaultBurn(msg.sender, amount);
        if (supplyBefore == amount) {
            share.vaultMint(msg.sender, REFILL_SUPPLY);
        }

        emit Claim(msg.sender, amount, ethOut, stEthOut, 0);

        // External calls last (ETH balance already reduced atomically with send)
        if (ethOut != 0) _payEth(msg.sender, ethOut);
        if (stEthOut != 0) _payToken(address(steth), msg.sender, stEthOut);
    }

    /// @notice Burn DGVA (allShare) tokens to redeem proportional ETH/stETH, BURNIE, and DGNRS
    /// @dev ETH/stETH claims are limited to DGVA's combined reserve (20% of deposits).
    ///      Formula per asset: out = (reserve * sharesBurned) / totalSupply
    ///      If burning entire supply, caller receives new 1B shares (refill mechanism).
    /// @param amount Amount of DGVA shares to burn
    /// @return ethOut Amount of ETH sent to caller
    /// @return stEthOut Amount of stETH sent to caller
    /// @return coinOut Amount of BURNIE minted to caller
    /// @return dgnrsOut Amount of DGNRS minted to caller
    function burnAll(
        uint256 amount
    ) external returns (uint256 ethOut, uint256 stEthOut, uint256 coinOut, uint256 dgnrsOut) {
        DegenerusVaultShare share = allShare;
        uint256 bal = share.balanceOf(msg.sender);
        if (amount == 0 || amount > bal) revert Insufficient();

        (uint256 ethBal, uint256 stBal, uint256 combined) = _syncEthReserves();
        _syncCoinReserves();
        _syncDgnrsReserves();

        uint256 supplyBefore = share.totalSupply();
        uint256 ethReserve = dgvaEthReserve;
        if (combined < ethReserve) revert Insufficient();
        uint256 coinReserve = dgvaCoinReserve;
        uint256 dgnrsReserve = dgvaDgnrsReserve;

        uint256 claimValue = (ethReserve * amount) / supplyBefore;
        coinOut = (coinReserve * amount) / supplyBefore;
        dgnrsOut = (dgnrsReserve * amount) / supplyBefore;

        if (claimValue <= ethBal) {
            ethOut = claimValue;
        } else {
            ethOut = ethBal;
            stEthOut = claimValue - ethBal;
            if (stEthOut > stBal) revert Insufficient();
        }

        // CEI: State changes before external calls
        share.vaultBurn(msg.sender, amount);
        if (supplyBefore == amount) {
            share.vaultMint(msg.sender, REFILL_SUPPLY);
        }
        if (claimValue != 0) {
            dgvaEthReserve = ethReserve - claimValue;
        }
        if (coinOut != 0) {
            dgvaCoinReserve = coinReserve - coinOut;
            coinTracked -= coinOut;
        }
        if (dgnrsOut != 0) {
            dgvaDgnrsReserve = dgnrsReserve - dgnrsOut;
            dgnrsTracked -= dgnrsOut;
        }

        emit ClaimAll(msg.sender, amount, ethOut, stEthOut, coinOut, dgnrsOut);

        if (ethOut != 0) _payEth(msg.sender, ethOut);
        if (stEthOut != 0) _payToken(address(steth), msg.sender, stEthOut);
        if (coinOut != 0) IVaultCoin(coin).vaultMintTo(msg.sender, coinOut);
        if (dgnrsOut != 0) IVaultCoin(dgnrs).vaultMintTo(msg.sender, dgnrsOut);
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS - Reverse Calculations (Target Output → Required Burn)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Calculate shares to burn for a target BURNIE output
    /// @dev Uses ceiling division to ensure user burns enough shares
    /// @param coinOut Target BURNIE amount to receive
    /// @return burnAmount DGVB shares required to burn
    function previewBurnForCoinOut(uint256 coinOut) external view returns (uint256 burnAmount) {
        (uint256 reserve, ) = _coinReservesView();
        if (coinOut == 0 || coinOut > reserve) revert Insufficient();
        uint256 supply = coinShare.totalSupply();
        // Ceiling division: ceil(coinOut * supply / reserve)
        burnAmount = (coinOut * supply + reserve - 1) / reserve;
    }

    /// @notice Calculate shares to burn for a target DGNRS output
    /// @dev Uses ceiling division to ensure user burns enough shares
    /// @param dgnrsOut Target DGNRS amount to receive
    /// @return burnAmount DGVD shares required to burn
    function previewBurnForDgnrsOut(uint256 dgnrsOut) external view returns (uint256 burnAmount) {
        (uint256 reserve, ) = _dgnrsReservesView();
        if (dgnrsOut == 0 || dgnrsOut > reserve) revert Insufficient();
        uint256 supply = dgnrsShare.totalSupply();
        // Ceiling division: ceil(dgnrsOut * supply / reserve)
        burnAmount = (dgnrsOut * supply + reserve - 1) / reserve;
    }

    /// @notice Calculate shares to burn for a target ETH-equivalent value
    /// @dev Value = DGVE's share of the combined ETH+stETH pool. Uses ceiling division.
    /// @param targetValue Target combined ETH+stETH value to receive (DGVE share)
    /// @return burnAmount DGVE shares required to burn
    /// @return ethOut Estimated ETH output
    /// @return stEthOut Estimated stETH output
    function previewBurnForEthOut(
        uint256 targetValue
    ) external view returns (uint256 burnAmount, uint256 ethOut, uint256 stEthOut) {
        uint256 supply = ethShare.totalSupply();
        (uint256 reserve, , uint256 ethBal) = _ethReservesView();
        if (targetValue == 0 || targetValue > reserve) revert Insufficient();

        // Ceiling division: ceil(targetValue * supply / reserve)
        burnAmount = (targetValue * supply + reserve - 1) / reserve;

        // Simulate actual claim output with calculated burn amount
        uint256 claimValue = (reserve * burnAmount) / supply;
        if (claimValue <= ethBal) {
            ethOut = claimValue;
        } else {
            ethOut = ethBal;
            stEthOut = claimValue - ethBal;
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS - Forward Calculations (Shares to Burn → Expected Output)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Preview BURNIE output for burning a given amount of shares
    /// @param amount DGVB shares to burn
    /// @return coinOut BURNIE that would be minted
    function previewCoin(uint256 amount) external view returns (uint256 coinOut) {
        uint256 supply = coinShare.totalSupply();
        if (amount == 0 || amount > supply) revert Insufficient();
        (uint256 coinBal, ) = _coinReservesView();
        coinOut = (coinBal * amount) / supply; // Floor division
    }

    /// @notice Preview DGNRS output for burning a given amount of shares
    /// @param amount DGVD shares to burn
    /// @return dgnrsOut DGNRS that would be minted
    function previewDgnrs(uint256 amount) external view returns (uint256 dgnrsOut) {
        uint256 supply = dgnrsShare.totalSupply();
        if (amount == 0 || amount > supply) revert Insufficient();
        (uint256 dgnrsBal, ) = _dgnrsReservesView();
        dgnrsOut = (dgnrsBal * amount) / supply; // Floor division
    }

    /// @notice Preview ETH/stETH output for burning a given amount of shares
    /// @param amount DGVE shares to burn
    /// @return ethOut ETH that would be sent
    /// @return stEthOut stETH that would be sent
    function previewEth(uint256 amount) external view returns (uint256 ethOut, uint256 stEthOut) {
        uint256 supply = ethShare.totalSupply();
        if (amount == 0 || amount > supply) revert Insufficient();
        (uint256 reserve, , uint256 ethBal) = _ethReservesView();
        uint256 claimValue = (reserve * amount) / supply; // Floor division

        // ETH-first payout strategy
        if (claimValue <= ethBal) {
            ethOut = claimValue;
        } else {
            ethOut = ethBal;
            stEthOut = claimValue - ethBal;
        }
    }

    /// @notice Preview ETH/stETH/BURNIE/DGNRS output for burning a given amount of DGVA shares
    /// @param amount DGVA shares to burn
    /// @return ethOut ETH that would be sent
    /// @return stEthOut stETH that would be sent
    /// @return coinOut BURNIE that would be minted
    /// @return dgnrsOut DGNRS that would be minted
    function previewAll(
        uint256 amount
    ) external view returns (uint256 ethOut, uint256 stEthOut, uint256 coinOut, uint256 dgnrsOut) {
        uint256 supply = allShare.totalSupply();
        if (amount == 0 || amount > supply) revert Insufficient();
        (, uint256 ethReserve, uint256 ethBal) = _ethReservesView();
        ( , uint256 coinBal) = _coinReservesView();
        ( , uint256 dgnrsBal) = _dgnrsReservesView();
        uint256 claimValue = (ethReserve * amount) / supply;
        if (claimValue <= ethBal) {
            ethOut = claimValue;
        } else {
            ethOut = ethBal;
            stEthOut = claimValue - ethBal;
        }
        coinOut = (coinBal * amount) / supply;
        dgnrsOut = (dgnrsBal * amount) / supply;
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Clamp DGVA's ETH+stETH reserve to actual balance; returns balances to avoid re-reading
    function _syncEthReserves() private returns (uint256 ethBal, uint256 stBal, uint256 combined) {
        ethBal = address(this).balance;
        stBal = _tokenBalance(address(steth));
        combined = ethBal + stBal;
        if (dgvaEthReserve > combined) {
            dgvaEthReserve = combined;
        }
    }

    /// @dev Sync BURNIE reserve split with the actual allowance
    function _syncCoinReserves() private {
        uint256 allowance = IVaultCoin(coin).vaultMintAllowance();
        uint256 tracked = coinTracked;
        if (allowance > tracked) {
            uint256 delta = allowance - tracked;
            uint256 dgvaShare = delta / DGVA_SPLIT_DIVISOR;
            dgvaCoinReserve += dgvaShare;
            coinTracked = allowance;
        } else if (allowance < tracked) {
            coinTracked = allowance;
            if (dgvaCoinReserve > allowance) {
                dgvaCoinReserve = allowance;
            }
        }
    }

    /// @dev Sync DGNRS reserve split with the actual allowance
    function _syncDgnrsReserves() private {
        uint256 allowance = IVaultCoin(dgnrs).vaultMintAllowance();
        uint256 tracked = dgnrsTracked;
        if (allowance > tracked) {
            uint256 delta = allowance - tracked;
            uint256 dgvaShare = delta / DGVA_SPLIT_DIVISOR;
            dgvaDgnrsReserve += dgvaShare;
            dgnrsTracked = allowance;
        } else if (allowance < tracked) {
            dgnrsTracked = allowance;
            if (dgvaDgnrsReserve > allowance) {
                dgvaDgnrsReserve = allowance;
            }
        }
    }

    /// @dev View helper for BURNIE reserves with pending split delta applied
    function _coinReservesView() private view returns (uint256 mainReserve, uint256 dgvaReserve) {
        uint256 allowance = IVaultCoin(coin).vaultMintAllowance();
        uint256 tracked = coinTracked;
        dgvaReserve = dgvaCoinReserve;
        if (allowance > tracked) {
            uint256 delta = allowance - tracked;
            dgvaReserve += delta / DGVA_SPLIT_DIVISOR;
        }
        if (dgvaReserve > allowance) {
            dgvaReserve = allowance;
        }
        mainReserve = allowance - dgvaReserve;
    }

    /// @dev View helper for DGNRS reserves with pending split delta applied
    function _dgnrsReservesView() private view returns (uint256 mainReserve, uint256 dgvaReserve) {
        uint256 allowance = IVaultCoin(dgnrs).vaultMintAllowance();
        uint256 tracked = dgnrsTracked;
        dgvaReserve = dgvaDgnrsReserve;
        if (allowance > tracked) {
            uint256 delta = allowance - tracked;
            dgvaReserve += delta / DGVA_SPLIT_DIVISOR;
        }
        if (dgvaReserve > allowance) {
            dgvaReserve = allowance;
        }
        mainReserve = allowance - dgvaReserve;
    }

    /// @dev View helper for ETH+stETH reserves (stETH rebase yield goes to DGVE)
    function _ethReservesView()
        private
        view
        returns (uint256 mainReserve, uint256 dgvaReserve, uint256 ethBal)
    {
        ethBal = address(this).balance;
        uint256 stBal = _tokenBalance(address(steth));
        uint256 combined = ethBal + stBal;
        dgvaReserve = dgvaEthReserve;
        if (dgvaReserve > combined) {
            dgvaReserve = combined;
        }
        mainReserve = combined - dgvaReserve;
    }

    /// @dev Get token balance of this contract
    function _tokenBalance(address token) private view returns (uint256) {
        return IERC20Minimal(token).balanceOf(address(this));
    }

    /// @dev Send ETH to recipient using low-level call
    /// @notice Uses .call{} to support contracts with custom receive logic
    function _payEth(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Transfer ERC20 token to recipient
    function _payToken(address token, address to, uint256 amount) private {
        if (!IERC20Minimal(token).transfer(to, amount)) revert TransferFailed();
    }

    /// @dev Pull ERC20 token from sender (requires prior approval)
    function _pullToken(address token, address from, uint256 amount) private {
        if (amount == 0) return;
        if (!IERC20Minimal(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }
}
