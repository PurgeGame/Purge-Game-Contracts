// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockStETH {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        uint256 bal = balanceOf[from];
        require(amount <= bal, "bal");
        balanceOf[from] = bal - amount;
        balanceOf[to] += amount;
    }
}
