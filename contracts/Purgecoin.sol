// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameNFT} from "./PurgeGameNFT.sol";
import {IPurgeGameTrophies, PURGE_TROPHY_KIND_STAKE} from "./PurgeGameTrophies.sol";
import {PurgeAffiliate} from "./PurgeAffiliate.sol";
import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeRenderer} from "./interfaces/IPurgeRenderer.sol";
import {IPurgeQuestModule, QuestInfo, PlayerQuestView} from "./interfaces/IPurgeQuestModule.sol";
import {IPurgeJackpots} from "./interfaces/IPurgeJackpots.sol";

interface IPurgeBonds {
    function onBondMint(uint256 amount) external;
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
    event CoinflipFinished(bool result);
    event BountyOwed(address indexed to, uint256 bountyAmount, uint256 newRecordFlip);
    event BountyPaid(address indexed to, uint256 amount);
    event DailyQuestRolled(uint48 indexed day, uint8 questType, bool highDifficulty, uint8 stakeMask, uint8 stakeRisk);
    event QuestCompleted(address indexed player, uint8 questType, uint32 streak, uint256 reward, bool hardMode);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyGame();
    error BettingPaused();
    error Zero();
    error Insufficient();
    error AmountLTMin();
    error E();
    error InvalidKind();
    error StakeInvalid();
    error ZeroAddress();
    error NotDecimatorWindow();
    error OnlyBonds();
    error AlreadyWired();

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

    struct CoinflipDayResult {
        uint16 rewardPercent;
        bool win;
    }

    struct StakePosition {
        uint256 principal;
        uint256 modifiedAmount;
        uint24 distance;
        uint8 risk;
        bool claimed;
    }

    struct StakeResolution {
        uint8 winningRiskLevels;
        uint256 winningModifiedTotal;
        uint256 stakeFreeMoney;
        address topStakeWinner;
        uint256 topStakeAmount;
        bool resolved;
    }

    struct StakeTop {
        address player;
        uint256 modifiedAmount;
    }

    // ---------------------------------------------------------------------
    // Game wiring & session state
    // ---------------------------------------------------------------------
    IPurgeGame internal purgeGame;
    PurgeGameNFT internal purgeGameNFT;
    IPurgeGameTrophies internal purgeGameTrophies;
    IPurgeQuestModule internal questModule;
    PurgeAffiliate public affiliateProgram;
    bool private affiliateOverride;
    address public jackpots;

    uint24 internal stakeLevelComplete;

    mapping(uint48 => mapping(address => uint256)) internal coinflipBalance;
    mapping(uint48 => CoinflipDayResult) internal coinflipDayResult;
    mapping(address => uint48) internal lastCoinflipClaim;
    uint48 internal currentFlipDay;

    PlayerScore public topBettor;
    mapping(uint48 => PlayerScore) internal coinflipTopByDay;
    mapping(uint24 => PlayerScore) internal coinflipTopByLevel;

    mapping(address => uint256) public playerLuckbox;
    PlayerScore public biggestLuckbox;

    /// @notice View-only helper to estimate claimable coin (flips + stakes) for the caller.
    function claimableCoin() external view returns (uint256) {
        address player = msg.sender;
        return _viewClaimableCoin(player);
    }

    mapping(address => mapping(uint24 => StakePosition[])) internal stakePositions;
    mapping(uint24 => mapping(uint8 => uint256)) internal stakeModifiedTotals;
    mapping(uint24 => mapping(uint8 => StakeTop)) internal stakeTopByLevelAndRisk;
    mapping(uint24 => StakeResolution) internal stakeResolutionInfo;
    mapping(address => uint24) internal lastStakeScanLevel;
    mapping(address => uint48) internal lastStakeScanDay;
    uint256 public presaleClaimableRemaining;

    uint128 public currentBounty = 1_000_000_000;
    uint128 public biggestFlipEver = 1_000_000_000;
    address internal bountyOwedTo;
    mapping(uint24 => uint48) internal stakeResolutionDay;
    mapping(uint24 => bool) internal stakeTrophyAwarded;
    address public immutable bonds;

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
    uint8 private constant MAX_RISK = 25; // staking risk 1..25
    uint16 private constant COINFLIP_EXTRA_MIN_PERCENT = 78;
    uint16 private constant COINFLIP_EXTRA_RANGE = 38;
    uint16 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant STAKE_PRINCIPAL_FACTOR = MILLION;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;
    uint48 private constant JACKPOT_RESET_TIME = 82620;

    // ---------------------------------------------------------------------
    // Immutables / external wiring
    // ---------------------------------------------------------------------
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
    constructor(address bonds_) {
        if (bonds_ == address(0)) revert ZeroAddress();
        bonds = bonds_;
        affiliateProgram = new PurgeAffiliate(bonds_);
        currentFlipDay = _currentDay();
        uint256 bondSeed = 2_000_000 * MILLION;
        _mint(bonds_, bondSeed);
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

    /// @notice Claim presale/early affiliate bonuses that were deferred to the affiliate contract.
    function claimPresaleAffiliateBonus() external {
        uint256 amount = affiliateProgram.consumePresaleCoin(msg.sender);
        if (amount == 0) return;
        if (amount > presaleClaimableRemaining) revert Insufficient();
        presaleClaimableRemaining -= amount;
        _transfer(address(this), msg.sender, amount);
    }

    /// @notice Burn PURGE during an active Decimator window to accrue weighted participation.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum.
    function decimatorBurn(uint256 amount) external {
        (bool decOn, uint24 lvl) = purgeGame.decWindow();
        if (!decOn) revert NotDecimatorWindow();
        if (amount < MIN) revert AmountLTMin();

        address moduleAddr = jackpots;
        if (moduleAddr == address(0)) revert ZeroAddress();

        address caller = msg.sender;
        _burn(caller, amount);

        uint256 effectiveAmount = amount;
        uint8 decBonusPct = purgeGameTrophies.decStakeBonus(caller);
        if (decBonusPct != 0) {
            effectiveAmount += (effectiveAmount * decBonusPct) / 100;
        }

        bool specialDec = (lvl % DECIMATOR_SPECIAL_LEVEL) == 0;
        uint8 bucket = specialDec
            ? _decBucketDenominatorFromLevels(purgeGame.ethMintLevelCount(caller))
            : _decBucketDenominator(purgeGame.ethMintStreakCount(caller));
        uint8 bucketUsed = IPurgeJackpots(moduleAddr).recordDecBurn(caller, lvl, bucket, effectiveAmount);

        IPurgeQuestModule module = questModule;
        (uint32 streak, , , ) = module.playerQuestStates(caller);
        if (streak != 0) {
            uint256 bonusBps = uint256(streak) * 25; // (streak/4)%
            if (bonusBps > 2500) bonusBps = 2500; // cap at 25%
            uint256 streakBonus = (effectiveAmount * bonusBps) / BPS_DENOMINATOR;
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

    function _awardStakeTrophy(uint24 level, StakeResolution memory res) private {
        if (stakeTrophyAwarded[level]) return;
        if (res.winningRiskLevels == 0) return;
        if (res.topStakeWinner == address(0) || res.topStakeAmount == 0) return;
        stakeTrophyAwarded[level] = true;

        uint256 dataWord = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_STAKE;
        purgeGameTrophies.awardTrophy(res.topStakeWinner, level, PURGE_TROPHY_KIND_STAKE, dataWord, 0);
    }

    function _stakeFreeMoneyView() private view returns (uint256) {
        (, , , uint256 priceWei, , uint256 prizePoolTarget, , , ) = /*earlyPurgePercent_*/
        purgeGame.gameInfo();
        uint256 priceCoinUnit = purgeGame.coinPriceUnit();
        if (priceWei == 0 || priceCoinUnit == 0) return 0;
        uint256 tenPercentEth = prizePoolTarget / 10;
        if (tenPercentEth == 0) return 0;
        return (tenPercentEth * priceCoinUnit) / priceWei;
    }

    function _winningRiskLevels(uint24 level) private view returns (uint8 winningRisk) {
        if (level == 0) return 0;
        uint8 maxRisk = level < MAX_RISK ? uint8(level) : MAX_RISK;
        for (uint8 step; step < maxRisk; ) {
            uint24 checkLevel = level - uint24(step);
            uint48 day = stakeResolutionDay[checkLevel];
            if (day == 0) break;
            CoinflipDayResult storage result = coinflipDayResult[day];
            if (result.rewardPercent == 0 && !result.win) break;
            if (!result.win) break;
            unchecked {
                ++winningRisk;
                ++step;
            }
        }
    }

    function _stakeResolutionView(uint24 level) private view returns (StakeResolution memory res) {
        StakeResolution storage stored = stakeResolutionInfo[level];
        if (stored.resolved) {
            res = stored;
            return res;
        }

        res.winningRiskLevels = _winningRiskLevels(level);
        if (res.winningRiskLevels != 0) {
            uint8 maxRisk = res.winningRiskLevels;
            address bestPlayer;
            uint256 bestModified;
            for (uint8 r = 1; r <= maxRisk; ) {
                res.winningModifiedTotal += stakeModifiedTotals[level][r];
                StakeTop storage top = stakeTopByLevelAndRisk[level][r];
                if (top.player != address(0) && top.modifiedAmount > bestModified) {
                    bestModified = top.modifiedAmount;
                    bestPlayer = top.player;
                }
                unchecked {
                    ++r;
                }
            }
            res.topStakeWinner = bestPlayer;
            res.topStakeAmount = bestModified;
        }
        res.stakeFreeMoney = _stakeFreeMoneyView();
    }

    function _finalizeStakeResolution(uint24 level) internal returns (StakeResolution memory res) {
        StakeResolution storage stored = stakeResolutionInfo[level];
        if (stored.resolved) {
            return stored;
        }

        uint48 resDay = stakeResolutionDay[level];
        if (resDay == 0) {
            return stored;
        }
        CoinflipDayResult storage dayResult = coinflipDayResult[resDay];
        if (dayResult.rewardPercent == 0 && !dayResult.win) {
            return stored;
        }

        res = _stakeResolutionView(level);
        stored.winningRiskLevels = res.winningRiskLevels;
        stored.winningModifiedTotal = res.winningModifiedTotal;
        stored.stakeFreeMoney = res.stakeFreeMoney;
        stored.topStakeWinner = res.topStakeWinner;
        stored.topStakeAmount = res.topStakeAmount;
        stored.resolved = true;
        return stored;
    }

    function _viewClaimableCoin(address player) internal view returns (uint256 total) {
        // Pending flip winnings since last claim (up to 30 days)
        uint48 latestDay = _latestClaimableDayView();
        uint48 startDay = lastCoinflipClaim[player];
        uint8 remaining = 30;
        if (startDay < latestDay) {
            uint48 cursor = startDay + 1;
            while (remaining != 0 && cursor <= latestDay) {
                CoinflipDayResult storage result = coinflipDayResult[cursor];
                if (result.rewardPercent == 0 && !result.win) break;

                uint256 flipStake = coinflipBalance[cursor][player];
                if (flipStake != 0 && result.win) {
                    uint256 payout = flipStake + (flipStake * uint256(result.rewardPercent) * 100) / BPS_DENOMINATOR;
                    total += payout;
                }
                unchecked {
                    ++cursor;
                    --remaining;
                }
            }
        }

        // Pending stakes in the last 30 days of resolved levels
        uint48 currentDay = _currentDay();
        uint48 windowStart = currentDay > 30 ? currentDay - 30 : 0;
        uint24 lvl = stakeLevelComplete;
        uint24 scanned;

        // Only reuse the prior scan boundary when the window start hasn't shifted.
        uint24 lowerBound;
        if (lastStakeScanDay[player] == windowStart) {
            lowerBound = lastStakeScanLevel[player];
            if (lowerBound >= lvl) {
                lowerBound = 0;
            }
        }
        while (lvl != 0 && lvl > lowerBound && scanned < 400) {
            uint48 resDay = stakeResolutionDay[lvl];
            if (resDay == 0 || resDay < windowStart) {
                break;
            }

            CoinflipDayResult storage dayResult = coinflipDayResult[resDay];
            if (dayResult.rewardPercent == 0 && !dayResult.win) {
                break;
            }

            StakeResolution memory res = _stakeResolutionView(lvl);
            if (res.winningRiskLevels != 0) {
                StakePosition[] storage positions = stakePositions[player][lvl];
                uint256 len = positions.length;
                for (uint256 i; i < len; ) {
                    StakePosition storage position = positions[i];
                    if (!position.claimed && position.risk <= res.winningRiskLevels) {
                        uint256 base = position.principal * (uint256(1) << position.risk);
                        uint256 bonus;
                        if (res.stakeFreeMoney != 0 && res.winningModifiedTotal != 0) {
                            bonus = (position.modifiedAmount * res.stakeFreeMoney) / res.winningModifiedTotal;
                        }
                        total += base + bonus;
                    }
                    unchecked {
                        ++i;
                    }
                }
            }

            unchecked {
                --lvl;
                ++scanned;
            }
        }
    }

    function _claimStakePosition(
        address player,
        uint24 targetLevel,
        StakePosition storage position,
        StakeResolution memory res,
        bool mintPayout
    ) private returns (uint256 payout) {
        if (player == address(0)) revert ZeroAddress();
        if (position.claimed) revert StakeInvalid();
        if (position.risk == 0 || position.risk > MAX_RISK) revert StakeInvalid();

        bool won = res.winningRiskLevels != 0 && position.risk <= res.winningRiskLevels;
        position.claimed = true;
        if (!won) {
            emit StakeClaimed(player, targetLevel, position.risk, 0, false);
            return 0;
        }

        uint256 base = position.principal * (uint256(1) << position.risk);
        uint256 bonus;
        if (res.stakeFreeMoney != 0 && res.winningModifiedTotal != 0) {
            bonus = (position.modifiedAmount * res.stakeFreeMoney) / res.winningModifiedTotal;
        }
        payout = base + bonus;

        if (mintPayout) {
            _mint(player, payout);
            playerLuckbox[player] += payout;
        }
        _awardStakeTrophy(targetLevel, res);

        emit StakeClaimed(player, targetLevel, position.risk, payout, true);
    }

    function _claimRecentStakes(address player, uint48 windowStartDay) internal returns (uint256 total) {
        uint24 lvl = stakeLevelComplete;
        if (lvl == 0) return 0;

        // Only reuse the prior scan boundary when the window start hasn't shifted.
        uint24 lowerBound;
        if (lastStakeScanDay[player] == windowStartDay) {
            lowerBound = lastStakeScanLevel[player];
            if (lowerBound >= lvl) {
                lowerBound = 0;
            }
        }

        uint24 scanned;
        while (lvl != 0 && lvl > lowerBound && scanned < 400) {
            uint48 resDay = stakeResolutionDay[lvl];
            if (resDay == 0 || resDay < windowStartDay) {
                break;
            }

            CoinflipDayResult storage dayResult = coinflipDayResult[resDay];
            if (dayResult.rewardPercent == 0 && !dayResult.win) {
                break;
            }

            StakeResolution memory res = _finalizeStakeResolution(lvl);
            StakePosition[] storage positions = stakePositions[player][lvl];
            uint256 len = positions.length;
            for (uint256 i; i < len; ) {
                StakePosition storage position = positions[i];
                if (!position.claimed) {
                    total += _claimStakePosition(player, lvl, position, res, false);
                }
                unchecked {
                    ++i;
                }
            }

            unchecked {
                --lvl;
                ++scanned;
            }
        }

        // Cache the scan state for this window start.
        lastStakeScanDay[player] = windowStartDay;
        lastStakeScanLevel[player] = lvl;
    }

    /// @notice Burn PURGED to open a future stake targeting `targetLevel` with a risk radius.
    /// @dev
    /// - `burnAmt` must be at least 250e6 base units (token has 6 decimals).
    /// - `targetLevel` must be ahead of the current effective game level.
    /// - `risk` must be between 1 and `MAX_RISK` and cannot exceed the distance to `targetLevel`.
    /// - Records the stake with its distance, risk, original principal, and modified weighting used for prize splits.
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
        uint24 minDistance = currLevel > 20 ? 20 : currLevel;
        if (distance < minDistance) revert StakeInvalid();

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
        if (distance >= 20) {
            uint8 stakeTrophyBoost = purgeGameTrophies.stakeTrophyBonus(sender);
            if (stakeTrophyBoost != 0) {
                stepBps += (stepBps * stakeTrophyBoost) / 100;
            }
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

        // Encode and place the stake lane
        uint256 modifiedStake = boostedPrincipal - (boostedPrincipal % STAKE_PRINCIPAL_FACTOR);
        if (modifiedStake == 0) modifiedStake = STAKE_PRINCIPAL_FACTOR;
        IPurgeQuestModule module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleStake(
            sender,
            modifiedStake,
            distance,
            risk
        );
        uint256 questReward = _questApplyReward(sender, reward, hardMode, questType, streak, completed);
        if (questReward != 0) {
            uint256 bonus = questReward - (questReward % STAKE_PRINCIPAL_FACTOR);
            if (bonus != 0) {
                uint256 updated = modifiedStake + bonus;
                modifiedStake = updated;
            }
        }

        StakeTop storage top = stakeTopByLevelAndRisk[targetLevel][risk];
        if (modifiedStake > top.modifiedAmount) {
            top.modifiedAmount = modifiedStake;
            top.player = sender;
        }

        stakePositions[sender][targetLevel].push(
            StakePosition({
                principal: burnAmt,
                modifiedAmount: modifiedStake,
                distance: distance,
                risk: risk,
                claimed: false
            })
        );
        stakeModifiedTotals[targetLevel][risk] += modifiedStake;

        emit StakeCreated(sender, targetLevel, risk, burnAmt);
    }

    /// @notice Wire the game, NFT, renderers, and supporting modules using an address array.
    /// @dev Order: [game, nft, trophies, regular renderer, trophy renderer, quest module, jackpots]; set-once per slot.
    function wire(address[] calldata addresses) external {
        if (msg.sender != bonds) revert OnlyBonds();

        address game_ = addresses.length > 0 ? addresses[0] : address(0);
        address nft_ = addresses.length > 1 ? addresses[1] : address(0);
        address trophies_ = addresses.length > 2 ? addresses[2] : address(0);
        address regularRenderer_ = addresses.length > 3 ? addresses[3] : address(0);
        address trophyRenderer_ = addresses.length > 4 ? addresses[4] : address(0);
        address questModule_ = addresses.length > 5 ? addresses[5] : address(0);
        address jackpots_ = addresses.length > 6 ? addresses[6] : address(0);

        if (game_ != address(0)) {
            address currentGame = address(purgeGame);
            if (currentGame == address(0)) {
                purgeGame = IPurgeGame(game_);
            } else if (game_ != currentGame) {
                revert AlreadyWired();
            }
        }

        if (nft_ != address(0)) {
            address currentNft = address(purgeGameNFT);
            if (currentNft == address(0)) {
                purgeGameNFT = PurgeGameNFT(nft_);
            } else if (nft_ != currentNft) {
                revert AlreadyWired();
            }
        }

        if (trophies_ != address(0)) {
            address currentTrophies = address(purgeGameTrophies);
            if (currentTrophies == address(0)) {
                purgeGameTrophies = IPurgeGameTrophies(trophies_);
            } else if (trophies_ != currentTrophies) {
                revert AlreadyWired();
            }
        }

        if (questModule_ != address(0)) {
            address currentQuest = address(questModule);
            if (currentQuest == address(0)) {
                questModule = IPurgeQuestModule(questModule_);
            } else if (questModule_ != currentQuest) {
                revert AlreadyWired();
            }
        }

        if (jackpots_ != address(0)) {
            address currentJackpots = jackpots;
            if (currentJackpots == address(0)) {
                jackpots = jackpots_;
            } else if (jackpots_ != currentJackpots) {
                revert AlreadyWired();
            }
        }

        if (regularRenderer_ != address(0)) {
            IPurgeRenderer(regularRenderer_).wireContracts(address(purgeGame), address(purgeGameNFT));
        }
        if (trophyRenderer_ != address(0)) {
            IPurgeRenderer(trophyRenderer_).wireContracts(address(purgeGame), address(purgeGameNFT));
        }
        if (address(purgeGameNFT) != address(0) && address(purgeGameTrophies) != address(0)) {
            address[] memory nftWire = new address[](2);
            nftWire[0] = address(purgeGame);
            nftWire[1] = address(purgeGameTrophies);
            purgeGameNFT.wire(nftWire);

            address[] memory trophyWire = new address[](2);
            trophyWire[0] = address(purgeGame);
            trophyWire[1] = address(this);
            purgeGameTrophies.wireAndPrime(trophyWire, 1);
        }
        if (address(questModule) != address(0) && address(purgeGame) != address(0)) {
            questModule.wireGame(address(purgeGame));
        }
        if (address(jackpots) != address(0)) {
            address[] memory jackpotWire = new address[](3);
            jackpotWire[0] = address(this);
            jackpotWire[1] = address(purgeGame);
            jackpotWire[2] = address(purgeGameTrophies);
            IPurgeJackpots(jackpots).wire(jackpotWire);
        }
        _wireAffiliate(address(purgeGame), address(purgeGameTrophies));

        if (address(affiliateProgram) != address(0) && presaleClaimableRemaining == 0) {
            uint256 presaleTotal = affiliateProgram.presaleClaimableTotal();
            if (presaleTotal != 0) {
                presaleClaimableRemaining = presaleTotal;
                _mint(address(this), presaleTotal);
            }
        }
    }

    /// @notice Wire the game, NFT, renderers, and supporting modules required by Purgecoin.
    /// @dev Creator only; callable once.
    /// @notice Deprecated overload kept for compatibility; forwards to array-based wiring.
    function wire(
        address game_,
        address nft_,
        address trophies_,
        address regularRenderer_,
        address trophyRenderer_,
        address questModule_,
        address jackpots_
    ) external {
        address[] memory arr = new address[](7);
        arr[0] = game_;
        arr[1] = nft_;
        arr[2] = trophies_;
        arr[3] = regularRenderer_;
        arr[4] = trophyRenderer_;
        arr[5] = questModule_;
        arr[6] = jackpots_;
        wire(arr);
    }

    function wireAffiliate(address affiliate_) external {
        if (msg.sender != bonds || affiliateOverride) revert OnlyBonds();
        if (affiliate_ == address(0)) revert ZeroAddress();
        affiliateOverride = true;
        affiliateProgram = PurgeAffiliate(affiliate_);
        _wireAffiliate(address(purgeGame), address(purgeGameTrophies));
    }

    function _wireAffiliate(address game_, address trophies_) internal {
        address affiliateAddr = address(affiliateProgram);
        if (affiliateAddr == address(0)) return;
        affiliateProgram.wire(address(this), game_, trophies_);
        address payer = address(purgeGameNFT);
        if (payer != address(0)) {
            affiliateProgram.setPayer(payer);
        }
    }

    /// @notice Mint PURGE to the bonds contract for bond payouts (game only).
    function bondPayment(address to, uint256 amount) external {
        address sender = msg.sender;
        if (sender != address(purgeGame) && sender != bonds) revert OnlyGame();
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
        if (to == bonds) {
            IPurgeBonds(to).onBondMint(amount);
        }
    }

    /// @notice Grant a pending coinflip stake during gameplay flows instead of minting PURGE.
    /// @dev Access: PurgeGame, NFT, or trophy module only. Zero address is ignored. Optional luckbox bonus credited directly.
    function bonusCoinflip(address player, uint256 amount) external onlyGameplayContracts {
        if (player == address(0)) return;
        if (amount != 0) {
            addFlip(player, amount, false, false, false);
        }
    }

    /// @notice Credit a coinflip stake from the affiliate program.
    /// @dev Access: affiliate contract only; zero address is ignored.
    function affiliateAddFlip(address player, uint256 amount) external {
        if (msg.sender != address(affiliateProgram)) revert OnlyGame();
        if (player == address(0) || amount == 0) return;
        addFlip(player, amount, false, false, false);
    }

    /// @notice Batch credit up to three affiliate/upline flip stakes in a single call.
    /// @dev Access: affiliate contract only; zero amounts or addresses are skipped.
    function affiliateAddFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external {
        if (msg.sender != address(affiliateProgram)) revert OnlyGame();
        for (uint256 i; i < 3; ) {
            address player = players[i];
            uint256 amount = amounts[i];
            if (player != address(0) && amount != 0) {
                addFlip(player, amount, false, false, false);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Compute affiliate quest rewards while preserving quest module access control.
    /// @dev Access: affiliate contract only.
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256 questReward) {
        if (msg.sender != address(affiliateProgram)) revert OnlyGame();
        IPurgeQuestModule module = questModule;
        if (address(module) == address(0) || player == address(0) || amount == 0) return 0;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleAffiliate(
            player,
            amount
        );
        return _questApplyReward(player, reward, hardMode, questType, streak, completed);
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

    /// @notice Normalize purge quests mid-day when extermination ends the purge window.
    function normalizeActivePurgeQuests() external onlyPurgeGameContract {
        IPurgeQuestModule module = questModule;
        if (address(module) == address(0)) return;
        module.normalizeActivePurgeQuests();
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

    /// @notice Record the stake resolution day for a level (invoked by PurgeGame at end of state 1).
    /// @dev The first call at the start of level 2 is considered the level-1 resolution.
    function recordStakeResolution(uint24 level, uint48 day) external onlyPurgeGameContract {
        if (level == 0) return;
        uint48 setDay = day == 0 ? _currentDay() : day;
        if (setDay == 0) return;
        stakeResolutionDay[level] = setDay;
        stakeLevelComplete = level;
        _finalizeStakeResolution(level);
    }

    function _claimCoinflipsInternal(
        address player,
        uint8 maxDays,
        bool mintPayout
    ) internal returns (uint256 claimed) {
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

            if (result.rewardPercent == 0 && !result.win) {
                break; // day not settled yet; keep stake intact
            }

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
        if (mintPayout && claimed != 0) {
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

    function _latestClaimableDayView() internal view returns (uint48) {
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
        cap;
        level;
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

        uint256 seedWord = rngWord;
        if (epoch != 0) {
            seedWord = uint256(keccak256(abi.encodePacked(rngWord, epoch)));
        }

        uint256 roll = seedWord % 20; // ~5% each for the low/high outliers
        uint16 rewardPercent;
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

        bool win = (rngWord & 1) == 1;

        CoinflipDayResult storage dayResult = coinflipDayResult[day];
        dayResult.rewardPercent = rewardPercent;
        dayResult.win = win;

        // Bounty: convert any owed bounty into a flip credit once per window.
        if (bountyOwedTo != address(0) && currentBounty > 0) {
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

        currentFlipDay = day + 1;

        if (priceCoinUnit != 0) {
            _addToBounty(priceCoinUnit);
        }

        // Pay top flip bonus for the settled window; credits land in the next flip window.
        _rewardTopFlipBonus(day, priceCoinUnit);

        emit CoinflipFinished(win);
        return true;
    }

    function addToBounty(uint256 amount) external onlyPurgeGameContract {
        if (amount == 0) return;
        _addToBounty(amount);
    }

    function rewardTopFlipBonus(uint48 day, uint256 amount) external onlyPurgeGameContract {
        _rewardTopFlipBonus(day, amount);
    }

    /// @notice Return the top coinflip bettor recorded for a given level.
    /// @dev Reads the level keyed leaderboard; falls back to the live entry when querying the active level.
    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score) {
        PlayerScore memory stored = coinflipTopByLevel[lvl];
        if (lvl == purgeGame.level() && stored.player == address(0)) {
            stored = topBettor;
        }
        return (stored.player, stored.score);
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
        uint256 claimedFlips = _claimCoinflipsInternal(player, 30, false);
        uint48 currentDay = _currentDay();
        uint48 windowStart = currentDay > 30 ? currentDay - 30 : 0;
        uint256 claimedStakes = _claimRecentStakes(player, windowStart);
        uint256 totalClaimed = claimedFlips + claimedStakes;
        uint256 mintRemainder;

        if (coinflipDeposit > totalClaimed) {
            uint256 recycled = coinflipDeposit - totalClaimed;
            uint256 bonus = recycled / 100;
            uint256 bonusCap = 500 * MILLION;
            if (bonus > bonusCap) bonus = bonusCap;
            coinflipDeposit += bonus;
        } else if (totalClaimed > coinflipDeposit) {
            mintRemainder = totalClaimed - coinflipDeposit;
        }
        if (mintRemainder != 0) {
            _mint(player, mintRemainder);
            playerLuckbox[player] += mintRemainder;
        }

        uint48 settleDay = _syncFlipDay();
        bool rngLocked = purgeGame.rngLocked();
        uint48 targetDay = settleDay + (rngLocked ? 2 : 1);
        uint48 nowDay = _currentDay();
        if (targetDay <= nowDay) {
            targetDay = nowDay + 1;
        }

        uint256 prevStake = coinflipBalance[targetDay][player];

        uint256 newStake = prevStake + coinflipDeposit;
        uint256 eligibleStake = bountyEligible ? newStake : prevStake;

        coinflipBalance[targetDay][player] = newStake;

        // When BAF is active, capture a persistent roster entry + index for scatter.
        if (purgeGame.isBafLevelActive(purgeGame.level())) {
            uint24 bafLvl = purgeGame.level();
            address module = jackpots;
            if (module == address(0)) revert ZeroAddress();
            IPurgeJackpots(module).recordBafFlip(player, bafLvl, coinflipDeposit);
        }

        if (!skipLuckboxCheck && playerLuckbox[player] == 0) {
            playerLuckbox[player] = 1;
        }
        // Allow leaderboard churn even while RNG is locked; only freeze global records to avoid post-RNG manipulation.
        _updateTopBettor(player, newStake, targetDay, purgeGame.level());

        if (!rngLocked) {
            uint256 record = biggestFlipEver;
            address leader = topBettor.player;
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

    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    function _updateTopBettor(address player, uint256 stakeScore, uint48 day, uint24 lvl) private {
        uint96 score = _score96(stakeScore);
        PlayerScore memory candidate = PlayerScore({player: player, score: score});

        PlayerScore memory current = topBettor;
        if (score > current.score || current.player == address(0)) {
            topBettor = candidate;
        }

        PlayerScore memory dayLeader = coinflipTopByDay[day];
        if (score > dayLeader.score || dayLeader.player == address(0)) {
            coinflipTopByDay[day] = candidate;
        }

        PlayerScore memory levelLeader = coinflipTopByLevel[lvl];
        if (score > levelLeader.score || levelLeader.player == address(0)) {
            coinflipTopByLevel[lvl] = candidate;
        }
    }

    function _rewardTopFlipBonus(uint48 day, uint256 amount) private {
        if (amount == 0) return;
        // Prefer the recorded leader for the requested day; fall back to current-level leader if missing.
        PlayerScore memory entry = coinflipTopByDay[day];
        if (entry.player == address(0)) {
            entry = coinflipTopByLevel[purgeGame.level()];
        }
        if (entry.player == address(0)) return;

        addFlip(entry.player, amount, false, false, true);
    }
}
