// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
+=======================================================================================================+
|                                     IconRendererRegular32                                             |
|                    ERC721 Metadata & SVG Renderer for Degenerus Gamepieces                            |
+=======================================================================================================+
|                                                                                                       |
|  ARCHITECTURE OVERVIEW                                                                                |
|  ---------------------                                                                                |
|  IconRendererRegular32 is the primary renderer for Degenerus gamepiece tokens. It generates           |
|  complete ERC721 metadata including dynamically-rendered SVG images that reflect current game state.  |
|                                                                                                       |
|  +--------------------------------------------------------------------------------------------------+ |
|  |                              GAMEPIECE SVG LAYOUT                                                | |
|  |                                                                                                  | |
|  |   +---------------------------------------------------------------------+                       |  |
|  |   |                        Outer Square Frame                           |                       |  |
|  |   |                     (customizable border color)                     |                       |  |
|  |   |                                                                     |                       |  |
|  |   |   +-------------------+-------------------+                        |                       |   |
|  |   |   |                   |                   |                        |                       |   |
|  |   |   |   Q2 (Cards)      |   Q3 (Dice)      |                        |                       |    |
|  |   |   |   ◉ Ring+Symbol   |   ◉ Ring+Symbol  |                        |                       |    |
|  |   |   |                   |                   |                        |                       |   |
|  |   |   +-----------+◆◆◆◆◆◆+-------------------+                        |                       |    |
|  |   |   |           | FLAME|                   |                        |                       |    |
|  |   |   |   Q0      | ◆◆◆  |   Q1 (Zodiac)    |                        |                       |     |
|  |   |   |  (Crypto) |      |   ◉ Ring+Symbol  |                        |                       |     |
|  |   |   | ◉ Ring    |      |                   |                        |                       |    |
|  |   |   +-------------------+-------------------+                        |                       |   |
|  |   |                                                                     |                       |  |
|  |   +---------------------------------------------------------------------+                       |  |
|  |                                                                                                  | |
|  |   Each quadrant contains:                                                                        | |
|  |   • Outer ring: Quadrant's palette color (scarcity-scaled radius)                               |  |
|  |   • Middle ring: Dark (#111) contrast band                                                      |  |
|  |   • Inner ring: White (#fff) background for symbol                                              |  |
|  |   • Symbol: Quadrant-specific icon (Crypto/Zodiac/Cards/Dice)                                   |  |
|  +--------------------------------------------------------------------------------------------------+ |
|                                                                                                       |
|  +--------------------------------------------------------------------------------------------------+ |
|  |                              GAMEPIECE DATA LAYOUT (24-bit packed traits)                       |  |
|  |                                                                                                  | |
|  |   data parameter from DegenerusGamepieces:                                                      |  |
|  |   bits [0-5]:   Q0 trait (color*8 + symbol)                                                     |  |
|  |   bits [6-7]:   Q0 quadrant tag (0)                                                             |  |
|  |   bits [8-13]:  Q1 trait (color*8 + symbol)                                                     |  |
|  |   bits [14-15]: Q1 quadrant tag (1)                                                             |  |
|  |   bits [16-21]: Q2 trait (color*8 + symbol)                                                     |  |
|  |   bits [22-23]: Q2 quadrant tag (2)                                                             |  |
|  |   bits [24-29]: Q3 trait (color*8 + symbol)                                                     |  |
|  |   bits [30-31]: Q3 quadrant tag (3)                                                             |  |
|  |   bits [32-55]: Level (uint24)                                                                  |  |
|  |   bits [56-71]: Last exterminated trait (0..255 valid, 420 = none)                              |  |
|  +--------------------------------------------------------------------------------------------------+ |
|                                                                                                       |
|  +--------------------------------------------------------------------------------------------------+ |
|  |                              DYNAMIC FEATURES                                                    | |
|  |                                                                                                  | |
|  |   SCARCITY-BASED RING SIZE                                                                       | |
|  |   • Ring radius scales with trait scarcity                                                       | |
|  |   • More rare = larger ring (50% base → 100% when only 1 remains)                               |  |
|  |   • Calculated from startTraitRemaining() vs current remaining                                  |  |
|  |                                                                                                  | |
|  |   COLOR CUSTOMIZATION CASCADE                                                                    | |
|  |   • Per-token override (from registry)                                                          |  |
|  |   • → Owner default (from registry)                                                             |  |
|  |   • → Referrer default (from affiliate program + registry)                                      |  |
|  |   • → Upline default (referrer's referrer)                                                      |  |
|  |   • → Theme default (hardcoded in renderer)                                                     |  |
|  |                                                                                                  | |
|  |   EXTERMINATION HIGHLIGHTING                                                                     | |
|  |   • When a trait was just exterminated, that quadrant is inverted                               |  |
|  |   • Level 90 special case: all traits EXCEPT the exterminated one are inverted                  |  |
|  |   • Uses SVG filter for color inversion effect                                                  |  |
|  |                                                                                                  | |
|  |   LEVEL-BASED COLOR VARIATION                                                                    | |
|  |   • Base palette colors shift slightly based on level cycle (0-9)                               |  |
|  |   • Creates visual variety across levels while maintaining recognizability                      |  |
|  +--------------------------------------------------------------------------------------------------+ |
|                                                                                                       |
+=======================================================================================================+*/

import "@openzeppelin/contracts/utils/Base64.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import {ContractAddresses} from "./ContractAddresses.sol";
import "./interfaces/IconRendererTypes.sol";
import {RendererLibrary} from "./libraries/RendererLibrary.sol";
import {ColorResolver} from "./libraries/ColorResolver.sol";

// -----------------------------------------------------------------------------
// EXTERNAL INTERFACE
// -----------------------------------------------------------------------------

/// @notice Interface to read initial trait supply from game contract
/// @dev Used to calculate scarcity-based ring sizes
interface IDegenerusGameStartRemaining {
    /// @notice Get the starting "remaining" count for a trait
    /// @param traitId The trait ID (0-255)
    /// @return The initial remaining count for this trait
    function startTraitRemaining(uint8 traitId) external view returns (uint32);
}

// -----------------------------------------------------------------------------
// CONTRACT
// -----------------------------------------------------------------------------

/// @title IconRendererRegular32
/// @notice ERC721 metadata and SVG renderer for Degenerus gamepiece tokens
/// @dev Generates dynamic SVG images based on game state, scarcity, and color preferences
contract IconRendererRegular32 is ColorResolver {
    using Strings for uint256;

    // ---------------------------------------------------------------------
    // CONSTANTS & WIRING
    // ---------------------------------------------------------------------

    /// @dev Icon path and symbol name data source
    IIcons32 internal constant icons = IIcons32(ContractAddresses.ICONS_32);

    /// @dev Game contract for initial trait counts
    IDegenerusGameStartRemaining internal constant game = IDegenerusGameStartRemaining(ContractAddresses.GAME);

    /// @dev Gamepiece ERC721 contract
    IERC721Lite internal constant nft = IERC721Lite(ContractAddresses.GAMEPIECES);

    // ---------------------------------------------------------------------
    // User defaults
    // ---------------------------------------------------------------------

    /// @notice Save caller’s default color overrides. Pass "" to clear a channel.
    /// @dev Each value must be lowercase "#rrggbb" or empty string.
    function setMyColors(
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external returns (bool) {
        return registry.setMyColors(msg.sender, outlineHex, flameHex, diamondHex, squareHex);
    }

    // ---------------------------------------------------------------------
    // Per‑token overrides (batch)
    // ---------------------------------------------------------------------

    /// @notice Batch set the same per‑token color overrides for many tokenIds.
    /// @dev
    /// - Caller must own each tokenId in `nft`.
    /// - No explicit batch size limit; bounded by gas.
    /// - Pass "" for a channel to clear it on each token.
    function setCustomColorsForMany(
        uint256[] calldata tokenIds,
        string calldata outlineHex, // "" to clear
        string calldata flameHex, // "" to clear
        string calldata diamondHex, // "" to clear
        string calldata squareHex // "" to clear
    ) external returns (bool) {
        return
            registry.setCustomColorsForMany(
                msg.sender,
                ContractAddresses.GAMEPIECES,
                tokenIds,
                outlineHex,
                flameHex,
                diamondHex,
                squareHex,
                0
            );
    }

    // ---------------------------------------------------------------------
    // Palette & geometry
    // ---------------------------------------------------------------------

    // Layout tuning (1e6 fixed‑point).
    uint32 private constant SYM_FIT_BASE_1e6 = 750_000;
    uint32 private constant GLOBAL_BADGE_BOOST_1e6 = 1_010_000;

    // Quadrant offsets.
    int16 private constant CX_LEFT = -25;
    int16 private constant CX_RIGHT = 25;
    int16 private constant CY_TOP = -25;
    int16 private constant CY_BOTTOM = 25;

    // ---------------------------------------------------------------------
    // Trait baselines
    // ---------------------------------------------------------------------

    // ---------------------------------------------------------------------
    // Metadata helpers
    // ---------------------------------------------------------------------

    /// @notice Render metadata + image for a Degenerus token.
    /// @param tokenId   NFT id.
    /// @param data      Packed game data:
    ///                  - Regular: bits [63:48] last exterminated trait (0..255 or 420 sentinel),
    ///                             bits [47:24] level, bits [23:00] packed traits.
    /// @param remaining Live remaining counts for this token’s four traits (regular only).
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory) {
        if (tokenId == 0) {
            return _genesisTokenURI();
        }
        if ((data >> 128) != 0) revert("renderer:trophy-data");

        uint24 lvl = uint24((data >> 32) & 0xFFFFFF);
        uint16 lastEx = uint16((data >> 56) & 0xFFFF); // 0..255 valid; 420 = sentinel “none”
        uint32 traits = uint32(data);

        (uint8[4] memory col, uint8[4] memory sym) = _decodeTraits(traits);
        string memory img2 = _svgFull(tokenId, traits, col, sym, remaining, lastEx, lvl);
        string memory desc2 = _descFromRem(col, sym, remaining);

        string memory levelStr = (lvl == 0) ? "TBD" : uint256(lvl).toString();
        string memory attrs = string(
            abi.encodePacked(
                '[{"trait_type":"',
                RendererLibrary.quadrantTitle(0),
                '","value":"',
                _label(0, col[0], sym[0]),
                '"},{"trait_type":"',
                RendererLibrary.quadrantTitle(1),
                '","value":"',
                _label(1, col[1], sym[1]),
                '"},{"trait_type":"',
                RendererLibrary.quadrantTitle(2),
                '","value":"',
                _label(2, col[2], sym[2]),
                '"},{"trait_type":"',
                RendererLibrary.quadrantTitle(3),
                '","value":"',
                _label(3, col[3], sym[3]),
                '"},{"trait_type":"Level","value":"',
                levelStr,
                '"}]'
            )
        );

        return _pack(tokenId, img2, lvl, desc2, attrs);
    }

    function _genesisTokenURI() private view returns (string memory) {
        string memory imgData = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(_genesisTrophySvg()))
        );

        string memory j = string.concat(
            '{"name":"Degenerus Genesis Token","description":"A cosmetic token locked to the creator\'s vault.","image":"',
            imgData
        );
        j = string.concat(j, '"}');

        return string.concat("data:application/json;base64,", Base64.encode(bytes(j)));
    }

    function _genesisTrophySvg() private view returns (string memory) {
        string memory flamePath = icons.diamond();
        return
            string(
                abi.encodePacked(
                    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 512 512'>",
                    "<defs><clipPath id='flame-clip'><circle cx='0' cy='0' r='27'/></clipPath>",
                    "<symbol id='flame-icon' viewBox='-60 -60 120 120'><g clip-path='url(#flame-clip)'>",
                    "<path fill='#ff3300' transform='matrix(0.13 0 0 0.13 -56 -41)' d='",
                    flamePath,
                    "'/></g></symbol></defs>",
                    "<rect width='512' height='512' rx='64' fill='#30d100'/>",
                    "<rect x='16' y='16' width='480' height='480' rx='48' fill='#cccccc'/>",
                    "<circle cx='256' cy='256' r='180' fill='#30d100'/>",
                    "<circle cx='256' cy='256' r='140' fill='#111111'/>",
                    "<circle cx='256' cy='256' r='115' fill='#ffffff'/>",
                    "<use href='#flame-icon' x='156' y='156' width='200' height='200'/>",
                    "</svg>"
                )
            );
    }

    /// @dev Compose the full SVG for a regular token.
    /// @param tokenId      NFT id.
    /// @param traitsPacked Packed 4×6‑bit traits (low→high).
    /// @param col          Color indices per quadrant (0..7).
    /// @param sym          Symbol indices per quadrant (0..7).
    /// @param remaining    Live remaining counts for the four traits (Q0..Q3).
    /// @param lastEx       Last level’s exterminated trait (0..255) or 420 sentinel.
    function _svgFull(
        uint256 tokenId,
        uint32 traitsPacked,
        uint8[4] memory col,
        uint8[4] memory sym,
        uint32[4] calldata remaining,
        uint16 lastEx,
        uint24 level
    ) private view returns (string memory out) {
        // Resolve palette (owner/custom overrides cascade inside `_resolveColor`)
        string memory borderColor0 = _borderColor(tokenId, traitsPacked, col, level);
        string memory borderColor = _resolveColor(ContractAddresses.GAMEPIECES, tokenId, 0, borderColor0);
        string memory diamondFill = _resolveColor(ContractAddresses.GAMEPIECES, tokenId, 2, "#fff");
        string memory flameFill = _resolveColor(ContractAddresses.GAMEPIECES, tokenId, 1, "#111");
        string memory squareFill = _resolveColor(ContractAddresses.GAMEPIECES, tokenId, 3, "#d9d9d9");

        // Frame + guides
        out = RendererLibrary.svgHeader(borderColor, squareFill);
        string memory diamondPath = icons.diamond();
        out = string.concat(out, _guides(borderColor, diamondFill, flameFill, diamondPath));

        // Quadrant remap (visual layout): BL←Q2, BR←Q3, TL←Q0, TR←Q1
        out = string.concat(out, _svgQuad(0, 2, col[2], sym[2], remaining[2], lastEx, level)); // BL
        out = string.concat(out, _svgQuad(1, 3, col[3], sym[3], remaining[3], lastEx, level)); // BR
        out = string.concat(out, _svgQuad(2, 0, col[0], sym[0], remaining[0], lastEx, level)); // TL
        out = string.concat(out, _svgQuad(3, 1, col[1], sym[1], remaining[1], lastEx, level)); // TR

        out = string.concat(out, RendererLibrary.svgFooter());
    }

    /// @notice Render a single quadrant (rings + symbol), with optional per‑quadrant invert when it
    ///         matches the last exterminated trait.
    function _svgQuad(
        uint256 quadPos,
        uint256 quadId,
        uint8 colorIndex,
        uint8 symbolIndex,
        uint32 liveRemaining,
        uint16 lastExterminated,
        uint24 level
    ) private view returns (string memory) {
        // Trait id in the 0..255 namespace for (quadId, colorIndex, symbolIndex)
        uint8 traitId = _traitId(uint8(quadId), colorIndex, symbolIndex);

        // Highlight by inversion when this trait was exterminated last level.
        bool levelNinety = level == 90;
        bool highlightInvert;
        if (levelNinety) {
            // On level 90, invert every trait except the actual last exterminated (if present).
            if (lastExterminated != 420 && lastExterminated <= 255) {
                highlightInvert = traitId != uint8(lastExterminated);
            } else {
                highlightInvert = true;
            }
        } else {
            highlightInvert =
                (lastExterminated != 420 && lastExterminated <= 255 && traitId == uint8(lastExterminated));
        }

        // Radius computation: derive scarcity‑scaled outer/mid/inner radii
        uint32 rMax = _rMaxAt(quadPos);
        uint32 startRem = _startFor(quadId, colorIndex, symbolIndex);
        uint32 currRem = (liveRemaining == 0) ? 1 : (liveRemaining > startRem ? startRem : liveRemaining);
        uint32 scarcity1e6 = _scarcityFactor1e6(startRem, currRem);

        uint32 rOuter = uint32((uint256(rMax) * scarcity1e6) / 1_000_000);
        rOuter = uint32((uint256(rOuter) * GLOBAL_BADGE_BOOST_1e6) / 1_000_000);
        uint32 rMiddle = uint32((uint256(rOuter) * RendererLibrary.RATIO_MID_1e6) / 1_000_000);
        uint32 rInner = uint32((uint256(rOuter) * RendererLibrary.RATIO_IN_1e6) / 1_000_000);

        // Concentric rings
        string memory colorHex = _paletteColor(colorIndex, level);
        string memory ringsSvg = RendererLibrary.rings(
            colorHex,
            "#111",
            "#fff",
            rOuter,
            rMiddle,
            rInner,
            _cx(quadPos),
            _cy(quadPos)
        );

        // Symbol path selection (32 icons total: quadId*8 + symbolIndex)
        uint256 iconIndex = quadId * 8 + symbolIndex;
        string memory iconPath = icons.data(iconIndex);
        // Fit symbol into inner ring, scaled in 1e6 "micro‑units"
        uint32 fit1e6 = _symbolFit1e6(quadId, symbolIndex);
        uint32 scale1e6 = uint32((uint256(2) * rInner * fit1e6) / RendererLibrary.ICON_VB);

        // Place symbol centered at quadrant origin in micro‑space
        int256 cxMicro = int256(int32(_cx(quadPos))) * 1_000_000;
        int256 cyMicro = int256(int32(_cy(quadPos))) * 1_000_000;
        int256 txMicro = cxMicro - (int256(uint256(RendererLibrary.ICON_VB)) * int256(uint256(scale1e6))) / 2;
        int256 tyMicro = cyMicro - (int256(uint256(RendererLibrary.ICON_VB)) * int256(uint256(scale1e6))) / 2;

        // Color the symbol: Q0 uses source path colors; others use the quadrant color
        string memory symbolSvg = (quadId == 0)
            ? string(
                abi.encodePacked(
                    '<g transform="',
                    RendererLibrary.mat6(scale1e6, txMicro, tyMicro),
                    '"><g style="vector-effect:non-scaling-stroke">',
                    iconPath,
                    "</g></g>"
                )
            )
            : string(
                abi.encodePacked(
                    '<g transform="',
                    RendererLibrary.mat6(scale1e6, txMicro, tyMicro),
                    '"><g fill="',
                    colorHex,
                    '" stroke="',
                    colorHex,
                    '" style="vector-effect:non-scaling-stroke">',
                    iconPath,
                    "</g></g>"
                )
            );

        // Optional per‑quadrant invert wrapper (used to “spotlight” the last exterminated trait)
        if (highlightInvert) {
            return string(abi.encodePacked('<g filter="url(#inv)">', ringsSvg, symbolSvg, "</g>"));
        }
        return string(abi.encodePacked(ringsSvg, symbolSvg));
    }

    /// @notice Human label for a symbol index within a quadrant.
    /// @dev Q0..Q2 use named sets; Q3 is dice 1..8.
    function _symTitle(uint256 quadId, uint8 symbolIndex) private view returns (string memory) {
        if (quadId < 3) {
            string memory externalName = icons.symbol(quadId, symbolIndex);
            if (bytes(externalName).length != 0) {
                return externalName;
            }
            return string.concat("Symbol ", (uint256(symbolIndex) + 1).toString());
        }

        return (uint256(symbolIndex) + 1).toString();
    }

    /// @notice Color + symbol label (e.g., "Blue Diamond").
    function _label(uint256 quadId, uint8 colorIndex, uint8 symbolIndex) private view returns (string memory) {
        string memory symTitle = _symTitle(quadId, symbolIndex);
        return string(abi.encodePacked(RendererLibrary.colorTitle(colorIndex), " ", symTitle));
    }


    /// @notice Build a 4‑line description showing remaining counts per quadrant.
    function _descFromRem(
        uint8[4] memory col,
        uint8[4] memory sym,
        uint32[4] calldata rem
    ) private view returns (string memory) {
        return
            string(
                abi.encodePacked(
                    _label(0, col[0], sym[0]),
                    " : ",
                    uint256(rem[0]).toString(),
                    " remaining\\n",
                    _label(1, col[1], sym[1]),
                    " : ",
                    uint256(rem[1]).toString(),
                    " remaining\\n",
                    _label(2, col[2], sym[2]),
                    " : ",
                    uint256(rem[2]).toString(),
                    " remaining\\n",
                    _label(3, col[3], sym[3]),
                    " : ",
                    uint256(rem[3]).toString(),
                    " remaining"
                )
            );
    }


    /**
     * @dev Draw guides + central diamond/flame motif (shared by regular and genesis SVGs).
     */
    function _guides(
        string memory borderColor,
        string memory diamondFill,
        string memory flameColor,
        string memory diamondPath
    ) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '<g stroke="',
                    borderColor,
                    '" stroke-width="1" fill="none" opacity="1">',
                    '<line x1="0" y1="-50" x2="0" y2="50"/>',
                    '<line x1="-50" y1="0" x2="50" y2="0"/>',
                    "</g>",
                    '<path d="M0,15.5 L15.5,0 0,-15.5 -15.5,0 Z" fill="',
                    diamondFill,
                    '" stroke="',
                    borderColor,
                    '" stroke-width="1"/>',
                    _flameDiamond(flameColor, diamondPath)
                )
            );
    }

    /**
     * @dev Flame path clipped to the diamond.
     */
    function _flameDiamond(string memory flameFill, string memory diamondPath) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '<defs><clipPath id="cd"><path d="M0,15.5 L15.5,0 0,-15.5 -15.5,0 Z"/></clipPath></defs>',
                    '<g clip-path="url(#cd)"><g transform="translate(-1.596,-1.664) scale(2)">',
                    '<path fill="',
                    flameFill,
                    '" transform="matrix(0.027 0 0 0.027 -10.8 -8.10945)" d="',
                    diamondPath,
                    '"/>',
                    "</g></g>"
                )
            );
    }


    // ---------------- JSON pack ----------------------------------------------------------------------

    /**
     * @dev Build ERC‑721 metadata as data:application/json;base64 with an embedded
     *      data:image/svg+xml;base64 image.
     */
    function _pack(
        uint256 tokenId,
        string memory svg,
        uint256 level,
        string memory desc,
        string memory attrs
    ) private pure returns (string memory) {
        string memory lvlStr = (level == 0) ? "TBD" : level.toString();
        string memory nm = string.concat("Degenerus Level ", lvlStr, " #", tokenId.toString());

        // Image: inline SVG → base64 data URL
        string memory imgData = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        // Return as data:application/json;base64
        string memory j = string.concat('{"name":"', nm);
        j = string.concat(j, '","description":"', desc);
        j = string.concat(j, '","image":"', imgData, '","attributes":');
        j = string.concat(j, attrs, "}");
        return string.concat("data:application/json;base64,", Base64.encode(bytes(j)));
    }

    // ---------------- Helpers ------------------------------------------------------------------------

    /// @dev Compose a global 0..255 trait id.
    function _traitId(uint8 dataQ, uint8 colIdx, uint8 symIdx) private pure returns (uint8) {
        return ((colIdx << 3) | symIdx) + (dataQ << 6);
    }

    /// @dev Read the starting “remaining” supply for the trait bucket.
    function _startFor(uint256 dataQ, uint8 colIdx, uint8 symIdx) private view returns (uint32) {
        return game.startTraitRemaining(_traitId(uint8(dataQ), colIdx, symIdx));
    }

    /// @dev Map current remaining vs initial remaining into a 1e6‑scaled ring size factor.
    function _scarcityFactor1e6(uint32 start, uint32 curr) private pure returns (uint32) {
        if (start <= 1) return 1_000_000;
        if (curr == 0) curr = 1;
        if (curr > start) curr = start;
        uint256 add = (uint256(500_000) * (start - curr)) / (start - 1);
        return uint32(500_000 + add);
    }


    // ---------------- Geometry / layout helpers ------------------------------------------------------

    /**
     * @dev Maximum outer ring radius for a quadrant “pos” given fixed square bounds (±50),
     *      clamped to 24 to preserve spacing relative to guides and center glyph.
     */
    function _rMaxAt(uint256 pos) private view returns (uint32) {
        int32 cx = int32(_cx(pos));
        int32 cy = int32(_cy(pos));

        // Distance to vertical centerline and to outer square border on Y
        uint32 dx = uint32(cx < 0 ? -cx : cx);
        uint32 dyEdge = uint32(50 - (cy < 0 ? -cy : cy));

        // Limit by the tighter of the two, then clamp hard to 24
        uint32 r = dx < dyEdge ? dx : dyEdge;
        if (r > 24) r = 24;
        return r;
    }

    function _cx(uint256 pos) private pure returns (int16) {
        return (pos & 1) == 0 ? CX_LEFT : CX_RIGHT;
    }

    function _cy(uint256 pos) private pure returns (int16) {
        return pos < 2 ? CY_BOTTOM : CY_TOP;
    }

    /**
     * @dev Per‑icon scaling tweaks (1e6‑scaled) to visually normalize symbol sizes across the set.
     */
    function _symbolFit1e6(uint256 dataQ, uint8 symIdx) private pure returns (uint32) {
        uint32 f = (SYM_FIT_BASE_1e6 * 95) / 100; // default: 95% of base fit
        if (dataQ == 1 && symIdx == 6) {
            // TR / Sagittarius
            f = uint32((uint256(f) * 722_500) / 1_000_000);
        } else if (dataQ == 2 && symIdx == 7) {
            // BL / Ace
            f = uint32((uint256(f) * 130_000) / 100_000);
        } else if (dataQ == 3 && (symIdx == 6 || symIdx == 7)) {
            // BR / dice 7/8
            f = uint32((uint256(f) * 110_000) / 100_000);
        } else if (dataQ == 0 && symIdx == 6) {
            // TL / Ethereum
            f = uint32((uint256(f) * 110_000) / 100_000);
        } else if (dataQ == 2 && symIdx == 5) {
            // BL / Heart
            f = uint32((uint256(f) * 95_000) / 100_000);
        } else if (dataQ == 0 && (symIdx == 3 || symIdx == 7)) {
            // TL / Monero or Bitcoin: allow full fit
            f = 1_000_000;
        }
        return f;
    }


    // ---------------- Palette / trait helpers --------------------------------------------------------

    /**
     * @dev Choose a border color different from the 4 used quadrant colors.
     *      Starts from a deterministic index (tokenId,traits hash) and scans forward.
     */
    function _borderColor(
        uint256 tokenId,
        uint32 traits,
        uint8[4] memory used,
        uint24 level
    ) private view returns (string memory) {
        uint8 initial = uint8(uint256(keccak256(abi.encodePacked(tokenId, traits))) % 8);

        for (uint8 i; i < 8; ) {
            uint8 idx;
            unchecked {
                idx = uint8(initial + i) & 7;
            }

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
        // Fallback: should be unreachable (8 palette entries, 4 used)
        return _paletteColor(0, level);
    }

    function _paletteColor(uint8 idx, uint24 level) private pure returns (string memory) {
        uint24 rgb = _paletteColorRGB(idx, level);
        return RendererLibrary.rgbToHex(rgb);
    }

    function _paletteColorRGB(uint8 idx, uint24 level) private pure returns (uint24) {
        uint24 cycle = level % 10;
        uint24 base = RendererLibrary.paletteColorRGB(idx);
        uint8 r = uint8(base >> 16);
        uint8 g = uint8(base >> 8);
        uint8 b = uint8(base);

        int16 bias = RendererLibrary.variantBias(idx);
        uint256 seed = uint256(keccak256(abi.encodePacked(cycle, idx)));
        int16 jitter = int16(int8(uint8(seed & 0x1F))) - 16; // -16 .. +15
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

    /**
     * @dev Decode 24‑bit packed traits (4×8‑bit) into color and symbol indices per quadrant.
     *      For each quadrant q: v = (traits >> (q*8)) & 0x3F; col = v>>3; sym = v&7.
     */
    function _decodeTraits(uint32 t) private pure returns (uint8[4] memory col, uint8[4] memory sym) {
        unchecked {
            for (uint256 q; q < 4; ) {
                uint8 v = uint8((t >> (q * 8)) & 0x3F); // strip quadrant tag (64/128/192)
                col[q] = v >> 3;
                sym[q] = v & 0x07;
                ++q;
            }
        }
    }
}
