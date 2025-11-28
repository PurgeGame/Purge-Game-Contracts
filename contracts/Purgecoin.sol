// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameNFT} from "./PurgeGameNFT.sol";
import {IPurgeGameTrophies, PURGE_TROPHY_KIND_STAKE} from "./PurgeGameTrophies.sol";
import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeRenderer} from "./interfaces/IPurgeRenderer.sol";
import {IPurgeQuestModule, QuestInfo, PlayerQuestView} from "./interfaces/IPurgeQuestModule.sol";
import {IPurgeJackpots} from "./interfaces/IPurgeJackpots.sol";

interface IStETH {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract Purgecoin {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event StakeCreated(address indexed player, uint24 targetLevel, uint8 risk, uint256 principal);
    event StakeClaimed(address indexed player, uint24 targetLevel, uint8 risk, uint256 payout, bool won);
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
    string public name = "Purgecoin";
    string public symbol = "PURGE";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---------------------------------------------------------------------
    // Types used in storage
    // ---------------------------------------------------------------------
    struct PlayerScore {
        address player;
        uint96 score;
    }

    struct AffiliateCodeInfo {
        address owner;
        uint8 rakeback;
    }

    struct StakeTrophyCandidate {
        address player;
        uint72 principal;
        uint24 level;
    }

    struct CoinflipDayResult {
        uint16 rewardPercent;
        bool win;
    }

    // ---------------------------------------------------------------------
    // Game wiring & session state
    // ---------------------------------------------------------------------
    IPurgeGame internal purgeGame;
    PurgeGameNFT internal purgeGameNFT;
    IPurgeGameTrophies internal purgeGameTrophies;
    IPurgeQuestModule internal questModule;
    address public jackpots;

    bool internal bonusActive;

    uint8 internal affiliateLen;
    uint8 internal topLen;

    uint24 internal stakeLevelComplete;
    uint32 internal scanCursor = type(uint32).max;
    uint32 internal payoutIndex;

    address[] internal cfPlayers;
    uint128 internal cfHead;
    uint128 internal cfTail;
    address[] internal cfPlayersNext;
    uint128 internal cfHeadNext;
    uint128 internal cfTailNext;
    uint48 internal nextFlipDay;
    uint24 internal lastBafFlipLevel;

    mapping(uint48 => mapping(address => uint256)) internal coinflipBalance;
    mapping(uint48 => CoinflipDayResult) internal coinflipDayResult;
    mapping(address => uint48) internal lastCoinflipClaim;
    uint48 internal currentFlipDay;

    PlayerScore[8] public topBettors;

    mapping(bytes32 => AffiliateCodeInfo) internal affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;
    mapping(address => bytes32) internal playerReferralCode;
    mapping(address => uint256) public playerLuckbox;
    PlayerScore public biggestLuckbox;
    PlayerScore[8] public affiliateLeaderboard;

    uint8 private constant STAKE_BUCKETS = 12;

    mapping(uint24 => address[]) internal stakeAddr;
    mapping(uint24 => mapping(address => uint256[STAKE_BUCKETS])) internal stakeAmt;
    StakeTrophyCandidate internal stakeTrophyCandidate;

    mapping(address => uint8) internal affiliatePos;
    mapping(address => uint8) internal topPos;

    uint128 public currentBounty = 1_000_000_000;
    uint128 public biggestFlipEver = 1_000_000_000;
    address internal bountyOwedTo;
    uint96 public totalPresaleSold;

    uint256 internal coinflipRewardPercent;
    mapping(uint24 => uint48) internal stakeResolutionDay;
    mapping(uint24 => bool) internal stakeTrophyAwarded;

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
    uint256 private constant BUCKET_SIZE = 1500;
    uint16 private constant COINFLIP_EXTRA_MIN_PERCENT = 78;
    uint16 private constant COINFLIP_EXTRA_RANGE = 38;
    uint16 private constant BPS_DENOMINATOR = 10_000;
    bytes32 private constant H = 0x9aeceb0bff1d88815fac67760a5261a814d06dfaedc391fdf4cf62afac3f10b5;
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
    uint48 private constant JACKPOT_RESET_TIME = 82620;

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
        currentFlipDay = _currentDay();
        uint256 presaleAmount = PRESALE_SUPPLY_TOKENS * MILLION;
        _mint(address(this), presaleAmount);
        _mint(creator, presaleAmount);
    }

    receive() external payable {}

    /// @notice Burn PURGE to increase the caller’s coinflip stake, applying streak bonuses when eligible.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum.
    function depositCoinflip(uint256 amount) external {
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;

        _burn(caller, amount);

        IPurgeQuestModule module = questModule;
        uint256 questReward;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleFlip(
            caller,
            amount
        );
        questReward = _questApplyReward(caller, reward, hardMode, questType, streak, completed);

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
        (bool decOn, uint24 lvl) = purgeGame.decWindow();
        if (purgeGame.rngLocked()) revert BettingPaused();
        if (!decOn) revert NotDecimatorWindow();
        if (amount < MIN) revert AmountLTMin();

        address moduleAddr = jackpots;
        if (moduleAddr == address(0)) revert ZeroAddress();

        address caller = msg.sender;
        _burn(caller, amount);

        bool specialDec = (lvl % DECIMATOR_SPECIAL_LEVEL) == 0;
        uint8 bucket = specialDec
            ? _decBucketDenominatorFromLevels(purgeGame.ethMintLevelCount(caller))
            : _decBucketDenominator(purgeGame.ethMintStreakCount(caller));
        uint8 bucketUsed = IPurgeJackpots(moduleAddr).recordDecBurn(caller, lvl, bucket, amount);

        IPurgeQuestModule module = questModule;
        (uint32 streak, , , ) = module.playerQuestStates(caller);
        if (streak != 0) {
            uint256 bonusBps = uint256(streak) * 25; // (streak/4)%
            if (bonusBps > 2500) bonusBps = 2500; // cap at 25%
            uint256 streakBonus = (amount * bonusBps) / BPS_DENOMINATOR;
            IPurgeJackpots(moduleAddr).recordDecBurn(caller, lvl, bucketUsed, streakBonus);
        }

        (uint256 reward, bool hardMode, uint8 questType, uint32 streak2, bool completed) = module.handleDecimator(
            caller,
            amount
        );
        uint256 questReward = _questApplyReward(caller, reward, hardMode, questType, streak2, completed);
        if (questReward != 0) {
            addFlip(caller, questReward, false, false, false);
        }

        emit DecimatorBurn(caller, amount, bucketUsed);
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

    function _awardStakeTrophy(uint24 level, address player, uint256 principal) private {
        if (player == address(0) || principal == 0) return;
        if (stakeTrophyAwarded[level]) return;
        stakeTrophyAwarded[level] = true;

        uint256 dataWord = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_STAKE;
        purgeGameTrophies.awardTrophy(player, level, PURGE_TROPHY_KIND_STAKE, dataWord, 0);
    }

    function _hasAnyStake(uint256[STAKE_BUCKETS] storage buckets) private view returns (bool) {
        for (uint8 i = 1; i <= MAX_RISK; ) {
            if (buckets[i] != 0) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @notice Claim a matured stake recorded for `targetLevel` with the provided `risk` lane.
    /// @dev Reverts if resolution days are not yet recorded or the specified lane does not exist.
    function claimStake(uint24 targetLevel, uint8 risk) external returns (uint256 payout) {
        payout = _claimStake(msg.sender, targetLevel, risk);
    }

    function _claimStake(address player, uint24 targetLevel, uint8 risk) internal returns (uint256 payout) {
        if (player == address(0)) revert ZeroAddress();
        if (risk == 0 || risk > MAX_RISK) revert StakeInvalid();
        if (targetLevel == 0 || risk > targetLevel) revert StakeInvalid();

        uint256[STAKE_BUCKETS] storage stakes = stakeAmt[targetLevel][player];
        uint256 principal = stakes[risk];
        if (principal == 0) revert StakeInvalid();

        payout = principal;
        bool allWon = true;

        for (uint8 step; step < risk; ) {
            uint24 checkLevel = targetLevel - uint24(step);
            uint48 day = stakeResolutionDay[checkLevel];
            if (day == 0) revert StakeInvalid();

            CoinflipDayResult storage result = coinflipDayResult[day];
            if (!result.win) {
                allWon = false;
                break;
            }

            payout += (payout * uint256(result.rewardPercent) * 100) / BPS_DENOMINATOR;
            unchecked {
                ++step;
            }
        }

        stakes[risk] = 0;

        if (!allWon) {
            emit StakeClaimed(player, targetLevel, risk, 0, false);
            return 0;
        }

        _mint(player, payout);
        playerLuckbox[player] += payout;
        _awardStakeTrophy(targetLevel, player, principal);

        emit StakeClaimed(player, targetLevel, risk, payout, true);
    }

    /// @notice Burn PURGED to open a future stake targeting `targetLevel` with a risk radius.
    /// @dev
    /// - `burnAmt` must be at least 250e6 base units (token has 6 decimals).
    /// - `targetLevel` must be ahead of the current effective game level.
    /// - `risk` must be between 1 and `MAX_RISK` and cannot exceed the distance to `targetLevel`.
    /// - Stores stake principal per level/risk bucket (whole-token rounded).
    /// - Stakes are recorded on their maturity level and later claimed via `claimStake`.
    function stake(uint256 burnAmt, uint24 targetLevel, uint8 risk) external {
        if (burnAmt < 250 * MILLION) revert AmountLTMin();
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
        if (risk > targetLevel) revert StakeInvalid();

        uint256 maxRiskForTarget = uint256(targetLevel) + 1 - uint256(effectiveLevel);
        if (risk > maxRiskForTarget) revert Insufficient();

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
        if (stakeTrophyBoost != 0 && distance >= 20) {
            boostedPrincipal += (boostedPrincipal * stakeTrophyBoost) / 100;
        }

        // Encode and place the stake lane
        uint256 principalRounded = boostedPrincipal - (boostedPrincipal % STAKE_PRINCIPAL_FACTOR);
        if (principalRounded == 0) principalRounded = STAKE_PRINCIPAL_FACTOR;
        IPurgeQuestModule module = questModule;
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

        uint256[STAKE_BUCKETS] storage stakes = stakeAmt[targetLevel][sender];
        bool hadStake = _hasAnyStake(stakes);
        stakes[risk] += principalRounded;
        if (!hadStake) {
            stakeAddr[targetLevel].push(sender);
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
    /// - Caller can pre-apply any purchase bonus (e.g., early-purge or level checkpoint) to `amount`.
    /// - Direct ref gets a coinflip credit equal to `amount` (plus stake bonus), but the configured rakeback%
    ///   is diverted to the buyer as flip credit.
    /// - Their upline (if any) receives a 20% bonus coinflip credit of the same (post-doubling) amount.
    /// - A second upline (if any) receives another 20% credit of the upline’s bonus.
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

        mapping(address => uint256) storage earned = affiliateCoinEarned[lvl];
        IPurgeQuestModule module = questModule;
        IPurgeGameTrophies trophies = purgeGameTrophies;
        // Pay direct affiliate
        uint256 payout = baseAmount;
        uint8 stakeBonus = trophies.affiliateStakeBonus(affiliateAddr);
        if (stakeBonus != 0) {
            payout += (payout * stakeBonus) / 100;
        }

        uint256 rakebackShare = (payout * uint256(rakebackPct)) / 100;
        uint256 affiliateShare = payout - rakebackShare;

        uint256 newTotal = earned[affiliateAddr] + affiliateShare;
        earned[affiliateAddr] = newTotal;

        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleAffiliate(
            affiliateAddr,
            affiliateShare
        );
        uint256 questReward = _questApplyReward(affiliateAddr, reward, hardMode, questType, streak, completed);

        uint256 totalFlipAward = affiliateShare + questReward;
        addFlip(affiliateAddr, totalFlipAward, false, false, false);

        _updatePlayerScore(1, affiliateAddr, newTotal);

        playerRakeback = rakebackShare;

        // Upline bonus (20%)
        address upline = _referrerAddress(affiliateAddr);
        if (upline != address(0) && upline != sender) {
            uint256 bonus = baseAmount / 5;
            uint8 stakeBonusUpline = trophies.affiliateStakeBonus(upline);
            if (stakeBonusUpline != 0) {
                bonus += (bonus * stakeBonusUpline) / 100;
            }
            (
                uint256 rewardUpline,
                bool hardModeUpline,
                uint8 questTypeUpline,
                uint32 streakUpline,
                bool completedUpline
            ) = module.handleAffiliate(upline, bonus);
            uint256 questRewardUpline = _questApplyReward(
                upline,
                rewardUpline,
                hardModeUpline,
                questTypeUpline,
                streakUpline,
                completedUpline
            );
            uint256 uplineTotal = earned[upline] + bonus;
            earned[upline] = uplineTotal;
            addFlip(upline, bonus + questRewardUpline, false, false, false);
            _updatePlayerScore(1, upline, uplineTotal);

            // Second upline bonus (20%)
            address upline2 = _referrerAddress(upline);
            if (upline2 != address(0)) {
                uint256 bonus2 = bonus / 5;
                uint8 stakeBonusUpline2 = trophies.affiliateStakeBonus(upline2);
                if (stakeBonusUpline2 != 0) {
                    bonus2 += (bonus2 * stakeBonusUpline2) / 100;
                }
                (uint256 reward2, bool hardMode2, uint8 questType2, uint32 streak2, bool completed2) = module
                    .handleAffiliate(upline2, bonus2);
                uint256 questReward2 = _questApplyReward(upline2, reward2, hardMode2, questType2, streak2, completed2);
                uint256 upline2Total = earned[upline2] + bonus2;
                earned[upline2] = upline2Total;
                addFlip(upline2, bonus2 + questReward2, false, false, false);
                _updatePlayerScore(1, upline2, upline2Total);
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
        address jackpots_
    ) external {
        if (msg.sender != creator || jackpots != address(0)) revert OnlyDeployer();

        purgeGame = IPurgeGame(game_);
        bytes32 h = H;
        assembly {
            sstore(h, caller())
        }
        purgeGameNFT = PurgeGameNFT(nft_);
        purgeGameTrophies = IPurgeGameTrophies(trophies_);
        questModule = IPurgeQuestModule(questModule_);
        questModule.wireGame(game_);
        jackpots = jackpots_;
        IPurgeJackpots(jackpots_).wire(address(this), game_, trophies_);
        IPurgeRenderer(regularRenderer_).wireContracts(game_, nft_);
        IPurgeRenderer(trophyRenderer_).wireContracts(game_, nft_);
        purgeGameNFT.wireAll(game_, trophies_);
        purgeGameTrophies.wireAndPrime(game_, address(this), 1);
    }

    /// @notice Credit the creator's share of gameplay proceeds.
    /// @dev Access: PurgeGame only. Zero amounts are ignored.
    function burnie(uint256 amount, address stethToken) external payable onlyPurgeGameContract {
        address creator_ = creator;
        if (stethToken != address(0)) {
            uint256 stBal = IStETH(stethToken).balanceOf(address(this));
            if (stBal != 0) {
                if (!IStETH(stethToken).transfer(creator_, stBal)) revert E();
            }
        }
        if (msg.value != 0) {
            uint256 payout = address(this).balance;
            (bool ok, ) = payable(creator_).call{value: payout}("");
            if (!ok) revert E();
            return;
        }
        _mint(creator_, amount);
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

    function rollDailyQuestWithOverrides(
        uint48 day,
        uint256 entropy,
        bool forceMintEth,
        bool forcePurge
    ) external onlyPurgeGameContract {
        IPurgeQuestModule module = questModule;
        (bool rolled, , , , ) = module.rollDailyQuestWithOverrides(day, entropy, forceMintEth, forcePurge);
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

    function getActiveQuests() external view returns (QuestInfo[2] memory quests) {
        IPurgeQuestModule module = questModule;
        return module.getActiveQuests();
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

    function getPlayerQuestView(address player) external view returns (PlayerQuestView memory viewData) {
        IPurgeQuestModule module = questModule;
        return module.getPlayerQuestView(player);
    }

    /// @notice Burn PURGE from `target` during gameplay flows (purchases, fees).
    /// @dev Access: PurgeGame, NFT, or trophy module only. OZ ERC20 `_burn` reverts on zero address or insufficient balance.
    function burnCoin(address target, uint256 amount) external onlyGameplayContracts {
        _burn(target, amount);
    }

    function coinflipAmount(address player) external view returns (uint256) {
        uint48 day = _viewFlipDay();
        return coinflipBalance[day][player];
    }

    function coinflipDayInfo(
        uint48 day
    ) external view returns (uint16 rewardPercent, bool win) {
        CoinflipDayResult storage result = coinflipDayResult[day];
        return (result.rewardPercent, result.win);
    }

    function claimCoinflips(uint8 maxDays) external {
        _claimCoinflips(msg.sender, maxDays);
    }

    /// @notice Record the stake resolution day for a level (invoked by PurgeGame at end of state 1).
    /// @dev The first call at the start of level 2 is considered the level-1 resolution.
    function recordStakeResolution(uint24 level, uint48 day) external onlyPurgeGameContract {
        if (level == 0) return;
        uint48 setDay = day == 0 ? _currentDay() : day;
        if (setDay == 0) return;
        stakeResolutionDay[level] = setDay;
        stakeLevelComplete = level;
    }

    /// @notice Claim both coinflip winnings (for up to `maxDays`) and specified stakes in one call.
    /// @param maxDays Maximum days of coinflips to claim (bounded to 30 in practice).
    /// @param stakeLevels Levels of the stakes to claim.
    /// @param stakeRisks  Risk buckets (1..MAX_RISK) corresponding to `stakeLevels`.
    /// @return flipClaimed Total flip amount minted.
    /// @return stakeClaimed Total stake amount minted (sum of successful stake payouts).
    function claimRewards(
        uint8 maxDays,
        uint24[] calldata stakeLevels,
        uint8[] calldata stakeRisks
    ) external returns (uint256 flipClaimed, uint256 stakeClaimed) {
        flipClaimed = _claimCoinflips(msg.sender, maxDays);

        uint256 len = stakeLevels.length;
        if (len != stakeRisks.length) revert StakeInvalid();

        for (uint256 i; i < len; ) {
            stakeClaimed += _claimStake(msg.sender, stakeLevels[i], stakeRisks[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _claimCoinflips(address player, uint8 maxDays) internal returns (uint256 claimed) {
        _syncFlipDay();

        uint48 latest = _latestClaimableDay();
        uint48 start = lastCoinflipClaim[player];
        if (start >= latest) return 0;

        uint48 cursor;
        unchecked {
            cursor = start + 1;
        }
        uint48 processed;

        uint8 remaining = (maxDays == 0 || maxDays > 30) ? 30 : maxDays;

        while (remaining != 0 && cursor <= latest) {
            CoinflipDayResult storage result = coinflipDayResult[cursor];

            uint256 flipStake = coinflipBalance[cursor][player];
            if (flipStake != 0) {
                if (result.win) {
                    uint256 payout = flipStake + (flipStake * uint256(result.rewardPercent) * 100) / BPS_DENOMINATOR;
                    claimed += payout;
                }
                coinflipBalance[cursor][player] = 0;
            }

            processed = cursor;
            unchecked {
                ++cursor;
                --remaining;
            }
        }

        if (processed != 0 && processed != lastCoinflipClaim[player]) {
            lastCoinflipClaim[player] = processed;
        }
        if (claimed != 0) {
            _mint(player, claimed);
            playerLuckbox[player] += claimed;
        }
    }

    function _viewFlipDay() internal view returns (uint48) {
        uint48 target = currentFlipDay;
        if (target == 0) {
            target = _currentDay();
        }
        return target;
    }

    function _syncFlipDay() internal returns (uint48 activeDay) {
        activeDay = currentFlipDay;
        if (activeDay == 0) {
            activeDay = _currentDay();
            currentFlipDay = activeDay;
        }
    }

    function _latestClaimableDay() internal view returns (uint48) {
        uint48 day = currentFlipDay;
        if (day == 0) return 0;
        unchecked {
            return day - 1;
        }
    }

    function _currentDay() internal view returns (uint48) {
        uint256 ts = block.timestamp;
        if (ts <= JACKPOT_RESET_TIME) {
            return 0;
        }
        return uint48((ts - JACKPOT_RESET_TIME) / 1 days);
    }

    /// @notice Progress coinflip payouts for the current level in bounded slices.
    /// @dev Called by PurgeGame; runs in three phases per settlement:
    ///      1. Record the stake resolution day for the level being processed.
    ///      2. Arm bounties on the first payout window.
    ///      3. Perform cleanup and reopen betting (flip claims happen lazily per player).
    /// @param level Current PurgeGame level (used to gate 1/run and propagate stakes).
    /// @param cap   Work cap hint. cap==0 uses defaults; otherwise applies directly.
    /// @param bonusFlip Adds 6 percentage points to the payout roll for the last flip of the purchase phase.
    /// @return finished True when all payouts and cleanup are complete.
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch,
        uint256 priceCoinUnit
    ) external onlyPurgeGameContract returns (bool finished) {
        cap; // cap no longer affects work sizing
        level; // retained in signature for interface compatibility
        _syncFlipDay();
        uint48 day = currentFlipDay;
        if (day == 0) {
            day = _currentDay();
            currentFlipDay = day;
        }
        if (epoch > day) {
            day = epoch;
            currentFlipDay = day;
        }
        uint256 word = rngWord;
        uint16 rewardPercent = uint16(coinflipRewardPercent);
        if (payoutIndex == 0) {
            uint256 seedWord = word;
            if (epoch != 0) {
                seedWord = uint256(keccak256(abi.encodePacked(word, epoch)));
            }
            uint256 roll = seedWord % 20; // ~5% each for the low/high outliers
            if (roll == 0) {
                rewardPercent = 50;
            } else if (roll == 1) {
                rewardPercent = 150;
            } else {
                rewardPercent = uint16((seedWord % COINFLIP_EXTRA_RANGE) + COINFLIP_EXTRA_MIN_PERCENT);
            }
            if (bonusFlip) {
                unchecked {
                    rewardPercent += 7;
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

        bool win = (word & 1) == 1;

        CoinflipDayResult storage dayResult = coinflipDayResult[day];
        dayResult.rewardPercent = rewardPercent;
        dayResult.win = win;
        if (payoutIndex == 0) {
            scanCursor = SS_IDLE;
        }

        // --- Phase 2: bounty payout (first window only; flip claims are player-driven) -------
        uint256 totalPlayers = _coinflipCount();

        // Bounty: convert any owed bounty into a flip credit on the first window.
        if (totalPlayers != 0 && payoutIndex == 0 && bountyOwedTo != address(0) && currentBounty > 0) {
            address to = bountyOwedTo;
            uint256 slice = currentBounty >> 1; // pay/delete half of the bounty pool
            if (slice != 0) {
                unchecked {
                    currentBounty -= uint128(slice);
                }
                if (win) {
                    addFlip(to, slice, false, false, false);
                    emit BountyPaid(to, slice);
                }
            }
            bountyOwedTo = address(0);
        }

        // --- Phase 3: cleanup (claims happen lazily; clear queue markers) -------------------
        cfHead = cfTail;
        payoutIndex = 0;

        scanCursor = SS_IDLE;
        coinflipRewardPercent = 0;
        currentFlipDay = day + 1;
        _promoteNextQueue(currentFlipDay);

        if (priceCoinUnit != 0) {
            _addToBounty(priceCoinUnit);
        }

        emit CoinflipFinished(win);
        return true;
    }

    function addToBounty(uint256 amount) external onlyPurgeGameContract {
        if (amount == 0) return;
        _addToBounty(amount);
    }

    function rewardTopFlipBonus(uint256 amount) external onlyPurgeGameContract {
        address top = topBettors[0].player;
        if (top == address(0)) return;

        addFlip(top, amount, false, false, true);
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

    function _resetNextQueue() internal {
        delete cfPlayersNext;
        cfHeadNext = 0;
        cfTailNext = 0;
    }

    function _ensureNextFlipDay(uint48 targetDay) internal {
        uint48 queuedDay = nextFlipDay;
        if (queuedDay != targetDay) {
            _resetNextQueue();
            nextFlipDay = targetDay;
        }
    }

    // Append to the "next day" queue, reusing storage slots while advancing the ring tail.
    function _pushPlayerNext(address p) internal {
        uint128 tail = cfTailNext;
        uint128 head = cfHeadNext;
        uint256 capacity = cfPlayersNext.length;
        uint256 inQueue = uint256(tail) - uint256(head);

        if (capacity == 0 || inQueue == capacity) {
            cfPlayersNext.push(p);
        } else {
            uint256 slot = uint256(tail) % capacity;
            cfPlayersNext[slot] = p;
        }

        unchecked {
            cfTailNext = tail + 1;
        }
    }

    function _promoteNextQueue(uint48 newActiveDay) internal {
        if (nextFlipDay != newActiveDay) {
            cfHead = cfTail;
            return;
        }

        cfPlayers = cfPlayersNext;
        cfHead = cfHeadNext;
        cfTail = cfTailNext;

        _resetNextQueue();
        nextFlipDay = 0;
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
        _claimCoinflips(player, 30);

        uint48 settleDay = _syncFlipDay();
        uint48 targetDay = settleDay + 1;
        uint48 nowDay = _currentDay();
        if (targetDay <= nowDay) {
            targetDay = nowDay + 1;
        }
        _ensureNextFlipDay(targetDay);

        uint256 prevStake = coinflipBalance[targetDay][player];
        if (prevStake == 0) _pushPlayerNext(player);

        uint256 newStake = prevStake + coinflipDeposit;
        uint256 eligibleStake = bountyEligible ? newStake : prevStake;

        coinflipBalance[targetDay][player] = newStake;

        // When BAF is active, capture a persistent roster entry + index for scatter.
        if (purgeGame.isBafLevelActive(purgeGame.level())) {
            uint24 lvl = purgeGame.level();
            address module = jackpots;
            if (module == address(0)) revert ZeroAddress();
            IPurgeJackpots(module).recordBafFlip(player, lvl);
        }

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

    function _questApplyReward(
        address player,
        uint256 reward,
        bool hardMode,
        uint8 questType,
        uint32 streak,
        bool completed
    ) private returns (uint256) {
        if (!completed) return 0;
        emit QuestCompleted(player, questType, streak, reward, hardMode);
        return reward;
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

        if (streak < 25) {
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
