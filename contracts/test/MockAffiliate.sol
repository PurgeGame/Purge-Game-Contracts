// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal mock for synthetic payout routing tests.
contract MockAffiliate {
    mapping(address => address) public syntheticMapOwner;
    mapping(address => bytes32) public syntheticMapCode;

    function setSynthetic(address synthetic, address owner, bytes32 code) external {
        syntheticMapOwner[synthetic] = owner;
        syntheticMapCode[synthetic] = code;
    }

    function syntheticMapInfo(address synthetic) external view returns (address owner, bytes32 code) {
        owner = syntheticMapOwner[synthetic];
        code = syntheticMapCode[synthetic];
    }
}

