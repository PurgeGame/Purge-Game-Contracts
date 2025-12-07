// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal view into the core game to read the current level.
interface IPurgeGameLevel {
    function level() external view returns (uint24);
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
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
        if (msg.sender != minter) revert Unauthorized();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
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
}

/**
 * @title PurgeBonds
 * @notice Bond system wired for the Purge game:
 *         - Bonds created every 5 levels; sales open 10 levels before maturity.
 *         - Payout budget = 1.25x the last issuance raise (configurable for the first round).
 *         - Deposits award a score (multiplier stub) used for jackpots.
 *         - Five jackpot days mint a maturity-specific ERC20; total mint equals payout budget.
 *         - Burning the ERC20 enters a two-lane final jackpot at maturity; payout ~pro-rata to burned amount.
 */
contract PurgeBonds {
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
    event BondBurnJackpot(uint24 indexed maturityLevel, uint8 indexed dayIndex, uint256 mintedAmount, uint256 rngWord);
    event BondBurnJackpotPayout(uint24 indexed maturityLevel, address indexed player, uint256 amount, uint8 placement);
    event BondLaneCoinJackpot(uint24 indexed maturityLevel, uint256 mintedAmount);

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

    struct BurnParticipant {
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
        uint256 totalBurnScore;
        BondToken token;
        address[] participants;
        address[] burnParticipants;
        mapping(address => Participant) participant;
        mapping(address => BurnParticipant) burnParticipant;
        mapping(address => uint256) pendingScoreBoost; // early burns that should raise score once sale opens
        Lane[2] lanes;
        bool resolved;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    mapping(uint24 => BondSeries) internal series;
    uint24[] internal maturities;
    IPurgeGameLevel public immutable game;
    uint256 public lastIssuanceRaise;
    uint256 public initialPayoutBudget;
    address public immutable vrfAdmin; // usually the VRF sub owner
    address public vrfCoordinator;
    bytes32 public vrfKeyHash;
    uint256 public vrfSubscriptionId;
    uint256 public vrfRequestId;
    uint256 private vrfPendingWord;
    bool private vrfRequestPending;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address game_, uint256 initialPayoutBudget_, address vrfAdmin_) {
        game = IPurgeGameLevel(game_);
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

    /// @notice Player deposit flow during an active sale window.
    function deposit(uint24 maturityLevel) external payable returns (uint256 scoreAwarded) {
        if (msg.value == 0) revert SaleClosed();

        BondSeries storage s = _getOrCreateSeries(maturityLevel);
        uint24 currLevel = _currentLevel();
        if (currLevel < s.saleStartLevel || currLevel >= s.maturityLevel) revert SaleClosed();

        uint256 multiplier = _bondScoreMultiplier(msg.sender, msg.value);
        scoreAwarded = (msg.value * multiplier) / ONE;
        if (scoreAwarded == 0) revert InsufficientScore();

        Participant storage p = s.participant[msg.sender];
        if (!p.seen) {
            p.seen = true;
            s.participants.push(msg.sender);
        }
        p.score += scoreAwarded;
        s.totalScore += scoreAwarded;
        s.raised += msg.value;

        emit BondDeposit(msg.sender, maturityLevel, msg.value, scoreAwarded);
    }

    /// @notice Run bond maintenance for the current level (create series, run jackpots, resolve funded maturities).
    /// @param rngWord Entropy used for jackpots and lane selection.
    function bondMaintenance(uint256 rngWord) external {
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
                // If any unminted supply remains, drop it into the locked lanes as a coin jackpot.
                uint256 remainingMint = s.payoutBudget > s.mintedBudget ? s.payoutBudget - s.mintedBudget : 0;
                if (remainingMint != 0) {
                    _runLaneCoinJackpot(s, remainingMint);
                    rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "lane-jp")));
                }

                if (_isFunded(s, currLevel) && !backlogPending) {
                    _resolveSeries(s, rollingEntropy);
                    rollingEntropy = uint256(keccak256(abi.encode(rollingEntropy, s.maturityLevel, "resolve")));
                } else {
                    backlogPending = true; // enforce oldest-first resolution
                }
            }
        }
    }

    /// @notice Burn bond tokens to enter the final two-lane jackpot for a maturity.
    /// @param maturityLevel Series identifier (maturity level).
    /// @param amount Amount of bond token to burn.
    /// @param laneHint Ignored; lane assignment is derived from player + maturity for deterministic randomness.
    /// @dev Once a maturity has arrived, its lanes are locked and new burns are routed to the +10 maturity.
    ///      If maturity is >5 levels away, half the burn amount is queued as score for the next coin-minting jackpot.
    function burnForJackpot(uint24 maturityLevel, uint256 amount, uint8 laneHint) external {
        BondSeries storage s = series[maturityLevel];
        if (s.maturityLevel == 0) revert InvalidMaturity();
        if (amount == 0) revert InsufficientScore();

        uint24 currLevel = _currentLevel();
        (BondSeries storage target, uint24 targetMaturity) = _nextActiveSeries(maturityLevel, currLevel);
        if (target.resolved) revert AlreadyResolved();

        s.token.burn(msg.sender, amount);

        (uint8 lane, bool boosted) = _registerBurn(target, targetMaturity, amount, currLevel);
        if (targetMaturity != maturityLevel) {
            emit BondRolled(msg.sender, maturityLevel, targetMaturity, amount);
        }
        emit BondBurned(msg.sender, targetMaturity, lane, amount, boosted);
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

        if (currLevel != 0 && currLevel < s.maturityLevel) {
            uint24 levelsToMaturity = s.maturityLevel - currLevel;

            // Early burns (more than 5 levels out) grant a half-weight boost toward the next coin-minting jackpot.
            if (levelsToMaturity > 5) {
                uint256 boost = amount / 2;
                if (boost != 0) {
                    Participant storage p = s.participant[msg.sender];
                    if (!p.seen) {
                        p.seen = true;
                        s.participants.push(msg.sender);
                    }
                    s.pendingScoreBoost[msg.sender] += boost;
                    boosted = true;
                }
            }

            // Burns during the sales window also earn entries for the burn-only jackpots.
            if (currLevel >= s.saleStartLevel) {
                BurnParticipant storage bp = s.burnParticipant[msg.sender];
                if (!bp.seen) {
                    bp.seen = true;
                    s.burnParticipants.push(msg.sender);
                }
                bp.score += amount; // unmodified burn weight
                s.totalBurnScore += amount;
            }
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
        (uint256 burned, uint256 outstanding) = _obligationTotals(s); // coin already burned into lanes + live supply

        // Once at or past maturity, only the burned entries must be covered to resolve.
        if (currLevel >= s.maturityLevel) {
            return s.raised >= burned;
        }

        // Before maturity, require enough to cover burned entries plus all live coin as if it were burned.
        return s.raised >= burned + outstanding;
    }

    function _bondScoreMultiplier(address /*player*/, uint256 /*depositWei*/) internal view returns (uint256) {
        // Stub for future tuning; default 1x.
        return ONE;
    }

    function _createSeries(uint24 maturityLevel) private {
        BondSeries storage s = series[maturityLevel];
        s.maturityLevel = maturityLevel;
        s.saleStartLevel = maturityLevel > 10 ? maturityLevel - 10 : 0;

        uint256 budget = lastIssuanceRaise == 0 ? initialPayoutBudget : (lastIssuanceRaise * 120) / 100;
        s.payoutBudget = budget;

        string memory name = string(abi.encodePacked("Purge Bond L", _u24ToString(maturityLevel)));
        string memory symbol = string(abi.encodePacked("PBL", _u24ToString(maturityLevel)));
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

    function _runJackpot(BondSeries storage s, uint256 rngWord, uint24 currLevel) private {
    function _runJackpotsForDay(BondSeries storage s, uint256 rngWord, uint24 currLevel) private {
        if (s.payoutBudget == 0 || s.mintedBudget >= s.payoutBudget) return;

        uint256 base = s.payoutBudget / 100; // 1% of final supply
        uint256 primaryTarget = s.jackpotsRun == 0 ? base * 2 : base; // day 1: 2%
        uint256 secondaryTarget = base; // burner jackpot always 1%

        uint256 remaining = s.payoutBudget - s.mintedBudget;
        uint256 primaryMint = primaryTarget > remaining ? remaining : primaryTarget;
        remaining = remaining > primaryMint ? remaining - primaryMint : 0;
        uint256 secondaryMint = secondaryTarget > remaining ? remaining : secondaryTarget;

        // Apply any pending boosts queued from early burns (affects both jackpots).
        uint256 participantsLen = s.participants.length;
        for (uint256 i = 0; i < participantsLen; i++) {
            address player = s.participants[i];
            uint256 boost = s.pendingScoreBoost[player];
            if (boost != 0) {
                s.pendingScoreBoost[player] = 0;
                s.participant[player].score += boost;
                s.totalScore += boost;
            }
        }

        if (primaryMint != 0 && s.totalScore != 0) {
            _runMintJackpot(s, rngWord, primaryMint, false);
            s.mintedBudget += primaryMint;
            emit BondJackpot(s.maturityLevel, s.jackpotsRun, primaryMint, rngWord);
        }

        if (secondaryMint != 0 && s.totalBurnScore != 0) {
            uint256 burnEntropy = uint256(keccak256(abi.encode(rngWord, "burn")));
            _runMintJackpotBurners(s, burnEntropy, secondaryMint);
            s.mintedBudget += secondaryMint;
            emit BondBurnJackpot(s.maturityLevel, s.jackpotsRun, secondaryMint, burnEntropy);
        }

        s.jackpotsRun += 1;
        s.lastJackpotLevel = currLevel;
    }

    function _runMintJackpot(
        BondSeries storage s,
        uint256 rngWord,
        uint256 toMint,
        bool useBurners
    ) private {
        uint256 remaining = toMint;
        uint256 first = (toMint * TOP_PCT_1) / 100;
        uint256 second = (toMint * TOP_PCT_2) / 100;
        uint256 third = (toMint * TOP_PCT_3) / 100;
        uint256 fourth = (toMint * TOP_PCT_4) / 100;
        uint256 perOther = (toMint - first - second - third - fourth) / 96;

        uint256 entropy = rngWord;

        address w1 = _weightedPick(s, entropy, useBurners);
        s.token.mint(w1, first);
        _emitJackpotPayout(s.maturityLevel, w1, first, 1, useBurners);
        remaining -= first;

        entropy = uint256(keccak256(abi.encode(entropy, 1)));
        address w2 = _weightedPick(s, entropy, useBurners);
        s.token.mint(w2, second);
        _emitJackpotPayout(s.maturityLevel, w2, second, 2, useBurners);
        remaining -= second;

        entropy = uint256(keccak256(abi.encode(entropy, 2)));
        address w3 = _weightedPick(s, entropy, useBurners);
        s.token.mint(w3, third);
        _emitJackpotPayout(s.maturityLevel, w3, third, 3, useBurners);
        remaining -= third;

        entropy = uint256(keccak256(abi.encode(entropy, 3)));
        address w4 = _weightedPick(s, entropy, useBurners);
        s.token.mint(w4, fourth);
        _emitJackpotPayout(s.maturityLevel, w4, fourth, 4, useBurners);
        remaining -= fourth;

        for (uint256 i = 4; i < JACKPOT_SPOTS; i++) {
            entropy = uint256(keccak256(abi.encode(entropy, i)));
            address winner = _weightedPick(s, entropy, useBurners);
            uint256 amount = (i == JACKPOT_SPOTS - 1) ? remaining : perOther;
            s.token.mint(winner, amount);
            _emitJackpotPayout(s.maturityLevel, winner, amount, uint8(i + 1), useBurners);
            remaining -= amount;
        }
    }

    function _runMintJackpotBurners(BondSeries storage s, uint256 rngWord, uint256 toMint) private {
        _runMintJackpot(s, rngWord, toMint, true);
    }

    function _runLaneCoinJackpot(BondSeries storage s, uint256 toMint) private {
        uint256 totalBurn = s.lanes[0].total + s.lanes[1].total;
        if (toMint == 0 || totalBurn == 0) return;

        uint256 minted;
        for (uint8 laneIdx = 0; laneIdx < 2; laneIdx++) {
            Lane storage lane = s.lanes[laneIdx];
            uint256 len = lane.entries.length;
            for (uint256 i = 0; i < len; i++) {
                LaneEntry storage entry = lane.entries[i];
                uint256 share = (toMint * entry.amount) / totalBurn;
                if (share == 0) continue;
                minted += share;
                s.token.mint(entry.player, share);
            }
        }

        if (minted != 0) {
            s.mintedBudget += minted;
            emit BondLaneCoinJackpot(s.maturityLevel, minted);
        }
    }

    function _resolveSeries(BondSeries storage s, uint256 rngWord) private {
        if (s.resolved) return;
        (uint256 burned, uint256 outstanding) = _obligationTotals(s);
        uint256 remainingToken = outstanding;
        uint256 payoutCap = s.payoutBudget + s.carryPot;
        uint256 available = s.raised + s.carryPot;
        uint256 payout = payoutCap > available ? available : payoutCap;

        if (payout < burned) revert InsufficientReserve();

        uint256 reserve;
        if (payout > burned) {
            uint256 leftover = payout - burned;
            reserve = leftover > outstanding ? outstanding : leftover;
        }

        uint256 distributable = payout - reserve;
        s.rolloverReserve = reserve;

        if (burned == 0) {
            s.resolved = true;
            lastIssuanceRaise = s.raised;
            emit BondSeriesResolved(s.maturityLevel, 0, 0, remainingToken);
            return;
        }

        uint8 lane = uint8(rngWord & 1);
        if (s.lanes[lane].total == 0 && s.lanes[1 - lane].total != 0) {
            lane = 1 - lane;
        }
        if (s.lanes[lane].total == 0) revert NoBurnedEntries();

        Lane storage chosen = s.lanes[lane];
        uint256 paid;
        uint256 len = chosen.entries.length;
        if (distributable != 0) {
            for (uint256 i = 0; i < len; i++) {
                LaneEntry storage entry = chosen.entries[i];
                uint256 share = (distributable * entry.amount) / chosen.total;
                if (share == 0) continue;
                paid += share;
                (bool ok, ) = entry.player.call{value: share}("");
                if (!ok) {
                    // best effort; if transfer fails, leave funds in contract for manual recovery
                    paid -= share;
                }
            }
        }

        s.resolved = true;
        lastIssuanceRaise = s.raised;
        emit BondSeriesResolved(s.maturityLevel, lane, paid, remainingToken);
    }

    function _weightedPick(BondSeries storage s, uint256 entropy, bool useBurners) private view returns (address) {
        if (useBurners) {
            uint256 target = entropy % s.totalBurnScore;
            uint256 running;
            uint256 len = s.burnParticipants.length;
            for (uint256 i = 0; i < len; i++) {
                address player = s.burnParticipants[i];
                running += s.burnParticipant[player].score;
                if (running > target) return player;
            }
            return len == 0 ? address(0) : s.burnParticipants[len - 1];
        }

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

    function _emitJackpotPayout(uint24 maturityLevel, address player, uint256 amount, uint8 placement, bool burn) private {
        if (burn) {
            emit BondBurnJackpotPayout(maturityLevel, player, amount, placement);
        } else {
            emit BondJackpotPayout(maturityLevel, player, amount, placement);
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
