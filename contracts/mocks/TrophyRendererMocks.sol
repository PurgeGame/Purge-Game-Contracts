// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IPurgeRenderer.sol";

contract MockRegistry {
    mapping(address => mapping(uint8 => string)) private _addressColors;
    mapping(uint256 => mapping(uint8 => string)) private _tokenColors;
    mapping(uint256 => string) private _topAffiliateColor;

    function setMyColors(
        address user,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external returns (bool) {
        _addressColors[user][0] = outlineHex;
        _addressColors[user][1] = flameHex;
        _addressColors[user][2] = diamondHex;
        _addressColors[user][3] = squareHex;
        return true;
    }

    function setCustomColorsForMany(
        address user,
        uint256[] calldata tokenIds,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex,
        uint32 trophyOuterPct1e6
    ) external returns (bool) {
        trophyOuterPct1e6; // unused
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            _tokenColors[tokenId][0] = outlineHex;
            _tokenColors[tokenId][1] = flameHex;
            _tokenColors[tokenId][2] = diamondHex;
            _tokenColors[tokenId][3] = squareHex;
        }
        user; // silence warnings
        return true;
    }

    function setTopAffiliateColor(address user, uint256 tokenId, string calldata trophyHex) external returns (bool) {
        _topAffiliateColor[tokenId] = trophyHex;
        user; // unused
        return true;
    }

    function tokenColor(uint256 tokenId, uint8 channel) external view returns (string memory) {
        return _tokenColors[tokenId][channel];
    }

    function addressColor(address user, uint8 channel) external view returns (string memory) {
        return _addressColors[user][channel];
    }

    function trophyOuter(uint256 tokenId) external pure returns (uint32) {
        tokenId; // unused
        return 0;
    }

    function topAffiliateColor(uint256 tokenId) external view returns (string memory) {
        return _topAffiliateColor[tokenId];
    }
}

contract MockNFT {
    mapping(uint256 => address) private _owners;

    function setOwner(uint256 tokenId, address owner) external {
        _owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}

contract MockCoin {
    mapping(address => address) private _referrers;

    function setReferrer(address user, address ref) external {
        _referrers[user] = ref;
    }

    function getReferrer(address user) external view returns (address) {
        return _referrers[user];
    }

    function callWire(address renderer, address game, address nft) external {
        IPurgeRenderer(renderer).wireContracts(game, nft);
    }
}
