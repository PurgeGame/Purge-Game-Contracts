// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockLink {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) return false;
        unchecked {
            balanceOf[msg.sender] = bal - amount;
        }
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 bal = balanceOf[from];
        if (bal < amount) return false;
        unchecked {
            balanceOf[from] = bal - amount;
        }
        balanceOf[to] += amount;
        return true;
    }
}
