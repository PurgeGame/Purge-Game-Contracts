// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusAffiliate} from "../interfaces/IDegenerusAffiliate.sol";

interface IDegenerusQuestView {
    function playerQuestStates(
        address player
    )
        external
        view
        returns (uint32 streak, uint32 lastCompletedDay, uint128[2] memory progress, bool[2] memory completed);
}

interface IERC721BalanceOf {
    function balanceOf(address owner) external view returns (uint256);
}

library DegenerusBondsScoringLib {
    function scoreWithMultiplier(
        address affiliate,
        address questModule,
        address trophies,
        address player,
        uint256 baseScore,
        uint24 currLevel,
        uint24 mintLevelCount,
        uint24 mintStreak
    ) external view returns (uint256) {
        // Early exit: no score means no calculation needed
        if (baseScore == 0) return 0;

        // Early exit: zero player gets base score only (avoids all external calls)
        if (player == address(0)) return baseScore;

        uint256 bonusBps;

        unchecked {
            // Mint streak: cap at 25, worth 1% each (100 bps)
            uint256 mintStreakPoints = mintStreak > 25 ? 25 : uint256(mintStreak);
            bonusBps = mintStreakPoints * 100;

            // Quest streak: cap at 50, worth 0.5% each (50 bps)
            if (questModule != address(0)) {
                (uint32 streak, , , ) = IDegenerusQuestView(questModule).playerQuestStates(player);
                uint256 questStreak = streak > 50 ? 50 : uint256(streak);
                bonusBps += questStreak * 50;
            }

            // Affiliate bonus: only if currLevel >= 1 and affiliate is set
            if (currLevel != 0 && affiliate != address(0)) {
                bonusBps += IDegenerusAffiliate(affiliate).affiliateBonusPointsBest(currLevel, player) * 100;
            }

            // Mint count bonus: 1% each
            bonusBps += _mintCountBonusPoints(mintLevelCount, currLevel) * 100;

            // Trophy bonus: +10% per trophy, capped at +50%
            if (trophies != address(0)) {
                uint256 trophyCount = IERC721BalanceOf(trophies).balanceOf(player);
                if (trophyCount > 5) trophyCount = 5;
                bonusBps += trophyCount * 1000;
            }
        }

        // Apply multiplier: base 1.0x (10000 bps) plus bonuses
        unchecked {
            return (baseScore * (10000 + bonusBps)) / 10000;
        }
    }

    function _mintCountBonusPoints(uint24 mintCount, uint24 currLevel) private pure returns (uint256) {
        if (mintCount == 0 || currLevel == 0) return 0;

        unchecked {
            uint24 cyclePos = currLevel % 100;
            if (cyclePos == 0 || cyclePos <= 25) {
                return mintCount > 25 ? 25 : uint256(mintCount);
            }

            uint256 scaled = (uint256(mintCount) * 25) / uint256(cyclePos);
            return scaled > 25 ? 25 : scaled;
        }
    }
}
