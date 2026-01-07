// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                    IconRendererTrophy32Svg                                            ║
║                         SVG Generation Engine for Degenerus Trophy Tokens                             ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                       ║
║  ARCHITECTURE OVERVIEW                                                                                ║
║  ─────────────────────                                                                                ║
║  IconRendererTrophy32Svg generates the actual SVG image content for trophy tokens. It is called       ║
║  by IconRendererTrophy32 (the metadata wrapper) and returns raw SVG strings.                          ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              RENDERING PIPELINE                                                  │ ║
║  │                                                                                                  │ ║
║  │   DegenerusTrophies.tokenURI()                                                                   │ ║
║  │          │                                                                                       │ ║
║  │          ▼                                                                                       │ ║
║  │   IconRendererTrophy32.tokenURI() ─── Generates JSON metadata                                   │  ║
║  │          │                                                                                       │ ║
║  │          ▼                                                                                       │ ║
║  │   IconRendererTrophy32Svg.trophySvg() ─── THIS CONTRACT ─── Returns raw SVG                     │  ║
║  │          │                                                                                       │ ║
║  │          ├─► Icons32Data.data() ─── Retrieves symbol path data                                  │  ║
║  │          ├─► IconColorRegistry ─── Resolves color overrides                                     │  ║
║  │          ├─► TrophySvgAssets ─── BAF animation (if applicable)                                  │  ║
║  │          └─► DegenerusAffiliate ─── Referrer lookup for color cascade                           │  ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              TROPHY TYPES & RENDERING                                            │ ║
║  │                                                                                                  │ ║
║  │   EXTERMINATOR TROPHY                                                                            │ ║
║  │   ├─ Shows the eliminated trait symbol in center ring                                           │  ║
║  │   ├─ Ring color matches the trait's palette color                                               │  ║
║  │   ├─ May be inverted (negative filter) based on game state                                      │  ║
║  │   └─ Corner glyphs indicate trophy type                                                         │  ║
║  │                                                                                                  │ ║
║  │   AFFILIATE TROPHY                                                                               │ ║
║  │   ├─ Shows affiliate badge icon in center                                                       │  ║
║  │   ├─ Default blue ring (palette index 4)                                                        │  ║
║  │   ├─ Custom ring color via setTopAffiliateColor()                                               │  ║
║  │   └─ No corner glyphs (affiliate-specific styling)                                              │  ║
║  │                                                                                                  │ ║
║  │   BAF TROPHY                                                                                     │ ║
║  │   ├─ Shows animated coin flip (from TrophySvgAssets)                                            │  ║
║  │   ├─ Gold ring color (palette index 7)                                                          │  ║
║  │   └─ 6-second SMIL animation loop                                                               │  ║
║  │                                                                                                  │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              SVG STRUCTURE (120x120 viewBox centered at 0,0)                     │ ║
║  │                                                                                                  │ ║
║  │   <svg viewBox="-60 -60 120 120">                                                               │  ║
║  │     <defs>                                                                                       │ ║
║  │       <filter id="inv"> ─── Color inversion filter for highlighting                             │  ║
║  │     </defs>                                                                                      │ ║
║  │     <rect> ─── Outer rounded square (100x100, customizable fill/stroke)                         │  ║
║  │     <g> ─── Ring group (outer/middle/inner circles)                                             │  ║
║  │       <circle fill="ringColor"> ─── Outer colored ring                                          │  ║
║  │       <circle fill="bandColor"> ─── Middle dark band                                            │  ║
║  │       <circle fill="coreColor"> ─── Inner white core                                            │  ║
║  │     </g>                                                                                         │ ║
║  │     <g clip-path="..."> ─── Symbol clipped to inner circle                                      │  ║
║  │       <path> ─── The actual icon/symbol                                                         │  ║
║  │     </g>                                                                                         │ ║
║  │     <g> ─── Corner glyphs (exterminator only)                                                   │  ║
║  │   </svg>                                                                                         │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  SECURITY CONSIDERATIONS                                                                              ║
║  ───────────────────────                                                                              ║
║                                                                                                       ║
║  1. VIEW-ONLY                                                                                         ║
║     • trophySvg() is a view function - no state changes                                               ║
║     • Safe to call externally for off-chain metadata generation                                       ║
║                                                                                                       ║
║  2. EXTERNAL CALL SAFETY                                                                              ║
║     • All external calls are to trusted, constant addresses                                           ║
║     • ownerOf call wrapped in try/catch to handle burned tokens                                       ║
║     • No value transfers, no callbacks                                                                ║
║                                                                                                       ║
║  3. ACCESS CONTROL                                                                                    ║
║     • Constructor wiring via DeployConstants (no admin setters)                                       ║
║     • All other functions are view-only                                                               ║
║                                                                                                       ║
║  4. INPUT HANDLING                                                                                    ║
║     • SvgParams validated by caller (IconRendererTrophy32)                                            ║
║     • Sentinel values (0xFFFE, 0xFFFA) handled explicitly                                             ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  TRUST ASSUMPTIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. Icons32Data provides valid, safe SVG path data                                                    ║
║  2. TrophySvgAssets provides safe SVG animation markup                                                ║
║  3. IconColorRegistry returns validated hex color strings                                             ║
║  4. DegenerusAffiliate correctly reports referrer relationships                                       ║
║  5. DeployConstants provides correct NFT address at deployment                                        ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  GAS OPTIMIZATIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. All rendering is view-only (free for off-chain calls)                                             ║
║  2. Immutable addresses for dependencies (no SLOAD)                                                   ║
║  3. String concatenation via abi.encodePacked                                                         ║
║  4. Fixed-point math (1e6 scale) avoids floating point                                                ║
║  5. try/catch only where necessary (ownerOf for burned tokens)                                        ║
║                                                                                                       ║
╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝*/

import "@openzeppelin/contracts/utils/Strings.sol";
import {DeployConstants} from "./DeployConstants.sol";
import "./interfaces/IDegenerusAffiliate.sol";
import "./interfaces/IconRendererTypes.sol";
import {ITrophySvgAssets} from "./TrophySvgAssets.sol";
import {RendererLibrary} from "./libraries/RendererLibrary.sol";
import {ColorResolver} from "./libraries/ColorResolver.sol";

// ─────────────────────────────────────────────────────────────────────────────
// INTERFACE
// ─────────────────────────────────────────────────────────────────────────────

/// @title IIconRendererTrophy32Svg
/// @notice Interface for trophy SVG generation
/// @dev Called by IconRendererTrophy32 to generate the image portion of metadata
interface IIconRendererTrophy32Svg {
    /// @notice Parameters for trophy SVG generation
    struct SvgParams {
        uint256 tokenId;           // Trophy token ID
        uint16 exterminatedTrait;  // Trait ID (0-255) or sentinel (0xFFFE/0xFFFA)
        bool isAffiliate;          // True if affiliate trophy type
        bool isBaf;                // True if BAF trophy type
        uint24 lvl;                // Game level when trophy was earned
        bool invertFlag;           // Visual inversion flag from game
    }

    /// @notice Generate SVG image for a trophy token
    /// @param params Trophy parameters (tokenId, type, level, etc.)
    /// @return The complete SVG markup string
    function trophySvg(SvgParams calldata params) external view returns (string memory);
}

// ─────────────────────────────────────────────────────────────────────────────
// CONTRACT
// ─────────────────────────────────────────────────────────────────────────────

/// @title IconRendererTrophy32Svg
/// @notice SVG generation engine for Degenerus trophy tokens
/// @dev Generates SVG images based on trophy type (Exterminator, Affiliate, BAF)
contract IconRendererTrophy32Svg is IIconRendererTrophy32Svg, ColorResolver {
    using Strings for uint256;

    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Generic error for unauthorized access or invalid state
    error E();

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS & WIRING
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Icon path data source
    IIcons32 private constant icons = IIcons32(DeployConstants.ICONS_32);

    /// @dev Trophy SVG assets (BAF animation)
    ITrophySvgAssets private constant assets = ITrophySvgAssets(DeployConstants.TROPHY_SVG_ASSETS);

    /// @dev Trophy NFT contract
    IERC721Lite private constant nft = IERC721Lite(DeployConstants.TROPHIES);

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Sentinel value indicating BAF trophy type in trait field
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant BAF_FLIP_VB = 130;
    string private constant MAP_CORNER_TRANSFORM = "matrix(0.51 0 0 0.51 -6.12 -6.12)";
    string private constant FLAME_CORNER_TRANSFORM = "matrix(0.02810 0 0 0.02810 -12.03 -9.082)";
    uint32 private constant TOP_AFFILIATE_FIT_1e6 = (760_000 * 936) / 1_000;
    int256 private constant VIEWBOX_HEIGHT_1E6 = 120 * 1_000_000;
    int256 private constant TOP_AFFILIATE_SHIFT_DOWN_1E6 = 3_200_000;
    int256 private constant TOP_AFFILIATE_UPWARD_1E6 = (VIEWBOX_HEIGHT_1E6 * 4) / 100; // 4% of total height

    function trophySvg(SvgParams calldata params) external view override returns (string memory) {
        uint256 tokenId = params.tokenId;
        uint16 exterminatedTrait = params.exterminatedTrait;
        bool isAffiliate = params.isAffiliate;
        bool isBaf = params.isBaf;
        uint24 lvl = params.lvl;

        uint32 innerSide = _innerSquareSide();
        bool isExtermination = !isAffiliate && !isBaf;

        bool isTopAffiliate = isAffiliate && exterminatedTrait == 0xFFFE;
        bool isBafAward = isBaf && exterminatedTrait == BAF_TRAIT_SENTINEL;
        uint8 six = uint8(exterminatedTrait) & 0x3F;
        uint8 dataQ = uint8(exterminatedTrait) >> 6;
        if (isBafAward) {
            dataQ = 3;
            six = 0x38; // quadrant 3, color idx 7, symbol 0
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
            border = _resolveColorSafe(address(nft), tokenId, 0, ringOuterColor);
        } else {
            border = _resolveColorSafe(address(nft), tokenId, 0, _borderColor(tokenId, uint32(six), uint8(1) << colIdx, lvl));
        }

        string memory flameColor = _resolveColorSafe(address(nft), tokenId, 1, "#111");

        uint32 pct2 = registry.trophyOuter(address(nft), tokenId);
        uint32 rOut2 = (pct2 <= 1) ? 44 : uint32((uint256(innerSide) * pct2) / 2_000_000);
        uint32 rMid2 = uint32((uint256(rOut2) * RendererLibrary.RATIO_MID_1e6) / 1_000_000);
        uint32 rIn2 = uint32((uint256(rOut2) * RendererLibrary.RATIO_IN_1e6) / 1_000_000);
        if (isBafAward) {
            uint32 scale = 690_000;
            int256 center = int256(uint256(BAF_FLIP_VB) * uint256(scale)) / 2;
            int256 adjustX = 4_400_000; // shift right ~4.4px
            int256 adjustY = 2_600_000; // shift down ~2.6px
            int256 offsetX = -center + adjustX;
            int256 offsetY = -center + adjustY;
            string memory anim = string(
                abi.encodePacked("<g transform='", RendererLibrary.mat6(scale, offsetX, offsetY), "'>", assets.bafFlipSymbol(), "</g>")
            );

            return _composeSvg(RendererLibrary.svgHeader(border, _resolveColorSafe(address(nft), tokenId, 3, "#d9d9d9")), anim, isExtermination);
        }

        string memory iconPath;
        uint16 w;
        uint16 h;
        uint256 iconIndex = isTopAffiliate ? 32 : (uint256(dataQ) * 8 + uint256(symIdx));
        iconPath = icons.data(iconIndex);
        w = RendererLibrary.ICON_VB;
        h = RendererLibrary.ICON_VB;
        uint16 m = w > h ? w : h;
        if (m == 0) m = 1;

        uint32 fitSym1e6 = _symbolFitScale(isTopAffiliate, dataQ, symIdx);
        uint32 sSym1e6 = uint32((uint256(2) * rIn2 * fitSym1e6) / m);

        (int256 txm, int256 tyn) = _symbolTranslate(w, h, sSym1e6, isTopAffiliate);

        // Crypto quadrant symbols (dataQ == 0) should render with their native path colors,
        // not the ring color. Others stay tinted to the ring.
        string memory symbolGroup;
        if (dataQ == 0 && !isTopAffiliate) {
            symbolGroup = string(
                abi.encodePacked(
                    "<g transform='",
                    RendererLibrary.mat6(sSym1e6, txm, tyn),
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
                    RendererLibrary.mat6(sSym1e6, txm, tyn),
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
                RendererLibrary.rings(ringOuterColor, flameColor, _resolveColorSafe(address(nft), tokenId, 2, "#fff"), rOut2, rMid2, rIn2, 0, 0),
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

        return _composeSvg(RendererLibrary.svgHeader(border, _resolveColorSafe(address(nft), tokenId, 3, "#d9d9d9")), ringsAndSymbol, isExtermination);
    }


    function _cornerGlyph(string memory cornerTransform) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "<g transform='",
                    cornerTransform,
                    "'><path d='M13 21h-5.5l-1.5 7-1.5-7H-1V1h14z'/></g>"
                )
            );
    }

    function _composeSvg(
        string memory head,
        string memory inner,
        bool includeCorners
    ) private pure returns (string memory) {
        string memory corners = includeCorners
            ? string(abi.encodePacked(_cornerGlyph(MAP_CORNER_TRANSFORM), _cornerGlyph(FLAME_CORNER_TRANSFORM)))
            : "";
        return string(abi.encodePacked(head, inner, corners, RendererLibrary.svgFooter()));
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
        string memory ownerColor = _resolveColorSafe(address(nft), tokenId, 0, palette);
        if (bytes(ownerColor).length == 0) return palette;
        return ownerColor;
    }

    function _paletteColor(uint8 idx, uint24 level) private pure returns (string memory) {
        uint24 rgb = _paletteColorRGB(idx, level);
        return RendererLibrary.rgbToHex(rgb);
    }

    function _paletteColorRGB(uint8 idx, uint24 level) private pure returns (uint24) {
        uint24 rgb = RendererLibrary.paletteColorRGB(idx & 0x07);
        int16 delta = RendererLibrary.variantBias(idx & 0x07);
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


    function _innerSquareSide() private pure returns (uint32) {
        return 88;
    }



    function _symbolFitScale(bool isTopAffiliate, uint8 quadrant, uint8 symbolIdx) private pure returns (uint32) {
        if (isTopAffiliate) return TOP_AFFILIATE_FIT_1e6;
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
