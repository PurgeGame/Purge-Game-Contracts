// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockCoin {
    event BongPayment(uint256 amount);

    function bongPayment(uint256 amount) external {
        emit BongPayment(amount);
    }
}
