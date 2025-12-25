// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockGameStartTraits {
    uint32 private immutable startRemaining;

    constructor(uint32 startRemaining_) {
        startRemaining = startRemaining_;
    }

    function startTraitRemaining(uint8) external view returns (uint32) {
        return startRemaining;
    }
}
