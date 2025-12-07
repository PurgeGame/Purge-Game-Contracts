// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDegenerusCoinModule {
    function creditFlip(address player, uint256 amount) external;
    function rollDailyQuest(uint48 day, uint256 entropy) external;
    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forceBurn) external;
}
