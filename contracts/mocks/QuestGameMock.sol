// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IPurgeGame.sol";

contract QuestGameMock is IPurgeGame {
    uint8 private phase;
    uint8 private state;
    uint24 private currentLevel;
    mapping(address => uint24) private lastEthMintLevel;

    function setPhase(uint8 newPhase) external {
        phase = newPhase;
    }

    function setGameState(uint8 newState) external {
        state = newState;
    }

    function setLevel(uint24 newLevel) external {
        currentLevel = newLevel;
    }

    function setEthMintLastLevel(address player, uint24 lvl) external {
        lastEthMintLevel[player] = lvl;
    }

    function getTraitRemainingQuad(
        uint8[4] calldata /*traitIds*/
    ) external view override returns (uint16 lastExterminated, uint24 lvl, uint32[4] memory remaining) {
        lastExterminated = 0;
        lvl = currentLevel;
        remaining = [uint32(0), uint32(0), uint32(0), uint32(0)];
    }

    function level() external view override returns (uint24) {
        return currentLevel;
    }

    function gameState() external view override returns (uint8) {
        return state;
    }

    function currentPhase() external view override returns (uint8) {
        return phase;
    }

    function mintPrice() external pure override returns (uint256) {
        return 0;
    }

    function coinPriceUnit() external pure override returns (uint256) {
        return 0;
    }

    function getEarlyPurgePercent() external pure override returns (uint8) {
        return 0;
    }

    function coinMintUnlock(uint24 /*lvl*/) external pure override returns (bool) {
        return false;
    }

    function ethMintLevelCount(address /*player*/) external pure override returns (uint24) {
        return 0;
    }

    function ethMintStreakCount(address /*player*/) external pure override returns (uint24) {
        return 0;
    }

    function ethMintLastLevel(address player) external view override returns (uint24) {
        return lastEthMintLevel[player];
    }

    function enqueueMap(address /*buyer*/, uint32 /*quantity*/) external pure override {}

    function recordMint(
        address /*player*/,
        uint24 /*lvl*/,
        bool /*creditNext*/,
        bool /*coinMint*/,
        uint256 /*costWei*/
    ) external payable override returns (uint256 coinReward) {
        coinReward = 0;
    }

    function rngLocked() external pure override returns (bool) {
        return false;
    }

    function isRngFulfilled() external pure override returns (bool) {
        return true;
    }

    function purchaseWithClaimable(bool /*mapPurchase*/) external pure override {}
}
