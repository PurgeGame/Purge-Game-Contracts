// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Strings.sol";
import "./interfaces/IDegenerusAffiliate.sol";
import "./interfaces/IconRendererTypes.sol";
import {ITrophySvgAssets} from "./TrophySvgAssets.sol";

interface IIconRendererTrophy32Svg {
    struct SvgParams {
        uint256 tokenId;
        uint16 exterminatedTrait;
        bool isMap;
        bool isAffiliate;
        bool isStake;
        bool isBaf;
        bool isDec;
        uint32 statusFlags;
        uint24 lvl;
        bool invertFlag;
        bool isBond;
        uint16 bondChanceBps;
        bool bondMatured;
        uint32 bondProgress1e6;
    }

    function trophySvg(SvgParams calldata params) external view returns (string memory);
    function setNft(address nft_) external;
}

contract IconRendererTrophy32Svg is IIconRendererTrophy32Svg {
    using Strings for uint256;

    IDegenerusdRead private immutable coin;
    IIcons32 private immutable icons;
    IColorRegistry private immutable registry;
    ITrophySvgAssets private immutable assets;
    IERC721Lite private nft;

    error E();

    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    string private constant MAP_BADGE_PATH =
        "M14.3675 2.15671C14.7781 2.01987 15.2219 2.01987 15.6325 2.15671L20.6325 3.82338C21.4491 4.09561 22 4.85988 22 5.72074V19.6126C22 20.9777 20.6626 21.9416 19.3675 21.5099L15 20.0541L9.63246 21.8433C9.22192 21.9801 8.77808 21.9801 8.36754 21.8433L3.36754 20.1766C2.55086 19.9044 2 19.1401 2 18.2792V4.38741C2 3.0223 3.33739 2.05836 4.63246 2.49004L9 3.94589L14.3675 2.15671ZM15 4.05408L9.63246 5.84326C9.22192 5.9801 8.77808 5.9801 8.36754 5.84326L4 4.38741V18.2792L9 19.9459L14.3675 18.1567C14.7781 18.0199 15.2219 18.0199 15.6325 18.1567L20 19.6126V5.72074L15 4.05408ZM13.2929 8.29288C13.6834 7.90235 14.3166 7.90235 14.7071 8.29288L15.5 9.08577L16.2929 8.29288C16.6834 7.90235 17.3166 7.90235 17.7071 8.29288C18.0976 8.6834 18.0976 9.31657 17.7071 9.70709L16.9142 10.5L17.7071 11.2929C18.0976 11.6834 18.0976 12.3166 17.7071 12.7071C17.3166 13.0976 16.6834 13.0976 16.2929 12.7071L15.5 11.9142L14.7071 12.7071C14.3166 13.0976 13.6834 13.0976 13.2929 12.7071C12.9024 12.3166 12.9024 11.6834 13.2929 11.2929L14.0858 10.5L13.2929 9.70709C12.9024 9.31657 12.9024 8.6834 13.2929 8.29288ZM6 16C6.55228 16 7 15.5523 7 15C7 14.4477 6.55228 14 6 14C5.44772 14 5 14.4477 5 15C5 15.5523 5.44772 16 6 16ZM9 12C9 12.5523 8.55228 13 8 13C7.44772 13 7 12.5523 7 12C7 11.4477 7.44772 11 8 11C8.55228 11 9 11.4477 9 12ZM11 12C11.5523 12 12 11.5523 12 11C12 10.4477 11.5523 9.99998 11 9.99998C10.4477 9.99998 10 10.4477 10 11C10 11.5523 10.4477 12 11 12Z";
    string private constant AFFILIATE_BADGE_PATH =
        "M511.717 490.424l-85.333-136.533c-1.559-2.495-4.294-4.011-7.236-4.011H94.88c-2.942 0-5.677 1.516-7.236 4.011L2.311 490.424c-3.552 5.684 0.534 13.056 7.236 13.056H504.48c6.703 0 10.789-7.372 7.237-13.056zM24.943 486.414L99.61 366.947h314.807l74.667 119.467H24.943zM188.747 179.214c-2.942 0-5.677 1.516-7.236 4.011L96.177 319.758c-3.552 5.684 0.534 13.056 7.236 13.056h307.2c6.702 0 10.789-7.372 7.236-13.056l-45.173-72.277h73.146c3.789 14.723 17.152 25.6 33.058 25.6 18.853 0 34.133-15.281 34.133-34.133s-15.281-34.133-34.133-34.133c-15.906 0-29.269 10.877-33.058 25.6H362.01l-29.493-47.189c-1.559-2.495-4.294-4.011-7.236-4.011H188.747zM478.88 221.88c9.427 0 17.067 7.64 17.067 17.067 0 9.427-7.64 17.067-17.067 17.067s-17.067-7.64-17.067-17.067c0-9.427 7.64-17.067 17.067-17.067zM395.217 315.747H118.81l74.667-119.467h127.074l74.666 119.467zM94.88 145.08c15.906 0 29.269-10.877 33.058-25.6h74.961l-13.437 30.713c-2.467 5.638 1.664 11.954 7.818 11.954h119.467c6.154 0 10.284-6.316 7.818-11.954L264.832 13.66c-2.983-6.817-12.653-6.817-15.636 0l-38.83 88.754H127.938c-3.789-14.723-17.152-25.6-33.058-25.6-18.853 0-34.133 15.281-34.133 34.133 0 18.852 15.281 34.133 34.133 34.133zM257.014 38.37l46.686 106.71h-93.371l46.685-106.71zM94.88 93.88c9.427 0 17.067 7.64 17.067 17.067 0 9.427-7.64 17.067-17.067 17.067-9.427 0-17.067-7.64-17.067-17.067 0-9.427 7.64-17.067 17.067-17.067z";
    uint16 private constant DECIMATOR_SYMBOL_VB = 512;
    uint16 private constant BAF_FLIP_VB = 130;
    uint24[8] private BASE_COLOR = [0xf409cd, 0x7c2bff, 0x30d100, 0xed0e11, 0x1317f7, 0xf7931a, 0x5e5e5e, 0xab8d3f];
    string private constant STAKE_BADGE_HEX = "#4d2b1f";
    string private constant STAKE_STATUS_TRANSFORM = "matrix(0.02548 0 0 0.02548 -10.583 -10.500)";
    string private constant ETH_STATUS_TRANSFORM = "matrix(0.00800 0 0 0.00800 -3.131 -5.100)";
    uint32 private constant BOND_BADGE_ETH_SCALE_1e6 = 33_000;
    uint32 private constant BOND_BADGE_FLAME_SCALE_1e6 = 20_000;
    int32 private constant BOND_BADGE_ETH_CX = 392;
    int32 private constant BOND_BADGE_ETH_CY = 439;
    int32 private constant BOND_BADGE_FLAME_CX = 430;
    int32 private constant BOND_BADGE_FLAME_CY = 315;
    string private constant BOND_BADGE_FLAME_HEX = "#ff3300";
    string private constant MAP_CORNER_TRANSFORM = "matrix(0.51 0 0 0.51 -6.12 -6.12)";
    string private constant FLAME_CORNER_TRANSFORM = "matrix(0.02810 0 0 0.02810 -12.03 -9.082)";
    uint16 private constant ICON_VB = 512; // normalized icon viewBox (square)
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
    int256 private constant TOP_AFFILIATE_UPWARD_1E6 = (VIEWBOX_HEIGHT_1E6 * 4) / 100; // 4% of total height

    constructor(address coin_, address icons_, address registry_, address assets_) {
        coin = IDegenerusdRead(coin_);
        icons = IIcons32(icons_);
        registry = IColorRegistry(registry_);
        if (assets_ == address(0)) revert E();
        assets = ITrophySvgAssets(assets_);
    }

    function setNft(address nft_) external override {
        if (msg.sender != address(coin)) revert E();
        nft = IERC721Lite(nft_);
    }

    function trophySvg(SvgParams calldata params) external view override returns (string memory) {
        uint256 tokenId = params.tokenId;
        uint16 exterminatedTrait = params.exterminatedTrait;
        bool isMap = params.isMap;
        bool isAffiliate = params.isAffiliate;
        bool isStake = params.isStake;
        bool isBaf = params.isBaf;
        bool isDec = params.isDec;
        uint24 lvl = params.lvl;
        uint32 statusFlags = params.statusFlags;
        bool bondMatured = params.bondMatured;
        bool isBond = params.isBond;

        // Placeholder or stake trophies skip trait-driven palette lookup and instead
        // derive colors from owner/referrer overrides plus registry-configured sizes.
        uint32 innerSide = _innerSquareSide();
        string memory diamondPath = icons.diamond();
        bool isExtermination = !isMap && !isAffiliate && !isStake && !isBaf && !isDec;
        bool placeholderTrait = exterminatedTrait == 0xFFFF;

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
            string memory borderColor = _resolve(tokenId, 0, _borderColor(tokenId, 0, uint8(1) << ringIdx, lvl));

            uint32 rOut;
            uint32 rMid;
            uint32 rIn;
            if (isBond) {
                rOut = 66;
                rMid = 51;
                rIn = 40;
            } else {
                uint32 pct = registry.trophyOuter(address(nft), tokenId);
                uint32 diameter = (pct <= 1) ? 88 : uint32((uint256(innerSide) * pct) / 1_000_000);
                rOut = diameter / 2;
                rMid = uint32((uint256(rOut) * RATIO_MID_1e6) / 1_000_000);
                rIn = uint32((uint256(rOut) * RATIO_IN_1e6) / 1_000_000);
            }

            string memory head = isBond
                ? _svgHeader("#30d100", "#cccccc")
                : _svgHeader(borderColor, _resolve(tokenId, 3, "#d9d9d9"));
            string memory placeholderFlameColor = isBond ? "#ff3300" : _resolve(tokenId, 1, "#ff3300");
            string memory ringColor = isBond ? "#30d100" : _paletteColor(ringIdx, lvl);
            bool showProgress = isBond && !bondMatured ? false : (isBond && !bondMatured);
            string memory progressColor = placeholderFlameColor;
            string memory bandColor = isBond
                ? "#111"
                : (showProgress ? _bandColorForProgress(progressColor) : placeholderFlameColor);
            string memory rings = _rings(
                ringColor,
                bandColor,
                isBond ? "#fff" : _resolve(tokenId, 2, "#fff"),
                rOut,
                rMid,
                rIn,
                0,
                0
            );

            string memory clip = isBond
                ? ""
                : string(
                    abi.encodePacked(
                        '<defs><clipPath id="ct"><circle cx="0" cy="0" r="',
                        uint256(rIn).toString(),
                        '"/></clipPath></defs>'
                    )
                );

            string memory centerGlyph = isBond
                ? _bondCenterGlyph(placeholderFlameColor, diamondPath)
                : _centerGlyph(isMap, isAffiliate, isStake, placeholderFlameColor, ringColor, diamondPath);
            string memory progress = "";
            if (showProgress) {
                progress = _bondProgressArc(rIn, rMid, params.bondProgress1e6, progressColor);
            }
            string memory body = string(abi.encodePacked(rings, clip, progress, centerGlyph));
            return
                _composeSvg(
                    head,
                    body,
                    isMap,
                    isBond ? false : isExtermination,
                    placeholderFlameColor,
                    diamondPath,
                    statusFlags
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
        bool hasCustomAffiliateColor;
        {
            string memory defaultColor = _paletteColor(colIdx, lvl);
            if (isTopAffiliate) {
                string memory custom = registry.topAffiliateColor(address(nft), tokenId);
                hasCustomAffiliateColor = bytes(custom).length != 0;
                ringOuterColor = hasCustomAffiliateColor ? custom : defaultColor;
            } else {
                ringOuterColor = defaultColor;
            }
        }

        string memory border;
        if (isTopAffiliate && hasCustomAffiliateColor) {
            border = _resolve(tokenId, 0, ringOuterColor);
        } else {
            border = _resolve(tokenId, 0, _borderColor(tokenId, uint32(six), uint8(1) << colIdx, lvl));
        }

        string memory flameColor = _resolve(tokenId, 1, "#111");

        uint32 pct2 = registry.trophyOuter(address(nft), tokenId);
        uint32 rOut2 = (pct2 <= 1) ? 44 : uint32((uint256(innerSide) * pct2) / 2_000_000);
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
                abi.encodePacked("<g transform='", _mat6(scale, offsetX, offsetY), "'>", assets.bafFlipSymbol(), "</g>")
            );

            return
                _composeSvg(
                    _svgHeader(border, _resolve(tokenId, 3, "#d9d9d9")),
                    anim,
                    isMap,
                    isExtermination,
                    flameColor,
                    diamondPath,
                    statusFlags
                );
        }

        string memory iconPath;
        uint16 w;
        uint16 h;
        if (isDecAward) {
            iconPath = assets.decimatorSymbol();
            w = DECIMATOR_SYMBOL_VB;
            h = DECIMATOR_SYMBOL_VB;
        } else {
            uint256 iconIndex = isTopAffiliate ? 32 : (uint256(dataQ) * 8 + uint256(symIdx));
            iconPath = icons.data(iconIndex);
            w = ICON_VB;
            h = ICON_VB;
        }
        uint16 m = w > h ? w : h;
        if (m == 0) m = 1;

        uint32 fitSym1e6 = _symbolFitScale(isTopAffiliate, isDecAward, dataQ, symIdx);
        uint32 sSym1e6 = uint32((uint256(2) * rIn2 * fitSym1e6) / m);

        (int256 txm, int256 tyn) = _symbolTranslate(w, h, sSym1e6, isTopAffiliate);

        // Crypto quadrant symbols (dataQ == 0) should render with their native path colors,
        // not the ring color. Others stay tinted to the ring.
        string memory symbolGroup;
        if (dataQ == 0 && !isTopAffiliate && !isDecAward) {
            symbolGroup = string(
                abi.encodePacked(
                    "<g transform='",
                    _mat6(sSym1e6, txm, tyn),
                    "'><g style='vector-effect:non-scaling-stroke'>",
                    iconPath,
                    "</g></g>"
                )
            );
        } else {
            bool solidFill = (!isTopAffiliate && dataQ == 0 && (symIdx == 1 || symIdx == 5));
            symbolGroup = string(
                abi.encodePacked(
                    "<g transform='",
                    _mat6(sSym1e6, txm, tyn),
                    "'><g fill='",
                    ringOuterColor,
                    "' stroke='",
                    solidFill ? "none" : ringOuterColor,
                    "' style='vector-effect:non-scaling-stroke'>",
                    iconPath,
                    "</g></g>"
                )
            );
        }

        string memory ringsAndSymbol = string(
            abi.encodePacked(
                _rings(ringOuterColor, flameColor, _resolve(tokenId, 2, "#fff"), rOut2, rMid2, rIn2, 0, 0),
                "<defs><clipPath id='ct2'><circle cx='0' cy='0' r='",
                uint256(rIn2).toString(),
                "'/></clipPath></defs>",
                "<g clip-path='url(#ct2)'>",
                symbolGroup,
                "</g>"
            )
        );

        bool invertTrophy = isExtermination && ((lvl == 90) ? !params.invertFlag : params.invertFlag);
        if (invertTrophy) {
            ringsAndSymbol = string(abi.encodePacked('<g filter="url(#inv)">', ringsAndSymbol, "</g>"));
        }

        return
            _composeSvg(
                _svgHeader(border, _resolve(tokenId, 3, "#d9d9d9")),
                ringsAndSymbol,
                isMap,
                isExtermination,
                flameColor,
                diamondPath,
                statusFlags
            );
    }

    function _resolve(uint256 tokenId, uint8 k, string memory defColor) private view returns (string memory) {
        // Resolution order: per-token override → owner default (non-reverting lookup) →
        // referrer/upline defaults → provided fallback. The try/catch shields metadata
        // reads when `ownerOf` reverts for burned/unminted ids.
        string memory s = registry.tokenColor(address(nft), tokenId, k);
        if (bytes(s).length != 0) return s;

        address owner_;
        try nft.ownerOf(tokenId) returns (address o) {
            owner_ = o;
        } catch {
            owner_ = address(0);
        }
        s = registry.addressColor(owner_, k);
        if (bytes(s).length != 0) return s;

        address ref = _referrer(owner_);
        if (ref != address(0)) {
            s = registry.addressColor(ref, k);
            if (bytes(s).length != 0) return s;
            address up = _referrer(ref);
            if (up != address(0)) {
                s = registry.addressColor(up, k);
                if (bytes(s).length != 0) return s;
            }
        }
        return defColor;
    }

    function _affiliateProgram() private view returns (IDegenerusAffiliate) {
        address affiliate = coin.affiliateProgram();
        return affiliate == address(0) ? IDegenerusAffiliate(address(0)) : IDegenerusAffiliate(affiliate);
    }

    function _referrer(address user) private view returns (address) {
        IDegenerusAffiliate affiliate = _affiliateProgram();
        if (address(affiliate) == address(0)) return address(0);
        return affiliate.getReferrer(user);
    }

    function _svgHeader(string memory borderColor, string memory squareFill) private pure returns (string memory) {
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

    function _bondCenterGlyph(string memory defaultFillColor, string memory flamePath) private view returns (string memory) {
        // Fixed layout matching eth_trophy.svg badge.
        string memory ethIcon = string(
            abi.encodePacked(
                "<g transform='matrix(0.048888 0 0 0.048888 -19.164096 -31.239432)'>",
                assets.ethStatusPath(),
                "</g>"
            )
        );

        string memory flames = string(
            abi.encodePacked(
                "<g transform='translate(0.000018 0.000024)'><path fill='",
                defaultFillColor,
                "' transform='matrix(0.029629 0 0 0.029629 -12.740470 -9.333135)' d='",
                flamePath,
                "'/></g>",
                "<g transform='translate(0.000008 0.000028)'><path fill='",
                defaultFillColor,
                "' transform='matrix(0.032591 0 0 0.032591 -14.014130 -10.266165)' d='",
                flamePath,
                "'/></g>",
                "<g transform='translate(0.000024 0.000014)'><path fill='",
                defaultFillColor,
                "' transform='matrix(0.026666 0 0 0.026666 -11.466380 -8.399790)' d='",
                flamePath,
                "'/></g>"
            )
        );

        return string(abi.encodePacked(ethIcon, flames));
    }

    function _bondProgressArc(
        uint32 innerRadius,
        uint32 midRadius,
        uint32 progress1e6,
        string memory strokeColor
    ) private pure returns (string memory) {
        uint256 pct100 = (uint256(progress1e6) + 5_000) / 10_000;
        if (pct100 > 100) pct100 = 100;
        uint32 bandWidth = midRadius > innerRadius ? midRadius - innerRadius : uint32(1);
        uint256 strokeW = bandWidth == 0 ? 1 : bandWidth;
        string memory radius = _midRadiusToString(innerRadius, midRadius);
        string memory dash = pct100.toString();
        int256 rotateDeg = -90 + _bondRotationOffset(pct100);
        string memory rotateStr = _intToString(rotateDeg);
        return
            string(
                abi.encodePacked(
                    "<g class='bondeg' transform='rotate(",
                    rotateStr,
                    ")'>",
                    "<circle cx='0' cy='0' r='",
                    radius,
                    "' fill='none' stroke='",
                    strokeColor,
                    "' stroke-width='",
                    strokeW.toString(),
                    "' stroke-linecap='round' stroke-dasharray='",
                    dash,
                    " 100'/></g>"
                )
            );
    }

    function _badgeFlame(
        string memory flameColor,
        string memory flamePath,
        uint32 scale1e6,
        int256 tx1e6,
        int256 ty1e6,
        int256 shiftX1e6,
        int256 shiftY1e6
    ) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "<g transform='translate(",
                    _dec6s(shiftX1e6),
                    " ",
                    _dec6s(shiftY1e6),
                    ")'><path fill='",
                    flameColor,
                    "' transform='",
                    _mat6(scale1e6, tx1e6, ty1e6),
                    "' d='",
                    flamePath,
                    "'/></g>"
                )
            );
    }

    function _badgeFlameTx(uint32 scale1e6) private pure returns (int256) {
        return -int256(BOND_BADGE_FLAME_CX) * int256(uint256(scale1e6));
    }

    function _badgeFlameTy(uint32 scale1e6) private pure returns (int256) {
        return -int256(BOND_BADGE_FLAME_CY) * int256(uint256(scale1e6));
    }

    function _midRadiusToString(uint32 innerRadius, uint32 midRadius) private pure returns (string memory) {
        uint32 r = innerRadius + ((midRadius > innerRadius ? midRadius - innerRadius : uint32(0)) / 2);
        return uint256(r).toString();
    }

    function _bondRotationOffset(uint256 pct100) private pure returns (int256) {
        if (pct100 >= 90) return int256((pct100 - 90) / 3);
        return int256(0);
    }

    function _intToString(int256 v) private pure returns (string memory) {
        if (v < 0) {
            return string(abi.encodePacked("-", uint256(-v).toString()));
        }
        return uint256(v).toString();
    }

    function _bandColorForProgress(string memory progressColor) private pure returns (string memory) {
        string memory darker = _lightenHex(progressColor, -18);
        return _blendHex(progressColor, darker, 750_000);
    }

    function _blendHex(string memory a, string memory b, uint32 biasPct1e6) private pure returns (string memory) {
        uint24 c1 = _hexToRgb(a);
        uint24 c2 = _hexToRgb(b);
        uint24 blended;
        unchecked {
            blended =
                uint24((((c1 >> 16) * biasPct1e6) / 1_000_000) << 16) +
                uint24((((c2 >> 16) * (1_000_000 - biasPct1e6)) / 1_000_000) << 16) +
                uint24(((((c1 >> 8) & 0xff) * biasPct1e6) / 1_000_000) << 8) +
                uint24(((((c2 >> 8) & 0xff) * (1_000_000 - biasPct1e6)) / 1_000_000) << 8) +
                uint24((((c1 & 0xff) * biasPct1e6) / 1_000_000)) +
                uint24((((c2 & 0xff) * (1_000_000 - biasPct1e6)) / 1_000_000));
        }
        return _rgbToHex(blended);
    }

    function _cornerGlyph(
        string memory cornerTransform,
        string memory diamondPath,
        bool isMap
    ) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "<g transform='",
                    cornerTransform,
                    "'>",
                    isMap ? diamondPath : "<path d='M13 21h-5.5l-1.5 7-1.5-7H-1V1h14z'/>",
                    "</g>"
                )
            );
    }

    function _statusIcons(uint32 statusFlags) private view returns (string memory) {
        if (statusFlags == 0) {
            return "";
        }
        string memory stakeIcon;
        if ((statusFlags & 1) != 0) {
            stakeIcon = string(
                abi.encodePacked("<g transform='", STAKE_STATUS_TRANSFORM, "'>", assets.stakeBadgePath(), "</g>")
            );
        }
        string memory ethIcon;
        if ((statusFlags & 2) != 0) {
            ethIcon = string(
                abi.encodePacked("<g transform='", ETH_STATUS_TRANSFORM, "'>", assets.ethStatusPath(), "</g>")
            );
        }
        return string(abi.encodePacked(stakeIcon, ethIcon));
    }

    function _composeSvg(
        string memory head,
        string memory inner,
        bool isMap,
        bool includeCorners,
        string memory flamePath,
        string memory diamondPath,
        uint32 statusFlags
    ) private view returns (string memory) {
        string memory corners = includeCorners
            ? string(
                abi.encodePacked(
                    _cornerGlyph(MAP_CORNER_TRANSFORM, diamondPath, isMap),
                    _cornerGlyph(FLAME_CORNER_TRANSFORM, flamePath, false)
                )
            )
            : "";
        return string(abi.encodePacked(head, inner, corners, _statusIcons(statusFlags), _svgFooter()));
    }

    function _svgFooter() private pure returns (string memory) {
        return "</svg>";
    }

    function _rings(
        string memory outerRingColor,
        string memory bandColor,
        string memory coreColor,
        uint32 rOut,
        uint32 rMid,
        uint32 rIn,
        uint32 transformX,
        uint32 transformY
    ) private pure returns (string memory) {
        string memory transform = "";
        if (transformX != 0 || transformY != 0) {
            transform = string(
                abi.encodePacked(
                    " transform='translate(",
                    uint256(transformX).toString(),
                    " ",
                    uint256(transformY).toString(),
                    ")'"
                )
            );
        }
        return
            string(
                abi.encodePacked(
                    "<g",
                    transform,
                    ">",
                    "<circle cx='0' cy='0' r='",
                    uint256(rOut).toString(),
                    "' fill='",
                    outerRingColor,
                    "'/>",
                    "<circle cx='0' cy='0' r='",
                    uint256(rMid).toString(),
                    "' fill='",
                    bandColor,
                    "'/>",
                    "<circle cx='0' cy='0' r='",
                    uint256(rIn).toString(),
                    "' fill='",
                    coreColor,
                    "'/>",
                    "</g>"
                )
            );
    }

    function _borderColor(
        uint256 tokenId,
        uint32 six,
        uint8 colorMask,
        uint24 level
    ) private view returns (string memory) {
        uint8 colIdx = uint8((six >> 3) & 0x07);
        if ((colorMask & (uint8(1) << colIdx)) == 0) {
            colIdx = 0;
        }
        string memory palette = _paletteColor(colIdx, level);
        string memory ownerColor = _resolve(tokenId, 0, palette);
        if (bytes(ownerColor).length == 0) return palette;
        return ownerColor;
    }

    function _paletteColor(uint8 idx, uint24 level) private view returns (string memory) {
        uint24 rgb = _paletteColorRGB(idx, level);
        return _rgbToHex(rgb);
    }

    function _paletteColorRGB(uint8 idx, uint24 level) private view returns (uint24) {
        uint24 rgb = BASE_COLOR[idx & 0x07];
        int16 delta = BASE_VARIANT_BIAS[idx & 0x07];
        if (idx == 7 || level == 0) {
            return rgb;
        }
        uint8 levelGroup = uint8(((level - 1) % 24) / 8);
        if (levelGroup == 0) {
            return rgb;
        }
        if (levelGroup == 1) {
            delta = delta > 0 ? int16(delta / 2) : int16(-((-delta) / 2));
        }
        return _toneChannel(rgb, delta);
    }

    function _toneChannel(uint24 rgb, int16 delta) private pure returns (uint24) {
        int256 d = int256(delta);
        int256 r = int256(uint256(uint16(rgb >> 16))) + d;
        int256 g = int256(uint256(uint16((rgb >> 8) & 0xff))) + d;
        int256 b = int256(uint256(uint16(rgb & 0xff))) + d;
        if (r < 0) r = 0;
        if (g < 0) g = 0;
        if (b < 0) b = 0;
        if (r > 255) r = delta > 0 ? int256(255) : int256(0);
        if (g > 255) g = delta > 0 ? int256(255) : int256(0);
        if (b > 255) b = delta > 0 ? int256(255) : int256(0);
        return (uint24(uint16(uint256(r))) << 16) | (uint24(uint16(uint256(g))) << 8) | uint24(uint16(uint256(b)));
    }

    function _rgbToHex(uint24 rgb) private pure returns (string memory) {
        bytes memory buffer = new bytes(7);
        buffer[0] = "#";
        buffer[1] = _hexChar(uint8(rgb >> 20));
        buffer[2] = _hexChar(uint8(rgb >> 16));
        buffer[3] = _hexChar(uint8(rgb >> 12));
        buffer[4] = _hexChar(uint8(rgb >> 8));
        buffer[5] = _hexChar(uint8(rgb >> 4));
        buffer[6] = _hexChar(uint8(rgb));
        return string(buffer);
    }

    function _hexToRgb(string memory hexColor) private pure returns (uint24) {
        bytes memory b = bytes(hexColor);
        if (b.length != 7 || b[0] != "#") return 0;
        return
            uint24(
                (_fromHexChar(b[1]) << 20) |
                    (_fromHexChar(b[2]) << 16) |
                    (_fromHexChar(b[3]) << 12) |
                    (_fromHexChar(b[4]) << 8) |
                    (_fromHexChar(b[5]) << 4) |
                    _fromHexChar(b[6])
            );
    }

    function _hexChar(uint8 nibble) private pure returns (bytes1) {
        return bytes1(nibble < 10 ? nibble + 0x30 : nibble + 0x57);
    }

    function _fromHexChar(bytes1 c) private pure returns (uint8) {
        uint8 b = uint8(c);
        if (b >= 0x30 && b <= 0x39) {
            return b - 0x30;
        }
        if (b >= 0x61 && b <= 0x66) {
            return 10 + b - 0x61;
        }
        if (b >= 0x41 && b <= 0x46) {
            return 10 + b - 0x41;
        }
        return 0;
    }

    function _lightenHex(string memory hexColor, int16 delta) private pure returns (string memory) {
        uint24 rgb = _hexToRgb(hexColor);
        return _rgbToHex(_toneChannel(rgb, delta));
    }

    function _innerSquareSide() private pure returns (uint32) {
        return 88;
    }

    function _bondScaleFromChance(uint16 chanceBps, bool matured) private pure returns (uint32) {
        uint256 base = matured ? 1_380_000 : 1_300_000;
        uint256 delta = (uint256(chanceBps) * 400_000) / 10_000;
        uint256 scale = base + delta;
        if (scale < 1_000_000) scale = 1_000_000;
        if (scale > 1_900_000) scale = 1_900_000;
        return uint32(scale);
    }

    function _mat6(uint32 scale1e6, int256 tx1e6, int256 ty) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "matrix(",
                    _dec6(scale1e6),
                    " 0 0 ",
                    _dec6(scale1e6),
                    " ",
                    _dec6s(tx1e6),
                    " ",
                    _dec6s(ty),
                    ")"
                )
            );
    }

    function _dec6(uint256 x) private pure returns (string memory) {
        return string(abi.encodePacked((x / 1_000_000).toString(), ".", _pad6(uint32(x % 1_000_000))));
    }

    function _dec6s(int256 x) private pure returns (string memory) {
        if (x < 0) {
            return string(abi.encodePacked("-", _dec6(uint256(-x))));
        }
        return _dec6(uint256(x));
    }

    function _pad6(uint32 f) private pure returns (string memory) {
        bytes memory b = new bytes(6);
        uint256 i = 6;
        uint32 n = f;
        while (i > 0) {
            unchecked {
                b[--i] = bytes1(uint8(48 + (n % 10)));
                n /= 10;
            }
        }
        return string(b);
    }

    function _symbolFitScale(
        bool isTopAffiliate,
        bool isDecAward,
        uint8 quadrant,
        uint8 symbolIdx
    ) private pure returns (uint32) {
        if (isTopAffiliate) return TOP_AFFILIATE_FIT_1e6;
        if (isDecAward && symbolIdx == 1) return 750_000;
        if (quadrant == 0 && (symbolIdx == 1 || symbolIdx == 5)) return 790_000;
        if (quadrant == 2 && (symbolIdx == 1 || symbolIdx == 5)) return 820_000;
        if (quadrant == 1 && symbolIdx == 6) return 820_000;
        if (quadrant == 3 && symbolIdx == 7) return 780_000;
        return 890_000;
    }

    function _symbolTranslate(
        uint16 w,
        uint16 h,
        uint32 sSym1e6,
        bool isTopAffiliate
    ) private pure returns (int256 txm, int256 tyn) {
        int256 scale = int256(uint256(sSym1e6));
        int256 w1e6 = int256(uint256(w)) * scale;
        int256 h1e6 = int256(uint256(h)) * scale;
        txm = -w1e6 / 2;
        tyn = -h1e6 / 2;
        if (isTopAffiliate && h > w) {
            int256 shift = (h1e6 * TOP_AFFILIATE_UPWARD_1E6) / VIEWBOX_HEIGHT_1E6;
            tyn -= shift;
            txm += TOP_AFFILIATE_SHIFT_DOWN_1E6;
        }
    }
}
