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
    function describeBaseToken(uint256 tokenId)
        external
        view
        returns (uint256 metaPacked, uint32[4] memory remaining);

    function level() external view returns (uint24);
}

interface IPurgecoin {
    function bonusCoinflip(address player, uint256 amount) external;

    function isBettingPaused() external view returns (bool);
}

contract PurgeGameNFT is ERC721A {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error E();
    error NotTokenOwner();
    error NotTrophyOwner();
    error ClaimNotReady();
    error CoinPaused();
    error OnlyCoin();
    error InvalidToken();

    // ---------------------------------------------------------------------
    // Linked contracts
    // ---------------------------------------------------------------------
    IPurgeGame private game;
    IPurgeRenderer private immutable renderer;
    IPurgecoin private immutable coin;

    // ---------------------------------------------------------------------
    // Trophy bookkeeping
    // ---------------------------------------------------------------------
    uint256 private basePointers; // high 128 bits = previous base token id, low 128 bits = current base token id
    mapping(uint256 => uint256) private trophyData; // Packed metadata + owed + claim bookkeeping per trophy

    struct EndLevelRequest {
        address exterminator;
        uint8 traitId;
        uint24 level;
        uint256 pool;
        uint256 randomWord;
    }

    // Snapshot of all trophies ever awarded (no pruning required)
    uint256[] private mapTrophyIds;
    uint256[] private levelTrophyIds;

    uint32 private constant COIN_DRIP_STEPS = 10; // MAP coin drip cadence
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * 1_000_000; // 1000 PURGED (6 decimals)
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_BASE_LEVEL_MASK = uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;
    uint256 private constant TROPHY_LAST_CLAIM_MASK = uint256(0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT;

    function _currentBaseTokenId() private view returns (uint256) {
        return uint256(uint128(basePointers));
    }

    function _previousBaseTokenId() private view returns (uint256) {
        return basePointers >> 128;
    }

    function _setBasePointers(uint256 previousBase, uint256 currentBase) private {
        basePointers = (uint256(uint128(previousBase)) << 128) | uint128(currentBase);
    }

    constructor(address renderer_, address coin_) ERC721A("Purge Game", "PG") {
        renderer = IPurgeRenderer(renderer_);
        coin = IPurgecoin(coin_);
    }

    // ---------------------------------------------------------------------
    // Wiring / access control
    // ---------------------------------------------------------------------
    modifier onlyGame() {
        if (msg.sender != address(game)) revert E();
        _;
    }

    function wireContracts(address game_) external {
        if (msg.sender != address(coin)) revert E();
        game = IPurgeGame(game_);
        uint256 currentBase = _mintTrophyPlaceholders(1);
        _setBasePointers(0, currentBase);
    }

    // ---------------------------------------------------------------------
    // Game operations
    // ---------------------------------------------------------------------

    /// @notice Mint `quantity` tokens for the game contract.
    function gameMint(address to, uint256 quantity) external onlyGame returns (uint256 startTokenId) {
        startTokenId = _nextTokenId();
        _mint(to, quantity);
    }

    function prepareNextLevel(uint24 nextLevel) external onlyGame {
        uint256 previousBase = _currentBaseTokenId();
        uint256 currentBase = _mintTrophyPlaceholders(nextLevel);
        _setBasePointers(previousBase, currentBase);
    }

    function _mintTrophyPlaceholders(uint24 level) private returns (uint256 newBaseTokenId) {
        uint256 startId = _nextTokenId();
        _mint(address(game), 2);
        uint256 mapTokenId = startId;
        uint256 levelTokenId = startId + 1;
        trophyData[mapTokenId] =
            (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_MAP;
        trophyData[levelTokenId] = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT);
        newBaseTokenId = levelTokenId + 1;
    }

    /// @notice Burn a token controlled by the game (non-trophies only).
    function purge(address owner, uint256 tokenId) external onlyGame {
        if (ownerOf(tokenId) != owner) revert NotTokenOwner();
        _burn(tokenId, false);
    }

    /// @notice Award a trophy placeholder, finalise metadata, and seed ETH vesting (if any).
    function awardTrophy(address to, uint256 data, uint256 deferredWei) external payable onlyGame {
        bool isMap = (data & TROPHY_FLAG_MAP) != 0;
        uint256 baseTokenId = _currentBaseTokenId();
        uint256 tokenId = isMap ? (baseTokenId - 2) : (baseTokenId - 1);
        _awardTrophy(to, data, deferredWei, tokenId);
    }

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        onlyGame
        returns (address mapImmediateRecipient)
    {
        uint24 nextLevel = req.level + 1;
        uint256 previousBase = _previousBaseTokenId();
        uint256 levelTokenId = previousBase - 1;
        uint256 mapTokenId = previousBase - 2;

        bool traitWin = req.exterminator != address(0);
        uint256 randomWord = req.randomWord;

        if (traitWin) {
            uint256 traitData = (uint256(req.traitId) << 152) | (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT);
            uint256 legacyPool = (req.level > 1) ? (req.pool / 20) : 0;
            uint256 deferredAward = msg.value;
            if (legacyPool != 0) {
                deferredAward -= legacyPool;
            }
            _awardTrophy(req.exterminator, traitData, deferredAward, levelTokenId);

            if (legacyPool != 0) {
                uint256[] storage source = levelTrophyIds;
                uint256 trophyCount = source.length;
                if (trophyCount != 0) {
                    uint256 draws = trophyCount < 3 ? trophyCount : 3;
                    uint256 baseShare = legacyPool / draws;
                    uint256 rand = randomWord;
                    uint256 mask = type(uint64).max;
                    for (uint256 i; i < draws; ) {
                        uint256 idx = trophyCount == 1 ? 0 : (rand & mask) % trophyCount;
                        rand >>= 64;
                        _addTrophyReward(source[idx], baseShare, nextLevel);
                        unchecked {
                            ++i;
                        }
                    }
                }
            }
        } else {
            uint256 poolCarry = req.pool;
            uint256 mapUnit = poolCarry / 20;

            mapImmediateRecipient = ownerOf(mapTokenId);

            delete trophyData[levelTokenId];

            uint256 valueIn = msg.value;
            _addTrophyReward(mapTokenId, mapUnit, nextLevel);
            valueIn -= mapUnit;

            uint256 draws = valueIn / mapUnit;
            for (uint256 j; j < draws; ) {
                uint256 idx = mapTrophyIds.length == 1
                    ? 0
                    : (randomWord & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) % mapTrophyIds.length;
                uint256 tokenId = mapTrophyIds[idx];
                _addTrophyReward(tokenId, mapUnit, nextLevel);
                randomWord >>= 64;
                unchecked {
                    ++j;
                }
            }
        }
    }

    function claimTrophyReward(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        uint256 info = trophyData[tokenId];
        if (info == 0) revert InvalidToken();

        uint256 owed = info & TROPHY_OWED_MASK;
        if (owed == 0) revert ClaimNotReady();

        uint24 currentLevel = game.level();
        uint24 lastClaim = uint24((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);
        if (currentLevel <= lastClaim) revert ClaimNotReady();

        uint24 baseStartLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + 1;
        if (currentLevel < baseStartLevel) revert ClaimNotReady();

        uint32 vestEnd = uint32(baseStartLevel) + COIN_DRIP_STEPS;
        uint256 denom = vestEnd > currentLevel ? vestEnd - currentLevel : 1;
        uint256 payout = owed / denom;
        if (payout == 0) payout = owed;

        info = (info & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK))
            | ((owed - payout) & TROPHY_OWED_MASK)
            | (uint256(currentLevel & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
        trophyData[tokenId] = info;

        (bool ok, ) = msg.sender.call{value: payout}("");
        if (!ok) revert E();

        emit TrophyRewardClaimed(tokenId, msg.sender, payout);
    }

event TrophyRewardClaimed(uint256 indexed tokenId, address indexed claimant, uint256 amount);

    function burnieNFT() external {
        if (msg.sender != address(coin)) revert OnlyCoin();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = payable(msg.sender).call{value: bal}("");
        if (!ok) revert E();
    }

    // ---------------------------------------------------------------------
    // MAP Purgecoin drip
    // ---------------------------------------------------------------------

    function claimMapTrophyCoin(uint256 tokenId) external {
        if (coin.isBettingPaused()) revert CoinPaused();
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        uint256 info = trophyData[tokenId];
        if (info == 0 || (info & TROPHY_FLAG_MAP) == 0) revert ClaimNotReady();

        uint32 start = uint32((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
        uint32 levelNow = game.level();
        uint32 floor = start - 1;

        if (levelNow <= floor) revert ClaimNotReady();

        uint32 last = uint32((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);
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

        info = (info & ~TROPHY_LAST_CLAIM_MASK) | (uint256(levelNow & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
        trophyData[tokenId] = info;
        coin.bonusCoinflip(msg.sender, claimable);
    }

    // ---------------------------------------------------------------------
    // Views / metadata
    // ---------------------------------------------------------------------

    function ownerOf(uint256 tokenId) public view override returns (address) {
        uint256 info = trophyData[tokenId];
        if (info == 0 && tokenId < _currentBaseTokenId()) revert InvalidToken();
        return super.ownerOf(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        uint256 info = trophyData[tokenId];
        if (info != 0) {
            uint32[4] memory empty;
            return renderer.tokenURI(tokenId, info, empty);
        } else if (tokenId < _currentBaseTokenId()) {
            revert InvalidToken();
        }

        (uint256 metaPacked, uint32[4] memory remaining) = game.describeBaseToken(tokenId);
        return renderer.tokenURI(tokenId, metaPacked, remaining);
    }

    function currentBaseTokenId() external view returns (uint256) {
        return _currentBaseTokenId();
    }

    function getTrophyData(uint256 tokenId)
        external
        view
        returns (uint256 owedWei, uint24 baseLevel, uint24 lastClaimLevel, uint16 traitId, bool isMap)
    {
        uint256 raw = trophyData[tokenId];
        owedWei = raw & TROPHY_OWED_MASK;
        uint256 shiftedBase = raw >> TROPHY_BASE_LEVEL_SHIFT;
        baseLevel = uint24(shiftedBase);
        lastClaimLevel = uint24((raw >> TROPHY_LAST_CLAIM_SHIFT));
        traitId = uint16(raw >> 152);
        isMap = (raw & TROPHY_FLAG_MAP) != 0;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _awardTrophy(address to, uint256 data, uint256 deferredWei, uint256 tokenId) private {
        bool isMap = (data & TROPHY_FLAG_MAP) != 0;
        address currentOwner = super.ownerOf(tokenId);
        if (currentOwner == address(game)) {
            transferFrom(address(game), to, tokenId);
            if (isMap) {
                mapTrophyIds.push(tokenId);
            } else {
                levelTrophyIds.push(tokenId);
            }
        }

        uint256 newData = data & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK);
        if (deferredWei != 0) {
            uint256 owed = deferredWei & TROPHY_OWED_MASK;
            newData |= owed;
        }
        trophyData[tokenId] = newData;
    }

    function _addTrophyReward(uint256 tokenId, uint256 amountWei, uint24 startLevel) private {
        if (amountWei == 0) return;
        uint256 info = trophyData[tokenId];
        uint256 owed = (info & TROPHY_OWED_MASK) + amountWei;
        uint256 base = uint256((startLevel - 1) & 0xFFFFFF);
        uint256 updated = (info & ~(TROPHY_OWED_MASK | TROPHY_BASE_LEVEL_MASK))
            | (owed & TROPHY_OWED_MASK)
            | (base << TROPHY_BASE_LEVEL_SHIFT);
        trophyData[tokenId] = updated;
    }
    // ---------------------------------------------------------------------
    // Internal overrides
    // ---------------------------------------------------------------------

    function _beforeTokenTransfers(address from, address to, uint256 tokenId, uint256 quantity) internal override {
        if (to == address(0) && trophyData[tokenId] != 0) revert E();
        super._beforeTokenTransfers(from, to, tokenId, quantity);
    }

}
