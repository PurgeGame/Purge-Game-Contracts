// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal view into the core game to read the current level.
interface IDegenerusGameLevel {
    function level() external view returns (uint24);
}

/// @notice Minimal view into the game for bond banking (ETH pooling + claim credit).
interface IDegenerusGameBondBank is IDegenerusGameLevel {
    function bondDeposit() external payable;
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
    error NoBurnedEntries();
    error NextSeriesUnavailable();
    error AlreadyResolved();
    error NotResolved();
    error InsufficientReserve();
    error BankCallFailed();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event BondSeriesCreated(uint24 indexed maturityLevel, uint24 saleStartLevel, address token, uint256 payoutBudget);
    event BondDeposit(address indexed player, uint24 indexed maturityLevel, uint256 amount, uint256 scoreAwarded);
    event BondJackpot(uint24 indexed maturityLevel, uint8 indexed dayIndex, uint256 mintedAmount, uint256 rngWord);
    event BondJackpotPayout(uint24 indexed maturityLevel, address indexed player, uint256 amount, uint8 placement);
    event BondBurned(address indexed player, uint24 indexed maturityLevel, uint8 lane, uint256 amount, bool boostedScore);
    event BondSeriesResolved(uint24 indexed maturityLevel, uint8 winningLane, uint256 payoutEth, uint256 remainingToken);
    event BondRolled(address indexed player, uint24 indexed fromMaturity, uint24 indexed toMaturity, uint256 amount);
    event BondGameOver(uint256 poolSpent, uint24 partialMaturity);
    event BondCoinJackpot(address indexed player, uint256 amount, uint24 maturityLevel, uint8 lane);

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint8 private constant JACKPOT_SPOTS = 100;
    uint8 private constant JACKPOT_DAYS = 255; // effectively unlimited; guarded by payoutBudget remaining
    uint8 private constant TOP_PCT_1 = 20;
    uint8 private constant TOP_PCT_2 = 10;
    uint8 private constant TOP_PCT_3 = 5;
    uint8 private constant TOP_PCT_4 = 5;
    uint256 private constant ONE = 1e18;
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;

    // ---------------------------------------------------------------------
    // Data structures
    // ---------------------------------------------------------------------
    struct Participant {
        uint256 score;
        bool seen;
    }

    struct LaneEntry {
        address player;
        uint256 amount;
    }

    struct Lane {
        uint256 total;
        LaneEntry[] entries;
    }

    struct BondSeries {
        uint24 maturityLevel;
        uint24 saleStartLevel;
        uint256 payoutBudget;
        uint256 mintedBudget;
        uint256 raised;
        uint256 carryPot; // ETH carried in from previous series rollovers
        uint256 rolloverReserve; // ETH held back for unburned tokens at resolution
        uint8 jackpotsRun;
        uint24 lastJackpotLevel;
        uint256 totalScore;
        BondToken token;
        address[] participants;
        mapping(address => Participant) participant;
        Lane[2] lanes;
        bool resolved;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    mapping(uint24 => BondSeries) internal series;
    uint24[] internal maturities;
    IDegenerusGameLevel public immutable game;
    uint256 public lastIssuanceRaise;
    uint256 public initialPayoutBudget;
    address public immutable vrfAdmin; // usually the VRF sub owner
    address public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint256 public vrfSubscriptionId;
    uint256 public vrfRequestId;
    uint256 private vrfPendingWord;
    bool private vrfRequestPending;
    bool public bankedInGame = true; // true while funds live in the game contract’s bond pool
    address public vault;
    address public coin;
    uint256 private coinJackpotPot;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address game_, uint256 initialPayoutBudget_, address vrfAdmin_) {
        game = IDegenerusGameLevel(game_);
        initialPayoutBudget = initialPayoutBudget_;
        vrfAdmin = vrfAdmin_;
    }

    // ---------------------------------------------------------------------
    // External write API
    // ---------------------------------------------------------------------

    /// @notice One-time VRF wiring for the bond contract (called by the VRF admin/sub owner).
    function wireBondVrf(address coordinator_, uint256 subId, bytes32 keyHash_) external {
        if (msg.sender != vrfAdmin) revert Unauthorized();
        if (coordinator_ == address(0) || keyHash_ == bytes32(0)) revert Unauthorized();
        vrfCoordinator = coordinator_;
        vrfSubscriptionId = subId;
        vrfKeyHash = keyHash_;
    }

    /// @notice Set the vault to receive excess funds beyond global bond obligations.
    function setVault(address vault_) external {
        if (msg.sender != vrfAdmin && msg.sender != address(game)) revert Unauthorized();
        if (vault_ == address(0)) revert Unauthorized();
        vault = vault_;
    }

    /// @notice Set the coin token used for coin jackpots funded by the game.
    function setCoin(address coin_) external {
        if (msg.sender != vrfAdmin && msg.sender != address(game)) revert Unauthorized();
        if (coin_ == address(0)) revert Unauthorized();
        coin = coin_;
    }

    /// @notice Player deposit flow during an active sale window.
    function deposit(uint24 maturityLevel) external payable returns (uint256 scoreAwarded) {
        return _depositFor(msg.sender, msg.sender, maturityLevel, msg.value);
    }

    /// @notice Deposit on behalf of a player into the current active maturity (game compatibility shim).
    /// @dev Caller is expected to be the game when using credit on behalf of a player.
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded) {
        uint24 maturityLevel = _activeMaturity();
        return _depositFor(beneficiary, beneficiary, maturityLevel, msg.value);
    }

    /// @notice Funding shim used by the game to route yield/coin into bonds and run upkeep.
    function payBonds(
        uint256 coinAmount,
        uint256 stEthAmount,
        uint256 rngWord
    ) external payable {
        address vaultAddr = vault;
        uint256 vaultShare = (coinAmount * 60) / 100;
        uint256 jackpotShare = coinAmount - vaultShare;

        if (vaultAddr != address(0) && vaultShare != 0) {
            try IVaultLike(vaultAddr).deposit{value: 0}(vaultShare, 0) {} catch {}
        }

        // Pull stETH yield from the caller and convert via the vault; fallback to parking the stETH if conversion fails.
        if (stEthAmount != 0 && vaultAddr != address(0)) {
            address stEthToken = IVaultLike(vaultAddr).steth();
            if (stEthToken != address(0)) {
                bool pulled;
                try IStETHLike(stEthToken).transferFrom(msg.sender, address(this), stEthAmount) returns (bool ok) {
                    pulled = ok;
                } catch {}

                if (pulled) {
                    bool converted;
                    try IVaultLike(vaultAddr).swapWithBonds{value: 0}(true, stEthAmount) {
                        converted = true;
                    } catch {}
                    if (!converted) {
                        try IVaultLike(vaultAddr).deposit{value: 0}(0, stEthAmount) {
                            converted = true;
                        } catch {}
                    }
                    if (!converted) {
                        try IStETHLike(stEthToken).transfer(msg.sender, stEthAmount) {} catch {}
                    }
                }
            }
        }

        // While funds are banked inside the game, immediately push all ETH back into the game’s bond pool.
        if (bankedInGame) {
            uint256 bal = address(this).balance;
            if (bal != 0) {
                try IDegenerusGameBondBank(address(game)).bondDeposit{value: bal}() {} catch {
                    revert BankCallFailed();
                }
            }
        }

        uint256 pot = jackpotShare;
        if (coinJackpotPot != 0) {
            pot += coinJackpotPot;
            coinJackpotPot = 0;
        }
        if (pot != 0) {
            bool paid = _payCoinJackpot(pot, rngWord);
            if (!paid) {
                coinJackpotPot = pot; // carry forward if no eligible lane or transfer failed
            }
        }
    }

    /// @notice Run jackpots and resolution using the latest entropy.
    function resolveBonds(uint256 rngWord) external returns (bool worked) {
        bondMaintenance(rngWord);
        return true;
    }

    function purchaseGameBonds(
        address[] calldata recipients,
        uint256 /*quantity*/,
        uint256 /*basePerBondWei*/,
        bool /*stake*/
    ) external pure returns (uint256 startTokenId) {
        if (recipients.length != 0) {
            // No tokens minted; return a dummy start id.
            return 1;
        }
        return 0;
    }

    function resolvePendingBonds(uint256 /*maxBonds*/) external {
        bondMaintenance(0);
    }

    // ---------------------------------------------------------------------
    // Internals (coin jackpot)
    // ---------------------------------------------------------------------

    function _payCoinJackpot(uint256 amount, uint256 rngWord) private returns (bool paid) {
        if (amount == 0 || rngWord == 0) return false;
        address coinAddr = coin;
        if (coinAddr == address(0)) return false;

        uint24 currLevel = _currentLevel();
        (BondSeries storage target, uint24 targetMat) = _selectActiveSeries(currLevel);
        if (targetMat == 0) return false;

        // Pick a lane with entries.
        uint8 lane = uint8(rngWord & 1);
        if (target.lanes[lane].total == 0 && target.lanes[1 - lane].total != 0) {
            lane = 1 - lane;
        }
        if (target.lanes[lane].total == 0) return false;

        address winner = _weightedLanePick(target.lanes[lane], rngWord);
        if (winner == address(0)) return false;

        bool ok = ICoinLike(coinAddr).transfer(winner, amount);
        if (ok) {
            emit BondCoinJackpot(winner, amount, targetMat, lane);
            return true;
        }
        return false;
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

    function resolvePending() external pure returns (bool) {
        return false;
    }

    function notifyGameOver() external {
        if (msg.sender != address(game)) revert Unauthorized();
        bankedInGame = false;
    }

    function finalizeShutdown(uint256 /*maxIds*/) external pure returns (uint256 processedIds, uint256 burned, bool complete) {
        return (0, 0, true);
    }

    function setTransfersLocked(bool /*locked*/, uint48 /*rngDay*/) external {}

    function stakeRateBps() external pure returns (uint16) {
        return 0;
    }

    function purchasesEnabled() external view returns (bool) {
        return bankedInGame;
    }

    /// @notice Emergency shutdown path: consume all ETH and resolve maturities in order, partially paying the last one.
    /// @dev If no entropy is ready, this requests VRF (if configured) and exits; call again once fulfilled.
    function gameOver() external payable {
        if (msg.sender != address(game)) revert Unauthorized();
        bankedInGame = false;

        (uint256 entropy, bool requested) = _prepareEntropy(0);
        if (entropy == 0) {
            // Either VRF was requested or not configured; no entropy to proceed yet.
            if (requested) return;
            return;
        }

        uint256 initialPool = address(this).balance;
        uint256 pool = initialPool;
        uint256 rollingEntropy = entropy;
        uint24 partialMaturity;

        uint24 len = uint24(maturities.length);
        for (uint24 i = 0; i < len; i++) {
            BondSeries storage s = series[maturities[i]];
            if (s.maturityLevel == 0 || s.resolved) continue;

            (uint256 burned, ) = _obligationTotals(s);
            if (burned == 0) {
                s.resolved = true;
                _nukeToken(s);
                continue;
            }

            uint256 payout = burned <= pool ? burned : pool;
            uint256 paid = _resolveSeriesGameOver(s, rollingEntropy, payout);
            pool = pool >= paid ? pool - paid : 0;
            rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "go")));

            s.resolved = true;
            s.rolloverReserve = 0;
            _nukeToken(s);

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
            rem.rolloverReserve = 0;
            _nukeToken(rem);
        }

        uint256 spent = initialPool - pool;
        // Any surplus after resolving in order is forwarded to the vault if configured.
        if (pool != 0 && vault != address(0)) {
            (bool ok, ) = payable(vault).call{value: pool}("");
            if (ok) {
                pool = 0;
            }
        }

        emit BondGameOver(spent, partialMaturity);
    }

    function _activeMaturity() private view returns (uint24 maturityLevel) {
        uint24 currLevel = _currentLevel();
        // choose the next multiple of 5 that is at most 10 levels ahead
        maturityLevel = ((currLevel / 5) + 1) * 5;
        while (currLevel < maturityLevel - 10) {
            maturityLevel += 5;
        }
    }

    function _depositFor(
        address buyer,
        address beneficiary,
        uint24 maturityLevel,
        uint256 amount
    ) private returns (uint256 scoreAwarded) {
        if (amount == 0) revert SaleClosed();
        if (!bankedInGame) revert BankCallFailed();

        BondSeries storage s = _getOrCreateSeries(maturityLevel);
        uint24 currLevel = _currentLevel();
        if (currLevel < s.saleStartLevel || currLevel >= s.maturityLevel) revert SaleClosed();

        try IDegenerusGameBondBank(address(game)).bondDeposit{value: amount}() {} catch {
            revert BankCallFailed();
        }

        uint256 multiplier = _bondScoreMultiplier(buyer, amount);
        scoreAwarded = (amount * multiplier) / ONE;
        if (scoreAwarded == 0) revert InsufficientScore();

        Participant storage p = s.participant[beneficiary];
        if (!p.seen) {
            p.seen = true;
            s.participants.push(beneficiary);
        }
        p.score += scoreAwarded;
        s.totalScore += scoreAwarded;
        s.raised += amount;

        emit BondDeposit(beneficiary, maturityLevel, amount, scoreAwarded);
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
            _sweepExcessToVault(currLevel);
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

            if (currLevel >= s.saleStartLevel && currLevel < s.maturityLevel && s.jackpotsRun < JACKPOT_DAYS && s.lastJackpotLevel != currLevel) {
                _runJackpotsForDay(s, rollingEntropy, currLevel);
                rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, s.jackpotsRun)));
            }

            if (currLevel >= s.maturityLevel && !s.resolved) {
                if (_isFunded(s, currLevel) && !backlogPending) {
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

        _sweepExcessToVault(currLevel);
    }

    /// @notice Burn bond tokens to enter the final two-lane jackpot for a maturity.
    /// @param maturityLevel Series identifier (maturity level).
    /// @param amount Amount of bond token to burn.
    /// @dev Once a maturity has arrived, its lanes are locked and new burns are routed to the +10 maturity.
    ///      Burns performed while the series is still minting also add their weight to the DGNS mint jackpot score.
    function burnForJackpot(uint24 maturityLevel, uint256 amount) external {
        BondSeries storage s = series[maturityLevel];
        if (s.maturityLevel == 0) revert InvalidMaturity();
        if (amount == 0) revert InsufficientScore();

        uint24 currLevel = _currentLevel();
        (BondSeries storage target, uint24 targetMaturity) = _nextActiveSeries(maturityLevel, currLevel);
        if (target.resolved) revert AlreadyResolved();

        s.token.burn(msg.sender, amount);

        uint256 burnWeight = amount;
        if (s.resolved) {
            uint256 reserve = s.rolloverReserve;
            if (reserve == 0 || amount > reserve) revert InsufficientReserve();
            s.rolloverReserve = reserve - amount;
            target.carryPot += amount;
            target.raised += amount;
        }

        (uint8 lane, bool boosted) = _registerBurn(target, targetMaturity, burnWeight, currLevel);
        if (targetMaturity != maturityLevel) {
            emit BondRolled(msg.sender, maturityLevel, targetMaturity, amount);
        }
        emit BondBurned(msg.sender, targetMaturity, lane, burnWeight, boosted);
    }

    function _nextActiveSeries(uint24 maturityLevel, uint24 currLevel) private returns (BondSeries storage target, uint24 targetMaturity) {
        targetMaturity = maturityLevel;
        target = _getOrCreateSeries(targetMaturity);
        // Once a maturity has arrived or been resolved, redirect new burns to the next (+10) maturity.
        while (currLevel >= targetMaturity || target.resolved) {
            targetMaturity += 10;
            target = _getOrCreateSeries(targetMaturity);
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

        // While DGNS is still being minted for this series, count burns toward mint jackpot score as well.
        if (currLevel != 0 && currLevel < s.maturityLevel && s.jackpotsRun < 5 && s.mintedBudget < s.payoutBudget) {
            Participant storage p = s.participant[msg.sender];
            if (!p.seen) {
                p.seen = true;
                s.participants.push(msg.sender);
            }
            p.score += amount;
            s.totalScore += amount;
            boosted = true;
        }
    }

    /// @notice Burn remaining coins from a resolved series to enter the next series jackpot and move reserved ETH.
    function rollToNext(uint24 fromMaturity, uint256 amount) external {
        if (amount == 0) revert InsufficientScore();

        BondSeries storage from = series[fromMaturity];
        if (!from.resolved) revert NotResolved();

        uint256 reserve = from.rolloverReserve;
        if (reserve == 0) revert InsufficientReserve();
        if (amount > reserve) revert InsufficientReserve();

        uint24 toMaturity = fromMaturity + 5;
        BondSeries storage to = _getOrCreateSeries(toMaturity);
        if (to.maturityLevel == 0) revert NextSeriesUnavailable();
        if (to.resolved) revert AlreadyResolved();

        from.token.burn(msg.sender, amount);

        uint256 credit = amount;
        from.rolloverReserve = reserve - credit;

        to.carryPot += credit;
        to.raised += credit;

        uint8 lane = uint8(uint256(keccak256(abi.encodePacked(to.maturityLevel, msg.sender))) & 1);
        to.lanes[lane].entries.push(LaneEntry({player: msg.sender, amount: credit}));
        to.lanes[lane].total += credit;

        emit BondRolled(msg.sender, fromMaturity, to.maturityLevel, credit);
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

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

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
        outstanding = s.token.totalSupply();
    }

    function _isFunded(BondSeries storage s, uint24 currLevel) private view returns (bool) {
        uint256 available = _availableBank();
        (uint256 totalRequired, ) = _requiredCoverTotals(s, currLevel);
        return available >= totalRequired;
    }

    function _requiredCover(BondSeries storage s, uint24 /*currLevel*/) private view returns (uint256 required) {
        if (s.maturityLevel == 0) return 0;
        if (s.resolved) return s.rolloverReserve;

        (uint256 burned, uint256 outstanding) = _obligationTotals(s);
        required = burned + outstanding;
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
        if (bankedInGame) {
            try IDegenerusGameBondBank(address(game)).bondAvailable() returns (uint256 avail) {
                return avail;
            } catch {
                return 0;
            }
        }
        return address(this).balance;
    }

    function _sweepExcessToVault(uint24 currLevel) private {
        address v = vault;
        if (v == address(0)) return;
        if (bankedInGame) return;

        uint256 required;
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

    function _bondScoreMultiplier(address /*player*/, uint256 /*depositWei*/) internal pure returns (uint256) {
        // Stub for future tuning; default 1x.
        return ONE;
    }

    function _createSeries(uint24 maturityLevel) private {
        BondSeries storage s = series[maturityLevel];
        s.maturityLevel = maturityLevel;
        s.saleStartLevel = maturityLevel > 10 ? maturityLevel - 10 : 0;

        uint256 budget = lastIssuanceRaise == 0 ? initialPayoutBudget : (lastIssuanceRaise * 120) / 100;
        s.payoutBudget = budget;

        string memory name = string(abi.encodePacked("Degenerus Bond L", _u24ToString(maturityLevel)));
        // Symbols are fixed by maturity offset: levels ending in 5 use DGNS5, ending in 0 use DGNS0.
        string memory symbol = maturityLevel % 10 == 5 ? "DGNS5" : "DGNS0";
        s.token = new BondToken(name, symbol, address(this), maturityLevel);

        maturities.push(maturityLevel);
        emit BondSeriesCreated(maturityLevel, s.saleStartLevel, address(s.token), budget);
    }

    function _getOrCreateSeries(uint24 maturityLevel) private returns (BondSeries storage s) {
        s = series[maturityLevel];
        if (s.maturityLevel == 0) {
            if (maturityLevel % 5 != 0 || maturityLevel < 5) revert InvalidMaturity();
            _createSeries(maturityLevel);
            s = series[maturityLevel];
        }
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

        uint256 primaryMint = targetTotal > remainingBudget ? remainingBudget : targetTotal;

        if (primaryMint != 0 && s.totalScore != 0) {
            _runMintJackpot(s, rngWord, primaryMint);
            s.mintedBudget += primaryMint;
            emit BondJackpot(s.maturityLevel, s.jackpotsRun, primaryMint, rngWord);
        }

        s.jackpotsRun += 1;
        s.lastJackpotLevel = currLevel;
    }

    function _emissionPct(uint8 run) private pure returns (uint256) {
        if (run < 4) return 5; // first four runs: 5% each
        if (run == 4) return 80; // final run: 80%
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

        for (uint256 i = 4; i < JACKPOT_SPOTS; i++) {
            entropy = uint256(keccak256(abi.encode(entropy, i)));
            address winner = _weightedPick(s, entropy);
            uint256 amount = (i == JACKPOT_SPOTS - 1) ? remaining : perOther;
            s.token.mint(winner, amount);
            _emitJackpotPayout(s.maturityLevel, winner, amount, uint8(i + 1));
            remaining -= amount;
        }
    }

    function _resolveSeriesGameOver(BondSeries storage s, uint256 rngWord, uint256 payout) private returns (uint256 paid) {
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
        uint256 len = chosen.entries.length;
        for (uint256 i = 0; i < len; i++) {
            LaneEntry storage entry = chosen.entries[i];
            uint256 share = (decPool * entry.amount) / chosen.total;
            if (share == 0) continue;
            paid += share;
            if (!_creditPayout(entry.player, share)) {
                paid -= share;
            }
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
            for (uint8 k = 0; k < 14; k++) {
                uint256 prize = buckets[k];
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

    function _nukeToken(BondSeries storage s) private {
        if (address(s.token) == address(0)) return;
        try s.token.nuke() {} catch {}
    }

    function _resolveSeries(BondSeries storage s, uint256 rngWord) private returns (bool resolved) {
        if (s.resolved) return true;
        (uint256 burned, uint256 outstanding) = _obligationTotals(s);
        uint256 remainingToken = outstanding;
        uint256 payoutCap = s.payoutBudget + s.carryPot;
        uint24 currLevel = _currentLevel();
        uint256 available = _availableBank();
        (uint256 totalRequired, uint256 currentRequired) = _requiredCoverTotals(s, currLevel);
        if (available < totalRequired) return false;

        uint256 otherRequired = totalRequired - currentRequired;
        uint256 maxSpend = available - otherRequired;
        uint256 payout = payoutCap > maxSpend ? maxSpend : payoutCap;

        uint256 required = burned + outstanding;
        if (payout < required || payout < currentRequired) return false;

        uint256 reserve = outstanding;

        uint256 distributable = payout - reserve;
        s.rolloverReserve = reserve;

        if (burned == 0) {
            s.resolved = true;
            lastIssuanceRaise = s.raised;
            emit BondSeriesResolved(s.maturityLevel, 0, 0, remainingToken);
            return true;
        }

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
            uint256 len = chosen.entries.length;
            for (uint256 i = 0; i < len; i++) {
                LaneEntry storage entry = chosen.entries[i];
                uint256 share = (decPool * entry.amount) / chosen.total;
                if (share == 0) continue;
                paid += share;
                if (!_creditPayout(entry.player, share)) {
                    paid -= share;
                }
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
                for (uint8 k = 0; k < 14; k++) {
                    uint256 prize = buckets[k];
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
        emit BondSeriesResolved(s.maturityLevel, lane, paid, remainingToken);
        return true;
    }

    function _weightedLanePick(Lane storage lane, uint256 entropy) private view returns (address) {
        uint256 target = entropy % lane.total;
        uint256 running;
        uint256 len = lane.entries.length;
        for (uint256 i = 0; i < len; i++) {
            LaneEntry storage entry = lane.entries[i];
            running += entry.amount;
            if (running > target) return entry.player;
        }
        return len == 0 ? address(0) : lane.entries[len - 1].player;
    }

    function _creditPayout(address player, uint256 amount) private returns (bool) {
        if (amount == 0) return true;
        if (bankedInGame) {
            try IDegenerusGameBondBank(address(game)).bondCreditToClaimable(player, amount) {
                return true;
            } catch {
                return false;
            }
        }
        (bool ok, ) = player.call{value: amount}("");
        return ok;
    }

    function _weightedPick(BondSeries storage s, uint256 entropy) private view returns (address) {
        uint256 targetMain = entropy % s.totalScore;
        uint256 runningMain;
        uint256 lenMain = s.participants.length;
        for (uint256 j = 0; j < lenMain; j++) {
            address playerMain = s.participants[j];
            runningMain += s.participant[playerMain].score;
            if (runningMain > targetMain) return playerMain;
        }
        return lenMain == 0 ? address(0) : s.participants[lenMain - 1];
    }

    function _emitJackpotPayout(uint24 maturityLevel, address player, uint256 amount, uint8 placement) private {
        emit BondJackpotPayout(maturityLevel, player, amount, placement);
    }

    /// @notice VRF callback entrypoint.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != vrfCoordinator) revert Unauthorized();
        if (!vrfRequestPending || requestId != vrfRequestId) return;
        if (randomWords.length == 0) return;
        vrfRequestPending = false;
        vrfPendingWord = randomWords[0];
    }

    function _u24ToString(uint24 value) private pure returns (string memory str) {
        if (value == 0) return "0";
        uint24 temp = value;
        uint8 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        uint8 index = digits;
        temp = value;
        while (temp != 0) {
            index--;
            buffer[index] = bytes1(uint8(48 + temp % 10));
            temp /= 10;
        }
        str = string(buffer);
    }
}
