// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IIcons32 {
    function data(uint256 i) external view returns (string memory);
    function diamond() external view returns (string memory);
    function symbol(uint256 quadrant, uint8 idx) external view returns (string memory);
}

interface IColorRegistry {
    function setMyColors(
        address user,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external returns (bool);

    function setCustomColorsForMany(
        address user,
        uint256[] calldata tokenIds,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex,
        uint32 trophyOuterPct1e6
    ) external returns (bool);

    function setTopAffiliateColor(
        address user,
        uint256 tokenId,
        string calldata trophyHex
    ) external returns (bool);

    function tokenColor(uint256 tokenId, uint8 channel) external view returns (string memory);
    function addressColor(address user, uint8 channel) external view returns (string memory);
    function trophyOuter(uint256 tokenId) external view returns (uint32);
    function topAffiliateColor(uint256 tokenId) external view returns (string memory);
}

interface IERC721Lite {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPurgedRead {
    function affiliateProgram() external view returns (address);
}
