// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import "erc721a/contracts/ERC721A.sol";

/**
 * @title PurgeGameNFT
 * @notice ERC721A collection controlled by the Purge game. Handles game-driven mint/burn flows,
 *         trophy transfers, and MAP trophy emission claims while delegating metadata to renderer.
 */
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
    IPurgeGame private game; // Set once by the coin contract after deployment
    IPurgeRenderer private immutable renderer; // On-chain renderer for metadata generation
    IPurgecoin private immutable coin; // Purgecoin contract (authorizes wiring + coin drips)

    mapping(uint256 => bool) private trophyToken; // Tracks which tokenIds are trophies (non-burnable)
    mapping(uint256 => uint32) private mapTrophyLastClaim; // MAP trophy -> last level claimed for drip

    uint32 private constant COIN_DRIP_STEPS = 10; // Number of levels across which MAP drips accrue
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * 1_000_000; // 1000 PURGED (6 decimals)
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200; // Flag in trophy metadata for MAP origin

    constructor(address renderer_, address coin_) ERC721A("Purge Game", "PG") {
        renderer = IPurgeRenderer(renderer_);
        coin = IPurgecoin(coin_);
    }

    // --- Admin ----------------------------------------------------------------

    /// @notice Wire the game contract once the coin deployer approves it.
    /// @dev Only callable by the coin contract to prevent arbitrary rewiring.
    function wireContracts(address game_) external {
        if (msg.sender != address(coin)) revert NotCoinContract();
        game = IPurgeGame(game_);
    }

    // --- Game-restricted mint/burn -------------------------------------------

    modifier onlyGame() {
        if (msg.sender != address(game)) revert NotGame();
        _;
    }

    /// @notice Game-controlled batch mint. Returns the starting token id for caller bookkeeping.
    function gameMint(address to, uint256 quantity) external onlyGame returns (uint256 startTokenId) {
        startTokenId = _nextTokenId();
        _mint(to, quantity);
    }

    /// @notice Game-controlled purge burn. Trophies are protected via `_beforeTokenTransfers`.
    function purge(uint256 tokenId) external onlyGame {
        _burn(tokenId, false);
    }

    /// @notice Transfer a trophy placeholder owned by the game to the awarded player.
    function trophyAward(address to, uint256 tokenId) external onlyGame {
        trophyToken[tokenId] = true;
        transferFrom(address(game), to, tokenId);
    }

    /// @notice Claim accumulated Purgecoin drip for a MAP trophy. Callable once per level window.
    function claimMapTrophyCoin(uint256 tokenId) external {
        if (coin.isBettingPaused()) revert CoinPaused();
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        (bool isTrophy, uint256 trophyInfo, , ) = game.describeToken(tokenId);
        if (!isTrophy || (trophyInfo & TROPHY_FLAG_MAP) == 0) revert NotMapTrophy();

        uint32 start = uint32((trophyInfo >> 128) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
        uint32 levelNow = game.level();
        uint32 floor = start - 1;

        if (levelNow <= floor) revert ClaimNotReady();

        uint32 last = mapTrophyLastClaim[tokenId];
        if (last < floor) last = floor;
        if (levelNow <= last) revert ClaimNotReady();

        uint32 from = last + 1;
        uint32 offsetStart = from - start;
        uint32 offsetEnd = levelNow - start;

        uint256 span = uint256(offsetEnd - offsetStart + 1);

        uint256 blocksEnd = offsetEnd / 10;
        uint256 blocksStart = offsetStart / 10;
        uint256 remEnd = offsetEnd % 10;
        uint256 remStart = offsetStart % 10;

        uint256 prefixEnd = ((blocksEnd * (blocksEnd - 1)) / 2) * 10 + blocksEnd * (remEnd + 1);
        uint256 prefixStart = ((blocksStart * (blocksStart - 1)) / 2) * 10 + blocksStart * (remStart + 1);

        uint256 claimable = COIN_EMISSION_UNIT * (span + (prefixEnd - prefixStart));

        mapTrophyLastClaim[tokenId] = levelNow;
        coin.bonusCoinflip(msg.sender, claimable);
    }

    /// @dev Prevent trophies from being burned by overriding the ERC721A pre-transfer hook.
    function _beforeTokenTransfers(address from, address to, uint256 tokenId, uint256 quantity) internal override {
        if (to == address(0) && trophyToken[tokenId]) revert TrophyBurnNotAllowed();
        super._beforeTokenTransfers(from, to, tokenId, quantity);
    }

    // --- Views ----------------------------------------------------------------

    /// @inheritdoc ERC721A
    /// @dev Ensures the game has been wired and forwards to the game for descriptor liveness.
    function ownerOf(uint256 tokenId) public view override returns (address) {
        game.describeToken(tokenId);
        return super.ownerOf(tokenId);
    }

    /// @inheritdoc ERC721A
    /// @dev Delegates metadata building to the on-chain renderer using game-sourced descriptors.
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        (bool isTrophy, uint256 trophyInfo, uint256 metaPacked, uint32[4] memory remaining) = game.describeToken(tokenId);

        uint256 data = isTrophy ? trophyInfo : metaPacked;
        return renderer.tokenURI(tokenId, data, remaining);
    }

    function sampleTrophies(
        bool isExtermination,
        uint256 payout,
        uint256 randomWord,
        uint256[] calldata pool
    )
        external
        view
        returns (address[] memory recipients, uint256[] memory amounts, uint256 count, uint256 distributed)
    {
        if (msg.sender != address(game)) revert NotGame();

        recipients = new address[](3);
        amounts = new uint256[](3);

        if (payout == 0) return (recipients, amounts, 0, 0);

        uint256 len = pool.length;
        if (len == 0) return (recipients, amounts, 0, 0);

        uint256 mask = type(uint64).max;
        uint256 baseShare;
        uint256 remainder;

        if (isExtermination) {
            baseShare = payout / 3;
            remainder = payout - (baseShare * 3);
        }

        for (uint256 draw; draw < 3; ) {
            uint256 idx = len == 1 ? 0 : (randomWord & mask) % len;
            randomWord >>= 64;
            uint256 tokenId = pool[idx];

            uint256 amount = isExtermination
                ? (draw < 2 ? baseShare : baseShare + remainder)
                : payout;

            if (amount != 0) {
                recipients[count] = ownerOf(tokenId);
                amounts[count] = amount;
                distributed += amount;
                unchecked {
                    ++count;
                }
            }

            unchecked {
                ++draw;
            }
        }

        return (recipients, amounts, count, distributed);
    }
}
