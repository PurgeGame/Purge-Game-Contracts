// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IPurgeQuestModule.sol";

contract MockQuestModule is IPurgeQuestModule {
    function wireGame(address) external override {}
    function primeMintEthQuest(uint48) external override {}
    function rollDailyQuest(uint48, uint256) external override returns (bool, uint8, bool, uint8, uint8) {
        return (false, 0, false, 0, 0);
    }
    function rollDailyQuestWithOverrides(uint48, uint256, bool, bool)
        external
        override
        returns (bool, uint8, bool, uint8, uint8)
    {
        return (false, 0, false, 0, 0);
    }
    function handleMint(address, uint32, bool) external override returns (uint256, bool, uint8, uint32, bool) {
        return (0, false, 0, 0, false);
    }
    function handlePurge(address, uint32) external override returns (uint256, bool, uint8, uint32, bool) {
        return (0, false, 0, 0, false);
    }
    function handleFlip(address, uint256) external override returns (uint256, bool, uint8, uint32, bool) {
        return (0, false, 0, 0, false);
    }
    function handleStake(address, uint256, uint24, uint8) external override returns (uint256, bool, uint8, uint32, bool) {
        return (0, false, 0, 0, false);
    }
    function handleAffiliate(address, uint256) external override returns (uint256, bool, uint8, uint32, bool) {
        return (0, false, 0, 0, false);
    }
    function handleDecimator(address, uint256) external override returns (uint256, bool, uint8, uint32, bool) {
        return (0, false, 0, 0, false);
    }
    function getActiveQuest() external pure override returns (uint48, uint8, bool, uint8, uint8) {
        return (0, 0, false, 0, 0);
    }
    function getActiveQuests() external pure override returns (QuestInfo[2] memory) {
        QuestInfo[2] memory q;
        return q;
    }
    function playerQuestState(address) external pure override returns (uint32, uint32, uint128, bool) {
        return (0, 0, 0, false);
    }
    function playerQuestStates(address) external pure override returns (uint32, uint32, uint128[2] memory, bool[2] memory) {
        uint128[2] memory p;
        bool[2] memory c;
        return (0, 0, p, c);
    }
    function getQuestDetails() external pure override returns (QuestDetail[2] memory quests) {
        return quests;
    }
}
