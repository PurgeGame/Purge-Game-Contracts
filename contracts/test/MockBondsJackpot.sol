// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal mock used by endgame module tests.
contract MockBondsJackpot {
    function purchasesEnabled() external pure returns (bool) {
        return false;
    }

    function depositCurrentFor(address) external payable returns (uint256) {
        return 0;
    }

    function depositFromGame(address, uint256) external payable returns (uint256) {
        return 0;
    }
}

