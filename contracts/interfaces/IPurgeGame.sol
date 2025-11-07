// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeGame {
    function getTraitRemainingQuad(
        uint8[4] calldata traitIds
    ) external view returns (uint16 lastExterminated, uint24 currentLevel, uint32[4] memory remaining);

    function level() external view returns (uint24);

    function gameState() external view returns (uint8);

    function currentPhase() external view returns (uint8);

    function mintPrice() external view returns (uint256);

    function coinPriceUnit() external view returns (uint256);

    function getEarlyPurgePercent() external view returns (uint8);

    function coinMintUnlock(uint24 lvl) external view returns (bool);

    function ethMintLastDay(address player) external view returns (uint48);

    function ethMintDayStreak(address player) external view returns (uint24);

    function coinMintLastDay(address player) external view returns (uint48);

    function coinMintDayStreak(address player) external view returns (uint24);

    function mintLastDay(address player) external view returns (uint48);

    function mintDayStreak(address player) external view returns (uint24);

    function ethMintLevelCount(address player) external view returns (uint24);

    function ethMintStreakCount(address player) external view returns (uint24);

    function ethMintLastLevel(address player) external view returns (uint24);

    function playerMintData(
        address player
    )
        external
        view
        returns (
            uint24 ethLastLevel,
            uint24 ethLevelCount,
            uint24 ethLevelStreak,
            uint48 ethLastDay,
            uint24 ethDayStreak,
            uint48 coinLastDay,
            uint24 coinDayStreak,
            uint48 overallLastDay,
            uint24 overallDayStreak
        );

    function enqueueMap(address buyer, uint32 quantity) external;

    function recordMint(
        address player,
        uint24 lvl,
        bool creditNext,
        bool coinMint
    ) external payable returns (uint256 coinReward);

    function getJackpotWinners(
        uint256 randomWord,
        uint8 trait,
        uint8 numWinners,
        uint8 salt
    ) external view returns (address[] memory);

    function purchaseMultiplier() external view returns (uint32);

    function rngLocked() external view returns (bool);

    function currentRngWord() external view returns (uint256);

    function isRngFulfilled() external view returns (bool);

    function releaseRngLock() external;
}
