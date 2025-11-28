// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeAffiliate {
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external returns (uint256);

    function resetAffiliateLeaderboard(uint24 lvl) external;

    function getTopAffiliate() external view returns (address);

    function affiliateTop(uint24 lvl) external view returns (address player, uint96 score);

    function getReferrer(address player) external view returns (address);
}
