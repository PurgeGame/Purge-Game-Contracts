// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "../interfaces/DegenerusGameModuleInterfaces.sol";
import {IDegenerusBondsJackpot} from "../interfaces/IDegenerusBondsJackpot.sol";
import {IStETH} from "../interfaces/IStETH.sol";
import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";
import {DegenerusTraitUtils} from "../DegenerusTraitUtils.sol";

/**
 * @title DegenerusGameJackpotModule
 * @author Burnie Degenerus
 * @notice Delegate-called module that hosts the jackpot distribution logic for `DegenerusGame`.
 *
 * @dev ARCHITECTURE NOTES:
 *      - This contract is ONLY meant to be invoked via `delegatecall` from the main game contract.
 *      - Storage layout inherits from `DegenerusGameStorage` to ensure slot alignment with the parent.
 *      - All external functions lack access modifiers intentionally; the parent contract controls access.
 *      - DO NOT deploy this contract standalone or call it directly—state would be written to the
 *        module's own storage rather than the game's.
 *
 *      JACKPOT FLOW OVERVIEW:
 *      1. `calcPrizePoolForLevelJackpot` — Computes pool splits (reward vs prize vs level jackpot) at level start.
 *      2. `payLevelJackpot` — Distributes the level jackpot after purchases close.
 *      3. `payDailyJackpot` — Handles early-burn rewards during purchase phase and rolling dailies at EOL.
 *      4. `payDailyMapJackpot` — Separate MAP ticket draw after daily jackpot settlement.
 *      5. `payExterminationJackpot` / `payCarryoverExterminationJackpot` — Trait-specific payouts during burns.
 *      6. `processMapBatch` — Batched airdrop processing with gas budgeting to stay block-safe.
 *
 *      FUND ACCOUNTING:
 *      - ETH flows through `rewardPool`, `currentPrizePool`, `nextPrizePool`, `claimablePool`, `bondPool`.
 *      - The solo bucket in any distribution absorbs remainder to prevent dust accumulation.
 *      - `claimableWinnings` tracks per-player ETH; `claimablePool` is the aggregate liability.
 *
 *      RANDOMNESS:
 *      - All entropy originates from VRF words passed by the parent contract.
 *      - Internal `_entropyStep` provides deterministic derivation for sub-selections.
 *      - Winner selection intentionally allows duplicates (more tickets = more chances).
 */
contract DegenerusGameJackpotModule is DegenerusGameStorage {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when ETH is credited to a player's claimable balance.
    /// @param player The original winner (ticket holder).
    /// @param recipient The address receiving the credit (same as player in current impl).
    /// @param amount Wei credited.
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);

    /// @notice A MAP jackpot is already queued.
    error MapJackpotPending();

    // -------------------------------------------------------------------------
    // Constants — MAP Jackpot Type (unified pending state)
    // -------------------------------------------------------------------------

    /// @dev No MAP jackpot pending.
    uint8 private constant MAP_JACKPOT_NONE = 0;

    /// @dev Daily MAP jackpot pending (burn phase).
    uint8 private constant MAP_JACKPOT_DAILY = 1;

    /// @dev Purchase-phase MAP jackpot pending (level/early-burn).
    uint8 private constant MAP_JACKPOT_PURCHASE = 2;

    // -------------------------------------------------------------------------
    // Constants — Timing & Thresholds
    // -------------------------------------------------------------------------

    /// @dev Seconds offset from midnight UTC for daily jackpot reset boundary (22:57 UTC).
    uint48 private constant JACKPOT_RESET_TIME = 82620;

    /// @dev Maximum number of daily jackpots per level before forcing level transition.
    uint8 private constant JACKPOT_LEVEL_CAP = 10;

    /// @dev Sentinel value for degenerate entropy detection (Easter egg: 420).
    uint256 private constant DEGENERATE_ENTROPY_CHECK_VALUE = 420;

    // -------------------------------------------------------------------------
    // Constants — Share Distribution (Basis Points)
    // -------------------------------------------------------------------------

    /// @dev Level jackpot trait bucket shares packed into 64 bits: [6000, 1333, 1333, 1334] = 10000 bps.
    ///      With rotation, the 60% share is assigned to the solo (1-winner) bucket.
    uint64 private constant LEVEL_JACKPOT_SHARES_PACKED =
        (uint64(6000)) | (uint64(1333) << 16) | (uint64(1333) << 32) | (uint64(1334) << 48);

    /// @dev Daily jackpot trait bucket shares: 2000 bps each × 4 = 8000 bps (remaining 20% absorbed by solo bucket).
    uint64 private constant DAILY_JACKPOT_SHARES_PACKED = uint64(2000) * 0x0001000100010001;

    // -------------------------------------------------------------------------
    // Constants — Entropy Salts
    // -------------------------------------------------------------------------

    /// @dev Domain separator for coin jackpot entropy derivation.
    bytes32 private constant COIN_JACKPOT_TAG = keccak256("coin-jackpot");

    /// @dev Domain separator for carryover bonus roll derivation.
    bytes32 private constant CARRYOVER_BONUS_TAG = keccak256("carryover_bonus");

    /// @dev Domain separator for carryover 3d4 dice roll derivation.
    bytes32 private constant CARRYOVER_3D4_SALT = keccak256("carryover-3d4");

    /// @dev Domain separator for dailyMapJackpot draw entropy.
    bytes32 private constant DAILY_MAP_TAG = keccak256("daily-map-jackpot");

    /// @dev Domain separator for dailyMapJackpot carryover draw entropy.
    bytes32 private constant DAILY_MAP_NEXT_TAG = keccak256("daily-map-jackpot-next");

    /// @dev Domain separator for level jackpot MAP draw entropy.
    bytes32 private constant LEVEL_MAP_TAG = keccak256("level-map-jackpot");

    /// @dev Domain separator for early-burn MAP draw entropy.
    bytes32 private constant EARLY_BURN_MAP_TAG = keccak256("early-burn-map-jackpot");

    // -------------------------------------------------------------------------
    // Constants — Daily Jackpot Sizing (Escalating BPS)
    // -------------------------------------------------------------------------

    /// @dev Per-jackpot basis points of dailyJackpotBase. Sums to 9156 bps (~91.56%).
    ///      Roughly 2× growth from first (610) to last (1225) to reward patience.
    uint16 private constant DAILY_JACKPOT_BPS_0 = 610;
    uint16 private constant DAILY_JACKPOT_BPS_1 = 677;
    uint16 private constant DAILY_JACKPOT_BPS_2 = 746;
    uint16 private constant DAILY_JACKPOT_BPS_3 = 813;
    uint16 private constant DAILY_JACKPOT_BPS_4 = 881;
    uint16 private constant DAILY_JACKPOT_BPS_5 = 949;
    uint16 private constant DAILY_JACKPOT_BPS_6 = 1017;
    uint16 private constant DAILY_JACKPOT_BPS_7 = 1085;
    uint16 private constant DAILY_JACKPOT_BPS_8 = 1153;
    uint16 private constant DAILY_JACKPOT_BPS_9 = 1225;

    // -------------------------------------------------------------------------
    // Constants — Gas Budgeting (Map Batch Processing)
    // -------------------------------------------------------------------------

    /// @dev Default SSTORE budget for processMapBatch to stay safely under 15M gas.
    uint32 private constant WRITES_BUDGET_SAFE = 780;

    /// @dev Minimum writes budget to ensure progress even with very low caps.
    uint32 private constant WRITES_BUDGET_MIN = 8;

    /// @dev LCG multiplier for deterministic trait generation (Knuth's MMIX constant).
    uint64 private constant MAP_LCG_MULT = 0x5851F42D4C957F2D;

    // -------------------------------------------------------------------------
    // Constants — Bond Integration
    // -------------------------------------------------------------------------

    /// @dev Bond BPS for daily/early-burn jackpots (disabled = 0).
    uint16 private constant BOND_BPS_DAILY = 0;

    /// @dev Base bucket size for "large bucket" bond winner selection.
    uint16 private constant MAIN_LARGE_BUCKET_SIZE = 25;

    /// @dev Number of bond winners per base large bucket (scaled by bucket size).
    uint16 private constant MAIN_LARGE_BUCKET_BOND_WINNERS = 12;

    /// @dev Bond purchase percentage for solo level jackpot winners (25%).
    uint16 private constant LEVEL_JACKPOT_SOLO_BOND_BPS = 2500;

    /// @dev Bond purchase percentage for solo daily winners (50%).
    uint16 private constant DAILY_SOLO_BOND_BPS = 5000;

    /// @dev Portion of level jackpot ETH converted to MAP tickets (20%).
    uint16 private constant LEVEL_JACKPOT_MAP_BPS = 2000;

    /// @dev Portion of daily jackpot ETH converted to MAP tickets (20%).
    uint16 private constant DAILY_JACKPOT_MAP_BPS = 2000;

    /// @dev Portion of reward-pool-funded daily jackpot ETH converted to MAP tickets (50%).
    uint16 private constant DAILY_REWARD_JACKPOT_MAP_BPS = 5000;

    /// @dev Max total MAP winners per MAP jackpot draw.
    ///      250 winners × ~54k gas = ~13.5M gas worst case (under 16M limit).
    uint16 private constant DAILY_MAP_MAX_WINNERS = 250;

    /// @dev Max winners per single trait bucket (must fit in uint8 for _randTraitTicket).
    ///      Set to 250 to allow all MAP winners in single trait if others are empty.
    uint8 private constant MAX_BUCKET_WINNERS = 250;

    // -------------------------------------------------------------------------
    // Constants — Jackpot Bucket Scaling (Gas Guardrails)
    // -------------------------------------------------------------------------

    /// @dev Maximum total winners per jackpot payout (including solo bucket).
    uint16 private constant JACKPOT_MAX_WINNERS = 300;

    /// @dev Maximum total ETH winners across daily + carryover jackpots.
    uint16 private constant DAILY_ETH_MAX_WINNERS = 321;

    /// @dev Minimum pool size before scaling kicks in.
    uint256 private constant JACKPOT_SCALE_MIN_WEI = 10 ether;

    /// @dev First scale target (2x) by this pool size.
    uint256 private constant JACKPOT_SCALE_FIRST_WEI = 50 ether;

    /// @dev Second scale target (4x) by this pool size; cap beyond.
    uint256 private constant JACKPOT_SCALE_SECOND_WEI = 200 ether;

    /// @dev Scale values in basis points.
    uint16 private constant JACKPOT_SCALE_BASE_BPS = 10_000;
    uint16 private constant JACKPOT_SCALE_FIRST_BPS = 20_000;
    uint16 private constant JACKPOT_SCALE_MAX_BPS = 40_000;

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @dev Mutable context passed through ETH distribution loops to track cumulative state.
    ///      Using a struct avoids stack-too-deep and makes the flow explicit.
    struct JackpotEthCtx {
        uint256 entropyState;     // Rolling entropy for winner selection.
        uint256 liabilityDelta;   // Cumulative claimable liability added this run.
        uint256 totalPaidEth;     // Total ETH paid out (including bond purchases).
    }

    /// @dev Packed parameters for a single jackpot execution. Keeps external call surface lean
    ///      and avoids passing 7+ parameters through multiple internal functions.
    struct JackpotParams {
        uint24 lvl;                      // Current game level (1-indexed).
        uint256 ethPool;                 // ETH available for this jackpot.
        uint256 coinPool;                // COIN available for this jackpot.
        uint256 entropy;                 // VRF-derived entropy for winner selection.
        uint32 winningTraitsPacked;      // 4 trait IDs packed into 32 bits (8 bits each).
        uint64 traitShareBpsPacked;      // 4 share percentages packed (16 bits each).
        IDegenerusCoinModule coinContract; // Coin module for COIN credits.
    }

    // =========================================================================
    // External Entry Points (delegatecall targets)
    // =========================================================================

    /// @notice Pays early-burn jackpots during purchase phase OR rolling daily jackpots at level end.
    /// @dev Called by the parent game contract via delegatecall. Two distinct paths:
    ///
    ///      DAILY PATH (isDaily=true):
    ///      - Distributes escalating slice of dailyJackpotBase to trait-based winners.
    ///      - Seeds next level's carryover jackpot from rewardPool.
    ///      - Queues MAP ticket distribution for a follow-up tx (if budgeted).
    ///      - Increments jackpotCounter; clears dailyBurnCount on completion.
    ///
    ///      EARLY-BURN PATH (isDaily=false):
    ///      - Triggered during purchase phase when early burns occur.
    ///      - Pays a rewardPool-funded ETH slice every third day (1% of rewardPool).
    ///      - Coin jackpots pay on non-ETH days, sized from lastPrizePool.
    ///
    /// @param isDaily True for scheduled daily jackpot, false for early-burn jackpot.
    /// @param lvl Current game level.
    /// @param randWord VRF entropy for winner selection and trait derivation.
    /// @param coinContract Coin module for COIN payouts and quest rolls.
    function payDailyJackpot(bool isDaily, uint24 lvl, uint256 randWord, IDegenerusCoinModule coinContract) external {
        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        uint32 winningTraitsPacked;

        if (isDaily) {
            winningTraitsPacked = _packWinningTraits(_getWinningTraits(randWord, dailyBurnCount));
            bool lastDaily = (jackpotCounter + 1) >= JACKPOT_LEVEL_CAP;
            uint256 budget = (dailyJackpotBase * _dailyJackpotBps(jackpotCounter)) / 10_000;

            (uint256 mapUnitsCurrent, uint256 mapCostCurrent) = _mapUnitsAndCost(budget, DAILY_JACKPOT_MAP_BPS);
            if (mapCostCurrent != 0 && !_hasTraitTickets(lvl, winningTraitsPacked)) {
                mapUnitsCurrent = 0;
                mapCostCurrent = 0;
            }
            if (mapCostCurrent != 0) {
                budget -= mapCostCurrent;
            }

            uint256 entropyDaily = randWord ^ (uint256(lvl) << 192);
            (uint16[4] memory baseBucketCountsDaily, uint16[4] memory bucketCountsDaily) =
                _bucketCountsForPool(budget, entropyDaily);
            bucketCountsDaily = _capBucketCounts(bucketCountsDaily, DAILY_ETH_MAX_WINNERS, entropyDaily);

            uint256 paidDailyEth = _runMainJackpotEthFlow(
                JackpotParams({
                    lvl: lvl,
                    ethPool: budget,
                    coinPool: 0,
                    entropy: entropyDaily,
                    winningTraitsPacked: winningTraitsPacked,
                    traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                    coinContract: coinContract
                }),
                baseBucketCountsDaily,
                bucketCountsDaily,
                DAILY_SOLO_BOND_BPS,
                MAIN_LARGE_BUCKET_SIZE,
                MAIN_LARGE_BUCKET_BOND_WINNERS,
                0
            );
            if (paidDailyEth != 0 || mapCostCurrent != 0) {
                currentPrizePool -= (paidDailyEth + mapCostCurrent);
            }
            if (mapCostCurrent != 0) {
                nextPrizePool += mapCostCurrent;
            }

            uint24 nextLevel = lvl + 1;
            uint256 futureEthPool;
            uint256 rewardSlice;
            uint16 carryoverMapBps;

            // On the last daily, push all leftover prize pool plus the standard 1% reward slice to the next level.
            if (lastDaily) {
                uint256 leftoverPool = currentPrizePool;
                currentPrizePool = 0;
                uint256 futurePoolBps = 100; // 1% reward pool contribution
                rewardSlice = (rewardPool * futurePoolBps * _rewardJackpotScaleBps(nextLevel)) / 100_000_000;
                rewardPool -= rewardSlice;
                futureEthPool = rewardSlice + leftoverPool;
                carryoverMapBps = _weightedDailyMapBps(rewardSlice, leftoverPool);
            } else {
                uint256 futurePoolBps = jackpotCounter == 0 ? 300 : 100; // 3% on first burn, else 1%
                if (jackpotCounter == 1) {
                    futurePoolBps += 100; // +1% boost on the second daily jackpot
                }
                futureEthPool = (rewardPool * futurePoolBps * _rewardJackpotScaleBps(nextLevel)) / 100_000_000;
                carryoverMapBps = DAILY_REWARD_JACKPOT_MAP_BPS;
            }

            (uint256 mapUnitsNext, uint256 mapCostNext) = _mapUnitsAndCost(futureEthPool, carryoverMapBps);
            if (mapCostNext != 0 && !_hasTraitTickets(nextLevel, winningTraitsPacked)) {
                mapUnitsNext = 0;
                mapCostNext = 0;
            }
            if (mapCostNext != 0) {
                futureEthPool -= mapCostNext;
                nextPrizePool += mapCostNext;
                if (!lastDaily) {
                    rewardPool -= mapCostNext;
                }
            }

            uint256 entropyNext = randWord ^ (uint256(nextLevel) << 192);
            (, uint16[4] memory bucketCountsNext) = _bucketCountsForPool(futureEthPool, entropyNext);
            uint256 totalDailyWinners = _sumBucketCounts(bucketCountsDaily);
            uint16 remainingCap = totalDailyWinners >= DAILY_ETH_MAX_WINNERS
                ? 0
                : uint16(DAILY_ETH_MAX_WINNERS - totalDailyWinners);
            bucketCountsNext = _capBucketCounts(bucketCountsNext, remainingCap, entropyNext);

            uint256 paidCarryEth;
            if (futureEthPool != 0) {
                uint8[4] memory traitIds = _unpackWinningTraits(winningTraitsPacked);
                uint16[4] memory shareBps = _shareBpsByBucket(
                    DAILY_JACKPOT_SHARES_PACKED,
                    uint8(entropyNext & 3)
                );
                paidCarryEth = _distributeJackpotEth(
                    nextLevel,
                    futureEthPool,
                    entropyNext,
                    traitIds,
                    shareBps,
                    bucketCountsNext,
                    coinContract,
                    bonds,
                    BOND_BPS_DAILY,
                    0
                );
            }
            if (!lastDaily && paidCarryEth != 0) {
                rewardPool -= paidCarryEth;
            }

            bool mapPending = (mapUnitsCurrent != 0 || mapUnitsNext != 0);
            if (mapPending) {
                mapJackpotUnits1 = mapUnitsCurrent;
                mapJackpotUnits2 = mapUnitsNext;
                mapJackpotType = MAP_JACKPOT_DAILY;
            }

            unchecked {
                ++jackpotCounter;
            }
            if (!mapPending) {
                _clearDailyBurnCount();
            }

            _rollQuestForJackpot(coinContract, randWord, false, questDay);
            return;
        }

        // Non-daily (early-burn) path.
        winningTraitsPacked = _packWinningTraits(_getRandomTraits(randWord));

        bool isEthDay = (questDay % 3) == 0;
        uint256 rewardPoolSlice;
        if (isEthDay) {
            uint256 poolBps = 100; // 1% of rewardPool every third day
            rewardPoolSlice = (rewardPool * poolBps * _rewardJackpotScaleBps(lvl)) / 100_000_000;
        }

        uint256 ethPool = rewardPoolSlice;
        uint256 mapUnits;
        uint256 mapCost;
        if (ethPool != 0) {
            (mapUnits, mapCost) = _mapUnitsAndCost(ethPool, DAILY_REWARD_JACKPOT_MAP_BPS);
            if (mapCost != 0 && !_hasTraitTickets(lvl, winningTraitsPacked)) {
                mapUnits = 0;
                mapCost = 0;
            }
            if (mapCost != 0) {
                ethPool -= mapCost;
            }
        }
        uint256 coinPool;
        uint256 priceWei = price;
        if (!isEthDay && priceWei != 0) {
            uint256 coinEquivalent = (lastPrizePool * PRICE_COIN_UNIT) / priceWei;
            coinPool = coinEquivalent / 200; // 0.5% of coin-equivalent lastPrizePool
        }
        uint256 paidEth = _executeJackpot(
            JackpotParams({
                lvl: lvl,
                ethPool: ethPool,
                coinPool: coinPool,
                entropy: randWord ^ (uint256(lvl) << 192),
                winningTraitsPacked: winningTraitsPacked,
                traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                coinContract: coinContract
            }),
            false,
            false,
            BOND_BPS_DAILY,
            0
        );

        // Only the reward pool-funded slice should reduce reward pool accounting.
        rewardPool -= paidEth;
        if (mapCost != 0) {
            rewardPool -= mapCost;
            nextPrizePool += mapCost;
        }
        if (mapUnits != 0) {
            if (mapJackpotType != MAP_JACKPOT_NONE) revert MapJackpotPending();
            mapJackpotType = MAP_JACKPOT_PURCHASE;
            mapJackpotUnits1 = mapUnits;
        }
        _rollQuestForJackpot(coinContract, randWord, false, questDay);
    }

    /// @notice Pays the queued MAP jackpot (daily or purchase) in a separate transaction.
    /// @dev Branches based on mapJackpotType:
    ///      - DAILY (1): Uses burn-weighted traits, splits winners across current + carryover levels.
    ///      - PURCHASE (2): Uses random traits, single draw for current level only.
    /// @param lvl Current game level.
    /// @param randWord VRF entropy for winner selection.
    function payMapJackpot(uint24 lvl, uint256 randWord) external {
        uint8 jackpotType = mapJackpotType;
        if (jackpotType == MAP_JACKPOT_NONE) return;

        mapJackpotType = MAP_JACKPOT_NONE;

        if (jackpotType == MAP_JACKPOT_DAILY) {
            _payDailyMapJackpotInternal(lvl, randWord);
        } else {
            _payPurchaseMapJackpotInternal(lvl, randWord);
        }
    }

    /// @dev Internal logic for daily MAP jackpot distribution.
    function _payDailyMapJackpotInternal(uint24 lvl, uint256 randWord) private {
        uint256 unitsCurrent = mapJackpotUnits1;
        uint256 unitsNext = mapJackpotUnits2;

        if (unitsCurrent == 0 && unitsNext == 0) {
            _clearDailyBurnCount();
            return;
        }

        uint32 traitsPacked = _packWinningTraits(_getWinningTraits(randWord, dailyBurnCount));

        uint256 totalUnits = unitsCurrent + unitsNext;
        uint16 totalCap = totalUnits < DAILY_MAP_MAX_WINNERS ? uint16(totalUnits) : DAILY_MAP_MAX_WINNERS;

        uint16 capCurrent;
        uint16 capNext;
        if (unitsCurrent != 0 && unitsNext != 0) {
            capCurrent = uint16((uint256(totalCap) * unitsCurrent) / totalUnits);
            capNext = uint16((uint256(totalCap) * unitsNext) / totalUnits);

            if (capCurrent == 0) capCurrent = 1;
            if (capNext == 0) capNext = 1;

            uint16 assigned = capCurrent + capNext;
            if (assigned > totalCap) {
                uint16 excess = assigned - totalCap;
                if (capCurrent >= capNext) {
                    capCurrent -= excess;
                } else {
                    capNext -= excess;
                }
            } else if (assigned < totalCap) {
                uint256 remCurrent = (uint256(totalCap) * unitsCurrent) % totalUnits;
                uint256 remNext = (uint256(totalCap) * unitsNext) % totalUnits;
                if (remNext > remCurrent) {
                    capNext += totalCap - assigned;
                } else {
                    capCurrent += totalCap - assigned;
                }
            }
        } else if (unitsCurrent != 0) {
            capCurrent = totalCap;
        } else {
            capNext = totalCap;
        }

        if (unitsCurrent != 0) {
            uint256 entropy = randWord ^ (uint256(lvl) << 192) ^ uint256(DAILY_MAP_TAG);
            _distributeMapJackpot(lvl, traitsPacked, unitsCurrent, entropy, capCurrent, 220);
        }
        if (unitsNext != 0) {
            uint24 nextLevel = lvl + 1;
            uint256 entropyNext = randWord ^ (uint256(nextLevel) << 192) ^ uint256(DAILY_MAP_NEXT_TAG);
            _distributeMapJackpot(nextLevel, traitsPacked, unitsNext, entropyNext, capNext, 232);
        }

        _clearDailyBurnCount();
    }

    /// @dev Internal logic for purchase-phase MAP jackpot distribution.
    function _payPurchaseMapJackpotInternal(uint24 lvl, uint256 randWord) private {
        uint256 units = mapJackpotUnits1;
        if (units == 0) return;

        uint32 traitsPacked = _packWinningTraits(_getRandomTraits(randWord));
        bytes32 tag = levelJackpotPaid ? LEVEL_MAP_TAG : EARLY_BURN_MAP_TAG;
        uint256 entropy = randWord ^ (uint256(lvl) << 192) ^ uint256(tag);
        _distributeMapJackpot(lvl, traitsPacked, units, entropy, DAILY_MAP_MAX_WINNERS, 244);
    }

    /// @notice Pays a trait-restricted jackpot during extermination phase.
    /// @dev Called when a trait is being exterminated. All four bucket slots use the SAME trait ID
    ///      so that only holders of the exterminated trait can win. Uses daily jackpot share/bucket
    ///      sizing but draws exclusively from the single trait's ticket pool.
    ///
    /// @param lvl Current game level.
    /// @param traitId The trait being exterminated (0-255).
    /// @param randWord VRF entropy for winner selection.
    /// @param ethPool ETH allocated for this extermination jackpot.
    /// @param coinContract Coin module (unused for ETH-only extermination jackpots).
    /// @return paidEth Actual ETH distributed to winners.
    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        uint256 ethPool,
        IDegenerusCoinModule coinContract
    ) external returns (uint256 paidEth) {
        // Pack the same trait into all 4 slots — ensures all buckets draw from the same trait pool.
        uint32 packedTrait = uint32(traitId);
        packedTrait |= uint32(traitId) << 8;
        packedTrait |= uint32(traitId) << 16;
        packedTrait |= uint32(traitId) << 24;

        paidEth = _executeJackpot(
            JackpotParams({
                lvl: lvl,
                ethPool: ethPool,
                coinPool: 0,
                entropy: randWord ^ (uint256(lvl) << 192),
                winningTraitsPacked: packedTrait,
                traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                coinContract: coinContract
            }),
            false,
            false,
            BOND_BPS_DAILY,
            0
        );
    }

    /// @notice Pays a post-extermination carryover jackpot for the NEXT level's ticket holders.
    /// @dev After a trait is exterminated, this rewards players who already hold tickets for the
    ///      upcoming level. Funded from rewardPool at 1% (scaled by level position in 100-level band).
    ///      Also triggers a quest roll for the jackpot day.
    ///
    /// @param lvl Target level for ticket lookup (typically current level + 1).
    /// @param traitId The exterminated trait whose holders are rewarded.
    /// @param randWord VRF entropy for winner selection.
    /// @param coinContract Coin module for quest rolls.
    /// @return paidEth Actual ETH distributed (debited from rewardPool).
    function payCarryoverExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        IDegenerusCoinModule coinContract
    ) external returns (uint256 paidEth) {
        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        // 1% of rewardPool, scaled down as level progresses through 100-level band.
        uint256 ethPool = (rewardPool * 100 * _rewardJackpotScaleBps(lvl)) / 100_000_000;

        if (ethPool != 0) {
            uint32 packedTrait = uint32(traitId);
            packedTrait |= uint32(traitId) << 8;
            packedTrait |= uint32(traitId) << 16;
            packedTrait |= uint32(traitId) << 24;

            paidEth = _executeJackpot(
                JackpotParams({
                    lvl: lvl,
                    ethPool: ethPool,
                    coinPool: 0,
                    entropy: randWord ^ (uint256(lvl) << 192),
                    winningTraitsPacked: packedTrait,
                    traitShareBpsPacked: DAILY_JACKPOT_SHARES_PACKED,
                    coinContract: coinContract
                }),
                false,
                false,
                BOND_BPS_DAILY,
                0
            );

            if (paidEth != 0) {
                rewardPool -= paidEth;
            }
        }

        _rollQuestForJackpot(coinContract, randWord, false, questDay);
    }

    /// @notice Pays the level jackpot at the end of the purchase phase.
    /// @dev The flagship jackpot with 60/13/13/14 share distribution. Uses the "main" flow which
    ///      supports solo bond purchases (25% for single winners) and large-bucket bond distribution.
    ///      Unpaid ETH rolls into currentPrizePool for daily jackpots.
    ///
    /// @param lvl Current game level.
    /// @param rngWord VRF entropy for trait and winner selection.
    /// @param effectiveWei Total ETH allocated for the level jackpot (from calcPrizePoolForLevelJackpot).
    /// @param coinContract Coin module for quest rolls.
    function payLevelJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IDegenerusCoinModule coinContract
    ) external {
        uint8[4] memory winningTraits = _getRandomTraits(rngWord);
        uint32 winningTraitsPacked = _packWinningTraits(winningTraits);

        uint256 ethPool = effectiveWei;
        uint256 mapUnits;
        uint256 mapCost;
        if (ethPool != 0) {
            (mapUnits, mapCost) = _mapUnitsAndCost(ethPool, LEVEL_JACKPOT_MAP_BPS);
            if (mapCost != 0 && !_hasTraitTickets(lvl, winningTraitsPacked)) {
                mapUnits = 0;
                mapCost = 0;
            }
            if (mapCost != 0) {
                ethPool -= mapCost;
            }
        }

        (uint16[4] memory baseBucketCounts, uint16[4] memory bucketCounts) =
            _bucketCountsForPool(ethPool, rngWord);

        // Main jackpot flow with bond integration for solo and large-bucket winners.
        uint256 paidEth = _runMainJackpotEthFlow(
            JackpotParams({
                lvl: lvl,
                ethPool: ethPool,
                coinPool: 0,
                entropy: rngWord,
                winningTraitsPacked: winningTraitsPacked,
                traitShareBpsPacked: LEVEL_JACKPOT_SHARES_PACKED,
                coinContract: coinContract
            }),
            baseBucketCounts,
            bucketCounts,
            LEVEL_JACKPOT_SOLO_BOND_BPS,
            MAIN_LARGE_BUCKET_SIZE,
            MAIN_LARGE_BUCKET_BOND_WINNERS,
            0
        );
        currentPrizePool += (ethPool - paidEth);
        if (mapCost != 0) {
            nextPrizePool += mapCost;
        }
        if (mapUnits != 0) {
            if (mapJackpotType != MAP_JACKPOT_NONE) revert MapJackpotPending();
            mapJackpotType = MAP_JACKPOT_PURCHASE;
            mapJackpotUnits1 = mapUnits;
        }

        uint48 questDay = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        _rollQuestForJackpot(coinContract, rngWord, true, questDay);
    }

    /// @notice Computes and applies prize pool splits at the start of a new level's jackpot phase.
    /// @dev This is the "budgeting" function that determines how ETH flows between pools:
    ///
    ///      FLOW:
    ///      1. Merge nextPrizePool into currentPrizePool.
    ///      2. Compute rewardPool retention % based on level and RNG (higher at end of 100-level bands).
    ///      3. Adjust retention based on flip activity trends.
    ///      4. Split remainder into level jackpot (20-40%) and daily jackpot base.
    ///      5. On level % 100, optionally add yield surplus (stETH appreciation) to rewardPool.
    ///
    /// @param lvl Current game level.
    /// @param rngWord VRF entropy for percentage rolls.
    /// @param stethAddr stETH contract address for balance checks.
    /// @return effectiveWei ETH allocated for the level jackpot.
    function calcPrizePoolForLevelJackpot(
        uint24 lvl,
        uint256 rngWord,
        address stethAddr
    ) external returns (uint256 effectiveWei) {
        // Consolidate pools for this level's jackpot calculations.
        currentPrizePool += nextPrizePool;
        nextPrizePool = 0;

        uint256 totalWei = rewardPool + currentPrizePool;
        uint256 levelJackpotPct;
        uint256 levelJackpotWei;
        uint256 mainWei;

        (uint256 savePctTimes2, uint256 level100RollTotal) = _mapRewardPoolPercent(lvl, rngWord);
        savePctTimes2 = _adjustRewardPoolForFlipTotals(savePctTimes2);
        uint256 _rewardPool = (totalWei * savePctTimes2) / 200;
        rewardPool = _rewardPool;

        uint256 jackpotBase = totalWei - _rewardPool;
        levelJackpotPct = _levelJackpotPercent(lvl, rngWord);
        levelJackpotWei = (jackpotBase * levelJackpotPct) / 100;

        unchecked {
            mainWei = jackpotBase - levelJackpotWei;
        }

        lastPrizePool = currentPrizePool;
        currentPrizePool = mainWei;
        dailyJackpotBase = mainWei;

        effectiveWei = levelJackpotWei;

        if ((lvl % 100) == 0) {
            uint256 stBal = IStETH(stethAddr).balanceOf(address(this));
            uint256 totalBal = address(this).balance + stBal;
            uint256 obligations = currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool;
            uint256 bafPool = bafHundredPool;
            if (bafPool != 0) {
                unchecked {
                    obligations += bafPool;
                }
            }
            uint256 decPool = decimatorHundredPool;
            if (decPool != 0) {
                unchecked {
                    obligations += decPool;
                }
            }
            if (totalBal > obligations && level100RollTotal < 5) {
                uint256 yieldPool = totalBal - obligations;
                uint256 bonus = yieldPool / 2;
                rewardPool += bonus;
            }
        }
    }

    // =========================================================================
    // Internal Helpers — Claimable ETH
    // =========================================================================

    /// @dev Credits ETH to a player's claimable balance. Uses unchecked arithmetic because
    ///      uint256 overflow is practically impossible with real ETH amounts.
    /// @param beneficiary Address to credit.
    /// @param weiAmount Wei to add to their claimable balance.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
        address recipient = beneficiary;
        // SAFETY: uint256 max is ~10^77 wei; overflow impossible in practice.
        unchecked {
            claimableWinnings[recipient] += weiAmount;
        }
        emit PlayerCredited(beneficiary, recipient, weiAmount);
    }

    /// @dev Queue MAP tickets for batch processing.
    function _queueRewardMaps(address buyer, uint32 quantity) private {
        if (quantity == 0) return;

        uint32 owed = playerMapMintsOwed[buyer];
        if (owed == 0) {
            pendingMapMints.push(buyer);
        }
        unchecked {
            playerMapMintsOwed[buyer] = owed + quantity;
        }
    }

    /// @dev Pay a jackpot winner by splitting a portion into MAP tickets.
    function _payJackpotWinnerWithMaps(
        address winner,
        uint256 amount,
        uint16 mapBps
    ) private returns (uint256 ethPaid, uint256 mapSpent) {
        if (winner == address(0) || amount == 0) return (0, 0);

        uint256 cashPortion = amount;
        if (mapBps != 0) {
            uint256 mapPrice = uint256(price) / 4;
            if (mapPrice != 0) {
                uint256 mapBudget = (amount * mapBps) / 10_000;
                if (mapBudget >= mapPrice) {
                    uint256 qty = mapBudget / mapPrice;
                    if (qty > type(uint32).max) qty = type(uint32).max;
                    uint256 mapCost = qty * mapPrice;
                    if (mapCost != 0) {
                        _queueRewardMaps(winner, uint32(qty));
                        nextPrizePool += mapCost;
                        mapSpent = mapCost;
                        cashPortion = amount - mapCost;
                    }
                }
            }
        }

        if (cashPortion != 0) {
            _addClaimableEth(winner, cashPortion);
            ethPaid = cashPortion;
        }
    }

    /// @dev Derives MAP ticket units and total cost from an ETH pool slice.
    ///      Uses the current MAP price (25% of the NFT price) and floors to whole units.
    function _mapUnitsAndCost(
        uint256 ethPool,
        uint16 mapBps
    ) private view returns (uint256 mapUnits, uint256 mapCost) {
        if (ethPool == 0 || mapBps == 0) return (0, 0);
        uint256 mapPrice = uint256(price) / 4;
        if (mapPrice == 0) return (0, 0);

        uint256 mapBudget = (ethPool * mapBps) / 10_000;
        if (mapBudget < mapPrice) return (0, 0);

        mapUnits = mapBudget / mapPrice;
        mapCost = mapUnits * mapPrice;
    }

    /// @dev Returns true if any of the packed traits have tickets at the given level.
    function _hasTraitTickets(uint24 lvl, uint32 packedTraits) private view returns (bool) {
        uint8[4] memory traitIds = _unpackWinningTraits(packedTraits);
        for (uint8 i; i < 4; ) {
            if (traitBurnTicket[lvl][traitIds[i]].length != 0) return true;
            unchecked {
                ++i;
            }
        }
        return false;
    }

    /// @dev Weighted dailyMapJackpot split when a carryover mixes rewardPool + prizePool.
    function _weightedDailyMapBps(uint256 rewardWei, uint256 prizeWei) private pure returns (uint16) {
        uint256 total = rewardWei + prizeWei;
        if (total == 0) return 0;
        uint256 weighted = rewardWei * DAILY_REWARD_JACKPOT_MAP_BPS + prizeWei * DAILY_JACKPOT_MAP_BPS;
        return uint16(weighted / total);
    }

    // =========================================================================
    // Internal Helpers — DailyMapJackpot
    // =========================================================================

    /// @dev Distributes MAP tickets to winners drawn from winning trait ticket pools.
    ///      Caps total winners to maxWinners, splits winners evenly across traits,
    ///      and spreads MAP units evenly across winners.
    function _distributeMapJackpot(
        uint24 lvl,
        uint32 winningTraitsPacked,
        uint256 mapUnits,
        uint256 entropy,
        uint16 maxWinners,
        uint8 saltBase
    ) private {
        if (mapUnits == 0) return;

        uint8[4] memory traitIds = _unpackWinningTraits(winningTraitsPacked);
        uint16[4] memory counts;
        uint8 activeCount;
        uint8 activeMask;

        for (uint8 i; i < 4; ) {
            if (traitBurnTicket[lvl][traitIds[i]].length != 0) {
                activeMask |= uint8(1 << i);
                unchecked {
                    ++activeCount;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (activeCount == 0) return;

        uint256 cap = maxWinners;
        if (mapUnits < cap) {
            cap = mapUnits;
        }

        uint16 baseCount = uint16(cap / activeCount);
        uint16 remainder = uint16(cap - uint256(baseCount) * activeCount);

        for (uint8 i; i < 4; ) {
            if ((activeMask & uint8(1 << i)) != 0) {
                counts[i] = baseCount;
            }
            unchecked {
                ++i;
            }
        }

        if (remainder != 0) {
            uint8 idx = uint8(entropy & 3);
            while (remainder != 0) {
                if ((activeMask & uint8(1 << idx)) != 0) {
                    counts[idx] += 1;
                    unchecked {
                        --remainder;
                    }
                }
                idx = uint8((idx + 1) & 3);
            }
        }

        uint256 total = cap;
        uint256 baseUnits = mapUnits / total;
        uint256 extra = mapUnits % total;
        uint256 offset = entropy % total;

        uint256 globalIndex;
        uint256 entropyState = entropy;

        for (uint8 traitIdx; traitIdx < 4; ) {
            uint16 count = counts[traitIdx];
            if (count != 0) {
                // Cap to MAX_BUCKET_WINNERS to fit in uint8 and bound gas.
                if (count > MAX_BUCKET_WINNERS) count = MAX_BUCKET_WINNERS;

                entropyState = _entropyStep(entropyState ^ (uint256(traitIdx) << 64) ^ mapUnits);
                address[] memory winners = _randTraitTicket(
                    traitBurnTicket[lvl],
                    entropyState,
                    traitIds[traitIdx],
                    uint8(count),
                    uint8(saltBase + traitIdx)
                );
                uint256 len = winners.length;
                for (uint256 i; i < len; ) {
                    address winner = winners[i];
                    uint256 units = baseUnits;
                    if (extra != 0) {
                        uint256 idx = (globalIndex + offset) % total;
                        if (idx < extra) {
                            units += 1;
                        }
                    }
                    if (winner != address(0) && units != 0) {
                        if (units > type(uint32).max) {
                            units = type(uint32).max;
                        }
                        _queueRewardMaps(winner, uint32(units));
                    }
                    unchecked {
                        ++globalIndex;
                        ++i;
                    }
                }
            }
            unchecked {
                ++traitIdx;
            }
        }
    }

    // =========================================================================
    // Internal Helpers — Bucket Sizing
    // =========================================================================

    /// @dev Computes base winner counts for each of the 4 trait buckets.
    ///      Base counts [25, 15, 8, 1] are rotated by entropy for fairness.
    ///
    /// @param entropy Used for rotation offset (bottom 2 bits).
    /// @return counts Winner counts for each bucket [bucket0, bucket1, bucket2, bucket3].
    function _traitBucketCounts(uint256 entropy) private pure returns (uint16[4] memory counts) {
        uint16[4] memory base;
        base[0] = 25;  // Large bucket
        base[1] = 15;  // Mid bucket
        base[2] = 8;   // Small bucket
        base[3] = 1;   // Solo bucket (receives the 60% share via rotation)

        // Rotate bucket assignments based on entropy for fairness across traits.
        uint8 offset = uint8(entropy & 3);
        for (uint8 i; i < 4; ) {
            counts[i] = base[(i + offset) & 3];
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Scales base bucket counts by jackpot size (excluding solo) with a hard cap.
    ///      1x under 10 ETH, linearly to 2x by 50 ETH, linearly to 4x by 200 ETH, then capped.
    function _scaleTraitBucketCounts(
        uint16[4] memory baseCounts,
        uint256 ethPool,
        uint256 entropy
    ) private pure returns (uint16[4] memory counts) {
        counts = baseCounts;

        if (ethPool < JACKPOT_SCALE_MIN_WEI) return counts;

        uint256 scaleBps;
        if (ethPool < JACKPOT_SCALE_FIRST_WEI) {
            uint256 range = JACKPOT_SCALE_FIRST_WEI - JACKPOT_SCALE_MIN_WEI;
            uint256 progress = ethPool - JACKPOT_SCALE_MIN_WEI;
            scaleBps = JACKPOT_SCALE_BASE_BPS
                + (progress * (JACKPOT_SCALE_FIRST_BPS - JACKPOT_SCALE_BASE_BPS)) / range;
        } else if (ethPool < JACKPOT_SCALE_SECOND_WEI) {
            uint256 range = JACKPOT_SCALE_SECOND_WEI - JACKPOT_SCALE_FIRST_WEI;
            uint256 progress = ethPool - JACKPOT_SCALE_FIRST_WEI;
            scaleBps = JACKPOT_SCALE_FIRST_BPS
                + (progress * (JACKPOT_SCALE_MAX_BPS - JACKPOT_SCALE_FIRST_BPS)) / range;
        } else {
            scaleBps = JACKPOT_SCALE_MAX_BPS;
        }

        if (scaleBps != JACKPOT_SCALE_BASE_BPS) {
            for (uint8 i; i < 4; ) {
                uint16 baseCount = counts[i];
                if (baseCount > 1) {
                    uint256 scaled = (uint256(baseCount) * scaleBps) / 10_000;
                    if (scaled < baseCount) scaled = baseCount;
                    if (scaled > type(uint16).max) scaled = type(uint16).max;
                    counts[i] = uint16(scaled);
                }
                unchecked {
                    ++i;
                }
            }
        }

        return _capBucketCounts(counts, JACKPOT_MAX_WINNERS, entropy);
    }

    /// @dev Computes base + scaled bucket counts for a given pool; returns zeroes when pool is empty.
    function _bucketCountsForPool(
        uint256 ethPool,
        uint256 entropy
    ) private pure returns (uint16[4] memory baseCounts, uint16[4] memory bucketCounts) {
        if (ethPool == 0) return (baseCounts, bucketCounts);
        baseCounts = _traitBucketCounts(entropy);
        bucketCounts = _scaleTraitBucketCounts(baseCounts, ethPool, entropy);
    }

    /// @dev Sums the bucket counts.
    function _sumBucketCounts(uint16[4] memory counts) private pure returns (uint256 total) {
        total = uint256(counts[0]) + counts[1] + counts[2] + counts[3];
    }

    /// @dev Caps total winners while keeping the solo bucket fixed at 1 when present.
    function _capBucketCounts(
        uint16[4] memory counts,
        uint16 maxTotal,
        uint256 entropy
    ) private pure returns (uint16[4] memory capped) {
        capped = counts;
        if (maxTotal == 0) {
            capped[0] = 0;
            capped[1] = 0;
            capped[2] = 0;
            capped[3] = 0;
            return capped;
        }

        uint256 total = _sumBucketCounts(counts);
        if (total <= maxTotal) return capped;

        uint256 nonSoloCap = uint256(maxTotal) - 1;
        uint256 nonSoloTotal = total - 1;
        uint256 scaledTotal;

        for (uint8 i; i < 4; ) {
            uint16 bucketCount = counts[i];
            if (bucketCount > 1) {
                uint256 scaled = (uint256(bucketCount) * nonSoloCap) / nonSoloTotal;
                if (scaled == 0) scaled = 1;
                capped[i] = uint16(scaled);
                scaledTotal += scaled;
            }
            unchecked {
                ++i;
            }
        }

        uint256 remainder = nonSoloCap - scaledTotal;
        if (remainder != 0) {
            uint8 offset = uint8((entropy >> 24) & 3);
            for (uint8 i; i < 4 && remainder != 0; ) {
                uint8 idx = uint8((uint256(offset) + i) & 3);
                if (capped[idx] > 1) {
                    capped[idx] += 1;
                    unchecked {
                        --remainder;
                    }
                }
                unchecked {
                    ++i;
                }
            }
        }

        return capped;
    }

    // =========================================================================
    // Internal Helpers — Reward Pool Percentage Calculation
    // =========================================================================

    /// @dev Determines what percentage of the total pool to retain in rewardPool.
    ///      Returns pctTimes2 (percentage * 2) to allow 0.5% granularity without decimals.
    ///
    ///      LEVEL-BASED LOGIC:
    ///      - Level 100 multiples: Roll 3d11 (0-30%) for dramatic variance.
    ///      - Levels 80-98: High retention (75%+) to build finale reserves.
    ///      - Level 99: Hard cap at 98% — nearly all ETH reserved for level 100.
    ///      - Early levels (1-4): Aggressive payouts (low retention).
    ///      - Mid levels (5-79): Gradual increase in retention.
    ///
    /// @param lvl Current game level.
    /// @param rngWord VRF entropy for percentage rolls.
    /// @return pctTimes2 Retention percentage * 2 (e.g., 100 = 50%).
    /// @return level100Roll Raw 3d11 roll for level-100 yield bonus eligibility.
    function _mapRewardPoolPercent(
        uint24 lvl,
        uint256 rngWord
    ) private pure returns (uint256 pctTimes2, uint256 level100Roll) {
        if ((lvl % 100) == 0) {
            level100Roll = _roll3d11(rngWord); // 0-30
            return (level100Roll * 2, level100Roll); // returned as times two
        }
        if ((rngWord % 1_000_000_000) == DEGENERATE_ENTROPY_CHECK_VALUE) {
            return (20, 0); // 10% fallback when trait entropy is degenerate (returned as times two).
        }
        if (lvl >= 80 && lvl <= 98) {
            uint256 base = 75 + (uint256(lvl) - 80) + ((lvl % 10 == 9) ? 5 : 0);
            uint256 pct = base + _rollSum(rngWord, CARRYOVER_3D4_SALT, 4, 3);
            return (_clampPctTimes2(pct), 0);
        }
        if (lvl == 99) {
            return (196, 0); // Hard cap at 98% for the pre-finale level (times two).
        }

        uint256 baseTimes2;
        if (lvl <= 4) {
            uint256 increments = lvl > 0 ? uint256(lvl) - 1 : 0;
            baseTimes2 = (8 + increments * 8) * 2;
        } else if (lvl <= 79) {
            baseTimes2 = 64 + (uint256(lvl) - 4);
        } else {
            baseTimes2 = _legacyRewardPoolTimes2(lvl, rngWord);
        }

        baseTimes2 += _rewardPoolBonus(rngWord) * 2;
        if (baseTimes2 > 196) {
            baseTimes2 = 196;
        }

        uint256 jackpotPctTimes2 = 200 - baseTimes2;
        if (jackpotPctTimes2 < 34 && jackpotPctTimes2 != 60) {
            baseTimes2 = 166;
        }
        return (baseTimes2, 0);
    }

    /// @dev Adjusts reward pool retention based on flip activity trends between levels.
    ///      Encourages participation: if flips doubled, reduce retention (bigger jackpots);
    ///      if flips halved, increase retention (preserve reserves).
    ///
    /// @param baseTimes2 Initial retention percentage * 2.
    /// @return adjusted Modified retention percentage * 2, clamped to [0, 196].
    function _adjustRewardPoolForFlipTotals(uint256 baseTimes2) private view returns (uint256 adjusted) {
        adjusted = baseTimes2;
        uint256 prevTotal = lastPurchaseDayFlipTotalPrev;
        if (prevTotal == 0) return adjusted;
        uint256 currentTotal = lastPurchaseDayFlipTotal;

        // Flips doubled or more → reduce retention by 2% (reward activity).
        if (currentTotal >= prevTotal && currentTotal - prevTotal >= prevTotal) {
            if (adjusted > 3) {
                adjusted -= 4;
            } else {
                adjusted = 0;
            }
        // Flips halved or worse → increase retention by 2% (preserve reserves).
        } else if (currentTotal < prevTotal && prevTotal - currentTotal > currentTotal) {
            adjusted += 4;
        }

        // Hard cap at 98% retention.
        if (adjusted > 196) {
            adjusted = 196;
        }
    }

    // =========================================================================
    // Internal Helpers — Dice Rolls
    // =========================================================================

    /// @dev Rolls 3d11 (three 11-sided dice, 0-10 each) for 0-30 range.
    ///      Used for level-100 reward pool percentage.
    function _roll3d11(uint256 rngWord) private pure returns (uint256 total) {
        total = (rngWord % 11);
        total += ((rngWord >> 16) % 11);
        total += ((rngWord >> 32) % 11);
    }

    /// @dev Computes a random bonus for reward pool retention (2d4 + 1d14 + 3 = 6-24 range).
    ///      Adds variance to prevent predictable jackpot sizing.
    function _rewardPoolBonus(uint256 rngWord) private pure returns (uint256) {
        uint256 seed = uint256(keccak256(abi.encodePacked(rngWord, CARRYOVER_BONUS_TAG)));
        uint256 d4a = (seed & 0xF) % 4;        // 0-3
        uint256 d4b = ((seed >> 8) & 0xF) % 4; // 0-3
        uint256 d14 = ((seed >> 16) & 0xFF) % 14; // 0-13
        return d4a + d4b + d14 + 3;            // 3-23
    }

    /// @dev Legacy fallback for reward pool calculation on levels outside the main formula.
    ///      Provides backward-compatible behavior for edge cases.
    function _legacyRewardPoolTimes2(uint24 lvl, uint256 rngWord) private pure returns (uint256) {
        uint256 base;
        uint256 lvlMod100 = lvl % 100;
        if (lvl < 10) base = uint256(lvl) * 5;
        else if (lvl < 20) base = 55 + (rngWord % 16);
        else if (lvl < 40) base = 55 + (rngWord % 21);
        else if (lvl < 60) base = 60 + (rngWord % 21);
        else if (lvl < 80) base = 60 + (rngWord % 26);
        else if (lvlMod100 == 99) base = 93;
        else base = 65 + (rngWord % 26);

        if ((lvl % 10) == 9) base += 5;  // Boost on "9" levels
        base += lvl / 100;               // Slight increase per 100-level era
        return base * 2;
    }

    /// @dev Clamps a percentage to max 98% and returns it doubled.
    function _clampPctTimes2(uint256 pct) private pure returns (uint256) {
        if (pct > 98) {
            pct = 98;
        }
        return pct * 2;
    }

    /// @dev Generic dice roll: sum of `dice` rolls of `sides`-sided dice (1 to sides each).
    /// @param rngWord Base entropy.
    /// @param salt Domain separator for this roll type.
    /// @param sides Number of sides per die (e.g., 4 for d4).
    /// @param dice Number of dice to roll.
    /// @return Sum of all dice (range: dice to dice*sides).
    function _rollSum(uint256 rngWord, bytes32 salt, uint8 sides, uint8 dice) private pure returns (uint256) {
        uint256 seed = uint256(keccak256(abi.encodePacked(rngWord, salt)));
        uint256 result;
        unchecked {
            for (uint8 i; i < dice; ++i) {
                result += (seed % sides) + 1;
                seed >>= 16;
            }
        }
        return result;
    }

    /// @dev Determines what percentage of the jackpot base goes to the level jackpot.
    ///      Fixed at 40% for "big" levels (16, 36, 56, 76, 96); otherwise 20-40% random.
    function _levelJackpotPercent(uint24 lvl, uint256 rngWord) private pure returns (uint256) {
        if (lvl % 20 == 16) return 40; // Big level jackpot levels get fixed 40%
        return 20 + (rngWord % 21);    // Otherwise 20-40% random
    }

    /// @dev Returns the basis points for the nth daily jackpot (0-9).
    ///      Escalates from 610 bps to 1225 bps (~2× growth).
    function _dailyJackpotBps(uint8 idx) private pure returns (uint16) {
        if (idx == 0) return DAILY_JACKPOT_BPS_0;
        if (idx == 1) return DAILY_JACKPOT_BPS_1;
        if (idx == 2) return DAILY_JACKPOT_BPS_2;
        if (idx == 3) return DAILY_JACKPOT_BPS_3;
        if (idx == 4) return DAILY_JACKPOT_BPS_4;
        if (idx == 5) return DAILY_JACKPOT_BPS_5;
        if (idx == 6) return DAILY_JACKPOT_BPS_6;
        if (idx == 7) return DAILY_JACKPOT_BPS_7;
        if (idx == 8) return DAILY_JACKPOT_BPS_8;
        return DAILY_JACKPOT_BPS_9;
    }

    // =========================================================================
    // Internal Helpers — Jackpot Execution
    // =========================================================================

    /// @dev Core jackpot execution: distributes ETH and/or COIN to winners, then debits pools.
    ///      This is the unified entry point for daily, early-burn, and extermination jackpots.
    ///
    /// @param jp Packed jackpot parameters.
    /// @param fromPrizePool If true, debit paidEth from currentPrizePool.
    /// @param fromRewardPool If true, debit paidEth from rewardPool.
    /// @param bondBps Bond purchase percentage for this jackpot type.
    /// @param mapBps Basis points of ETH payout to convert into MAP tickets.
    /// @return paidEth Total ETH paid out (for pool accounting).
    function _executeJackpot(
        JackpotParams memory jp,
        bool fromPrizePool,
        bool fromRewardPool,
        uint16 bondBps,
        uint16 mapBps
    ) private returns (uint256 paidEth) {
        uint8[4] memory traitIds = _unpackWinningTraits(jp.winningTraitsPacked);
        uint16[4] memory shareBps = _shareBpsByBucket(jp.traitShareBpsPacked, uint8(jp.entropy & 3));

        if (jp.ethPool != 0) {
            paidEth = _runJackpotEthFlow(jp, traitIds, shareBps, bondBps, mapBps);
        }

        if (jp.coinPool != 0) {
            _runJackpotCoinFlow(jp, traitIds, shareBps);
        }

        // Debit the appropriate pool(s) based on caller specification.
        if (fromPrizePool) {
            currentPrizePool -= paidEth;
        }
        if (fromRewardPool) {
            rewardPool -= paidEth;
        }
    }

    /// @dev Simple ETH flow for daily/extermination jackpots without special bond logic.
    function _runJackpotEthFlow(
        JackpotParams memory jp,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16 bondBps,
        uint16 mapBps
    ) private returns (uint256 totalPaidEth) {
        uint16[4] memory baseBucketCounts = _traitBucketCounts(jp.entropy);
        uint16[4] memory bucketCounts = _scaleTraitBucketCounts(baseBucketCounts, jp.ethPool, jp.entropy);
        address bondsAddr = bonds;
        return
            _distributeJackpotEth(
                jp.lvl,
                jp.ethPool,
                jp.entropy,
                traitIds,
                shareBps,
                bucketCounts,
                jp.coinContract,
                bondsAddr,
                bondBps,
                mapBps
            );
    }

    /// @dev Main ETH flow for MAP/daily jackpots with solo and large-bucket bond integration.
    ///      Solo winners (bucket size 1) get a percentage converted to bonds.
    ///      Large buckets get a subset of winners receiving bonds instead of ETH.
    function _runMainJackpotEthFlow(
        JackpotParams memory jp,
        uint16[4] memory baseBucketCounts,
        uint16[4] memory bucketCounts,
        uint16 soloBondBps,
        uint16 largeBucketSize,
        uint16 largeBucketBondWinners,
        uint16 mapBps
    ) private returns (uint256 totalPaidEth) {
        uint8[4] memory traitIds = _unpackWinningTraits(jp.winningTraitsPacked);
        uint16[4] memory shareBps = _shareBpsByBucket(jp.traitShareBpsPacked, uint8(jp.entropy & 3));
        uint16 largeBucketCount;
        if (largeBucketSize != 0) {
            largeBucketCount = largeBucketSize;
        }
        address bondsAddr = bonds;
        uint256 unit = uint256(price) / 4;
        uint8 remainderIdx = _soloBucketIndex(jp.entropy);
        bool bondPurchasesOpen;
        if (bondsAddr != address(0) && (soloBondBps != 0 || (largeBucketSize != 0 && largeBucketBondWinners != 0))) {
            bondPurchasesOpen = IDegenerusBondsJackpot(bondsAddr).purchasesEnabled();
        }
        uint256[4] memory shares = _bucketShares(jp.ethPool, shareBps, bucketCounts, remainderIdx, unit);

        JackpotEthCtx memory ctx;
        ctx.entropyState = jp.entropy;

        for (uint8 traitIdx; traitIdx < 4; ) {
            uint16 bucketCount = bucketCounts[traitIdx];
            uint256 share = shares[traitIdx];

            uint16 bucketBondBps;
            uint16 bondWinnerCount;

            if (bucketCount == 1) {
                bucketBondBps = soloBondBps;
            } else if (baseBucketCounts[traitIdx] == largeBucketCount && largeBucketSize != 0 && largeBucketBondWinners != 0) {
                bondWinnerCount = (bucketCount * largeBucketBondWinners) / largeBucketSize;
            }

            (uint256 newEntropyState, uint256 ethDelta, uint256 bondSpent, uint256 bucketLiability, uint256 mapSpent) =
                _resolveTraitWinners(
                    jp.coinContract,
                    false,
                    jp.lvl,
                    traitIds[traitIdx],
                    traitIdx,
                    share,
                    ctx.entropyState,
                    bucketCount,
                    bondsAddr,
                    bucketBondBps,
                    bondWinnerCount,
                    mapBps,
                    bondPurchasesOpen
                );
            ctx.entropyState = newEntropyState;
            ctx.totalPaidEth += ethDelta + bondSpent + mapSpent;
            ctx.liabilityDelta += bucketLiability;
            unchecked {
                ++traitIdx;
            }
        }

        if (ctx.liabilityDelta != 0) {
            unchecked {
                claimablePool += ctx.liabilityDelta;
            }
        }

        return ctx.totalPaidEth;
    }

    function _runJackpotCoinFlow(JackpotParams memory jp, uint8[4] memory traitIds, uint16[4] memory shareBps) private {
        // Do not scale coin jackpots by level; scale by size using coin->ETH equivalent.
        uint16[4] memory baseBucketCounts = _traitBucketCounts(jp.entropy);
        uint256 coinPoolEth;
        uint256 priceWei = price;
        if (jp.coinPool != 0 && priceWei != 0) {
            coinPoolEth = (jp.coinPool * priceWei) / PRICE_COIN_UNIT;
        }
        uint16[4] memory bucketCounts = _scaleTraitBucketCounts(baseBucketCounts, coinPoolEth, jp.entropy);
        uint8 remainderIdx = _soloBucketIndex(jp.entropy);
        _distributeJackpotCoin(
            jp.lvl,
            jp.coinPool,
            jp.entropy ^ uint256(COIN_JACKPOT_TAG),
            traitIds,
            shareBps,
            bucketCounts,
            remainderIdx,
            jp.coinContract
        );
    }

    function _distributeJackpotEth(
        uint24 lvl,
        uint256 ethPool,
        uint256 entropy,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16[4] memory bucketCounts,
        IDegenerusCoinModule coinContract,
        address bondsAddr,
        uint16 bondBps,
        uint16 mapBps
    ) private returns (uint256 totalPaidEth) {
        // Each trait bucket gets a slice; the solo bucket absorbs remainder to avoid dust. totalPaidEth counts ETH plus bond spend.
        JackpotEthCtx memory ctx;
        ctx.entropyState = entropy;
        bool bondPurchasesOpen;
        if (bondBps != 0 && bondsAddr != address(0)) {
            bondPurchasesOpen = IDegenerusBondsJackpot(bondsAddr).purchasesEnabled();
        }
        uint256 unit = uint256(price) / 4;
        uint8 remainderIdx = _soloBucketIndex(entropy);
        uint256[4] memory shares = _bucketShares(ethPool, shareBps, bucketCounts, remainderIdx, unit);

        for (uint8 traitIdx; traitIdx < 4; ) {
            uint16 bucketCount = bucketCounts[traitIdx];
            uint256 share = shares[traitIdx];
            uint16 bucketBondBps = bondBps;
            {
            (uint256 newEntropyState, uint256 ethDelta, uint256 bondSpent, uint256 bucketLiability, uint256 mapSpent) =
                _resolveTraitWinners(
                    coinContract,
                    false,
                    lvl,
                    traitIds[traitIdx],
                    traitIdx,
                    share,
                    ctx.entropyState,
                    bucketCount,
                    bondsAddr,
                    bucketBondBps,
                    0,
                    mapBps,
                    bondPurchasesOpen
                );
            ctx.entropyState = newEntropyState;
            ctx.totalPaidEth += ethDelta + bondSpent + mapSpent;
            ctx.liabilityDelta += bucketLiability;
            }
            unchecked {
                ++traitIdx;
            }
        }

        if (ctx.liabilityDelta != 0) {
            unchecked {
                claimablePool += ctx.liabilityDelta;
            }
        }

        return ctx.totalPaidEth;
    }

    function _distributeJackpotCoin(
        uint24 lvl,
        uint256 coinPool,
        uint256 entropy,
        uint8[4] memory traitIds,
        uint16[4] memory shareBps,
        uint16[4] memory bucketCounts,
        uint8 remainderIdx,
        IDegenerusCoinModule coinContract
    ) private {
        uint256 unit = PRICE_COIN_UNIT / 4;
        uint256[4] memory shares = _bucketShares(coinPool, shareBps, bucketCounts, remainderIdx, unit);
        for (uint8 traitIdx; traitIdx < 4; ) {
            uint16 bucketCount = bucketCounts[traitIdx];
            uint256 share = shares[traitIdx];
            uint8 traitId = traitIds[traitIdx];
            (entropy, , , , ) = _resolveTraitWinners(
                coinContract,
                true,
                lvl,
                traitId,
                traitIdx,
                share,
                entropy,
                bucketCount,
                address(0),
                0,
                0,
                0,
                false
            );
            unchecked {
                ++traitIdx;
            }
        }
    }

    function _rotatedShareBps(uint64 packed, uint8 offset, uint8 traitIdx) private pure returns (uint16) {
        uint8 baseIndex = uint8((uint256(traitIdx) + uint256(offset) + 1) & 3);
        return uint16(packed >> (baseIndex * 16));
    }

    function _soloBucketIndex(uint256 entropy) private pure returns (uint8) {
        return uint8((uint256(3) - (entropy & 3)) & 3);
    }

    function _bucketShares(
        uint256 pool,
        uint16[4] memory shareBps,
        uint16[4] memory bucketCounts,
        uint8 remainderIdx,
        uint256 unit
    ) private pure returns (uint256[4] memory shares) {
        // Round non-solo buckets to unit * winnerCount; remainder goes to the solo bucket.
        uint256 distributed;
        for (uint8 i; i < 4; ) {
            if (i != remainderIdx) {
                uint16 count = bucketCounts[i];
                uint256 share = (pool * shareBps[i]) / 10_000;
                if (count != 0) {
                    if (unit != 0) {
                        uint256 unitBucket = unit * count;
                        share = (share / unitBucket) * unitBucket;
                    }
                    shares[i] = share;
                }
                distributed += share;
            }
            unchecked {
                ++i;
            }
        }
        shares[remainderIdx] = pool - distributed;
    }

    // =========================================================================
    // Internal Helpers — Winner Resolution
    // =========================================================================

    /// @dev Resolves winners for a single trait bucket and distributes ETH or COIN.
    ///
    ///      FLOW:
    ///      1. Early exit if no share or no winners.
    ///      2. Select random ticket holders from the trait's burn ticket pool.
    ///      3. For ETH payouts: route bond prizes via purchases when open, otherwise mint/burn DGNRS 1:1.
    ///      4. Solo winners may get a bond/ETH split; large buckets may have subset bond winners.
    ///      5. Credit remaining ETH to claimableWinnings.
    ///
    /// @param coinContract Coin module for COIN credits.
    /// @param payCoin If true, pay COIN; if false, pay ETH.
    /// @param lvl Current level for ticket pool lookup.
    /// @param traitId Which trait's ticket pool to draw from.
    /// @param traitIdx Bucket index (0-3) for entropy derivation.
    /// @param traitShare Total ETH/COIN allocated to this bucket.
    /// @param entropy Current entropy state.
    /// @param winnerCount Number of winners to select.
    /// @param bondsAddr Bonds contract address.
    /// @param bondBps Bond percentage for solo winners.
    /// @param bondWinnerCount Number of winners to receive bonds (large bucket mode).
    /// @param mapBps Basis points of ETH payout to convert into MAP tickets.
    /// @param bondPurchasesOpen True if bond purchases are open; otherwise prizes mint DGNRS 1:1.
    /// @return entropyState Updated entropy after selection.
    /// @return ethDelta ETH credited to claimable balances.
    /// @return bondSpent ETH spent on bond purchases.
    /// @return liabilityDelta Total claimable liability added.
    /// @return mapSpent ETH converted to MAP tickets (added to nextPrizePool).
    function _resolveTraitWinners(
        IDegenerusCoinModule coinContract,
        bool payCoin,
        uint24 lvl,
        uint8 traitId,
        uint8 traitIdx,
        uint256 traitShare,
        uint256 entropy,
        uint16 winnerCount,
        address bondsAddr,
        uint16 bondBps,
        uint16 bondWinnerCount,
        uint16 mapBps,
        bool bondPurchasesOpen
    )
        private
        returns (
            uint256 entropyState,
            uint256 ethDelta,
            uint256 bondSpent,
            uint256 liabilityDelta,
            uint256 mapSpent
        )
    {
        entropyState = entropy;

        // Early exits for edge cases.
        if (traitShare == 0) return (entropyState, 0, 0, 0, 0);

        uint16 totalCount = winnerCount;
        if (totalCount == 0) return (entropyState, 0, 0, 0, 0);

        // Cap to MAX_BUCKET_WINNERS to fit in uint8 and bound gas.
        if (totalCount > MAX_BUCKET_WINNERS) totalCount = MAX_BUCKET_WINNERS;

        // Derive sub-entropy and select winners from the trait's ticket pool.
        entropyState = _entropyStep(entropyState ^ (uint256(traitIdx) << 64) ^ traitShare);
        address[] memory winners = _randTraitTicket(
            traitBurnTicket[lvl],
            entropyState,
            traitId,
            uint8(totalCount),
            uint8(200 + traitIdx)  // Salt to differentiate trait buckets
        );
        if (winners.length == 0) return (entropyState, 0, 0, 0, 0);

        uint256 perWinner = traitShare / totalCount;
        if (perWinner == 0) return (entropyState, 0, bondSpent, liabilityDelta, 0);

        bool bondsConfigured = bondsAddr != address(0);
        if (!payCoin && bondBps != 0 && bondsConfigured && totalCount == 1) {
            address winner = winners[0];
            if (winner == address(0)) return (entropyState, 0, 0, 0, 0);
            uint256 bondBudget = (perWinner * bondBps) / 10_000;
            uint256 cashPortion = perWinner;
            if (bondBudget != 0) {
                _awardBondPrize(bondsAddr, winner, bondBudget, lvl, bondPurchasesOpen);
                cashPortion = perWinner - bondBudget;
                bondSpent = bondBudget;
            }
            (uint256 soloEthPaid, uint256 soloMapSpent) = _payJackpotWinnerWithMaps(winner, cashPortion, mapBps);
            ethDelta = soloEthPaid;
            liabilityDelta = soloEthPaid;
            mapSpent = soloMapSpent;
            return (entropyState, ethDelta, bondSpent, liabilityDelta, mapSpent);
        }

        if (!payCoin && bondWinnerCount != 0 && bondsConfigured) {
            uint256 burnLiability;
            (bondSpent, burnLiability) = _jackpotBondSpendCount(
                bondsAddr,
                winners,
                perWinner,
                entropyState,
                bondWinnerCount,
                lvl,
                bondPurchasesOpen
            );
            liabilityDelta += burnLiability;
        } else if (!payCoin && bondBps != 0 && bondsConfigured) {
            uint256 burnLiability;
            (bondSpent, burnLiability) = _jackpotBondSpend(
                bondsAddr,
                winners,
                perWinner,
                traitShare,
                entropyState,
                bondBps,
                lvl,
                bondPurchasesOpen
            );
            liabilityDelta += burnLiability;
        }

        uint256 len = winners.length;
        if (payCoin) {
            for (uint256 i; i < len; ) {
                _creditJackpot(coinContract, true, winners[i], perWinner);

                unchecked {
                    ++i;
                }
            }
            return (entropyState, 0, bondSpent, liabilityDelta, 0);
        }

        uint256 totalPayout;
        uint256 totalMapSpent;
        for (uint256 i; i < len; ) {
            address w = winners[i];
            if (w != address(0)) {
                (uint256 ethPaid, uint256 mapPaid) = _payJackpotWinnerWithMaps(w, perWinner, mapBps);
                totalPayout += ethPaid;
                totalMapSpent += mapPaid;
            }
            unchecked {
                ++i;
            }
        }
        if (totalPayout == 0 && totalMapSpent == 0) return (entropyState, 0, bondSpent, liabilityDelta, 0);

        liabilityDelta += totalPayout;
        ethDelta = totalPayout;
        mapSpent = totalMapSpent;

        return (entropyState, ethDelta, bondSpent, liabilityDelta, mapSpent);
    }

    // =========================================================================
    // Internal Helpers — Bond Integration
    // =========================================================================

    /// @dev Calculates how many winners should receive bonds based on bondBps skim.
    ///      Delegates to _jackpotBondSpendCount for actual distribution.
    function _jackpotBondSpend(
        address bondsAddr,
        address[] memory winners,
        uint256 perWinner,
        uint256 traitShare,
        uint256 entropyState,
        uint16 bondBps,
        uint24 lvl,
        bool bondPurchasesOpen
    ) private returns (uint256 bondSpent, uint256 liabilityDelta) {
        uint256 winnersLen = winners.length;

        // Calculate bond budget and determine how many full winner payouts it covers.
        uint256 bondBudget = (traitShare * bondBps) / 10_000;
        if (bondBudget < perWinner) return (0, 0);

        uint256 targetBondWinners = bondBudget / perWinner;
        if (targetBondWinners > winnersLen) {
            targetBondWinners = winnersLen;
        }

        return _jackpotBondSpendCount(
            bondsAddr,
            winners,
            perWinner,
            entropyState,
            uint16(targetBondWinners),
            lvl,
            bondPurchasesOpen
        );
    }

    /// @dev Awards bond prizes for a subset of winners, nullifying them in the array
    ///      so they don't also receive ETH payouts in the main distribution loop.
    ///
    /// @param bondsAddr Bonds contract address.
    /// @param winners Mutable array of winner addresses (nullified after bond prize).
    /// @param perWinner ETH amount per bond prize.
    /// @param entropyState Used for random offset into winners array.
    /// @param targetBondWinners Number of winners to convert to bonds.
    /// @return bondSpent Total ETH spent on bonds.
    /// @return liabilityDelta Always 0 (bonds don't create claimable liability).
    function _jackpotBondSpendCount(
        address bondsAddr,
        address[] memory winners,
        uint256 perWinner,
        uint256 entropyState,
        uint16 targetBondWinners,
        uint24 lvl,
        bool bondPurchasesOpen
    ) private returns (uint256 bondSpent, uint256 liabilityDelta) {
        uint256 winnersLen = winners.length;
        if (targetBondWinners == 0 || winnersLen == 0) return (0, 0);
        if (targetBondWinners > winnersLen) {
            targetBondWinners = uint16(winnersLen);
        }

        // Start at a random offset for fairness.
        uint16 offset = uint16(entropyState % winnersLen);

        for (uint256 i; i < targetBondWinners; ) {
            address recipient = winners[(uint256(offset) + i) % winnersLen];
            if (recipient == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Award bond prize and null out the winner so they don't also get ETH.
            _awardBondPrize(bondsAddr, recipient, perWinner, lvl, bondPurchasesOpen);
            winners[(uint256(offset) + i) % winnersLen] = address(0);
            bondSpent += perWinner;

            unchecked {
                ++i;
            }
        }

        return (bondSpent, liabilityDelta);
    }

    // =========================================================================
    // Internal Helpers — Entropy
    // =========================================================================

    /// @dev XOR-shift PRNG step for deterministic entropy derivation.
    ///      Creates new pseudo-random state from the current state without
    ///      requiring additional VRF calls. Not cryptographically secure on
    ///      its own, but adequate when seeded with VRF output.
    function _entropyStep(uint256 state) private pure returns (uint256) {
        unchecked {
            state ^= state << 7;
            state ^= state >> 9;
            state ^= state << 8;
        }
        return state;
    }

    /// @dev Award bond prizes for jackpot winners.
    ///      When bond purchases are open, this records a bond purchase.
    ///      When closed, mint/burn DGNRS 1:1 and fully fund the bond pool.
    ///
    /// @param bondsAddr Bonds contract address.
    /// @param beneficiary Winner receiving the bond prize.
    /// @param amount ETH amount to convert into bonds.
    /// @param lvl Current game level (used for auto-burn routing).
    /// @param bondPurchasesOpen True if bond purchases are open.
    function _awardBondPrize(
        address bondsAddr,
        address beneficiary,
        uint256 amount,
        uint24 lvl,
        bool bondPurchasesOpen
    ) private {
        if (amount == 0 || beneficiary == address(0)) return;
        if (bondPurchasesOpen) {
            IDegenerusBondsJackpot(bondsAddr).depositFromGame(beneficiary, amount);
            uint256 bondShare = amount / 2;
            if (bondShare != 0) {
                bondPool += bondShare;
            }
            return;
        }

        IDegenerusBondsJackpot(bondsAddr).mintJackpotDgnrs(beneficiary, amount, lvl);
        bondPool += amount;
    }

    // =========================================================================
    // Internal Helpers — Quest & Credit
    // =========================================================================

    /// @dev Triggers the daily quest roll after a jackpot. Level jackpots force ETH+Degenerus quests.
    function _rollQuestForJackpot(
        IDegenerusCoinModule coinContract,
        uint256 entropySource,
        bool forceMintEthAndDegenerus,
        uint48 questDay
    ) private {
        if (forceMintEthAndDegenerus) {
            coinContract.rollDailyQuestWithOverrides(questDay, entropySource, true, true);
        } else {
            coinContract.rollDailyQuest(questDay, entropySource);
        }
    }

    /// @dev Credits a jackpot winner with COIN or ETH. Returns false if beneficiary is invalid.
    function _creditJackpot(
        IDegenerusCoinModule coinContract,
        bool payInCoin,
        address beneficiary,
        uint256 amount
    ) private returns (bool) {
        if (beneficiary == address(0) || amount == 0) return false;
        if (payInCoin) {
            coinContract.creditFlip(beneficiary, amount);
        } else {
            // Liability is tracked by the caller to avoid per-winner SSTORE cost.
            _addClaimableEth(beneficiary, amount);
        }
        return true;
    }

    // =========================================================================
    // Internal Helpers — Trait Packing/Unpacking
    // =========================================================================

    /// @dev Packs 4 trait IDs (0-255 each) into a single uint32.
    function _packWinningTraits(uint8[4] memory traits) private pure returns (uint32 packed) {
        packed = uint32(traits[0]) | (uint32(traits[1]) << 8) | (uint32(traits[2]) << 16) | (uint32(traits[3]) << 24);
    }

    /// @dev Unpacks a uint32 into 4 trait IDs.
    function _unpackWinningTraits(uint32 packed) private pure returns (uint8[4] memory traits) {
        traits[0] = uint8(packed);
        traits[1] = uint8(packed >> 8);
        traits[2] = uint8(packed >> 16);
        traits[3] = uint8(packed >> 24);
    }

    /// @dev Unpacks share BPS from packed uint64 with rotation offset for fairness.
    function _shareBpsByBucket(uint64 packed, uint8 offset) private pure returns (uint16[4] memory shares) {
        unchecked {
            for (uint8 i; i < 4; ++i) {
                shares[i] = _rotatedShareBps(packed, offset, i);
            }
        }
    }

    // =========================================================================
    // Internal Helpers — Trait Selection
    // =========================================================================

    /// @dev Derives 4 random trait IDs from entropy. Each quadrant uses 6 bits (0-63 range).
    ///      Quadrant offsets: 0, 64, 128, 192.
    function _getRandomTraits(uint256 rw) private pure returns (uint8[4] memory w) {
        w[0] = uint8(rw & 0x3F);                    // Quadrant 0: 0-63
        w[1] = 64 + uint8((rw >> 6) & 0x3F);        // Quadrant 1: 64-127
        w[2] = 128 + uint8((rw >> 12) & 0x3F);      // Quadrant 2: 128-191
        w[3] = 192 + uint8((rw >> 18) & 0x3F);      // Quadrant 3: 192-255
    }

    /// @dev Derives winning traits based on daily burn activity counters.
    ///      Favors the most-burned traits to reward active participation.
    ///
    ///      SELECTION LOGIC:
    ///      - Trait 0: Most-burned symbol (0-7) combined with random color.
    ///      - Trait 1: Most-burned color (0-7) combined with random symbol.
    ///      - Trait 2: Most-burned overall trait (0-63).
    ///      - Trait 3: Fully random from quadrant 3.
    function _getWinningTraits(
        uint256 randomWord,
        uint32[80] storage counters
    ) private view returns (uint8[4] memory w) {
        uint8 sym = _maxIdxInRange(counters, 0, 8);   // Most-burned symbol

        uint8 col0 = uint8(randomWord & 7);           // Random color
        w[0] = (col0 << 3) | sym;

        uint8 maxColor = _maxIdxInRange(counters, 8, 8);  // Most-burned color
        uint8 randSym = uint8((randomWord >> 3) & 7);     // Random symbol
        w[1] = 64 + ((maxColor << 3) | randSym);

        uint8 maxTrait = _maxIdxInRange(counters, 16, 64); // Most-burned overall
        w[2] = 128 + maxTrait;

        w[3] = 192 + uint8((randomWord >> 6) & 63);        // Fully random
    }

    /// @dev Finds the index with maximum value in a slice of the counters array.
    /// @param counters Daily burn count array (80 elements).
    /// @param base Starting index in the array.
    /// @param len Number of elements to scan.
    /// @return Relative index (0 to len-1) of the maximum value.
    function _maxIdxInRange(uint32[80] storage counters, uint8 base, uint8 len) private view returns (uint8) {
        if (len == 0 || base >= 80) return 0;

        uint256 end = uint256(base) + uint256(len);
        if (end > 80) end = 80;

        uint8 maxRel = 0;
        uint32 maxVal = counters[base];

        for (uint256 i = uint256(base) + 1; i < end; ) {
            uint32 v = counters[i];
            if (v > maxVal) {
                maxVal = v;
                maxRel = uint8(i) - base;
            }
            unchecked {
                ++i;
            }
        }
        return maxRel;
    }

    // =========================================================================
    // Internal Helpers — Scaling
    // =========================================================================

    /// @dev Computes a scaling factor for reward pool-funded jackpots based on level position.
    ///      Scales from 100% at band start down to 50% at band end, resetting each 100 levels.
    ///      This prevents early levels from draining too much of the reward pool.
    function _rewardJackpotScaleBps(uint24 lvl) private pure returns (uint16) {
        uint256 cycle = (lvl == 0) ? 0 : ((uint256(lvl) - 1) % 100); // 0..99
        uint256 discount = (cycle * 5000) / 99; // up to 50% at cycle==99
        uint256 scale = 10_000 - discount;
        return uint16(scale);
    }

    // =========================================================================
    // External Entry Point — Map Batch Processing
    // =========================================================================

    /// @notice Processes a batch of pending map mints with gas-bounded iteration.
    /// @dev Called iteratively until all pending mints are processed. Uses a writes budget
    ///      to stay within block gas limits. The first batch in a new airdrop round is
    ///      scaled down by 35% to account for cold storage access costs.
    ///
    ///      GAS BUDGETING:
    ///      - Each mint requires ~2 SSTOREs (trait ticket + count update).
    ///      - Budget defaults to WRITES_BUDGET_SAFE (780) if not specified.
    ///      - Minimum budget is WRITES_BUDGET_MIN (8) to ensure progress.
    ///
    /// @param writesBudget Maximum SSTORE writes allowed this call (0 = use default).
    /// @return finished True if all pending map mints have been fully processed.
    function processMapBatch(uint32 writesBudget) external returns (bool finished) {
        uint256 idx = airdropIndex;
        uint256 total = pendingMapMints.length;
        if (idx >= total) return true;
        uint32 processed = airdropMapsProcessedCount;

        if (writesBudget == 0) {
            writesBudget = WRITES_BUDGET_SAFE;
        } else if (writesBudget < WRITES_BUDGET_MIN) {
            writesBudget = WRITES_BUDGET_MIN;
        }
        uint24 lvl = level;
        if (gameState == 3) {
            unchecked {
                ++lvl;
            }
        }

        bool firstAirdropBatch = (idx == 0 && processed == 0);
        if (firstAirdropBatch) {
            writesBudget -= (writesBudget * 35) / 100; // 65% scaling
        }

        uint32 used = 0;
        uint256 entropy = rngWordCurrent;

        while (idx < total && used < writesBudget) {
            address player = pendingMapMints[idx];
            uint32 owed = playerMapMintsOwed[player];
            if (owed == 0) {
                unchecked {
                    ++idx;
                }
                processed = 0;
                continue;
            }

            uint32 room = writesBudget - used;

            uint32 baseOv = 2;
            if (processed == 0 && owed <= 2) {
                baseOv += 2;
            }
            if (room <= baseOv) break;
            room -= baseOv;

            uint32 maxT = (room <= 256) ? (room / 2) : (room - 256);
            uint32 take = owed > maxT ? maxT : owed;
            if (take == 0) break;

            uint256 baseKey = (uint256(lvl) << 224) | (idx << 192) | (uint256(uint160(player)) << 32);
            _raritySymbolBatch(player, baseKey, processed, take, entropy);

            uint32 writesThis = (take <= 256) ? (take * 2) : (take + 256);
            writesThis += baseOv;
            if (take == owed) {
                writesThis += 1;
            }

            uint32 remainingOwed;
            unchecked {
                remainingOwed = owed - take;
                playerMapMintsOwed[player] = remainingOwed;
                processed += take;
                used += writesThis;
            }
            if (remainingOwed == 0) {
                unchecked {
                    ++idx;
                }
                processed = 0;
            }
        }
        airdropIndex = uint32(idx);
        airdropMapsProcessedCount = processed;
        return idx >= total;
    }

    // =========================================================================
    // Internal Helpers — Batch Trait Generation
    // =========================================================================

    /// @dev Generates trait tickets in batch for a player's map mints using LCG-based PRNG.
    ///      Uses inline assembly for gas-efficient bulk storage writes.
    ///
    ///      ALGORITHM:
    ///      1. Generate traits in groups of 16 using LCG stepping.
    ///      2. Track unique traits touched and their occurrence counts in memory.
    ///      3. Batch-write all occurrences to storage in a single pass per trait.
    ///
    /// @param player Address receiving the trait tickets.
    /// @param baseKey Encoded key containing level, index, and player address.
    /// @param startIndex Starting position within this player's owed mints.
    /// @param count Number of mints to process this batch.
    /// @param entropyWord VRF entropy for trait generation.
    function _raritySymbolBatch(
        address player,
        uint256 baseKey,
        uint32 startIndex,
        uint32 count,
        uint256 entropyWord
    ) private {
        // Memory arrays to track which traits were generated and how many times.
        uint32[256] memory counts;
        uint8[256] memory touchedTraits;
        uint16 touchedLen;

        uint32 endIndex;
        unchecked {
            endIndex = startIndex + count;
        }
        uint32 i = startIndex;

        // Generate traits in groups of 16, using LCG for deterministic randomness.
        while (i < endIndex) {
            uint32 groupIdx = i >> 4; // Group index (per 16 symbols)

            uint256 seed;
            unchecked {
                seed = (baseKey + groupIdx) ^ entropyWord;
            }
            uint64 s = uint64(seed) | 1;  // Ensure odd for full LCG period
            uint8 offset = uint8(i & 15);
            unchecked {
                s = s * (MAP_LCG_MULT + uint64(offset)) + uint64(offset);
            }

            for (uint8 j = offset; j < 16 && i < endIndex; ) {
                unchecked {
                    s = s * MAP_LCG_MULT + 1;  // LCG step

                    // Generate trait using weighted distribution, add quadrant offset.
                    uint8 traitId = DegenerusTraitUtils.traitFromWord(s) + (uint8(i & 3) << 6);

                    // Track first occurrence of each trait for batch writing.
                    if (counts[traitId]++ == 0) {
                        touchedTraits[touchedLen++] = traitId;
                    }
                    ++i;
                    ++j;
                }
            }
        }

        // Extract level from baseKey for storage slot calculation.
        uint24 lvl = uint24(baseKey >> 224);

        // Calculate the storage slot for this level's trait arrays.
        uint256 levelSlot;
        assembly ("memory-safe") {
            mstore(0x00, lvl)
            mstore(0x20, traitBurnTicket.slot)
            levelSlot := keccak256(0x00, 0x40)
        }

        // Batch-write trait tickets to storage using assembly for gas efficiency.
        for (uint16 u; u < touchedLen; ) {
            uint8 traitId = touchedTraits[u];
            uint32 occurrences = counts[traitId];

            assembly ("memory-safe") {
                // Get array length slot and current length.
                let elem := add(levelSlot, traitId)
                let len := sload(elem)
                let newLen := add(len, occurrences)
                sstore(elem, newLen)

                // Calculate data slot and write player address `occurrences` times.
                mstore(0x00, elem)
                let data := keccak256(0x00, 0x20)
                let dst := add(data, len)
                for {
                    let k := 0
                } lt(k, occurrences) {
                    k := add(k, 1)
                } {
                    sstore(dst, player)
                    dst := add(dst, 1)
                }
            }
            unchecked {
                ++u;
            }
        }
    }

    /// @dev Clears all 80 daily burn counters using assembly for gas efficiency.
    ///      The counters are packed 8 per slot (10 slots total).
    function _clearDailyBurnCount() private {
        assembly ("memory-safe") {
            let slot := dailyBurnCount.slot
            let end := add(slot, 10)
            for { let s := slot } lt(s, end) { s := add(s, 1) } {
                sstore(s, 0)
            }
        }
    }

    // =========================================================================
    // Internal Helpers — Winner Selection
    // =========================================================================

    /// @dev Selects random winners from a trait's ticket pool.
    ///      NOTE: Duplicates are intentionally allowed — more tickets = more chances to win multiple times.
    ///
    /// @param traitBurnTicket_ Storage reference to the trait ticket mapping.
    /// @param randomWord VRF entropy for selection.
    /// @param trait Trait ID to select from.
    /// @param numWinners Number of winners to select.
    /// @param salt Additional entropy to differentiate calls.
    /// @return winners Array of selected winner addresses (may contain duplicates).
    function _randTraitTicket(
        address[][256] storage traitBurnTicket_,
        uint256 randomWord,
        uint8 trait,
        uint8 numWinners,
        uint8 salt
    ) private view returns (address[] memory winners) {
        address[] storage holders = traitBurnTicket_[trait];
        uint256 len = holders.length;
        if (len == 0 || numWinners == 0) return new address[](0);

        winners = new address[](numWinners);
        // XOR in trait and salt to create unique entropy per call.
        uint256 slice = randomWord ^ (uint256(trait) << 128) ^ (uint256(salt) << 192);
        for (uint256 i; i < numWinners; ) {
            uint256 idx = slice % len;
            winners[i] = holders[idx];
            unchecked {
                ++i;
                // Rotate bits to get different indices for subsequent winners.
                slice = (slice >> 16) | (slice << 240);
            }
        }
    }

}
