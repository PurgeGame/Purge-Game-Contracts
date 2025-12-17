// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev No-op coin module used by jackpot module tests.
contract MockCoinModule {
    function creditFlip(address, uint256) external {}

    function rollDailyQuest(uint48, uint256) external {}

    function rollDailyQuestWithOverrides(uint48, uint256, bool, bool) external {}
}

