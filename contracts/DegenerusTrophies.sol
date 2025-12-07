// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./interfaces/IDegenerusTrophies.sol";
import "./interfaces/IconRendererTypes.sol"; // for IERC721Lite compat

/**
 * @title DegenerusTrophies
 * @notice Minimal, non-transferable ERC721-like cosmetic trophies for Degenerus.
 * @dev Implements the ERC721 interface surface but reverts all transfer/approval flows.
 */
contract DegenerusTrophies is IDegenerusTrophies {
    // ---------------------------------------------------------------------
    // Errors / events
    // ---------------------------------------------------------------------
    error NotGame();
    error InvalidToken();
    error InvalidRenderer();
    error NotOwner();
    error GameAlreadySet();
    error TransfersDisabled();

    enum TrophyKind {
        Exterminator,
        Baf,
        Affiliate,
        Stake
    }

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event TrophyMinted(uint256 indexed tokenId, address indexed to, TrophyKind kind, uint24 level, uint8 trait);

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    uint256 private constant TROPHY_FLAG_INVERT = uint256(1) << 229;
    uint256 private constant AFFILIATE_TROPHY_FLAG = uint256(1) << 201;
    uint256 private constant BAF_TROPHY_FLAG = uint256(1) << 203;
    uint256 private constant STAKE_TROPHY_FLAG = uint256(1) << 202;
    uint256 private constant AFFILIATE_TRAIT_SENTINEL = 0xFFFE;
    uint256 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint256 private constant STAKE_TRAIT_SENTINEL = 0xFFFD;

    // ---------------------------------------------------------------------
    // Immutable wiring
    // ---------------------------------------------------------------------
    address public game;
    address public immutable renderer;
    address private immutable _owner;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    uint256 private _nextId = 1;
    uint256 private _totalSupply;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => uint256) private _trophyData;

    constructor(address renderer_) {
        if (renderer_ == address(0)) revert InvalidRenderer();
        _owner = msg.sender;
        renderer = renderer_;
    }

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    modifier onlyGame() {
        address g = game;
        if (g == address(0) || msg.sender != g) revert NotGame();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }

    function setGame(address game_) external onlyOwner {
        if (game == address(0)) {
            if (game_ == address(0)) revert InvalidRenderer();
            game = game_;
        } else {
            revert GameAlreadySet();
        }
    }

    // ---------------------------------------------------------------------
    // Minting
    // ---------------------------------------------------------------------
    function mintExterminator(
        address to,
        uint24 level,
        uint8 trait,
        bool invertFlag
    ) external override onlyGame returns (uint256 tokenId) {
        tokenId = _mint(to);
        uint256 data = (uint256(trait) << 152) | (uint256(level) << 128);
        if (invertFlag) {
            data |= TROPHY_FLAG_INVERT;
        }
        _trophyData[tokenId] = data;
        emit TrophyMinted(tokenId, to, TrophyKind.Exterminator, level, trait);
    }

    function mintBaf(address to, uint24 level) external override onlyGame returns (uint256 tokenId) {
        tokenId = _mint(to);
        uint256 data = (BAF_TRAIT_SENTINEL << 152) | (uint256(level) << 128) | BAF_TROPHY_FLAG;
        _trophyData[tokenId] = data;
        emit TrophyMinted(tokenId, to, TrophyKind.Baf, level, 0);
    }

    function mintAffiliate(address to, uint24 level) external override onlyGame returns (uint256 tokenId) {
        tokenId = _mint(to);
        uint256 data = (AFFILIATE_TRAIT_SENTINEL << 152) | (uint256(level) << 128) | AFFILIATE_TROPHY_FLAG;
        _trophyData[tokenId] = data;
        emit TrophyMinted(tokenId, to, TrophyKind.Affiliate, level, 0);
    }

    function mintStake(address to, uint24 level) external override onlyGame returns (uint256 tokenId) {
        tokenId = _mint(to);
        uint256 data = (STAKE_TRAIT_SENTINEL << 152) | (uint256(level) << 128) | STAKE_TROPHY_FLAG;
        _trophyData[tokenId] = data;
        emit TrophyMinted(tokenId, to, TrophyKind.Stake, level, 0);
    }

    function _mint(address to) private returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidToken();
        tokenId = _nextId++;
        _owners[tokenId] = to;
        unchecked {
            ++_balances[to];
            ++_totalSupply;
        }
        emit Transfer(address(0), to, tokenId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------
    function name() external pure returns (string memory) {
        return "Degenerus Trophies";
    }

    function symbol() external pure returns (string memory) {
        return "PGTROPHY";
    }

    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert InvalidToken();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _owners[tokenId];
        if (o == address(0)) revert InvalidToken();
        return o;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165
            interfaceId == 0x80ac58cd || // ERC721
            interfaceId == 0x5b5e139f; // ERC721Metadata
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert InvalidToken();
        uint32[4] memory extras;
        return ITrophyRenderer(renderer).tokenURI(tokenId, _trophyData[tokenId], extras);
    }

    function trophyData(uint256 tokenId) external view returns (uint256) {
        if (_owners[tokenId] == address(0)) revert InvalidToken();
        return _trophyData[tokenId];
    }

    // ---------------------------------------------------------------------
    // ERC721 surface (transfers/approvals disabled)
    // ---------------------------------------------------------------------
    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure {
        revert TransfersDisabled();
    }

    function setApprovalForAll(address, bool) external pure {
        revert TransfersDisabled();
    }

    function transferFrom(address, address, uint256) external pure {
        revert TransfersDisabled();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert TransfersDisabled();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert TransfersDisabled();
    }
}

interface ITrophyRenderer {
    function tokenURI(uint256 tokenId, uint256 data, uint32[4] calldata extras) external view returns (string memory);
}
