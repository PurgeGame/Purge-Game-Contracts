// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockPurgeGameTrophies {
    address public sampleWinner;
    function setSampleWinner(address w) external { sampleWinner = w; }

    function wireAndPrime(address, address, uint24) external {}
    function burnDecPlaceholder(uint24) external {}
    function burnBafPlaceholder(uint24) external {}
    function awardTrophy(address, uint24, uint8, uint256, uint256) external payable {}
    function stakeTrophyBonus(address) external pure returns (uint8) { return 0; }
    function affiliateStakeBonus(address) external pure returns (uint8) { return 0; }
    function stakedTrophySample(uint256) external view returns (address) { return sampleWinner; }
}
