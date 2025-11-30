// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameExternalOp} from "../interfaces/IPurgeGameExternal.sol";

contract MockPurgeGame {
    bool public rngLocked;
    uint24 public level = 25;
    uint8 public gameState = 2;
    mapping(address => uint32) public streaks;
    mapping(address => uint32) public levelCounts;
    mapping(address => uint24) public lastMintLevels;
    uint256 public principalStEth;
    address public bonds;
    uint24 public sampleTicketsLevel;
    uint8 public sampleTraitId;
    address[] internal sampleTickets;

    function setRngLocked(bool v) external { rngLocked = v; }
    function setLevel(uint24 v) external { level = v; }
    function setGameState(uint8 v) external { gameState = v; }
    function setStreak(address u, uint32 s) external { streaks[u] = s; }
    function setLevelCount(address u, uint32 c) external { levelCounts[u] = c; }
    function setLastMintLevel(address u, uint24 l) external { lastMintLevels[u] = l; }
    function setPrincipalStEth(uint256 v) external { principalStEth = v; }
    function setBonds(address bonds_) external { bonds = bonds_; }
    function setSampleTickets(address[] calldata tickets, uint24 lvl, uint8 trait) external {
        sampleTicketsLevel = lvl;
        sampleTraitId = trait;
        sampleTickets = tickets;
    }

    function ethMintStreakCount(address player) external view returns (uint32) {
        return streaks[player];
    }
    
    function ethMintLevelCount(address player) external view returns (uint32) {
        return levelCounts[player];
    }

    function ethMintLastLevel(address player) external view returns (uint24) {
        return lastMintLevels[player];
    }

    function principalStEthBalance() external view returns (uint256) {
        return principalStEth;
    }

    function sampleTraitTickets(uint256) external view returns (uint24 lvl, uint8 trait, address[] memory tickets) {
        return (sampleTicketsLevel, sampleTraitId, sampleTickets);
    }

    function applyExternalOp(PurgeGameExternalOp, address, uint256, uint24) external {}
}
