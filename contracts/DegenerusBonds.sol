// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal view into the core game to read the current level.
interface IDegenerusGameLevel {
    function level() external view returns (uint24);
}

/// @notice Minimal view into the game for bond banking (ETH pooling + claim credit).
interface IDegenerusGameBondBank is IDegenerusGameLevel {
    function bondDeposit() external payable;
    function bondYieldDeposit() external payable;
    function bondCreditToClaimable(address player, uint256 amount) external;
    function bondAvailable() external view returns (uint256);
}

/// @notice Minimal VRF coordinator surface for V2+ random word requests.
interface IVRFCoordinatorV2Like {
    function requestRandomWords(
        bytes32 keyHash,
        uint256 subId,
        uint16 requestConfirmations,
        uint32 callbackGasLimit,
        uint32 numWords
    ) external returns (uint256 requestId);
}

interface IStETHLike {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IVaultLike {
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable;
    function swapWithBonds(bool stEthForEth, uint256 amount) external payable;
    function steth() external view returns (address);
}

interface ICoinLike {
    function transfer(address to, uint256 amount) external returns (bool);
}

/**
 * @title BondToken
 * @notice Minimal mintable/burnable ERC20 representing liquid bonds for a specific maturity level.
 */
contract BondToken {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error InsufficientBalance();
    error Disabled();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------
    // Immutable data
    // ---------------------------------------------------------------------
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint24 public immutable maturityLevel;
    address public immutable minter;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool private disabled;

    constructor(string memory name_, string memory symbol_, address minter_, uint24 maturityLevel_) {
        name = name_;
        symbol = symbol_;
        minter = minter_;
        maturityLevel = maturityLevel_;
    }

    // ------------------------------------------------------------------
    // ERC20 core
    // ------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _requireActive();
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _requireActive();
        uint256 allowed = allowance[from][msg.sender];
        if (allowed < amount) revert Unauthorized();
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowance[from][msg.sender]);
        }
        _transfer(from, to, amount);
        return true;
    }

    // ------------------------------------------------------------------
    // Mint / burn (minter-gated mint, holder/approved burn)
    // ------------------------------------------------------------------

    function mint(address to, uint256 amount) external {
        _requireActive();
        if (msg.sender != minter) revert Unauthorized();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        _requireActive();
        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed < amount) revert Unauthorized();
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
                emit Approval(from, msg.sender, allowance[from][msg.sender]);
            }
        }
        _burn(from, amount);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _requireActive() private view {
        if (disabled) revert Disabled();
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) private {
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    /// @notice Permanently disable transfers/mint/burn; callable only by the minter (bond controller).
    function nuke() external {
        if (msg.sender != minter) revert Unauthorized();
        disabled = true;
    }
}

/**
 * @title DegenerusBonds
 * @notice Bond system wired for the Degenerus game:
 *         - Bonds created every 5 levels; sales open 10 levels before maturity.
 *         - Payout budget = 1.25x the last issuance raise (configurable for the first round).
 *         - Deposits award a score (multiplier stub) used for jackpots.
 *         - Five jackpot days mint a maturity-specific ERC20; total mint equals payout budget.
 *         - Burning the ERC20 enters a two-lane final jackpot at maturity; payout ~pro-rata to burned amount.
 */
contract DegenerusBonds {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error Unauthorized();
    error InvalidMaturity();
    error SaleClosed();
    error InsufficientScore();
    error AlreadyResolved();
    error AlreadySet();
    error BankCallFailed();
    error PurchasesDisabled();
    error NotExpired();
    error VrfLocked();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event BondSeriesCreated(uint24 indexed maturityLevel, uint24 saleStartLevel, address token, uint256 payoutBudget);
    event BondDeposit(address indexed player, uint24 indexed maturityLevel, uint256 amount, uint256 scoreAwarded);
    event BondJackpot(uint24 indexed maturityLevel, uint8 indexed dayIndex, uint256 mintedAmount, uint256 rngWord);
    event BondJackpotPayout(uint24 indexed maturityLevel, address indexed player, uint256 amount, uint8 placement);
    event BondBurned(
        address indexed player,
        uint24 indexed maturityLevel,
        uint8 lane,
        uint256 amount,
        bool boostedScore
    );
    event BondSeriesResolved(
        uint24 indexed maturityLevel,
        uint8 winningLane,
        uint256 payoutEth,
        uint256 remainingToken
    );
    event BondGameOver(uint256 poolSpent, uint24 partialMaturity);
    event BondCoinJackpot(address indexed player, uint256 amount, uint24 maturityLevel, uint8 lane);
    event ExpiredSweep(uint256 ethAmount, uint256 stEthAmount);

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint8 private constant JACKPOT_SPOTS = 100;
    uint8 private constant JACKPOT_DAYS = 255; // effectively unlimited; guarded by payoutBudget remaining
    uint8 private constant TOP_PCT_1 = 20;
    uint8 private constant TOP_PCT_2 = 10;
    uint8 private constant TOP_PCT_3 = 5;
    uint8 private constant TOP_PCT_4 = 5;
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;

    // ---------------------------------------------------------------------
    // Data structures
    // ---------------------------------------------------------------------
    struct LaneEntry {
        address player;
        uint256 amount;
    }

    struct Lane {
        uint256 total;
        LaneEntry[] entries;
        uint256[] cumulative;
        mapping(address => uint256) burnedAmount;
    }

    struct WireConfig {
        address game;
        address vault;
        address coin;
        address vrfCoordinator;
        uint256 vrfSubId;
        bytes32 vrfKeyHash;
    }

    struct BondSeries {
        uint24 maturityLevel;
        uint24 saleStartLevel;
        uint256 payoutBudget;
        uint256 mintedBudget;
        uint256 raised;
        uint8 jackpotsRun;
        uint24 lastJackpotLevel;
        uint256 totalScore;
        BondToken token;
        address[] jackpotParticipants;
        uint256[] jackpotCumulative;
        Lane[2] lanes;
        bool resolved;
        uint8 winningLane;
        uint256 decSharePrice;
        uint256 unclaimedBudget;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    mapping(uint24 => BondSeries) internal series;
    uint24[] internal maturities;
    IDegenerusGameLevel public game;
    address public immutable admin;
    uint256 public lastIssuanceRaise;
    uint256 public immutable initialPayoutBudget;
    address public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint256 public vrfSubscriptionId;
    uint256 public vrfRequestId;
    uint256 private vrfPendingWord;
    bool private vrfRequestPending;
    bool public gameOverStarted; // true after game signals shutdown; disables new deposits and bank pushes
    uint48 public gameOverTimestamp; // timestamp when game over was triggered
    bool public gameOverEntropyAttempted; // true after gameOver() attempts to fetch entropy (request or failure)
    bool public externalPurchasesEnabled = true; // owner toggle for non-game purchases
    bool public gamePurchasesEnabled = true; // owner toggle for game-routed purchases
    address public vault;
    address public coin;
    BondToken private tokenDGNS0;
    BondToken private tokenDGNS5;
    address public immutable steth;
    bool private vrfRecoveryArmed;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address admin_, address steth_, uint256 initialPayoutBudget_) {
        if (admin_ == address(0)) revert Unauthorized();
        if (steth_ == address(0)) revert Unauthorized();
        admin = admin_;
        steth = steth_;
        initialPayoutBudget = initialPayoutBudget_;
    }

    // ---------------------------------------------------------------------
    // External write API
    // ---------------------------------------------------------------------

    /// @notice Wire bonds like other modules: [game, vault, coin, vrfCoordinator] + subId/keyHash (partial allowed).
    function wire(address[] calldata addresses, uint256 vrfSubId, bytes32 vrfKeyHash_) external {
        if (msg.sender != admin) revert Unauthorized();
        _wire(
            WireConfig({
                game: addresses.length > 0 ? addresses[0] : address(0),
                vault: addresses.length > 1 ? addresses[1] : address(0),
                coin: addresses.length > 2 ? addresses[2] : address(0),
                vrfCoordinator: addresses.length > 3 ? addresses[3] : address(0),
                vrfSubId: vrfSubId,
                vrfKeyHash: vrfKeyHash_
            })
        );
    }

    /// @notice Owner toggle to allow/deny purchases from external callers and the game.
    function setPurchaseToggles(bool externalEnabled, bool gameEnabled) external {
        if (msg.sender != admin) revert Unauthorized();
        externalPurchasesEnabled = externalEnabled;
        gamePurchasesEnabled = gameEnabled;
    }

    /// @notice Set the coin token used for coin jackpots funded by the game.
    function setCoin(address coin_) external {
        if (msg.sender != admin) revert Unauthorized();
        _wire(
            WireConfig({
                game: address(0),
                vault: address(0),
                coin: coin_,
                vrfCoordinator: address(0),
                vrfSubId: 0,
                vrfKeyHash: bytes32(0)
            })
        );
    }

    /// @notice Arm a single-use VRF rewire; intended for emergency recovery only.
    function armVrfRecovery() external {
        if (msg.sender != admin) revert Unauthorized();
        vrfRecoveryArmed = true;
    }

    /// @notice Unified deposit: external callers route ETH into the current maturity.
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded) {
        if (msg.sender == address(game)) revert Unauthorized(); // game should use depositFromGame with direct split
        address ben = beneficiary == address(0) ? msg.sender : beneficiary;
        uint256 amount = msg.value;
        scoreAwarded = _processDeposit(ben, amount, false);
    }

    /// @notice Game-only deposit that credits the current maturity and splits ETH without round-tripping.
    function depositFromGame(address beneficiary, uint256 amount) external payable returns (uint256 scoreAwarded) {
        if (msg.sender != address(game)) revert Unauthorized();
        if (amount != msg.value) revert SaleClosed();
        address ben = beneficiary == address(0) ? msg.sender : beneficiary;
        scoreAwarded = _processDeposit(ben, amount, true);
    }

    /// @notice Funding shim used by the game to route yield/coin into bonds and run upkeep.
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable {
        address vaultAddr = vault;
        address stEthToken = steth;
        uint256 vaultShare = (coinAmount * 60) / 100;
        uint256 jackpotShare = coinAmount - vaultShare;
        bool shutdown = gameOverStarted;
        if (stEthAmount != 0) {
            IStETHLike(stEthToken).transferFrom(msg.sender, address(this), stEthAmount);
        }
        // Route ETH + coin share to the vault while live; keep ETH on bonds during shutdown.
        if (!shutdown) {
            uint256 ethIn = msg.value;
            (, bool eligible) = _payCoinJackpot(jackpotShare, rngWord);
            if (!eligible) vaultShare += jackpotShare;
            IVaultLike(vaultAddr).deposit{value: ethIn}(vaultShare, stEthAmount);
            return;
        }
    }

    // ---------------------------------------------------------------------
    // Internals (coin jackpot)
    // ---------------------------------------------------------------------

    function _payCoinJackpot(uint256 amount, uint256 rngWord) private returns (bool paid, bool eligible) {
        if (amount == 0 || rngWord == 0) return (false, false);
        address coinAddr = coin;
        if (coinAddr == address(0)) return (false, false);

        uint24 currLevel = _currentLevel();
        (BondSeries storage target, uint24 targetMat) = _selectActiveSeries(currLevel);
        if (targetMat == 0) return (false, false);

        // Pick a lane with entries.
        uint8 lane = uint8(rngWord & 1);
        if (target.lanes[lane].total == 0 && target.lanes[1 - lane].total != 0) {
            lane = 1 - lane;
        }
        if (target.lanes[lane].total == 0) return (false, false);

        address winner = _weightedLanePick(target.lanes[lane], rngWord);
        if (winner == address(0)) return (false, false);
        eligible = true;

        bool ok = ICoinLike(coinAddr).transfer(winner, amount);
        if (ok) {
            emit BondCoinJackpot(winner, amount, targetMat, lane);
            return (true, true);
        }
        return (false, true);
    }

    function _selectActiveSeries(uint24 currLevel) private view returns (BondSeries storage s, uint24 maturityLevel) {
        uint24 len = uint24(maturities.length);
        for (uint24 i = 0; i < len; i++) {
            BondSeries storage iter = series[maturities[i]];
            if (iter.maturityLevel == 0 || iter.resolved) continue;
            // Consider unresolved series that can still accept burns (before maturity) or are in grace window.
            if (currLevel < iter.maturityLevel) {
                maturityLevel = iter.maturityLevel;
                return (iter, maturityLevel);
            }
        }
        s = series[0]; // dummy slot; caller checks maturityLevel==0 before use
        maturityLevel = 0;
        return (s, maturityLevel);
    }

    function notifyGameOver() external {
        if (msg.sender != address(game)) revert Unauthorized();
        if (!gameOverStarted) {
            gameOverStarted = true;
            gameOverTimestamp = uint48(block.timestamp);
        }
    }

    function purchasesEnabled() external view returns (bool) {
        return !gameOverStarted && gamePurchasesEnabled;
    }

    /// @notice Emergency shutdown path: consume all ETH/stETH and resolve maturities in order, partially paying the last one.
    /// @dev If no entropy is ready, this requests VRF (if configured) and exits; call again once fulfilled.
    function gameOver() external payable {
        if (msg.sender != address(game)) revert Unauthorized();
        if (!gameOverStarted) {
            gameOverStarted = true;
            gameOverTimestamp = uint48(block.timestamp);
        }

        (uint256 entropy, bool requested) = _prepareEntropy(0);
        gameOverEntropyAttempted = true;
        if (entropy == 0) {
            // Either VRF was requested or not configured; no entropy to proceed yet.
            if (requested) return;
            return;
        }

        uint256 initialEth = address(this).balance;
        uint256 initialStEth = _stEthBalance();
        uint256 rollingEntropy = entropy;
        uint24 partialMaturity;

        uint24 len = uint24(maturities.length);
        for (uint24 i = 0; i < len; i++) {
            BondSeries storage s = series[maturities[i]];
            if (s.maturityLevel == 0 || s.resolved) continue;

            (uint256 burned, ) = _obligationTotals(s);
            if (burned == 0) {
                s.resolved = true;
                continue;
            }

            uint256 availableValue = address(this).balance + _stEthBalance();
            if (availableValue == 0) {
                partialMaturity = s.maturityLevel;
                s.resolved = true;
                break;
            }

            uint256 payout = burned <= availableValue ? burned : availableValue;
            uint256 paid = _resolveSeriesGameOver(s, rollingEntropy, payout);
            rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "go")));

            s.resolved = true;

            if (paid < burned) {
                partialMaturity = s.maturityLevel;
                break;
            }
        }

        // Mark any remaining series as resolved and nuke their tokens.
        for (uint24 j = 0; j < len; j++) {
            BondSeries storage rem = series[maturities[j]];
            if (rem.maturityLevel == 0 || rem.resolved) continue;
            rem.resolved = true;
        }

        uint256 remainingEth = address(this).balance;
        uint256 remainingStEth = _stEthBalance();
        uint256 spent = (initialEth + initialStEth) - (remainingEth + remainingStEth);

        uint256 totalReserved;
        for (uint24 k = 0; k < len; k++) {
            totalReserved += series[maturities[k]].unclaimedBudget;
        }

        // Any surplus after resolving in order is forwarded to the vault if configured.
        if (remainingEth > totalReserved && vault != address(0)) {
            uint256 surplus = remainingEth - totalReserved;
            (bool ok, ) = payable(vault).call{value: surplus}("");
            if (ok) {
                remainingEth -= surplus;
            }
        }

        emit BondGameOver(spent, partialMaturity);
    }

    /// @notice Sweep all funds (ETH + stETH) to the vault 1 year after game over.
    /// @dev Callable by anyone; destination is fixed to the vault.
    function sweepExpiredPools() external {
        if (gameOverTimestamp == 0) revert Unauthorized();
        if (block.timestamp <= gameOverTimestamp + 365 days) revert NotExpired();

        address v = vault;
        if (v == address(0)) revert BankCallFailed();

        uint256 ethBal = address(this).balance;
        if (ethBal != 0) {
            (bool ok, ) = payable(v).call{value: ethBal}("");
            ok; // best effort
        }

        uint256 stBal = _stEthBalance();
        if (stBal != 0) {
            try IStETHLike(steth).transfer(v, stBal) {} catch {}
        }
        
        emit ExpiredSweep(ethBal, stBal);
    }

    function _processDeposit(
        address beneficiary,
        uint256 amount,
        bool fromGame
    ) private returns (uint256 scoreAwarded) {
        if (amount == 0) revert SaleClosed();
        if (gameOverStarted) revert SaleClosed();
        if (fromGame) {
            if (!gamePurchasesEnabled) revert PurchasesDisabled();
        } else {
            if (!externalPurchasesEnabled) revert PurchasesDisabled();
        }

        uint24 maturityLevel = _activeMaturity();
        BondSeries storage s = _getOrCreateSeries(maturityLevel);
        uint24 currLevel = _currentLevel();
        if (currLevel < s.saleStartLevel || currLevel >= s.maturityLevel) revert SaleClosed();

        // Split ETH: from game (30% vault, 50% bondPool, 20% rewardPool), external (50% vault, 30% bondPool, 20% rewardPool)
        uint256 vaultShare = (amount * (fromGame ? 30 : 50)) / 100;
        uint256 bondShare = (amount * (fromGame ? 50 : 30)) / 100;
        uint256 rewardShare = amount - vaultShare - bondShare; // remaining 20%

        address vaultAddr = vault;
        if (vaultShare != 0 && vaultAddr != address(0)) {
            (bool sentVault, ) = payable(vaultAddr).call{value: vaultShare}("");
            if (!sentVault) revert BankCallFailed();
        }

        if (bondShare != 0) {
            try IDegenerusGameBondBank(address(game)).bondYieldDeposit{value: bondShare}() {} catch {
                revert BankCallFailed();
            }
        }

        if (rewardShare != 0) {
            (bool sentReward, ) = payable(address(game)).call{value: rewardShare}("");
            if (!sentReward) revert BankCallFailed();
        }

        scoreAwarded = amount;

        // Append new weight slice for jackpot selection (append-only cumulative for O(log N) sampling).
        _recordJackpotScore(s, beneficiary, scoreAwarded);
        s.raised += amount;

        emit BondDeposit(beneficiary, maturityLevel, amount, scoreAwarded);
    }

    function _activeMaturity() private view returns (uint24 maturityLevel) {
        uint24 currLevel = _currentLevel();
        // choose the next multiple of 5 that is at most 10 levels ahead
        maturityLevel = ((currLevel / 5) + 1) * 5;
        while (currLevel < maturityLevel - 10) {
            maturityLevel += 5;
        }
    }

    /// @notice Run bond maintenance for the current level (create series, run jackpots, resolve funded maturities).
    /// @param rngWord Entropy used for jackpots and lane selection.
    function bondMaintenance(uint256 rngWord) public {
        uint24 currLevel = _currentLevel();

        // Start a new series when we are exactly 10 levels before a maturity that is a multiple of 5.
        if ((currLevel + 10) % 5 == 0 && currLevel + 10 >= 5) {
            uint24 maturityLevel = currLevel + 10;
            BondSeries storage s = series[maturityLevel];
            if (s.maturityLevel == 0) {
                _createSeries(maturityLevel);
            }
        }

        (uint256 entropy, bool requested) = _prepareEntropy(rngWord);
        if (entropy == 0) {
            _sweepExcessToVault();
            if (requested) return; // wait for VRF
            // If no entropy provided and no VRF configured, skip RNG-dependent work but allow series creation above.
            return;
        }

        uint256 rollingEntropy = entropy;
        bool backlogPending;
        // Run jackpots and resolve matured series.
        uint24 len = uint24(maturities.length);
        for (uint24 i = 0; i < len; i++) {
            BondSeries storage s = series[maturities[i]];
            if (s.maturityLevel == 0 || s.resolved) continue;

            if (
                currLevel >= s.saleStartLevel &&
                currLevel < s.maturityLevel &&
                s.jackpotsRun < JACKPOT_DAYS &&
                s.lastJackpotLevel != currLevel
            ) {
                _runJackpotsForDay(s, rollingEntropy, currLevel);
                rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, s.jackpotsRun)));
            }

            if (currLevel >= s.maturityLevel && !s.resolved) {
                if (_isFunded(s) && !backlogPending) {
                    bool resolved = _resolveSeries(s, rollingEntropy);
                    if (resolved) {
                        rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "resolve")));
                    } else {
                        backlogPending = true;
                    }
                } else {
                    backlogPending = true; // enforce oldest-first resolution
                }
            }
        }

        _sweepExcessToVault();
    }

    /// @notice Burn DGNS0 (levels ending in 0) to enter the active jackpot for that digit.
    function burnDGNS0(uint256 amount) external {
        _burnForDigit(false, amount);
    }

    /// @notice Burn DGNS5 (levels ending in 5) to enter the active jackpot for that digit.
    function burnDGNS5(uint256 amount) external {
        _burnForDigit(true, amount);
    }

    /// @notice Claim Decimator share for a resolved bond series.
    function claim(uint24 maturityLevel) external {
        BondSeries storage s = series[maturityLevel];
        if (!s.resolved) revert SaleClosed(); // Reusing SaleClosed or similar "NotReady" error

        uint256 price = s.decSharePrice;
        if (price == 0) return;

        uint8 lane = s.winningLane;
        uint256 burned = s.lanes[lane].burnedAmount[msg.sender];
        if (burned == 0) return;

        s.lanes[lane].burnedAmount[msg.sender] = 0;
        uint256 payout = (burned * price) / 1e18;

        if (s.unclaimedBudget >= payout) {
            s.unclaimedBudget -= payout;
        } else {
            s.unclaimedBudget = 0;
        }

        if (!_creditPayout(msg.sender, payout)) {
            // If payout fails, revert state (though _creditPayout mostly handles failure by returning false)
            // Here we just revert to allow retry later if it was a transient failure
            revert BankCallFailed();
        }
    }

    function _burnForDigit(bool isFive, uint256 amount) private {
        if (amount == 0) revert InsufficientScore();

        uint24 currLevel = _currentLevel();
        uint24 targetMat = _baseMaturityForDigit(isFive);
        (BondSeries storage target, uint24 resolvedTargetMat) = _nextActiveSeries(targetMat, currLevel);
        if (target.resolved) revert AlreadyResolved();

        // Burn from the shared DGNS0/DGNS5 token.
        _ensureDGNSToken(isFive).burn(msg.sender, amount);

        (uint8 lane, bool boosted) = _registerBurn(target, resolvedTargetMat, amount, currLevel);
        emit BondBurned(msg.sender, resolvedTargetMat, lane, amount, boosted);
    }

    function _nextActiveSeries(
        uint24 maturityLevel,
        uint24 currLevel
    ) private returns (BondSeries storage target, uint24 targetMaturity) {
        targetMaturity = maturityLevel;
        target = _getOrCreateSeries(targetMaturity);
        // Once a maturity has arrived or been resolved, redirect new burns to the next (+10) maturity.
        while (currLevel >= targetMaturity || target.resolved) {
            targetMaturity += 10;
            target = _getOrCreateSeries(targetMaturity);
        }
    }

    function _baseMaturityForDigit(bool isFive) private view returns (uint24 maturityLevel) {
        maturityLevel = _activeMaturity();
        if (isFive) {
            if (maturityLevel % 10 == 0) {
                maturityLevel += 5;
            }
        } else {
            if (maturityLevel % 10 == 5) {
                maturityLevel += 5;
            }
        }
    }

    function _registerBurn(
        BondSeries storage s,
        uint24 maturityLevel,
        uint256 amount,
        uint24 currLevel
    ) private returns (uint8 lane, bool boosted) {
        // Deterministic lane assignment based on maturity level and player address (laneHint ignored).
        lane = uint8(uint256(keccak256(abi.encodePacked(maturityLevel, msg.sender))) & 1);

        s.lanes[lane].entries.push(LaneEntry({player: msg.sender, amount: amount}));
        s.lanes[lane].total += amount;
        s.lanes[lane].burnedAmount[msg.sender] += amount;
        s.lanes[lane].cumulative.push(s.lanes[lane].total);

        // While DGNS is still being minted for this series, count burns toward mint jackpot score as well.
        if (currLevel != 0 && currLevel < s.maturityLevel && s.jackpotsRun < 5 && s.mintedBudget < s.payoutBudget) {
            _recordJackpotScore(s, msg.sender, amount);
            boosted = true;
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function seriesToken(uint24 maturityLevel) external view returns (address) {
        return address(series[maturityLevel].token);
    }

    function payoutBudget(uint24 maturityLevel) external view returns (uint256) {
        return series[maturityLevel].payoutBudget;
    }

    /// @notice Required cover across all maturities up to the next active maturity.
    function requiredCoverNext() external view returns (uint256 required) {
        uint24 targetMat = _activeMaturity();
        BondSeries storage target = series[targetMat];
        (required, ) = _requiredCoverTotals(target, _currentLevel());
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _wire(WireConfig memory cfg) private {
        if (cfg.game != address(0)) {
            _setGame(cfg.game);
        }
        if (cfg.vault != address(0)) {
            _setVault(cfg.vault);
        }
        if (cfg.coin != address(0)) {
            _setCoin(cfg.coin);
        }
        // Only touch VRF when any field is provided; _setVrf enforces non-zero coordinator/keyHash.
        if (cfg.vrfCoordinator != address(0) || cfg.vrfSubId != 0 || cfg.vrfKeyHash != bytes32(0)) {
            _setVrf(cfg.vrfCoordinator, cfg.vrfSubId, cfg.vrfKeyHash);
        }
    }

    function _currentLevel() private view returns (uint24) {
        try game.level() returns (uint24 lvl) {
            return lvl;
        } catch {
            return 0;
        }
    }

    function _prepareEntropy(uint256 provided) private returns (uint256 entropy, bool requested) {
        if (provided != 0) return (provided, false);

        entropy = vrfPendingWord;
        if (entropy != 0) {
            vrfPendingWord = 0;
            return (entropy, false);
        }

        if (vrfRequestPending) return (0, true);
        if (vrfCoordinator == address(0) || vrfSubscriptionId == 0 || vrfKeyHash == bytes32(0)) return (0, false);

        try
            IVRFCoordinatorV2Like(vrfCoordinator).requestRandomWords(
                vrfKeyHash,
                vrfSubscriptionId,
                VRF_REQUEST_CONFIRMATIONS,
                VRF_CALLBACK_GAS_LIMIT,
                1
            )
        returns (uint256 reqId) {
            vrfRequestPending = true;
            vrfRequestId = reqId;
            return (0, true);
        } catch {
            return (0, false);
        }
    }

    function _obligationTotals(BondSeries storage s) private view returns (uint256 burned, uint256 outstanding) {
        burned = s.lanes[0].total + s.lanes[1].total;
        outstanding = 0; // ignore global shared supply; payouts are keyed to burned amount only
    }

    function _isFunded(BondSeries storage s) private view returns (bool) {
        uint24 currLevel = _currentLevel();
        uint256 available = _availableBank();
        (uint256 totalRequired, ) = _requiredCoverTotals(s, currLevel);
        return available >= totalRequired;
    }

    function _requiredCover(BondSeries storage s, uint24 currLevel) private view returns (uint256 required) {
        if (s.maturityLevel == 0) return 0;
        if (s.resolved) return s.unclaimedBudget;

        (uint256 burned, ) = _obligationTotals(s);
        if (currLevel >= s.maturityLevel) {
            required = burned; // maturity reached/past: cover actual burns only
        } else {
            // Upcoming maturity: cover all potential burns (full budget for that digit cycle).
            required = s.payoutBudget;
        }
    }

    function _requiredCoverTotals(
        BondSeries storage target,
        uint24 currLevel
    ) private view returns (uint256 total, uint256 current) {
        uint24 len = uint24(maturities.length);
        uint24 targetMat = target.maturityLevel;
        for (uint24 i = 0; i < len; i++) {
            BondSeries storage iter = series[maturities[i]];
            uint256 req = _requiredCover(iter, currLevel);
            total += req;
            if (iter.maturityLevel == targetMat) {
                current = req;
            }
        }
    }

    function _availableBank() private view returns (uint256 available) {
        if (!gameOverStarted) {
            try IDegenerusGameBondBank(address(game)).bondAvailable() returns (uint256 avail) {
                return avail;
            } catch {
                return 0;
            }
        }
        return address(this).balance;
    }

    function _stEthBalance() private view returns (uint256 bal) {
        try IStETHLike(steth).balanceOf(address(this)) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _sweepExcessToVault() private {
        address v = vault;
        if (v == address(0)) return;
        if (!gameOverStarted) return;

        uint256 required;
        uint24 currLevel = _currentLevel();
        uint24 len = uint24(maturities.length);
        for (uint24 i = 0; i < len; i++) {
            BondSeries storage s = series[maturities[i]];
            required += _requiredCover(s, currLevel);
        }

        uint256 bal = address(this).balance;
        if (bal <= required) return;

        uint256 excess = bal - required;
        (bool ok, ) = payable(v).call{value: excess}("");
        ok; // best-effort sweep
    }

    function _createSeries(uint24 maturityLevel) private {
        BondSeries storage s = series[maturityLevel];
        s.maturityLevel = maturityLevel;
        s.saleStartLevel = maturityLevel > 10 ? maturityLevel - 10 : 0;

        uint256 budget = lastIssuanceRaise == 0 ? initialPayoutBudget : (lastIssuanceRaise * 120) / 100;
        s.payoutBudget = budget;

        // Only two ERC20s are ever used: DGNS0 (maturities ending in 0) and DGNS5 (ending in 5).
        s.token = maturityLevel % 10 == 5 ? _ensureDGNSToken(true) : _ensureDGNSToken(false);

        maturities.push(maturityLevel);
        emit BondSeriesCreated(maturityLevel, s.saleStartLevel, address(s.token), budget);
    }

    function _setGame(address game_) private {
        if (game_ == address(0)) return;
        address current = address(game);
        if (current != address(0)) revert AlreadySet();
        game = IDegenerusGameLevel(game_);
    }

    function _setVault(address vault_) private {
        if (vault_ == address(0)) return;
        address current = vault;
        if (current != address(0)) revert AlreadySet();
        vault = vault_;
    }

    function _setCoin(address coin_) private {
        if (coin_ == address(0)) return;
        address current = coin;
        if (current != address(0)) revert AlreadySet();
        coin = coin_;
    }

    function _setVrf(address coordinator_, uint256 subId, bytes32 keyHash_) private {
        if (coordinator_ == address(0) && keyHash_ == bytes32(0) && subId == 0) return;
        if (coordinator_ == address(0) || keyHash_ == bytes32(0) || subId == 0) revert Unauthorized();

        address currentCoord = vrfCoordinator;
        bytes32 currentKey = vrfKeyHash;
        uint256 currentSub = vrfSubscriptionId;

        // Initial wiring when unset.
        if (currentCoord == address(0)) {
            vrfCoordinator = coordinator_;
            vrfSubscriptionId = subId;
            vrfKeyHash = keyHash_;
            return;
        }

        // No-op if unchanged.
        if (coordinator_ == currentCoord && keyHash_ == currentKey && subId == currentSub) {
            return;
        }

        if (!vrfRecoveryArmed) revert VrfLocked();

        vrfCoordinator = coordinator_;
        vrfSubscriptionId = subId;
        vrfKeyHash = keyHash_;
        vrfRecoveryArmed = false;
    }

    function _getOrCreateSeries(uint24 maturityLevel) private returns (BondSeries storage s) {
        s = series[maturityLevel];
        if (s.maturityLevel == 0) {
            if (maturityLevel % 5 != 0 || maturityLevel < 5) revert InvalidMaturity();
            _createSeries(maturityLevel);
            s = series[maturityLevel];
        }
    }

    function _recordJackpotScore(BondSeries storage s, address player, uint256 score) private {
        if (player == address(0) || score == 0) return;
        uint256 newTotal = s.totalScore + score;
        s.totalScore = newTotal;
        s.jackpotParticipants.push(player);
        s.jackpotCumulative.push(newTotal);
    }

    function _runJackpotsForDay(BondSeries storage s, uint256 rngWord, uint24 currLevel) private {
        if (s.payoutBudget == 0 || s.mintedBudget >= s.payoutBudget) return;

        uint256 pct = _emissionPct(s.jackpotsRun);
        if (pct == 0) return;

        uint256 targetTotal = (s.payoutBudget * pct) / 100;
        uint256 remainingBudget = s.payoutBudget - s.mintedBudget;
        if (targetTotal > remainingBudget) {
            targetTotal = remainingBudget;
        }

        uint256 primaryMint = targetTotal;

        if (primaryMint != 0 && s.totalScore != 0) {
            _runMintJackpot(s, rngWord, primaryMint);
            s.mintedBudget += primaryMint;
            emit BondJackpot(s.maturityLevel, s.jackpotsRun, primaryMint, rngWord);
        }

        s.jackpotsRun += 1;
        s.lastJackpotLevel = currLevel;
    }

    function _emissionPct(uint8 run) private pure returns (uint256) {
        if (run == 0) return 5;
        if (run == 1) return 5;
        if (run == 2) return 10;
        if (run == 3) return 10;
        if (run == 4) return 70;
        return 0;
    }

    function _runMintJackpot(BondSeries storage s, uint256 rngWord, uint256 toMint) private {
        uint256 remaining = toMint;
        uint256 first = (toMint * TOP_PCT_1) / 100;
        uint256 second = (toMint * TOP_PCT_2) / 100;
        uint256 third = (toMint * TOP_PCT_3) / 100;
        uint256 fourth = (toMint * TOP_PCT_4) / 100;
        uint256 perOther = (toMint - first - second - third - fourth) / 96;

        uint256 entropy = rngWord;

        address w1 = _weightedPick(s, entropy);
        s.token.mint(w1, first);
        _emitJackpotPayout(s.maturityLevel, w1, first, 1);
        remaining -= first;

        entropy = uint256(keccak256(abi.encode(entropy, 1)));
        address w2 = _weightedPick(s, entropy);
        s.token.mint(w2, second);
        _emitJackpotPayout(s.maturityLevel, w2, second, 2);
        remaining -= second;

        entropy = uint256(keccak256(abi.encode(entropy, 2)));
        address w3 = _weightedPick(s, entropy);
        s.token.mint(w3, third);
        _emitJackpotPayout(s.maturityLevel, w3, third, 3);
        remaining -= third;

        entropy = uint256(keccak256(abi.encode(entropy, 3)));
        address w4 = _weightedPick(s, entropy);
        s.token.mint(w4, fourth);
        _emitJackpotPayout(s.maturityLevel, w4, fourth, 4);
        remaining -= fourth;

        for (uint256 i = 4; i < JACKPOT_SPOTS; ) {
            entropy = uint256(keccak256(abi.encode(entropy, i)));
            address winner = _weightedPick(s, entropy);
            uint256 amount = (i == JACKPOT_SPOTS - 1) ? remaining : perOther;
            s.token.mint(winner, amount);
            _emitJackpotPayout(s.maturityLevel, winner, amount, uint8(i + 1));
            remaining -= amount;
            unchecked {
                ++i;
            }
        }
    }

    function _resolveSeriesGameOver(
        BondSeries storage s,
        uint256 rngWord,
        uint256 payout
    ) private returns (uint256 paid) {
        if (payout == 0) return 0;
        uint8 lane = uint8(rngWord & 1);
        if (s.lanes[lane].total == 0 && s.lanes[1 - lane].total != 0) {
            lane = 1 - lane;
        }
        if (s.lanes[lane].total == 0) return 0;

        Lane storage chosen = s.lanes[lane];
        uint256 decPool = payout / 2;
        uint256 drawPool = payout - decPool;

        // Decimator slice: proportional to burned amount (score).
        s.winningLane = lane;
        if (chosen.total > 0) {
            s.decSharePrice = (decPool * 1e18) / chosen.total;
            s.unclaimedBudget = decPool;
            paid += decPool;
        }

        // Ticketed draws on the remaining pool: 20%, 10%, 5%, 5%, 1% x10.
        if (drawPool != 0) {
            uint256 base = drawPool;
            uint256 first = (base * 20) / 100;
            uint256 second = (base * 10) / 100;
            uint256 third = (base * 5) / 100;
            uint256 fourth = (base * 5) / 100;
            uint256 ones = base / 100; // 1%

            uint256[14] memory buckets;
            buckets[0] = first;
            buckets[1] = second;
            buckets[2] = third;
            buckets[3] = fourth;
            for (uint8 j = 4; j < 14; j++) {
                buckets[j] = ones;
            }

            uint256 localEntropy = rngWord;
            for (uint8 k = 0; k < 14; ) {
                uint256 prize = buckets[k];
                unchecked {
                    ++k;
                }
                if (prize == 0) continue;
                localEntropy = uint256(keccak256(abi.encode(localEntropy, k, lane)));
                address winner = _weightedLanePick(chosen, localEntropy);
                if (winner == address(0)) continue;
                paid += prize;
                if (!_creditPayout(winner, prize)) {
                    paid -= prize;
                }
            }
        }
    }

    function _resolveSeries(BondSeries storage s, uint256 rngWord) private returns (bool resolved) {
        if (s.resolved) return true;
        uint24 currLevel = _currentLevel();
        (uint256 burned, ) = _obligationTotals(s);
        uint256 payoutCap = s.payoutBudget;
        uint256 available = _availableBank();
        (uint256 totalRequired, uint256 currentRequired) = _requiredCoverTotals(s, currLevel);
        if (available < totalRequired) return false;

        uint256 otherRequired = totalRequired - currentRequired;
        uint256 maxSpend = available - otherRequired;
        uint256 payout = payoutCap > maxSpend ? maxSpend : payoutCap;

        if (burned == 0) {
            s.resolved = true;
            lastIssuanceRaise = s.raised;
            emit BondSeriesResolved(s.maturityLevel, 0, 0, 0);
            return true;
        }
        if (payout < burned) return false;

        uint256 distributable = burned;

        uint8 lane = uint8(rngWord & 1);
        if (s.lanes[lane].total == 0 && s.lanes[1 - lane].total != 0) {
            lane = 1 - lane;
        }
        if (s.lanes[lane].total == 0) return false;

        Lane storage chosen = s.lanes[lane];
        uint256 paid;
        if (distributable != 0) {
            uint256 decPool = distributable / 2;
            uint256 drawPool = distributable - decPool;

            // Decimator slice: proportional to burned amount (score).
            // Converted to Pull/Claim pattern to avoid O(N) loop.
            s.winningLane = lane;
            if (chosen.total > 0) {
                s.decSharePrice = (decPool * 1e18) / chosen.total;
                s.unclaimedBudget = decPool;
            }

            // Ticketed draws on the remaining pool: 20%, 10%, 5%, 5%, 1% x10.
            if (drawPool != 0) {
                uint256 base = drawPool;
                uint256 first = (base * 20) / 100;
                uint256 second = (base * 10) / 100;
                uint256 third = (base * 5) / 100;
                uint256 fourth = (base * 5) / 100;
                uint256 ones = base / 100; // 1%

                uint256[14] memory buckets;
                buckets[0] = first;
                buckets[1] = second;
                buckets[2] = third;
                buckets[3] = fourth;
                for (uint8 j = 4; j < 14; j++) {
                    buckets[j] = ones;
                }

                uint256 localEntropy = rngWord;
                for (uint8 k = 0; k < 14; ) {
                    uint256 prize = buckets[k];
                    unchecked {
                        ++k;
                    }
                    if (prize == 0) continue;
                    localEntropy = uint256(keccak256(abi.encode(localEntropy, k, lane)));
                    address winner = _weightedLanePick(chosen, localEntropy);
                    if (winner == address(0)) continue;
                    paid += prize;
                    if (!_creditPayout(winner, prize)) {
                        paid -= prize;
                    }
                }
            }
        }

        s.resolved = true;
        lastIssuanceRaise = s.raised;
        emit BondSeriesResolved(s.maturityLevel, lane, paid, 0);
        return true;
    }

    function _weightedLanePick(Lane storage lane, uint256 entropy) private view returns (address) {
        uint256 total = lane.total;
        if (total == 0) return address(0);
        uint256 len = lane.cumulative.length;
        if (len == 0) return address(0);
        uint256 target = entropy % total;
        uint256 idx = _upperBound(lane.cumulative, target);
        if (idx >= len) return lane.entries[len - 1].player;
        return lane.entries[idx].player;
    }

    function _creditPayout(address player, uint256 amount) private returns (bool) {
        if (amount == 0) return true;
        if (!gameOverStarted) {
            try IDegenerusGameBondBank(address(game)).bondCreditToClaimable(player, amount) {
                return true;
            } catch {
                return false;
            }
        }
        uint256 remaining = amount;
        uint256 ethBal = address(this).balance;
        if (ethBal != 0) {
            uint256 toSend = ethBal >= remaining ? remaining : ethBal;
            (bool sent, ) = player.call{value: toSend}("");
            if (sent) {
                remaining -= toSend;
            }
        }
        if (remaining != 0) {
            address stEthToken = steth;
            try IStETHLike(stEthToken).transfer(player, remaining) returns (bool ok) {
                if (!ok) return false;
            } catch {
                return false;
            }
        }
        return true;
    }

    function _upperBound(uint256[] storage arr, uint256 target) private view returns (uint256 idx) {
        uint256 low;
        uint256 high = arr.length;
        while (low < high) {
            uint256 mid = (low + high) >> 1;
            if (arr[mid] > target) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low;
    }

    function _weightedPick(BondSeries storage s, uint256 entropy) private view returns (address) {
        uint256 total = s.totalScore;
        if (total == 0) return address(0);
        uint256 len = s.jackpotCumulative.length;
        if (len == 0) return address(0);
        uint256 target = entropy % total;
        uint256 idx = _upperBound(s.jackpotCumulative, target);
        if (idx >= len) return s.jackpotParticipants[len - 1];
        return s.jackpotParticipants[idx];
    }

    function _emitJackpotPayout(uint24 maturityLevel, address player, uint256 amount, uint8 placement) private {
        emit BondJackpotPayout(maturityLevel, player, amount, placement);
    }

    function _ensureDGNSToken(bool isFive) private returns (BondToken token) {
        if (isFive) {
            token = tokenDGNS5;
            if (address(token) == address(0)) {
                token = new BondToken("Degenerus Bond DGNS5", "DGNS5", address(this), 5);
                tokenDGNS5 = token;
            }
        } else {
            token = tokenDGNS0;
            if (address(token) == address(0)) {
                token = new BondToken("Degenerus Bond DGNS0", "DGNS0", address(this), 0);
                tokenDGNS0 = token;
            }
        }
    }

    /// @notice VRF callback entrypoint.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != vrfCoordinator) revert Unauthorized();
        if (!vrfRequestPending || requestId != vrfRequestId) return;
        if (randomWords.length == 0) return;
        vrfRequestPending = false;
        vrfPendingWord = randomWords[0];
    }
}
