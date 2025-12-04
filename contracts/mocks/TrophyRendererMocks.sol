// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721Lite, IColorRegistry, IPurgedRead} from "../interfaces/IconRendererTypes.sol";

/// @dev Minimal mock NFT for renderer tests.
contract MockNFT is IERC721Lite {
    mapping(uint256 => address) private _owner;

    function setOwner(uint256 tokenId, address owner) external {
        _owner[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view override returns (address) {
        return _owner[tokenId];
    }
}

/// @dev Minimal mock coin that only exposes affiliateProgram (unset by default).
contract MockCoin is IPurgedRead {
    address private _affiliate;

    function setRendererNft(address renderer, address nft) external {
        ISetNft(renderer).setNft(nft);
    }

    function setAffiliate(address affiliate) external {
        _affiliate = affiliate;
    }

    function affiliateProgram() external view override returns (address) {
        return _affiliate;
    }
}

interface ISetNft {
    function setNft(address nft_) external;
}

/// @dev Registry stub that accepts calls but returns defaults.
contract MockRegistry is IColorRegistry {
    function setMyColors(
        address,
        string calldata,
        string calldata,
        string calldata,
        string calldata
    ) external pure override returns (bool) {
        return true;
    }

    function setCustomColorsForMany(
        address,
        address,
        uint256[] calldata,
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        uint32
    ) external pure override returns (bool) {
        return true;
    }

    function setTopAffiliateColor(address, address, uint256, string calldata) external pure override returns (bool) {
        return true;
    }

    function addAllowedToken(address) external pure override {}

    function tokenColor(address, uint256, uint8 channel) external pure override returns (string memory) {
        if (channel == 1) return "#ff6633";
        if (channel == 2) return "#ffffff";
        return "";
    }

    function addressColor(address, uint8 channel) external pure override returns (string memory) {
        if (channel == 1) return "#ff6633";
        if (channel == 2) return "#ffffff";
        return "";
    }

    function trophyOuter(address, uint256) external pure override returns (uint32) {
        return 0;
    }

    function topAffiliateColor(address, uint256) external pure override returns (string memory) {
        return "";
    }
}
