// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockVault {
    address private immutable stethAddr;

    constructor(address steth_) {
        stethAddr = steth_;
    }

    function deposit(uint256, uint256) external payable {}

    function swapWithBonds(bool, uint256) external payable {}

    function steth() external view returns (address) {
        return stethAddr;
    }

    receive() external payable {}
}

