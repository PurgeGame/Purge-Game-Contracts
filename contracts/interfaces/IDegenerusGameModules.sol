// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "./DegenerusGameModuleInterfaces.sol";
import {MintPaymentKind} from "./IDegenerusGame.sol";

interface IDegenerusGameEndgameModule {
    function finalizeEndgame(uint24 lvl, uint256 rngWord) external;
}

interface IDegenerusGameGameOverModule {
    function handleGameOverDrain(uint48 day) external;
    function handleFinalSweep() external;
}

interface IDegenerusGameJackpotModule {
    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord
    ) external;

    function payMapJackpot(
        uint24 lvl,
        uint256 randWord
    ) external;

    function payCarryoverExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord
    ) external returns (uint256 paidEth);

    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        uint256 ethPool
    ) external returns (uint256 paidEth);

    function payLevelJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei
    ) external;

    function calcPrizePoolForLevelJackpot(
        uint24 lvl,
        uint256 rngWord
    ) external returns (uint256 effectiveWei);

    function processMapBatch(uint32 writesBudget) external returns (bool finished);
}

interface IDegenerusGameMintModule {
    function recordMintData(
        address player,
        uint24 lvl,
        uint32 mintUnits
    ) external payable returns (uint256 coinReward);

    function purchase(
        uint256 gamepieceQuantity,
        uint256 mapQuantity,
        uint256 lootBoxAmount,
        bytes32 affiliateCode,
        MintPaymentKind payKind
    ) external payable;

    function openLootBox(uint48 day) external;

    function queueFutureRewardMints(
        address player,
        uint24 targetLevel,
        uint32 quantity,
        uint256 poolWei
    ) external;

    function processFutureMintBatch(
        uint32 playersToProcess,
        uint24 lvl
    ) external returns (bool worked, bool finished);

    function payFutureTicketJackpot(uint24 lvl, uint256 randWord) external;

    function calculateAirdropMultiplier(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount,
        uint24 lvl
    ) external pure returns (uint32);

    function purchaseTargetCountFromRaw(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount
    ) external view returns (uint32);

    function rebuildTraitCounts(
        uint32 tokenBudget,
        uint32 target,
        uint256 baseTokenId
    ) external returns (bool finished);
}
