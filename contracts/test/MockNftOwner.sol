// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockNftOwner {
    address private immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function ownerOf(uint256) external view returns (address) {
        return owner;
    }
}
