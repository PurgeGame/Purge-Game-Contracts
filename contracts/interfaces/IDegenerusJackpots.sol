// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDegenerusJackpots {
    function runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        returns (address[] memory winners, uint256[] memory amounts, uint256 winnerMask, uint256 returnAmountWei);

    function runDecimatorJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    ) external returns (uint256 returnAmountWei);

    function recordBafFlip(address player, uint24 lvl, uint256 amount) external;
    function recordDecBurn(
        address player,
        uint24 lvl,
        uint8 bucket,
        uint256 baseAmount,
        uint256 multBps
    ) external returns (uint8 bucketUsed);
}
