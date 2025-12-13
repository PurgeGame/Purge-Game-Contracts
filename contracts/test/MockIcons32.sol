// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal icon set for renderer tests.
contract MockIcons32 {
    function data(uint256) external pure returns (string memory) {
        return "<path d='M256 0h256v256H256z'/>";
    }

    function diamond() external pure returns (string memory) {
        return "M256 0L512 256 256 512 0 256Z";
    }

    function symbol(uint256, uint8) external pure returns (string memory) {
        return "";
    }
}

