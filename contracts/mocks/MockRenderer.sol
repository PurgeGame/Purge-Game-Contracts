// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockRenderer {
    function tokenURI(uint256, uint256, uint32[4] calldata) external pure returns (string memory) {
        return "data:application/json;base64,eyJuYW1lIjoiTW9jayJ9";
    }
}
