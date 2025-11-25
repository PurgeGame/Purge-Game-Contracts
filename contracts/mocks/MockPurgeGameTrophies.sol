// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockPurgeGameTrophies {
    address public sampleWinner;
    function setSampleWinner(address w) external { sampleWinner = w; }

    function wireAndPrime(address, address, uint24) external {}
    function burnDecPlaceholder(uint24) external {}
    function burnBafPlaceholder(uint24) external {}
    function awardTrophy(address, uint24, uint8, uint256, uint256) external {}
    function stakeTrophyBonus(address) external pure returns (uint8) { return 0; }
    function affiliateStakeBonus(address) external pure returns (uint8) { return 0; }
    function stakedTrophySampleWithId(uint256) external view returns (uint256 tokenId) {
        return 0;
    }
    function trophyToken(uint24, uint8) external pure returns (uint256 tokenId, address owner) {
        return (0, address(0));
    }
    function trophyOwner(uint256) external view returns (address owner) { return sampleWinner; }
    function rewardTrophyByToken(uint256, uint256, uint24) external {}
}
