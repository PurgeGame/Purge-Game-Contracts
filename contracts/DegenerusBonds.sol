// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal view into the core game to read the current level.
interface IDegenerusGameLevel {
    function level() external view returns (uint24);
    function ethMintStreakCount(address player) external view returns (uint24);
}

/// @notice Minimal view into the game for bond banking (ETH pooling + claim credit).
interface IDegenerusGameBondBank is IDegenerusGameLevel {
    function bondDeposit(bool trackPool) external payable;
    function bondCreditToClaimable(address player, uint256 amount) external;
    function bondCreditToClaimableBatch(address[] calldata players, uint256[] calldata amounts) external;
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

interface ICoinAffiliateLike is ICoinLike {
    function affiliateProgram() external view returns (address);
}

interface IAffiliatePresaleShutdown {
    function shutdownPresale() external;
}

interface IDegenerusQuestView {
    function playerQuestStates(
        address player
    )
        external
        view
        returns (uint32 streak, uint32 lastCompletedDay, uint128[2] memory progress, bool[2] memory completed);
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
    uint24 private immutable maturityLevel;
    address private immutable minter;

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
 *         - Payout budget = last issuance raise * growthBps (default 1.5x), seeded by presale raise for the first round.
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
    error MinimumDeposit();
    error NotExpired();
    error VrfLocked();
    error NotReady();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event BondSeriesCreated(uint24 indexed maturityLevel, uint24 saleStartLevel, address token, uint256 payoutBudget);
    event BondDeposit(address indexed player, uint24 indexed maturityLevel, uint256 amount, uint256 scoreAwarded);
    event BondJackpot(uint24 indexed maturityLevel, uint8 indexed dayIndex, uint256 mintedAmount, uint256 rngWord);
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
    // Default work budget for maintenance; each unit roughly covers one series tick or archive step.
    uint32 private constant BOND_MAINT_WORK_CAP = 3;
    uint8 private constant JACKPOT_SPOTS = 100;
    uint8 private constant JACKPOT_DAYS = 255; // effectively unlimited; guarded by payoutBudget remaining
    uint8 private constant TOP_PCT_1 = 20;
    uint8 private constant TOP_PCT_2 = 10;
    uint8 private constant TOP_PCT_3 = 5;
    uint8 private constant TOP_PCT_4 = 5;
    uint256 private constant MIN_DEPOSIT = 0.01 ether;
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
        address questModule;
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
    uint24 private activeMaturityIndex;
    uint256 private resolvedUnclaimedTotal;
    IDegenerusGameLevel private game;
    address private immutable admin;
    uint256 private lastIssuanceRaise;
    address private vrfCoordinator;
    bytes32 private vrfKeyHash;
    uint256 private vrfSubscriptionId;
    uint256 private vrfRequestId;
    uint256 private vrfPendingWord;
    bool private vrfRequestPending;
    bool private firstSeriesBudgetFinalized;
    bool public gameOverStarted; // true after game signals shutdown; disables new deposits and bank pushes
    uint48 public gameOverTimestamp; // timestamp when game over was triggered
    bool public gameOverEntropyAttempted; // true after gameOver() attempts to fetch entropy (request or failure)
    bool public externalPurchasesEnabled = true; // owner toggle for non-game purchases
    bool public gamePurchasesEnabled = true; // owner toggle for game-routed purchases
    address private vault;
    address private coin;
    IDegenerusQuestView private questModule;
    BondToken private tokenDGNS0;
    BondToken private tokenDGNS5;
    address private immutable steth;
    bool private vrfRecoveryArmed;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address admin_, address steth_) {
        if (admin_ == address(0)) revert Unauthorized();
        if (steth_ == address(0)) revert Unauthorized();
        admin = admin_;
        steth = steth_;

        // Predeploy the two shared bond tokens (DGNS0 for maturities ending in 0, DGNS5 for ending in 5).
        tokenDGNS0 = new BondToken("Degenerus Bond DGNS0", "DGNS0", address(this), 0);
        tokenDGNS5 = new BondToken("Degenerus Bond DGNS5", "DGNS5", address(this), 5);
    }

    modifier onlyGame() {
        if (msg.sender != address(game)) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------------
    // External write API
    // ---------------------------------------------------------------------

    /// @notice Wire bonds like other modules: [game, vault, coin, vrfCoordinator, questModule] + subId/keyHash (partial allowed).
    function wire(address[] calldata addresses, uint256 vrfSubId, bytes32 vrfKeyHash_) external {
        if (msg.sender != admin) revert Unauthorized();
        _wire(
            WireConfig({
                game: addresses.length > 0 ? addresses[0] : address(0),
                vault: addresses.length > 1 ? addresses[1] : address(0),
                coin: addresses.length > 2 ? addresses[2] : address(0),
                vrfCoordinator: addresses.length > 3 ? addresses[3] : address(0),
                questModule: addresses.length > 4 ? addresses[4] : address(0),
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

    /// @notice Close presale and lock the first maturity (level 10) budget to presale raise * growth factor.
    /// @dev Calls affiliate.shutdownPresale() (best effort) and finalizes once; reverts if no presale raise.
    function shutdownPresale() external {
        if (msg.sender != admin) revert Unauthorized();
        if (firstSeriesBudgetFinalized) revert AlreadySet();

        // Attempt to close presale on the affiliate contract.
        address coinAddr = coin;
        if (coinAddr == address(0)) revert NotReady();
        address affiliate = ICoinAffiliateLike(coinAddr).affiliateProgram();
        if (affiliate != address(0)) {
            try IAffiliatePresaleShutdown(affiliate).shutdownPresale() {} catch {}
        }

        BondSeries storage s = _getOrCreateSeries(10);
        uint256 raised = s.raised;
        if (raised == 0) revert NotReady();

        uint256 target = _targetBudgetForSeries(s);
        if (target > s.payoutBudget) {
            s.payoutBudget = target;
        }
        firstSeriesBudgetFinalized = true;
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
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable onlyGame {
        address vaultAddr = vault;
        address stEthToken = steth;
        uint256 vaultShare = (coinAmount * 60) / 100;
        uint256 jackpotShare = coinAmount - vaultShare;
        bool shutdown = gameOverStarted;
        if (stEthAmount != 0) {
            try IStETHLike(stEthToken).transferFrom(msg.sender, address(this), stEthAmount) {} catch {}
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
        for (uint24 i = activeMaturityIndex; i < len; i++) {
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
        for (uint24 i = activeMaturityIndex; i < len; i++) {
            BondSeries storage s = series[maturities[i]];
            if (s.maturityLevel == 0 || s.resolved) continue;

            uint256 burned = s.lanes[0].total + s.lanes[1].total;
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
        for (uint24 j = activeMaturityIndex; j < len; j++) {
            BondSeries storage rem = series[maturities[j]];
            if (rem.maturityLevel == 0 || rem.resolved) continue;
            rem.resolved = true;
        }

        uint256 remainingEth = address(this).balance;
        uint256 remainingStEth = _stEthBalance();
        uint256 spent = (initialEth + initialStEth) - (remainingEth + remainingStEth);

        uint256 totalReserved = resolvedUnclaimedTotal;
        for (uint24 k = activeMaturityIndex; k < len; k++) {
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
        if (!fromGame && amount < MIN_DEPOSIT) revert MinimumDeposit();
        if (gameOverStarted) revert SaleClosed();
        if (fromGame) {
            if (!gamePurchasesEnabled) revert PurchasesDisabled();
        } else {
            if (!externalPurchasesEnabled) revert PurchasesDisabled();
        }

        uint24 maturityLevel = _activeMaturity();
        BondSeries storage s = _getOrCreateSeries(maturityLevel);

        // Split ETH: from game (30% vault, 50% bondPool, 20% rewardPool), external (50% vault, 30% bondPool, 20% rewardPool)
        uint256 vaultShare = (amount * (fromGame ? 30 : 50)) / 100;
        uint256 bondShare = (amount * (fromGame ? 50 : 30)) / 100;
        uint256 rewardShare = amount - vaultShare - bondShare; // remaining 20%

        address vaultAddr = vault;
        if (vaultAddr == address(0)) revert BankCallFailed();
        if (vaultShare != 0) {
            (bool sentVault, ) = payable(vaultAddr).call{value: vaultShare}("");
            if (!sentVault) revert BankCallFailed();
        }

        if (bondShare != 0) {
            IDegenerusGameBondBank(address(game)).bondDeposit{value: bondShare}(false);
        }

        if (rewardShare != 0) {
            (bool sentReward, ) = payable(address(game)).call{value: rewardShare}("");
            if (!sentReward) revert BankCallFailed();
        }

        scoreAwarded = _scoreWithMultiplier(beneficiary, amount);

        // Append new weight slice for jackpot selection (append-only cumulative for O(log N) sampling).
        _recordJackpotScore(s, beneficiary, scoreAwarded);
        s.raised += amount;
        // Ensure payout budget never trails total deposits for this maturity.
        if (s.payoutBudget < s.raised) {
            s.payoutBudget = s.raised;
        }

        emit BondDeposit(beneficiary, maturityLevel, amount, scoreAwarded);
    }

    function _activeMaturity() private view returns (uint24 maturityLevel) {
        uint24 currLevel = _currentLevel();
        if (currLevel < 10) {
            return 10; // treat presale / unwired play as level 0; first maturity is level 10
        }
        // choose the next multiple of 5 ahead of the current level
        maturityLevel = ((currLevel / 5) + 1) * 5;
    }

    /// @notice Run bond maintenance for the current level (create series, run jackpots, resolve funded maturities).
    /// @param rngWord Entropy used for jackpots and lane selection.
    /// @param workCapOverride Optional work budget override; 0 uses the built-in default.
    ///        Budget units are coarse “work ticks” (series iterations/archive steps), not gas.
    /// @return worked True if any maintenance action was performed this call.
    function bondMaintenance(uint256 rngWord, uint32 workCapOverride) external onlyGame returns (bool worked) {
        uint32 workCap = workCapOverride == 0 ? BOND_MAINT_WORK_CAP : workCapOverride;
        uint32 workUsed;
        uint24 currLevel = _currentLevel();

        // Ensure the active series exists and precreate the next maturity when we are 10 levels out.
        uint24 nextMat = currLevel < 10 ? 10 : ((currLevel / 5) + 1) * 5;
        _getOrCreateSeries(nextMat);
        unchecked {
            uint24 ahead = currLevel + 10;
            if (ahead >= 5 && ahead % 5 == 0) {
                _getOrCreateSeries(ahead);
            }
        }
        uint256 rollingEntropy = rngWord;
        bool backlogPending;
        // Run jackpots and resolve matured series.
        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; i++) {
            if (_bondMaintWorkExceeded(workUsed, workCap)) return worked;

            BondSeries storage s = series[maturities[i]];
            if (s.maturityLevel == 0 || s.resolved) continue;
            bool consumedWork;

            if (
                currLevel >= s.saleStartLevel &&
                currLevel < s.maturityLevel &&
                s.jackpotsRun < _maxEmissionRuns(s.maturityLevel) &&
                s.lastJackpotLevel != currLevel
            ) {
                _runJackpotsForDay(s, rollingEntropy, currLevel);
                rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, s.jackpotsRun)));
                consumedWork = true;
            }

            if (currLevel >= s.maturityLevel && !s.resolved) {
                if (_isFunded(s) && !backlogPending) {
                    bool wasResolved = s.resolved;
                    bool resolved = _resolveSeries(s, rollingEntropy);
                    if (resolved) {
                        rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "resolve")));
                        if (!wasResolved && s.resolved) {
                            worked = true; // only count work when we resolve a new maturity
                        }
                    } else {
                        backlogPending = true;
                    }
                } else {
                    backlogPending = true; // enforce oldest-first resolution
                }
                consumedWork = true;
            }

            if (consumedWork) {
                unchecked {
                    ++workUsed;
                }
            }
        }

        // Archive fully resolved series to save gas on future iterations
        while (activeMaturityIndex < len) {
            if (_bondMaintWorkExceeded(workUsed, workCap)) return worked;

            BondSeries storage s = series[maturities[activeMaturityIndex]];
            if (s.resolved) {
                resolvedUnclaimedTotal += s.unclaimedBudget;
                activeMaturityIndex++;
                unchecked {
                    ++workUsed;
                }
            } else {
                break;
            }
        }

        if (_bondMaintWorkExceeded(workUsed, workCap)) return worked;

        // Sweep excess if possible; does not affect work flag.
        _sweepExcessToVault();
    }

    function _bondMaintWorkExceeded(uint32 used, uint32 cap) private pure returns (bool exceeded) {
        return used >= cap;
    }

    /// @notice Burn DGNS for a digit lane (false = DGNS0, true = DGNS5) to enter the active jackpot.
    function burnDGNS(bool isFive, uint256 amount) external {
        if (amount == 0) revert InsufficientScore();

        uint24 currLevel = _currentLevel();
        uint24 targetMat = _baseMaturityForDigit(isFive);
        (BondSeries storage target, uint24 resolvedTargetMat) = _nextActiveSeries(targetMat, currLevel);
        // Burn from the predeployed shared DGNS0/DGNS5 token.
        (isFive ? tokenDGNS5 : tokenDGNS0).burn(msg.sender, amount);

        (uint8 lane, bool boosted) = _registerBurn(target, resolvedTargetMat, amount, currLevel);
        emit BondBurned(msg.sender, resolvedTargetMat, lane, amount, boosted);
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

        uint256 budgetBefore = s.unclaimedBudget;
        if (s.unclaimedBudget >= payout) {
            s.unclaimedBudget -= payout;
        } else {
            s.unclaimedBudget = 0;
        }

        uint256 delta = budgetBefore - s.unclaimedBudget;
        if (delta != 0) {
            // If this series is archived (skipped in main loops), update the global tracker.
            bool isArchived = false;
            uint24 head = activeMaturityIndex;
            if (head > 0) {
                if (head == maturities.length) {
                    isArchived = true;
                } else if (maturityLevel < series[maturities[head]].maturityLevel) {
                    isArchived = true;
                }
            }
            if (isArchived) {
                resolvedUnclaimedTotal -= delta;
            }
        }

        if (!_creditPayout(msg.sender, payout)) {
            // If payout fails, revert state (though _creditPayout mostly handles failure by returning false)
            // Here we just revert to allow retry later if it was a transient failure
            revert BankCallFailed();
        }
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
            uint256 boostedScore = _scoreWithMultiplier(msg.sender, amount);
            _recordJackpotScore(s, msg.sender, boostedScore);
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
        (required, ) = _requiredCoverTotals(target, _currentLevel(), 0);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _wire(WireConfig memory cfg) private {
        _setGame(cfg.game);
        _setVault(cfg.vault);
        _setCoin(cfg.coin);
        _setQuestModule(cfg.questModule);
        _setVrf(cfg.vrfCoordinator, cfg.vrfSubId, cfg.vrfKeyHash);
    }

    function _currentLevel() private view returns (uint24) {
        return game.level();
    }

    function _scoreMultiplierBps(address player) private view returns (uint256) {
        uint256 mintStreak = uint256(game.ethMintStreakCount(player));
        if (mintStreak > 25) {
            mintStreak = 25;
        }

        uint256 questStreak;
        IDegenerusQuestView quest = questModule;
        if (address(quest) != address(0)) {
            (uint32 streak, , , ) = quest.playerQuestStates(player);
            questStreak = streak;
        }
        if (questStreak > 50) {
            questStreak = 50;
        }

        uint256 bonusBps = (mintStreak * 100) + (questStreak * 50); // 1% per mint streak, 0.5% per quest streak
        return 10000 + bonusBps; // base 1.0x (10000 bps) plus bonuses up to +50%
    }

    function _scoreWithMultiplier(address player, uint256 baseScore) private view returns (uint256) {
        uint256 multBps = _scoreMultiplierBps(player);
        return (baseScore * multBps) / 10000;
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

    function _isFunded(BondSeries storage s) private view returns (bool) {
        uint24 currLevel = _currentLevel();
        uint256 available = _availableBank();
        (uint256 totalRequired, ) = _requiredCoverTotals(s, currLevel, available);
        return available >= totalRequired;
    }

    function _requiredCover(BondSeries storage s, uint24 currLevel) private view returns (uint256 required) {
        if (s.maturityLevel == 0) return 0;
        if (s.resolved) return s.unclaimedBudget;

        uint256 burned = s.lanes[0].total + s.lanes[1].total;
        if (currLevel >= s.maturityLevel) {
            required = burned; // maturity reached/past: cover actual burns only
        } else {
            // Upcoming maturity: cover all potential burns (full budget for that digit cycle).
            required = s.payoutBudget;
        }
    }

    function _requiredCoverTotals(
        BondSeries storage target,
        uint24 currLevel,
        uint256 stopAt
    ) private view returns (uint256 total, uint256 current) {
        total = resolvedUnclaimedTotal;
        uint24 len = uint24(maturities.length);
        uint24 targetMat = target.maturityLevel;
        for (uint24 i = activeMaturityIndex; i < len; i++) {
            BondSeries storage iter = series[maturities[i]];
            uint256 req = _requiredCover(iter, currLevel);
            total += req;
            if (iter.maturityLevel == targetMat) {
                current = req;
            }
            if (stopAt != 0 && total > stopAt) {
                // Signal that we already exceed the available cover; caller will bail early.
                uint256 capped = stopAt == type(uint256).max ? stopAt : stopAt + 1;
                return (capped, current);
            }
        }
    }

    function _availableBank() private view returns (uint256 available) {
        if (!gameOverStarted) {
            return IDegenerusGameBondBank(address(game)).bondAvailable();
        }
        return address(this).balance + _stEthBalance();
    }

    function _stEthBalance() private view returns (uint256 bal) {
        try IStETHLike(steth).balanceOf(address(this)) returns (uint256 b) {
            return b;
        } catch {
            return 0;
        }
    }

    function _sweepExcessToVault() private returns (bool swept) {
        address v = vault;
        if (v == address(0)) return false;
        if (!gameOverStarted) return false;

        uint256 required = resolvedUnclaimedTotal;
        uint256 bal = address(this).balance;
        if (bal <= required) return false;
        uint24 currLevel = _currentLevel();
        uint24 len = uint24(maturities.length);
        for (uint24 i = activeMaturityIndex; i < len; i++) {
            BondSeries storage s = series[maturities[i]];
            required += _requiredCover(s, currLevel);
            if (required >= bal) {
                return false;
            }
        }

        if (bal <= required) return false;

        uint256 excess = bal - required;
        (bool ok, ) = payable(v).call{value: excess}("");
        if (ok) {
            swept = true;
        }
    }

    function _createSeries(uint24 maturityLevel) private {
        BondSeries storage s = series[maturityLevel];
        s.maturityLevel = maturityLevel;
        s.saleStartLevel = maturityLevel > 10 ? maturityLevel - 10 : 0;

        // Seed budget from the last raise; the first series starts at 0 and grows with presale deposits.
        uint256 budget = lastIssuanceRaise;
        s.payoutBudget = budget;

        // Only two ERC20s are ever used: DGNS0 (maturities ending in 0) and DGNS5 (ending in 5).
        s.token = maturityLevel % 10 == 5 ? tokenDGNS5 : tokenDGNS0;

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

    function _setQuestModule(address questModule_) private {
        if (questModule_ == address(0)) return;
        address current = address(questModule);
        if (current != address(0)) revert AlreadySet();
        questModule = IDegenerusQuestView(questModule_);
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

        revert VrfLocked(); // Rewiring after initial set is disallowed; use admin emergency path.
    }

    function _getOrCreateSeries(uint24 maturityLevel) private returns (BondSeries storage s) {
        s = series[maturityLevel];
        if (s.maturityLevel == 0) {
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
        uint8 maxRuns = _maxEmissionRuns(s.maturityLevel);
        bool isFinalRun = (s.jackpotsRun + 1 == maxRuns);

        // For early runs, keep payout budget tracked to raised so remaining stays non-negative.
        // On the final run, compute the true growth-adjusted budget once and sweep the remainder.
        if (isFinalRun) {
            uint256 finalBudget = _targetBudgetForSeries(s);
            if (finalBudget > s.payoutBudget) {
                s.payoutBudget = finalBudget;
            }
        } else if (s.payoutBudget < s.raised) {
            s.payoutBudget = s.raised;
        }

        if (s.payoutBudget == 0 || s.mintedBudget >= s.payoutBudget) return;

        uint256 pct = _emissionPct(s.maturityLevel, s.jackpotsRun);
        if (pct == 0) return;

        uint256 remainingBudget = s.payoutBudget - s.mintedBudget;

        // Early runs mint against actual ETH raised; final run mints the remaining budget (growth-adjusted).
        uint256 baseForRun = isFinalRun ? s.payoutBudget : s.raised;
        uint256 targetTotal = isFinalRun ? remainingBudget : _min((baseForRun * pct) / 100, remainingBudget);

        uint256 primaryMint = targetTotal;

        if (primaryMint != 0 && s.totalScore != 0) {
            _runMintJackpot(s, rngWord, primaryMint);
            s.mintedBudget += primaryMint;
            emit BondJackpot(s.maturityLevel, s.jackpotsRun, primaryMint, rngWord);
        }

        s.jackpotsRun += 1;
        s.lastJackpotLevel = currLevel;
    }

    function _emissionPct(uint24 maturityLevel, uint8 run) private pure returns (uint256) {
        // Special-case the first series (maturity 10) to emit only four days; day 1 combines level0/level1 share.
        if (maturityLevel == 10) {
            if (run == 0) return 20;
            if (run == 1) return 10;
            if (run == 2) return 10;
            if (run == 3) return 60;
            return 0;
        }

        if (run == 0) return 10;
        if (run == 1) return 10;
        if (run == 2) return 10;
        if (run == 3) return 10;
        if (run == 4) return 60;
        return 0;
    }

    function _maxEmissionRuns(uint24 maturityLevel) private pure returns (uint8) {
        return maturityLevel == 10 ? 4 : 5;
    }

    // Piecewise sliding multiplier: 3x at 0.5x prior raise, 2x at 1x, 1x at 2x; clamped outside.
    function _growthMultiplierBps(uint256 raised) private view returns (uint256) {
        uint256 prev = lastIssuanceRaise;
        if (prev == 0 || raised == 0) return 20000; // default 2.0x when no prior raise data

        uint256 ratio = (raised * 1e18) / prev; // 1e18 == 1.0
        if (ratio <= 5e17) return 30000; // <=0.5x -> 3.0x
        if (ratio <= 1e18) {
            // Linear from 3.0x at 0.5 to 2.0x at 1.0: 4 - 2r
            return 40000 - (20000 * ratio) / 1e18;
        }
        if (ratio <= 2e18) {
            // Linear from 2.0x at 1.0 to 1.0x at 2.0: 3 - r
            return 20000 - (10000 * (ratio - 1e18)) / 1e18;
        }
        return 10000; // >=2x -> 1.0x
    }

    function _targetBudgetForSeries(BondSeries storage s) private view returns (uint256) {
        uint256 growthBps = _growthMultiplierBps(s.raised);
        uint256 target = (s.raised * growthBps) / 10000;
        if (target < s.raised) {
            target = s.raised;
        }
        return target;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _runMintJackpot(BondSeries storage s, uint256 rngWord, uint256 toMint) private {
        uint256 remaining = toMint;
        uint256 first = (toMint * TOP_PCT_1) / 100;
        uint256 second = (toMint * TOP_PCT_2) / 100;
        uint256 third = (toMint * TOP_PCT_3) / 100;
        uint256 fourth = (toMint * TOP_PCT_4) / 100;
        uint256 perOther = (toMint - first - second - third - fourth) / 96;

        uint256 entropy = rngWord;

        address[4] memory winners;
        uint256[4] memory amounts;

        address w1 = _weightedPick(s, entropy);
        s.token.mint(w1, first);
        winners[0] = w1;
        amounts[0] = first;
        remaining -= first;

        entropy = _nextEntropy(entropy, 1);
        address w2 = _weightedPick(s, entropy);
        s.token.mint(w2, second);
        winners[1] = w2;
        amounts[1] = second;
        remaining -= second;

        entropy = _nextEntropy(entropy, 2);
        address w3 = _weightedPick(s, entropy);
        s.token.mint(w3, third);
        winners[2] = w3;
        amounts[2] = third;
        remaining -= third;

        entropy = _nextEntropy(entropy, 3);
        address w4 = _weightedPick(s, entropy);
        s.token.mint(w4, fourth);
        winners[3] = w4;
        amounts[3] = fourth;
        remaining -= fourth;

        for (uint256 i = 4; i < JACKPOT_SPOTS; ) {
            entropy = _nextEntropy(entropy, i);
            address winner = _weightedPick(s, entropy);
            uint256 amount = (i == JACKPOT_SPOTS - 1) ? remaining : perOther;
            s.token.mint(winner, amount);
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
        uint256 burned = s.lanes[0].total + s.lanes[1].total;
        uint256 available = _availableBank();
        (uint256 totalRequired, uint256 currentRequired) = _requiredCoverTotals(s, currLevel, available);
        if (available < totalRequired) return false;

        uint256 otherRequired = totalRequired - currentRequired;
        uint256 maxSpend = available - otherRequired;
        uint256 payout = burned;
        if (payout > maxSpend) return false;

        if (burned == 0) {
            s.resolved = true;
            lastIssuanceRaise = s.raised;
            emit BondSeriesResolved(s.maturityLevel, 0, 0, 0);
            return true;
        }

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

                address[] memory payoutWinners;
                uint256[] memory payoutAmounts;
                uint256 payoutCount;
                bool liveGame = !gameOverStarted;
                if (liveGame) {
                    payoutWinners = new address[](14);
                    payoutAmounts = new uint256[](14);
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
                    if (liveGame) {
                        payoutWinners[payoutCount] = winner;
                        payoutAmounts[payoutCount] = prize;
                        unchecked {
                            ++payoutCount;
                        }
                    } else if (!_creditPayout(winner, prize)) {
                        paid -= prize;
                    }
                }

                if (liveGame && payoutCount != 0) {
                    _creditPayoutBatch(payoutWinners, payoutAmounts, payoutCount);
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
            IDegenerusGameBondBank(address(game)).bondCreditToClaimable(player, amount);
            return true;
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

    function _creditPayoutBatch(address[] memory winners, uint256[] memory amounts, uint256 count) private {
        if (count == 0) return;
        assembly {
            mstore(winners, count)
            mstore(amounts, count)
        }
        IDegenerusGameBondBank(address(game)).bondCreditToClaimableBatch(winners, amounts);
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

    function _nextEntropy(uint256 entropy, uint256 salt) private pure returns (uint256) {
        unchecked {
            entropy ^= entropy << 32;
            entropy ^= entropy >> 13;
            entropy ^= entropy << 7;
            return entropy ^ (salt * 0x9E3779B97F4A7C15);
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
