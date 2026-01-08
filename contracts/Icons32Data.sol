// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
+=======================================================================================================+
|                                         Icons32Data                                                   |
|                           On-Chain SVG Icon Path Storage for Degenerus                                |
+=======================================================================================================+
|                                                                                                       |
|  ARCHITECTURE OVERVIEW                                                                                |
|  ---------------------                                                                                |
|  Icons32Data is an immutable on-chain storage contract for SVG path data. It holds 33 icon           |
|  paths representing the symbols used in Degenerus gamepieces and trophies.                            |
|                                                                                                       |
|  +--------------------------------------------------------------------------------------------------+ |
|  |                              ICON INDEX LAYOUT                                                   | |
|  |                                                                                                  | |
|  |   _paths[0-7]   -► Quadrant 0 (Crypto):   Bitcoin, Ethereum, Litecoin, etc.                     | |
|  |   _paths[8-15]  -► Quadrant 1 (Zodiac):   Aries, Taurus, Gemini, etc.                           | |
|  |   _paths[16-23] -► Quadrant 2 (Cards):    Horseshoe, King, Cashsack, Club, Diamond, Heart       | |
|  |                                      Spade, Ace                                                 | |
|  |   _paths[24-31] -► Quadrant 3 (Dice):     1-8                                                   | |
|  |   _paths[32]    -► Affiliate Badge:       Special icon for affiliate trophies                   | |
|  |                                                                                                  | |
|  |   _diamond      -► Flame icon:            Center glyph for all token renders                    | |
|  |                                                                                                  | |
|  |   _symQ1[0-7]   -► Crypto symbol names:   "Bitcoin", "Ethereum", etc.                           | |
|  |   _symQ2[0-7]   -► Zodiac symbol names:   "Aries", "Taurus", etc.                               | |
|  |   _symQ3[0-7]   -► Cards symbol names:    "Horseshoe", "King", "Cashsack", "Club",               | |
|  |                                      "Diamond", "Heart", "Spade", "Ace"                         | |
|  |   (Q4 Dice names are generated dynamically: "1", "2", etc.)                                     | |
|  +--------------------------------------------------------------------------------------------------+ |
|                                                                                                       |
|  DESIGN RATIONALE                                                                                     |
|  ----------------                                                                                     |
|  1. On-chain storage ensures token metadata remains available even if IPFS/centralized              |
|     servers become unavailable.                                                                       |
|  2. Constructor-based initialization makes the data immutable after deployment.                      |
|  3. View functions allow efficient reading by renderers without state changes.                       |
|  4. SVG paths are stored as raw strings (not base64) to allow renderer flexibility.                  |
|                                                                                                       |
+=======================================================================================================+
|  SECURITY CONSIDERATIONS                                                                              |
|  -----------------------                                                                              |
|                                                                                                       |
|  1. IMMUTABILITY                                                                                      |
|     • All data is set at construction time and cannot be modified                                     |
|     • No admin functions, no upgrade path                                                             |
|     • Once deployed, icon data is permanent                                                           |
|                                                                                                       |
|  2. BOUNDS CHECKING                                                                                   |
|     • data(i) will revert if i >= 33 (array bounds)                                                   |
|     • symbol(q, idx) returns "" for invalid quadrant or out-of-range index                            |
|     • Renderers handle empty strings gracefully                                                       |
|                                                                                                       |
|  3. NO EXTERNAL CALLS                                                                                 |
|     • Pure data storage, no dependencies on other contracts                                           |
|     • Cannot be manipulated by external state changes                                                 |
|                                                                                                       |
|  4. GAS OPTIMIZATION                                                                                  |
|     • Uses storage arrays (not memory) for large path data                                            |
|     • View functions are free for off-chain calls                                                     |
|     • String data stored once, read many times                                                        |
|                                                                                                       |
+=======================================================================================================+
|  TRUST ASSUMPTIONS                                                                                    |
|  -----------------                                                                                    |
|                                                                                                       |
|  1. Deployer provides valid SVG path data at construction                                             |
|  2. Path data does not contain malicious SVG (script injection, etc.)                                 |
|  3. Symbol names are appropriate and accurate                                                         |
|                                                                                                       |
+=======================================================================================================+
*/

/// @title Icons32Data
/// @notice On-chain storage for Degenerus SVG icon paths and symbol names
/// @dev Immutable after construction; implements IIcons32 interface
contract Icons32Data {
    // ---------------------------------------------------------------------
    // STORAGE
    // ---------------------------------------------------------------------

    /// @dev SVG path data for 33 icons (32 quadrant symbols + 1 affiliate badge)
    ///      Each path is the "d" attribute content for an SVG <path> element
    ///      Paths are designed for a 512x512 viewBox
    string[33] private _paths;

    /// @dev The center flame/diamond icon path used in all token renders
    ///      Displayed in the central diamond shape of gamepiece and trophy SVGs
    string private _diamond;

    /// @dev Human-readable symbol names for Quadrant 0 (Crypto)
    ///      Examples: "Bitcoin", "Ethereum", "Dogecoin", "Solana"
    string[8] private _symQ1;

    /// @dev Human-readable symbol names for Quadrant 1 (Zodiac)
    ///      Examples: "Aries", "Taurus", "Gemini", "Cancer"
    string[8] private _symQ2;

    /// @dev Human-readable symbol names for Quadrant 2 (Cards)
    ///      Examples: "Horseshoe", "King", "Cashsack", "Club", "Diamond", "Heart", "Spade", "Ace"
    string[8] private _symQ3;

    // Note: Quadrant 3 (Dice) names are generated dynamically as "1" through "8"

    // ---------------------------------------------------------------------
    // CONSTRUCTOR
    // ---------------------------------------------------------------------

    /// @notice Deploy with all icon data (immutable after construction)
    /// @dev All arrays must be fully populated. Data cannot be changed post-deployment.
    /// @param paths_ Array of 33 SVG path strings (indices 0-31 for symbols, 32 for affiliate)
    /// @param diamond_ The center flame icon path string
    /// @param symQ1_ Array of 8 symbol names for Quadrant 0 (Crypto)
    /// @param symQ2_ Array of 8 symbol names for Quadrant 1 (Zodiac)
    /// @param symQ3_ Array of 8 symbol names for Quadrant 2 (Cards)
    constructor(
        string[33] memory paths_,
        string memory diamond_,
        string[8] memory symQ1_,
        string[8] memory symQ2_,
        string[8] memory symQ3_
    ) {
        // Copy path data to storage (33 icons total)
        for (uint256 i; i < 33; ++i) {
            _paths[i] = paths_[i];
        }

        // Store the central flame/diamond icon
        _diamond = diamond_;

        // Copy symbol names for each quadrant (8 symbols per quadrant)
        for (uint256 i; i < 8; ++i) {
            _symQ1[i] = symQ1_[i];
            _symQ2[i] = symQ2_[i];
            _symQ3[i] = symQ3_[i];
        }
    }

    // ---------------------------------------------------------------------
    // VIEW FUNCTIONS
    // ---------------------------------------------------------------------

    /// @notice Get the SVG path data for an icon by index
    /// @dev Reverts if index >= 33 (array bounds check)
    /// @param i Icon index: 0-31 for quadrant symbols, 32 for affiliate badge
    ///          Layout: i = (quadrant * 8) + symbolIndex
    /// @return The SVG path "d" attribute string for the icon
    function data(uint256 i) external view returns (string memory) {
        return _paths[i];
    }

    /// @notice Get the center diamond/flame icon path
    /// @dev Used as the central motif in gamepiece and trophy SVGs
    /// @return The flame icon SVG path string
    function diamond() external view returns (string memory) {
        return _diamond;
    }

    /// @notice Get the human-readable name for a symbol
    /// @dev Quadrant 3 (Dice) returns empty string; renderer generates "1..8" dynamically
    /// @param quadrant Quadrant index: 0=Crypto, 1=Zodiac, 2=Cards, 3=Dice
    /// @param idx Symbol index within the quadrant (0-7)
    /// @return The symbol name, or "" if quadrant is 3 or invalid
    function symbol(uint256 quadrant, uint8 idx) external view returns (string memory) {
        if (quadrant == 0) return _symQ1[idx];
        if (quadrant == 1) return _symQ2[idx];
        if (quadrant == 2) return _symQ3[idx];
        // Quadrant 3 (Dice) names are generated by the renderer as "1..8"
        return "";
    }
}
