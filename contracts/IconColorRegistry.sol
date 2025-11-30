// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC721Lite} from "./interfaces/IconRendererTypes.sol";

contract IconColorRegistry {
    error NotOwner();
    error RendererSet();
    error NotRenderer();
    error InvalidTrophyOuterPercentage();
    error InvalidHexColor();

    struct Colors {
        string outline;
        string flame;
        string diamond;
        string square;
    }

    address private immutable _owner;
    IERC721Lite private immutable _nft;
    address private _renderer;

    mapping(address => Colors) private _addr;
    mapping(uint256 => Colors) private _custom;
    mapping(uint256 => string) private _topAffiliate;
    mapping(uint256 => uint32) private _trophyOuterPct1e6;

    constructor(address nft_) {
        _owner = msg.sender;
        _nft = IERC721Lite(nft_);
    }

    function setRenderer(address renderer_) external {
        if (msg.sender != _owner) revert NotOwner();
        if (_renderer != address(0)) revert RendererSet();
        _renderer = renderer_;
    }

    modifier onlyRenderer() {
        if (msg.sender != _renderer) revert NotRenderer();
        _;
    }

    function setMyColors(
        address user,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external onlyRenderer returns (bool) {
        Colors storage pref = _addr[user];

        if (bytes(outlineHex).length == 0) delete pref.outline;
        else pref.outline = _requireHex7(outlineHex);

        if (bytes(flameHex).length == 0) delete pref.flame;
        else pref.flame = _requireHex7(flameHex);

        if (bytes(diamondHex).length == 0) delete pref.diamond;
        else pref.diamond = _requireHex7(diamondHex);

        if (bytes(squareHex).length == 0) delete pref.square;
        else pref.square = _requireHex7(squareHex);

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
    ) external onlyRenderer returns (bool) {
        bool clearOutline = (bytes(outlineHex).length == 0);
        bool clearFlame = (bytes(flameHex).length == 0);
        bool clearDiamond = (bytes(diamondHex).length == 0);
        bool clearSquare = (bytes(squareHex).length == 0);

        string memory outlineVal = clearOutline ? "" : _requireHex7(outlineHex);
        string memory flameVal = clearFlame ? "" : _requireHex7(flameHex);
        string memory diamondVal = clearDiamond ? "" : _requireHex7(diamondHex);
        string memory squareVal = clearSquare ? "" : _requireHex7(squareHex);

        if (
            trophyOuterPct1e6 != 0 &&
            trophyOuterPct1e6 != 1 &&
            (trophyOuterPct1e6 < 50_000 || trophyOuterPct1e6 > 1_000_000)
        ) revert InvalidTrophyOuterPercentage(); // reuse error for slight savings

        IERC721Lite nftRef = _nft;
        uint256 count = tokenIds.length;
        for (uint256 i; i < count; ) {
            uint256 tokenId = tokenIds[i];
            if (nftRef.ownerOf(tokenId) != user) revert NotRenderer();

            Colors storage c = _custom[tokenId];
            if (clearOutline) delete c.outline;
            else c.outline = outlineVal;
            if (clearFlame) delete c.flame;
            else c.flame = flameVal;
            if (clearDiamond) delete c.diamond;
            else c.diamond = diamondVal;
            if (clearSquare) delete c.square;
            else c.square = squareVal;

            if (trophyOuterPct1e6 == 0) {
                // no change
            } else if (trophyOuterPct1e6 == 1) {
                delete _trophyOuterPct1e6[tokenId];
            } else {
                _trophyOuterPct1e6[tokenId] = trophyOuterPct1e6;
            }

            unchecked {
                ++i;
            }
        }
        return true;
    }

    function setTopAffiliateColor(
        address user,
        uint256 tokenId,
        string calldata trophyHex
    ) external onlyRenderer returns (bool) {
        if (_nft.ownerOf(tokenId) != user) revert NotRenderer();

        if (bytes(trophyHex).length == 0) {
            delete _topAffiliate[tokenId];
            return true;
        }

        _topAffiliate[tokenId] = _requireHex7(trophyHex);
        return true;
    }

    function tokenColor(uint256 tokenId, uint8 channel) external view returns (string memory) {
        Colors storage c = _custom[tokenId];
        if (channel == 0) return c.outline;
        if (channel == 1) return c.flame;
        if (channel == 2) return c.diamond;
        return c.square;
    }

    function addressColor(address user, uint8 channel) external view returns (string memory) {
        Colors storage c = _addr[user];
        if (channel == 0) return c.outline;
        if (channel == 1) return c.flame;
        if (channel == 2) return c.diamond;
        return c.square;
    }

    function topAffiliateColor(uint256 tokenId) external view returns (string memory) {
        return _topAffiliate[tokenId];
    }

    function trophyOuter(uint256 tokenId) external view returns (uint32) {
        return _trophyOuterPct1e6[tokenId];
    }

    function _requireHex7(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length != 7 || b[0] != bytes1("#")) revert InvalidHexColor();
        uint8 ch = uint8(b[1]);
        if ((ch < 48 || ch > 57) && (ch < 97 || ch > 102)) revert InvalidHexColor();
        ch = uint8(b[2]);
        if ((ch < 48 || ch > 57) && (ch < 97 || ch > 102)) revert InvalidHexColor();
        ch = uint8(b[3]);
        if ((ch < 48 || ch > 57) && (ch < 97 || ch > 102)) revert InvalidHexColor();
        ch = uint8(b[4]);
        if ((ch < 48 || ch > 57) && (ch < 97 || ch > 102)) revert InvalidHexColor();
        ch = uint8(b[5]);
        if ((ch < 48 || ch > 57) && (ch < 97 || ch > 102)) revert InvalidHexColor();
        ch = uint8(b[6]);
        if ((ch < 48 || ch > 57) && (ch < 97 || ch > 102)) revert InvalidHexColor();
        return s;
    }
}
