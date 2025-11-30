// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal stETH stand-in for local testing.
contract MockStETH {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    function submit(address) external payable returns (uint256 minted) {
        minted = msg.value;
        _balances[msg.sender] += minted;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (_balances[msg.sender] < amount) revert();
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }
}
