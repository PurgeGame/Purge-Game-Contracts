// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDegenerusCoinModule {
    function creditFlip(address player, uint256 amount) external;
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external;
    function rollDailyQuest(uint48 day, uint256 entropy) external;
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forceBurn) external;
}
