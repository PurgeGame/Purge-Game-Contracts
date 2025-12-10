// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockGameBondBank {
    uint24 public lvl;
    uint256 public available;

    function setLevel(uint24 l) external {
        lvl = l;
    }

    function setAvailable(uint256 a) external {
        available = a;
    }

    function level() external view returns (uint24) {
        return lvl;
    }

    function bondDeposit() external payable {}

    function bondYieldDeposit() external payable {}

    function bondCreditToClaimable(address, uint256) external {}

    function bondAvailable() external view returns (uint256) {
        return available;
    }

    receive() external payable {}
}
