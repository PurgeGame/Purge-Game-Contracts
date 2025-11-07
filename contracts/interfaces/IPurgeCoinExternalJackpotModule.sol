// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeCoinExternalJackpotModule {
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    ) external returns (bool finished, address[] memory winners, uint256[] memory amounts, uint256 returnAmountWei);
}
