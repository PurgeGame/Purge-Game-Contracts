// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IERC721Lite {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPurgedRead {
    function affiliateProgram() external view returns (address);
}

interface IIconRendererWire {
    function wireContracts(address game_, address nft_) external;
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

    function setTopAffiliateColor(address user, uint256 tokenId, string calldata trophyHex) external returns (bool);

    function tokenColor(uint256 tokenId, uint8 channel) external view returns (string memory);
    function addressColor(address user, uint8 channel) external view returns (string memory);
    function trophyOuter(uint256 tokenId) external view returns (uint32);
    function topAffiliateColor(uint256 tokenId) external view returns (string memory);
}

contract MockRegistry is IColorRegistry {
    struct Colors {
        string outline;
        string flame;
        string diamond;
        string square;
    }

    mapping(address => Colors) private addressColors;
    mapping(uint256 => Colors) private tokenColors;
    mapping(uint256 => string) private affiliateHex;
    mapping(uint256 => uint32) private trophyOuterPct;

    function setMyColors(
        address user,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external override returns (bool) {
        addressColors[user] = Colors(outlineHex, flameHex, diamondHex, squareHex);
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
    ) external override returns (bool) {
        Colors memory colors = Colors(outlineHex, flameHex, diamondHex, squareHex);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenColors[tokenIds[i]] = colors;
            trophyOuterPct[tokenIds[i]] = trophyOuterPct1e6;
        }
        user;
        return true;
    }

    function setTopAffiliateColor(address, uint256 tokenId, string calldata trophyHex) external override returns (bool) {
        affiliateHex[tokenId] = trophyHex;
        return true;
    }

    function tokenColor(uint256 tokenId, uint8 channel) external view override returns (string memory) {
        return _colorForChannel(tokenColors[tokenId], channel);
    }

    function addressColor(address user, uint8 channel) external view override returns (string memory) {
        return _colorForChannel(addressColors[user], channel);
    }

    function trophyOuter(uint256 tokenId) external view override returns (uint32) {
        uint32 pct = trophyOuterPct[tokenId];
        return pct == 0 ? 1 : pct;
    }

    function topAffiliateColor(uint256 tokenId) external view override returns (string memory) {
        return affiliateHex[tokenId];
    }

    function _colorForChannel(Colors storage colors, uint8 channel) private view returns (string memory) {
        if (channel == 0) return colors.outline;
        if (channel == 1) return colors.flame;
        if (channel == 2) return colors.diamond;
        if (channel == 3) return colors.square;
        return "";
    }
}

contract MockNFT is IERC721Lite {
    mapping(uint256 => address) private _owners;

    function ownerOf(uint256 tokenId) external view override returns (address) {
        address owner_ = _owners[tokenId];
        require(owner_ != address(0), "mockNFT:notMinted");
        return owner_;
    }

    function setOwner(uint256 tokenId, address owner_) external {
        _owners[tokenId] = owner_;
    }
}

contract MockCoin is IPurgedRead {
    address private _affiliate;

    function setAffiliate(address affiliate) external {
        _affiliate = affiliate;
    }

    function affiliateProgram() external view override returns (address) {
        return _affiliate;
    }

    function callWire(address renderer, address game_, address nft_) external {
        IIconRendererWire(renderer).wireContracts(game_, nft_);
    }
}
