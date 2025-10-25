// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "erc721a/contracts/ERC721A.sol";

interface IPurgeRenderer {
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory);
}

interface IPurgeGame {
    function describeToken(
        uint256 tokenId
    ) external view returns (bool isTrophy, uint256 trophyInfo, uint256 metaPacked, uint32[4] memory remaining);

    function level() external view returns (uint24);
}

interface IPurgecoin {
    function bonusCoinflip(address player, uint256 amount) external;

    function isBettingPaused() external view returns (bool);
}

contract PurgeGameNFT is ERC721A {
    // Errors -----------------------------------------------------------------
    error NotCoinContract();
    error NotGame();
    error GameAlreadySet();
    error GameNotLinked();
    error TrophyBurnNotAllowed();
    error NotTrophyOwner();
    error NotMapTrophy();
    error ClaimNotReady();
    error CoinPaused();
    // Linked contracts ------------------------------------------------------
    IPurgeGame private game;
    IPurgeRenderer private immutable renderer;
    IPurgecoin private immutable coin;

    mapping(uint256 => bool) private trophyToken;
    mapping(uint256 => uint32) private mapTrophyLastClaim;

    uint32 private constant COIN_DRIP_STEPS = 10;
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * 1_000_000; // 1000 PURGED (6 decimals)
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;

    constructor(address renderer_, address coin_) ERC721A("Purge Game", "PG") {
        renderer = IPurgeRenderer(renderer_);
        coin = IPurgecoin(coin_);
    }

    // --- Admin ----------------------------------------------------------------

    function wireContracts(address game_) external {
        if (msg.sender != address(coin)) revert NotCoinContract();
        if (game_ == address(0)) revert GameNotLinked();
        if (address(game) != address(0)) revert GameAlreadySet();
        game = IPurgeGame(game_);
    }

    // --- Game-restricted mint/burn -------------------------------------------

    modifier onlyGame() {
        if (msg.sender != address(game)) revert NotGame();
        _;
    }

    function gameMint(address to, uint256 quantity) external onlyGame returns (uint256 startTokenId) {
        startTokenId = _nextTokenId();
        _mint(to, quantity);
    }

    function gameBurn(uint256 tokenId) external onlyGame {
        _burn(tokenId, false);
    }

    function trophyAward(address to, uint256 tokenId) external onlyGame {
        trophyToken[tokenId] = true;
        transferFrom(address(game), to, tokenId);
    }

    function pendingMapTrophyCoin(uint256 tokenId) external view returns (uint256 claimable, uint24 claimThrough) {
        (claimable, uint32 through) = _pendingMapTrophyCoin(tokenId);
        return (claimable, uint24(through));
    }

    function claimMapTrophyCoin(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        (uint256 claimable, uint32 claimThrough) = _pendingMapTrophyCoin(tokenId);
        if (claimable == 0) revert ClaimNotReady();

        if (coin.isBettingPaused()) revert CoinPaused();

        mapTrophyLastClaim[tokenId] = claimThrough;
        coin.bonusCoinflip(msg.sender, claimable);
    }

    function _pendingMapTrophyCoin(uint256 tokenId) private view returns (uint256 claimable, uint32 claimThrough) {
        (bool isTrophy, uint256 trophyInfo, , ) = game.describeToken(tokenId);
        if (!isTrophy || (trophyInfo & TROPHY_FLAG_MAP) == 0) revert NotMapTrophy();

        uint32 awardLevel = uint32((trophyInfo >> 128) & 0xFFFFFF);
        uint32 emissionStart = awardLevel + COIN_DRIP_STEPS + 1;
        uint32 currentLevel = game.level();

        if (currentLevel < emissionStart) return (0, emissionStart - 1);

        uint32 lastClaim = mapTrophyLastClaim[tokenId];
        if (lastClaim < emissionStart - 1) lastClaim = emissionStart - 1;
        if (currentLevel <= lastClaim) return (0, lastClaim);

        uint32 fromLevel = lastClaim + 1;
        if (fromLevel < emissionStart) fromLevel = emissionStart;
        if (fromLevel > currentLevel) return (0, fromLevel - 1);

        uint32 toLevel = currentLevel;
        uint32 a = fromLevel - emissionStart;
        uint32 b = toLevel - emissionStart;

        uint256 count = uint256(b) - uint256(a) + 1;
        uint256 floorSum = _prefixFloor(b);
        if (a != 0) floorSum -= _prefixFloor(a - 1);

        uint256 total = COIN_EMISSION_UNIT * (count + floorSum);
        return (total, toLevel);
    }

    function _beforeTokenTransfers(address from, address to, uint256 tokenId, uint256 quantity) internal override {
        if (to == address(0) && trophyToken[tokenId]) revert TrophyBurnNotAllowed();
        super._beforeTokenTransfers(from, to, tokenId, quantity);
    }

    // --- Views ----------------------------------------------------------------

    function ownerOf(uint256 tokenId) public view override returns (address) {
        if (address(game) == address(0)) revert GameNotLinked();
        game.describeToken(tokenId);
        return super.ownerOf(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (address(game) == address(0) || address(renderer) == address(0)) revert GameNotLinked();

        (bool isTrophy, uint256 trophyInfo, uint256 metaPacked, uint32[4] memory remaining) = game.describeToken(tokenId);

        uint256 data = isTrophy ? trophyInfo : metaPacked;
        return renderer.tokenURI(tokenId, data, remaining);
    }

    function _prefixFloor(uint32 n) private pure returns (uint256) {
        uint256 m = n / 10;
        uint256 r = n % 10;
        return ((m * (m - 1)) / 2) * 10 + m * (r + 1);
    }
}
