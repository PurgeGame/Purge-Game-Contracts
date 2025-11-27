// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {ITrophySvgAssets} from "./TrophySvgAssets.sol";

interface IIcons32 {
    function vbW(uint256 i) external view returns (uint16);
    function vbH(uint256 i) external view returns (uint16);
    function data(uint256 i) external view returns (string memory);
    function diamond() external view returns (string memory);
    function symbol(
        uint256 quadrant,
        uint8 idx
    ) external view returns (string memory);
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
    function topAffiliateColor(
        uint256 tokenId
    ) external view returns (string memory);
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
    uint256 private constant TROPHY_FLAG_INVERT = uint256(1) << 229;
    uint256 private constant TROPHY_STAKE_LEVEL_SHIFT = 205;
    uint256 private constant TROPHY_STAKE_LEVEL_MASK =
        uint256(0xFFFFFF) << TROPHY_STAKE_LEVEL_SHIFT;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    string private constant MAP_BADGE_PATH =
        "M14.3675 2.15671C14.7781 2.01987 15.2219 2.01987 15.6325 2.15671L20.6325 3.82338C21.4491 4.09561 22 4.85988 22 5.72074V19.6126C22 20.9777 20.6626 21.9416 19.3675 21.5099L15 20.0541L9.63246 21.8433C9.22192 21.9801 8.77808 21.9801 8.36754 21.8433L3.36754 20.1766C2.55086 19.9044 2 19.1401 2 18.2792V4.38741C2 3.0223 3.33739 2.05836 4.63246 2.49004L9 3.94589L14.3675 2.15671ZM15 4.05408L9.63246 5.84326C9.22192 5.9801 8.77808 5.9801 8.36754 5.84326L4 4.38741V18.2792L9 19.9459L14.3675 18.1567C14.7781 18.0199 15.2219 18.0199 15.6325 18.1567L20 19.6126V5.72074L15 4.05408ZM13.2929 8.29288C13.6834 7.90235 14.3166 7.90235 14.7071 8.29288L15.5 9.08577L16.2929 8.29288C16.6834 7.90235 17.3166 7.90235 17.7071 8.29288C18.0976 8.6834 18.0976 9.31657 17.7071 9.70709L16.9142 10.5L17.7071 11.2929C18.0976 11.6834 18.0976 12.3166 17.7071 12.7071C17.3166 13.0976 16.6834 13.0976 16.2929 12.7071L15.5 11.9142L14.7071 12.7071C14.3166 13.0976 13.6834 13.0976 13.2929 12.7071C12.9024 12.3166 12.9024 11.6834 13.2929 11.2929L14.0858 10.5L13.2929 9.70709C12.9024 9.31657 12.9024 8.6834 13.2929 8.29288ZM6 16C6.55228 16 7 15.5523 7 15C7 14.4477 6.55228 14 6 14C5.44772 14 5 14.4477 5 15C5 15.5523 5.44772 16 6 16ZM9 12C9 12.5523 8.55228 13 8 13C7.44772 13 7 12.5523 7 12C7 11.4477 7.44772 11 8 11C8.55228 11 9 11.4477 9 12ZM11 12C11.5523 12 12 11.5523 12 11C12 10.4477 11.5523 9.99998 11 9.99998C10.4477 9.99998 10 10.4477 10 11C10 11.5523 10.4477 12 11 12Z";
    string private constant AFFILIATE_BADGE_PATH =
        "M511.717 490.424l-85.333-136.533c-1.559-2.495-4.294-4.011-7.236-4.011H94.88c-2.942 0-5.677 1.516-7.236 4.011L2.311 490.424c-3.552 5.684 0.534 13.056 7.236 13.056H504.48c6.703 0 10.789-7.372 7.237-13.056zM24.943 486.414L99.61 366.947h314.807l74.667 119.467H24.943zM188.747 179.214c-2.942 0-5.677 1.516-7.236 4.011L96.177 319.758c-3.552 5.684 0.534 13.056 7.236 13.056h307.2c6.702 0 10.789-7.372 7.236-13.056l-45.173-72.277h73.146c3.789 14.723 17.152 25.6 33.058 25.6 18.853 0 34.133-15.281 34.133-34.133s-15.281-34.133-34.133-34.133c-15.906 0-29.269 10.877-33.058 25.6H362.01l-29.493-47.189c-1.559-2.495-4.294-4.011-7.236-4.011H188.747zM478.88 221.88c9.427 0 17.067 7.64 17.067 17.067 0 9.427-7.64 17.067-17.067 17.067s-17.067-7.64-17.067-17.067c0-9.427 7.64-17.067 17.067-17.067zM395.217 315.747H118.81l74.667-119.467h127.074l74.666 119.467zM94.88 145.08c15.906 0 29.269-10.877 33.058-25.6h74.961l-13.437 30.713c-2.467 5.638 1.664 11.954 7.818 11.954h119.467c6.154 0 10.284-6.316 7.818-11.954L264.832 13.66c-2.983-6.817-12.653-6.817-15.636 0l-38.83 88.754H127.938c-3.789-14.723-17.152-25.6-33.058-25.6-18.853 0-34.133 15.281-34.133 34.133 0 18.852 15.281 34.133 34.133 34.133zM257.014 38.37l46.686 106.71h-93.371l46.685-106.71zM94.88 93.88c9.427 0 17.067 7.64 17.067 17.067 0 9.427-7.64 17.067-17.067 17.067-9.427 0-17.067-7.64-17.067-17.067 0-9.427 7.64-17.067 17.067-17.067z";
    uint16 private constant DECIMATOR_SYMBOL_VB = 512;
    uint16 private constant BAF_FLIP_VB = 130;
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
    string private constant STAKE_BADGE_HEX = "#4d2b1f";
    string private constant STAKE_STATUS_TRANSFORM =
        "matrix(0.02548 0 0 0.02548 -10.583 -10.500)";
    string private constant ETH_STATUS_TRANSFORM =
        "matrix(0.00800 0 0 0.00800 -3.131 -5.100)";
    string private constant MAP_CORNER_TRANSFORM =
        "matrix(0.51 0 0 0.51 -6.12 -6.12)";
    string private constant FLAME_CORNER_TRANSFORM =
        "matrix(0.02810 0 0 0.02810 -12.03 -9.082)";
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
    uint32 private constant TOP_AFFILIATE_FIT_1e6 = (760_000 * 936) / 1_000;
    int256 private constant VIEWBOX_HEIGHT_1E6 = 120 * 1_000_000;
    int256 private constant TOP_AFFILIATE_SHIFT_DOWN_1E6 = 3_200_000;
    int256 private constant TOP_AFFILIATE_UPWARD_1E6 =
        (VIEWBOX_HEIGHT_1E6 * 4) / 100; // 4% of total height

    IPurgedRead private immutable coin;
    IIcons32 private immutable icons;
    IColorRegistry private immutable registry;
    ITrophySvgAssets private immutable assets;

    IERC721Lite private nft;

    error E();

    constructor(
        address coin_,
        address icons_,
        address registry_,
        address assets_
    ) {
        coin = IPurgedRead(coin_);
        icons = IIcons32(icons_);
        registry = IColorRegistry(registry_);
        if (assets_ == address(0)) revert E();
        assets = ITrophySvgAssets(assets_);
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
        uint32[4] calldata extras
    ) external view returns (string memory) {
        if ((data >> 128) == 0) revert("renderer:notTrophy");

        uint24 lvl = uint24((data >> 128) & 0xFFFFFF);
        uint16 exTr = _readExterminatedTrait(data);
        bool isMap = (data & MAP_TROPHY_FLAG) != 0;
        bool isAffiliate = (data & AFFILIATE_TROPHY_FLAG) != 0;
        bool isStake = (data & STAKE_TROPHY_FLAG) != 0;
        bool isBaf = (data & BAF_TROPHY_FLAG) != 0;
        bool isDec = (data & DECIMATOR_TROPHY_FLAG) != 0;
        bool isExtermination = !isMap &&
            !isAffiliate &&
            !isStake &&
            !isBaf &&
            !isDec;
        bool invertFlag = (data & TROPHY_FLAG_INVERT) != 0;
        uint32 statusFlags = extras[0];
        uint256 ethAttachment = data & TROPHY_OWED_MASK;
        if ((statusFlags & 2) == 0 && ethAttachment != 0) {
            statusFlags |= 2;
        }
        bool hasEthAttachment = ethAttachment != 0;
        uint24 stakedLevel = uint24(
            (data & TROPHY_STAKE_LEVEL_MASK) >> TROPHY_STAKE_LEVEL_SHIFT
        );
        bool hasStakedLevel = stakedLevel != 0;
        string memory stakedDurationStr;
        string memory stakeAttrValue = "No";
        if (hasStakedLevel) {
            uint256 duration = uint256(lvl) >= uint256(stakedLevel)
                ? uint256(lvl) - uint256(stakedLevel)
                : 0;
            stakedDurationStr = duration.toString();
            stakeAttrValue = string.concat(stakedDurationStr, " Levels");
        }

        string memory lvlStr = (lvl == 0) ? "TBD" : uint256(lvl).toString();
        string memory trophyType;
        string memory trophyLabel;
        if (isMap) {
            trophyType = "MAP";
            trophyLabel = "MAP Trophy";
        } else if (isAffiliate) {
            trophyType = "Affiliate";
            trophyLabel = "Affiliate Trophy";
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
            trophyType = "Exterminator";
            trophyLabel = "Exterminator Trophy";
        }

        string memory desc;
        if (exTr == 0xFFFF) {
            if (lvl == 0) {
                desc = string.concat("Reserved Purge Game ", trophyLabel, ".");
            } else {
                desc = string.concat(
                    "Reserved for level ",
                    lvlStr,
                    " ",
                    trophyLabel,
                    "."
                );
            }
        } else if (isAffiliate && exTr == 0xFFFE) {
            desc = string.concat(
                "Awarded to the top affiliate for level ",
                lvlStr,
                "."
            );
        } else if (isStake && exTr == 0xFFFD) {
            desc = string.concat(
                "Awarded for level ",
                lvlStr,
                " largest stake maturation."
            );
        } else if (isBaf && exTr == BAF_TRAIT_SENTINEL) {
            desc = string.concat(
                "Awarded to the biggest coinflipper in the level ",
                lvlStr,
                " BAF."
            );
        } else if (isDec && exTr == DECIMATOR_TRAIT_SENTINEL) {
            desc = string.concat(
                "Awarded to the biggest winner in the level ",
                lvlStr,
                " Decimator."
            );
        } else {
            desc = string.concat("Awarded for level ", lvlStr);
            desc = string.concat(
                desc,
                isMap ? " MAP Jackpot." : " Extermination victory."
            );
        }

        if (hasEthAttachment) {
            desc = string.concat(
                desc,
                "\\n",
                _formatEthAmount(ethAttachment),
                " ETH claimable."
            );
        }
        if (hasStakedLevel) {
            desc = string.concat(
                desc,
                "\\nStaked for ",
                stakedDurationStr,
                " levels."
            );
        }

        bool includeTraitAttr;
        string memory traitType;
        string memory traitValue;
        if (exTr < 256 && (isMap || isExtermination)) {
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
                '"},{"trait_type":"Eth","value":"',
                hasEthAttachment ? "Yes" : "No",
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
        attrs = string(
            abi.encodePacked(
                attrs,
                ',{"trait_type":"Staked","value":"',
                stakeAttrValue,
                '"}'
            )
        );
        attrs = string(abi.encodePacked(attrs, "]"));

        string memory img = _trophySvg(
            tokenId,
            exTr,
            isMap,
            isAffiliate,
            isStake,
            isBaf,
            isDec,
            statusFlags,
            lvl,
            invertFlag
        );
        return _pack(tokenId, true, img, lvl, desc, trophyType, attrs);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _readExterminatedTrait(
        uint256 data
    ) private pure returns (uint16) {
        uint16 ex16 = uint16((data >> 152) & 0xFFFF);
        if (ex16 >= 0xFFFA) return ex16;
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
        uint32 statusFlags,
        uint24 lvl,
        bool invertFlag
    ) private view returns (string memory) {
        uint32 innerSide = _innerSquareSide();
        string memory diamondPath = icons.diamond();
        bool isExtermination = !isMap &&
            !isAffiliate &&
            !isStake &&
            !isBaf &&
            !isDec;
        bool placeholderTrait = exterminatedTrait == 0xFFFF;
        // if (placeholderTrait && isAffiliate && !isStake) {
        //     exterminatedTrait = 0xFFFE;
        //     placeholderTrait = false;
        // }

        if (placeholderTrait || isStake) {
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
                _borderColor(tokenId, 0, uint8(1) << ringIdx, lvl)
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
                isStake,
                placeholderFlameColor,
                ringColor,
                diamondPath
            );
            string memory body = string(
                abi.encodePacked(rings, clip, centerGlyph)
            );
            return
                _composeSvg(
                    head,
                    body,
                    isMap,
                    isExtermination,
                    placeholderFlameColor,
                    diamondPath,
                    statusFlags
                );
        }

        bool isTopAffiliate = isAffiliate && exterminatedTrait == 0xFFFE;
        bool isBafAward = isBaf && exterminatedTrait == BAF_TRAIT_SENTINEL;
        bool isDecAward = isDec &&
            exterminatedTrait == DECIMATOR_TRAIT_SENTINEL;
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
        bool hasCustomAffiliateColor;
        {
            string memory defaultColor = _paletteColor(colIdx, lvl);
            if (isTopAffiliate) {
                string memory custom = registry.topAffiliateColor(tokenId);
                hasCustomAffiliateColor = bytes(custom).length != 0;
                ringOuterColor = hasCustomAffiliateColor
                    ? custom
                    : defaultColor;
                symbolColor = ringOuterColor;
            } else {
                ringOuterColor = defaultColor;
                symbolColor = defaultColor;
            }
        }

        string memory border;
        if (isTopAffiliate && hasCustomAffiliateColor) {
            border = _resolve(tokenId, 0, ringOuterColor);
        } else {
            border = _resolve(
                tokenId,
                0,
                _borderColor(tokenId, uint32(six), uint8(1) << colIdx, lvl)
            );
        }

        string memory flameColor = _resolve(tokenId, 1, "#111");
        string memory squareFill = _resolve(tokenId, 3, "#d9d9d9");

        uint32 pct2 = registry.trophyOuter(tokenId);
        uint32 rOut2 = (pct2 <= 1)
            ? 44
            : uint32((uint256(innerSide) * pct2) / 2_000_000);
        uint32 rMid2 = uint32((uint256(rOut2) * RATIO_MID_1e6) / 1_000_000);
        uint32 rIn2 = uint32((uint256(rOut2) * RATIO_IN_1e6) / 1_000_000);
        if (isBafAward) {
            uint32 scale = 690_000;
            int256 center = int256(uint256(BAF_FLIP_VB) * uint256(scale)) / 2;
            int256 adjustX = 4_400_000; // shift right ~4.4px
            int256 adjustY = 2_600_000; // shift down ~2.6px
            int256 offsetX = -center + adjustX;
            int256 offsetY = -center + adjustY;
            string memory anim = string(
                abi.encodePacked(
                    "<g transform='",
                    _mat6(scale, offsetX, offsetY),
                    "'>",
                    assets.bafFlipSymbol(),
                    "</g>"
                )
            );

            return
                _composeSvg(
                    _svgHeader(border, squareFill),
                    anim,
                    isMap,
                    isExtermination,
                    flameColor,
                    diamondPath,
                    statusFlags
                );
        }

        string memory innerFill = _resolve(tokenId, 2, "#fff");

        string memory iconPath;
        uint16 w;
        uint16 h;
        if (isDecAward) {
            iconPath = assets.decimatorSymbol();
            w = DECIMATOR_SYMBOL_VB;
            h = DECIMATOR_SYMBOL_VB;
        } else {
            uint256 iconIndex = isTopAffiliate
                ? 32
                : (uint256(dataQ) * 8 + uint256(symIdx));
            iconPath = icons.data(iconIndex);
            w = icons.vbW(iconIndex);
            h = icons.vbH(iconIndex);
        }
        uint16 m = w > h ? w : h;
        if (m == 0) m = 1;

        uint32 fitSym1e6 = _symbolFitScale(
            isTopAffiliate,
            isDecAward,
            dataQ,
            symIdx
        );
        uint32 sSym1e6 = uint32((uint256(2) * rIn2 * fitSym1e6) / m);

        (int256 txm, int256 tyn) = _symbolTranslate(
            w,
            h,
            sSym1e6,
            isTopAffiliate
        );

        bool solidFill = (!isTopAffiliate &&
            dataQ == 0 &&
            (symIdx == 1 || symIdx == 5));

        string memory ringsAndSymbol = string(
            abi.encodePacked(
                _rings(
                    ringOuterColor,
                    flameColor,
                    innerFill,
                    rOut2,
                    rMid2,
                    rIn2,
                    0,
                    0
                ),
                "<defs><clipPath id='ct2'><circle cx='0' cy='0' r='",
                uint256(rIn2).toString(),
                "'/></clipPath></defs>",
                string(
                    abi.encodePacked(
                        "<g clip-path='url(#ct2)'><g transform='",
                        _mat6(sSym1e6, txm, tyn),
                        "'><g fill='",
                        symbolColor,
                        "' stroke='",
                        solidFill ? "none" : symbolColor,
                        "' style='vector-effect:non-scaling-stroke'>",
                        iconPath,
                        "</g></g></g>"
                    )
                )
            )
        );

        // Invert exterminator trophies on repeat traits; flip logic on level 90.
        bool invertTrophy = isExtermination && ((lvl == 90) ? !invertFlag : invertFlag);
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
            _composeSvg(
                _svgHeader(border, squareFill),
                ringsAndSymbol,
                isMap,
                isExtermination,
                flameColor,
                diamondPath,
                statusFlags
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
        bool isStake,
        string memory defaultFillColor,
        string memory outerRingColor,
        string memory flamePath
    ) private view returns (string memory) {
        if (isMap) {
            return
                string(
                    abi.encodePacked(
                        '<g clip-path="url(#ct)">',
                        '<path fill="',
                        defaultFillColor,
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
                        outerRingColor,
                        '" transform="matrix(0.075 0 0 0.075 -19.2 -21.0)" d="',
                        AFFILIATE_BADGE_PATH,
                        '"/>',
                        "</g>"
                    )
                );
        }

        if (isStake) {
            string memory stakePath = assets.stakeBadgePath();
            return
                string(
                    abi.encodePacked(
                        '<g clip-path="url(#ct)">',
                        '<path fill="',
                        STAKE_BADGE_HEX,
                        '" transform="matrix(0.078125 0 0 0.078125 -31.25 -31.25)" d="',
                        stakePath,
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
                    defaultFillColor,
                    '" transform="matrix(0.13 0 0 0.13 -56 -41)" d="',
                    flamePath,
                    '"/>',
                    "</g>"
                )
            );
    }

    function _cornerGlyph(
        bool isMap,
        bool showFlame,
        string memory flameFill,
        string memory flamePath
    ) private pure returns (string memory) {
        if (isMap) {
            return
                string(
                    abi.encodePacked(
                        '<g transform="translate(40.5 40.5)" opacity="0.95">',
                        '<g transform="',
                        MAP_CORNER_TRANSFORM,
                        '"><path fill="',
                        flameFill,
                        '" d="',
                        MAP_BADGE_PATH,
                        '"/></g></g>'
                    )
                );
        }

        if (showFlame) {
            return
                string(
                    abi.encodePacked(
                        '<g transform="translate(40.5 40.5)" opacity="0.95">',
                        '<g transform="',
                        FLAME_CORNER_TRANSFORM,
                        '"><path fill="',
                        flameFill,
                        '" d="',
                        flamePath,
                        '"/></g></g>'
                    )
                );
        }

        return "";
    }

    function _statusIcons(
        bool isCurrentlyStaked,
        bool hasEthAttachment
    ) private view returns (string memory) {
        if (!isCurrentlyStaked && !hasEthAttachment) return "";

        string memory markup;
        if (isCurrentlyStaked) {
            string memory stakePath = assets.stakeBadgePath();
            markup = string(
                abi.encodePacked(
                    "<g transform='translate(-41 -41)'>",
                    "<g transform='",
                    STAKE_STATUS_TRANSFORM,
                    "'>",
                    "<path fill='",
                    STAKE_BADGE_HEX,
                    "' d='",
                    stakePath,
                    "'/>",
                    "</g></g>"
                )
            );
        }

        if (hasEthAttachment) {
            string memory ethPath = assets.ethStatusPath();
            markup = string(
                abi.encodePacked(
                    markup,
                    "<g transform='translate(41 -41)'>",
                    "<g transform='",
                    ETH_STATUS_TRANSFORM,
                    "' style='vector-effect:non-scaling-stroke'>",
                    ethPath,
                    "</g></g>"
                )
            );
        }

        return markup;
    }

    function _composeSvg(
        string memory header,
        string memory mainLayer,
        bool isMap,
        bool showCornerFlame,
        string memory flameColor,
        string memory diamondPath,
        uint32 statusFlags
    ) private view returns (string memory) {
        bool staked = (statusFlags & 1) != 0;
        bool hasEth = (statusFlags & 2) != 0;
        return
            string(
                abi.encodePacked(
                    header,
                    mainLayer,
                    _statusIcons(staked, hasEth),
                    _cornerGlyph(
                        isMap,
                        showCornerFlame,
                        flameColor,
                        diamondPath
                    ),
                    _svgFooter()
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
        uint8 excludeMask,
        uint24 level
    ) private view returns (string memory) {
        uint8 initial = uint8(
            uint256(keccak256(abi.encodePacked(tokenId, traits))) % 8
        );

        for (uint8 i; i < 8; ) {
            uint8 idx = uint8(initial + i) & 7;
            if ((excludeMask & (uint8(1) << idx)) == 0) {
                return _paletteColor(idx, level);
            }
            unchecked {
                ++i;
            }
        }
        return _paletteColor(0, level);
    }

    function _paletteColor(
        uint8 idx,
        uint24 level
    ) private view returns (string memory) {
        uint24 rgb = _paletteColorRGB(idx, level);
        return _rgbToHex(rgb);
    }

    function _paletteColorRGB(
        uint8 idx,
        uint24 level
    ) private view returns (uint24) {
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

    function _toneChannel(
        uint8 value,
        int16 delta
    ) private pure returns (uint8) {
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
        buf[0] = "#";
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

    function _symbolTitle(
        uint8 quadrant,
        uint8 symbolIdx
    ) private view returns (string memory) {
        if (quadrant < 3) {
            string memory externalName = icons.symbol(quadrant, symbolIdx);
            if (bytes(externalName).length != 0) {
                return externalName;
            }
            return
                string.concat("Symbol ", (uint256(symbolIdx) + 1).toString());
        }

        return string.concat("Dice ", (uint256(symbolIdx) + 1).toString());
    }

    function _isCryptoShrinkTarget(uint8 symIdx) private pure returns (bool) {
        return symIdx == 0 || symIdx == 1 || symIdx == 4;
    }

    function _isGamblingShrinkTarget(uint8 symIdx) private pure returns (bool) {
        return symIdx == 0 || symIdx == 6;
    }

    // All Zodiac symbols except Alpha (indexes 1-7) should shrink slightly.
    function _isZodiacShrinkTarget(uint8 symIdx) private pure returns (bool) {
        return
            symIdx == 1 ||
            symIdx == 2 ||
            symIdx == 3 ||
            symIdx == 4 ||
            symIdx == 5 ||
            symIdx == 6 ||
            symIdx == 7;
    }

    function _traitLabel(
        uint8 quadrant,
        uint8 colorIdx,
        uint8 symbolIdx
    ) private view returns (string memory) {
        return
            string.concat(
                _colorTitle(colorIdx),
                " ",
                _symbolTitle(quadrant, symbolIdx)
            );
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

    function _formatEthAmount(
        uint256 weiAmount
    ) private pure returns (string memory) {
        if (weiAmount == 0) return "0";
        uint256 whole = weiAmount / 1 ether;
        uint256 remainder = weiAmount % 1 ether;
        if (remainder == 0) {
            return whole.toString();
        }
        uint256 milli = (remainder + 500_000_000_000_000) /
            1_000_000_000_000_000;
        if (milli == 1000) {
            unchecked {
                ++whole;
            }
            milli = 0;
        }
        if (milli == 0) {
            return whole.toString();
        }
        bytes memory frac = new bytes(3);
        for (uint256 i; i < 3; ++i) {
            frac[2 - i] = bytes1(uint8(48 + (milli % 10)));
            milli /= 10;
        }
        uint256 trim = 3;
        while (trim > 0 && frac[trim - 1] == bytes1(uint8(48))) {
            unchecked {
                --trim;
            }
        }
        if (trim == 0) {
            return whole.toString();
        }
        bytes memory trimmed = new bytes(trim);
        for (uint256 i; i < trim; ++i) {
            trimmed[i] = frac[i];
        }
        return string(abi.encodePacked(whole.toString(), ".", trimmed));
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

    function _symbolFitScale(
        bool isTopAffiliate,
        bool isDecAward,
        uint8 dataQ,
        uint8 symIdx
    ) private pure returns (uint32) {
        if (isTopAffiliate) {
            return TOP_AFFILIATE_FIT_1e6;
        }

        uint32 fitSym1e6;
        if (isDecAward) {
            fitSym1e6 = 738_000;
        } else if (dataQ == 0 && (symIdx == 3 || symIdx == 7)) {
            fitSym1e6 = 1_030_000;
        } else if (dataQ == 1 && symIdx == 6) {
            fitSym1e6 = 600_000;
        } else {
            fitSym1e6 = 800_000;
        }

        if (dataQ == 1 && _isZodiacShrinkTarget(symIdx)) {
            fitSym1e6 = (fitSym1e6 * 9) / 10;
        } else if (dataQ == 0 && _isCryptoShrinkTarget(symIdx)) {
            fitSym1e6 = (fitSym1e6 * 85) / 100;
        } else if (dataQ == 2) {
            if (_isGamblingShrinkTarget(symIdx)) {
                fitSym1e6 = (fitSym1e6 * 9) / 10;
            } else if (symIdx == 1) {
                fitSym1e6 = (fitSym1e6 * 115) / 100;
            }
        } else if (dataQ == 3) {
            if (symIdx != 6 && symIdx != 7) {
                fitSym1e6 = (fitSym1e6 * 9) / 10;
            }
        }

        return fitSym1e6;
    }

    function _symbolTranslate(
        uint16 w,
        uint16 h,
        uint32 scale1e6,
        bool isTopAffiliate
    ) private pure returns (int256 txm, int256 tyn) {
        txm = -(int256(uint256(w)) * int256(uint256(scale1e6))) / 2;
        tyn = -(int256(uint256(h)) * int256(uint256(scale1e6))) / 2;
        if (isTopAffiliate) {
            tyn += TOP_AFFILIATE_SHIFT_DOWN_1E6;
            tyn -= TOP_AFFILIATE_UPWARD_1E6;
        }
    }

    function _i(int16 v) private pure returns (string memory) {
        int256 x = v;
        if (x >= 0) return uint256(x).toString();
        return string.concat("-", uint256(-x).toString());
    }
}
