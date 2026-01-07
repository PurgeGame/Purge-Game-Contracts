// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
╔═══════════════════════════════════════════════════════════════════════════════════════════════════════╗
║                                       DegenerusTrophies                                               ║
║                          Soulbound ERC721 Trophies — Non-Transferable Achievements                    ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║                                                                                                       ║
║  ARCHITECTURE OVERVIEW                                                                                ║
║  ─────────────────────                                                                                ║
║  DegenerusTrophies is a minimal, gas-optimized soulbound NFT contract for game achievements.          ║
║  Implements the ERC721 interface surface but permanently disables all transfer/approval flows.        ║
║                                                                                                       ║
║  TROPHY TYPES                                                                                         ║
║  ────────────                                                                                         ║
║  1. Exterminator  - Awarded for eliminating the final trait at level end                              ║
║  2. BAF           - "Burn and Flip" trophy for strategic coinflip wins                                ║
║  3. Affiliate     - Awarded to top affiliate performers per level                                     ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              TROPHY DATA BIT LAYOUT (uint256)                                   │ ║
║  │                                                                                                  │ ║
║  │   ┌─────────────────────────────────────────────────────────────────────────────────────────┐   │ ║
║  │   │  Bit 229        │ TROPHY_FLAG_INVERT    │ Visual inversion flag for renderer            │   │ ║
║  │   │  Bit 203        │ BAF_TROPHY_FLAG       │ Identifies BAF trophy type                    │   │ ║
║  │   │  Bit 201        │ AFFILIATE_TROPHY_FLAG │ Identifies Affiliate trophy type              │   │ ║
║  │   │  Bits 152-167   │ trait (uint16)        │ Exterminator trait (low 8) or sentinel value  │   │ ║
║  │   │  Bits 128-151   │ level (uint24)        │ Game level when trophy was earned             │   │ ║
║  │   │  Bits 0-95      │ score (uint96)        │ Affiliate score or exterminator winnings      │   │ ║
║  │   └─────────────────────────────────────────────────────────────────────────────────────────┘   │ ║
║  │                                                                                                  │ ║
║  │   Sentinel Values:                                                                               │ ║
║  │   • AFFILIATE_TRAIT_SENTINEL (0xFFFE) - Indicates Affiliate trophy in trait field               │ ║
║  │   • BAF_TRAIT_SENTINEL (0xFFFA)       - Indicates BAF trophy in trait field                     │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  ┌──────────────────────────────────────────────────────────────────────────────────────────────────┐ ║
║  │                              MINTING FLOW                                                        │ ║
║  │                                                                                                  │ ║
║  │   DegenerusGame ────► onlyGame ────► mintExterminator() ────► _mint() ────► Transfer event      │ ║
║  │        │                                   │                                                     │ ║
║  │        ├─────────────────────────► mintBaf() ───────────────► _mint() ────► Transfer event      │ ║
║  │        │                                   │                                                     │ ║
║  │        └─────────────────────────► mintAffiliate() ─────────► _mint() ────► Transfer event      │ ║
║  │                                                                                                  │ ║
║  │   Note: All mints are gated by onlyGame modifier. Game address is fixed at deploy.             │ ║
║  └──────────────────────────────────────────────────────────────────────────────────────────────────┘ ║
║                                                                                                       ║
║  KEY INVARIANTS                                                                                       ║
║  ──────────────                                                                                       ║
║  • Tokens are permanently non-transferable (soulbound)                                                ║
║  • All transfer and approval setters revert (getters return zero/false)                               ║
║  • Once minted, a trophy cannot be burned or moved                                                    ║
║  • Token IDs are sequential starting from 1                                                           ║
║  • Only the game contract can mint trophies                                                           ║
║  • Game address can only be set once (one-time wiring pattern)                                        ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  SECURITY CONSIDERATIONS                                                                              ║
║  ───────────────────────                                                                              ║
║                                                                                                       ║
║  1. SOULBOUND ENFORCEMENT                                                                             ║
║     • All 5 transfer vectors blocked: transferFrom, safeTransferFrom (x2), approve, setApprovalForAll ║
║     • getApproved returns address(0), isApprovedForAll returns false                                  ║
║     • No internal _transfer function exists                                                           ║
║                                                                                                       ║
║  2. ACCESS CONTROL                                                                                    ║
║     • admin: none (addresses fixed at deploy)                                                        ║
║     • game: constant, set at construction                                                            ║
║     • renderer: constant, set at construction (use a router for upgradeable visuals)                 ║
║                                                                                                       ║
║  3. REENTRANCY                                                                                        ║
║     • No ETH handling (no payable functions, no withdrawals)                                          ║
║     • External call to renderer is view-only in tokenURI()                                            ║
║     • _mint follows checks-effects-interactions pattern                                               ║
║                                                                                                       ║
║  4. OVERFLOW SAFETY                                                                                   ║
║     • Token ID increment uses unchecked (safe: requires 2^256 mints to overflow)                      ║
║     • Balance increment uses unchecked (safe: same reasoning)                                         ║
║     • All bit operations are within uint256 bounds                                                    ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  TRUST ASSUMPTIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. Deployer is trusted to set the correct game address                                                ║
║  2. Game contract is trusted to mint trophies fairly and correctly                                    ║
║  3. Renderer contract is trusted to return valid tokenURI data                                        ║
║  4. Renderer will not revert maliciously (would block tokenURI for all tokens)                        ║
║                                                                                                       ║
╠═══════════════════════════════════════════════════════════════════════════════════════════════════════╣
║  GAS OPTIMIZATIONS                                                                                    ║
║  ─────────────────                                                                                    ║
║                                                                                                       ║
║  1. Affiliate score / exterminator winnings packed into bits 0-95 (saves 1 SSTORE per mint)           ║
║  2. Custom errors instead of require strings (~200 gas saved per revert)                              ║
║  3. unchecked blocks for safe arithmetic (~30 gas saved per operation)                                ║
║  4. No enumeration (ERC721Enumerable) - tokens tracked via events only                                ║
║  5. Minimal storage: only _owners, _balances, _trophyData mappings                                    ║
║                                                                                                       ║
╚═══════════════════════════════════════════════════════════════════════════════════════════════════════╝
*/

import "./interfaces/IDegenerusTrophies.sol";
import {DeployConstants} from "./DeployConstants.sol";

/// @title DegenerusTrophies
/// @notice Soulbound ERC721 trophies for Degenerus game achievements
/// @dev Implements ERC721 interface but reverts all transfer/approval operations
contract DegenerusTrophies is IDegenerusTrophies {
    // ─────────────────────────────────────────────────────────────────────
    // ERRORS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Caller is not the authorized game contract
    error NotGame();
    /// @dev Token does not exist or invalid address provided
    error InvalidToken();
    /// @dev Renderer address is zero (required at construction)
    error InvalidRenderer();
    /// @dev Address parameter is zero when non-zero required
    error ZeroAddress();
    /// @dev All transfer operations are permanently disabled (soulbound)
    error TransfersDisabled();

    // ─────────────────────────────────────────────────────────────────────
    // ENUMS
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Trophy categories awarded for different achievements
    enum TrophyKind {
        Exterminator, // Awarded for eliminating the final trait
        Baf,          // "Burn and Flip" strategic coinflip winner
        Affiliate     // Top affiliate performer for a level
    }

    // ─────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev ERC721 Transfer event - emitted on mint (from = address(0))
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    /// @dev ERC721 Approval event - never emitted (approvals disabled)
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    /// @dev ERC721 ApprovalForAll event - never emitted (approvals disabled)
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    /// @notice Emitted when a new trophy is minted
    /// @param tokenId The newly minted token ID
    /// @param to The recipient address
    /// @param kind The trophy category (Exterminator, Baf, or Affiliate)
    /// @param level The game level when the trophy was earned
    /// @param trait The trait ID for Exterminator trophies (0 for others)
    event TrophyMinted(uint256 indexed tokenId, address indexed to, TrophyKind kind, uint24 level, uint8 trait);

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────
    // Bit layout for _trophyData (uint256):
    //   Bits 0-95:    affiliate score or exterminator winnings (uint96, wei)
    //   Bits 128-151: level (uint24)
    //   Bits 152-167: trait (uint16; low 8 bits for exterminator)
    //   Bit 201:      AFFILIATE_TROPHY_FLAG
    //   Bit 203:      BAF_TROPHY_FLAG
    //   Bit 229:      TROPHY_FLAG_INVERT

    /// @dev Flag indicating visual inversion for renderer (bit 229)
    uint256 private constant TROPHY_FLAG_INVERT = uint256(1) << 229;
    /// @dev Flag identifying Affiliate trophy type (bit 201)
    uint256 private constant AFFILIATE_TROPHY_FLAG = uint256(1) << 201;
    /// @dev Flag identifying BAF trophy type (bit 203)
    uint256 private constant BAF_TROPHY_FLAG = uint256(1) << 203;
    /// @dev Sentinel value in trait field indicating Affiliate trophy
    uint256 private constant AFFILIATE_TRAIT_SENTINEL = 0xFFFE;
    /// @dev Sentinel value in trait field indicating BAF trophy
    uint256 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    /// @dev Bitmask to extract the low 96-bit score/winnings field
    uint256 private constant LOW_96_MASK = (uint256(1) << 96) - 1;

    // ─────────────────────────────────────────────────────────────────────
    // CONSTANTS & WIRING
    // ─────────────────────────────────────────────────────────────────────
    /// @notice The game contract authorized to mint trophies (constant).
    address private constant game = DeployConstants.GAME;
    /// @notice The renderer contract for generating tokenURI metadata (constant).
    address private constant renderer = DeployConstants.TROPHY_RENDERER_ROUTER;

    // ─────────────────────────────────────────────────────────────────────
    // STORAGE
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Next token ID to mint (starts at 1, increments monotonically)
    uint256 private _nextId = 1;
    /// @dev Mapping from token ID to owner address
    mapping(uint256 => address) private _owners;
    /// @dev Mapping from owner address to token count
    mapping(address => uint256) private _balances;
    /// @dev Mapping from token ID to packed trophy data (see bit layout above)
    mapping(uint256 => uint256) private _trophyData;

    // ─────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Deploy the trophy contract with fixed renderer and game addresses.
    // ─────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────
    /// @dev Restricts function to the authorized game contract
    modifier onlyGame() {
        address g = game;
        if (msg.sender != g) revert NotGame();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────
    // MINTING (Game-Only)
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Mint an Exterminator trophy for eliminating the final trait
    /// @param to Recipient address (will own the soulbound trophy)
    /// @param level Game level when the trait was exterminated
    /// @param trait The trait ID that was eliminated
    /// @param invertFlag Visual inversion flag for the renderer
    /// @param exterminationWinnings Total extermination winnings (wei) packed into bits 0-95
    /// @return tokenId The newly minted token ID
    function mintExterminator(
        address to,
        uint24 level,
        uint8 trait,
        bool invertFlag,
        uint96 exterminationWinnings
    ) external override onlyGame returns (uint256 tokenId) {
        tokenId = _mint(to);
        uint256 data = uint256(exterminationWinnings) | (uint256(trait) << 152) | (uint256(level) << 128);
        if (invertFlag) {
            data |= TROPHY_FLAG_INVERT;
        }
        _trophyData[tokenId] = data;
        emit TrophyMinted(tokenId, to, TrophyKind.Exterminator, level, trait);
    }

    /// @notice Mint a BAF (Burn and Flip) trophy for strategic coinflip wins
    /// @param to Recipient address (will own the soulbound trophy)
    /// @param level Game level when the BAF was achieved
    /// @return tokenId The newly minted token ID
    function mintBaf(address to, uint24 level) external override onlyGame returns (uint256 tokenId) {
        tokenId = _mint(to);
        uint256 data = (BAF_TRAIT_SENTINEL << 152) | (uint256(level) << 128) | BAF_TROPHY_FLAG;
        _trophyData[tokenId] = data;
        emit TrophyMinted(tokenId, to, TrophyKind.Baf, level, 0);
    }

    /// @notice Mint an Affiliate trophy for top affiliate performers
    /// @param to Recipient address (will own the soulbound trophy)
    /// @param level Game level when the affiliate achievement occurred
    /// @param score The affiliate's score (packed into bits 0-95)
    /// @return tokenId The newly minted token ID
    function mintAffiliate(address to, uint24 level, uint96 score) external override onlyGame returns (uint256 tokenId) {
        tokenId = _mint(to);
        // Pack score into bits 0-95, level into bits 128-151, trait sentinel into bits 152+, flag at bit 201
        uint256 data = uint256(score) | (uint256(level) << 128) | (AFFILIATE_TRAIT_SENTINEL << 152) | AFFILIATE_TROPHY_FLAG;
        _trophyData[tokenId] = data;
        emit TrophyMinted(tokenId, to, TrophyKind.Affiliate, level, 0);
    }

    /// @dev Internal mint logic - creates token and updates balances
    /// @param to Recipient address (must be non-zero)
    /// @return tokenId The newly minted token ID
    function _mint(address to) private returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidToken();
        tokenId = _nextId;
        unchecked {
            _nextId = tokenId + 1; // Safe: would require 2^256 mints to overflow
        }
        _owners[tokenId] = to;
        unchecked {
            ++_balances[to]; // Safe: same reasoning
        }
        emit Transfer(address(0), to, tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC721 METADATA
    // ─────────────────────────────────────────────────────────────────────
    /// @notice Collection name for ERC721 metadata
    /// @return The collection name "Degenerus Trophies"
    function name() external pure returns (string memory) {
        return "Degenerus Trophies";
    }

    /// @notice Collection symbol for ERC721 metadata
    /// @return The collection symbol "PGTROPHY"
    function symbol() external pure returns (string memory) {
        return "PGTROPHY";
    }

    /// @notice Total number of trophies minted
    /// @return The total supply (sequential IDs from 1 to totalSupply)
    function totalSupply() external view returns (uint256) {
        unchecked {
            return _nextId - 1; // Safe: _nextId starts at 1
        }
    }

    /// @notice Get the token count for an owner
    /// @param owner Address to query
    /// @return The number of tokens owned by the address
    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert InvalidToken();
        return _balances[owner];
    }

    /// @notice Get the owner of a specific token
    /// @param tokenId The token ID to query
    /// @return The owner address
    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _owners[tokenId];
        if (o == address(0)) revert InvalidToken();
        return o;
    }

    /// @notice ERC165 interface detection
    /// @param interfaceId The interface identifier to check
    /// @return True if the interface is supported
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f;   // ERC721Metadata
    }

    /// @notice Get the metadata URI for a token
    /// @dev Delegates to the constant renderer contract
    /// @param tokenId The token ID to query
    /// @return The metadata URI string
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert InvalidToken();
        uint256 data = _trophyData[tokenId];
        uint32[4] memory extras;
        // Extract low 96 bits (affiliate score or exterminator winnings) for renderer metadata.
        uint96 score = uint96(data & LOW_96_MASK);
        extras[0] = uint32(score);
        extras[1] = uint32(score >> 32);
        extras[2] = uint32(score >> 64);
        return ITrophyRenderer(renderer).tokenURI(tokenId, data, extras);
    }

    /// @notice Get the raw packed trophy data for a token
    /// @param tokenId The token ID to query
    /// @return The packed trophy data (see bit layout in contract header)
    function trophyData(uint256 tokenId) external view returns (uint256) {
        if (_owners[tokenId] == address(0)) revert InvalidToken();
        return _trophyData[tokenId];
    }

    // ─────────────────────────────────────────────────────────────────────
    // ERC721 TRANSFER SURFACE (ALL DISABLED - SOULBOUND)
    // ─────────────────────────────────────────────────────────────────────
    // These functions implement the ERC721 interface but permanently revert.
    // Trophies are soulbound and cannot be transferred or approved.

    /// @notice Get approved address for a token (always returns zero)
    /// @dev Approvals are disabled; included for ERC721 interface compliance
    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    /// @notice Check if operator is approved for all (always returns false)
    /// @dev Approvals are disabled; included for ERC721 interface compliance
    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    /// @notice Approve a spender (always reverts)
    /// @dev Soulbound tokens cannot be approved for transfer
    function approve(address, uint256) external pure {
        revert TransfersDisabled();
    }

    /// @notice Set approval for all (always reverts)
    /// @dev Soulbound tokens cannot be approved for transfer
    function setApprovalForAll(address, bool) external pure {
        revert TransfersDisabled();
    }

    /// @notice Transfer a token (always reverts)
    /// @dev Soulbound tokens cannot be transferred
    function transferFrom(address, address, uint256) external pure {
        revert TransfersDisabled();
    }

    /// @notice Safe transfer a token (always reverts)
    /// @dev Soulbound tokens cannot be transferred
    function safeTransferFrom(address, address, uint256) external pure {
        revert TransfersDisabled();
    }

    /// @notice Safe transfer a token with data (always reverts)
    /// @dev Soulbound tokens cannot be transferred
    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert TransfersDisabled();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// EXTERNAL INTERFACES
// ─────────────────────────────────────────────────────────────────────────────

/// @notice Interface for the trophy renderer contract
/// @dev Generates tokenURI metadata for each trophy type
interface ITrophyRenderer {
    /// @notice Generate the metadata URI for a trophy
    /// @param tokenId The token ID
    /// @param data The packed trophy data (contains level, trait, flags)
    /// @param extras Additional data (affiliate score or exterminator winnings split into uint32 chunks)
    /// @return The metadata URI string (typically base64-encoded JSON)
    function tokenURI(uint256 tokenId, uint256 data, uint32[4] calldata extras) external view returns (string memory);
}
