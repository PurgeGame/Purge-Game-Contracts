// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "erc721a/contracts/ERC721A.sol";

interface IPurgeGameMetadataProvider {
    function describeToken(
        uint256 tokenId
    )
        external
        view
        returns (
            bool isTrophy,
            uint256 trophyInfo,
            uint256 metaPacked,
            uint32[4] memory remaining
        );
}

interface IPurgeRenderer {
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory);
}

contract PurgeGameNFT is ERC721A {
    // Errors -----------------------------------------------------------------
    error NotCreator();
    error NotGame();
    error GameAlreadySet();
    error GameNotLinked();
    // Immutable roles --------------------------------------------------------
    address public immutable creator;

    // Linked contracts ------------------------------------------------------
    address public game;
    IPurgeRenderer public renderer;
    IPurgeGameMetadataProvider public metadataProvider;

    constructor(address creator_) ERC721A("Purge Game", "PG") {
        creator = creator_;
    }

    // --- Admin ----------------------------------------------------------------

    function setGame(address game_, address renderer_) external {
        if (msg.sender != creator) revert NotCreator();
        if (game != address(0)) revert GameAlreadySet();
        if (game_ == address(0) || renderer_ == address(0)) revert GameNotLinked();

        game = game_;
        renderer = IPurgeRenderer(renderer_);
        metadataProvider = IPurgeGameMetadataProvider(game_);
    }

    // --- Game-restricted mint/burn -------------------------------------------

    modifier onlyGame() {
        if (msg.sender != game) revert NotGame();
        _;
    }

    function gameMint(
        address to,
        uint256 quantity
    ) external onlyGame returns (uint256 startTokenId) {
        startTokenId = _nextTokenId();
        _mint(to, quantity);
    }

    function gameBurn(uint256 tokenId) external onlyGame {
        _burn(tokenId, false);
    }

    function trophyAward(address to, uint256 tokenId) external onlyGame {
        transferFrom(game, to, tokenId);
    }

    // --- Views ----------------------------------------------------------------

    function ownerOf(
        uint256 tokenId
    ) public view override returns (address) {
        if (game == address(0)) revert GameNotLinked();
        metadataProvider.describeToken(tokenId);
        return super.ownerOf(tokenId);
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _exists(tokenId);
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        if (game == address(0) || address(renderer) == address(0)) revert GameNotLinked();

        (
            bool isTrophy,
            uint256 trophyInfo,
            uint256 metaPacked,
            uint32[4] memory remaining
        ) = metadataProvider.describeToken(tokenId);

        uint256 data = isTrophy ? trophyInfo : metaPacked;
        return renderer.tokenURI(tokenId, data, remaining);
    }
}
