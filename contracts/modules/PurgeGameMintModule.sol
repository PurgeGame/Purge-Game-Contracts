// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameStorage} from "../storage/PurgeGameStorage.sol";

/**
 * @title PurgeGameMintModule
 * @notice Delegate-called module that hosts mint history packing, airdrop math, and trait rebuild helpers.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract PurgeGameMintModule is PurgeGameStorage {
    error E();

    uint48 private constant JACKPOT_RESET_TIME = 82620;
    uint32 private constant TRAIT_REBUILD_TOKENS_PER_TX = 2500;
    uint32 private constant TRAIT_REBUILD_TOKENS_LEVEL1 = 1800;

    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant MINT_MASK_16 = (uint256(1) << 16) - 1;
    uint256 private constant MINT_MASK_20 = (uint256(1) << 20) - 1;
    uint256 private constant MINT_MASK_32 = (uint256(1) << 32) - 1;
    uint256 private constant ETH_LAST_LEVEL_SHIFT = 0;
    uint256 private constant ETH_LEVEL_COUNT_SHIFT = 24;
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;
    uint256 private constant ETH_DAY_SHIFT = 72;
    uint256 private constant ETH_DAY_STREAK_SHIFT = 104;
    uint256 private constant COIN_DAY_SHIFT = 124;
    uint256 private constant COIN_DAY_STREAK_SHIFT = 156;
    uint256 private constant AGG_DAY_SHIFT = 176;
    uint256 private constant AGG_DAY_STREAK_SHIFT = 208;
    uint256 private constant ETH_LEVEL_UNITS_SHIFT = 228;
    uint256 private constant ETH_LEVEL_BONUS_SHIFT = 244;

    /// @notice Record mint metadata and compute coin rewards for ETH mints.
    function recordMintData(
        address player,
        uint24 lvl,
        bool coinMint,
        uint32 mintUnits
    ) external returns (uint256 coinReward) {
        uint256 prevData = mintPacked_[player];
        uint32 day = _currentMintDay();
        uint256 data;

        if (coinMint) {
            data = _applyMintDay(prevData, day, COIN_DAY_SHIFT, MINT_MASK_32, COIN_DAY_STREAK_SHIFT, MINT_MASK_20);
        } else {
            uint256 priceCoinLocal = priceCoin;
            uint24 prevLevel = uint24((prevData >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
            uint24 total = uint24((prevData >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
            uint24 streak = uint24((prevData >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
            bool sameLevel = prevLevel == lvl;
            bool newCentury = (prevLevel / 100) != (lvl / 100);
            uint256 levelUnitsBefore = (prevData >> ETH_LEVEL_UNITS_SHIFT) & MINT_MASK_16;
            if (!sameLevel && prevLevel + 1 != lvl) {
                levelUnitsBefore = 0;
            }
            bool bonusPaid = sameLevel && (((prevData >> ETH_LEVEL_BONUS_SHIFT) & 1) == 1);
            uint256 levelUnitsAfter = levelUnitsBefore + uint256(mintUnits);
            if (levelUnitsAfter > MINT_MASK_16) {
                levelUnitsAfter = MINT_MASK_16;
            }
            bool awardBonus = (!bonusPaid) && levelUnitsAfter >= 400;
            if (awardBonus) {
                coinReward += (priceCoinLocal * 5) / 2;
                bonusPaid = true;
            }

            if (!sameLevel && levelUnitsAfter < 4) {
                data = _setPacked(prevData, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
                data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);
                if (data != prevData) {
                    mintPacked_[player] = data;
                }
                return coinReward;
            }

            data = _applyMintDay(prevData, day, ETH_DAY_SHIFT, MINT_MASK_32, ETH_DAY_STREAK_SHIFT, MINT_MASK_20);

            if (sameLevel) {
                data = _setPacked(data, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
                data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);
                if (data != prevData) {
                    mintPacked_[player] = data;
                }
                return coinReward;
            }

            if (newCentury) {
                total = 1;
            } else if (total < type(uint24).max) {
                unchecked {
                    total = uint24(total + 1);
                }
            }

            if (prevLevel != 0 && prevLevel + 1 == lvl) {
                if (streak < type(uint24).max) {
                    unchecked {
                        streak = uint24(streak + 1);
                    }
                }
            } else {
                streak = 1;
            }

            data = _setPacked(data, ETH_LAST_LEVEL_SHIFT, MINT_MASK_24, lvl);
            data = _setPacked(data, ETH_LEVEL_COUNT_SHIFT, MINT_MASK_24, total);
            data = _setPacked(data, ETH_LEVEL_STREAK_SHIFT, MINT_MASK_24, streak);
            data = _setPacked(data, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
            data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);

            uint256 rewardUnit = priceCoinLocal / 10;
            uint256 streakReward;
            if (streak >= 2) {
                uint256 capped = streak >= 61 ? 60 : uint256(streak - 1);
                streakReward = capped * rewardUnit;
            }

            uint256 totalReward;
            if (total >= 2) {
                uint256 cappedTotal = total >= 61 ? 60 : uint256(total - 1);
                totalReward = (cappedTotal * rewardUnit * 30) / 100;
            }

            if (streakReward != 0 || totalReward != 0) {
                unchecked {
                    coinReward += streakReward + totalReward;
                }
            }

            if (streak == lvl && lvl >= 20 && (lvl % 10 == 0)) {
                uint256 milestoneBonus = (uint256(lvl) / 2) * priceCoinLocal;
                coinReward += milestoneBonus;
            }

            if (total >= 20 && (total % 10 == 0)) {
                uint256 totalMilestone = (uint256(total) / 2) * priceCoinLocal;
                coinReward += (totalMilestone * 30) / 100;
            }
        }

        if (data != prevData) {
            mintPacked_[player] = data;
        }
        return coinReward;
    }

    /// @notice Pure airdrop multiplier helper (kept out of the core contract for bytecode savings).
    function calculateAirdropMultiplier(uint32 purchaseCount, uint24 lvl) external pure returns (uint32) {
        if (purchaseCount == 0) {
            return 1;
        }
        uint256 target = (lvl % 10 == 8) ? 10_000 : 5_000;
        if (purchaseCount >= target) {
            return 1;
        }
        uint256 numerator = target + uint256(purchaseCount) - 1;
        return uint32(numerator / purchaseCount);
    }

    /// @notice Expand raw purchase counts using the stored airdrop multiplier.
    function purchaseTargetCountFromRaw(uint32 rawCount) external view returns (uint32) {
        if (rawCount == 0) {
            return 0;
        }
        uint32 multiplier = airdropMultiplier;
        uint256 scaled = uint256(rawCount) * uint256(multiplier);
        if (scaled > type(uint32).max) revert E();
        return uint32(scaled);
    }

    /// @notice Rebuild `traitRemaining` by scanning scheduled token traits in capped slices.
    /// @param tokenBudget Max tokens to process this call (0 => default 4,096 or level-1 fallback).
    /// @param target Total tokens expected for this level (pre-scaled).
    /// @param baseTokenId Current base token id for this level (passed from core to avoid extra slots).
    /// @return finished True when all tokens for the level have been incorporated.
    function rebuildTraitCounts(
        uint32 tokenBudget,
        uint32 target,
        uint256 baseTokenId
    ) external returns (bool finished) {
        uint32 cursor = traitRebuildCursor;
        if (cursor >= target) return true;

        uint32 batch = (tokenBudget == 0) ? TRAIT_REBUILD_TOKENS_PER_TX : tokenBudget;
        bool startingSlice = cursor == 0;
        if (startingSlice) {
            uint32 firstBatch = (level == 1) ? TRAIT_REBUILD_TOKENS_LEVEL1 : TRAIT_REBUILD_TOKENS_PER_TX;
            batch = firstBatch;
        }
        uint32 remaining = target - cursor;
        if (batch > remaining) batch = remaining;

        uint32[256] memory localCounts;

        for (uint32 i; i < batch; ) {
            uint32 tokenOffset = cursor + i;
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

        uint32[256] storage remainingCounts = traitRemaining;
        for (uint16 traitId; traitId < 256; ) {
            uint32 incoming = localCounts[traitId];
            if (incoming != 0) {
                // Assumes the first slice will touch all traits to overwrite stale counts from the previous level.
                if (startingSlice) {
                    remainingCounts[traitId] = incoming;
                } else {
                    remainingCounts[traitId] += incoming;
                }
            }
            unchecked {
                ++traitId;
            }
        }

        traitRebuildCursor = cursor + batch;
        finished = (traitRebuildCursor == target);
    }

    function _currentMintDay() private view returns (uint32) {
        uint48 day = dailyIdx;
        if (day == 0) {
            // Matches the JACKPOT_RESET_TIME-offset day index used in advanceGame.
            day = uint48((uint48(block.timestamp) - JACKPOT_RESET_TIME) / 1 days);
        }
        return uint32(day);
    }

    function _applyMintDay(
        uint256 data,
        uint32 day,
        uint256 dayShift,
        uint256 dayMask,
        uint256 streakShift,
        uint256 streakMask
    ) private pure returns (uint256) {
        data = _bumpMintDay(data, day, dayShift, dayMask, streakShift, streakMask);
        if (dayShift != AGG_DAY_SHIFT) {
            data = _bumpMintDay(data, day, AGG_DAY_SHIFT, MINT_MASK_32, AGG_DAY_STREAK_SHIFT, MINT_MASK_20);
        }
        return data;
    }

    function _bumpMintDay(
        uint256 data,
        uint32 day,
        uint256 dayShift,
        uint256 dayMask,
        uint256 streakShift,
        uint256 streakMask
    ) private pure returns (uint256) {
        uint32 prevDay = uint32((data >> dayShift) & dayMask);
        if (prevDay == day) {
            return data;
        }

        uint256 streak = (data >> streakShift) & streakMask;
        if (prevDay != 0 && day == prevDay + 1) {
            if (streak < streakMask) {
                unchecked {
                    streak += 1;
                }
            }
        } else {
            streak = 1;
        }

        uint256 clearedDay = data & ~(dayMask << dayShift);
        uint256 updated = clearedDay | (uint256(day) << dayShift);
        uint256 clearedStreak = updated & ~(streakMask << streakShift);
        return clearedStreak | (streak << streakShift);
    }

    function _setPacked(uint256 data, uint256 shift, uint256 mask, uint256 value) private pure returns (uint256) {
        return (data & ~(mask << shift)) | ((value & mask) << shift);
    }

    function _traitWeight(uint32 rnd) private pure returns (uint8) {
        unchecked {
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

    function _deriveTrait(uint64 rnd) private pure returns (uint8) {
        uint8 category = _traitWeight(uint32(rnd));
        uint8 sub = _traitWeight(uint32(rnd >> 32));
        return (category << 3) | sub;
    }

    function _traitsForToken(uint256 tokenId) private pure returns (uint32 packed) {
        uint256 rand = uint256(keccak256(abi.encodePacked(tokenId)));
        uint8 trait0 = _deriveTrait(uint64(rand));
        uint8 trait1 = _deriveTrait(uint64(rand >> 64)) | 64;
        uint8 trait2 = _deriveTrait(uint64(rand >> 128)) | 128;
        uint8 trait3 = _deriveTrait(uint64(rand >> 192)) | 192;
        packed = uint32(trait0) | (uint32(trait1) << 8) | (uint32(trait2) << 16) | (uint32(trait3) << 24);
    }
}
