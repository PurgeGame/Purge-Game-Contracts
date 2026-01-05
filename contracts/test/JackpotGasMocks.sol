// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "../interfaces/DegenerusGameModuleInterfaces.sol";

contract MockCoinModule is IDegenerusCoinModule {
    function creditFlip(address, uint256) external override {}
    function rollDailyQuest(uint48, uint256) external override {}
    function rollDailyQuestWithOverrides(uint48, uint256, bool, bool) external override {}
}

contract MockBondsJackpot {
    function purchasesEnabled() external pure returns (bool) {
        return false;
    }

    function depositCurrentFor(address, uint256) external payable returns (uint256) {
        return 0;
    }

    function depositFromGame(address, uint256) external returns (uint256) {
        return 0;
    }

    function mintJackpotDgnrs(address, uint256, uint24) external {}
}

contract MockBondsJackpotEnabled {
    uint256 public totalDeposits;
    mapping(address => uint256) public deposits;

    function purchasesEnabled() external pure returns (bool) {
        return true;
    }

    function depositCurrentFor(address, uint256) external payable returns (uint256) {
        return 0;
    }

    function depositFromGame(address beneficiary, uint256 amount) external returns (uint256) {
        deposits[beneficiary] += amount;
        totalDeposits += amount;
        return 0;
    }

    function mintJackpotDgnrs(address, uint256, uint24) external {}
}
