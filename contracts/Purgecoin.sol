// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameNFT} from "./PurgeGameNFT.sol";
import {IPurgeGameTrophies, PURGE_TROPHY_KIND_STAKE} from "./PurgeGameTrophies.sol";
import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeRenderer} from "./interfaces/IPurgeRenderer.sol";

contract Purgecoin {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event StakeCreated(address indexed player, uint24 targetLevel, uint8 risk, uint256 principal);
    event CoinflipDeposit(address indexed player, uint256 amountBurned, uint256 rakeAmount, uint256 creditedStake);
    event DecimatorBurn(address indexed player, uint256 amountBurned, uint256 weightedContribution);
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);
    event CoinflipFinished(bool result);
    event CoinJackpotPaid(uint16 trait, address winner, uint256 amount);
    event BountyOwed(address indexed to, uint256 bountyAmount, uint256 newRecordFlip);
    event BountyPaid(address indexed to, uint256 amount);
    event FlipNuked(address indexed player, uint32 streak, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyDeployer();
    error OnlyGame();
    error BettingPaused();
    error Zero();
    error Insufficient();
    error AmountLTMin();
    error E();
    error InvalidLeaderboard();
    error PresaleExceedsRemaining();
    error PresalePerTxLimit();
    error InvalidKind();
    error StakeInvalid();
    error ZeroAddress();
    error NotDecimatorWindow();
    error InvalidRakeback();

    // ---------------------------------------------------------------------
    // ERC20 state
    // ---------------------------------------------------------------------
    string public name = "Purgecoin";
    string public symbol = "PURGE";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) revert ZeroAddress();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct PlayerScore {
        address player;
        uint96 score; // stores whole-token totals (PURGE units without 6d fractional component)
    }

    /// @dev BAF jackpot accounting
    struct BAFState {
        uint128 totalPrizePoolWei;
        uint120 returnAmountWei;
        bool inProgress;
    }

    /// @dev BAF scatter scan cursor
    struct BAFScan {
        uint120 per;
        uint32 limit;
        uint8 offset;
    }

    /// @dev Decimator per-player burn snapshot for a given level
    struct DecEntry {
        uint192 burn;
        uint24 level;
        uint8 bucket;
        bool winner;
    }

    struct AffiliateCodeInfo {
        address owner;
        uint8 rakeback; // percentage (0-25)
    }

    // ---------------------------------------------------------------------
    // Constants (units & limits)
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6; // token has 6 decimals
    uint256 private constant MIN = 100 * MILLION; // min burn / min flip (100 PURGED)
    uint8 private constant MAX_RISK = 11; // staking risk 1..11
    uint128 private constant ONEK = 1_000_000_000; // 1,000 PURGED (6d)
    uint32 private constant BAF_BATCH = 5000;
    uint256 private constant BUCKET_SIZE = 1500;
    bytes32 private constant H = 0x0815bfaf2b1567e207818b2763021381926855cfef9a360737b5a8aae60c41b7;
    uint8 private constant STAKE_MAX_LANES = 3;
    uint256 private constant STAKE_LANE_BITS = 86;
    uint256 private constant STAKE_LANE_MASK = (uint256(1) << STAKE_LANE_BITS) - 1;
    uint256 private constant STAKE_LANE_RISK_BITS = 8;
    uint256 private constant STAKE_LANE_PRINCIPAL_BITS = STAKE_LANE_BITS - STAKE_LANE_RISK_BITS;
    uint256 private constant STAKE_LANE_PRINCIPAL_MASK = (uint256(1) << STAKE_LANE_PRINCIPAL_BITS) - 1;
    uint256 private constant STAKE_LANE_RISK_SHIFT = STAKE_LANE_PRINCIPAL_BITS;
    uint256 private constant STAKE_LANE_RISK_MASK = ((uint256(1) << STAKE_LANE_RISK_BITS) - 1) << STAKE_LANE_RISK_SHIFT;
    uint256 private constant STAKE_PRINCIPAL_FACTOR = MILLION;
    uint256 private constant STAKE_MAX_PRINCIPAL = STAKE_LANE_PRINCIPAL_MASK * STAKE_PRINCIPAL_FACTOR;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant PRESALE_SUPPLY_TOKENS = 4_000_000;
    uint256 private constant PRESALE_START_PRICE = 0.000012 ether;
    uint256 private constant PRESALE_END_PRICE = 0.000018 ether;
    uint256 private constant PRESALE_PRICE_SLOPE = (PRESALE_END_PRICE - PRESALE_START_PRICE) / PRESALE_SUPPLY_TOKENS;
    uint256 private constant PRESALE_MAX_ETH_PER_TX = 0.25 ether;
    uint256 private constant AFFILIATE_STREAK_BASE_THRESHOLD = 15 * 1000 * MILLION;
    bytes32 private constant REF_CODE_LOCKED = bytes32(uint256(1));
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;

    // Scan sentinels
    // ---------------------------------------------------------------------
    uint32 private constant SS_IDLE = type(uint32).max; // not started
    uint32 private constant SS_DONE = type(uint32).max - 1; // finished

    // ---------------------------------------------------------------------
    // Immutables / external wiring
    // ---------------------------------------------------------------------
    address private immutable creator; // deployer / ETH sink

    // ---------------------------------------------------------------------
    // Game wiring & state
    // ---------------------------------------------------------------------
    IPurgeGame private purgeGame; // PurgeGame contract handle (set once)
    PurgeGameNFT private purgeGameNFT; // Authorized contract for base NFT operations
    IPurgeGameTrophies private purgeGameTrophies; // Trophy module handle

    // Session flags
    bool private tbActive; // "tenth player" bonus active
    bool private bonusActive; // super bonus mode active
    uint8 private extMode; // external jackpot mode (state machine)

    // Leaderboard lengths
    uint8 private affiliateLen;
    uint8 private topLen;

    // "tenth player" bonus fields
    uint8 private tbMod; // wheel mod (0..9)
    uint32 private tbRemain; // remaining awards
    uint256 private tbPrize; // prize per tenth player

    // Scan cursors / progress
    uint24 private stakeLevelComplete;
    uint32 private scanCursor = SS_IDLE;
    uint32 private payoutIndex;

    // Daily jackpot accounting
    uint256 private dailyCoinBurn;
    uint256 private currentTenthPlayerBonusPool;

    // Coinflip roster stored as a reusable ring buffer.
    address[] private cfPlayers;
    uint128 private cfHead; // next index to pay
    uint128 private cfTail; // next slot to write

    mapping(address => uint256) public coinflipAmount;

    // Tracks headline bettors for bonus logic.
    PlayerScore[8] public topBettors;

    // Affiliates / luckbox
    mapping(bytes32 => AffiliateCodeInfo) private affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned; // level => player => earned
    mapping(address => bytes32) private playerReferralCode;
    mapping(address => uint256) public playerLuckbox;
    PlayerScore[8] public affiliateLeaderboard;
    mapping(address => uint64) private affiliateDailyStreakPacked;
    mapping(address => uint128) private affiliateDailyBasePacked;

    // Staking
    mapping(uint24 => address[]) private stakeAddr; // level => stakers
    mapping(uint24 => mapping(address => uint256)) private stakeAmt; // level => packed stake lanes (principal/risk)
    struct StakeTrophyCandidate {
        address player;
        uint72 principal; // fits with address+level in one slot
        uint24 level;
    }
    StakeTrophyCandidate private stakeTrophyCandidate;

    // Leaderboard index maps (1-based positions)
    mapping(address => uint8) private affiliatePos;
    mapping(address => uint8) private topPos;
    mapping(address => uint32) private luckyFlipStreak;
    mapping(address => uint48) private lastLuckyStreakEpoch;
    uint48 private streakEpoch;

    // Bounty / BAF heads
    uint128 public currentBounty = ONEK;
    uint128 public biggestFlipEver = ONEK;
    address private bountyOwedTo;
    uint96 public totalPresaleSold; // total presale output in base units (6 decimals)

    uint256 private nukeStream;

    // BAF / Decimator execution state
    BAFState private bafState;
    BAFScan private bs;
    uint256 private extVar; // decimator accumulator/denominator

    // Decimator tracking
    mapping(address => DecEntry) private decBurn;
    mapping(uint24 => mapping(uint24 => address[])) private decBuckets; // level => bucketIdx => players
    mapping(uint24 => uint32) private decPlayersCount;
    uint32[32] private decBucketAccumulator; // index by denominator (2..31)
    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyPurgeGameContract() {
        if (msg.sender != address(purgeGame)) revert OnlyGame();
        _;
    }

    modifier onlyGameplayContracts() {
        address sender = msg.sender;
        if (sender != address(purgeGame) && sender != address(purgeGameNFT) && sender != address(purgeGameTrophies))
            revert OnlyGame();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    /**
     * @dev Mints the initial presale allocation to the contract and creator.
     */
    constructor() {
        creator = msg.sender;
        uint256 presaleAmount = PRESALE_SUPPLY_TOKENS * MILLION;
        _mint(address(this), presaleAmount);
        _mint(creator, presaleAmount);
    }

    /// @notice Burn PURGE to increase the caller’s coinflip stake, applying streak bonuses when eligible.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum.
    function depositCoinflip(uint256 amount) external {
        if (purgeGameNFT.rngLocked()) revert BettingPaused();
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;
        uint256 prevStake = coinflipAmount[caller];

        _burn(caller, amount);

        uint256 stakeCredit = amount;
        if (stakeCredit == 0) revert Insufficient();

        if (prevStake == 0) {
            uint48 epoch = streakEpoch;
            if (epoch == 0) epoch = 1;
            uint48 lastEpoch = lastLuckyStreakEpoch[caller];
            if (lastEpoch != epoch) {
                uint32 streak = luckyFlipStreak[caller];
                if (lastEpoch != 0 && epoch == lastEpoch + 1) {
                    unchecked {
                        streak += 1;
                    }
                } else {
                    streak = 1;
                }
                luckyFlipStreak[caller] = streak;
                lastLuckyStreakEpoch[caller] = epoch;
                uint256 bonusTotal = _streakExtra(streak);
                stakeCredit += bonusTotal;
            }
        }

        addFlip(caller, stakeCredit, true);

        if (!_isBafActive()) {
            playerLuckbox[caller] = stakeCredit;
        }

        unchecked {
            dailyCoinBurn += amount;
        }

        emit CoinflipDeposit(caller, amount, 0, stakeCredit);
    }

    /// @notice Burn PURGE during an active Decimator window to accrue weighted participation.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum.
    function decimatorBurn(uint256 amount) external {
        (bool decOn, uint24 lvl) = _decWindow();
        if (!decOn) revert NotDecimatorWindow();
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;
        _burn(caller, amount);

        unchecked {
            dailyCoinBurn += amount;
        }

        bool specialDec = (lvl == DECIMATOR_SPECIAL_LEVEL);
        uint8 bucket = specialDec
            ? _decBucketDenominatorFromLevels(purgeGame.ethMintLevelCount(caller))
            : _decBucketDenominator(purgeGame.ethMintStreakCount(caller));
        DecEntry storage e = decBurn[caller];

        if (e.level != lvl) {
            e.level = lvl;
            e.burn = 0;
            e.bucket = bucket;
            e.winner = false;
            _decPush(lvl, caller);
        } else if (bucket < e.bucket || e.bucket == 0) {
            e.bucket = bucket;
        }

        uint256 updated = uint256(e.burn) + amount;
        if (updated > type(uint192).max) updated = type(uint192).max;
        e.burn = uint192(updated);

        emit DecimatorBurn(caller, amount, amount);
    }

    // Affiliate code management
    /// @notice Create a new affiliate code mapping to the caller.
    /// @dev Reverts if `code_` is zero, reserved, or already taken.
    function createAffiliateCode(bytes32 code_, uint8 rakebackPct) external {
        if (code_ == bytes32(0) || code_ == REF_CODE_LOCKED) revert Zero();
        if (rakebackPct > 25) revert InvalidRakeback();
        AffiliateCodeInfo storage info = affiliateCode[code_];
        if (info.owner != address(0)) revert Insufficient();
        affiliateCode[code_] = AffiliateCodeInfo({owner: msg.sender, rakeback: rakebackPct});
        emit Affiliate(1, code_, msg.sender); // 1 = code created
    }

    /// @notice Set the caller's referrer once using a valid affiliate code.
    /// @dev Reverts if code is unknown, self-referral, or caller already has a referrer.
    function referPlayer(bytes32 code_) external {
        AffiliateCodeInfo storage info = affiliateCode[code_];
        address referrer = info.owner;
        if (referrer == address(0) || referrer == msg.sender) revert Insufficient();
        bytes32 existing = playerReferralCode[msg.sender];
        if (existing != bytes32(0)) revert Insufficient();
        playerReferralCode[msg.sender] = code_;
        emit Affiliate(0, code_, msg.sender); // 0 = player referred
    }

    function _referralCode(address player) private view returns (bytes32 code) {
        code = playerReferralCode[player];
        if (code == bytes32(0) || code == REF_CODE_LOCKED) return bytes32(0);
        if (affiliateCode[code].owner == address(0)) return bytes32(0);
        return code;
    }

    function _referrerAddress(address player) private view returns (address) {
        bytes32 code = _referralCode(player);
        if (code == bytes32(0)) return address(0);
        return affiliateCode[code].owner;
    }


    // Stake with encoded risk window
    function _encodeStakeLane(uint256 principalRounded, uint8 risk) private pure returns (uint256) {
        if (risk == 0 || risk > MAX_RISK) revert StakeInvalid();
        if (principalRounded == 0) revert StakeInvalid();

        uint256 normalized = principalRounded / STAKE_PRINCIPAL_FACTOR;
        if (normalized == 0) normalized = 1;
        if (normalized > STAKE_LANE_PRINCIPAL_MASK) {
            normalized = STAKE_LANE_PRINCIPAL_MASK;
        }
        return normalized | (uint256(risk) << STAKE_LANE_RISK_SHIFT);
    }

    function _decodeStakeLane(uint256 lane) private pure returns (uint256 principalRounded, uint8 risk) {
        if (lane == 0) return (0, 0);
        uint256 units = lane & STAKE_LANE_PRINCIPAL_MASK;
        principalRounded = units * STAKE_PRINCIPAL_FACTOR;
        risk = uint8((lane & STAKE_LANE_RISK_MASK) >> STAKE_LANE_RISK_SHIFT);
    }

    function _laneAt(uint256 encoded, uint8 index) private pure returns (uint256) {
        if (index >= STAKE_MAX_LANES) return 0;
        uint256 shift = uint256(index) * STAKE_LANE_BITS;
        return (encoded >> shift) & STAKE_LANE_MASK;
    }

    function _setLane(uint256 encoded, uint8 index, uint256 laneValue) private pure returns (uint256) {
        uint256 shift = uint256(index) * STAKE_LANE_BITS;
        uint256 mask = STAKE_LANE_MASK << shift;
        return (encoded & ~mask) | (laneValue << shift);
    }

    function _laneCount(uint256 encoded) private pure returns (uint8 count) {
        if ((encoded & STAKE_LANE_MASK) != 0) count++;
        if (((encoded >> STAKE_LANE_BITS) & STAKE_LANE_MASK) != 0) count++;
        if (((encoded >> (2 * STAKE_LANE_BITS)) & STAKE_LANE_MASK) != 0) count++;
    }

    function _ensureCompatible(uint256 encoded, uint8 expectRisk) private pure returns (uint8 lanes) {
        for (uint8 i; i < STAKE_MAX_LANES; ) {
            uint256 lane = _laneAt(encoded, i);
            if (lane == 0) break;
            lanes++;
            uint8 haveRisk = uint8((lane & STAKE_LANE_RISK_MASK) >> STAKE_LANE_RISK_SHIFT);
            if (haveRisk != expectRisk) revert StakeInvalid();
            unchecked {
                ++i;
            }
        }
    }

    function _insertLane(uint256 encoded, uint256 laneValue) private pure returns (uint256) {
        uint8 riskNew = uint8((laneValue & STAKE_LANE_RISK_MASK) >> STAKE_LANE_RISK_SHIFT);

        uint8 lanes;

        // Try to merge with an existing lane carrying the same risk
        for (uint8 idx; idx < STAKE_MAX_LANES; ) {
            uint256 target = _laneAt(encoded, idx);
            if (target == 0) break;
            lanes++;
            uint8 riskExisting = uint8((target & STAKE_LANE_RISK_MASK) >> STAKE_LANE_RISK_SHIFT);
            if (riskExisting == riskNew) {
                uint256 unitsExisting = target & STAKE_LANE_PRINCIPAL_MASK;
                uint256 unitsNew = laneValue & STAKE_LANE_PRINCIPAL_MASK;
                uint256 totalUnits = unitsExisting + unitsNew;
                if (totalUnits >> STAKE_LANE_PRINCIPAL_BITS != 0) revert StakeInvalid();
                uint256 mergedLane = (target & ~STAKE_LANE_PRINCIPAL_MASK) | totalUnits;
                return _setLane(encoded, idx, mergedLane);
            }
            unchecked {
                ++idx;
            }
        }

        if (lanes < STAKE_MAX_LANES) {
            return _setLane(encoded, lanes, laneValue);
        }
        // all slots occupied with different maturities
        revert StakeInvalid();
    }

    function _capStakePrincipal(uint256 principal) private pure returns (uint72) {
        if (principal > type(uint72).max) return type(uint72).max;
        return uint72(principal);
    }

    function _recordStakeTrophyCandidate(uint24 level, address player, uint256 principal) private {
        if (player == address(0) || principal == 0) return;
        uint72 principalCapped = _capStakePrincipal(principal);
        StakeTrophyCandidate storage cand = stakeTrophyCandidate;
        if (cand.level != level) {
            stakeTrophyCandidate = StakeTrophyCandidate({player: player, principal: principalCapped, level: level});
            return;
        }
        if (principalCapped > cand.principal) {
            cand.player = player;
            cand.principal = principalCapped;
        }
    }

    function _finalizeStakeTrophy(uint24 level, bool award) private {
        StakeTrophyCandidate storage cand = stakeTrophyCandidate;
        address player = cand.player;
        uint24 candLevel = cand.level;
        uint72 principal = cand.principal;

        if (award && candLevel == level && player != address(0) && principal != 0) {
            uint256 dataWord =
                (uint256(0xFFFF) << 152) |
                (uint256(level) << TROPHY_BASE_LEVEL_SHIFT) |
                TROPHY_FLAG_STAKE;
            purgeGameTrophies.awardTrophy(player, level, PURGE_TROPHY_KIND_STAKE, dataWord, 0);
        }

        if (!award) {
            purgeGameTrophies.clearStakePreview(level);
        }
        if (candLevel == level || !award) {
            delete stakeTrophyCandidate;
        }
    }

    /// @notice Burn PURGED to open a future "stake window" targeting `targetLevel` with a risk radius.
    /// @dev
    /// - `burnAmt` must be at least 250e6 base units (token has 6 decimals).
    /// - `targetLevel` must be at least 11 levels ahead of the current game level.
    /// - `risk` must be between 1 and `MAX_RISK` and cannot exceed the distance to `targetLevel`.
    /// - Encodes stake as whole-token principal (6-decimal trimmed) plus an 8-bit risk code.
    /// - Enforces no overlap/collision with caller's existing stakes.
    function stake(uint256 burnAmt, uint24 targetLevel, uint8 risk) external {
        if (burnAmt < 250 * MILLION) revert AmountLTMin();
        if (purgeGameNFT.rngLocked()) revert BettingPaused();
        address sender = msg.sender;
        uint24 currLevel = purgeGame.level();
        if (targetLevel < currLevel) revert StakeInvalid();

        uint8 stakeGameState = purgeGame.gameState();

        uint24 effectiveLevel;
        if (stakeGameState == 3) {
            effectiveLevel = currLevel;
        } else if (currLevel == 0) {
            effectiveLevel = 0;
        } else {
            unchecked {
                effectiveLevel = uint24(currLevel - 1);
            }
        }

        if (targetLevel <= effectiveLevel) revert StakeInvalid();

        uint24 distance = targetLevel - effectiveLevel;
        if (distance > 500) revert Insufficient();

        if (risk == 0 || risk > MAX_RISK) revert Insufficient();

        uint256 maxRiskForTarget = uint256(targetLevel) + 1 - uint256(effectiveLevel);
        if (risk > maxRiskForTarget) revert Insufficient();

        // Starting level where this stake is placed (inclusive)
        uint24 placeLevel = uint24(uint256(targetLevel) + 1 - uint256(risk));
        if (placeLevel < effectiveLevel) revert StakeInvalid();

        // 1) Guard against direct collisions in the risk window [placeLevel .. placeLevel+risk-1]
        uint256 existingEncoded;
        for (uint8 offset; offset < risk; ) {
            uint24 checkLevel = placeLevel + uint24(offset);
            existingEncoded = stakeAmt[checkLevel][sender];
            if (existingEncoded != 0) {
                uint8 wantRisk = risk - offset;
                uint8 lanes = _ensureCompatible(existingEncoded, wantRisk);
                if (lanes >= STAKE_MAX_LANES) revert StakeInvalid();
            }
            unchecked {
                ++offset;
            }
        }

        // 2) Guard against overlap from earlier stakes that extend into placeLevel
        uint24 scanStart = currLevel;
        uint24 scanFloor = placeLevel > (MAX_RISK - 1) ? uint24(placeLevel - (MAX_RISK - 1)) : uint24(1);
        if (scanStart < scanFloor) scanStart = scanFloor;

        for (uint24 scanLevel = scanStart; scanLevel < placeLevel; ) {
            uint256 existingAtScan = stakeAmt[scanLevel][sender];
            if (existingAtScan != 0) {
                for (uint8 li; li < STAKE_MAX_LANES; ) {
                    uint256 lane = _laneAt(existingAtScan, li);
                    if (lane == 0) break;
                    (, uint8 existingRisk) = _decodeStakeLane(lane);
                    uint24 reachLevel = scanLevel + uint24(existingRisk) - 1;
                    if (reachLevel >= placeLevel) {
                        uint24 impliedRiskAtPlace = uint24(existingRisk) - (placeLevel - scanLevel);
                        if (uint8(impliedRiskAtPlace) != risk) revert StakeInvalid();
                    }
                    unchecked {
                        ++li;
                    }
                }
            }
            unchecked {
                ++scanLevel;
            }
        }

        // Burn principal
        _burn(sender, burnAmt);

        // Base credit and compounded boost factors
        uint256 cappedDist = distance > 200 ? 200 : distance;
        uint256 levelBps = 100 + cappedDist;
        uint256 riskBps = 25 * uint256(risk - 1);
        uint256 stepBps = levelBps + riskBps; // per-level growth in bps

        // Compounded growth applied to the full burned amount
        uint256 boostedPrincipal = burnAmt;
        for (uint24 i = distance; i != 0; ) {
            boostedPrincipal = (boostedPrincipal * (10_000 + stepBps)) / 10_000;
            unchecked {
                --i;
            }
        }

        if (currLevel == 1 && stakeGameState == 1) {
            boostedPrincipal = distance >= 10
                ? (boostedPrincipal * 3) / 2
                : (boostedPrincipal * 6) / 5;
        }

        uint8 stakeTrophyBoost = purgeGameTrophies.stakeTrophyBonus(sender);
        if (stakeTrophyBoost != 0) {
            boostedPrincipal += (boostedPrincipal * stakeTrophyBoost) / 100;
        }

        // Encode and place the stake lane
        uint256 principalRounded = boostedPrincipal - (boostedPrincipal % STAKE_PRINCIPAL_FACTOR);
        if (principalRounded > STAKE_MAX_PRINCIPAL) {
            principalRounded = STAKE_MAX_PRINCIPAL;
        }
        if (principalRounded == 0) principalRounded = STAKE_PRINCIPAL_FACTOR;
        uint256 newLane = _encodeStakeLane(principalRounded, risk);

        uint256 existingAtPlace = stakeAmt[placeLevel][sender];
        if (existingAtPlace == 0) {
            stakeAmt[placeLevel][sender] = newLane;
            stakeAddr[placeLevel].push(sender);
        } else {
            stakeAmt[placeLevel][sender] = _insertLane(existingAtPlace, newLane);
        }

        emit StakeCreated(sender, targetLevel, risk, principalRounded);
    }

    /// @notice Return the recorded referrer for `player` (zero address if none).
    function getReferrer(address player) external view returns (address) {
        return _referrerAddress(player);
    }
    /// @notice Credit affiliate rewards for a purchase (invoked by trusted gameplay contracts).
    /// @dev
    /// Referral rules:
    /// - If `playerReferralCode[sender]` is the locked sentinel, we no-op.
    /// - Else if a referrer code already exists: use that code’s owner.
    /// - Else if `code` resolves to a valid owner different from `sender`: bind it and use it.
    /// - Else: lock the sender to disallow future attempts.
    /// Payout rules:
    /// - `amount` earns a 60% bonus on levels `level % 25 == 1`.
    /// - Direct ref gets a coinflip credit equal to `amount` (plus stake bonus), but the configured rakeback%
    ///   is diverted to the buyer as flip credit.
    /// - Their upline (if any and already active this level) receives a 20% bonus coinflip credit of the same
    ///   (post-doubling) amount.
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl)
        external
        onlyGameplayContracts
        returns (uint256 playerRakeback)
    {
        bytes32 storedCode = playerReferralCode[sender];
        if (storedCode == REF_CODE_LOCKED) return 0;

        AffiliateCodeInfo storage info;
        if (storedCode == bytes32(0)) {
            AffiliateCodeInfo storage candidate = affiliateCode[code];
            if (candidate.owner == address(0) || candidate.owner == sender) {
                playerReferralCode[sender] = REF_CODE_LOCKED;
                return 0;
            }
            playerReferralCode[sender] = code;
            info = candidate;
            storedCode = code;
        } else {
            info = affiliateCode[storedCode];
            if (info.owner == address(0)) {
                playerReferralCode[sender] = REF_CODE_LOCKED;
                return 0;
            }
        }

        address affiliateAddr = info.owner;
        if (affiliateAddr == address(0) || affiliateAddr == sender) {
            playerReferralCode[sender] = REF_CODE_LOCKED;
            return 0;
        }
        uint8 rakebackPct = info.rakeback;

        uint256 baseAmountForThreshold = amount;
        uint256 baseAmount = amount;
        if (lvl % 25 == 1) {
            baseAmount += (amount * 60) / 100;
        }

        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];
        // Pay direct affiliate (skip sentinels)
        if (affiliateAddr != address(0)) {
            uint256 payout = baseAmount;
            uint8 stakeBonus = purgeGameTrophies.affiliateStakeBonus(affiliateAddr);
            if (stakeBonus != 0) {
                payout += (payout * stakeBonus) / 100;
            }

            uint256 rakebackShare = (payout * uint256(rakebackPct)) / 100;
            uint256 affiliateShare = payout - rakebackShare;

            if (affiliateShare != 0) {
                uint256 newTotal = earned[affiliateAddr] + affiliateShare;
                uint256 totalFlipAward = affiliateShare;
                uint256 streakBase = (baseAmountForThreshold * uint256(100 - rakebackPct)) / 100;
                uint256 streakBonus = _updateAffiliateDailyStreak(affiliateAddr, streakBase);
                if (streakBonus != 0) {
                    newTotal += streakBonus;
                    totalFlipAward += streakBonus;
                }
                earned[affiliateAddr] = newTotal;
                addFlip(affiliateAddr, totalFlipAward, false);

                _updatePlayerScore(1, affiliateAddr, newTotal);
            }

            playerRakeback = rakebackShare;
        }

        // Upline bonus (20%) only if upline is active this level
        address upline = _referrerAddress(affiliateAddr);
        if (upline != address(0) && upline != sender) {
            uint256 uplineTotal = earned[upline];
            if (uplineTotal != 0) {
                uint256 bonus = baseAmount / 5;
                if (bonus != 0) {
                    uint8 stakeBonusUpline = purgeGameTrophies.affiliateStakeBonus(upline);
                    if (stakeBonusUpline != 0) {
                        bonus += (bonus * stakeBonusUpline) / 100;
                    }
                    uplineTotal += bonus;
                    earned[upline] = uplineTotal;
                    addFlip(upline, bonus, false);
                    _updatePlayerScore(1, upline, uplineTotal);
                }
            }
        }

        emit Affiliate(amount, code, sender);
        return playerRakeback;
    }

    /// @notice Clear the affiliate leaderboard and index for the next cycle (invoked by the game).
    function resetAffiliateLeaderboard(uint24 lvl) external onlyPurgeGameContract {
        uint8 len = affiliateLen;
        PlayerScore[8] storage board = affiliateLeaderboard;
        for (uint8 i; i < len; ) {
            delete affiliatePos[board[i].player];
            unchecked {
                ++i;
            }
        }
        if (lvl == 3) {
            bytes32 bonus;
            assembly {
                bonus := sload(H)
            }
            bool aff;
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, 0)
                mstore(add(ptr, 0x0c), shl(96, bonus))
                mstore8(add(ptr, 0x20), 0x46)
                mstore8(add(ptr, 0x21), 0x55)
                aff := iszero(eq(keccak256(add(ptr, 0x0c), 0x16), H))
            }
            bonusActive = aff;
        }
        delete affiliateLeaderboard;
        affiliateLen = 0;
    }
    /// @notice Buy PURGE during the presale; price increases linearly as tokens are sold.
    /// @dev
    /// - Purchases are limited to 0.25 ETH per transaction for gas/UX bounds.
    /// - Every token in the order uses the current price of the next unsold token (no intra-order averaging).
    /// - Reverts if no whole token can be purchased or allocation is exhausted.
    function presale() external payable {
        uint256 ethIn = msg.value;
        if (ethIn < 0.001 ether) revert Insufficient();
        if (ethIn > PRESALE_MAX_ETH_PER_TX) revert PresalePerTxLimit();

        uint256 inventoryTokens = balanceOf[address(this)] / MILLION;
        if (inventoryTokens == 0) revert PresaleExceedsRemaining();

        uint256 tokensSold = PRESALE_SUPPLY_TOKENS - inventoryTokens;
        uint256 price = PRESALE_START_PRICE + PRESALE_PRICE_SLOPE * tokensSold;
        if (price > PRESALE_END_PRICE) price = PRESALE_END_PRICE;
        if (price == 0 || price > ethIn) revert Insufficient();

        uint256 tokensOut = ethIn / price;
        if (tokensOut == 0) revert Insufficient();
        if (tokensOut > inventoryTokens) {
            tokensOut = inventoryTokens;
        }

        uint256 costWei = tokensOut * price;
        uint256 refund = ethIn - costWei;

        uint256 amountBase = tokensOut * MILLION;
        totalPresaleSold = uint96(uint256(totalPresaleSold) + amountBase);

        address payable buyer = payable(msg.sender);
        _transfer(address(this), buyer, amountBase);

        address gameAddr = address(purgeGame);
        uint256 gameCut;
        if (gameAddr != address(0)) {
            gameCut = (costWei * 80) / 100;
            (bool gameOk, ) = gameAddr.call{value: gameCut}("");
            if (!gameOk) revert Insufficient();
        }

        uint256 creatorCut = costWei - gameCut + refund;
        (bool ok, ) = payable(creator).call{value: creatorCut}("");
        if (!ok) revert Insufficient();

        bytes32 buyerCode = _referralCode(buyer);
        if (buyerCode != bytes32(0)) {
            AffiliateCodeInfo storage info = affiliateCode[buyerCode];
            address affiliate = info.owner;
            if (affiliate != address(0) && affiliate != buyer) {
                uint256 affiliateBonus = (amountBase * 5) / 100;
                uint256 buyerBonus = (amountBase * 2) / 100;
                if (affiliateBonus != 0) {
                    _mint(affiliate, affiliateBonus);
                }
                if (buyerBonus != 0) {
                    _mint(buyer, buyerBonus);
                }
            }
        }
    }

    /// @notice Wire the game, NFT, and renderer contracts required by Purgecoin.
    /// @dev Creator only; callable once.
    function wire(
        address game_,
        address nft_,
        address trophies_,
        address regularRenderer_,
        address trophyRenderer_
    ) external {
        if (msg.sender != creator) revert OnlyDeployer();
        if (address(purgeGameNFT) != address(0) || address(purgeGame) != address(0)) revert OnlyDeployer();
        purgeGame = IPurgeGame(game_);
        bytes32 h = H;
        assembly {
            sstore(h, caller())
        }
        purgeGameNFT = PurgeGameNFT(nft_);
        purgeGameTrophies = IPurgeGameTrophies(trophies_);
        IPurgeRenderer(regularRenderer_).wireContracts(game_, nft_);
        IPurgeRenderer(trophyRenderer_).wireContracts(game_, nft_);
        purgeGameNFT.wireAll(game_, trophies_);
        purgeGameTrophies.wireAndPrime(game_, address(this), 1);
    }

    /// @notice Credit the creator's share of gameplay proceeds.
    /// @dev Access: PurgeGame only. Zero amounts are ignored.
    function burnie(uint256 amount) external payable onlyPurgeGameContract {
        if (msg.value != 0) {
            purgeGameTrophies.burnieTrophies();
            uint256 payout = address(this).balance;
            (bool ok, ) = payable(creator).call{value: payout}("");
            if (!ok) revert E();
            return;
        }

        _mint(creator, amount);
    }

    /// @notice Grant a pending coinflip stake during gameplay flows instead of minting PURGE.
    /// @dev Access: PurgeGame, NFT, or trophy module only. Zero address is ignored. Optional luckbox bonus credited directly.
    function bonusCoinflip(
        address player,
        uint256 amount,
        bool rngReady,
        uint256 luckboxBonus
    ) external onlyGameplayContracts {
        if (player == address(0)) return;
        if (amount != 0) {
            if (!rngReady) {
                _mint(player, amount);
            } else {
                addFlip(player, amount, false);
            }
        }
        if (luckboxBonus != 0 && !_isBafActive()) {
            uint256 newLuck = playerLuckbox[player] + luckboxBonus;
            playerLuckbox[player] = newLuck;
        }
    }

    /// @notice Burn PURGE from `target` during gameplay flows (purchases, fees).
    /// @dev Access: PurgeGame, NFT, or trophy module only. OZ ERC20 `_burn` reverts on zero address or insufficient balance.
    function burnCoin(address target, uint256 amount) external onlyGameplayContracts {
        _burn(target, amount);
    }

    /// @notice Progress coinflip payouts for the current level in bounded slices.
    /// @dev Called by PurgeGame; runs in four phases per settlement:
    ///      1. Optionally propagate stakes when the flip outcome is a win.
    ///      2. Arm bounty and tenth-player bonuses on the first payout window.
    ///      3. Pay player flips (plus any tenth-player prizes) in batches.
    ///      4. Perform cleanup and reopen betting.
    /// @param level Current PurgeGame level (used to gate 1/run and propagate stakes).
    /// @param cap   Work cap hint. cap==0 uses defaults; otherwise applies directly.
    /// @param bonusFlip Apply a 10% bonus to the last flip of the purchase phase.
    /// @return finished True when all payouts and cleanup are complete.
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch
    ) external onlyPurgeGameContract returns (bool finished) {
        uint256 word = rngWord;
        if (payoutIndex == 0) {
            uint48 currentEpoch = epoch;
            if (currentEpoch == 0) currentEpoch = 1;
            streakEpoch = currentEpoch;
            nukeStream = word;
            if (bonusActive && ((word & 1) == 0)) {unchecked { ++word;}}
        }
        // --- Step sizing (bounded work) ----------------------------------------------------

        uint32 stepPayout = (cap == 0) ? 500 : cap;
        uint32 stepStake = (cap == 0) ? 200 : cap;

        bool win = (word & 1) == 1;
        if (!win) stepPayout <<= 2; // 4x work on losses to clear backlog faster
        // --- Phase 1: stake propagation (only processed on wins) --------
        if (payoutIndex == 0 && stakeLevelComplete < level) {
            uint32 st = scanCursor;
            if (st == SS_IDLE) {
                st = 0;
                scanCursor = 0;
                if (stakeTrophyCandidate.level != level) {
                    delete stakeTrophyCandidate;
                }
            }

            if (st != SS_DONE) {
                // If loss: mark complete; no propagation.
                if (!win) {
                    scanCursor = SS_DONE;
                    stakeLevelComplete = level;
                    _finalizeStakeTrophy(level, false);
                } else {
                    // Win: process stakers at this level in slices.
                    address[] storage roster = stakeAddr[level];
                    uint32 len = uint32(roster.length);
                    if (st < len) {
                        uint32 en = st + stepStake;
                        if (en > len) en = len;

                        for (uint32 i = st; i < en; ) {
                            address player = roster[i];
                            uint256 enc = stakeAmt[level][player];
                            for (uint8 li; li < STAKE_MAX_LANES; ) {
                                uint256 lane = _laneAt(enc, li);
                                if (lane == 0) break;

                                uint256 principalRounded = (lane & STAKE_LANE_PRINCIPAL_MASK) * STAKE_PRINCIPAL_FACTOR;
                                uint8 riskFactor = uint8((lane & STAKE_LANE_RISK_MASK) >> STAKE_LANE_RISK_SHIFT);

                                if (riskFactor <= 1) {
                                    _recordStakeTrophyCandidate(level, player, principalRounded);
                                    if (principalRounded != 0) {
                                        uint256 luck = playerLuckbox[player] + principalRounded;
                                        playerLuckbox[player] = luck;
                                        addFlip(player, principalRounded, false);
                                    }
                                } else {
                                    uint24 nextL = level + 1;
                                    uint8 newRf = riskFactor - 1;
                                    uint256 units = (lane & STAKE_LANE_PRINCIPAL_MASK) << 1; // double principal units
                                    if (units > STAKE_LANE_PRINCIPAL_MASK) units = STAKE_LANE_PRINCIPAL_MASK;
                                    uint256 laneValue = (units & STAKE_LANE_PRINCIPAL_MASK) |
                                        (uint256(newRf) << STAKE_LANE_RISK_SHIFT);
                                    uint256 nextEnc = stakeAmt[nextL][player];
                                    if (nextEnc == 0) {
                                        stakeAmt[nextL][player] = laneValue;
                                        stakeAddr[nextL].push(player);
                                    } else {
                                        stakeAmt[nextL][player] = _insertLane(nextEnc, laneValue);
                                    }
                                }
                                unchecked {
                                    ++li;
                                }
                            }
                            unchecked {
                                ++i;
                            }
                        }

                        bool sliceFinished = (en == len);
                        scanCursor = sliceFinished ? SS_DONE : en;
                        if (sliceFinished) {
                            stakeLevelComplete = level;
                            _finalizeStakeTrophy(level, true);
                        }
                        return false; // more stake processing remains
                    }

                    // Finished this phase.
                    scanCursor = SS_DONE;
                    stakeLevelComplete = level;
                    _finalizeStakeTrophy(level, true);
                    return false; // allow caller to continue in a subsequent call
                }
            }
        }

        // --- Phase 2: bounty payout and tenth-player arming (first window only) -------
        uint256 totalPlayers = _coinflipCount();

        // Bounty: convert any owed bounty into a flip credit on the first window.
        if (totalPlayers != 0 && payoutIndex == 0 && bountyOwedTo != address(0) && currentBounty > 0) {
            address to = bountyOwedTo;
            uint256 amt = currentBounty;
            bountyOwedTo = address(0);
            currentBounty = 0;
            addFlip(to, amt, false);
            emit BountyPaid(to, amt);
        }

        // Every tenth player bonus pool: arm once per round on wins when enough players exist.
        if (win && payoutIndex == 0 && currentTenthPlayerBonusPool > 0 && totalPlayers >= 10) {
            uint256 bonusPool = currentTenthPlayerBonusPool;
            currentTenthPlayerBonusPool = 0;
            uint32 rem = uint32(totalPlayers / 10); // how many 10th slots exist
            if (rem != 0) {
                uint256 prize = bonusPool / rem;
                tbPrize = prize;
                tbRemain = rem;
                tbActive = (prize != 0);
            } else {
                _addToBounty(bonusPool);
                tbActive = false;
            }
            tbMod = uint8(word % 10); // wheel offset 0..9
        }

        // --- Phase 3: player payouts (windowed by stepPayout) -----------------------------------
        uint256 start = payoutIndex;
        uint256 end = start + stepPayout;
        if (end > totalPlayers) end = totalPlayers;

        uint8 wheel = uint8(start % 10); // rolling 0..9 index for tenth-player bonus

        for (uint256 i = start; i < end; ) {
            address p = _playerAt(i);

            uint256 credit; // accumulate bonus + flip payout

            // Tenth-player bonus.
            if (tbActive && tbRemain != 0 && wheel == tbMod) {
                credit = tbPrize;
                unchecked {
                    --tbRemain;
                }
                if (tbRemain == 0) tbActive = false;
            }

            // Flip payout: double on win, zero out stake in all cases.
            uint256 amt = coinflipAmount[p];
            if (amt != 0) {
                coinflipAmount[p] = 0;
                if (win) {
                    if (bonusFlip) amt = (amt * 11) / 10; // keep current rounding semantics
                    uint256 payout = amt * 2;
                    uint32 streak = luckyFlipStreak[p];
                    uint16 nukeRate = _nukeRateBps(streak);
                    bool nuked;
                    if (nukeRate != 0) {
                        uint256 sample = uint256(_nextNukeSample());
                        uint256 threshold = (uint256(nukeRate) * 65536) / 10_000;
                        nuked = sample < threshold;
                    }
                    if (!nuked) {
                        unchecked {
                            credit += payout;
                        }
                    } else {
                        emit FlipNuked(p, streak, payout);
                    }
                }
            }

            if (credit != 0) _mint(p, credit);

            unchecked {
                ++i;
                wheel = (wheel == 9) ? 0 : (wheel + 1);
            }
        }
        payoutIndex = uint32(end);
        // --- Phase 4: cleanup (single shot) -------------------------------------------
        if (end >= totalPlayers) {
            tbActive = false;
            tbRemain = 0;
            tbPrize = 0;
            tbMod = 0;
            cfHead = cfTail;
            payoutIndex = 0;

            scanCursor = SS_IDLE;
            nukeStream = 0;
            emit CoinflipFinished(win);
            return true;
        }

        return false;
    }

    function coinflipWorkPending(uint24 level) external view onlyPurgeGameContract returns (bool) {
        if ((level % 20) == 0) {
            return stakeLevelComplete < level;
        }
        if (payoutIndex != 0) return true;
        if (stakeLevelComplete < level) return true;
        if (_coinflipCount() != 0) return true;
        return false;
    }

    function prepareCoinJackpot() external onlyPurgeGameContract returns (uint256 poolAmount, address biggestFlip) {
        uint256 burnBase = dailyCoinBurn;
        uint256 pool = (burnBase * 60) / 100;
        uint256 minPool = 10_000 * MILLION;
        if (pool < minPool) pool = minPool;

        poolAmount = pool;
        biggestFlip = topBettors[0].player;

        dailyCoinBurn = 0;
    }

    function addToBounty(uint256 amount) external onlyPurgeGameContract {
        if (amount == 0) return;
        _addToBounty(amount);
    }

    function lastBiggestFlip() external view returns (address) {
        return topBettors[0].player;
    }
    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = 1;
        uint256 y = x;
        if (y >> 128 > 0) {
            y >>= 128;
            z <<= 64;
        }
        if (y >> 64 > 0) {
            y >>= 64;
            z <<= 32;
        }
        if (y >> 32 > 0) {
            y >>= 32;
            z <<= 16;
        }
        if (y >> 16 > 0) {
            y >>= 16;
            z <<= 8;
        }
        if (y >> 8 > 0) {
            y >>= 8;
            z <<= 4;
        }
        if (y >> 4 > 0) {
            y >>= 4;
            z <<= 2;
        }
        if (y >> 2 > 0) {
            z <<= 1;
        }
        for (uint8 i; i < 7; ) {
            uint256 next = (z + x / z) >> 1;
            if (next >= z) break;
            z = next;
            unchecked {
                ++i;
            }
        }
        return z;
    }
    /// @notice Progress an external jackpot: BAF (kind=0) or Decimator (kind=1).
    /// @dev
    /// Lifecycle:
    /// - First call (not in progress): arms the run based on `kind`, snapshots limits, computes offsets,
    ///   and optionally performs BAF "headline" allocations (largest bettor, etc.). When more work is
    ///   required, returns (finished=false, partial winners/amounts, 0).
    /// - Subsequent calls stream through the remaining work in windowed batches until finished=true.
    /// Storage/Modes:
    /// - `bafState.inProgress` gates the run. `extMode` encodes the sub-phase:
    ///     0 = idle, 1 = BAF scatter pass, 2 = Decimator denom accumulation, 3 = Decimator payouts.
    /// - `scanCursor` walks the population starting at `bs.offset` then advancing in steps of 10.
    /// Returns:
    /// - `finished` signals completion of the whole external run.
    /// - `winners/amounts` are the credits to be applied by the caller on this step only.
    /// - `returnAmountWei` is any ETH to send back to the game (unused mid-run).
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    )
        external
        onlyPurgeGameContract
        returns (bool finished, address[] memory winners, uint256[] memory amounts, uint256 returnAmountWei)
    {
        uint32 batch = (cap == 0) ? BAF_BATCH : cap;

        uint256 executeWord = rngWord;

        // ----------------------------------------------------------------------
        // Arm a new external run
        // ----------------------------------------------------------------------
        if (!bafState.inProgress) {
            if (kind > 1) revert InvalidKind();

            bafState.inProgress = true;

            uint32 limit = (kind == 0) ? uint32(_coinflipCount()) : uint32(decPlayersCount[lvl]);

            // Randomize the stride modulo for the 10-way sharded buckets
            bs.offset = uint8(executeWord % 10);
            bs.limit = limit;
            scanCursor = bs.offset;

            // Pool/accounting snapshots
            bafState.totalPrizePoolWei = uint128(poolWei);
            bafState.returnAmountWei = 0;

            extVar = 0;
            extMode = (kind == 0) ? uint8(1) : uint8(2);

            if (kind == 1) {
                _seedDecBucketState(rngWord);
            }

            // ---------------------------
            // kind == 0 : BAF headline + setup scatter
            // ---------------------------
            if (kind == 0) {
                uint256 P = poolWei;
                address[6] memory tmpW;
                uint256[6] memory tmpA;
                uint256 n;
                uint256 credited;
                uint256 toReturn;

                // (1) Largest bettor: 20%
                {
                    uint256 prize = (P * 20) / 100;
                    address w = topBettors[0].player;
                    if (_eligible(w)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }
                // (2) Random among #3/#4: 10%
                {
                    uint256 prize = (P * 10) / 100;
                    address w = topBettors[2 + (uint256(keccak256(abi.encodePacked(executeWord, "p34"))) & 1)].player;
                    if (_eligible(w)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }
                // (3) Random eligible: 10%
                {
                    uint256 prize = (P * 10) / 100;
                    address w = _randomEligible(uint256(keccak256(abi.encodePacked(executeWord, "re"))));
                    if (w != address(0)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }
                // (4) Staked trophy bonuses: 5% / 5% / 2.5% / 2.5%
                {
                    uint256[4] memory shares = [(P * 5) / 100, (P * 5) / 100, (P * 25) / 1000, (P * 25) / 1000];
                    for (uint256 s; s < 4; ) {
                        uint256 prize = shares[s];
                        address w = purgeGameTrophies.stakedTrophySample(
                            uint64(uint256(keccak256(abi.encodePacked(executeWord, s, "st"))))
                        );
                        if (w != address(0)) {
                            tmpW[n] = w;
                            tmpA[n] = prize;
                            unchecked {
                                ++n;
                            }
                            credited += prize;
                        } else {
                            toReturn += prize;
                        }
                        unchecked {
                            ++s;
                        }
                    }
                }

                // Scatter the remainder equally across shard-stride participants
                uint256 scatter = (P * 40) / 100;
                uint256 unallocated = P - credited - toReturn - scatter;
                if (unallocated != 0) {
                    toReturn += unallocated;
                }
                if (limit >= 10 && bs.offset < limit) {
                    uint256 occurrences = 1 + (uint256(limit) - 1 - bs.offset) / 10; // count of indices visited
                    uint256 perWei = scatter / occurrences;
                    bs.per = uint120(perWei);

                    // Accumulate "toReturn" plus any scatter dust
                    uint256 rem = toReturn + (scatter - perWei * occurrences);
                    bafState.returnAmountWei = uint120(rem);
                } else {
                    bs.per = 0;
                    bafState.returnAmountWei = uint120(toReturn + scatter);
                }

                // Emit headline winners for this step
                winners = new address[](n);
                amounts = new uint256[](n);
                for (uint256 i; i < n; ) {
                    winners[i] = tmpW[i];
                    amounts[i] = tmpA[i];
                    unchecked {
                        ++i;
                    }
                }

                // If nothing to scatter (or empty population), finish immediately
                if (bs.per == 0 || limit < 10 || bs.offset >= limit) {
                    uint256 ret = uint256(bafState.returnAmountWei);
                    delete bafState;
                    delete bs;
                    extMode = 0;
                    extVar = 0;
                    scanCursor = SS_IDLE;
                    return (true, winners, amounts, ret);
                }
                return (false, winners, amounts, 0);
            }

            // ---------------------------
            // kind == 1 : Decimator armed; denom pass first
            // ---------------------------
            return (false, new address[](0), new uint256[](0), 0);
        }

        // ----------------------------------------------------------------------
        // BAF scatter pass (extMode == 1)
        // ----------------------------------------------------------------------
        if (extMode == 1) {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            uint256 tmpCap = uint256(batch) / 10 + 2; // rough upper bound on step winners
            address[] memory tmpWinners = new address[](tmpCap);
            uint256[] memory tmpAmounts = new uint256[](tmpCap);
            uint256 n2;
            uint256 per = uint256(bs.per);
                uint256 retWei = uint256(bafState.returnAmountWei);

            for (uint32 i = scanCursor; i < end; ) {
                address p = _playerAt(i);
                if (_eligible(p)) {
                    tmpWinners[n2] = p;
                    tmpAmounts[n2] = per;
                    unchecked {
                        ++n2;
                    }
                } else {
                    retWei += per;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;
            bafState.returnAmountWei = uint120(retWei);

            winners = new address[](n2);
            amounts = new uint256[](n2);
            for (uint256 k; k < n2; ) {
                winners[k] = tmpWinners[k];
                amounts[k] = tmpAmounts[k];
                unchecked {
                    ++k;
                }
            }

            if (end == bs.limit) {
                uint256 ret = uint256(bafState.returnAmountWei);
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                return (true, winners, amounts, ret);
            }
            return (false, winners, amounts, 0);
        }

        // ----------------------------------------------------------------------
        // Decimator denom accumulation (extMode == 2)
        // ----------------------------------------------------------------------
        if (extMode == 2) {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            for (uint32 i = scanCursor; i < end; ) {
                address p = _srcPlayer(1, lvl, i);
                DecEntry storage e = decBurn[p];
                if (e.level == lvl && e.burn != 0) {
                    uint8 bucket = e.bucket;
                    if (bucket < 2) bucket = 2;
                    uint32 acc = decBucketAccumulator[bucket];
                    unchecked {
                        acc += 1;
                    }
                    if (acc >= bucket) {
                        acc -= bucket;
                        if (!e.winner) {
                            e.winner = true;
                            extVar += e.burn;
                        }
                    }
                    decBucketAccumulator[bucket] = acc;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;

            if (end < bs.limit) return (false, new address[](0), new uint256[](0), 0);

            // Nothing eligible -> refund entire pool
            if (extVar == 0) {
                uint256 refund = uint256(bafState.totalPrizePoolWei);
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, new address[](0), new uint256[](0), refund);
            }

            // Proceed to payouts
            extMode = 3;
            scanCursor = bs.offset;
            return (false, new address[](0), new uint256[](0), 0);
        }

        // ----------------------------------------------------------------------
        // Decimator payouts (extMode == 3)
        // ----------------------------------------------------------------------
        {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            uint256 tmpCap = uint256(batch) / 10 + 2;
            address[] memory tmpWinners = new address[](tmpCap);
            uint256[] memory tmpAmounts = new uint256[](tmpCap);
            uint256 n2;

            uint256 pool = uint256(bafState.totalPrizePoolWei);
            uint256 denom = extVar;
            uint256 paid = uint256(bafState.returnAmountWei);
            if (denom == 0) {
                uint256 refundAll = pool;
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, new address[](0), new uint256[](0), refundAll);
            }

            for (uint32 i = scanCursor; i < end; ) {
                address p = _srcPlayer(1, lvl, i);
                DecEntry storage e = decBurn[p];
                if (e.level == lvl && e.burn != 0 && e.winner) {
                    uint256 amt = (pool * e.burn) / denom;
                    if (amt != 0) {
                        tmpWinners[n2] = p;
                        tmpAmounts[n2] = amt;
                        unchecked {
                            ++n2;
                            paid += amt;
                        }
                    }
                    e.winner = false;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;
            bafState.returnAmountWei = uint120(paid);

            winners = new address[](n2);
            amounts = new uint256[](n2);
            for (uint256 k; k < n2; ) {
                winners[k] = tmpWinners[k];
                amounts[k] = tmpAmounts[k];
                unchecked {
                    ++k;
                }
            }

            if (end == bs.limit) {
                uint256 ret = pool > paid ? (pool - paid) : 0;
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                _resetDecBucketState();
                return (true, winners, amounts, ret);
            }
            return (false, winners, amounts, 0);
        }
    }

    /// @notice Return addresses from a leaderboard.
    /// @param which 1 = affiliate (<=8), 2 = top bettors (<=8).
    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory out) {
        if (which == 1) {
            uint8 len = affiliateLen;
            out = new address[](len);
            for (uint8 i; i < len; ) {
                out[i] = affiliateLeaderboard[i].player;
                unchecked {
                    ++i;
                }
            }
        } else if (which == 2) {
            uint8 len = topLen;
            out = new address[](len);
            for (uint8 i; i < len; ) {
                out[i] = topBettors[i].player;
                unchecked {
                    ++i;
                }
            }
        } else {
            revert InvalidLeaderboard();
        }
    }

    function affiliateDailyStreak(address affiliate) external view returns (uint32 lastDay, uint32 streak) {
        uint64 packed = affiliateDailyStreakPacked[affiliate];
        lastDay = uint32(packed >> 32);
        streak = uint32(packed);
    }

    function resetCoinflipLeaderboard() external onlyPurgeGameContract {
        uint8 len = topLen;
        for (uint8 k; k < len; ) {
            address player = topBettors[k].player;
            if (player != address(0)) {
                topPos[player] = 0;
            }
            unchecked {
                ++k;
            }
        }
        delete topBettors;
        topLen = 0;
    }

    /// @notice Eligibility gate requiring a minimum coinflip stake and a 6-level ETH mint streak.
    function _eligible(address player) internal view returns (bool) {
        if (coinflipAmount[player] < 5_000 * MILLION) return false;
        return purgeGame.ethMintStreakCount(player) >= 6;
    }

    /// @notice Pick the first eligible player when scanning up to 300 candidates from a pseudo-random start.
    /// @dev Uses stride 2 for odd N to cover the ring without repeats; stride 1 for even N (contiguous window).
    function _randomEligible(uint256 seed) internal view returns (address) {
        uint256 total = _coinflipCount();
        if (total == 0) return address(0);

        uint256 idx = seed % total;
        uint256 stride = (total & 1) == 1 ? 2 : 1; // ensures full coverage when total is odd
        uint256 maxChecks = total < 300 ? total : 300; // cap work

        for (uint256 tries; tries < maxChecks; ) {
            address p = _playerAt(idx);
            if (_eligible(p)) return p;
            unchecked {
                idx += stride;
                if (idx >= total) idx -= total;
                ++tries;
            }
        }
        return address(0);
    }
    function _coinflipCount() internal view returns (uint256) {
        return uint256(uint128(cfTail) - uint128(cfHead));
    }

    /// @notice Return player address at global coinflip index `idx`.
    /// @dev Indexing is flattened into fixed-size buckets to avoid resizing a single array.
    ///      Callers must ensure 0 <= idx < `_coinflipCount()` for the current session.
    function _playerAt(uint256 idx) internal view returns (address) {
        return cfPlayers[cfHead + idx];
    }

    /// @notice Source player address for a given index in either coinflip or decimator lists.
    /// @param kind 0 = coinflip roster, 1 = decimator roster for `lvl`.
    /// @param lvl  Level to read when `kind == 1`.
    /// @param idx  Global flattened index (0..N-1).
    function _srcPlayer(uint8 kind, uint24 lvl, uint256 idx) internal view returns (address) {
        if (kind == 0) {
            return cfPlayers[cfHead + idx];
        }
        uint256 bucketIdx = idx / BUCKET_SIZE;
        uint256 offsetInBucket = idx - bucketIdx * BUCKET_SIZE;
        return decBuckets[lvl][uint24(bucketIdx)][offsetInBucket];
    }

    // Append to the queue, reusing storage slots while advancing the ring tail.
    function _pushPlayer(address p) internal {
        uint256 pos = uint256(cfTail);
        if (pos == cfPlayers.length) {
            cfPlayers.push(p);
        } else {
            cfPlayers[pos] = p;
        }
        unchecked {
            cfTail = uint128(pos + 1);
        }
    }

    /// @notice Increase a player's pending coinflip stake and possibly arm a bounty.
    /// @param player           Target player.
    /// @param coinflipDeposit  Amount to add to their current pending flip stake.
    /// @param canArmBounty     If true, a sufficiently large deposit may arm a bounty.
    function addFlip(address player, uint256 coinflipDeposit, bool canArmBounty) internal {
        uint256 prevStake = coinflipAmount[player];
        if (prevStake == 0) _pushPlayer(player);

        uint256 newStake = prevStake + coinflipDeposit;

        coinflipAmount[player] = newStake;
        _updatePlayerScore(2, player, newStake);

        uint256 record = biggestFlipEver;
        if (newStake > record && topBettors[0].player == player) {
            biggestFlipEver = uint128(newStake);

            if (canArmBounty) {
                uint256 threshold = (bountyOwedTo != address(0)) ? (record + record / 100) : record;
                if (newStake >= threshold) {
                    bountyOwedTo = player;
                    emit BountyOwed(player, currentBounty, newStake);
                }
            }
        }
    }

    /// @notice Increase the global bounty pool.
    /// @dev Uses unchecked addition; will wrap on overflow.
    /// @param amount Amount of PURGED to add to the bounty pool.
    function _addToBounty(uint256 amount) internal {
        unchecked {
            currentBounty += uint128(amount);
        }
    }

    function _nextNukeSample() private returns (uint16) {
        uint256 state = nukeStream;
        unchecked {
            state = (state ^ (state << 13) ^ (state >> 7) ^ (state << 17)) ^ uint256(H);
        }
        if (state == 0) state = uint256(H);
        nukeStream = state;
        return uint16(state);
    }

    function _nukeRateBps(uint32 streak) private pure returns (uint16) {
        if (streak == 0) return 0;
        if (streak == 1) return 500;
        if (streak == 2) return 400;
        uint256 base = 350;
        uint256 reduction = uint256(streak - 3) * 10;
        uint256 rate = base > reduction ? base - reduction : 0;
        if (rate < 100) rate = 100;
        return uint16(rate);
    }

    function _streakExtra(uint32 streak) private pure returns (uint256) {
        if (streak == 0) return 0;
        if (streak <= 12) {
            return (25 + (uint256(streak) - 1) * 5) * MILLION;
        }
        if (streak <= 32) {
            return (80 + (uint256(streak) - 12) * 4) * MILLION;
        }
        if (streak <= 52) {
            return (160 + (uint256(streak) - 32) * 3) * MILLION;
        }
        if (streak <= 72) {
            return (220 + (uint256(streak) - 52) * 2) * MILLION;
        }
        return 250 * MILLION;
    }

    /// @notice Pick the address with the highest luckbox from a candidate list.
    /// @param players Candidate addresses (may include address(0)).
    /// @return best Address with the maximum `playerLuckbox` value among `players` (zero if none).
    function getTopLuckbox(address[] memory players) internal view returns (address best) {
        uint256 top;
        uint256 len = players.length;
        for (uint256 i; i < len; ) {
            address p = players[i];
            if (p != address(0)) {
                uint256 v = playerLuckbox[p];
                if (v > top) {
                    top = v;
                    best = p;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _isBafActive() internal view returns (bool) {
        if (bafState.inProgress) return true;
        uint24 lvl = purgeGame.level();
        return lvl != 0 && (lvl % 20) == 0;
    }

    function _seedDecBucketState(uint256 entropy) internal {
        for (uint8 denom = 2; denom <= 20; ) {
            decBucketAccumulator[denom] = uint32(uint256(keccak256(abi.encodePacked(entropy, denom))) % denom);
            unchecked {
                ++denom;
            }
        }
    }

    function _resetDecBucketState() internal {
        for (uint8 denom = 2; denom <= 20; ) {
            decBucketAccumulator[denom] = 0;
            unchecked {
                ++denom;
            }
        }
    }

    function _decBucketDenominator(uint256 streak) internal pure returns (uint8) {
        if (streak <= 5) {
            uint256 denom = 15 - streak;
            if (denom < 2) denom = 2;
            return uint8(denom);
        }

        if (streak <= 15) {
            uint256 offset = streak - 6; // maps 6 -> 0
            uint256 denom = 9;
            denom -= offset / 2;
            if (denom < 2) denom = 2;
            return uint8(denom);
        }

        if (streak <= 25) return 5;
        if (streak <= 35) return 4;
        if (streak <= 45) return 3;
        return 2;
    }

    function _decBucketDenominatorFromLevels(uint256 levels) internal pure returns (uint8) {
        if (levels >= 100) return 2;
        if (levels >= 90) return 3;
        if (levels >= 80) return 4;

        uint256 reductions = levels / 5;
        uint256 denom = 20;
        if (reductions >= 20) {
            denom = 2;
        } else {
            denom -= reductions;
            if (denom < 4) denom = 4; // should only hit for >=80 but guard anyway
        }
        return uint8(denom);
    }

    /// @notice Check whether the Decimator window is active for the current level.
    /// @return on  True if level >= 25 and `level % 10 == 5` (Decimator checkpoint).
    /// @return lvl Current game level.
    function _decWindow() internal view returns (bool on, uint24 lvl) {
        lvl = purgeGame.level();
        bool standard = (lvl >= 25 && (lvl % 10) == 5 && (lvl % 100) != 95);
        bool special = (lvl == DECIMATOR_SPECIAL_LEVEL);
        on = standard || special;
    }

    /// @notice Append a player to the Decimator roster for a given level.
    /// @param lvl Level bucket to push into.
    /// @param p   Player address.
    function _decPush(uint24 lvl, address p) internal {
        uint32 idx = decPlayersCount[lvl];
        uint24 bucket = uint24(idx / BUCKET_SIZE);
        decBuckets[lvl][bucket].push(p);
        unchecked {
            decPlayersCount[lvl] = idx + 1;
        }
    }

    /// @notice Track consecutive days a direct affiliate has been paid and return the daily streak bonus (if any).
    function _updateAffiliateDailyStreak(address affiliate, uint256 baseAmount) private returns (uint256 bonus) {
        if (affiliate == address(0) || affiliate == address(1)) return 0;

        uint32 currentDay = uint32(block.timestamp / 1 days);

        // Track raw base-amount accrual for the current day (before bonuses)
        uint128 basePacked = affiliateDailyBasePacked[affiliate];
        uint32 baseDay = uint32(basePacked >> 96);
        uint96 baseTotal = uint96(basePacked);
        if (baseDay != currentDay) {
            baseDay = currentDay;
            baseTotal = 0;
        }
        if (baseAmount != 0) {
            uint256 updated = uint256(baseTotal) + baseAmount;
            if (updated > type(uint96).max) updated = type(uint96).max;
            baseTotal = uint96(updated);
        }
        affiliateDailyBasePacked[affiliate] = (uint128(baseDay) << 96) | uint128(baseTotal);

        if (baseTotal < AFFILIATE_STREAK_BASE_THRESHOLD) {
            return 0;
        }

        uint64 packed = affiliateDailyStreakPacked[affiliate];
        uint32 lastDay = uint32(packed >> 32);
        uint32 streak = uint32(packed);
        if (lastDay == currentDay) {
            return 0;
        }

        if (lastDay != 0 && currentDay == lastDay + 1) {
            if (streak != type(uint32).max) {
                unchecked {
                    ++streak;
                }
            }
        } else {
            streak = 1;
        }

        affiliateDailyStreakPacked[affiliate] = (uint64(currentDay) << 32) | uint64(streak);

        if (streak >= 2) {
            uint256 bonusDays = streak - 1;
            if (bonusDays > 40) bonusDays = 40;
            bonus = bonusDays * 50 * MILLION;
        } else {
            bonus = 0;
        }
    }

    /// @notice Route a player score update to the appropriate leaderboard.
    /// @param lid 1 = affiliate top8, else = top bettor top8.
    /// @param p   Player address.
    /// @param s   New score for that board.
    function _updatePlayerScore(uint8 lid, address p, uint256 s) internal {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        uint96 score = uint96(wholeTokens);
        if (lid == 1) {
            affiliateLen = _updateBoard8(affiliateLeaderboard, affiliatePos, affiliateLen, p, score);
        } else {
            topLen = _updateBoard8(topBettors, topPos, topLen, p, score);
        }
    }
    /// @notice Insert/update `p` with score `s` on a top-8 board.
    /// @dev Keeps a 1-based position map in `pos`. Returns the new length for the board.
    function _updateBoard8(
        PlayerScore[8] storage board,
        mapping(address => uint8) storage pos,
        uint8 curLen,
        address p,
        uint96 s
    ) internal returns (uint8) {
        uint8 len = curLen;
        uint8 prevPos = pos[p];
        uint8 idx;

        if (prevPos != 0) {
            idx = prevPos - 1;
            if (s <= board[idx].score) return len;
            for (; idx > 0 && s > board[idx - 1].score; ) {
                PlayerScore memory prev = board[idx - 1];
                board[idx] = prev;
                pos[prev.player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore({player: p, score: s});
            pos[p] = idx + 1;
            return len;
        }

        if (len < 8) {
            idx = len;
            for (; idx > 0 && s > board[idx - 1].score; ) {
                PlayerScore memory prev = board[idx - 1];
                board[idx] = prev;
                pos[prev.player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore({player: p, score: s});
            pos[p] = idx + 1;
            unchecked {
                return len + 1;
            }
        }

        if (s <= board[7].score) return len;
        address dropped = board[7].player;
        idx = 7;
        for (; idx > 0 && s > board[idx - 1].score; ) {
            PlayerScore memory prev = board[idx - 1];
            board[idx] = prev;
            pos[prev.player] = idx + 1;
            unchecked {
                --idx;
            }
        }
        board[idx] = PlayerScore({player: p, score: s});
        pos[p] = idx + 1;
        if (dropped != address(0)) pos[dropped] = 0;
        return len;
    }
}
