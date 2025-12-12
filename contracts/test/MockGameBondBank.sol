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

    function ethMintStreakCount(address) external pure returns (uint24) {
        return 0;
    }

    function bondDeposit(bool) external payable {}

    function bondCreditToClaimable(address, uint256) external {}

    function bondCreditToClaimableBatch(address[] calldata, uint256[] calldata) external {}

    function bondAvailable() external view returns (uint256) {
        return available;
    }

    receive() external payable {}
}
