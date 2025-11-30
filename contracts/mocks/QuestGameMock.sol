// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGameExternalOp} from "../interfaces/IPurgeGameExternal.sol";
import "../interfaces/IPurgeGame.sol";

contract QuestGameMock is IPurgeGame {
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;

    uint8 private phase;
    uint8 private state;
    uint24 private currentLevel;
    uint24 private sampleTicketLevel;
    uint8 private sampleTraitId;
    mapping(address => uint24) private lastEthMintLevel;
    mapping(address => uint24) private ethStreaks;
    address[] private sampleTickets;

    function setPhase(uint8 newPhase) external {
        phase = newPhase;
    }

    function setGameState(uint8 newState) external {
        state = newState;
    }

    function setLevel(uint24 newLevel) external {
        currentLevel = newLevel;
    }

    function setEthMintStreak(address player, uint24 streak) external {
        ethStreaks[player] = streak;
    }

    function setEthMintLastLevel(address player, uint24 lvl) external {
        lastEthMintLevel[player] = lvl;
    }

    function setSampleTickets(address[] calldata tickets, uint24 lvl, uint8 trait) external {
        sampleTickets = tickets;
        sampleTicketLevel = lvl;
        sampleTraitId = trait;
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

    function gameInfo()
        external
        view
        override
        returns (
            uint8 gameState_,
            uint8 phase_,
            uint8 jackpotCounter_,
            uint256 price_,
            uint256 rewardPool_,
            uint256 prizePoolTarget,
            uint256 prizePoolCurrent,
            uint256 nextPrizePool_,
            uint8 earlyPurgePercent_
        )
    {
        gameState_ = state;
        phase_ = phase;
        jackpotCounter_ = 0;
        price_ = 0;
        rewardPool_ = 0;
        prizePoolTarget = 0;
        prizePoolCurrent = 0;
        nextPrizePool_ = 0;
        earlyPurgePercent_ = 0;
    }

    function getEarlyPurgePercent() external pure override returns (uint8) {
        return 0;
    }

    function principalStEthBalance() external pure override returns (uint256) {
        return 0;
    }

    function setBonds(address) external pure override {}

    function decWindow() external view override returns (bool on, uint24 lvl) {
        uint24 curLvl = currentLevel;
        lvl = curLvl;

        bool special = (curLvl != 0) && (curLvl % DECIMATOR_SPECIAL_LEVEL == 0);
        if (!special && state == 3 && curLvl < type(uint24).max) {
            uint24 next = curLvl + 1;
            if (next % DECIMATOR_SPECIAL_LEVEL == 0) {
                special = true;
                lvl = next;
            }
        }

        bool standard = (curLvl >= 25 && (curLvl % 10) == 5 && (curLvl % 100) != 95);
        on = standard || special;
    }

    function isBafLevelActive(uint24 lvl) external view override returns (bool) {
        if (lvl == 0) return false;
        if ((lvl % 10) != 0) return false;
        return state == 3;
    }

    function purchaseInfo()
        external
        view
        override
        returns (
            uint24 lvl,
            uint8 gameState_,
            uint8 phase_,
            bool rngLocked_,
            uint256 priceWei,
            uint256 priceCoinUnit
        )
    {
        lvl = currentLevel;
        gameState_ = state;
        phase_ = phase;
        rngLocked_ = false;
        priceWei = 0;
        priceCoinUnit = 0;

        if (gameState_ == 3) {
            unchecked {
                ++lvl;
            }
        }
    }

    function ethMintLevelCount(address /*player*/) external pure override returns (uint24) {
        return 0;
    }

    function ethMintStreakCount(address player) external view override returns (uint24) {
        return ethStreaks[player];
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
        uint256 /*costWei*/,
        uint32 /*mintUnits*/
    ) external payable override returns (uint256 coinReward) {
        coinReward = 0;
    }

    function rngLocked() external pure override returns (bool) {
        return false;
    }

    function purchaseWithClaimable(bool /*mapPurchase*/) external pure override {}

    function applyExternalOp(
        PurgeGameExternalOp,
        address,
        uint256,
        uint24
    ) external pure override {}

    function sampleTraitTickets(uint256) external view override returns (uint24, uint8, address[] memory) {
        return (sampleTicketLevel, sampleTraitId, sampleTickets);
    }

    function stEthToken() external pure returns (address) {
        return address(0);
    }
}
