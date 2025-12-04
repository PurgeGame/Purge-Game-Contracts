// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockGame {
    uint256 public mintPriceWei = 0.025 ether;
    uint256 public coinPriceUnit = 1e9;
    uint256 private rngWord;

    function setPricing(uint256 mintPrice_, uint256 coinUnit_) external {
        mintPriceWei = mintPrice_;
        coinPriceUnit = coinUnit_;
    }

    function setRngWord(uint256 word) external {
        rngWord = word;
    }

    function rngWordForDay(uint48) external view returns (uint256) {
        return rngWord;
    }

    function bongRewardDeposit() external payable {}

    function bongYieldDeposit() external payable {}

    function creditBongWinnings(address) external payable {}
}
