// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeCoinModule {
    function jackpots() external view returns (address);
    function affiliateProgram() external view returns (address);

    function processCoinflipPayouts(
        uint24 level,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch,
        uint256 priceCoinUnit
    ) external returns (bool);

    function creditFlip(address player, uint256 amount) external;
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;

    function addToBounty(uint256 amount) external;

    function rollDailyQuest(uint48 day, uint256 entropy) external;
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forcePurge) external;
}
