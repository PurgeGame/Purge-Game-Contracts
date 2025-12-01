// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockCoin {
    event BondPayment(uint256 amount);

    function bondPayment(uint256 amount) external {
        emit BondPayment(amount);
    }
}
