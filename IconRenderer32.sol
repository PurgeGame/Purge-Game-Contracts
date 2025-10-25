// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./Icons32.sol";

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
 * - Stores four hex color slots per token OR per address (fallback).
 * - Enforces strict `#rrggbb` lowercase format for all custom colors.
 * - Keepers:
 *    * `_custom[tokenId]` has precedence over `_addr[owner]`
 *    * If no overrides set, consumers may fall back to palette indices elsewhere.
 */
contract IconRenderer32 {
    using Strings for uint256;

    uint256 private constant MAP_TROPHY_FLAG = uint256(1) << 200;

    // ---------------- Storage ----------------

    /// @dev Four color channels (border, mid ring, inner ring, square bg).
    struct Colors {
        string outline;
        string flame;
        string diamond;
        string square;
    }

    /// @notice Per-token overrides (highest precedence).
    mapping(uint256 => Colors) private _custom;

    /// @notice Per-address defaults (secondary precedence).
    mapping(address => Colors) private _addr;

    /// @notice Per-token trophy outer DIAMETER as a fraction of the inner square side, 1e6 fixed-point.
    ///         0 = no override; 1 = reset to default; valid range = [50_000 .. 1_000_000] (5%..100%).
    mapping(uint256 => uint32) private _trophyOuterPct1e6;

    /// @notice Deployer retained for optional admin-only methods (if any).
    address private immutable deployer;

    /// @dev Generic guard.
    error E();

    constructor() {
        deployer = msg.sender;
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

    /**
     * @notice Strictly require a hex color of the form "#rrggbb" (lowercase).
     * @dev Reverts if:
     *  - length != 7
     *  - no leading '#'
     *  - any char not in [0-9a-f]
     * @return s Echoes the validated string (for inline usage).
     */
    function _requireHex7(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        require(b.length == 7 && b[0] == bytes1("#"));
        for (uint256 i = 1; i < 7; ++i) {
            uint8 ch = uint8(b[i]);
            require((ch >= 48 && ch <= 57) || (ch >= 97 && ch <= 102));
        }
        return s;
    }

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
        Colors storage pref = _addr[msg.sender];

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
        return setCustomColorsForMany(tokenIds, outlineHex, flameHex, diamondHex, squareHex, /*trophyOuterPct1e6=*/ 0);
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
        uint256 count = tokenIds.length;
        require(count <= 150, "renderer:max150");

        IERC721Lite nft = IERC721Lite(game); // NOTE: `game` must be defined in this contract.

        bool clearOutline = (bytes(outlineHex).length == 0);
        bool clearFlame = (bytes(flameHex).length == 0);
        bool clearDiamond = (bytes(diamondHex).length == 0);
        bool clearSquare = (bytes(squareHex).length == 0);

        string memory outlineVal = clearOutline ? "" : _requireHex7(outlineHex);
        string memory flameVal = clearFlame ? "" : _requireHex7(flameHex);
        string memory diamondVal = clearDiamond ? "" : _requireHex7(diamondHex);
        string memory squareVal = clearSquare ? "" : _requireHex7(squareHex);

        // Trophy size validation: allow 0 (no change) and 1 (reset), else 5%..100%.
        if (trophyOuterPct1e6 != 0 && trophyOuterPct1e6 != 1) {
            require(trophyOuterPct1e6 >= 50_000 && trophyOuterPct1e6 <= 1_000_000, "renderer:trophy_pct_oob");
        }

        for (uint256 i; i < count; ) {
            uint256 tokenId = tokenIds[i];
            require(nft.ownerOf(tokenId) == msg.sender, "not owner");

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
                delete _trophyOuterPct1e6[tokenId]; // reset to default per trophy type
            } else {
                _trophyOuterPct1e6[tokenId] = trophyOuterPct1e6;
            }

            unchecked {
                ++i;
            }
        }
        return true;
    }

    // ---------------------------------------------------------------------
    // Color resolution: token → per‑token override → owner default → referrer/upline default → fallback
    // ---------------------------------------------------------------------

    /// @dev Selector into a Colors struct.
    function _F(Colors storage c, uint8 k) private view returns (string storage r) {
        if (k == 0) return c.outline;
        if (k == 1) return c.flame;
        if (k == 2) return c.diamond;
        return c.square;
    }

    /// @notice Resolve a channel color for `tokenId`, falling back across owner, referrer, upline, or `defColor`.
    /// @param tokenId  Token to render.
    /// @param k        Channel index: 0=outline, 1=flame, 2=diamond, 3=square.
    /// @param defColor Final fallback color (e.g., theme default).
    function _resolve(uint256 tokenId, uint8 k, string memory defColor) private view returns (string memory) {
        address owner_ = _ownerOf(tokenId); // NOTE: expects an internal helper or use IERC721Lite(game).ownerOf(tokenId)

        {
            string storage s = _F(_custom[tokenId], k);
            if (bytes(s).length != 0) return s;
        }
        {
            string storage s = _F(_addr[owner_], k);
            if (bytes(s).length != 0) return s;
        }

        address coinAddr = coin;
        if (coinAddr.code.length != 0) {
            address ref = IPurgedRead(coinAddr).getReferrer(owner_);
            if (ref != address(0)) {
                {
                    string storage s = _F(_addr[ref], k);
                    if (bytes(s).length != 0) return s;
                }
                // Referrer exists but has no color → try upline
                address up = IPurgedRead(coinAddr).getReferrer(ref);
                if (up != address(0)) {
                    string storage s = _F(_addr[up], k);
                    if (bytes(s).length != 0) return s;
                }
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

    // SVG path for the diamond logo (shared across variants).
    string private constant DIAMOND_LOGO_PATH =
        "M431.48,504.54c-5.24-10.41-12.36-18.75-21.62-24.98-6.91-4.65-14.21-8.76-21.56-12.69-12.95-6.93-26.54-12.66-38.78-20.91-19.24-12.96-31.77-30.57-36.56-53.37-3.66-17.46-2.13-34.69,2.89-51.71,4.01-13.6,10.35-26.15,16.95-38.6,7.71-14.54,15.86-28.87,21.81-44.28,3.39-8.77,5.94-17.76,7.2-27.11,0,3.69,.24,7.4-.04,11.07-1.48,19.17-7.44,37.4-11.94,55.94-3.57,14.72-6.92,29.46-6.53,44.78,.46,18.05,6.14,34.08,19.02,46.86,9.15,9.09,19.11,17.38,28.83,25.89,8.46,7.41,17.32,14.37,24.28,23.36,7.48,9.66,11.24,20.77,13.22,32.63,.32,1.93,.63,3.86,1.02,6.22,4.22-6.71,8.24-12.99,12.15-19.34,2.97-4.81,5.94-9.63,8.66-14.58,8.98-16.34,8-31.83-4.22-46.28-6.7-7.92-13.41-15.82-20.01-23.82-4.83-5.86-9.23-12.01-10.54-19.77-1.49-8.9,.02-17.43,3.25-25.74,3.45-8.89,7.2-17.67,10.28-26.69,3.52-10.29,5.13-21.02,5.5-31.89,.14-4.19-.28-8.39-.74-12.61-3.91,16.79-14.43,29.92-23.51,43.8-7.15,10.93-14.4,21.79-19.47,33.9-3.78,9.03-6.23,18.4-6.71,28.2-.59,11.95,2.26,23.17,8.54,33.28,3.76,6.07,8.44,11.56,12.72,17.31,.36,.49,.75,.96,1.13,1.44l-.39,.49c-2.78-2-5.65-3.89-8.33-6.02-12.9-10.23-23.86-22.09-30.76-37.27-5.35-11.77-6.76-24.15-5.31-36.9,2.41-21.24,11.63-39.66,23.7-56.9,7.63-10.9,15.43-21.7,22.75-32.81,7.31-11.11,11.78-23.44,13.48-36.65,1.58-12.32,.38-24.49-2.45-36.55-2.43-10.38-6-20.36-10.24-30.13l.47-.43c3.18,3.14,6.6,6.08,9.51,9.45,16.8,19.42,27.96,41.68,33.29,66.83,3.12,14.73,3.44,29.56,1.84,44.51-1.06,9.89-2.25,19.82-2.49,29.75-.27,11.05,3.86,21.06,9.7,30.3,5.19,8.22,10.8,16.18,15.83,24.48,7.27,12.01,11.77,25.09,13,39.09,1.06,12.19-1.32,23.97-5.7,35.33-4.68,12.14-11.42,23.07-19.75,33.04-.28,.34-.5,.73-.98,1.42,.58-.2,.81-.21,.94-.33,13.86-12.66,25.56-26.91,32.56-44.59,4.2-10.61,4.64-21.64,2.92-32.71-1.55-9.97-3.84-19.83-5.69-29.75-1.3-6.98-1.62-14.03-.96-21.16,2.41,11.44,9.46,20.38,15.71,29.77,4.45,6.69,8.7,13.49,10.95,21.34l.78-.11c-.52-5.46-.86-10.95-1.6-16.38-1.57-11.65-6.36-22.27-10.97-32.92-5.36-12.4-10.87-24.73-14.2-37.9-4.6-18.21-6.04-36.6-3.4-55.24,.17-1.22,.27-2.44,.62-3.65,3.31,18.57,10.98,35.38,19.91,51.69,5.97,10.9,12.18,21.66,18.06,32.61,7.08,13.2,12.26,27.14,14.41,42.02,4.35,30.04-2.87,56.63-24.51,78.55-9.21,9.33-20.5,15.79-31.95,21.98-9.44,5.1-18.91,10.16-28.11,15.67-11.91,7.14-21.38,16.78-27.83,29.82Z";

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
    address private game; // ERC721 implementing IERC721Lite
    address private coin; // PURGE ERC20 implementing IPurgedRead (getReferrer)

    // Human‑readable labels (used in JSON metadata).
    string[8] private SYM_Q1_TITLE = ["XRP", "Tron", "Sui", "Monero", "Solana", "Chainlink", "Ethereum", "Bitcoin"]; // TL
    string[8] private SYM_Q2_TITLE = ["Aries", "Taurus", "Gemini", "Cancer", "Leo", "Libra", "Sagittarius", "Aquarius"]; // TR
    string[8] private SYM_Q3_TITLE = ["Horseshoe", "Mushroom", "Ball", "Cashsack", "Club", "Diamond", "Heart", "Spade"]; // BL

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
        require(msg.sender == game, "renderer:onlyGame");
        _;
    }

    /// @notice One‑time link to the on‑chain game and coin contracts.
    /// @dev Callable only by the deployer; cannot be re‑set after initialization.
    function setPurgeGame(address g, address c) external returns (bool) {
        if (msg.sender != deployer || game != address(0)) revert E();
        game = g;
        coin = c;
        return true;
    }

    /// @notice Capture the starting trait‑remaining snapshot for the new epoch.
    /// @dev Writes 256 slots; intended to be called once per level by the game.
    function setStartingTraitRemaining(uint32[256] calldata values) external onlyGame {
        for (uint256 i; i < 256; ++i) {
            startTR[i] = values[i];
        }
    }

    // ---------------------------------------------------------------------
    // Owner lookup (robust)
    // ---------------------------------------------------------------------

    /// @dev Resolve current owner using a low‑level staticcall to `ownerOf(uint256)`.
    ///      Returns address(0) if the call fails or the game is not set/deployed.
    function _ownerOf(uint256 tokenId) private view returns (address a) {
        address g = game;
        if (g.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = g.staticcall(abi.encodeWithSelector(0x6352211e, tokenId)); // ownerOf(uint256)
        if (!ok || ret.length < 32) return address(0);
        assembly {
            a := mload(add(ret, 32))
        }
    }

    // ---------------------------------------------------------------------
    // Trophy helpers
    // ---------------------------------------------------------------------

    /// @dev Read the exterminated trait from a packed trophy `data` word.
    ///      Bits [167:152] hold: 0xFFFF for placeholder (unwon), else uint8 trait id.
    ///      Bit 200 is reserved for MAP trophies (1 = MAP, 0 = level trophy).
    function _readExterminatedTrait(uint256 data) private pure returns (uint16) {
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

            string memory desc;
            if (exTr == 0xFFFF) {
                desc = string.concat("Unawarded ", trophyType, " trophy placeholder.");
            } else {
                desc = string.concat(
                    "Awarded for Level ",
                    lvlStr,
                    isMap ? " MAP jackpot dominance." : " final extermination victory."
                );
            }

            string memory img = _trophySvg(tokenId, exTr);
            return _pack(tokenId, true, img, lvl, desc, trophyType);
        }

        // ----- Regular token path -----
        lvl = uint24((data >> 32) & 0xFFFFFF);
        uint16 lastEx = uint16((data >> 56) & 0xFFFF); // 0..255 valid; 420 = sentinel “none”
        uint32 traits = uint32(data);

        (uint8[4] memory col, uint8[4] memory sym) = _decodeTraits(traits);
        string memory img2 = _svgFull(tokenId, traits, col, sym, remaining, lastEx);
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
        out = string.concat(out, _guides(borderColor, diamondFill, flameFill));

        // Quadrant remap (visual layout): BL←Q2, BR←Q3, TL←Q0, TR←Q1
        out = string.concat(out, _svgQuad(0, 2, col[2], sym[2], remaining[2], lastEx)); // BL
        out = string.concat(out, _svgQuad(1, 3, col[3], sym[3], remaining[3], lastEx)); // BR
        out = string.concat(out, _svgQuad(2, 0, col[0], sym[0], remaining[0], lastEx)); // TL
        out = string.concat(out, _svgQuad(3, 1, col[1], sym[1], remaining[1], lastEx)); // TR

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
        bool highlightInvert = (lastExterminated != 420 &&
            lastExterminated <= 255 &&
            traitId == uint8(lastExterminated));

        // Radius computation: derive scarcity‑scaled outer/mid/inner radii
        uint32 rMax = _rMaxAt(quadPos);
        uint32 startRem = _startFor(quadId, colorIndex, symbolIndex);
        uint32 currRem = (liveRemaining == 0) ? 1 : (liveRemaining > startRem ? startRem : liveRemaining);
        uint32 scarcity1e6 = _scarcityFactor1e6(startRem, currRem);

        uint32 rOuter = uint32((uint256(rMax) * scarcity1e6) / 1_000_000);
        rOuter = uint32((uint256(rOuter) * GLOBAL_BADGE_BOOST_1e6) / 1_000_000);
        uint32 rMiddle = uint32((uint256(rOuter) * RATIO_MID_1e6) / 1_000_000);
        uint32 rInner = uint32((uint256(rOuter) * RATIO_IN_1e6) / 1_000_000);

        // Concentric rings
        string memory ringsSvg = _rings(
            COLOR_HEX[colorIndex],
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
        string memory iconPath = Icons32.data(iconIndex);
        uint16 vbW = Icons32.vbW(iconIndex);
        uint16 vbH = Icons32.vbH(iconIndex);
        uint16 vbMax = vbW > vbH ? vbW : vbH;
        if (vbMax == 0) vbMax = 1;

        // Fit symbol into inner ring, scaled in 1e6 “micro‑units”
        uint32 fit1e6 = _symbolFit1e6(quadId, symbolIndex);
        uint32 scale1e6 = uint32((uint256(2) * rInner * fit1e6) / vbMax);

        // Place symbol centered at quadrant origin in micro‑space
        int256 cxMicro = int256(int32(CX[quadPos])) * 1_000_000;
        int256 cyMicro = int256(int32(CY[quadPos])) * 1_000_000;
        int256 txMicro = cxMicro - (int256(uint256(vbW)) * int256(uint256(scale1e6))) / 2;
        int256 tyMicro = cyMicro - (int256(uint256(vbH)) * int256(uint256(scale1e6))) / 2;

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
                    COLOR_HEX[colorIndex],
                    '" stroke="',
                    COLOR_HEX[colorIndex],
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
        if (quadId == 0) return SYM_Q1_TITLE[symbolIndex];
        if (quadId == 1) return SYM_Q2_TITLE[symbolIndex];
        if (quadId == 2) return SYM_Q3_TITLE[symbolIndex];
        unchecked {
            return (uint256(symbolIndex) + 1).toString();
        }
    }

    /// @notice Color + symbol label (e.g., “Blue Diamond”).
    function _label(uint256 quadId, uint8 colorIndex, uint8 symbolIndex) private view returns (string memory) {
        return string(abi.encodePacked(_colorTitle(colorIndex), " ", _symTitle(quadId, symbolIndex)));
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
    function _trophySvg(uint256 tokenId, uint16 exterminatedTrait) private view returns (string memory) {
        uint32 innerSide = _innerSquareSide(); // currently 98
        // ---------------- Unwon/placeholder trophy -------------------------
        if (exterminatedTrait == 0xFFFF) {
            uint8 ringIdx = 3; // Red
            string memory borderColor = _resolve(
                tokenId,
                /*k=*/ 0, // outline/border
                _borderColor(tokenId, /*traitsPacked=*/ 0, _repeat4(ringIdx))
            );

            // Determine DIAMETER percentage (1e6 fp)
            uint32 pct = _trophyOuterPct1e6[tokenId];
            uint32 diameter = (pct == 0 || pct == 1)
                ? 88 // default from prior rOut=44
                : uint32((uint256(innerSide) * pct) / 1_000_000);
            uint32 rOut = diameter / 2;
            uint32 rMid = uint32((uint256(rOut) * RATIO_MID_1e6) / 1_000_000);
            uint32 rIn = uint32((uint256(rOut) * RATIO_IN_1e6) / 1_000_000);

            string memory head = _svgHeader(borderColor, _resolve(tokenId, /*square*/ 3, "#d9d9d9"));
            string memory rings = _rings(
                /*outer*/ COLOR_HEX[ringIdx],
                /*middle*/ _resolve(tokenId, /*flame*/ 1, "#111"),
                /*inner*/ _resolve(tokenId, /*diamond*/ 2, "#fff"),
                rOut,
                rMid,
                rIn,
                /*cx=*/ 0,
                /*cy=*/ 0
            );

            // Clip the central diamond area and paint the “flame” inside.
            string memory clip = string(
                abi.encodePacked(
                    '<defs><clipPath id="ct"><circle cx="0" cy="0" r="',
                    uint256(rIn).toString(),
                    '"/></clipPath></defs>'
                )
            );

            string memory flame = string(
                abi.encodePacked(
                    '<g clip-path="url(#ct)">',
                    '<path fill="',
                    _resolve(tokenId, /*flame*/ 1, "#111"),
                    '" stroke="none" transform="matrix(0.13 0 0 0.13 -56 -41)" d="',
                    DIAMOND_LOGO_PATH,
                    '"/>',
                    "</g>"
                )
            );

            return string(abi.encodePacked(head, rings, clip, flame, _svgFooter()));
        }

        // ---------------- Won trophy ---------------------------------------
        uint8 dataQ = uint8(exterminatedTrait) >> 6; // 0..3
        uint8 six = uint8(exterminatedTrait) & 0x3F; // 0..63
        uint8 colIdx = six >> 3; // 0..7 (palette index)
        uint8 symIdx = six & 0x07; // 0..7 (symbol within quadrant)

        string memory border = _resolve(
            tokenId,
            /*k=*/ 0,
            _borderColor(tokenId, /*traitsPacked=*/ uint32(six), _repeat4(colIdx))
        );

        uint32 pct2 = _trophyOuterPct1e6[tokenId];
        uint32 diameter2 = (pct2 == 0 || pct2 == 1)
            ? 76 // default from prior rOut=38
            : uint32((uint256(innerSide) * pct2) / 1_000_000);
        uint32 rOut2 = diameter2 / 2;
        uint32 rMid2 = uint32((uint256(rOut2) * RATIO_MID_1e6) / 1_000_000);
        uint32 rIn2 = uint32((uint256(rOut2) * RATIO_IN_1e6) / 1_000_000);

        // Load the symbol path for the (quadrant, index) pair.
        uint256 i = uint256(dataQ) * 8 + uint256(symIdx);
        string memory g = Icons32.data(i);
        uint16 w = Icons32.vbW(i);
        uint16 h = Icons32.vbH(i);
        uint16 m = w > h ? w : h;
        if (m == 0) m = 1;

        // Fit crypto icons a touch larger for two specific cases; otherwise the standard fit.
        uint32 fitSym1e6 = (dataQ == 0 && (symIdx == 3 || symIdx == 7)) ? 1_030_000 : 800_000;
        uint32 sSym1e6 = uint32((uint256(2) * rIn2 * fitSym1e6) / m);

        // Center the symbol in the inner circle.
        int256 txm = -(int256(uint256(w)) * int256(uint256(sSym1e6))) / 2;
        int256 tyn = -(int256(uint256(h)) * int256(uint256(sSym1e6))) / 2;

        // Symbols on trophies are ALWAYS tinted to the palette color (no per‑path strokes).
        string memory body = string(
            abi.encodePacked(
                '<g fill="',
                COLOR_HEX[colIdx],
                '" stroke="',
                COLOR_HEX[colIdx],
                '" style="vector-effect:non-scaling-stroke">',
                g,
                "</g>"
            )
        );

        return
            string(
                abi.encodePacked(
                    _svgHeader(border, _resolve(tokenId, /*square*/ 3, "#d9d9d9")),
                    _rings(
                        COLOR_HEX[colIdx],
                        _resolve(tokenId, /*flame*/ 1, "#111"),
                        _resolve(tokenId, /*diamond*/ 2, "#fff"),
                        rOut2,
                        rMid2,
                        rIn2,
                        /*cx=*/ 0,
                        /*cy=*/ 0
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
                    "</g>",
                    _svgFooter()
                )
            );
    }

    /**
     * @dev SVG root header. Defines the inversion filter (#inv), then draws the outer rounded square.
     * @param borderColor Stroke color for the outer square (resolved border).
     * @param squareFill  Fill color for the outer square (resolved square background).
     */
    function _svgHeader(string memory borderColor, string memory squareFill) private pure returns (string memory) {
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
        string memory flameColor
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
                    _flameDiamond(flameColor)
                )
            );
    }

    /**
     * @dev Flame path clipped to the diamond.
     */
    function _flameDiamond(string memory flameFill) private pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '<defs><clipPath id="cd"><path d="M0,15.5 L15.5,0 0,-15.5 -15.5,0 Z"/></clipPath></defs>',
                    '<g clip-path="url(#cd)"><g transform="translate(-1.596,-1.664) scale(2)">',
                    '<path fill="',
                    flameFill,
                    '" stroke="none" transform="matrix(0.027 0 0 0.027 -10.8 -8.10945)" d="',
                    DIAMOND_LOGO_PATH,
                    '"/>',
                    "</g></g>"
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
            ? string.concat("Purge Game Level ", lvlStr, " ", trophyType, " Trophy")
            : string.concat("Purge Game Level ", lvlStr, " #", tokenId.toString());

        // Image: inline SVG → base64 data URL
        string memory imgData = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        // Minimal trait list; attributes[] intentionally empty for compactness
        string memory j = string.concat('{"name":"', nm);
        j = string.concat(j, '","description":"', desc);
        j = string.concat(j, '","image":"', imgData, '","attributes":');
        if (isTrophy) {
            j = string.concat(j, '[{"trait_type":"Trophy","value":"', trophyType, '"}]}');
        } else {
            j = string.concat(j, "[]}");
        }

        // Return as data:application/json;base64
        return string.concat("data:application/json;base64,", Base64.encode(bytes(j)));
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
    function _traitId(uint8 dataQ, uint8 colIdx, uint8 symIdx) private pure returns (uint8) {
        return ((colIdx << 3) | symIdx) + (dataQ << 6);
    }

    /// @dev Read the starting “remaining” supply for the trait bucket.
    function _startFor(uint256 dataQ, uint8 colIdx, uint8 symIdx) private view returns (uint32) {
        return startTR[_traitId(uint8(dataQ), colIdx, symIdx)];
    }

    /// @dev Map current remaining vs initial remaining into a 1e6‑scaled ring size factor.
    function _scarcityFactor1e6(uint32 start, uint32 curr) private pure returns (uint32) {
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
    function _symbolFit1e6(uint256 dataQ, uint8 symIdx) private pure returns (uint32) {
        uint32 f = (SYM_FIT_BASE_1e6 * 95) / 100; // default: 95% of base fit
        if (dataQ == 1 && symIdx == 6) {
            // TR / Sagittarius
            f = uint32((uint256(f) * 850_000) / 1_000_000);
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
    function _mat6(uint32 s1e6, int256 tx1e6, int256 ty1e6) private pure returns (string memory) {
        string memory s = _dec6(uint256(s1e6));
        string memory txn = _dec6s(tx1e6);
        string memory tyn = _dec6s(ty1e6);
        return string(abi.encodePacked("matrix(", s, " 0 0 ", s, " ", txn, " ", tyn, ")"));
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
    function _borderColor(uint256 tokenId, uint32 traits, uint8[4] memory used) private view returns (string memory) {
        uint8 initial = uint8(uint256(keccak256(abi.encodePacked(tokenId, traits))) % 8);

        for (uint8 i; i < 8; ++i) {
            uint8 idx = (initial + i) % 8;

            bool isUsed;
            for (uint8 j; j < 4; ++j) {
                if (used[j] == idx) {
                    isUsed = true;
                    break;
                }
            }
            if (!isUsed) return COLOR_HEX[idx];
        }
        // Fallback: should be unreachable (8 palette entries, 4 used)
        return COLOR_HEX[0];
    }

    /**
     * @dev Decode 24‑bit packed traits (4×8‑bit) into color and symbol indices per quadrant.
     *      For each quadrant q: v = (traits >> (q*8)) & 0x3F; col = v>>3; sym = v&7.
     */
    function _decodeTraits(uint32 t) private pure returns (uint8[4] memory col, uint8[4] memory sym) {
        unchecked {
            for (uint256 q; q < 4; ++q) {
                uint8 v = uint8((t >> (q * 8)) & 0x3F); // strip quadrant tag (64/128/192)
                col[q] = v >> 3;
                sym[q] = v & 0x07;
            }
        }
    }
}
