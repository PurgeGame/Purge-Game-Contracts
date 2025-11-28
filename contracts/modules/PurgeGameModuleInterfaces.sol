// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";

interface IPurgeCoinModule {
    function jackpots() external view returns (address);

    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch,
        uint256 priceCoinUnit
    ) external returns (bool);

    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory);
    function getTopAffiliate() external view returns (address);

    function bonusCoinflip(address player, uint256 amount, bool rngReady) external;

    function addToBounty(uint256 amount) external;

    function rewardTopFlipBonus(uint256 amount) external;

    function resetCoinflipLeaderboard() external;

    function resetAffiliateLeaderboard(uint24 lvl) external;

    function burnie(uint256 amount, address stethToken) external payable;

    function rollDailyQuest(uint48 day, uint256 entropy) external;
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forcePurge) external;
}

interface IPurgeGameTrophiesModule {
    function awardTrophy(address to, uint24 level, uint8 kind, uint256 data, uint256 deferredWei) external;

    function trophyToken(uint24 level, uint8 kind) external view returns (uint256 tokenId);
    function rewardTrophyByToken(uint256 tokenId, uint256 amountWei, uint24 level) external;
    function rewardTrophy(uint24 level, uint8 kind, uint256 amountWei) external returns (bool paid);
    function rewardRandomStaked(uint256 rngSeed, uint256 amountWei, uint24 level) external returns (bool paid);
    function processEndLevel(
        IPurgeGameTrophies.EndLevelRequest calldata req,
        uint256 scaledPool
    ) external returns (uint256 paidTotal);
    function trophyOwner(uint256 tokenId) external view returns (address owner);

    function burnBafPlaceholder(uint24 level) external;

    function burnDecPlaceholder(uint24 level) external;
}
