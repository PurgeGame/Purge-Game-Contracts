// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

interface IIcons32 {
    function vbW(uint256 i) external view returns (uint16);
    function vbH(uint256 i) external view returns (uint16);
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

    function tokenColor(
        uint256 tokenId,
        uint8 channel
    ) external view returns (string memory);
    function addressColor(
        address user,
        uint8 channel
    ) external view returns (string memory);
    function trophyOuter(uint256 tokenId) external view returns (uint32);
    function topAffiliateColor(uint256 tokenId) external view returns (string memory);
}

interface IERC721Lite {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPurgedRead {
    function getReferrer(address user) external view returns (address);
}

/**
 * @title IconRendererTrophy32
 * @notice Dedicated renderer for Purge Game trophy metadata and SVG generation.
 */
contract IconRendererTrophy32 {
    using Strings for uint256;

    uint256 private constant MAP_TROPHY_FLAG = uint256(1) << 200;
    uint256 private constant AFFILIATE_TROPHY_FLAG = uint256(1) << 201;
    uint256 private constant STAKE_TROPHY_FLAG = uint256(1) << 202;
    uint256 private constant BAF_TROPHY_FLAG = uint256(1) << 203;
    uint256 private constant DECIMATOR_TROPHY_FLAG = uint256(1) << 204;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    string private constant MAP_BADGE_PATH =
        "M14.3675 2.15671C14.7781 2.01987 15.2219 2.01987 15.6325 2.15671L20.6325 3.82338C21.4491 4.09561 22 4.85988 22 5.72074V19.6126C22 20.9777 20.6626 21.9416 19.3675 21.5099L15 20.0541L9.63246 21.8433C9.22192 21.9801 8.77808 21.9801 8.36754 21.8433L3.36754 20.1766C2.55086 19.9044 2 19.1401 2 18.2792V4.38741C2 3.0223 3.33739 2.05836 4.63246 2.49004L9 3.94589L14.3675 2.15671ZM15 4.05408L9.63246 5.84326C9.22192 5.9801 8.77808 5.9801 8.36754 5.84326L4 4.38741V18.2792L9 19.9459L14.3675 18.1567C14.7781 18.0199 15.2219 18.0199 15.6325 18.1567L20 19.6126V5.72074L15 4.05408ZM13.2929 8.29288C13.6834 7.90235 14.3166 7.90235 14.7071 8.29288L15.5 9.08577L16.2929 8.29288C16.6834 7.90235 17.3166 7.90235 17.7071 8.29288C18.0976 8.6834 18.0976 9.31657 17.7071 9.70709L16.9142 10.5L17.7071 11.2929C18.0976 11.6834 18.0976 12.3166 17.7071 12.7071C17.3166 13.0976 16.6834 13.0976 16.2929 12.7071L15.5 11.9142L14.7071 12.7071C14.3166 13.0976 13.6834 13.0976 13.2929 12.7071C12.9024 12.3166 12.9024 11.6834 13.2929 11.2929L14.0858 10.5L13.2929 9.70709C12.9024 9.31657 12.9024 8.6834 13.2929 8.29288ZM6 16C6.55228 16 7 15.5523 7 15C7 14.4477 6.55228 14 6 14C5.44772 14 5 14.4477 5 15C5 15.5523 5.44772 16 6 16ZM9 12C9 12.5523 8.55228 13 8 13C7.44772 13 7 12.5523 7 12C7 11.4477 7.44772 11 8 11C8.55228 11 9 11.4477 9 12ZM11 12C11.5523 12 12 11.5523 12 11C12 10.4477 11.5523 9.99998 11 9.99998C10.4477 9.99998 10 10.4477 10 11C10 11.5523 10.4477 12 11 12Z";
    string private constant AFFILIATE_BADGE_PATH =
        "M12 2A10 10 0 1 1 2 12 10 10 0 0 1 12 2Zm0 2.4a.8.8 0 0 0-.73.48l-1.38 3.07-3.33.47a.8.8 0 0 0-.44 1.37l2.4 2.33-.57 3.29a.8.8 0 0 0 1.16.84L12 14.9l2.89 1.43a.8.8 0 0 0 1.16-.84l-.57-3.29 2.4-2.33a.8.8 0 0 0-.44-1.37l-3.33-.47-1.38-3.07A.8.8 0 0 0 12 4.4Z";
    uint24[8] private BASE_COLOR = [
        0xf409cd,
        0x7c2bff,
        0x30d100,
        0xed0e11,
        0x1317f7,
        0xf7931a,
        0x5e5e5e,
        0xab8d3f
    ];

    int16[8] private BASE_VARIANT_BIAS = [
        int16(-14),
        int16(-6),
        int16(12),
        int16(-10),
        int16(14),
        int16(6),
        int16(-8),
        int16(10)
    ];
    uint32 private constant RATIO_MID_1e6 = 780_000;
    uint32 private constant RATIO_IN_1e6 = 620_000;

    IPurgedRead private immutable coin;
    IIcons32 private immutable icons;
    IColorRegistry private immutable registry;

    IERC721Lite private nft;

    error E();

    constructor(address coin_, address icons_, address registry_) {
        coin = IPurgedRead(coin_);
        icons = IIcons32(icons_);
        registry = IColorRegistry(registry_);
    }

    function setMyColors(
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external returns (bool) {
        return
            registry.setMyColors(
                msg.sender,
                outlineHex,
                flameHex,
                diamondHex,
                squareHex
            );
    }

    function setCustomColorsForMany(
        uint256[] calldata tokenIds,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex,
        uint32 trophyOuterPct1e6
    ) external returns (bool) {
        return
            registry.setCustomColorsForMany(
                msg.sender,
                tokenIds,
                outlineHex,
                flameHex,
                diamondHex,
                squareHex,
                trophyOuterPct1e6
            );
    }

    function setTopAffiliateColor(
        uint256 tokenId,
        string calldata trophyHex
    ) external returns (bool) {
        return registry.setTopAffiliateColor(msg.sender, tokenId, trophyHex);
    }

    function wireContracts(address game_, address nft_) external {
        if (msg.sender != address(coin)) revert E();
        game_;
        nft = IERC721Lite(nft_);
    }

    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata /*remaining*/
    ) external view returns (string memory) {
        if ((data >> 128) == 0) revert("renderer:notTrophy");

        uint24 lvl = uint24((data >> 128) & 0xFFFFFF);
        uint16 exTr = _readExterminatedTrait(data);
        bool isMap = (data & MAP_TROPHY_FLAG) != 0;
        bool isAffiliate = (data & AFFILIATE_TROPHY_FLAG) != 0;
        bool isStake = (data & STAKE_TROPHY_FLAG) != 0;
        bool isBaf = (data & BAF_TROPHY_FLAG) != 0;
        bool isDec = (data & DECIMATOR_TROPHY_FLAG) != 0;

        string memory lvlStr = (lvl == 0) ? "TBD" : uint256(lvl).toString();
        string memory trophyType;
        string memory trophyLabel;
        if (isMap) {
            trophyType = "Map";
            trophyLabel = "MAP Trophy";
        } else if (isAffiliate) {
            trophyType = "Top Affiliate's";
            trophyLabel = "Top Affiliate's Trophy";
        } else if (isStake) {
            trophyType = "Stake";
            trophyLabel = "Stake Trophy";
        } else if (isBaf) {
            trophyType = "BAF";
            trophyLabel = "BAF Trophy";
        } else if (isDec) {
            trophyType = "Decimator";
            trophyLabel = "Decimator Trophy";
        } else {
            trophyType = "Winner's";
            trophyLabel = "Winner's Trophy";
        }

        string memory desc;
        if (exTr == 0xFFFF) {
            if (lvl == 0) {
                desc = string.concat("Reserved Purge Game ", trophyLabel, ".");
            } else {
                desc = string.concat(
                    "Reserved for Level ",
                    lvlStr,
                    " ",
                    trophyLabel,
                    "."
                );
            }
        } else if (isAffiliate && exTr == 0xFFFE) {
            desc = string.concat(
                "Awarded for Level ",
                lvlStr,
                " Top Affiliate's champion."
            );
        } else if (isStake && exTr == 0xFFFD) {
            desc = string.concat(
                "Awarded for Level ",
                lvlStr,
                " largest stake maturation."
            );
        } else if (isBaf && exTr == BAF_TRAIT_SENTINEL) {
            desc = string.concat(
                "Awarded for Level ",
                lvlStr,
                " BAF finale."
            );
        } else if (isDec && exTr == DECIMATOR_TRAIT_SENTINEL) {
            desc = string.concat(
                "Awarded for Level ",
                lvlStr,
                " Decimator finale."
            );
        } else {
            desc = string.concat("Awarded for Level ", lvlStr);
            desc = string.concat(
                desc,
                isMap ? " MAP jackpot." : " extermination victory."
            );
        }

        bool includeTraitAttr;
        string memory traitType;
        string memory traitValue;
        if (exTr < 256 && (isMap || (!isMap && !isAffiliate && !isStake && !isBaf && !isDec))) {
            uint8 quadrant = uint8(exTr >> 6);
            uint8 raw = uint8(exTr & 0x3F);
            uint8 colorIdx = raw >> 3;
            uint8 symIdx = raw & 0x07;
            traitType = _quadrantTitle(quadrant);
            traitValue = _traitLabel(quadrant, colorIdx, symIdx);
            includeTraitAttr = true;
        }

        string memory attrs = string(
            abi.encodePacked(
                '[{"trait_type":"Level","value":"',
                lvlStr,
                '"},{"trait_type":"Trophy","value":"',
                trophyType,
                '"}'
            )
        );
        if (includeTraitAttr) {
            attrs = string(
                abi.encodePacked(
                    attrs,
                    ',{"trait_type":"',
                    traitType,
                    '","value":"',
                    traitValue,
                    '"}'
                )
            );
        }
        attrs = string(abi.encodePacked(attrs, "]"));

        string memory img = _trophySvg(tokenId, exTr, isMap, isAffiliate, isStake, isBaf, isDec, lvl);
        return _pack(tokenId, true, img, lvl, desc, trophyType, attrs);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _readExterminatedTrait(
        uint256 data
    ) private pure returns (uint16) {
        uint16 ex16 = uint16((data >> 152) & 0xFFFF);
        if (ex16 >= 0xFFFD) return ex16;
        return uint16(uint8(ex16));
    }

    function _resolve(
        uint256 tokenId,
        uint8 k,
        string memory defColor
    ) private view returns (string memory) {
        string memory s = registry.tokenColor(tokenId, k);
        if (bytes(s).length != 0) return s;

        address owner_ = nft.ownerOf(tokenId);
        s = registry.addressColor(owner_, k);
        if (bytes(s).length != 0) return s;

        address ref = coin.getReferrer(owner_);
        if (ref != address(0)) {
            s = registry.addressColor(ref, k);
            if (bytes(s).length != 0) return s;
            address up = coin.getReferrer(ref);
            if (up != address(0)) {
                s = registry.addressColor(up, k);
                if (bytes(s).length != 0) return s;
            }
        }
        return defColor;
    }

    function _trophySvg(
        uint256 tokenId,
        uint16 exterminatedTrait,
        bool isMap,
        bool isAffiliate,
        bool isStake,
        bool isBaf,
        bool isDec,
        uint24 lvl
    ) private view returns (string memory) {
        uint32 innerSide = _innerSquareSide();
        string memory diamondPath = icons.diamond();

        if (exterminatedTrait == 0xFFFF || isStake) {
            uint8 ringIdx;
            if (isMap) {
                ringIdx = 2;
            } else if (isAffiliate) {
                ringIdx = 4;
            } else if (isStake) {
                ringIdx = 5;
            } else if (isBaf) {
                ringIdx = 7;
            } else if (isDec) {
                ringIdx = 6;
            } else {
                ringIdx = 3;
            }
            string memory borderColor = _resolve(
                tokenId,
                0,
                _borderColor(tokenId, 0, _repeat4(ringIdx), lvl)
            );

            uint32 pct = registry.trophyOuter(tokenId);
            uint32 diameter = (pct <= 1)
                ? 88
                : uint32((uint256(innerSide) * pct) / 1_000_000);
            uint32 rOut = diameter / 2;
            uint32 rMid = uint32((uint256(rOut) * RATIO_MID_1e6) / 1_000_000);
            uint32 rIn = uint32((uint256(rOut) * RATIO_IN_1e6) / 1_000_000);

            string memory head = _svgHeader(
                borderColor,
                _resolve(tokenId, 3, "#d9d9d9")
            );
            string memory ringColor = _paletteColor(ringIdx, lvl);
            string memory placeholderFlameColor = _resolve(tokenId, 1, "#111");
            string memory rings = _rings(
                ringColor,
                placeholderFlameColor,
                _resolve(tokenId, 2, "#fff"),
                rOut,
                rMid,
                rIn,
                0,
                0
            );

            string memory clip = string(
                abi.encodePacked(
                    '<defs><clipPath id="ct"><circle cx="0" cy="0" r="',
                    uint256(rIn).toString(),
                    '"/></clipPath></defs>'
                )
            );

            string memory centerGlyph = _centerGlyph(
                isMap,
                isAffiliate,
                placeholderFlameColor,
                diamondPath
            );
            string memory cornerGlyph = _cornerGlyph(
                isMap,
                isAffiliate,
                placeholderFlameColor,
                diamondPath
            );

            return
                string(
                    abi.encodePacked(
                        head,
                        rings,
                        clip,
                        centerGlyph,
                        cornerGlyph,
                        _svgFooter()
                    )
                );
        }

        bool isTopAffiliate = isAffiliate && exterminatedTrait == 0xFFFE;
        bool isBafAward = isBaf && exterminatedTrait == BAF_TRAIT_SENTINEL;
        bool isDecAward = isDec && exterminatedTrait == DECIMATOR_TRAIT_SENTINEL;
        uint8 six = uint8(exterminatedTrait) & 0x3F;
        uint8 dataQ = uint8(exterminatedTrait) >> 6;
        if (isBafAward) {
            dataQ = 3;
            six = 0x38; // quadrant 3, color idx 7, symbol 0
        } else if (isDecAward) {
            dataQ = 3;
            six = 0x31; // quadrant 3, color idx 6, symbol 1
        }
        uint8 colIdx = isTopAffiliate ? 4 : (six >> 3);
        uint8 symIdx = isTopAffiliate ? 0 : (six & 0x07);

        string memory ringOuterColor;
        string memory symbolColor;
        {
            string memory defaultColor = _paletteColor(colIdx, lvl);
            if (isTopAffiliate) {
                string memory custom = registry.topAffiliateColor(tokenId);
                ringOuterColor = bytes(custom).length != 0
                    ? custom
                    : defaultColor;
                symbolColor = ringOuterColor;
            } else {
                ringOuterColor = defaultColor;
                symbolColor = defaultColor;
            }
        }

        string memory border = isTopAffiliate
            ? _resolve(tokenId, 0, ringOuterColor)
            : _resolve(
                tokenId,
                0,
                _borderColor(tokenId, uint32(six), _repeat4(colIdx), lvl)
            );

        string memory flameColor = _resolve(tokenId, 1, "#111");
        string memory squareFill = _resolve(tokenId, 3, "#d9d9d9");

        uint32 pct2 = registry.trophyOuter(tokenId);
        uint32 rOut2 = (pct2 <= 1)
            ? 38
            : uint32((uint256(innerSide) * pct2) / 2_000_000);
        uint32 rMid2 = uint32((uint256(rOut2) * RATIO_MID_1e6) / 1_000_000);
        uint32 rIn2 = uint32((uint256(rOut2) * RATIO_IN_1e6) / 1_000_000);

        uint256 iconIndex = isTopAffiliate
            ? 32
            : (uint256(dataQ) * 8 + uint256(symIdx));
        string memory iconPath = icons.data(iconIndex);
        uint16 w = icons.vbW(iconIndex);
        uint16 h = icons.vbH(iconIndex);
        uint16 m = w > h ? w : h;
        if (m == 0) m = 1;

        uint32 fitSym1e6;
        if (isTopAffiliate) {
            fitSym1e6 = 760_000;
        } else if (dataQ == 0 && (symIdx == 3 || symIdx == 7)) {
            fitSym1e6 = 1_030_000;
        } else if (dataQ == 1 && symIdx == 6) {
            fitSym1e6 = 600_000;
        } else {
            fitSym1e6 = 800_000;
        }
        uint32 sSym1e6 = uint32((uint256(2) * rIn2 * fitSym1e6) / m);

        int256 txm = -(int256(uint256(w)) * int256(uint256(sSym1e6))) / 2;
        int256 tyn = -(int256(uint256(h)) * int256(uint256(sSym1e6))) / 2;

        string memory ringsAndSymbol = string(
            abi.encodePacked(
                _rings(
                    ringOuterColor,
                    flameColor,
                    _resolve(tokenId, 2, "#fff"),
                    rOut2,
                    rMid2,
                    rIn2,
                    0,
                    0
                ),
                '<defs><clipPath id="ct2"><circle cx="0" cy="0" r="',
                uint256(rIn2).toString(),
                '"/></clipPath></defs>',
                '<g clip-path="url(#ct2)">',
                '<g transform="',
                _mat6(sSym1e6, txm, tyn),
                '">',
                '<g fill="',
                symbolColor,
                '" stroke="',
                symbolColor,
                '" style="vector-effect:non-scaling-stroke">',
                iconPath,
                "</g></g></g>"
            )
        );

        bool invertTrophy = !isMap && !isTopAffiliate && (exterminatedTrait <= 255 || lvl == 90);
        if (invertTrophy) {
            ringsAndSymbol = string(
                abi.encodePacked(
                    '<g filter="url(#inv)">',
                    ringsAndSymbol,
                    "</g>"
                )
            );
        }

        return
            string(
                abi.encodePacked(
                    _svgHeader(border, squareFill),
                    ringsAndSymbol,
                    _cornerGlyph(isMap, isAffiliate, flameColor, diamondPath),
                    _svgFooter()
                )
            );
    }

    function _svgHeader(
        string memory borderColor,
        string memory squareFill
    ) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-60 -60 120 120">',
                    '<defs><filter id="inv" color-interpolation-filters="sRGB">',
                    '<feColorMatrix type="matrix" values="',
                    "-1 0 0 0 1 ",
                    "0 -1 0 0 1 ",
                    "0 0 -1 0 1 ",
                    "0 0 0  1 0",
                    '"/></filter></defs>',
                    '<rect x="-50" y="-50" width="100" height="100" rx="12" fill="',
                    squareFill,
                    '" stroke="',
                    borderColor,
                    '" stroke-width="2"/>'
                )
            );
    }

    function _centerGlyph(
        bool isMap,
        bool isAffiliate,
        string memory flameFill,
        string memory flamePath
    ) private pure returns (string memory) {
        if (isMap) {
            return
                string(
                    abi.encodePacked(
                        '<g clip-path="url(#ct)">',
                        '<path fill="',
                        flameFill,
                        '" transform="matrix(1.9125 0 0 1.9125 -22.95 -22.95)" d="',
                        MAP_BADGE_PATH,
                        '"/>',
                        "</g>"
                    )
                );
        }

        if (isAffiliate) {
            return
                string(
                    abi.encodePacked(
                        '<g clip-path="url(#ct)">',
                        '<path fill="',
                        flameFill,
                        '" transform="matrix(1.85 0 0 1.85 -22.2 -22.2)" d="',
                        AFFILIATE_BADGE_PATH,
                        '"/>',
                        "</g>"
                    )
                );
        }

        return
            string(
                abi.encodePacked(
                    '<g clip-path="url(#ct)">',
                    '<path fill="',
                    flameFill,
                    '" transform="matrix(0.13 0 0 0.13 -56 -41)" d="',
                    flamePath,
                    '"/>',
                    "</g>"
                )
            );
    }

    function _cornerGlyph(
        bool isMap,
        bool isAffiliate,
        string memory flameFill,
        string memory flamePath
    ) private pure returns (string memory) {
        if (isMap) {
            return
                string(
                    abi.encodePacked(
                        '<g transform="translate(41.28 40.32)" opacity="0.95">',
                        '<path fill="',
                        flameFill,
                        '" transform="matrix(0.442 0 0 0.442 -5.304 -5.304)" d="',
                        MAP_BADGE_PATH,
                        '"/>',
                        "</g>"
                    )
                );
        }

        if (isAffiliate) {
            return
                string(
                    abi.encodePacked(
                        '<g transform="translate(41 35)" opacity="0.95">',
                        '<path fill="',
                        flameFill,
                        '" transform="matrix(0.09 0 0 0.09 -21.6 -21.6)" d="',
                        AFFILIATE_BADGE_PATH,
                        '"/>',
                        "</g>"
                    )
                );
        }

        return
            string(
                abi.encodePacked(
                    '<g transform="translate(43 42)" opacity="0.95">',
                    '<path fill="',
                    flameFill,
                    '" transform="matrix(0.021 0 0 0.021 -10.8 -8.10945)" d="',
                    flamePath,
                    '"/>',
                    "</g>"
                )
            );
    }

    function _svgFooter() private pure returns (string memory) {
        return "</svg>";
    }

    function _rings(
        string memory outer,
        string memory mid,
        string memory inner,
        uint32 rOut,
        uint32 rMid,
        uint32 rIn,
        int16 cx,
        int16 cy
    ) private pure returns (string memory) {
        string memory cxs = _i(cx);
        string memory cys = _i(cy);
        return
            string(
                abi.encodePacked(
                    '<circle cx="',
                    cxs,
                    '" cy="',
                    cys,
                    '" r="',
                    uint256(rOut).toString(),
                    '" fill="',
                    outer,
                    '"/>',
                    '<circle cx="',
                    cxs,
                    '" cy="',
                    cys,
                    '" r="',
                    uint256(rMid).toString(),
                    '" fill="',
                    mid,
                    '"/>',
                    '<circle cx="',
                    cxs,
                    '" cy="',
                    cys,
                    '" r="',
                    uint256(rIn).toString(),
                    '" fill="',
                    inner,
                    '"/>'
                )
            );
    }

    function _borderColor(
        uint256 tokenId,
        uint32 traits,
        uint8[4] memory used,
        uint24 level
    ) private view returns (string memory) {
        uint8 initial = uint8(
            uint256(keccak256(abi.encodePacked(tokenId, traits))) % 8
        );

        for (uint8 i; i < 8; ) {
            uint8 idx = uint8(initial + i) & 7;
            bool isUsed;
            for (uint8 j; j < 4; ) {
                if (used[j] == idx) {
                    isUsed = true;
                    break;
                }
                unchecked {
                    ++j;
                }
            }
            if (!isUsed) return _paletteColor(idx, level);
            unchecked {
                ++i;
            }
        }
        return _paletteColor(0, level);
    }

    function _paletteColor(uint8 idx, uint24 level) private view returns (string memory) {
        uint24 rgb = _paletteColorRGB(idx, level);
        return _rgbToHex(rgb);
    }

    function _paletteColorRGB(uint8 idx, uint24 level) private view returns (uint24) {
        uint24 cycle = level % 10;
        uint24 base = BASE_COLOR[idx];
        uint8 r = uint8(base >> 16);
        uint8 g = uint8(base >> 8);
        uint8 b = uint8(base);

        int16 bias = BASE_VARIANT_BIAS[idx];
        uint256 seed = uint256(keccak256(abi.encodePacked(cycle, idx)));
        int16 jitter = int16(int8(uint8(seed & 0x1F))) - 16;
        int16 delta = bias + jitter;
        if (delta > 24) delta = 24;
        if (delta < -24) delta = -24;

        uint8 r2 = _toneChannel(r, delta);
        uint8 g2 = _toneChannel(g, delta);
        uint8 b2 = _toneChannel(b, delta);
        return (uint24(r2) << 16) | (uint24(g2) << 8) | uint24(b2);
    }

    function _toneChannel(uint8 value, int16 delta) private pure returns (uint8) {
        if (delta == 0) return value;
        if (delta > 0) {
        uint16 span = 255 - value;
        return value + uint8((span * uint16(uint16(delta))) / 32);
    }
    uint16 spanDown = value;
    return value - uint8((spanDown * uint16(uint16(-delta))) / 32);
}

    function _rgbToHex(uint24 rgb) private pure returns (string memory) {
        uint8 r = uint8(rgb >> 16);
        uint8 g = uint8(rgb >> 8);
        uint8 b = uint8(rgb);
        bytes memory buf = new bytes(7);
        buf[0] = '#';
        buf[1] = _hexChar(r >> 4);
        buf[2] = _hexChar(r & 0x0F);
        buf[3] = _hexChar(g >> 4);
        buf[4] = _hexChar(g & 0x0F);
        buf[5] = _hexChar(b >> 4);
        buf[6] = _hexChar(b & 0x0F);
        return string(buf);
    }

    function _hexChar(uint8 nibble) private pure returns (bytes1) {
        uint8 v = nibble & 0x0F;
        return bytes1(v + (v < 10 ? 48 : 87));
    }

    function _repeat4(uint8 v) private pure returns (uint8[4] memory a) {
        a[0] = v;
        a[1] = v;
        a[2] = v;
        a[3] = v;
    }

    function _colorTitle(uint8 idx) private pure returns (string memory) {
        if (idx == 0) return "Pink";
        if (idx == 1) return "Purple";
        if (idx == 2) return "Green";
        if (idx == 3) return "Red";
        if (idx == 4) return "Blue";
        if (idx == 5) return "Orange";
        if (idx == 6) return "Silver";
        return "Gold";
    }

    function _quadrantTitle(uint8 idx) private pure returns (string memory) {
        if (idx == 0) return "Crypto";
        if (idx == 1) return "Zodiac";
        if (idx == 2) return "Gambling";
        return "Dice";
    }

    function _symbolTitle(uint8 quadrant, uint8 symbolIdx) private view returns (string memory) {
        if (quadrant < 3) {
            string memory externalName = icons.symbol(quadrant, symbolIdx);
            if (bytes(externalName).length != 0) {
                return externalName;
            }
            return string.concat("Symbol ", (uint256(symbolIdx) + 1).toString());
        }

        return string.concat("Dice ", (uint256(symbolIdx) + 1).toString());
    }

    function _traitLabel(uint8 quadrant, uint8 colorIdx, uint8 symbolIdx) private view returns (string memory) {
        return string.concat(_colorTitle(colorIdx), " ", _symbolTitle(quadrant, symbolIdx));
    }

    function _pack(
        uint256 tokenId,
        bool isTrophy,
        string memory svg,
        uint256 level,
        string memory desc,
        string memory trophyType,
        string memory attrs
    ) private pure returns (string memory) {
        string memory lvlStr = (level == 0) ? "TBD" : level.toString();
        string memory nm = isTrophy
            ? string.concat(
                "Purge Game Level ",
                lvlStr,
                " ",
                trophyType,
                " Trophy"
            )
            : string.concat(
                "Purge Game Level ",
                lvlStr,
                " #",
                tokenId.toString()
            );

        string memory imgData = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );

        string memory j = string.concat('{"name":"', nm);
        j = string.concat(j, '","description":"', desc);
        j = string.concat(j, '","image":"', imgData, '","attributes":');
        if (isTrophy) {
            j = string.concat(j, attrs, "}");
        } else {
            j = string.concat(j, "[]}");
        }

        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(bytes(j))
            );
    }

    function _innerSquareSide() private pure returns (uint32) {
        return 98;
    }

    function _mat6(
        uint32 s1e6,
        int256 tx1e6,
        int256 ty1e6
    ) private pure returns (string memory) {
        string memory s = _dec6(uint256(s1e6));
        string memory txn = _dec6s(tx1e6);
        string memory tyn = _dec6s(ty1e6);
        return
            string(
                abi.encodePacked(
                    "matrix(",
                    s,
                    " 0 0 ",
                    s,
                    " ",
                    txn,
                    " ",
                    tyn,
                    ")"
                )
            );
    }

    function _dec6(uint256 x) private pure returns (string memory) {
        uint256 i = x / 1_000_000;
        uint256 f = x % 1_000_000;
        return string(abi.encodePacked(i.toString(), ".", _pad6(uint32(f))));
    }

    function _dec6s(int256 x) private pure returns (string memory) {
        if (x < 0) {
            uint256 y = uint256(-x);
            return string(abi.encodePacked("-", _dec6(y)));
        }
        return _dec6(uint256(x));
    }

    function _pad6(uint32 f) private pure returns (string memory) {
        bytes memory b = new bytes(6);
        for (uint256 k; k < 6; ++k) {
            b[5 - k] = bytes1(uint8(48 + (f % 10)));
            f /= 10;
        }
        return string(b);
    }

    function _i(int16 v) private pure returns (string memory) {
        int256 x = v;
        if (x >= 0) return uint256(x).toString();
        return string.concat("-", uint256(-x).toString());
    }
}
