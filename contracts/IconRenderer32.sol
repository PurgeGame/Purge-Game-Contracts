// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

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

    function tokenColor(
        uint256 tokenId,
        uint8 channel
    ) external view returns (string memory);
    function addressColor(
        address user,
        uint8 channel
    ) external view returns (string memory);
    function trophyOuter(uint256 tokenId) external view returns (uint32);
}

/// @notice Minimal ERC-721 surface for ownership checks.
interface IERC721Lite {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Read-only aux interface (e.g., for referral lookups in labels/traits).
interface IPurgedRead {
    function getReferrer(address user) external view returns (address);
}

/**
 * @title IconRenderer32
 * @notice Stateless(ish) SVG renderer with per-token and per-address color overrides.
 * @dev
 * - Reads color overrides from an external registry (per-token or per-address fallback).
 * - Enforces strict `#rrggbb` lowercase format via the registry when overrides are set.
 * - Without overrides, consumers fall back to palette indices elsewhere.
 */
contract IconRenderer32 {
    using Strings for uint256;

    uint256 private constant MAP_TROPHY_FLAG = uint256(1) << 200;
    string private constant MAP_BADGE_PATH =
        "M14.3675 2.15671C14.7781 2.01987 15.2219 2.01987 15.6325 2.15671L20.6325 3.82338C21.4491 4.09561 22 4.85988 22 5.72074V19.6126C22 20.9777 20.6626 21.9416 19.3675 21.5099L15 20.0541L9.63246 21.8433C9.22192 21.9801 8.77808 21.9801 8.36754 21.8433L3.36754 20.1766C2.55086 19.9044 2 19.1401 2 18.2792V4.38741C2 3.0223 3.33739 2.05836 4.63246 2.49004L9 3.94589L14.3675 2.15671ZM15 4.05408L9.63246 5.84326C9.22192 5.9801 8.77808 5.9801 8.36754 5.84326L4 4.38741V18.2792L9 19.9459L14.3675 18.1567C14.7781 18.0199 15.2219 18.0199 15.6325 18.1567L20 19.6126V5.72074L15 4.05408ZM13.2929 8.29288C13.6834 7.90235 14.3166 7.90235 14.7071 8.29288L15.5 9.08577L16.2929 8.29288C16.6834 7.90235 17.3166 7.90235 17.7071 8.29288C18.0976 8.6834 18.0976 9.31657 17.7071 9.70709L16.9142 10.5L17.7071 11.2929C18.0976 11.6834 18.0976 12.3166 17.7071 12.7071C17.3166 13.0976 16.6834 13.0976 16.2929 12.7071L15.5 11.9142L14.7071 12.7071C14.3166 13.0976 13.6834 13.0976 13.2929 12.7071C12.9024 12.3166 12.9024 11.6834 13.2929 11.2929L14.0858 10.5L13.2929 9.70709C12.9024 9.31657 12.9024 8.6834 13.2929 8.29288ZM6 16C6.55228 16 7 15.5523 7 15C7 14.4477 6.55228 14 6 14C5.44772 14 5 14.4477 5 15C5 15.5523 5.44772 16 6 16ZM9 12C9 12.5523 8.55228 13 8 13C7.44772 13 7 12.5523 7 12C7 11.4477 7.44772 11 8 11C8.55228 11 9 11.4477 9 12ZM11 12C11.5523 12 12 11.5523 12 11C12 10.4477 11.5523 9.99998 11 9.99998C10.4477 9.99998 10 10.4477 10 11C10 11.5523 10.4477 12 11 12Z";

    // ---------------- Storage ----------------

    IPurgedRead private immutable coin; // PURGE ERC20 implementing IPurgedRead (getReferrer)
    IIcons32 private immutable icons; // External icon data source
    IColorRegistry private immutable registry; // Color override store

    /// @dev Generic guard.
    error E();

    constructor(address coin_, address icons_, address registry_) {
        coin = IPurgedRead(coin_);
        icons = IIcons32(icons_);
        registry = IColorRegistry(registry_);
    }

    // ---------------- Metadata helpers ----------------

    /// @notice Human‑readable color family titles for palette indices 0..7.
    /// @dev Falls back to "Gold" for out‑of‑range values.
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

    // ---------------- Validation ----------------

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
        return
            registry.setMyColors(
                msg.sender,
                outlineHex,
                flameHex,
                diamondHex,
                squareHex
            );
    }

    // ---------------------------------------------------------------------
    // Per‑token overrides (batch)
    // ---------------------------------------------------------------------

    /// @notice Batch set the same per‑token color overrides for many tokenIds.
    /// @dev
    /// - Max 150 tokenIds per call (reverts with "renderer:max150" if exceeded).
    /// - Caller must own each tokenId in `game`.
    /// - Pass "" for a channel to clear it on each token.
    function setCustomColorsForMany(
        uint256[] calldata tokenIds,
        string calldata outlineHex, // "" to clear
        string calldata flameHex, // "" to clear
        string calldata diamondHex, // "" to clear
        string calldata squareHex // "" to clear
    ) external returns (bool) {
        // Delegate to overload with no trophy size change.
        return
            setCustomColorsForMany(
                tokenIds,
                outlineHex,
                flameHex,
                diamondHex,
                squareHex,
                /*trophyOuterPct1e6=*/ 0
            );
    }

    /// @notice Batch set per‑token color overrides AND trophy badge size.
    /// @dev
    /// - `trophyOuterPct1e6`: 0 = leave size unchanged; 1 = reset to default per trophy type;
    ///                         else clamp-checked in [50_000..1_000_000] (5%..100% of inner side).
    function setCustomColorsForMany(
        uint256[] calldata tokenIds,
        string calldata outlineHex, // "" to clear
        string calldata flameHex, // "" to clear
        string calldata diamondHex, // "" to clear
        string calldata squareHex, // "" to clear
        uint32 trophyOuterPct1e6
    ) public returns (bool) {
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

    // ---------------------------------------------------------------------
    // Color resolution: token → per‑token override → owner default → referrer/upline default → fallback
    // ---------------------------------------------------------------------

    /// @notice Resolve a channel color for `tokenId`, falling back across owner, referrer, upline, or `defColor`.
    /// @param tokenId  Token to render.
    /// @param k        Channel index: 0=outline, 1=flame, 2=diamond, 3=square.
    /// @param defColor Final fallback color (e.g., theme default).
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

    // ---------------------------------------------------------------------
    // Palette & geometry
    // ---------------------------------------------------------------------

    // Canonical palette (indexed 0..7). Stored intentionally (non‑zero) for direct lookup.
    string[8] private COLOR_HEX = [
        "#f409cd",
        "#7c2bff",
        "#30d100",
        "#ed0e11",
        "#1317f7",
        "#f7931a",
        "#5e5e5e",
        "#ab8d3f"
    ];

    // Layout tuning (1e6 fixed‑point).
    uint32 private constant RATIO_MID_1e6 = 780_000;
    uint32 private constant RATIO_IN_1e6 = 620_000;
    uint32 private constant SYM_FIT_BASE_1e6 = 750_000;
    uint32 private constant GLOBAL_BADGE_BOOST_1e6 = 1_010_000;

    // Quadrant offsets.
    int16[4] private CX = [int16(-25), int16(25), int16(-25), int16(25)];
    int16[4] private CY = [int16(25), int16(25), int16(-25), int16(-25)];

    // Trait‑remaining snapshot (set by game at epoch start).
    uint32[256] private startTR;

    // Linked contracts (set once).
    address private game; // PurgeGame contract (authorised caller)
    IERC721Lite private nft; // PurgeGameNFT ERC721 contract

    // --- Square geometry (for trophy sizing vs inner side) -----------------
    uint32 private constant SQUARE_SIDE_100 = 100; // <rect width/height>
    uint32 private constant BORDER_STROKE_W = 2; // stroke-width in _svgHeader()

    /// @dev Inner usable side length (inside the stroke).
    function _innerSquareSide() private pure returns (uint32) {
        return SQUARE_SIDE_100 - BORDER_STROKE_W; // 98 with current header
    }

    // ---------------------------------------------------------------------
    // Game wiring & trait baselines
    // ---------------------------------------------------------------------

    /// @dev Restrict to the PurgeGame contract once linked.
    modifier onlyGame() {
        if (msg.sender != game) revert E();
        _;
    }

    /// @notice Wire both the game controller and ERC721 contract in a single call.
    /// @dev Callable only by the PURGE coin contract. Allows sequencing by wiring game first, then NFT.
    function wireContracts(address game_, address nft_) external {
        if (msg.sender != address(coin)) revert E();
        game = game_;
        nft = IERC721Lite(nft_);
    }

    /// @notice Capture the starting trait‑remaining snapshot for the new epoch.
    /// @dev Writes 256 slots; intended to be called once per level by the game.
    function setStartingTraitRemaining(
        uint32[256] calldata values
    ) external onlyGame {
        for (uint256 i; i < 256; ) {
            startTR[i] = values[i];
            unchecked {
                ++i;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Owner lookup (robust)
    // ---------------------------------------------------------------------

    // ---------------------------------------------------------------------
    // Trophy helpers
    // ---------------------------------------------------------------------

    /// @dev Read the exterminated trait from a packed trophy `data` word.
    ///      Bits [167:152] hold: 0xFFFF for placeholder (unwon), else uint8 trait id.
    ///      Bit 200 is reserved for MAP trophies (1 = MAP, 0 = level trophy).
    function _readExterminatedTrait(
        uint256 data
    ) private pure returns (uint16) {
        uint16 ex16 = uint16((data >> 152) & 0xFFFF);
        if (ex16 == 0xFFFF) return 0xFFFF; // placeholder/unwon trophy
        return uint16(uint8(ex16)); // normalize to 0..255 for won trophies
    }

    /// @notice Render metadata + image for a PURGE token (regular or trophy).
    /// @param tokenId   NFT id.
    /// @param data      Packed game data:
    ///                  - Trophy: bits [167:152] exterminated trait (0xFFFF = placeholder), bits [151:128] level, bit 200 = MAP flag.
    ///                  - Regular: bits [63:48] last exterminated trait (0..255 or 420 sentinel),
    ///                             bits [47:24] level, bits [23:00] packed traits.
    /// @param remaining Live remaining counts for this token’s four traits (regular only).
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory) {
        uint24 lvl;

        // ----- Trophy path: presence of bits above 128 indicates trophy layout -----
        if ((data >> 128) != 0) {
            lvl = uint24((data >> 128) & 0xFFFFFF); // may be 0 for placeholder trophies
            uint16 exTr = _readExterminatedTrait(data); // 0xFFFF = placeholder, else 0..255
            bool isMap = (data & MAP_TROPHY_FLAG) != 0;
            string memory lvlStr = (lvl == 0) ? "TBD" : uint256(lvl).toString();
            string memory trophyType = isMap ? "Map" : "Winner's";
            string memory trophyLabel = isMap
                ? "MAP Trophy"
                : "Winner's Trophy";

            string memory desc;
            if (exTr == 0xFFFF) {
                if (lvl == 0) {
                    desc = string.concat("Reserved Purge Game ", trophyLabel);
                    desc = string.concat(desc, ".");
                } else {
                    desc = string.concat("Reserved for Level ", lvlStr);
                    desc = string.concat(desc, " ");
                    desc = string.concat(desc, trophyLabel);
                    desc = string.concat(desc, ".");
                }
            } else {
                desc = string.concat("Awarded for Level ", lvlStr);
                desc = string.concat(
                    desc,
                    isMap ? " MAP jackpot." : " extermination victory."
                );
            }

            string memory img = _trophySvg(tokenId, exTr, isMap, lvl);
            return _pack(tokenId, true, img, lvl, desc, trophyType);
        }

        // ----- Regular token path -----
        lvl = uint24((data >> 32) & 0xFFFFFF);
        uint16 lastEx = uint16((data >> 56) & 0xFFFF); // 0..255 valid; 420 = sentinel “none”
        if (lvl == 90) {
            lastEx = 0xFFFF; // special case: level 90 renders all quadrants inverted
        }
        uint32 traits = uint32(data);

        (uint8[4] memory col, uint8[4] memory sym) = _decodeTraits(traits);
        string memory img2 = _svgFull(
            tokenId,
            traits,
            col,
            sym,
            remaining,
            lastEx
        );
        string memory desc2 = _descFromRem(col, sym, remaining);

        return _pack(tokenId, false, img2, lvl, desc2, "");
    }

    /// @dev Compose the full SVG for a regular token (non‑trophy).
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
        uint16 lastEx
    ) private view returns (string memory out) {
        // Resolve palette (owner/custom overrides cascade inside `_resolve`)
        string memory borderColor0 = _borderColor(tokenId, traitsPacked, col);
        string memory borderColor = _resolve(tokenId, 0, borderColor0);
        string memory diamondFill = _resolve(tokenId, 2, "#fff");
        string memory flameFill = _resolve(tokenId, 1, "#111");
        string memory squareFill = _resolve(tokenId, 3, "#d9d9d9");

        // Frame + guides
        out = _svgHeader(borderColor, squareFill);
        string memory diamondPath = icons.diamond();
        out = string.concat(
            out,
            _guides(borderColor, diamondFill, flameFill, diamondPath)
        );

        // Quadrant remap (visual layout): BL←Q2, BR←Q3, TL←Q0, TR←Q1
        out = string.concat(
            out,
            _svgQuad(0, 2, col[2], sym[2], remaining[2], lastEx)
        ); // BL
        out = string.concat(
            out,
            _svgQuad(1, 3, col[3], sym[3], remaining[3], lastEx)
        ); // BR
        out = string.concat(
            out,
            _svgQuad(2, 0, col[0], sym[0], remaining[0], lastEx)
        ); // TL
        out = string.concat(
            out,
            _svgQuad(3, 1, col[1], sym[1], remaining[1], lastEx)
        ); // TR

        out = string.concat(out, _svgFooter());
    }

    /// @notice Render a single quadrant (rings + symbol), with optional per‑quadrant invert when it
    ///         matches the last exterminated trait.
    function _svgQuad(
        uint256 quadPos,
        uint256 quadId,
        uint8 colorIndex,
        uint8 symbolIndex,
        uint32 liveRemaining,
        uint16 lastExterminated
    ) private view returns (string memory) {
        // Trait id in the 0..255 namespace for (quadId, colorIndex, symbolIndex)
        uint8 traitId = _traitId(uint8(quadId), colorIndex, symbolIndex);

        // Highlight by inversion when this trait was exterminated last level.
        bool highlightInvert = (lastExterminated == 0xFFFF) ||
            (lastExterminated != 420 &&
                lastExterminated <= 255 &&
                traitId == uint8(lastExterminated));

        // Radius computation: derive scarcity‑scaled outer/mid/inner radii
        uint32 rMax = _rMaxAt(quadPos);
        uint32 startRem = _startFor(quadId, colorIndex, symbolIndex);
        uint32 currRem = (liveRemaining == 0)
            ? 1
            : (liveRemaining > startRem ? startRem : liveRemaining);
        uint32 scarcity1e6 = _scarcityFactor1e6(startRem, currRem);

        uint32 rOuter = uint32((uint256(rMax) * scarcity1e6) / 1_000_000);
        rOuter = uint32((uint256(rOuter) * GLOBAL_BADGE_BOOST_1e6) / 1_000_000);
        uint32 rMiddle = uint32((uint256(rOuter) * RATIO_MID_1e6) / 1_000_000);
        uint32 rInner = uint32((uint256(rOuter) * RATIO_IN_1e6) / 1_000_000);

        // Concentric rings
        string memory colorHex = COLOR_HEX[colorIndex];
        string memory ringsSvg = _rings(
            colorHex,
            "#111",
            "#fff",
            rOuter,
            rMiddle,
            rInner,
            CX[quadPos],
            CY[quadPos]
        );

        // Symbol path selection (32 icons total: quadId*8 + symbolIndex)
        uint256 iconIndex = quadId * 8 + symbolIndex;
        string memory iconPath = icons.data(iconIndex);
        uint16 vbW = icons.vbW(iconIndex);
        uint16 vbH = icons.vbH(iconIndex);
        uint16 vbMax = vbW > vbH ? vbW : vbH;
        if (vbMax == 0) vbMax = 1;

        // Fit symbol into inner ring, scaled in 1e6 “micro‑units”
        uint32 fit1e6 = _symbolFit1e6(quadId, symbolIndex);
        uint32 scale1e6 = uint32((uint256(2) * rInner * fit1e6) / vbMax);

        // Place symbol centered at quadrant origin in micro‑space
        int256 cxMicro = int256(int32(CX[quadPos])) * 1_000_000;
        int256 cyMicro = int256(int32(CY[quadPos])) * 1_000_000;
        int256 txMicro = cxMicro -
            (int256(uint256(vbW)) * int256(uint256(scale1e6))) /
            2;
        int256 tyMicro = cyMicro -
            (int256(uint256(vbH)) * int256(uint256(scale1e6))) /
            2;

        // Color the symbol: Q0 uses source path colors; others use the quadrant color
        string memory symbolSvg = (quadId == 0)
            ? string(
                abi.encodePacked(
                    '<g transform="',
                    _mat6(scale1e6, txMicro, tyMicro),
                    '"><g style="vector-effect:non-scaling-stroke">',
                    iconPath,
                    "</g></g>"
                )
            )
            : string(
                abi.encodePacked(
                    '<g transform="',
                    _mat6(scale1e6, txMicro, tyMicro),
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
            return
                string(
                    abi.encodePacked(
                        '<g filter="url(#inv)">',
                        ringsSvg,
                        symbolSvg,
                        "</g>"
                    )
                );
        }
        return string(abi.encodePacked(ringsSvg, symbolSvg));
    }

    /// @notice Human label for a symbol index within a quadrant.
    /// @dev Q0..Q2 use named sets; Q3 is dice 1..8.
    function _symTitle(
        uint256 quadId,
        uint8 symbolIndex
    ) private view returns (string memory) {
        if (quadId < 3) return icons.symbol(quadId, symbolIndex);
        unchecked {
            return (uint256(symbolIndex) + 1).toString();
        }
    }

    /// @notice Color + symbol label (e.g., “Blue Diamond”).
    function _label(
        uint256 quadId,
        uint8 colorIndex,
        uint8 symbolIndex
    ) private view returns (string memory) {
        return
            string(
                abi.encodePacked(
                    _colorTitle(colorIndex),
                    " ",
                    _symTitle(quadId, symbolIndex)
                )
            );
    }

    /// @notice Build a 4‑line description showing remaining counts per quadrant.
    function _descFromRem(
        uint8[4] memory col,
        uint8[4] memory sym,
        uint32[4] memory rem
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

    // ---------------- Trophy / SVG helpers -----------------------------------------------------------

    /**
     * @dev Build the complete SVG for a trophy token.
     *      - If `exterminatedTrait == 0xFFFF`: trophy is *unwon/placeholder* (red outer ring,
     *        other colors resolved via owner/referrer defaults).
     *      - Otherwise: “won” trophy; ring uses the trait’s color family and the symbol is
     *        always tinted (fills the inner white circle).
     *
     * Size:
     * - Outer ring DIAMETER = `pct × innerSquareSide`, where `pct` is either the per-token override
     *   in `_trophyOuterPct1e6[tokenId]` (5%..100%), or a default mapped from prior fixed radii:
     *   88px for placeholder, 76px for won, over an inner side of 98px.
     */
    function _trophySvg(
        uint256 tokenId,
        uint16 exterminatedTrait,
        bool isMap,
        uint24 lvl
    ) private view returns (string memory) {
        uint32 innerSide = _innerSquareSide(); // currently 98
        // ---------------- Unwon/placeholder trophy -------------------------
        string memory diamondPath = icons.diamond();
        if (exterminatedTrait == 0xFFFF) {
            uint8 ringIdx = isMap ? 2 : 3; // Green for MAP placeholders, Red otherwise
            string memory borderColor = _resolve(
                tokenId,
                /*k=*/
                0, // outline/border
                _borderColor(tokenId, /*traitsPacked=*/ 0, _repeat4(ringIdx))
            );

            // Determine DIAMETER percentage (1e6 fp)
            uint32 pct = registry.trophyOuter(tokenId);
            uint32 diameter = (pct <= 1)
                ? 88 // default from prior rOut=44
                : uint32((uint256(innerSide) * pct) / 1_000_000);
            uint32 rOut = diameter / 2;
            uint32 rMid = uint32((uint256(rOut) * RATIO_MID_1e6) / 1_000_000);
            uint32 rIn = uint32((uint256(rOut) * RATIO_IN_1e6) / 1_000_000);

            string memory head = _svgHeader(
                borderColor,
                _resolve(tokenId, /*square*/ 3, "#d9d9d9")
            );
            string memory ringColor = COLOR_HEX[ringIdx];
            string memory placeholderFlameColor = _resolve(
                tokenId,
                /*flame*/ 1,
                "#111"
            );
            string memory rings = _rings(
                /*outer*/
                ringColor,
                /*middle*/
                placeholderFlameColor,
                /*inner*/
                _resolve(tokenId, /*diamond*/ 2, "#fff"),
                rOut,
                rMid,
                rIn,
                /*cx=*/
                0,
                /*cy=*/
                0
            );

            // Clip the central diamond area and paint the “flame” inside.
            string memory clip = string(
                abi.encodePacked(
                    '<defs><clipPath id="ct"><circle cx="0" cy="0" r="',
                    uint256(rIn).toString(),
                    '"/></clipPath></defs>'
                )
            );

            string memory centerGlyph = _centerGlyph(
                isMap,
                placeholderFlameColor,
                diamondPath
            );
            string memory cornerGlyph = _cornerGlyph(
                isMap,
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

        // ---------------- Won trophy ---------------------------------------
        uint8 dataQ = uint8(exterminatedTrait) >> 6; // 0..3
        uint8 six = uint8(exterminatedTrait) & 0x3F; // 0..63
        uint8 colIdx = six >> 3; // 0..7 (palette index)
        uint8 symIdx = six & 0x07; // 0..7 (symbol within quadrant)

        string memory border = _resolve(
            tokenId,
            /*k=*/
            0,
            _borderColor(
                tokenId,
                /*traitsPacked=*/ uint32(six),
                _repeat4(colIdx)
            )
        );

        string memory flameColor = _resolve(tokenId, /*flame*/ 1, "#111");
        string memory diamondColor = _resolve(tokenId, /*diamond*/ 2, "#fff");

        uint32 pct2 = registry.trophyOuter(tokenId);
        uint32 diameter2 = (pct2 <= 1)
            ? 76 // default from prior rOut=38
            : uint32((uint256(innerSide) * pct2) / 1_000_000);
        uint32 rOut2 = diameter2 / 2;
        uint32 rMid2 = uint32((uint256(rOut2) * RATIO_MID_1e6) / 1_000_000);
        uint32 rIn2 = uint32((uint256(rOut2) * RATIO_IN_1e6) / 1_000_000);

        // Load the symbol path for the (quadrant, index) pair.
        uint256 i = uint256(dataQ) * 8 + uint256(symIdx);
        string memory g = icons.data(i);
        uint16 w = icons.vbW(i);
        uint16 h = icons.vbH(i);
        uint16 m = w > h ? w : h;
        if (m == 0) m = 1;

        // Fit crypto icons a touch larger for two specific cases; otherwise the standard fit.
        uint32 fitSym1e6;
        if (dataQ == 0 && (symIdx == 3 || symIdx == 7)) {
            fitSym1e6 = 1_030_000;
        } else if (dataQ == 1 && symIdx == 6) {
            fitSym1e6 = 600_000; // Sagittarius trophy; reduce 25% for better framing
        } else {
            fitSym1e6 = 800_000;
        }
        uint32 sSym1e6 = uint32((uint256(2) * rIn2 * fitSym1e6) / m);

        // Center the symbol in the inner circle.
        int256 txm = -(int256(uint256(w)) * int256(uint256(sSym1e6))) / 2;
        int256 tyn = -(int256(uint256(h)) * int256(uint256(sSym1e6))) / 2;

        // Symbols on trophies are ALWAYS tinted to the palette color (no per‑path strokes).
        string memory paletteColor = COLOR_HEX[colIdx];
        string memory body = string(
            abi.encodePacked(
                '<g fill="',
                paletteColor,
                '" stroke="',
                paletteColor,
                '" style="vector-effect:non-scaling-stroke">',
                g,
                "</g>"
            )
        );

        string memory ringsAndSymbol = string(
            abi.encodePacked(
                _rings(
                    paletteColor,
                    flameColor,
                    diamondColor,
                    rOut2,
                    rMid2,
                    rIn2,
                    /*cx=*/
                    0,
                    /*cy=*/
                    0
                ),
                '<defs><clipPath id="ct2"><circle cx="0" cy="0" r="',
                uint256(rIn2).toString(),
                '"/></clipPath></defs>',
                '<g clip-path="url(#ct2)">',
                '<g transform="',
                _mat6(sSym1e6, txm, tyn),
                '">',
                body,
                "</g>",
                "</g>"
            )
        );

        bool invertTrophy = !isMap && (exterminatedTrait <= 255 || lvl == 90);
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
                    _svgHeader(
                        border,
                        _resolve(tokenId, /*square*/ 3, "#d9d9d9")
                    ),
                    ringsAndSymbol,
                    _cornerGlyph(isMap, flameColor, diamondPath),
                    _svgFooter()
                )
            );
    }

    /**
     * @dev SVG root header. Defines the inversion filter (#inv), then draws the outer rounded square.
     * @param borderColor Stroke color for the outer square (resolved border).
     * @param squareFill  Fill color for the outer square (resolved square background).
     */
    function _svgHeader(
        string memory borderColor,
        string memory squareFill
    ) private pure returns (string memory) {
        // Note: stroke-width is 2; inner usable side = 100 - 2 = 98.
        return
            string(
                abi.encodePacked(
                    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-60 -60 120 120">',
                    // Define a reusable inversion filter for quadrant “negative” effect (used ONLY in _svgQuad).
                    '<defs><filter id="inv" color-interpolation-filters="sRGB">',
                    '<feColorMatrix type="matrix" values="',
                    "-1 0 0 0 1 ",
                    "0 -1 0 0 1 ",
                    "0 0 -1 0 1 ",
                    "0 0 0  1 0",
                    '"/>',
                    "</filter></defs>",
                    '<rect x="-50" y="-50" width="100" height="100" rx="12" fill="',
                    squareFill,
                    '" stroke="',
                    borderColor,
                    '" stroke-width="2"/>'
                )
            );
    }

    /**
     * @dev Draw guides + central diamond/flame motif (shared by regular token and trophy SVGs).
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
    function _flameDiamond(
        string memory flameFill,
        string memory diamondPath
    ) private pure returns (string memory) {
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

    function _centerGlyph(
        bool isMap,
        string memory flameFill,
        string memory flamePath
    ) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '<g clip-path="url(#ct)">',
                    '<path fill="',
                    flameFill,
                    '" transform="',
                    isMap
                        ? "matrix(1.9125 0 0 1.9125 -22.95 -22.95)"
                        : "matrix(0.13 0 0 0.13 -56 -41)",
                    '" d="',
                    isMap ? MAP_BADGE_PATH : flamePath,
                    '"/>',
                    "</g>"
                )
            );
    }

    function _cornerGlyph(
        bool isMap,
        string memory flameFill,
        string memory flamePath
    ) private pure returns (string memory) {
        string memory translate = isMap
            ? "translate(41.28 40.32)"
            : "translate(43 42)";
        return
            string(
                abi.encodePacked(
                    '<g transform="',
                    translate,
                    '" opacity="0.95">',
                    '<path fill="',
                    flameFill,
                    '" transform="',
                    isMap
                        ? "matrix(0.442 0 0 0.442 -5.304 -5.304)"
                        : "matrix(0.021 0 0 0.021 -10.8 -8.10945)",
                    '" d="',
                    isMap ? MAP_BADGE_PATH : flamePath,
                    '"/>',
                    "</g>"
                )
            );
    }

    /**
     * @dev Footer closes the SVG root. No conditional groups here—quadrant inversion is handled
     *      locally in `_svgQuad` with a `<g filter="url(#inv)">...</g>` wrapper.
     */
    function _svgFooter() private pure returns (string memory) {
        return "</svg>";
    }

    // ---------------- JSON pack ----------------------------------------------------------------------

    /**
     * @dev Build ERC‑721 metadata as data:application/json;base64 with an embedded
     *      data:image/svg+xml;base64 image.
     * @param trophyType For trophies, short label (e.g. "Map"); ignored for regular tokens.
     */
    function _pack(
        uint256 tokenId,
        bool isTrophy,
        string memory svg,
        uint256 level,
        string memory desc,
        string memory trophyType
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

        // Image: inline SVG → base64 data URL
        string memory imgData = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );

        // Minimal trait list; attributes[] intentionally empty for compactness
        string memory j = string.concat('{"name":"', nm);
        j = string.concat(j, '","description":"', desc);
        j = string.concat(j, '","image":"', imgData, '","attributes":');
        if (isTrophy) {
            j = string.concat(
                j,
                '[{"trait_type":"Trophy","value":"',
                trophyType,
                '"}]}'
            );
        } else {
            j = string.concat(j, "[]}");
        }

        // Return as data:application/json;base64
        return
            string.concat(
                "data:application/json;base64,",
                Base64.encode(bytes(j))
            );
    }

    // ---------------- Helpers ------------------------------------------------------------------------

    /// @dev Utility: replicate a single palette index into a 4‑tuple (used by border resolver).
    function _repeat4(uint8 v) private pure returns (uint8[4] memory a) {
        a[0] = v;
        a[1] = v;
        a[2] = v;
        a[3] = v;
    }

    /// @dev Compose a global 0..255 trait id.
    function _traitId(
        uint8 dataQ,
        uint8 colIdx,
        uint8 symIdx
    ) private pure returns (uint8) {
        return ((colIdx << 3) | symIdx) + (dataQ << 6);
    }

    /// @dev Read the starting “remaining” supply for the trait bucket.
    function _startFor(
        uint256 dataQ,
        uint8 colIdx,
        uint8 symIdx
    ) private view returns (uint32) {
        return startTR[_traitId(uint8(dataQ), colIdx, symIdx)];
    }

    /// @dev Map current remaining vs initial remaining into a 1e6‑scaled ring size factor.
    function _scarcityFactor1e6(
        uint32 start,
        uint32 curr
    ) private pure returns (uint32) {
        if (start <= 1) return 1_000_000;
        if (curr == 0) curr = 1;
        if (curr > start) curr = start;
        uint256 add = (uint256(500_000) * (start - curr)) / (start - 1);
        return uint32(500_000 + add);
    }

    /// @dev Unified ring painter: draws three concentric circles centered at (cx,cy).
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

    /// @dev Signed small‑int to string (for SVG positions). Safe for int16 domain.
    function _i(int16 v) private pure returns (string memory) {
        int256 x = v;
        if (x >= 0) return uint256(x).toString();
        return string.concat("-", uint256(-x).toString());
    }

    // ---------------- Geometry / layout helpers ------------------------------------------------------

    /**
     * @dev Maximum outer ring radius for a quadrant “pos” given fixed square bounds (±50),
     *      clamped to 24 to preserve spacing relative to guides and center glyph.
     */
    function _rMaxAt(uint256 pos) private view returns (uint32) {
        int32 cx = int32(CX[pos]);
        int32 cy = int32(CY[pos]);

        // Distance to vertical centerline and to outer square border on Y
        uint32 dx = uint32(cx < 0 ? -cx : cx);
        uint32 dyEdge = uint32(50 - (cy < 0 ? -cy : cy));

        // Limit by the tighter of the two, then clamp hard to 24
        uint32 r = dx < dyEdge ? dx : dyEdge;
        if (r > 24) r = 24;
        return r;
    }

    /**
     * @dev Per‑icon scaling tweaks (1e6‑scaled) to visually normalize symbol sizes across the set.
     */
    function _symbolFit1e6(
        uint256 dataQ,
        uint8 symIdx
    ) private pure returns (uint32) {
        uint32 f = (SYM_FIT_BASE_1e6 * 95) / 100; // default: 95% of base fit
        if (dataQ == 1 && symIdx == 6) {
            // TR / Sagittarius
            f = uint32((uint256(f) * 722_500) / 1_000_000);
        } else if (dataQ == 2 && symIdx == 1) {
            // BL / Mushroom
            f = uint32((uint256(f) * 130_000) / 100_000);
        } else if (dataQ == 3 && (symIdx == 6 || symIdx == 7)) {
            // BR / dice 7/8
            f = uint32((uint256(f) * 110_000) / 100_000);
        } else if (dataQ == 0 && symIdx == 6) {
            // TL / Ethereum
            f = uint32((uint256(f) * 110_000) / 100_000);
        } else if (dataQ == 2 && symIdx == 6) {
            // BL / Heart
            f = uint32((uint256(f) * 95_000) / 100_000);
        } else if (dataQ == 0 && (symIdx == 3 || symIdx == 7)) {
            // TL / Monero or Bitcoin: allow full fit
            f = 1_000_000;
        }
        return f;
    }

    /**
     * @dev SVG transform matrix for uniform scale with 6‑dec fixed‑point arguments.
     *      Builds: matrix(s 0 0 s tx ty)
     */
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

    /// @dev Format an unsigned 1e6 fixed‑point value as "I.FFFFFF".
    function _dec6(uint256 x) private pure returns (string memory) {
        uint256 i = x / 1_000_000;
        uint256 f = x % 1_000_000;
        return string(abi.encodePacked(i.toString(), ".", _pad6(uint32(f))));
    }

    /// @dev Signed version of `_dec6`.
    function _dec6s(int256 x) private pure returns (string memory) {
        if (x < 0) {
            uint256 y = uint256(-x);
            return string(abi.encodePacked("-", _dec6(y)));
        }
        return _dec6(uint256(x));
    }

    /// @dev Zero‑pad a 6‑digit fractional part.
    function _pad6(uint32 f) private pure returns (string memory) {
        bytes memory b = new bytes(6);
        for (uint256 k; k < 6; ++k) {
            b[5 - k] = bytes1(uint8(48 + (f % 10)));
            f /= 10;
        }
        return string(b);
    }

    // ---------------- Palette / trait helpers --------------------------------------------------------

    /**
     * @dev Choose a border color different from the 4 used quadrant colors.
     *      Starts from a deterministic index (tokenId,traits hash) and scans forward.
     */
    function _borderColor(
        uint256 tokenId,
        uint32 traits,
        uint8[4] memory used
    ) private view returns (string memory) {
        uint8 initial = uint8(
            uint256(keccak256(abi.encodePacked(tokenId, traits))) % 8
        );

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
            if (!isUsed) return COLOR_HEX[idx];
            unchecked {
                ++i;
            }
        }
        // Fallback: should be unreachable (8 palette entries, 4 used)
        return COLOR_HEX[0];
    }

    /**
     * @dev Decode 24‑bit packed traits (4×8‑bit) into color and symbol indices per quadrant.
     *      For each quadrant q: v = (traits >> (q*8)) & 0x3F; col = v>>3; sym = v&7.
     */
    function _decodeTraits(
        uint32 t
    ) private pure returns (uint8[4] memory col, uint8[4] memory sym) {
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
