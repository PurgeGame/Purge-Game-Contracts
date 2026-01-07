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
║     • All external calls are to trusted, immutable addresses                                          ║
║     • ownerOf call wrapped in try/catch to handle burned tokens                                       ║
║     • No value transfers, no callbacks                                                                ║
║                                                                                                       ║
║  3. ACCESS CONTROL                                                                                    ║
║     • wire() is onlyAdmin (one-time setup)                                                            ║
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
║  5. Admin wires correct NFT address during setup                                                      ║
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
import "./interfaces/IDegenerusAffiliate.sol";
import "./interfaces/IconRendererTypes.sol";
import {ITrophySvgAssets} from "./TrophySvgAssets.sol";

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

    /// @notice Wire the NFT contract address (one-time admin setup)
    /// @param addresses Array where addresses[0] is the trophy NFT contract
    function wire(address[] calldata addresses) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// CONTRACT
// ─────────────────────────────────────────────────────────────────────────────

/// @title IconRendererTrophy32Svg
/// @notice SVG generation engine for Degenerus trophy tokens
/// @dev Generates SVG images based on trophy type (Exterminator, Affiliate, BAF)
contract IconRendererTrophy32Svg is IIconRendererTrophy32Svg {
    using Strings for uint256;

    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Generic error for unauthorized access or invalid state
    error E();

    // ─────────────────────────────────────────────────────────────────────
    // IMMUTABLES & WIRING
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Affiliate program for referrer color cascade (optional)
    address private immutable affiliateProgram;

    /// @dev Icon path data source
    IIcons32 private immutable icons;

    /// @dev Color customization registry
    IColorRegistry private immutable registry;

    /// @dev Trophy SVG assets (BAF animation)
    ITrophySvgAssets private immutable assets;

    /// @dev Admin contract for wire() authorization
    address public immutable admin;

    /// @dev Trophy NFT contract (set once via wire())
    IERC721Lite private nft;

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Sentinel value indicating BAF trophy type in trait field
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant BAF_FLIP_VB = 130;
    uint24[8] private BASE_COLOR = [0xf409cd, 0x7c2bff, 0x30d100, 0xed0e11, 0x1317f7, 0xf7931a, 0x5e5e5e, 0xab8d3f];
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

    constructor(address icons_, address registry_, address assets_, address affiliate_, address admin_) {
        affiliateProgram = affiliate_;
        icons = IIcons32(icons_);
        registry = IColorRegistry(registry_);
        if (assets_ == address(0)) revert E();
        assets = ITrophySvgAssets(assets_);
        if (admin_ == address(0)) revert E();
        admin = admin_;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert E();
        _;
    }

    function wire(address[] calldata addresses) external override onlyAdmin {
        _setNft(addresses.length > 0 ? addresses[0] : address(0));
    }

    function _setNft(address nft_) private {
        if (nft_ == address(0)) return;
        address current = address(nft);
        if (current == address(0)) {
            nft = IERC721Lite(nft_);
        } else if (current != nft_) {
            revert E();
        }
    }

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

            return _composeSvg(_svgHeader(border, _resolve(tokenId, 3, "#d9d9d9")), anim, isExtermination);
        }

        string memory iconPath;
        uint16 w;
        uint16 h;
        uint256 iconIndex = isTopAffiliate ? 32 : (uint256(dataQ) * 8 + uint256(symIdx));
        iconPath = icons.data(iconIndex);
        w = ICON_VB;
        h = ICON_VB;
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

        return _composeSvg(_svgHeader(border, _resolve(tokenId, 3, "#d9d9d9")), ringsAndSymbol, isExtermination);
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
        address affiliate = affiliateProgram;
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
        return string(abi.encodePacked(head, inner, corners, _svgFooter()));
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
        buffer[2] = _hexChar(uint8((rgb >> 16) & 0x0f));
        buffer[3] = _hexChar(uint8((rgb >> 12) & 0x0f));
        buffer[4] = _hexChar(uint8((rgb >> 8) & 0x0f));
        buffer[5] = _hexChar(uint8((rgb >> 4) & 0x0f));
        buffer[6] = _hexChar(uint8(rgb & 0x0f));
        return string(buffer);
    }

    function _hexChar(uint8 nibble) private pure returns (bytes1) {
        return bytes1(nibble < 10 ? nibble + 0x30 : nibble + 0x57);
    }

    function _innerSquareSide() private pure returns (uint32) {
        return 88;
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
