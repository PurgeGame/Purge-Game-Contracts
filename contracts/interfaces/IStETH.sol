// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal Lido stETH interface shared across contracts.
interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
