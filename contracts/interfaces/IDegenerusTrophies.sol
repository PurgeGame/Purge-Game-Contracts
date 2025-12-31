// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDegenerusTrophies {
    function mintExterminator(
        address to,
        uint24 level,
        uint8 trait,
        bool invertFlag,
        uint96 exterminationWinnings
    ) external returns (uint256);
    function mintBaf(address to, uint24 level) external returns (uint256);
    function mintAffiliate(address to, uint24 level, uint96 score) external returns (uint256);
}
