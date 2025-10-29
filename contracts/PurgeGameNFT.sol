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
    error NotCoinContract();
    error NotGame();
    error GameAlreadySet();
    error GameNotLinked();
    error TrophyBurnNotAllowed();
    error NotTrophyOwner();
    error NotTokenOwner();
    error NotMapTrophy();
    error ClaimNotReady();
    error CoinPaused();
    error NoRewards();
    error TransferFailed();
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
    uint256 private baseTokenId; // Mirrors game-side _baseTokenId for guard checks
    mapping(uint256 => uint256) private trophyData; // Metadata (level + flags) per trophy token
    mapping(uint256 => uint256) private trophyOwedWei; // Outstanding deferred ETH per trophy
    mapping(uint256 => uint32) private trophyLastClaimLevel; // Last level processed for vesting/claims

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
    uint256 private constant ETH_VEST_DURATION = 10; // levels

    constructor(address renderer_, address coin_) ERC721A("Purge Game", "PG") {
        renderer = IPurgeRenderer(renderer_);
        coin = IPurgecoin(coin_);
    }

    // ---------------------------------------------------------------------
    // Wiring / access control
    // ---------------------------------------------------------------------
    modifier onlyGame() {
        if (msg.sender != address(game)) revert NotGame();
        _;
    }

    function wireContracts(address game_) external {
        if (msg.sender != address(coin)) revert NotCoinContract();
        if (address(game) != address(0)) revert GameAlreadySet();
        if (game_ == address(0)) revert NotGame();
        game = IPurgeGame(game_);
        if (baseTokenId == 0) {
            _mintTrophyPlaceholders(1);
        }
    }

    // ---------------------------------------------------------------------
    // Game operations
    // ---------------------------------------------------------------------

    /// @notice Mint `quantity` tokens for the game contract.
    function gameMint(address to, uint256 quantity) external onlyGame returns (uint256 startTokenId) {
        startTokenId = _nextTokenId();
        _mint(to, quantity);
    }

    function _mintTrophyPlaceholders(uint24 level) private {
        uint256 startId = _nextTokenId();
        _mint(address(game), 2);
        uint256 mapTokenId = startId;
        uint256 levelTokenId = startId + 1;
        trophyData[mapTokenId] = (uint256(0xFFFF) << 152) | (uint256(level) << 128) | TROPHY_FLAG_MAP;
        trophyData[levelTokenId] = (uint256(0xFFFF) << 152) | (uint256(level) << 128);
        baseTokenId = levelTokenId + 1;
    }

    /// @notice Burn a token controlled by the game (non-trophies only).
    function purge(address owner, uint256 tokenId) external onlyGame {
        if (ownerOf(tokenId) != owner) revert NotTokenOwner();
        _burn(tokenId, false);
    }

    /// @notice Award a trophy placeholder, finalise metadata, and seed ETH vesting (if any).
    function awardTrophy(
        address to,
        uint256 data,
        uint256 deferredWei,
        uint24 startLevel
    ) external payable onlyGame {
        _awardTrophy(to, data, deferredWei, startLevel);
    }

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        onlyGame
        returns (address mapImmediateRecipient)
    {
        uint24 nextLevel = req.level + 1;

        bool traitWin = req.exterminator != address(0);
        uint24 rewardStartLevel = nextLevel;
        uint256 randomWord = req.randomWord;
        address mapRecipient;

        if (traitWin) {
            uint256 traitData = (uint256(req.traitId) << 152) | (uint256(req.level) << 128);
            _awardTrophy(req.exterminator, traitData, msg.value, rewardStartLevel);

            uint256 trophyPool = (req.level > 1) ? (req.pool / 20) : 0;
            if (trophyPool != 0) {
                uint256 salted = uint256(keccak256(abi.encode(randomWord, uint8(5))));
                (uint256[] memory trophyTokens, , uint256[] memory trophyAmounts, ) =
                    _sampleTrophies(true, trophyPool, salted);
                uint256 len = trophyTokens.length;
                for (uint256 i; i < len; ) {
                    uint256 amount = trophyAmounts[i];
                    if (amount != 0) {
                        _addTrophyReward(trophyTokens[i], amount, rewardStartLevel);
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
        } else {
            uint256 poolCarry = req.pool;
            uint256 mapShare = poolCarry / 10;
            uint256 immediateMap = mapShare >> 1;
            uint256 mapDeferred = mapShare - immediateMap;
            uint256 mapRandomShare = poolCarry / 20;
            uint256 currentBase = baseTokenId;
            uint256 mapTokenId = currentBase - 2;
            uint256 levelTokenId = currentBase - 1;

            mapRecipient = ownerOf(mapTokenId);


            _clearAndBurnTrophy(levelTokenId);
            

            _addTrophyReward(mapTokenId, mapDeferred, rewardStartLevel);
        


            (uint256[] memory trophyTokens, , uint256[] memory trophyAmounts, ) =
                _sampleTrophies(false, mapRandomShare, randomWord);
            uint256 len = trophyTokens.length;
            for (uint256 i; i < len; ) {
                uint256 amount = trophyAmounts[i];
                if (amount != 0) {
                    _addTrophyReward(trophyTokens[i], amount, rewardStartLevel);
                }
                unchecked {
                    ++i;
                }
            }
        
        }

        uint256 postBase = baseTokenId;

        uint256 placeholderData = trophyData[postBase - 1];
        uint24 placeholderLevel = uint24((placeholderData >> 128) & 0xFFFFFF);
        if (placeholderData == 0 || placeholderLevel != nextLevel) {
            _mintTrophyPlaceholders(nextLevel);
        }

        return mapRecipient;
    }

    function _calculateTrophyPayout(uint256 tokenId, uint24 currentLevel)
        private
        view
        returns (uint256 amount, uint24 lastClaim, uint24 stepsElapsed)
    {
        uint256 owed = trophyOwedWei[tokenId];
        if (owed == 0) return (0, 0, 0);

        uint256 info = trophyData[tokenId];
        if (info == 0) return (0, 0, 0);

        uint24 awardLevel = uint24((info >> 128) & 0xFFFFFF);
        uint24 startStep = awardLevel + 1;

        uint32 recorded = trophyLastClaimLevel[tokenId];
        lastClaim = recorded < startStep ? startStep : uint24(recorded);

        if (currentLevel <= lastClaim) return (0, lastClaim, 0);

        uint256 stepsCompleted = lastClaim > startStep ? uint256(lastClaim - startStep) : 0;
        if (stepsCompleted >= ETH_VEST_DURATION) return (owed, lastClaim, 0);

        uint256 remainingSteps = ETH_VEST_DURATION - stepsCompleted;
        uint256 elapsed = uint256(currentLevel - lastClaim);
        if (elapsed > remainingSteps) elapsed = remainingSteps;
        stepsElapsed = uint24(elapsed);

        amount = (owed * elapsed) / remainingSteps;
        if (amount == 0 && owed != 0) amount = owed; // prevent rounding lock-in
    }

    // ---------------------------------------------------------------------
    // Trophy reward claims (ETH)
    // ---------------------------------------------------------------------

    /// @notice Claim vested ETH for a trophy.
    function claimTrophyReward(uint256 tokenId) public {
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        uint24 currentLevel = game.level();
        (uint256 amount, uint24 lastClaim, uint24 stepsElapsed) = _calculateTrophyPayout(tokenId, currentLevel);
        if (amount == 0) revert ClaimNotReady();

        uint256 owed = trophyOwedWei[tokenId];
        if (amount >= owed) {
            trophyOwedWei[tokenId] = 0;
            trophyLastClaimLevel[tokenId] = uint32(currentLevel);
        } else {
            trophyOwedWei[tokenId] = owed - amount;
            uint24 nextLevel = stepsElapsed == 0 ? currentLevel : uint24(lastClaim + stepsElapsed);
            trophyLastClaimLevel[tokenId] = uint32(nextLevel);
        }

        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit TrophyRewardClaimed(tokenId, msg.sender, amount);
    }

event TrophyRewardClaimed(uint256 indexed tokenId, address indexed claimant, uint256 amount);

    function burnieNFT() external {
        if (msg.sender != address(coin)) revert OnlyCoin();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = payable(msg.sender).call{value: bal}("");
        if (!ok) revert TransferFailed();
    }

    // ---------------------------------------------------------------------
    // MAP Purgecoin drip
    // ---------------------------------------------------------------------

    function claimMapTrophyCoin(uint256 tokenId) external {
        if (coin.isBettingPaused()) revert CoinPaused();
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        uint256 info = trophyData[tokenId];
        if (info == 0 || (info & TROPHY_FLAG_MAP) == 0) revert NotMapTrophy();

        uint32 start = uint32((info >> 128) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
        uint32 levelNow = game.level();
        uint32 floor = start - 1;

        if (levelNow <= floor) revert ClaimNotReady();

        uint32 last = trophyLastClaimLevel[tokenId];
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

        trophyLastClaimLevel[tokenId] = levelNow;
        coin.bonusCoinflip(msg.sender, claimable);
    }

    // ---------------------------------------------------------------------
    // Views / metadata
    // ---------------------------------------------------------------------

    function ownerOf(uint256 tokenId) public view override returns (address) {
        if (address(game) == address(0)) revert GameNotLinked();
        uint256 info = trophyData[tokenId];
        if (info == 0 && tokenId < baseTokenId) revert InvalidToken();
        return super.ownerOf(tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        uint256 info = trophyData[tokenId];
        if (info != 0) {
            uint32[4] memory empty;
            return renderer.tokenURI(tokenId, info, empty);
        } else if (tokenId < baseTokenId) {
            revert InvalidToken();
        }

        (uint256 metaPacked, uint32[4] memory remaining) = game.describeBaseToken(tokenId);
        return renderer.tokenURI(tokenId, metaPacked, remaining);
    }

    function currentBaseTokenId() external view returns (uint256) {
        return baseTokenId;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _awardTrophy(address to, uint256 data, uint256 deferredWei, uint24 startLevel) private {
        bool isMap = (data & TROPHY_FLAG_MAP) != 0;
        uint256 tokenId = isMap ? baseTokenId - 2 : baseTokenId - 1;
        if ((isMap && baseTokenId < 2) || (!isMap && baseTokenId < 1)) revert InvalidToken();
        address currentOwner = super.ownerOf(tokenId);
        if (currentOwner == address(game)) {
            transferFrom(address(game), to, tokenId);
            if (isMap) {
                mapTrophyIds.push(tokenId);
            } else {
                levelTrophyIds.push(tokenId);
            }
        } else if (currentOwner != to) {
            revert NotTrophyOwner();
        }

        trophyData[tokenId] = data;

        if (deferredWei != 0) {
            trophyOwedWei[tokenId] += deferredWei;
            uint24 claimStart = startLevel != 0 ? startLevel : uint24((data >> 128) & 0xFFFFFF) + 1;
            trophyLastClaimLevel[tokenId] = uint32(claimStart);
        }
    }

    function _addTrophyReward(uint256 tokenId, uint256 amountWei, uint24 startLevel) private {
        if (amountWei == 0) return;
        trophyOwedWei[tokenId] += amountWei;
        if (startLevel != 0) {
            uint32 current = trophyLastClaimLevel[tokenId];
            if (startLevel > current) {
                trophyLastClaimLevel[tokenId] = uint32(startLevel);
            }
            uint256 info = trophyData[tokenId];
            if (info != 0) {
                uint256 cleared = info & ~(uint256(0xFFFFFF) << 128);
                trophyData[tokenId] = cleared | (uint256(startLevel - 1) << 128);
            }
        }
    }

    function _clearAndBurnTrophy(uint256 tokenId) private {
        delete trophyData[tokenId];
        delete trophyOwedWei[tokenId];
        delete trophyLastClaimLevel[tokenId];
        _burn(tokenId, false);
    }

    function _sampleTrophies(bool isExtermination, uint256 payout, uint256 randomWord)
        private
        view
        returns (uint256[] memory tokenIds, address[] memory owners, uint256[] memory amounts, uint256 distributed)
    {
        if (payout == 0) return (new uint256[](0), new address[](0), new uint256[](0), 0);

        uint256[] storage source = isExtermination ? levelTrophyIds : mapTrophyIds;
        uint256 len = source.length;
        if (len == 0) return (new uint256[](0), new address[](0), new uint256[](0), 0);

        uint256 draws = len < 3 ? len : 3;
        tokenIds = new uint256[](draws);
        owners = new address[](draws);
        amounts = new uint256[](draws);

        uint256 baseShare = payout / draws;
        uint256 remainder = payout - (baseShare * draws);

        bool[] memory used = new bool[](len);
        uint256 mask = type(uint64).max;

        for (uint256 i; i < draws; ) {
            uint256 idx = len == 1 ? 0 : (randomWord & mask) % len;
            randomWord >>= 64;
            while (used[idx]) {
                idx = (idx + 1) % len;
            }
            used[idx] = true;

            uint256 tokenId = source[idx];
            address owner = super.ownerOf(tokenId);
            tokenIds[i] = tokenId;
            owners[i] = owner;

            uint256 share = baseShare;
            if (remainder != 0) {
                share += remainder;
                remainder = 0;
            }
            amounts[i] = share;
            distributed += share;

            unchecked {
                ++i;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Internal overrides
    // ---------------------------------------------------------------------

    function _beforeTokenTransfers(address from, address to, uint256 tokenId, uint256 quantity) internal override {
        if (to == address(0) && trophyData[tokenId] != 0) revert TrophyBurnNotAllowed();
        super._beforeTokenTransfers(from, to, tokenId, quantity);
    }

    receive() external payable {
        revert NoRewards();
    }
}
