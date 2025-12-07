// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDegenerusAffiliate {
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external returns (uint256);
    function createSyntheticMapPlayer(address synthetic, bytes32 code) external;

    function getTopAffiliate(uint24 lvl) external view returns (address);

    function affiliateTop(uint24 lvl) external view returns (address player, uint96 score);

    function getReferrer(address player) external view returns (address);
    function syntheticMapInfo(address synthetic) external view returns (address owner, bytes32 code);

    function claimAffiliateBong(uint24 lvl, uint8 tierIdx) external;

    function claimableAffiliateBongTiers(
        address player,
        uint24 lvl
    ) external view returns (uint16 claimable, uint256 claimedMask);

    function affiliateBongRewardsLength() external view returns (uint256);

    function affiliateBongReward(
        uint256 idx
    ) external view returns (uint96 scoreRequired, uint96 baseWeiPerBong, uint8 bongs, bool stake);

    function affiliateBongClaimed(uint24 lvl, address player) external view returns (uint256);
}
