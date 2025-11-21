// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Purgecoin} from "../Purgecoin.sol";

contract PurgecoinHarness is Purgecoin {
    function harnessSetStakeLevelComplete(uint24 level) external {
        stakeLevelComplete = level;
    }

    function harnessMint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function harnessQuestHandleMint(address player, uint32 quantity, bool paidWithEth) external {
        (
            uint256 reward,
            bool hardMode,
            uint8 questType,
            uint32 streak,
            bool completed
        ) = questModule.handleMint(player, quantity, paidWithEth);
        _questHarnessApply(player, reward, hardMode, questType, streak, completed);
    }

    function harnessQuestHandleFlip(address player, uint256 flipCredit) external {
        (
            uint256 reward,
            bool hardMode,
            uint8 questType,
            uint32 streak,
            bool completed
        ) = questModule.handleFlip(player, flipCredit);
        _questHarnessApply(player, reward, hardMode, questType, streak, completed);
    }

    function harnessQuestHandleStake(address player, uint256 principal, uint24 distance, uint8 risk) external {
        (
            uint256 reward,
            bool hardMode,
            uint8 questType,
            uint32 streak,
            bool completed
        ) = questModule.handleStake(player, principal, distance, risk);
        _questHarnessApply(player, reward, hardMode, questType, streak, completed);
    }

    function harnessQuestHandleAffiliate(address player, uint256 amount) external {
        (
            uint256 reward,
            bool hardMode,
            uint8 questType,
            uint32 streak,
            bool completed
        ) = questModule.handleAffiliate(player, amount);
        _questHarnessApply(player, reward, hardMode, questType, streak, completed);
    }

    function harnessQuestHandlePurge(address player, uint32 quantity) external {
        (
            uint256 reward,
            bool hardMode,
            uint8 questType,
            uint32 streak,
            bool completed
        ) = questModule.handlePurge(player, quantity);
        _questHarnessApply(player, reward, hardMode, questType, streak, completed);
    }

    function harnessQuestHandleDecimator(address player, uint256 burnAmount) external {
        (
            uint256 reward,
            bool hardMode,
            uint8 questType,
            uint32 streak,
            bool completed
        ) = questModule.handleDecimator(player, burnAmount);
        _questHarnessApply(player, reward, hardMode, questType, streak, completed);
    }

    function _questHarnessApply(
        address player,
        uint256 reward,
        bool hardMode,
        uint8 questType,
        uint32 streak,
        bool completed
    ) private {
        if (!completed || player == address(0)) {
            return;
        }
        if (reward != 0) {
            addFlip(player, reward, false, false, false);
        }
        emit QuestCompleted(player, questType, streak, reward, hardMode);
    }
}
