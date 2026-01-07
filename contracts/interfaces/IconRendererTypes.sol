// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                      IconRendererTypes                                                ║
║                           Shared Interfaces for Degenerus Renderer System                             ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                       ║
║  OVERVIEW                                                                                             ║
║  ────────                                                                                             ║
║  This file contains the minimal interfaces shared across the Degenerus rendering system:              ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              INTERFACE RELATIONSHIPS                                             │ ║
║  │                                                                                                  │ ║
║  │   IIcons32 ◄────────── IconRendererRegular32, IconRendererTrophy32, IconRendererTrophy32Svg      │ ║
║  │      │                                                                                           │ ║
║  │      └─ data(i)       Returns SVG path data for icon at index i (0-32)                           │ ║
║  │      └─ diamond()     Returns the flame/diamond center glyph path                                │ ║
║  │      └─ symbol(q,i)   Returns human-readable symbol name for quadrant q, index i                 │ ║
║  │                                                                                                  │ ║
║  │   IColorRegistry ◄─── IconRendererRegular32, IconRendererTrophy32Svg                             │ ║
║  │      │                                                                                           │ ║
║  │      └─ setMyColors()             Set per-address color preferences                              │ ║
║  │      └─ setCustomColorsForMany()  Set per-token color overrides (batch)                          │ ║
║  │      └─ setTopAffiliateColor()    Set special affiliate trophy color                             │ ║
║  │      └─ tokenColor()              Read per-token override for channel                            │ ║
║  │      └─ addressColor()            Read per-address default for channel                           │ ║
║  │      └─ trophyOuter()             Read trophy outer ring size override                           │ ║
║  │      └─ topAffiliateColor()       Read top affiliate special color                               │ ║
║  │                                                                                                  │ ║
║  │   IERC721Lite ◄────── IconColorRegistry, IconRendererRegular32, IconRendererTrophy32Svg          │ ║
║  │      │                                                                                           │ ║
║  │      └─ ownerOf()     Minimal ERC721 lookup for ownership verification                           │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  COLOR CHANNELS                                                                                       ║
║  ──────────────                                                                                       ║
║  The renderer uses 4 color channels for customization:                                                ║
║    Channel 0: outline   - Border/stroke color for frames and guides                                   ║
║    Channel 1: flame     - Center diamond flame fill color                                             ║
║    Channel 2: diamond   - Center diamond background fill color                                        ║
║    Channel 3: square    - Outer square background fill color                                          ║
║                                                                                                       ║
╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝
*/

// ─────────────────────────────────────────────────────────────────────────────
// ICON DATA INTERFACE
// ─────────────────────────────────────────────────────────────────────────────

/// @title IIcons32
/// @notice Interface for accessing SVG icon path data and symbol names
/// @dev Implemented by Icons32Data contract; stores 33 icon paths (32 symbols + 1 affiliate badge)
interface IIcons32 {
    /// @notice Get the SVG path data for an icon
    /// @param i Icon index (0-31 for quadrant symbols, 32 for affiliate badge)
    ///          Index layout: quadrant * 8 + symbolIndex
    ///          Q0 (Crypto):   0-7
    ///          Q1 (Zodiac):   8-15
    ///          Q2 (Cards): 16-23
    ///          Q3 (Dice):     24-31
    ///          Affiliate:     32
    /// @return The SVG path "d" attribute string
    function data(uint256 i) external view returns (string memory);

    /// @notice Get the center diamond/flame SVG path
    /// @dev Used as the central motif in both regular and trophy renders
    /// @return The flame icon SVG path string
    function diamond() external view returns (string memory);

    /// @notice Get the human-readable name for a symbol
    /// @param quadrant Quadrant index (0=Crypto, 1=Zodiac, 2=Cards, 3=Dice)
    /// @param idx Symbol index within the quadrant (0-7)
    /// @return The symbol name (e.g., "Bitcoin", "Aries", "5")
    function symbol(uint256 quadrant, uint8 idx) external view returns (string memory);
}

// ─────────────────────────────────────────────────────────────────────────────
// COLOR REGISTRY INTERFACE
// ─────────────────────────────────────────────────────────────────────────────

/// @title IColorRegistry
/// @notice Interface for managing per-token and per-address color customization
/// @dev Implemented by IconColorRegistry; stores hex color strings in "#rrggbb" format
interface IColorRegistry {
    /// @notice Set the caller's default color preferences for all their tokens
    /// @dev Colors cascade: per-token override → owner default → referrer → upline → theme default
    /// @param user The address whose preferences to set (must match msg.sender in renderer)
    /// @param outlineHex Outline/border color ("#rrggbb" lowercase, or "" to clear)
    /// @param flameHex Flame fill color ("#rrggbb" lowercase, or "" to clear)
    /// @param diamondHex Diamond background color ("#rrggbb" lowercase, or "" to clear)
    /// @param squareHex Square background color ("#rrggbb" lowercase, or "" to clear)
    /// @return success Always true on success, reverts on invalid input
    function setMyColors(
        address user,
        string calldata outlineHex,
        string calldata flameHex,
        string calldata diamondHex,
        string calldata squareHex
    ) external returns (bool);

    /// @notice Batch set per-token color overrides for multiple tokens
    /// @dev Caller must own all tokens. Validates hex format strictly.
    /// @param user The token owner (verified against ownerOf for each token)
    /// @param tokenContract The ERC721 contract address (must be in allowedToken list)
    /// @param tokenIds Array of token IDs to customize
    /// @param outlineHex Outline color override ("#rrggbb" or "" to clear)
    /// @param flameHex Flame color override ("#rrggbb" or "" to clear)
    /// @param diamondHex Diamond color override ("#rrggbb" or "" to clear)
    /// @param squareHex Square color override ("#rrggbb" or "" to clear)
    /// @param trophyOuterPct1e6 Trophy outer ring size (0=no change, 1=reset, 50000-1000000 = 5%-100%)
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
    ) external returns (bool);

    /// @notice Set the special color for a top affiliate trophy
    /// @dev Only for affiliate trophy type tokens
    /// @param user The token owner (verified against ownerOf)
    /// @param tokenContract The trophy contract address
    /// @param tokenId The affiliate trophy token ID
    /// @param trophyHex Special trophy color ("#rrggbb" or "" to clear)
    /// @return success Always true on success
    function setTopAffiliateColor(
        address user,
        address tokenContract,
        uint256 tokenId,
        string calldata trophyHex
    ) external returns (bool);

    /// @notice Register an additional token contract for color customization
    /// @dev Called by owner or renderer during wiring to enable trophy contracts
    /// @param tokenContract The ERC721 contract address to allow
    function addAllowedToken(address tokenContract) external;

    /// @notice Read a per-token color override
    /// @param tokenContract The ERC721 contract address
    /// @param tokenId The token ID
    /// @param channel Color channel (0=outline, 1=flame, 2=diamond, 3=square)
    /// @return The hex color string, or "" if not set
    function tokenColor(address tokenContract, uint256 tokenId, uint8 channel) external view returns (string memory);

    /// @notice Read a per-address default color
    /// @param user The address to query
    /// @param channel Color channel (0=outline, 1=flame, 2=diamond, 3=square)
    /// @return The hex color string, or "" if not set
    function addressColor(address user, uint8 channel) external view returns (string memory);

    /// @notice Read the trophy outer ring size override
    /// @param tokenContract The trophy contract address
    /// @param tokenId The trophy token ID
    /// @return The size as 1e6-scaled percentage (0 if not set)
    function trophyOuter(address tokenContract, uint256 tokenId) external view returns (uint32);

    /// @notice Read the top affiliate special color
    /// @param tokenContract The trophy contract address
    /// @param tokenId The affiliate trophy token ID
    /// @return The hex color string, or "" if not set
    function topAffiliateColor(address tokenContract, uint256 tokenId) external view returns (string memory);
}

// ─────────────────────────────────────────────────────────────────────────────
// MINIMAL ERC721 INTERFACE
// ─────────────────────────────────────────────────────────────────────────────

/// @title IERC721Lite
/// @notice Minimal ERC721 interface for ownership checks
/// @dev Used by renderers to verify token ownership without importing full ERC721
interface IERC721Lite {
    /// @notice Get the owner of a token
    /// @param tokenId The token ID to query
    /// @return The owner address (reverts if token doesn't exist)
    function ownerOf(uint256 tokenId) external view returns (address);
}
