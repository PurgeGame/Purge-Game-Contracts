// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";

/**
 * @title DegenerusGameMintModule
 * @author Burnie Degenerus
 * @notice Delegate-called module handling mint history, airdrop math, and trait rebuilding.
 *
 * @dev This module is called via `delegatecall` from DegenerusGame, meaning all storage
 *      reads/writes operate on the game contract's storage.
 *
 * ## Functions
 *
 * - `recordMintData`: Track per-player mint history and calculate BURNIE rewards
 * - `calculateAirdropMultiplier`: Compute bonus multiplier for low-participation levels
 * - `purchaseTargetCountFromRaw`: Scale raw purchase count by airdrop multiplier
 * - `rebuildTraitCounts`: Reconstruct traitRemaining[] for new levels
 *
 * ## Bit Packing Layout (mintPacked_)
 *
 * All per-player mint history is packed into a single uint256:
 *
 * ```
 * Bits 0-23:   lastLevel     - Last level with ETH mint
 * Bits 24-47:  levelCount    - Levels minted this century (resets every 100)
* Bits 48-71:  levelStreak   - Consecutive levels minted
* Bits 72-103: lastMintDay   - Day index of last mint
 * Bits 104-127: unitsLevel  - Level index for levelUnits tracking
* Bits 228-243: levelUnits   - Units minted this level (1 NFT = 4 units)
* Bit 244:     bonusPaid     - Whether 400-unit bonus was paid this level
* ```
 *
 * ## BURNIE Reward Structure
 *
 * | Reward Type | Trigger | Amount |
 * |-------------|---------|--------|
 * | 400-unit bonus | First mint ≥400 units in level | 2,500 BURNIE |
 * | Streak reward | Each new level (2nd+) | up to 1,800 BURNIE (capped at 60 levels) |
 * | Milestone | Every 10 levels from 20+ | (total/2) × 1000 × 30% BURNIE |
 *
 * ## Trait Generation
 *
 * Traits are deterministically derived from tokenId via keccak256:
 * - Each token has 4 traits (one per quadrant: 0-63, 64-127, 128-191, 192-255)
 * - Uses 8×8 weighted grid for non-uniform distribution
 * - Higher-numbered sub-traits within each category are slightly rarer
 */
contract DegenerusGameMintModule is DegenerusGameStorage {
    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Generic revert for overflow conditions.
    error E();

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Time offset for day calculation (matches game's jackpot reset time).
    uint48 private constant JACKPOT_RESET_TIME = 82620;

    /// @notice Default tokens to process per rebuildTraitCounts call.
    uint32 private constant TRAIT_REBUILD_TOKENS_PER_TX = 2500;

    /// @notice Reduced batch size for level 1 (smaller initial supply).
    uint32 private constant TRAIT_REBUILD_TOKENS_LEVEL1 = 1800;

    // ─────────────────────────────────────────────────────────────────────────
    // Bit Packing Masks and Shifts
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Mask for 24-bit fields.
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;

    /// @notice Mask for 16-bit fields.
    uint256 private constant MINT_MASK_16 = (uint256(1) << 16) - 1;

    /// @notice Mask for 32-bit fields.
    uint256 private constant MINT_MASK_32 = (uint256(1) << 32) - 1;

    /// @notice Bit shift for last minted level (24 bits at position 0).
    uint256 private constant ETH_LAST_LEVEL_SHIFT = 0;

    /// @notice Bit shift for level count within century (24 bits at position 24).
    uint256 private constant ETH_LEVEL_COUNT_SHIFT = 24;

    /// @notice Bit shift for consecutive level streak (24 bits at position 48).
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;

    /// @notice Bit shift for last mint day (32 bits at position 72).
    uint256 private constant ETH_DAY_SHIFT = 72;

    /// @notice Bit shift for units-level marker (24 bits at position 104).
    uint256 private constant ETH_LEVEL_UNITS_LEVEL_SHIFT = 104;

    /// @notice Bit shift for level units counter (16 bits at position 228).
    uint256 private constant ETH_LEVEL_UNITS_SHIFT = 228;

    /// @notice Bit shift for bonus-paid flag (1 bit at position 244).
    uint256 private constant ETH_LEVEL_BONUS_SHIFT = 244;

    // ─────────────────────────────────────────────────────────────────────────
    // Mint Data Recording
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Record mint metadata and compute BURNIE rewards for ETH mints.
     * @dev Called via delegatecall from DegenerusGame during recordMint().
     *      Updates the packed mint history and calculates bonus rewards.
     *
     * @param player Address of the player making the purchase.
     * @param lvl Current game level.
     * @param mintUnits Units purchased (1 NFT = 4 units, 1 MAP = 1 unit).
     * @return coinReward BURNIE amount to credit as coinflip stake.
     *
     * ## Reward Calculation
     *
     * 1. **400-unit bonus**: 2,500 BURNIE when first reaching 400 units in a level
     * 2. **Streak reward**: Based on total levels minted this century
     *    - Formula: min(total-1, 60) × (PRICE_COIN_UNIT/10) × 30%
     *    - Max: 60 × 100 × 0.3 = 1,800 BURNIE per level
     * 3. **Milestone bonus**: At levels 20, 30, 40... (every 10 from 20+)
     *    - Formula: (total/2) × PRICE_COIN_UNIT × 30%
     *
     * ## State Updates
     *
     * - `mintPacked_[player]` updated with new level, counts, streak, day
     * - Only writes to storage if data actually changed
     *
     * ## Level Transition Logic
     *
     * - Same level: Just update units and check bonus
     * - New level with <4 units: Only track units, don't count as "minted"
     * - New level with ≥4 units: Update streak, total, and award rewards
     * - Century boundary (level 100, 200...): Reset total to 1
     */
    function recordMintData(
        address player,
        uint24 lvl,
        uint32 mintUnits
    ) external payable returns (uint256 coinReward) {
        // Load previous packed data
        uint256 prevData = mintPacked_[player];
        uint256 data;

        // Calculate current day index
        uint32 day = _currentMintDay();
        uint256 priceCoinLocal = PRICE_COIN_UNIT;

        // ─────────────────────────────────────────────────────────────────────
        // Unpack previous state
        // ─────────────────────────────────────────────────────────────────────

        uint24 prevLevel = uint24((prevData >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
        uint24 total = uint24((prevData >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
        uint24 streak = uint24((prevData >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
        uint24 unitsLevel = uint24((prevData >> ETH_LEVEL_UNITS_LEVEL_SHIFT) & MINT_MASK_24);

        bool sameLevel = prevLevel == lvl;
        bool sameUnitsLevel = unitsLevel == lvl;
        bool newCentury = (prevLevel / 100) != (lvl / 100);

        // ─────────────────────────────────────────────────────────────────────
        // Handle level units and bonus
        // ─────────────────────────────────────────────────────────────────────

        // Get previous level units (reset on level change)
        uint256 levelUnitsBefore = sameUnitsLevel ? ((prevData >> ETH_LEVEL_UNITS_SHIFT) & MINT_MASK_16) : 0;

        // Check if 400-unit bonus already paid this level
        bool bonusPaid = sameUnitsLevel && (((prevData >> ETH_LEVEL_BONUS_SHIFT) & 1) == 1);

        // Calculate new level units (capped at 16-bit max)
        uint256 levelUnitsAfter = levelUnitsBefore + uint256(mintUnits);
        if (levelUnitsAfter > MINT_MASK_16) {
            levelUnitsAfter = MINT_MASK_16;
        }

        // Award 400-unit bonus if threshold crossed for first time
        bool awardBonus = (!bonusPaid) && levelUnitsAfter >= 400;
        if (awardBonus) {
            coinReward += (priceCoinLocal * 5) / 2; // 2,500 BURNIE
            bonusPaid = true;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Early exit: New level with <4 units (not counted as "minted")
        // ─────────────────────────────────────────────────────────────────────

        if (!sameLevel && levelUnitsAfter < 4) {
            // Just update units and bonus flag, don't update level/streak/total
            data = _setPacked(prevData, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
            data = _setPacked(data, ETH_LEVEL_UNITS_LEVEL_SHIFT, MINT_MASK_24, lvl);
            data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);
            if (data != prevData) {
                mintPacked_[player] = data;
            }
            return coinReward;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Update mint day
        // ─────────────────────────────────────────────────────────────────────

        data = _setMintDay(prevData, day, ETH_DAY_SHIFT, MINT_MASK_32);

        // ─────────────────────────────────────────────────────────────────────
        // Same level: Just update units
        // ─────────────────────────────────────────────────────────────────────

        if (sameLevel) {
            data = _setPacked(data, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
            data = _setPacked(data, ETH_LEVEL_UNITS_LEVEL_SHIFT, MINT_MASK_24, lvl);
            data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);
            if (data != prevData) {
                mintPacked_[player] = data;
            }
            return coinReward;
        }

        // ─────────────────────────────────────────────────────────────────────
        // New level with ≥4 units: Full state update
        // ─────────────────────────────────────────────────────────────────────

        // Update total (resets on century boundary)
        if (newCentury) {
            total = 1;
        } else if (total < type(uint24).max) {
            unchecked {
                total = uint24(total + 1);
            }
        }

        // Update streak (consecutive levels) or reset
        if (prevLevel != 0 && prevLevel + 1 == lvl) {
            // Consecutive level - increment streak
            if (streak < type(uint24).max) {
                unchecked {
                    streak = uint24(streak + 1);
                }
            }
        } else {
            // Gap or first mint - reset streak
            streak = 1;
        }

        // Pack all updated fields
        data = _setPacked(data, ETH_LAST_LEVEL_SHIFT, MINT_MASK_24, lvl);
        data = _setPacked(data, ETH_LEVEL_COUNT_SHIFT, MINT_MASK_24, total);
        data = _setPacked(data, ETH_LEVEL_STREAK_SHIFT, MINT_MASK_24, streak);
        data = _setPacked(data, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
        data = _setPacked(data, ETH_LEVEL_UNITS_LEVEL_SHIFT, MINT_MASK_24, lvl);
        data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);

        // ─────────────────────────────────────────────────────────────────────
        // Calculate streak rewards
        // ─────────────────────────────────────────────────────────────────────

        // Streak reward: scales with total levels minted (capped at 60)
        // Formula: min(total-1, 60) × (PRICE_COIN_UNIT/10) × 30%
        uint256 rewardUnit = priceCoinLocal / 10; // 100 BURNIE
        uint256 totalReward;
        if (total >= 2) {
            uint256 cappedTotal = total >= 61 ? 60 : uint256(total - 1);
            totalReward = (cappedTotal * rewardUnit * 30) / 100; // 30% of base
        }

        if (totalReward != 0) {
            unchecked {
                coinReward += totalReward;
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Milestone bonus (every 10 levels from 20+)
        // ─────────────────────────────────────────────────────────────────────

        if (total >= 20 && (total % 10 == 0)) {
            // Formula: (total/2) × PRICE_COIN_UNIT × 30%
            uint256 totalMilestone = (uint256(total) / 2) * priceCoinLocal;
            coinReward += (totalMilestone * 30) / 100;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Commit to storage (only if changed)
        // ─────────────────────────────────────────────────────────────────────

        if (data != prevData) {
            mintPacked_[player] = data;
        }
        return coinReward;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Airdrop Multiplier
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Calculate airdrop multiplier for low-participation levels.
     * @dev Pure function - no state changes. Creates a floor for trait distribution.
     *
     * @param prePurchaseCount Raw count before purchase phase (eligible for multiplier).
     * @param purchasePhaseCount Raw count during purchase phase (not multiplied).
     * @param lvl Current game level.
     * @return Multiplier to apply to purchase count (1 = no bonus).
     *
     * ## Logic
     *
     * - Target: 5,000 tokens (or 10,000 for levels ending in 8)
     * - If total purchases ≥ target: multiplier = 1 (no bonus)
     * - If prePurchaseCount == 0: multiplier = ceiling(target / purchasePhaseCount)
     * - Otherwise: multiplier = ceiling((target - purchasePhaseCount) / prePurchaseCount)
     *
     * ## Examples (purchasePhaseCount = 0)
     *
     * | Purchases | Level %10 | Target | Multiplier |
     * |-----------|-----------|--------|------------|
     * | 100 | 0-7,9 | 5,000 | 50x |
     * | 500 | 0-7,9 | 5,000 | 10x |
     * | 1,000 | 8 | 10,000 | 10x |
     * | 5,000+ | any | - | 1x |
     */
    function calculateAirdropMultiplier(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount,
        uint24 lvl
    ) external pure returns (uint32) {
        // Higher target for levels ending in 8
        uint256 target = (lvl % 10 == 8) ? 10_000 : 5_000;

        uint256 total = uint256(prePurchaseCount) + uint256(purchasePhaseCount);
        if (total >= target) {
            return 1;
        }

        if (prePurchaseCount == 0) {
            if (purchasePhaseCount == 0) {
                return 1;
            }
            // Ceiling division: (target + purchasePhaseCount - 1) / purchasePhaseCount
            uint256 numerator = target + uint256(purchasePhaseCount) - 1;
            return uint32(numerator / uint256(purchasePhaseCount));
        }

        // Remaining needed after purchase-phase purchases
        uint256 remaining = target - uint256(purchasePhaseCount);

        // Ceiling division: (remaining + prePurchaseCount - 1) / prePurchaseCount
        uint256 numerator = remaining + uint256(prePurchaseCount) - 1;
        return uint32(numerator / prePurchaseCount);
    }

    /**
     * @notice Scale raw purchase count by stored airdrop multiplier.
     * @dev View function - reads airdropMultiplier from storage.
     *
     * @param prePurchaseCount Raw count before purchase phase (eligible for multiplier).
     * @param purchasePhaseCount Raw count during purchase phase (not multiplied).
     * @return Scaled count (pre × airdropMultiplier + purchase phase).
     */
    function purchaseTargetCountFromRaw(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount
    ) external view returns (uint32) {
        if (prePurchaseCount == 0 && purchasePhaseCount == 0) {
            return 0;
        }

        uint32 multiplier = airdropMultiplier;
        uint256 scaled;
        if (prePurchaseCount == 0) {
            scaled = uint256(purchasePhaseCount) * uint256(multiplier);
        } else {
            scaled = uint256(prePurchaseCount) * uint256(multiplier) + uint256(purchasePhaseCount);
        }

        // Overflow protection
        if (scaled > type(uint32).max) revert E();

        return uint32(scaled);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Trait Count Rebuilding
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Rebuild traitRemaining[] by scanning scheduled token traits.
     * @dev Called during advanceGame state 2 to prepare trait counts for burn phase.
     *      Processes tokens in batches to stay within gas limits.
     *
     * @param tokenBudget Max tokens to process this call (0 = default 2,500).
     * @param target Total tokens expected for this level (pre-scaled).
     * @param baseTokenId Starting token ID for this level.
     * @return finished True when all tokens have been processed.
     *
     * ## Batching Strategy
     *
     * - Level 1: 1,800 tokens per batch (smaller initial supply)
     * - Other levels: 2,500 tokens per batch
     * - Can be called multiple times until finished
     *
     * ## State Updates
     *
     * - `traitRemaining[0-255]`: Overwritten on first slice, accumulated after
     * - `traitRebuildCursor`: Tracks progress through token list
     *
     * ## Trait Derivation
     *
     * Each token's 4 traits are deterministically computed from its tokenId:
     * - trait0: Quadrant 0 (0-63)
     * - trait1: Quadrant 1 (64-127)
     * - trait2: Quadrant 2 (128-191)
     * - trait3: Quadrant 3 (192-255)
     */
    function rebuildTraitCounts(
        uint32 tokenBudget,
        uint32 target,
        uint256 baseTokenId
    ) external returns (bool finished) {
        uint32 cursor = traitRebuildCursor;

        // Already complete
        if (cursor >= target) return true;

        // ─────────────────────────────────────────────────────────────────────
        // Determine batch size
        // ─────────────────────────────────────────────────────────────────────

        uint32 batch = (tokenBudget == 0) ? TRAIT_REBUILD_TOKENS_PER_TX : tokenBudget;
        bool startingSlice = cursor == 0;

        if (startingSlice) {
            // First batch: use level-appropriate size
            uint32 firstBatch = (level == 1) ? TRAIT_REBUILD_TOKENS_LEVEL1 : TRAIT_REBUILD_TOKENS_PER_TX;
            batch = firstBatch;
        }

        // Don't exceed remaining tokens
        uint32 remaining = target - cursor;
        if (batch > remaining) batch = remaining;

        // ─────────────────────────────────────────────────────────────────────
        // Scan tokens and count traits (in-memory)
        // ─────────────────────────────────────────────────────────────────────

        uint32[256] memory localCounts;

        for (uint32 i; i < batch; ) {
            uint32 tokenOffset = cursor + i;

            // Compute 4 traits for this token (deterministic from tokenId)
            uint32 traitPack = _traitsForToken(baseTokenId + tokenOffset);
            uint8 t0 = uint8(traitPack);
            uint8 t1 = uint8(traitPack >> 8);
            uint8 t2 = uint8(traitPack >> 16);
            uint8 t3 = uint8(traitPack >> 24);

            unchecked {
                ++localCounts[t0];
                ++localCounts[t1];
                ++localCounts[t2];
                ++localCounts[t3];
                ++i;
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Commit counts to storage
        // ─────────────────────────────────────────────────────────────────────

        uint32[256] storage remainingCounts = traitRemaining;

        for (uint16 traitId; traitId < 256; ) {
            uint32 incoming = localCounts[traitId];
            if (incoming != 0) {
                if (startingSlice) {
                    // First slice: overwrite stale counts from previous level
                    remainingCounts[traitId] = incoming;
                } else {
                    // Subsequent slices: accumulate
                    remainingCounts[traitId] += incoming;
                }
            }
            unchecked {
                ++traitId;
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Update cursor and return status
        // ─────────────────────────────────────────────────────────────────────

        traitRebuildCursor = cursor + batch;
        finished = (traitRebuildCursor == target);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Get current day index for mint tracking.
     * @dev Matches the JACKPOT_RESET_TIME-offset day index used in advanceGame.
     * @return Day index (days since epoch, offset by JACKPOT_RESET_TIME).
     */
    function _currentMintDay() private view returns (uint32) {
        uint48 day = dailyIdx;
        if (day == 0) {
            // Calculate from timestamp if not yet set
            day = uint48((uint48(block.timestamp) - JACKPOT_RESET_TIME) / 1 days);
        }
        return uint32(day);
    }

    /**
     * @notice Update day field in packed data (only if changed).
     * @param data Current packed data.
     * @param day New day value.
     * @param dayShift Bit position of day field.
     * @param dayMask Mask for day field.
     * @return Updated packed data.
     */
    function _setMintDay(uint256 data, uint32 day, uint256 dayShift, uint256 dayMask) private pure returns (uint256) {
        uint32 prevDay = uint32((data >> dayShift) & dayMask);
        if (prevDay == day) {
            return data; // No change needed
        }
        uint256 clearedDay = data & ~(dayMask << dayShift);
        return clearedDay | (uint256(day) << dayShift);
    }

    /**
     * @notice Set a field in packed data.
     * @param data Current packed data.
     * @param shift Bit position of field.
     * @param mask Mask for field width.
     * @param value New value for field.
     * @return Updated packed data.
     */
    function _setPacked(uint256 data, uint256 shift, uint256 mask, uint256 value) private pure returns (uint256) {
        return (data & ~(mask << shift)) | ((value & mask) << shift);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Trait Generation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Convert random value to weighted trait index (0-7).
     * @dev Non-uniform distribution - higher values slightly rarer.
     *
     * Weight distribution (out of 75 possible values):
     * - 0: 10 values (13.3%)
     * - 1: 10 values (13.3%)
     * - 2: 10 values (13.3%)
     * - 3: 10 values (13.3%)
     * - 4: 9 values (12.0%)
     * - 5: 9 values (12.0%)
     * - 6: 9 values (12.0%)
     * - 7: 8 values (10.7%)
     *
     * @param rnd Random 32-bit value.
     * @return Trait weight (0-7).
     */
    function _traitWeight(uint32 rnd) private pure returns (uint8) {
        unchecked {
            // Scale to 0-74 range
            uint32 scaled = uint32((uint64(rnd) * 75) >> 32);
            if (scaled < 10) return 0;
            if (scaled < 20) return 1;
            if (scaled < 30) return 2;
            if (scaled < 40) return 3;
            if (scaled < 49) return 4;
            if (scaled < 58) return 5;
            if (scaled < 67) return 6;
            return 7;
        }
    }

    /**
     * @notice Derive a single trait from 64 bits of randomness.
     * @dev Combines category (0-7) and sub-trait (0-7) into trait ID (0-63).
     *
     * @param rnd 64-bit random value.
     * @return Trait ID within quadrant (0-63).
     */
    function _deriveTrait(uint64 rnd) private pure returns (uint8) {
        uint8 category = _traitWeight(uint32(rnd));
        uint8 sub = _traitWeight(uint32(rnd >> 32));
        return (category << 3) | sub; // 8×8 grid = 64 possibilities
    }

    /**
     * @notice Compute all 4 traits for a token deterministically.
     * @dev Each trait is assigned to a quadrant (0-63, 64-127, 128-191, 192-255).
     *
     * @param tokenId Token ID to derive traits for.
     * @return packed Four traits packed as bytes: [trait3][trait2][trait1][trait0].
     *
     * ## Derivation
     *
     * ```
     * rand = keccak256(tokenId)
     * trait0 = deriveTrait(rand[0:64])         // Quadrant 0: 0-63
     * trait1 = deriveTrait(rand[64:128]) | 64  // Quadrant 1: 64-127
     * trait2 = deriveTrait(rand[128:192]) | 128 // Quadrant 2: 128-191
     * trait3 = deriveTrait(rand[192:256]) | 192 // Quadrant 3: 192-255
     * ```
     */
    function _traitsForToken(uint256 tokenId) private pure returns (uint32 packed) {
        uint256 rand = uint256(keccak256(abi.encodePacked(tokenId)));

        // Derive trait for each quadrant (each uses 64 bits of entropy)
        uint8 trait0 = _deriveTrait(uint64(rand));
        uint8 trait1 = _deriveTrait(uint64(rand >> 64)) | 64;   // Quadrant 1 offset
        uint8 trait2 = _deriveTrait(uint64(rand >> 128)) | 128; // Quadrant 2 offset
        uint8 trait3 = _deriveTrait(uint64(rand >> 192)) | 192; // Quadrant 3 offset

        // Pack into single uint32: [trait3][trait2][trait1][trait0]
        packed = uint32(trait0) | (uint32(trait1) << 8) | (uint32(trait2) << 16) | (uint32(trait3) << 24);
    }
}
