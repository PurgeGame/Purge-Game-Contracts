// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDegenerusAffiliate {
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl,
        uint8 gameState,
        bool rngLocked
    ) external returns (uint256);

    function affiliateTop(uint24 lvl) external view returns (address player, uint96 score);
    function presaleActive() external view returns (bool);

    function getReferrer(address player) external view returns (address);
}
