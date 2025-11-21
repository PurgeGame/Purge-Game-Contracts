// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameNFT} from "./PurgeGameNFT.sol";
import {IPurgeGameTrophies, PURGE_TROPHY_KIND_STAKE} from "./PurgeGameTrophies.sol";
import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeRenderer} from "./interfaces/IPurgeRenderer.sol";
import {IPurgeQuestModule, QuestInfo} from "./interfaces/IPurgeQuestModule.sol";
import {IPurgeCoinExternalJackpotModule} from "./interfaces/IPurgeCoinExternalJackpotModule.sol";
import {PurgeCoinStorage} from "./storage/PurgeCoinStorage.sol";

contract Purgecoin is PurgeCoinStorage {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event StakeCreated(address indexed player, uint24 targetLevel, uint8 risk, uint256 principal);
    event CoinflipDeposit(address indexed player, uint256 creditedFlip);
    event DecimatorBurn(address indexed player, uint256 amountBurned, uint8 bucket);
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);
    event CoinflipFinished(bool result);
    event BountyOwed(address indexed to, uint256 bountyAmount, uint256 newRecordFlip);
    event BountyPaid(address indexed to, uint256 amount);
    event DailyQuestRolled(uint48 indexed day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);
    event QuestCompleted(address indexed player, uint8 questType, uint32 streak, uint256 reward, bool hardMode);

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
    uint8 public constant decimals = 6;

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
            uint256 newAllowance = allowed - amount;
            allowance[from][msg.sender] = newAllowance;
            emit Approval(from, msg.sender, newAllowance);
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
    // Constants (units & limits)
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6; // token has 6 decimals
    uint256 private constant MIN = 100 * MILLION; // min burn / min flip (100 PURGED)
    uint8 private constant MAX_RISK = 11; // staking risk 1..11
    uint128 private constant ONEK = 1_000_000_000; // 1,000 PURGED (6d)
    uint32 private constant BAF_BATCH = 5000;
    uint256 private constant BUCKET_SIZE = 1500;
    uint16 private constant COINFLIP_EXTRA_MIN_PERCENT = 80;
    uint16 private constant COINFLIP_EXTRA_RANGE = 35;
    uint16 private constant BPS_DENOMINATOR = 10_000;
    uint32 private constant QUEST_TIER_BONUS_SPAN = 7;
    uint8 private constant QUEST_TIER_BONUS_MAX = 10;
    uint16 private constant QUEST_TIER_BONUS_BPS_PER_TIER = 20;
    bytes32 private constant H = 0x9aeceb0bff1d88815fac67760a5261a814d06dfaedc391fdf4cf62afac3f10b5;
    uint8 private constant STAKE_MAX_LANES = 3;
    uint256 private constant STAKE_LANE_BITS = 86;
    uint256 private constant STAKE_LANE_MASK = (uint256(1) << STAKE_LANE_BITS) - 1;
    uint256 private constant STAKE_LANE_RISK_BITS = 8;
    uint256 private constant STAKE_LANE_PRINCIPAL_BITS = STAKE_LANE_BITS - STAKE_LANE_RISK_BITS;
    uint256 private constant STAKE_LANE_PRINCIPAL_MASK = (uint256(1) << STAKE_LANE_PRINCIPAL_BITS) - 1;
    uint256 private constant STAKE_LANE_RISK_SHIFT = STAKE_LANE_PRINCIPAL_BITS;
    uint256 private constant STAKE_LANE_RISK_MASK = ((uint256(1) << STAKE_LANE_RISK_BITS) - 1) << STAKE_LANE_RISK_SHIFT;
    uint256 private constant STAKE_PRINCIPAL_FACTOR = MILLION;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant PRESALE_SUPPLY_TOKENS = 4_000_000;
    uint256 private constant PRESALE_START_PRICE = 0.000012 ether;
    uint256 private constant PRESALE_END_PRICE = 0.000018 ether;
    uint256 private constant PRESALE_PRICE_SLOPE = (PRESALE_END_PRICE - PRESALE_START_PRICE) / PRESALE_SUPPLY_TOKENS;
    uint256 private constant PRESALE_MAX_ETH_PER_TX = 0.25 ether;
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

    receive() external payable {}

    /// @notice Burn PURGE to increase the caller’s coinflip stake, applying streak bonuses when eligible.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum.
    function depositCoinflip(uint256 amount) external {
        if (purgeGame.rngLocked()) revert BettingPaused();
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;

        _burn(caller, amount);

        IPurgeQuestModule module = questModule;
        uint256 questReward;
        if (address(module) != address(0)) {
            (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleFlip(
                caller,
                amount
            );
            questReward = _questApplyReward(caller, reward, hardMode, questType, streak, completed);
        }

        uint256 creditedFlip = amount + questReward;
        addFlip(caller, creditedFlip, true, true, false);

        uint256 luckboxBalance = playerLuckbox[caller];
        PlayerScore storage record = biggestLuckbox;
        uint256 wholeCoins = luckboxBalance / MILLION;
        if (wholeCoins > uint256(record.score)) {
            record.player = caller;
            uint256 clamped = wholeCoins;
            if (clamped > type(uint96).max) clamped = type(uint96).max;
            record.score = uint96(clamped);
        }

        emit CoinflipDeposit(caller, amount);
    }

    /// @notice Burn PURGE during an active Decimator window to accrue weighted participation.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum.
    function decimatorBurn(uint256 amount) external {
        (bool decOn, uint24 lvl) = _decWindow();
        if (purgeGame.rngLocked()) revert BettingPaused();
        if (!decOn) revert NotDecimatorWindow();
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;
        _burn(caller, amount);

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

        IPurgeQuestModule module = questModule;
        if (address(module) != address(0)) {
            (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleDecimator(
                caller,
                amount
            );
            uint256 questReward = _questApplyReward(caller, reward, hardMode, questType, streak, completed);
            if (questReward != 0) {
                addFlip(caller, questReward, false, false, false);
            }
        }

        emit DecimatorBurn(caller, amount, e.bucket);
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
            uint256 dataWord = (uint256(0xFFFF) << 152) |
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
        if (purgeGame.rngLocked()) revert BettingPaused();
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

        if (playerLuckbox[sender] == 0) {
            playerLuckbox[sender] = 1;
        }

        // Burn principal
        _burn(sender, burnAmt);

        // Base credit and compounded boost factors
        uint256 cappedDist = distance > 200 ? 200 : distance;
        uint256 levelBps = 100 + cappedDist;
        uint256 riskBps = 12 * uint256(risk - 1);
        uint256 stepBps = levelBps + riskBps; // per-level growth in bps
        if (stepBps > 250) {
            stepBps = 250;
        }

        uint256 boostedPrincipal = burnAmt;
        if (distance != 0) {
            uint256 factor = 10_000 + stepBps;
            uint24 remaining = distance;

            while (remaining >= 4) {
                boostedPrincipal = (boostedPrincipal * factor) / 10_000;
                boostedPrincipal = (boostedPrincipal * factor) / 10_000;
                boostedPrincipal = (boostedPrincipal * factor) / 10_000;
                boostedPrincipal = (boostedPrincipal * factor) / 10_000;
                unchecked {
                    remaining -= 4;
                }
            }

            while (remaining != 0) {
                boostedPrincipal = (boostedPrincipal * factor) / 10_000;
                unchecked {
                    --remaining;
                }
            }
        }

        if (currLevel == 1 && stakeGameState == 1) {
            boostedPrincipal = distance >= 10 ? (boostedPrincipal * 3) / 2 : (boostedPrincipal * 6) / 5;
        }

        uint8 stakeTrophyBoost = purgeGameTrophies.stakeTrophyBonus(sender);
        if (stakeTrophyBoost != 0) {
            boostedPrincipal += (boostedPrincipal * stakeTrophyBoost) / 100;
        }

        // Encode and place the stake lane
        uint256 principalRounded = boostedPrincipal - (boostedPrincipal % STAKE_PRINCIPAL_FACTOR);
        if (principalRounded == 0) principalRounded = STAKE_PRINCIPAL_FACTOR;
        IPurgeQuestModule module = questModule;
        if (address(module) != address(0)) {
            (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleStake(
                sender,
                principalRounded,
                distance,
                risk
            );
            uint256 questReward = _questApplyReward(sender, reward, hardMode, questType, streak, completed);
            if (questReward != 0) {
                uint256 bonus = questReward - (questReward % STAKE_PRINCIPAL_FACTOR);
                if (bonus != 0) {
                    uint256 updated = principalRounded + bonus;
                    principalRounded = updated;
                }
            }
        }

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
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl
    ) external onlyGameplayContracts returns (uint256 playerRakeback) {
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

        uint256 baseAmount = amount;
        if (lvl % 25 == 1) {
            baseAmount += (amount * 60) / 100;
        }

        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];
        IPurgeQuestModule module = questModule;
        IPurgeGameTrophies trophies = purgeGameTrophies;
        // Pay direct affiliate (skip sentinels)
        if (affiliateAddr != address(0)) {
            uint256 payout = baseAmount;
            uint8 stakeBonus = trophies.affiliateStakeBonus(affiliateAddr);
            if (stakeBonus != 0) {
                payout += (payout * stakeBonus) / 100;
            }

            uint256 rakebackShare = (payout * uint256(rakebackPct)) / 100;
            uint256 affiliateShare = payout - rakebackShare;

            if (affiliateShare != 0) {
                uint256 newTotal = earned[affiliateAddr] + affiliateShare;
                earned[affiliateAddr] = newTotal;

                uint256 questReward;
                if (address(module) != address(0)) {
                    (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module
                        .handleAffiliate(affiliateAddr, affiliateShare);
                    questReward = _questApplyReward(affiliateAddr, reward, hardMode, questType, streak, completed);
                }

                uint256 totalFlipAward = affiliateShare + questReward;
                addFlip(affiliateAddr, totalFlipAward, false, false, false);

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
                    uint8 stakeBonusUpline = trophies.affiliateStakeBonus(upline);
                    if (stakeBonusUpline != 0) {
                        bonus += (bonus * stakeBonusUpline) / 100;
                    }
                    uplineTotal += bonus;
                    earned[upline] = uplineTotal;
                    uint256 questReward;
                    if (address(module) != address(0)) {
                        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module
                            .handleAffiliate(upline, bonus);
                        questReward = _questApplyReward(upline, reward, hardMode, questType, streak, completed);
                    }
                    addFlip(upline, bonus + questReward, false, false, false);
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

        if (refund != 0) {
            (bool refundOk, ) = buyer.call{value: refund}("");
            if (!refundOk) revert Insufficient();
        }

        uint256 creatorCut = costWei - gameCut;
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

    /// @notice Wire the game, NFT, renderers, and supporting modules required by Purgecoin.
    /// @dev Creator only; callable once.
    function wire(
        address game_,
        address nft_,
        address trophies_,
        address regularRenderer_,
        address trophyRenderer_,
        address questModule_,
        address externalJackpotModule_
    ) external {
        if (msg.sender != creator) revert OnlyDeployer();
        if (address(purgeGameNFT) != address(0) || address(purgeGame) != address(0)) revert OnlyDeployer();
        if (questModule_ == address(0) || externalJackpotModule_ == address(0)) revert ZeroAddress();
        purgeGame = IPurgeGame(game_);
        bytes32 h = H;
        assembly {
            sstore(h, caller())
        }
        purgeGameNFT = PurgeGameNFT(nft_);
        purgeGameTrophies = IPurgeGameTrophies(trophies_);
        questModule = IPurgeQuestModule(questModule_);
        questModule.wireGame(game_);
        externalJackpotModule = externalJackpotModule_;
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
    function bonusCoinflip(address player, uint256 amount, bool rngReady) external onlyGameplayContracts {
        if (player == address(0)) return;
        if (amount != 0) {
            if (!rngReady) {
                _mint(player, amount);
            } else {
                addFlip(player, amount, false, false, false);
            }
        }
    }

    // ---------------------------------------------------------------------
    // Daily quest wiring (delegated to quest module)
    // ---------------------------------------------------------------------

    function primeMintEthQuest(uint48 day) external onlyPurgeGameContract {
        IPurgeQuestModule module = questModule;
        module.primeMintEthQuest(day);
    }

    function rollDailyQuest(uint48 day, uint256 entropy) external onlyPurgeGameContract {
        IPurgeQuestModule module = questModule;
        (bool rolled, , , , ) = module.rollDailyQuest(day, entropy);
        if (rolled) {
            QuestInfo[2] memory quests = module.getActiveQuests();
            for (uint256 i; i < 2; ) {
                QuestInfo memory info = quests[i];
                if (info.day == day) {
                    emit DailyQuestRolled(day, info.questType, info.highDifficulty, info.stakeMask, info.stakeRisk);
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external onlyGameplayContracts {
        IPurgeQuestModule module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleMint(
            player,
            quantity,
            paidWithEth
        );
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed);
        if (questReward != 0) {
            addFlip(player, questReward, false, false, false);
        }
    }

    function notifyQuestPurge(address player, uint32 quantity) external onlyGameplayContracts {
        IPurgeQuestModule module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handlePurge(
            player,
            quantity
        );
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed);
        if (questReward != 0) {
            addFlip(player, questReward, false, false, false);
        }
    }

    function getActiveQuest()
        external
        view
        returns (uint48 day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk)
    {
        IPurgeQuestModule module = questModule;
        return module.getActiveQuest();
    }

    function getActiveQuests() external view returns (QuestInfo[2] memory quests) {
        IPurgeQuestModule module = questModule;
        return module.getActiveQuests();
    }

    function playerQuestState(
        address player
    ) external view returns (uint32 streak, uint32 lastCompletedDay, uint128 progress, bool completedToday) {
        IPurgeQuestModule module = questModule;
        return module.playerQuestState(player);
    }

    function playerQuestStates(
        address player
    )
        external
        view
        returns (uint32 streak, uint32 lastCompletedDay, uint128[2] memory progress, bool[2] memory completed)
    {
        IPurgeQuestModule module = questModule;
        return module.playerQuestStates(player);
    }

    /// @notice Burn PURGE from `target` during gameplay flows (purchases, fees).
    /// @dev Access: PurgeGame, NFT, or trophy module only. OZ ERC20 `_burn` reverts on zero address or insufficient balance.
    function burnCoin(address target, uint256 amount) external onlyGameplayContracts {
        _burn(target, amount);
    }

    /// @notice Progress coinflip payouts for the current level in bounded slices.
    /// @dev Called by PurgeGame; runs in four phases per settlement:
    ///      1. Optionally propagate stakes when the flip outcome is a win.
    ///      2. Arm bounties on the first payout window.
    ///      3. Pay player flips in batches.
    ///      4. Perform cleanup and reopen betting.
    /// @param level Current PurgeGame level (used to gate 1/run and propagate stakes).
    /// @param cap   Work cap hint. cap==0 uses defaults; otherwise applies directly.
    /// @param bonusFlip Adds 5 percentage points to the payout roll for the last flip of the purchase phase.
    /// @return finished True when all payouts and cleanup are complete.
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch
    ) external onlyPurgeGameContract returns (bool finished) {
        uint256 word = rngWord;
        uint16 rewardPercent = uint16(coinflipRewardPercent);
        if (payoutIndex == 0) {
            uint256 seedWord = word;
            if (epoch != 0) {
                seedWord = uint256(keccak256(abi.encodePacked(word, epoch)));
            }
            rewardPercent = uint16((seedWord % COINFLIP_EXTRA_RANGE) + COINFLIP_EXTRA_MIN_PERCENT);
            if (bonusFlip) {
                unchecked {
                    rewardPercent += 5;
                }
            }
            coinflipRewardPercent = rewardPercent;
            if (bonusActive && ((word & 1) == 0)) {
                unchecked {
                    ++word;
                }
            }
        } else if (rewardPercent == 0) {
            rewardPercent = COINFLIP_EXTRA_MIN_PERCENT;
        }
        // --- Step sizing (bounded work) ----------------------------------------------------

        uint32 stepPayout = (cap == 0) ? 420 : cap;
        uint32 stepStake = (cap == 0) ? 200 : (cap > 200 ? 200 : cap);

        bool isBafLevel = _isBafLevel(level);
        bool win = (word & 1) == 1;
        if (!win) {
            stepPayout *= 3;
        }
        // --- Phase 1: stake propagation (only processed on wins) --------
        if (payoutIndex == 0 && stakeLevelComplete < level) {
            uint24 settleLevel = level - 1;
            if (settleLevel == 0) {
                scanCursor = SS_DONE;
                stakeLevelComplete = level;
            } else {
                uint32 st = scanCursor;
                if (st == SS_IDLE) {
                    st = 0;
                    scanCursor = 0;
                    if (stakeTrophyCandidate.level != settleLevel) {
                        delete stakeTrophyCandidate;
                    }
                }

                if (st != SS_DONE) {
                    // If loss: mark complete; no propagation.
                    if (!win) {
                        scanCursor = SS_DONE;
                        stakeLevelComplete = level;
                        _finalizeStakeTrophy(settleLevel, false);
                    } else {
                        // Win: process stakers at this level in slices.
                        address[] storage roster = stakeAddr[settleLevel];
                        uint32 len = uint32(roster.length);
                        if (len == 0) {
                            scanCursor = SS_DONE;
                            stakeLevelComplete = level;
                            _finalizeStakeTrophy(settleLevel, false);
                            return false;
                        }
                        if (st < len) {
                            uint32 en = st + stepStake;
                            if (en > len) en = len;

                            for (uint32 i = st; i < en; ) {
                                address player = roster[i];
                                uint256 enc = stakeAmt[settleLevel][player];
                                for (uint8 li; li < STAKE_MAX_LANES; ) {
                                    uint256 lane = _laneAt(enc, li);
                                    if (lane == 0) break;

                                    uint256 principalRounded = (lane & STAKE_LANE_PRINCIPAL_MASK) *
                                        STAKE_PRINCIPAL_FACTOR;
                                    uint8 riskFactor = uint8((lane & STAKE_LANE_RISK_MASK) >> STAKE_LANE_RISK_SHIFT);

                                    if (riskFactor <= 1) {
                                        _recordStakeTrophyCandidate(settleLevel, player, principalRounded);
                                        if (principalRounded != 0) {
                                            addFlip(player, principalRounded, false, false, true);
                                        }
                                    } else {
                                        uint24 nextL = settleLevel + 1;
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
                                _finalizeStakeTrophy(settleLevel, true);
                            }
                            return false; // more stake processing remains
                        }

                        // Finished this phase.
                        scanCursor = SS_DONE;
                        stakeLevelComplete = level;
                        _finalizeStakeTrophy(settleLevel, true);
                        return false; // allow caller to continue in a subsequent call
                    }
                }
            }
        }

        // --- Phase 2: bounty payout (first window only) -------
        uint256 totalPlayers = _coinflipCount();

        // Bounty: convert any owed bounty into a flip credit on the first window.
        if (totalPlayers != 0 && payoutIndex == 0 && bountyOwedTo != address(0) && currentBounty > 0) {
            address to = bountyOwedTo;
            uint256 amt = currentBounty;
            bountyOwedTo = address(0);
            currentBounty = 0;
            addFlip(to, amt, false, false, false);
            emit BountyPaid(to, amt);
        }

        // --- Phase 3: player payouts (windowed by stepPayout) -----------------------------------
        uint256 start = payoutIndex;
        uint256 end = start + stepPayout;
        if (end > totalPlayers) end = totalPlayers;

        for (uint256 i = start; i < end; ) {
            address p = _playerAt(i);

            uint256 credit; // accumulate bonus + flip payout

            // Flip payout: double on win, zero out stake in all cases.
            uint256 amt = coinflipAmount[p];
            if (amt != 0) {
                if (!win) {
                    coinflipAmount[p] = 0;
                } else {
                    uint256 workingAmt = amt;
                    uint32 streak = _questStreak(p);
                    uint256 payout = _coinflipWinAmount(workingAmt, rewardPercent, streak);
                    if (isBafLevel) {
                        coinflipAmount[p] = payout;
                    } else {
                        coinflipAmount[p] = 0;
                        unchecked {
                            credit += payout;
                        }
                    }
                }
            }

            if (credit != 0) {
                _mint(p, credit);
                playerLuckbox[p] += credit;
            }

            unchecked {
                ++i;
            }
        }
        payoutIndex = uint32(end);
        // --- Phase 4: cleanup (single shot) -------------------------------------------
        if (end >= totalPlayers) {
            if (!isBafLevel) {
                cfHead = cfTail;
            }
            payoutIndex = 0;

            scanCursor = SS_IDLE;
            coinflipRewardPercent = 0;
            if (isBafLevel) {
                lastBafFlipLevel = level;
            }
            emit CoinflipFinished(win);
            return true;
        }

        return false;
    }

    function coinflipWorkPending(uint24 level) external view onlyPurgeGameContract returns (bool) {
        if (payoutIndex != 0) return true;

        if (stakeLevelComplete < level) return true;

        uint256 queued = _coinflipCount();
        if (queued == 0) return false;

        if (_isBafLevel(level)) {
            // BAF checkpoints only need a single doubling pass per level; after that the queue remains
            // armed until a future non-BAF loss clears it.
            return lastBafFlipLevel < level;
        }

        return true;
    }

    function prepareCoinJackpot()
        external
        view
        onlyPurgeGameContract
        returns (uint256 poolAmount, address biggestFlip)
    {
        poolAmount = 10_000 * MILLION;
        biggestFlip = topBettors[0].player;
    }

    function addToBounty(uint256 amount) external onlyPurgeGameContract {
        if (amount == 0) return;
        _addToBounty(amount);
    }

    function lastBiggestFlip() external view returns (address) {
        return topBettors[0].player;
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
        address module = externalJackpotModule;
        if (module == address(0)) revert ZeroAddress();

        (bool ok, bytes memory ret) = module.delegatecall(
            abi.encodeWithSelector(
                IPurgeCoinExternalJackpotModule.runExternalJackpot.selector,
                kind,
                poolWei,
                cap,
                lvl,
                rngWord
            )
        );
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return abi.decode(ret, (bool, address[], uint256[], uint256));
    }

    /// @notice Return addresses from a leaderboard.
    /// @param which 1 = affiliate (<=8), 2 = top bettors (<=8).
    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory out) {
        PlayerScore[8] storage board;
        uint8 len;
        if (which == 1) {
            board = affiliateLeaderboard;
            len = affiliateLen;
        } else if (which == 2) {
            board = topBettors;
            len = topLen;
        } else {
            revert InvalidLeaderboard();
        }
        out = new address[](len);
        for (uint8 i; i < len; ) {
            out[i] = board[i].player;
            unchecked {
                ++i;
            }
        }
    }

    function getTopAffiliate() external view returns (address) {
        if (affiliateLen == 0) return address(0);
        return affiliateLeaderboard[0].player;
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
        topLen = 0;
    }

    function _coinflipCount() internal view returns (uint256) {
        return uint256(uint128(cfTail) - uint128(cfHead));
    }

    /// @notice Return player address at global coinflip index `idx`.
    /// @dev Ring buffer backed by `cfPlayers`. Callers must ensure 0 <= idx < `_coinflipCount()`.
    function _playerAt(uint256 idx) internal view returns (address) {
        uint256 capacity = cfPlayers.length;
        if (capacity == 0) return address(0);
        uint256 physical = (uint256(cfHead) + idx) % capacity;
        return cfPlayers[physical];
    }

    // Append to the queue, reusing storage slots while advancing the ring tail.
    function _pushPlayer(address p) internal {
        uint128 tail = cfTail;
        uint128 head = cfHead;
        uint256 capacity = cfPlayers.length;
        uint256 inQueue = uint256(tail) - uint256(head);

        if (capacity == 0 || inQueue == capacity) {
            // Grow (first entry or fully utilized capacity).
            cfPlayers.push(p);
        } else {
            uint256 slot = uint256(tail) % capacity;
            cfPlayers[slot] = p;
        }

        unchecked {
            cfTail = tail + 1;
        }
    }

    /// @notice Increase a player's pending coinflip stake and possibly arm a bounty.
    /// @param player               Target player.
    /// @param coinflipDeposit      Amount to add to their current pending flip stake.
    /// @param canArmBounty         If true, a sufficiently large deposit may arm a bounty.
    /// @param bountyEligible       If true, this deposit can arm the bounty (entire amount is considered).
    /// @param skipLuckboxCheck     If true, do not initialize `playerLuckbox` when zero.
    function addFlip(
        address player,
        uint256 coinflipDeposit,
        bool canArmBounty,
        bool bountyEligible,
        bool skipLuckboxCheck
    ) internal {
        uint256 prevStake = coinflipAmount[player];
        if (prevStake == 0) _pushPlayer(player);

        uint256 newStake = prevStake + coinflipDeposit;
        uint256 eligibleStake = bountyEligible ? newStake : prevStake;

        coinflipAmount[player] = newStake;
        if (!skipLuckboxCheck && playerLuckbox[player] == 0) {
            playerLuckbox[player] = 1;
        }
        _updatePlayerScore(2, player, newStake);

        uint256 record = biggestFlipEver;
        address leader = topBettors[0].player;
        if (newStake > record && leader == player) {
            biggestFlipEver = uint128(newStake);

            if (canArmBounty && bountyEligible) {
                uint256 threshold = (bountyOwedTo != address(0)) ? (record + record / 100) : record;
                if (eligibleStake >= threshold) {
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

    function _coinflipWinAmount(uint256 amount, uint16 rewardPercent, uint32 streak) private pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 baseBps = uint256(rewardPercent) * 100;
        uint256 bonusBps = _questTierBonusBps(streak);
        uint256 payoutBonus = (amount * (baseBps + bonusBps)) / BPS_DENOMINATOR;
        return amount + payoutBonus;
    }
    function _questTierBonusBps(uint32 streak) private pure returns (uint256) {
        if (streak == 0) return 0;
        uint256 tier = uint256(streak) / QUEST_TIER_BONUS_SPAN;
        if (tier > QUEST_TIER_BONUS_MAX) {
            tier = QUEST_TIER_BONUS_MAX;
        }
        return tier * QUEST_TIER_BONUS_BPS_PER_TIER;
    }

    function _questApplyReward(
        address player,
        uint256 reward,
        bool hardMode,
        uint8 questType,
        uint32 streak,
        bool completed
    ) private returns (uint256) {
        if (!completed || player == address(0)) return 0;
        emit QuestCompleted(player, questType, streak, reward, hardMode);
        return reward;
    }

    function _questStreak(address player) private view returns (uint32) {
        IPurgeQuestModule module = questModule;
        (uint32 streak, , , ) = module.playerQuestState(player);
        return streak;
    }

    function _isBafLevel(uint24 lvl) private pure returns (bool) {
        if (lvl == 0) return false;
        if ((lvl % 20) != 0) return false;
        return (lvl % 100) != 0;
    }

    function _decBucketDenominator(uint256 streak) internal pure returns (uint8) {
        if (streak <= 5) {
            return uint8(15 - streak);
        }

        if (streak <= 15) {
            uint256 denom = 9 - ((streak - 6) / 2);
            if (denom < 4) denom = 4;
            return uint8(denom);
        }

        if (streak <= 25) {
            return 5;
        }

        return 4;
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
