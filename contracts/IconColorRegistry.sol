// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployConstants} from "./DeployConstants.sol";

/*
╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                       IconColorRegistry                                               ║
║                         Color Customization Storage for Degenerus NFT Renders                         ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                       ║
║  ARCHITECTURE OVERVIEW                                                                                ║
║  ─────────────────────                                                                                ║
║  IconColorRegistry stores color customization preferences for Degenerus NFT metadata.                 ║
║  Colors are stored as validated "#rrggbb" hex strings and used by renderers during SVG generation.   ║
║  Per-token recoloring requires burning 50 BURNIE per token as a deflationary fee.                    ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              COLOR RESOLUTION CASCADE                                            │ ║
║  │                                                                                                  │ ║
║  │   Renderer queries color for (tokenContract, tokenId, channel):                                 │ ║
║  │                                                                                                  │ ║
║  │   1. Per-Token Override    ─► _custom[contract][tokenId].{channel}                              │ ║
║  │          │ empty?                                                                                │ ║
║  │          ▼                                                                                       │ ║
║  │   2. Owner Default         ─► _addr[owner].{channel}                                            │ ║
║  │          │ empty?                                                                                │ ║
║  │          ▼                                                                                       │ ║
║  │   3. Referrer Default      ─► _addr[referrer].{channel}                                         │ ║
║  │          │ empty?                                                                                │ ║
║  │          ▼                                                                                       │ ║
║  │   4. Upline Default        ─► _addr[referrer's referrer].{channel}                              │ ║
║  │          │ empty?                                                                                │ ║
║  │          ▼                                                                                       │ ║
║  │   5. Theme Default         ─► Hardcoded in renderer (e.g., "#fff", "#111")                      │ ║
║  │                                                                                                  │ ║
║  │   Note: This cascade is implemented in the RENDERER, not here.                                  │ ║
║  │         Registry only stores and validates colors.                                               │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              COLOR CHANNELS (0-3)                                                │ ║
║  │                                                                                                  │ ║
║  │   Channel 0: outline   ─► Border stroke, guide lines, frame color                               │ ║
║  │   Channel 1: flame     ─► Center flame icon fill color                                          │ ║
║  │   Channel 2: diamond   ─► Center diamond background fill                                        │ ║
║  │   Channel 3: square    ─► Outer square background fill                                          │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              RECOLORING FEE (BURNIE BURN)                                       │ ║
║  │                                                                                                  │ ║
║  │   Per-Token Recoloring Flow (using burnCoin for direct burn):                                   │ ║
║  │   ┌─────────────┐    burnCoin     ┌─────────────┐                                               │ ║
║  │   │    User     │ ───────────────► │   Burned    │                                               │ ║
║  │   │ (50 BURNIE  │   (direct burn)  │  (supply ↓) │                                               │ ║
║  │   │  per token) │                  │             │                                               │ ║
║  │   └─────────────┘                  └─────────────┘                                               │ ║
║  │                                                                                                  │ ║
║  │   Cost: RECOLOR_COST_PER_TOKEN = 50 BURNIE (50 * 1e6 base units)                                │ ║
║  │   Total cost = number of tokens × 50 BURNIE                                                     │ ║
║  │                                                                                                  │ ║
║  │   Note: No approval required; burns route through the trusted coin contract.                    │ ║
║  │   Address-level colors (setMyColors) are FREE - no BURNIE required.                             │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              ACCESS CONTROL                                                      │ ║
║  │                                                                                                  │ ║
║  │   Renderers (regular + trophy, fixed at deploy)                                                  │ ║
║  │      │                                                                                           │ ║
║  │      ├─► setMyColors()              Proxy for user's address-level defaults                     │ ║
║  │      ├─► setCustomColorsForMany()   Proxy for per-token overrides (batch)                       │ ║
║  │      └─► setTopAffiliateColor()     Proxy for affiliate trophy special color                    │ ║
║  │                                                                                                  │ ║
║  │   Anyone (view functions)                                                                        │ ║
║  │      │                                                                                           │ ║
║  │      ├─► tokenColor()          Read per-token color                                             │ ║
║  │      ├─► addressColor()        Read per-address color                                           │ ║
║  │      ├─► trophyOuter()         Read trophy size override                                        │ ║
║  │      └─► topAffiliateColor()   Read affiliate special color                                     │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  SECURITY CONSIDERATIONS                                                                              ║
║  ───────────────────────                                                                              ║
║                                                                                                       ║
║  1. ACCESS CONTROL                                                                                    ║
║     • onlyRenderer modifier gates all write operations                                                ║
║     • Renderer allowlist is fixed at deployment via DeployConstants                                   ║
║     • Ownership verification happens in write functions (ownerOf check)                               ║
║                                                                                                       ║
║  2. INPUT VALIDATION                                                                                  ║
║     • _requireHex7() enforces strict "#rrggbb" lowercase format                                       ║
║     • Invalid hex colors revert with InvalidHexColor()                                                ║
║     • Empty strings are allowed (used to clear/delete overrides)                                      ║
║                                                                                                       ║
║  3. ALLOWLIST                                                                                         ║
║     • Only _allowedToken contracts can have per-token overrides                                       ║
║     • Prevents arbitrary contracts from polluting storage                                             ║
║     • Initial NFT is allowed at construction                                                          ║
║                                                                                                       ║
║  4. REENTRANCY                                                                                        ║
║     • BURNIE burnCoin called before state changes (checks-effects-interactions)                       ║
║     • ownerOf is view-only call to trusted contracts                                                  ║
║     • All storage writes happen after external calls complete                                         ║
║                                                                                                       ║
║  5. TOKEN BURN SAFETY                                                                                 ║
║     • Uses burnCoin (direct burn from user balance, no approval)                                      ║
║     • BURNIE token is constant (set at deploy, cannot be changed)                                     ║
║     • No token accumulation in contract (burns directly from user)                                    ║
║                                                                                                       ║
║  6. GAS LIMITS                                                                                        ║
║     • setCustomColorsForMany loops over tokenIds (bounded by gas)                                     ║
║     • No explicit batch size limit; callers should limit to ~50-100 tokens                            ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  TRUST ASSUMPTIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. Renderer contract is trusted to correctly pass msg.sender as user                                 ║
║  2. Allowed token contracts implement ownerOf correctly                                               ║
║  3. Renderers are precomputed and must be correct at deployment                                       ║
║  4. BURNIE token implements burnCoin correctly (reverts on insufficient balance)                     ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  GAS OPTIMIZATIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. Uses delete for clearing strings (refunds gas)                                                    ║
║  2. Pre-validates hex strings once, stores validated result                                           ║
║  3. Batch operations reduce per-token overhead                                                        ║
║  4. Custom errors instead of require strings                                                          ║
║                                                                                                       ║
╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝
*/

import {IERC721Lite} from "./interfaces/IconRendererTypes.sol";

/// @notice Minimal interface for BURNIE token with trusted burn functionality
interface IDegenerusCoinBurn {
    /// @notice Burn tokens directly from a target address (trusted contract burn)
    function burnCoin(address target, uint256 amount) external;
}

/// @title IconColorRegistry
/// @notice Storage for per-token and per-address color customization in Degenerus NFT renders
/// @dev Accessed via renderer contracts; validates and stores "#rrggbb" hex color strings
contract IconColorRegistry {
    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Caller is not the authorized renderer contract
    error NotRenderer();

    /// @dev Required address was zero.
    error ZeroAddress();

    /// @dev Trophy outer percentage is outside valid range (5%-100% or special values 0/1)
    error InvalidTrophyOuterPercentage();

    /// @dev Hex color string is not valid "#rrggbb" lowercase format
    error InvalidHexColor();

    // ─────────────────────────────────────────────────────────────────────
    // STRUCTS
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Color preferences for 4 customizable channels
    /// @dev Empty strings indicate "not set" (use cascade fallback)
    struct Colors {
        string outline;   // Channel 0: Border/stroke color
        string flame;     // Channel 1: Center flame fill
        string diamond;   // Channel 2: Diamond background
        string square;    // Channel 3: Outer square background
    }

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS & WIRING
    // ─────────────────────────────────────────────────────────────────────

    /// @dev BURNIE token contract for recoloring fee burns
    IDegenerusCoinBurn private constant _burnie = IDegenerusCoinBurn(DeployConstants.COIN);

    /// @notice Cost in BURNIE per token for recoloring (50 BURNIE)
    uint256 public constant RECOLOR_COST_PER_TOKEN = 50 * 1e6;

    /// @dev Mapping of allowed token contracts for per-token customization
    mapping(address => bool) private _allowedToken;

    /// @dev Authorized renderer contracts (regular + trophy)
    address private constant _rendererRegular = DeployConstants.RENDERER_REGULAR;
    address private constant _rendererTrophy = DeployConstants.RENDERER_TROPHY;

    // ─────────────────────────────────────────────────────────────────────
    // STORAGE
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Per-address default colors (owner, referrer, upline preferences)
    mapping(address => Colors) private _addr;

    /// @dev Per-token color overrides: tokenContract => tokenId => Colors
    mapping(address => mapping(uint256 => Colors)) private _custom;

    /// @dev Special affiliate trophy ring color: tokenContract => tokenId => hexColor
    mapping(address => mapping(uint256 => string)) private _topAffiliate;

    /// @dev Trophy outer ring size override: tokenContract => tokenId => size (1e6-scaled %)
    ///      0 = not set, 1 = reset to default, 50000-1000000 = 5%-100%
    mapping(address => mapping(uint256 => uint32)) private _trophyOuterPct1e6;

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Deploy the color registry with precomputed contract addresses.
    constructor() {
        _allowedToken[DeployConstants.GAMEPIECES] = true;
        _allowedToken[DeployConstants.TROPHIES] = true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Restricts function to the authorized renderer contract
    modifier onlyRenderer() {
        if (msg.sender != _rendererRegular && msg.sender != _rendererTrophy) revert NotRenderer();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // WRITE FUNCTIONS (Renderer-Proxied)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Set per-address default colors for a user
    /// @dev Called by renderer on behalf of msg.sender
    /// @param user The address whose defaults to set
    /// @param outlineHex Outline color ("#rrggbb" or "" to clear)
    /// @param flameHex Flame color ("#rrggbb" or "" to clear)
    /// @param diamondHex Diamond color ("#rrggbb" or "" to clear)
    /// @param squareHex Square color ("#rrggbb" or "" to clear)
    /// @return success Always true on success
    function setMyColors(
        address user,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external onlyRenderer returns (bool) {
        Colors storage pref = _addr[user];

        // For each channel: empty string clears (deletes), non-empty validates and stores
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

    /// @notice Batch set per-token color overrides for multiple tokens
    /// @dev User must own all tokens. Validates hex colors strictly.
    /// @param user Token owner address (verified against ownerOf)
    /// @param tokenContract ERC721 contract address (must be in allowlist)
    /// @param tokenIds Array of token IDs to customize
    /// @param outlineHex Outline color ("#rrggbb" or "" to clear)
    /// @param flameHex Flame color ("#rrggbb" or "" to clear)
    /// @param diamondHex Diamond color ("#rrggbb" or "" to clear)
    /// @param squareHex Square color ("#rrggbb" or "" to clear)
    /// @param trophyOuterPct1e6 Trophy size: 0=no change, 1=reset, 50000-1000000=5%-100%
    /// @return success Always true on success
    function setCustomColorsForMany(
        address user,
        address tokenContract,
        uint256[] calldata tokenIds,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex,
        uint32 trophyOuterPct1e6
    ) external onlyRenderer returns (bool) {
        // Verify token contract is in allowlist
        if (!_allowedToken[tokenContract]) revert NotRenderer();

        // Charge BURNIE recoloring fee: 50 BURNIE per token, burned
        _chargeBurnie(user, tokenIds.length);

        // Pre-process clear flags and validate hex strings once
        bool clearOutline = (bytes(outlineHex).length == 0);
        bool clearFlame = (bytes(flameHex).length == 0);
        bool clearDiamond = (bytes(diamondHex).length == 0);
        bool clearSquare = (bytes(squareHex).length == 0);

        string memory outlineVal = clearOutline ? "" : _requireHex7(outlineHex);
        string memory flameVal = clearFlame ? "" : _requireHex7(flameHex);
        string memory diamondVal = clearDiamond ? "" : _requireHex7(diamondHex);
        string memory squareVal = clearSquare ? "" : _requireHex7(squareHex);

        // Validate trophy outer percentage if provided
        // Valid values: 0 (no change), 1 (reset/clear), 50000-1000000 (5%-100%)
        if (
            trophyOuterPct1e6 != 0 &&
            trophyOuterPct1e6 != 1 &&
            (trophyOuterPct1e6 < 50_000 || trophyOuterPct1e6 > 1_000_000)
        ) revert InvalidTrophyOuterPercentage();

        // Process each token
        IERC721Lite nftRef = IERC721Lite(tokenContract);
        uint256 count = tokenIds.length;
        for (uint256 i; i < count; ) {
            uint256 tokenId = tokenIds[i];

            // Verify user owns this token
            if (nftRef.ownerOf(tokenId) != user) revert NotRenderer();

            // Apply color overrides
            Colors storage c = _custom[tokenContract][tokenId];
            if (clearOutline) delete c.outline;
            else c.outline = outlineVal;
            if (clearFlame) delete c.flame;
            else c.flame = flameVal;
            if (clearDiamond) delete c.diamond;
            else c.diamond = diamondVal;
            if (clearSquare) delete c.square;
            else c.square = squareVal;

            // Apply trophy outer size override
            if (trophyOuterPct1e6 == 0) {
                // 0 = no change, keep existing value
            } else if (trophyOuterPct1e6 == 1) {
                // 1 = reset to default
                delete _trophyOuterPct1e6[tokenContract][tokenId];
            } else {
                // 50000-1000000 = set custom size
                _trophyOuterPct1e6[tokenContract][tokenId] = trophyOuterPct1e6;
            }

            unchecked {
                ++i;
            }
        }
        return true;
    }

    /// @notice Set special ring color for a top affiliate trophy
    /// @dev Only for affiliate trophy tokens
    /// @param user Token owner address (verified against ownerOf)
    /// @param tokenContract Trophy contract address (must be in allowlist)
    /// @param tokenId Affiliate trophy token ID
    /// @param trophyHex Special ring color ("#rrggbb" or "" to clear)
    /// @return success Always true on success
    function setTopAffiliateColor(
        address user,
        address tokenContract,
        uint256 tokenId,
        string calldata trophyHex
    ) external onlyRenderer returns (bool) {
        if (!_allowedToken[tokenContract]) revert NotRenderer();
        if (IERC721Lite(tokenContract).ownerOf(tokenId) != user) revert NotRenderer();

        if (bytes(trophyHex).length == 0) {
            delete _topAffiliate[tokenContract][tokenId];
            return true;
        }

        _topAffiliate[tokenContract][tokenId] = _requireHex7(trophyHex);
        return true;
    }

    // ─────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Read a per-token color override
    /// @param tokenContract The ERC721 contract address
    /// @param tokenId The token ID
    /// @param channel Color channel (0=outline, 1=flame, 2=diamond, 3=square)
    /// @return The hex color string, or "" if not set or contract not allowed
    function tokenColor(address tokenContract, uint256 tokenId, uint8 channel) external view returns (string memory) {
        if (!_allowedToken[tokenContract]) return "";
        Colors storage c = _custom[tokenContract][tokenId];
        if (channel == 0) return c.outline;
        if (channel == 1) return c.flame;
        if (channel == 2) return c.diamond;
        return c.square;
    }

    /// @notice Read a per-address default color
    /// @param user The address to query
    /// @param channel Color channel (0=outline, 1=flame, 2=diamond, 3=square)
    /// @return The hex color string, or "" if not set
    function addressColor(address user, uint8 channel) external view returns (string memory) {
        Colors storage c = _addr[user];
        if (channel == 0) return c.outline;
        if (channel == 1) return c.flame;
        if (channel == 2) return c.diamond;
        return c.square;
    }

    /// @notice Read the special affiliate trophy color
    /// @param tokenContract The trophy contract address
    /// @param tokenId The affiliate trophy token ID
    /// @return The hex color string, or "" if not set
    function topAffiliateColor(address tokenContract, uint256 tokenId) external view returns (string memory) {
        return _topAffiliate[tokenContract][tokenId];
    }

    /// @notice Read the trophy outer ring size override
    /// @param tokenContract The trophy contract address
    /// @param tokenId The trophy token ID
    /// @return The size as 1e6-scaled percentage (0 if not set)
    function trophyOuter(address tokenContract, uint256 tokenId) external view returns (uint32) {
        return _trophyOuterPct1e6[tokenContract][tokenId];
    }

    // ─────────────────────────────────────────────────────────────────────
    // INTERNAL HELPERS
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Charge and burn BURNIE tokens for recoloring (burns directly from user)
    /// @param user The user to charge
    /// @param tokenCount Number of tokens being recolored
    function _chargeBurnie(address user, uint256 tokenCount) private {
        if (tokenCount == 0) return;
        uint256 totalCost = tokenCount * RECOLOR_COST_PER_TOKEN;
        _burnie.burnCoin(user, totalCost);
    }

    /// @dev Validate and return a "#rrggbb" lowercase hex color string
    /// @param s The string to validate
    /// @return The validated string (unchanged if valid)
    /// @notice Reverts with InvalidHexColor if:
    ///         - Length is not exactly 7 characters
    ///         - First character is not '#'
    ///         - Characters 2-7 are not lowercase hex (0-9, a-f)
    function _requireHex7(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);

        // Must be exactly 7 characters: "#rrggbb"
        if (b.length != 7 || b[0] != bytes1("#")) revert InvalidHexColor();

        // Validate each hex character (positions 1-6)
        // Valid: 0-9 (48-57), a-f (97-102)
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
