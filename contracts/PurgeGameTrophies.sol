// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeGameNftModule {
    function nextTokenId() external view returns (uint256);
    function mintPlaceholders(uint256 quantity) external returns (uint256 startTokenId);
    function getBasePointers() external view returns (uint256 previousBase, uint256 currentBase);
    function setBasePointers(uint256 previousBase, uint256 currentBase) external;
    function packedOwnershipOf(uint256 tokenId) external view returns (uint256 packed);
    function transferTrophy(address from, address to, uint256 tokenId) external;
    function setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool staked) external;
    function clearApproval(uint256 tokenId) external;
    function incrementTrophySupply(uint256 amount) external;
    function decrementTrophySupply(uint256 amount) external;
    function gameAddress() external view returns (address);
    function coinAddress() external view returns (address);
    function rngLocked() external view returns (bool);
    function currentRngWord() external view returns (uint256);
}

uint8 constant PURGE_TROPHY_KIND_MAP = 0;
uint8 constant PURGE_TROPHY_KIND_LEVEL = 1;
uint8 constant PURGE_TROPHY_KIND_AFFILIATE = 2;
uint8 constant PURGE_TROPHY_KIND_STAKE = 3;

interface IPurgeGameTrophies {

    struct EndLevelRequest {
        address exterminator;
        uint16 traitId;
        uint24 level;
        uint256 pool;
    }

    function wire(address game_, address coin_) external;

    function clearStakePreview(uint24 level) external;

    function prepareNextLevel(uint24 nextLevel) external;

    function awardTrophy(address to, uint24 level, uint8 kind, uint256 data, uint256 deferredWei) external payable;

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        returns (address mapImmediateRecipient, address[6] memory affiliateRecipients);

    function claimTrophy(uint256 tokenId) external;

    function setTrophyStake(uint256 tokenId, bool isMap, bool stake) external;

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata levelTokenIds,
        uint256[] calldata stakeTokenIds
    ) external;

    function affiliateStakeBonus(address player) external view returns (uint8);

    function stakeTrophyBonus(address player) external view returns (uint8);

    function mapStakeDiscount(address player) external view returns (uint8);

    function levelStakeDiscount(address player) external view returns (uint8);


    function purgeTrophy(uint256 tokenId) external;

    function stakedTrophySample(uint64 salt) external view returns (address owner);

    function hasTrophy(uint256 tokenId) external view returns (bool);

    function trophyData(uint256 tokenId) external view returns (uint256 rawData);

    function burnieTrophies() external;
}

interface IPurgeGameMinimal {
    function level() external view returns (uint24);
    function gameState() external view returns (uint8);
}

interface IPurgecoinMinimal {
    function bonusCoinflip(address player, uint256 amount, bool rngReady, uint256 luckboxBonus) external;
    function burnCoin(address target, uint256 amount) external;

    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory);
}

contract PurgeGameTrophies is IPurgeGameTrophies {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyCoin();
    error InvalidToken();
    error StakeInvalid();
    error TrophyStakeViolation(uint8 reason);
    error ClaimNotReady();
    error CoinPaused();
    error AlreadyWired();
    error ZeroAddress();
    error Unauthorized();
    error TransferFailed();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event TrophyRewardClaimed(uint256 indexed tokenId, address indexed claimant, uint256 amount);
    event TrophyStakeChanged(
        address indexed owner,
        uint256 indexed tokenId,
        uint8 kind,
        bool staked,
        uint8 count,
        uint16 mapBonusBps
    );
    event StakeTrophyAwarded(address indexed to, uint256 indexed tokenId, uint24 level, uint256 principal);

    struct StakeParams {
        address player;
        uint256 tokenId;
        bool targetMap;
        bool targetAffiliate;
        bool targetLevel;
        bool targetStake;
        bool pureLevelTrophy;
        uint24 trophyBaseLevel;
        uint24 trophyLevelValue;
        uint24 effectiveLevel;
    }

    struct StakeEventData {
        uint8 kind;
        uint8 count;
        uint16 discountBps;
    }

    struct TraitWinContext {
        uint256 levelBits;
        uint256 traitData;
        uint256 sharedPool;
        uint256 base;
        uint256 stakerRewardPool;
        uint256 affiliateShare;
        uint256 deferredAward;
        uint256 rand;
        uint256 trophyCount;
        uint256 rounds;
        uint256 baseShare;
    }

    struct MapTimeoutContext {
        uint256 mapUnit;
        uint256 valueIn;
        address affiliateWinner;
        uint256 stakedCount;
        uint256 distributed;
        uint256 draws;
        uint256 rand;
    }

    struct ClaimContext {
        uint256 info;
        uint256 owed;
        uint256 newOwed;
        uint256 payout;
        uint256 coinAmount;
        uint24 currentLevel;
        uint24 lastClaim;
        uint24 updatedLast;
        bool ethClaimed;
        bool coinClaimed;
        bool isStaked;
    }

    // ---------------------------------------------------------------------
    // Trophy constants
    // ---------------------------------------------------------------------
    uint32 private constant COIN_DRIP_STEPS = 10;
    uint256 private constant COIN_BASE_UNIT = 1_000_000;
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * COIN_BASE_UNIT;
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_FLAG_AFFILIATE = uint256(1) << 201;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;
    uint256 private constant TROPHY_LAST_CLAIM_MASK = uint256(0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT;
    uint48 private constant _PLACEHOLDER_OFFSETS_PACKED = 0x050504030102;

    uint8 private constant _STAKE_ERR_TRANSFER_BLOCKED = 1;
    uint8 private constant _STAKE_ERR_NOT_LEVEL = 2;
    uint8 private constant _STAKE_ERR_ALREADY_STAKED = 3;
    uint8 private constant _STAKE_ERR_NOT_STAKED = 4;
    uint8 private constant _STAKE_ERR_LOCKED = 5;
    uint8 private constant _STAKE_ERR_NOT_MAP = 6;
    uint8 private constant _STAKE_ERR_NOT_AFFILIATE = 7;
    uint8 private constant _STAKE_ERR_NOT_STAKE = 8;

    uint8 private constant MAP_STAKE_MAX = 20;
    uint8 private constant LEVEL_STAKE_MAX = 20;
    uint8 private constant AFFILIATE_STAKE_MAX = 20;
    uint8 private constant STAKE_TROPHY_MAX = 20;

    uint16 private constant STAKE_TRAIT_SENTINEL = 0xFFFD;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    IPurgeGameNftModule public immutable nft;
    IPurgeGameMinimal private game;
    IPurgecoinMinimal private coin;

    address public gameAddress;
    address public coinAddress;

    uint256[] private stakedTrophyIds;
    mapping(uint256 => uint256) private stakedTrophyIndex; // 1-based index
    mapping(uint256 => bool) private trophyStaked;
    mapping(uint256 => uint256) private trophyData_;
    mapping(address => uint8) private mapStakeCount_;
    mapping(address => uint8) private mapStakeBonusPct_;
    mapping(address => uint8) private affiliateStakeCount_;
    mapping(address => uint24) private affiliateStakeBaseLevel_;
    mapping(address => uint8) private levelStakeCount_;
    mapping(address => uint8) private levelStakeBonusPct_;
    mapping(address => uint8) private stakeStakeCount_;
    mapping(address => uint8) private stakeStakeBonusPct_;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address nft_) {
        if (nft_ == address(0)) revert ZeroAddress();
        nft = IPurgeGameNftModule(nft_);
    }

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    function wire(address game_, address coin_) external override {
        if (gameAddress != address(0)) revert AlreadyWired();
        if (game_ == address(0) || coin_ == address(0)) revert ZeroAddress();
        if (msg.sender != coin_) revert OnlyCoin();
        gameAddress = game_;
        coinAddress = coin_;
        game = IPurgeGameMinimal(game_);
        coin = IPurgecoinMinimal(coin_);
    }

    modifier onlyGame() {
        if (msg.sender != gameAddress) revert Unauthorized();
        _;
    }

    modifier onlyCoinCaller() {
        if (msg.sender != coinAddress) revert OnlyCoin();
        _;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _stakePreviewData(uint24 level) private pure returns (uint256) {
        uint24 baseLevel = level == 0 ? 0 : uint24(level - 1);
        return
            (uint256(STAKE_TRAIT_SENTINEL) << 152) |
            (uint256(baseLevel) << TROPHY_BASE_LEVEL_SHIFT) |
            TROPHY_FLAG_STAKE;
    }

    function _placeholderTokenId(uint24 level, uint8 kind) private view returns (uint256) {
        if (kind > PURGE_TROPHY_KIND_STAKE) return 0;
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();

        uint256 base;
        if (level == currentLevel) {
            base = currentBase;
        } else if (level + 1 == currentLevel) {
            base = previousBase;
        }
        if (base == 0) return 0;

        uint8 offset = uint8(_PLACEHOLDER_OFFSETS_PACKED >> (uint8(kind) * 8));
        return base - offset;
    }


    function _setTrophyData(uint256 tokenId, uint256 data) private {
        trophyData_[tokenId] = data;
    }

    function _eraseTrophy(uint256 tokenId, uint8 kind, bool adjustSupply) private returns (bool hadData) {
        if (trophyStaked[tokenId]) revert StakeInvalid();
        hadData = trophyData_[tokenId] != 0;
        delete trophyData_[tokenId];
        nft.setTrophyPackedInfo(tokenId, kind, false);
        if (adjustSupply && hadData) {
            nft.decrementTrophySupply(1);
        }
    }

    function _returnValue(address target, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = payable(target).call{value: amount}("");
        if (!ok) {
            // best-effort refund; ignore failure to avoid bubbling a revert
        }
    }

    function _awardTrophyData(
        address to,
        uint256 tokenId,
        uint256 data,
        uint256 deferredWei
    ) private returns (bool incrementSupply) {
        uint256 prevData = trophyData_[tokenId];
        uint256 newData = (data & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK)) | (deferredWei & TROPHY_OWED_MASK);
        trophyData_[tokenId] = newData;
        if (prevData == 0 && newData != 0 && to != gameAddress) {
            incrementSupply = true;
        }
    }

    function _addTrophyRewardInternal(uint256 tokenId, uint256 amountWei, uint24 startLevel) private {
        uint256 info = trophyData_[tokenId];
        uint256 owed = (info & TROPHY_OWED_MASK) + amountWei;
        uint256 base = uint256((startLevel - 1) & 0xFFFFFF);
        uint256 updated = (info & ~(TROPHY_OWED_MASK | (uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT)))
            | (owed & TROPHY_OWED_MASK)
            | (base << TROPHY_BASE_LEVEL_SHIFT);
        trophyData_[tokenId] = updated;
    }

    function _addStakedTrophy(uint256 tokenId) private {
        stakedTrophyIndex[tokenId] = stakedTrophyIds.length + 1;
        stakedTrophyIds.push(tokenId);
    }

    function _removeStakedTrophy(uint256 tokenId) private {
        uint256 index = stakedTrophyIndex[tokenId];
        if (index == 0) return;
        uint256 lastIndex = stakedTrophyIds.length;
        if (index != lastIndex) {
            uint256 lastId = stakedTrophyIds[lastIndex - 1];
            stakedTrophyIds[index - 1] = lastId;
            stakedTrophyIndex[lastId] = index;
        }
        stakedTrophyIds.pop();
        delete stakedTrophyIndex[tokenId];
    }

    function _mapDiscountCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 7;
        if (count == 2) return 12;
        if (count == 3) return 15;
        if (count == 4) return 20;
        return 25;
    }

    function _levelDiscountCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 5;
        if (count == 2) return 10;
        if (count == 3) return 15;
        if (count == 4) return 20;
        return 25;
    }

    function _stakeBonusCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 5;
        if (count == 2) return 10;
        if (count == 3) return 15;
        return 20;
    }

    function _ensurePlayerOwnsStaked(address player, uint256 tokenId) private view {
        if (!trophyStaked[tokenId]) revert StakeInvalid();
        address owner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (owner != player) revert StakeInvalid();
    }

    function _currentAffiliateBonus(address player, uint24 effectiveLevel) private view returns (uint8) {
        uint8 count = affiliateStakeCount_[player];
        if (count == 0) return 0;
        uint24 baseLevel = affiliateStakeBaseLevel_[player];
        uint24 levelsHeld = effectiveLevel > baseLevel ? effectiveLevel - baseLevel : 0;
        uint256 effectiveBonus = uint256(levelsHeld) * uint256(count);
        uint256 cap = 10 + (uint256(count - 1) * 5);
        if (cap > 25) cap = 25;
        if (effectiveBonus > cap) effectiveBonus = cap;
        return uint8(effectiveBonus);
    }

    function _stakeInternal(StakeParams memory params) private returns (StakeEventData memory data) {
        if (trophyData_[params.tokenId] == 0) revert StakeInvalid();
        if (trophyStaked[params.tokenId]) revert TrophyStakeViolation(_STAKE_ERR_ALREADY_STAKED);
        uint256 info = trophyData_[params.tokenId];
        uint256 owed = info & TROPHY_OWED_MASK;
        if (owed != 0) {
            uint256 levelBits = uint256(params.effectiveLevel & 0xFFFFFF);
            uint256 baseCleared = info & ~(uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT);
            uint256 lastCleared = baseCleared & ~TROPHY_LAST_CLAIM_MASK;
            uint256 updatedInfo =
                lastCleared |
                (levelBits << TROPHY_BASE_LEVEL_SHIFT) |
                (levelBits << TROPHY_LAST_CLAIM_SHIFT);
            trophyData_[params.tokenId] = updatedInfo;
            info = updatedInfo;
        }
        trophyStaked[params.tokenId] = true;
        _addStakedTrophy(params.tokenId);

        uint8 discountPct;

        if (params.targetMap) {
            uint8 current = mapStakeCount_[params.player];
            if (current >= MAP_STAKE_MAX) revert StakeInvalid();
            unchecked {
                current += 1;
            }
            mapStakeCount_[params.player] = current;
            uint8 cap = _mapDiscountCap(current);
            uint8 candidate = params.trophyBaseLevel > cap ? cap : uint8(params.trophyBaseLevel);
            uint8 prev = mapStakeBonusPct_[params.player];
            if (candidate > prev) {
                mapStakeBonusPct_[params.player] = candidate;
                discountPct = candidate;
            } else {
                discountPct = prev;
            }
            data.kind = 1;
            data.count = current;
        } else if (params.targetAffiliate) {
            uint8 before = affiliateStakeCount_[params.player];
            if (before >= AFFILIATE_STAKE_MAX) revert StakeInvalid();
            uint8 current = before + 1;
            affiliateStakeCount_[params.player] = current;
            affiliateStakeBaseLevel_[params.player] = params.effectiveLevel;
            discountPct = _currentAffiliateBonus(params.player, params.effectiveLevel);
            data.kind = 2;
            data.count = current;
        } else if (params.targetLevel) {
            if (params.pureLevelTrophy) {
                uint8 current = levelStakeCount_[params.player];
                if (current >= LEVEL_STAKE_MAX) revert StakeInvalid();
                unchecked {
                    current += 1;
                }
                levelStakeCount_[params.player] = current;
                uint8 cap = _levelDiscountCap(current);
                uint8 candidate = params.trophyBaseLevel > cap ? cap : uint8(params.trophyBaseLevel);
                uint8 prev = levelStakeBonusPct_[params.player];
                if (candidate > prev) {
                    levelStakeBonusPct_[params.player] = candidate;
                }
            }
            discountPct = levelStakeBonusPct_[params.player];
            data.kind = 3;
            data.count = levelStakeCount_[params.player];
        } else {
            uint8 current = stakeStakeCount_[params.player];
            if (current >= STAKE_TROPHY_MAX) revert StakeInvalid();
            unchecked {
                current += 1;
            }
            stakeStakeCount_[params.player] = current;
            uint8 cap = _stakeBonusCap(current);
            uint8 candidate = params.trophyLevelValue > cap ? cap : uint8(params.trophyLevelValue);
            uint8 prev = stakeStakeBonusPct_[params.player];
            if (candidate > prev) {
                stakeStakeBonusPct_[params.player] = candidate;
            }
            discountPct = stakeStakeBonusPct_[params.player];
            data.kind = 4;
            data.count = current;
        }

        data.discountBps = uint16(discountPct) * 100;
        return data;
    }

    function _unstakeInternal(StakeParams memory params) private returns (StakeEventData memory data) {
        if (trophyData_[params.tokenId] == 0) revert StakeInvalid();
        if (!trophyStaked[params.tokenId]) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKED);
        trophyStaked[params.tokenId] = false;
        _removeStakedTrophy(params.tokenId);

        if (params.targetMap) {
            uint8 current = mapStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            mapStakeCount_[params.player] = current;
            if (current == 0) {
                mapStakeBonusPct_[params.player] = 0;
            } else if (mapStakeBonusPct_[params.player] > _mapDiscountCap(current)) {
                mapStakeBonusPct_[params.player] = _mapDiscountCap(current);
            }
            data.kind = 1;
            data.count = current;
        } else if (params.targetAffiliate) {
            uint8 current = affiliateStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            affiliateStakeCount_[params.player] = current;
            if (current == 0) {
                affiliateStakeBaseLevel_[params.player] = 0;
            }
            data.kind = 2;
            data.count = current;
        } else if (params.targetLevel) {
            uint8 current = levelStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            levelStakeCount_[params.player] = current;
            if (current == 0) {
                levelStakeBonusPct_[params.player] = 0;
            } else if (levelStakeBonusPct_[params.player] > _levelDiscountCap(current)) {
                levelStakeBonusPct_[params.player] = _levelDiscountCap(current);
            }
            data.kind = 3;
            data.count = current;
        } else {
            uint8 current = stakeStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            stakeStakeCount_[params.player] = current;
            if (current == 0) {
                stakeStakeBonusPct_[params.player] = 0;
            } else if (stakeStakeBonusPct_[params.player] > _stakeBonusCap(current)) {
                stakeStakeBonusPct_[params.player] = _stakeBonusCap(current);
            }
            data.kind = 4;
            data.count = current;
        }

        data.discountBps = 0;
        return data;
    }

    function _refreshMapBonus(address player, uint256[] calldata tokenIds) private {
        uint8 expected = mapStakeCount_[player];
        if (tokenIds.length == 0) {
            if (expected == 0) {
                mapStakeBonusPct_[player] = 0;
                return;
            }
            revert StakeInvalid();
        }
        if (expected == 0 || tokenIds.length != expected) revert StakeInvalid();
        uint24 best;
        for (uint256 i; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            if ((info & TROPHY_FLAG_MAP) == 0) revert StakeInvalid();
            uint24 base = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
            if (base > best) best = base;
            unchecked {
                ++i;
            }
        }
        if (best == 0) revert StakeInvalid();
        uint8 cap = _mapDiscountCap(expected);
        mapStakeBonusPct_[player] = uint8(best > cap ? cap : best);
    }

    function _refreshLevelBonus(address player, uint256[] calldata tokenIds) private {
        uint8 expected = levelStakeCount_[player];
        if (tokenIds.length == 0) {
            if (expected == 0) {
                levelStakeBonusPct_[player] = 0;
                return;
            }
            revert StakeInvalid();
        }
        if (expected == 0 || tokenIds.length != expected) revert StakeInvalid();
        uint24 best;
        for (uint256 i; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            bool invalid = (info & TROPHY_FLAG_MAP) != 0
                || (info & TROPHY_FLAG_AFFILIATE) != 0
                || (info & TROPHY_FLAG_STAKE) != 0;
            if (invalid) revert StakeInvalid();
            uint24 base = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
            if (base > best) best = base;
            unchecked {
                ++i;
            }
        }
        if (best == 0) revert StakeInvalid();
        uint8 cap = _levelDiscountCap(expected);
        levelStakeBonusPct_[player] = uint8(best > cap ? cap : best);
    }

    function _refreshStakeBonus(address player, uint256[] calldata tokenIds) private {
        uint8 expected = stakeStakeCount_[player];
        if (tokenIds.length == 0) {
            if (expected == 0) {
                stakeStakeBonusPct_[player] = 0;
                return;
            }
            revert StakeInvalid();
        }
        if (expected == 0 || tokenIds.length != expected) revert StakeInvalid();
        uint24 best;
        for (uint256 i; i < tokenIds.length; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            if ((info & TROPHY_FLAG_STAKE) == 0) revert StakeInvalid();
            uint24 value = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + 1;
            if (value > best) best = value;
            unchecked {
                ++i;
            }
        }
        if (best == 0) revert StakeInvalid();
        uint8 cap = _stakeBonusCap(expected);
        stakeStakeBonusPct_[player] = uint8(best > cap ? cap : best);
    }

    function _mintTrophyPlaceholders(uint24 level) private returns (uint256 newBaseTokenId) {
        uint256 baseData = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT);
        uint256 placeholderCount = 4;
        uint256 startId = nft.nextTokenId();
        uint256 mintedCount = placeholderCount;

        uint256 projectedLastId = startId + mintedCount - 1;
        uint256 remainder = projectedLastId % 100;
        if (remainder != 0) {
            mintedCount += 100 - remainder;
        }

        uint256 mintedStart = nft.mintPlaceholders(mintedCount);
        if (mintedStart != startId) {
            // Defensive: NFT must mint sequentially.
            revert InvalidToken();
        }

        uint256 firstPlaceholderId = startId + mintedCount - placeholderCount;
        uint256 nextId = firstPlaceholderId;

        uint256 stakeTokenId = nextId++;
        _setTrophyData(stakeTokenId, _stakePreviewData(level));
        nft.setTrophyPackedInfo(stakeTokenId, PURGE_TROPHY_KIND_STAKE, false);

        uint256 affiliateTokenId = nextId++;
        _setTrophyData(affiliateTokenId, baseData | TROPHY_FLAG_AFFILIATE);
        nft.setTrophyPackedInfo(affiliateTokenId, PURGE_TROPHY_KIND_AFFILIATE, false);

        uint256 mapTokenId = nextId++;
        _setTrophyData(mapTokenId, baseData | TROPHY_FLAG_MAP);
        nft.setTrophyPackedInfo(mapTokenId, PURGE_TROPHY_KIND_MAP, false);

        uint256 levelTokenId = nextId++;
        _setTrophyData(levelTokenId, baseData);
        nft.setTrophyPackedInfo(levelTokenId, PURGE_TROPHY_KIND_LEVEL, false);

        newBaseTokenId = startId + mintedCount;
    }

    // ---------------------------------------------------------------------
    // Trophy awarding & end-level flows
    // ---------------------------------------------------------------------
    function _awardTrophyInternal(
        address to,
        uint8 kind,
        uint256 data,
        uint256 deferredWei,
        uint256 tokenId
    ) private {
        address currentOwner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (currentOwner != to) {
            nft.transferTrophy(currentOwner, to, tokenId);
            if (currentOwner == gameAddress) {
                nft.incrementTrophySupply(1);
            }
        }

        bool incSupply = _awardTrophyData(to, tokenId, data, deferredWei);
        if (incSupply) {
            nft.incrementTrophySupply(1);
        }

        nft.setTrophyPackedInfo(tokenId, kind, false);
    }

    function awardTrophy(
        address to,
        uint24 level,
        uint8 kind,
        uint256 data,
        uint256 deferredWei
    ) external payable override {
        bool fromGame = msg.sender == gameAddress;
        bool fromCoin = msg.sender == coinAddress;
        if (!fromGame && !fromCoin) {
            _returnValue(msg.sender, deferredWei);
            return;
        }

        if (kind == PURGE_TROPHY_KIND_STAKE) {
            if (!fromCoin) {
                _returnValue(msg.sender, deferredWei);
                return;
            }
        } else {
            if (!fromGame || kind > PURGE_TROPHY_KIND_AFFILIATE) {
                _returnValue(msg.sender, deferredWei);
                return;
            }
        }

        uint256 tokenId = _placeholderTokenId(level, kind);
        if (tokenId == 0) {
            _returnValue(msg.sender, deferredWei);
            return;
        }
        uint256 stakePrincipal;
        if (kind == PURGE_TROPHY_KIND_STAKE) {
            stakePrincipal = deferredWei;
            deferredWei = 0;
            data = _stakePreviewData(level);
        }
        _awardTrophyInternal(to, kind, data, deferredWei, tokenId);
        if (stakePrincipal != 0) {
            emit StakeTrophyAwarded(to, tokenId, level, stakePrincipal);
        }
    }

    function clearStakePreview(uint24 level) external override onlyCoinCaller {
        uint256 tokenId = _placeholderTokenId(level, PURGE_TROPHY_KIND_STAKE);
        _eraseTrophy(tokenId, PURGE_TROPHY_KIND_STAKE, false);
    }

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        override
        onlyGame
        returns (address mapImmediateRecipient, address[6] memory affiliateRecipients)
    {
        uint24 nextLevel = req.level + 1;
        uint256 mapTokenId = _placeholderTokenId(req.level, PURGE_TROPHY_KIND_MAP);
        uint256 levelTokenId = _placeholderTokenId(req.level, PURGE_TROPHY_KIND_LEVEL);
        uint256 affiliateTokenId = _placeholderTokenId(req.level, PURGE_TROPHY_KIND_AFFILIATE);

        if (mapTokenId == 0 || levelTokenId == 0 || affiliateTokenId == 0) {
            return (address(0), affiliateRecipients);
        }

        bool traitWin = req.traitId != TRAIT_ID_TIMEOUT;
        uint256 randomWord = nft.currentRngWord();

        if (traitWin) {
            affiliateRecipients = _processTraitWin(req, nextLevel, levelTokenId, affiliateTokenId, randomWord);
        } else {
            (mapImmediateRecipient, affiliateRecipients) = _processMapTimeout(
                req,
                nextLevel,
                mapTokenId,
                levelTokenId,
                affiliateTokenId,
                randomWord
            );
        }

        return (mapImmediateRecipient, affiliateRecipients);
    }

    function _processTraitWin(
        EndLevelRequest calldata req,
        uint24 nextLevel,
        uint256 levelTokenId,
        uint256 affiliateTokenId,
        uint256 randomWord
    ) private returns (address[6] memory recipients) {
        TraitWinContext memory ctx;
        ctx.levelBits = uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT;
        ctx.traitData = (uint256(req.traitId) << 152) | ctx.levelBits;
        ctx.sharedPool = req.pool / 20;
        ctx.base = ctx.sharedPool / 100;
        ctx.stakerRewardPool = ctx.base * 10;
        ctx.affiliateShare = ctx.sharedPool - ctx.base * 80;
        ctx.deferredAward = msg.value;

        if (ctx.deferredAward < ctx.affiliateShare + ctx.stakerRewardPool) revert InvalidToken();
        ctx.deferredAward -= ctx.affiliateShare + ctx.stakerRewardPool;

        _awardTrophyInternal(req.exterminator, PURGE_TROPHY_KIND_LEVEL, ctx.traitData, ctx.deferredAward, levelTokenId);

        recipients = _selectAffiliateRecipients(randomWord);
        address winner = recipients[0];
        if (winner == address(0)) {
            winner = req.exterminator;
            recipients[0] = winner;
        }

        _awardTrophyInternal(
            winner,
            PURGE_TROPHY_KIND_AFFILIATE,
            (uint256(0xFFFE) << 152) | ctx.levelBits | TROPHY_FLAG_AFFILIATE,
            ctx.affiliateShare,
            affiliateTokenId
        );

        ctx.trophyCount = stakedTrophyIds.length;
        if (ctx.stakerRewardPool != 0 && ctx.trophyCount != 0) {
            ctx.rounds = ctx.trophyCount == 1 ? 1 : 2;
            ctx.baseShare = ctx.stakerRewardPool / ctx.rounds;
            ctx.rand = randomWord;
            for (uint256 i; i < ctx.rounds; ) {
                uint256 idx = ctx.trophyCount == 1 ? 0 : (ctx.rand & type(uint64).max) % ctx.trophyCount;
                ctx.rand >>= 64;
                uint256 chosen = stakedTrophyIds[idx];
                if (ctx.trophyCount != 1) {
                    uint256 otherIdx = (ctx.rand & type(uint64).max) % ctx.trophyCount;
                    ctx.rand >>= 64;
                    uint256 otherToken = stakedTrophyIds[otherIdx];
                    if (otherToken < chosen) {
                        chosen = otherToken;
                    }
                }
                _addTrophyRewardInternal(chosen, ctx.baseShare, nextLevel);
                unchecked {
                    ++i;
                }
            }
        }
    }

    function _processMapTimeout(
        EndLevelRequest calldata req,
        uint24 nextLevel,
        uint256 mapTokenId,
        uint256 levelTokenId,
        uint256 affiliateTokenId,
        uint256 randomWord
    ) private returns (address mapImmediateRecipient, address[6] memory recipients) {
        MapTimeoutContext memory ctx;
        ctx.mapUnit = req.pool / 20;
        mapImmediateRecipient = address(uint160(nft.packedOwnershipOf(mapTokenId)));

        _eraseTrophy(levelTokenId, PURGE_TROPHY_KIND_LEVEL, false);

        ctx.valueIn = msg.value;
        ctx.affiliateWinner = req.exterminator;

        if (ctx.affiliateWinner != address(0) && ctx.mapUnit != 0) {
            _awardTrophyInternal(
                ctx.affiliateWinner,
                PURGE_TROPHY_KIND_AFFILIATE,
                (uint256(0xFFFE) << 152) | (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_AFFILIATE,
                ctx.mapUnit,
                affiliateTokenId
            );
            if (ctx.valueIn < ctx.mapUnit) revert InvalidToken();
            ctx.valueIn -= ctx.mapUnit;
        }

        for (uint8 k; k < 6; ) {
            recipients[k] = ctx.affiliateWinner;
            unchecked {
                ++k;
            }
        }

        _addTrophyRewardInternal(mapTokenId, ctx.mapUnit, nextLevel);
        if (ctx.valueIn < ctx.mapUnit) revert InvalidToken();
        ctx.valueIn -= ctx.mapUnit;

        ctx.stakedCount = stakedTrophyIds.length;
        if (ctx.mapUnit != 0 && ctx.stakedCount != 0) {
            ctx.draws = ctx.valueIn / ctx.mapUnit;
            ctx.rand = randomWord;
            for (uint256 j; j < ctx.draws; ) {
                uint256 idx = ctx.stakedCount == 1 ? 0 : (ctx.rand & type(uint64).max) % ctx.stakedCount;
                uint256 tokenId = stakedTrophyIds[idx];
                _addTrophyRewardInternal(tokenId, ctx.mapUnit, nextLevel);
                ctx.distributed += ctx.mapUnit;
                ctx.rand >>= 64;
                unchecked {
                    ++j;
                }
            }
        }

        uint256 leftover = ctx.valueIn - ctx.distributed;
        if (leftover != 0) {
            (bool ok, ) = payable(gameAddress).call{value: leftover}("");
            if (!ok) revert InvalidToken();
        }
    }

    function _processMapClaim(ClaimContext memory ctx) private view {
        uint32 start = uint32((ctx.info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
        uint32 floor = start - 1;
        uint32 last = ctx.lastClaim;
        if (last < floor) last = floor;
        if (ctx.currentLevel > last) {
            if (nft.rngLocked()) revert CoinPaused();
            uint32 from = last + 1;
            uint32 offsetStart = from - start;
            uint32 offsetEnd = ctx.currentLevel - start;

            uint256 span = uint256(offsetEnd - offsetStart + 1);
            uint256 periodSize = COIN_DRIP_STEPS;
            uint256 blocksEnd = uint256(offsetEnd) / periodSize;
            uint256 blocksStart = uint256(offsetStart) / periodSize;
            uint256 remEnd = uint256(offsetEnd) % periodSize;
            uint256 remStart = uint256(offsetStart) % periodSize;

            uint256 prefixEnd = ((blocksEnd * (blocksEnd - 1)) / 2) * periodSize + blocksEnd * (remEnd + 1);
            uint256 prefixStart = ((blocksStart * (blocksStart - 1)) / 2) * periodSize + blocksStart * (remStart + 1);

            ctx.coinAmount = COIN_EMISSION_UNIT * (span + (prefixEnd - prefixStart));
            ctx.coinClaimed = true;
            ctx.updatedLast = ctx.currentLevel;
        }
    }

    function _isTrophyStaked(uint256 tokenId) private view returns (bool) {
        return trophyStaked[tokenId];
    }

    function _effectiveStakeLevel() private view returns (uint24) {
        uint24 lvl = game.level();
        uint8 state = game.gameState();
        if (state != 3 && lvl != 0) {
            unchecked {
                return lvl - 1;
            }
        }
        return lvl;
    }

    function _kindFromInfo(uint256 info) private pure returns (uint8 kind) {
        if (info & TROPHY_FLAG_MAP != 0) return PURGE_TROPHY_KIND_MAP;
        if (info & TROPHY_FLAG_AFFILIATE != 0) return PURGE_TROPHY_KIND_AFFILIATE;
        if (info & TROPHY_FLAG_STAKE != 0) return PURGE_TROPHY_KIND_STAKE;
        return PURGE_TROPHY_KIND_LEVEL;
    }

    // ---------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------

    function claimTrophy(uint256 tokenId) external override {
        address owner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (owner != msg.sender) revert Unauthorized();

        ClaimContext memory ctx;
        ctx.info = trophyData_[tokenId];
        if (ctx.info == 0) revert InvalidToken();

        ctx.currentLevel = game.level();
        ctx.lastClaim = uint24((ctx.info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);
        ctx.updatedLast = ctx.lastClaim;
        ctx.isStaked = _isTrophyStaked(tokenId);

        ctx.owed = ctx.info & TROPHY_OWED_MASK;
        ctx.newOwed = ctx.owed;

        if (ctx.owed != 0 && ctx.currentLevel > ctx.lastClaim) {
            if (!ctx.isStaked) revert ClaimNotReady();
            uint24 baseStartLevel = uint24((ctx.info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + 1;
            if (ctx.currentLevel >= baseStartLevel) {
                uint32 vestEnd = uint32(baseStartLevel) + COIN_DRIP_STEPS;
                uint256 denom = vestEnd > ctx.currentLevel ? vestEnd - ctx.currentLevel : 1;
                ctx.payout = ctx.owed / denom;
                ctx.newOwed = ctx.owed - ctx.payout;
                ctx.ethClaimed = true;
                ctx.updatedLast = ctx.currentLevel;
            }
        }

        if ((ctx.info & TROPHY_FLAG_MAP) != 0) {
            _processMapClaim(ctx);
        }

        if (!ctx.ethClaimed && !ctx.coinClaimed) revert ClaimNotReady();
        uint256 newInfo =
            (ctx.info & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK)) |
            (ctx.newOwed & TROPHY_OWED_MASK) |
            (uint256(ctx.updatedLast & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
        _setTrophyData(tokenId, newInfo);

        if (ctx.ethClaimed) {
            (bool ok, ) = msg.sender.call{value: ctx.payout}("");
            if (!ok) revert TransferFailed();
            emit TrophyRewardClaimed(tokenId, msg.sender, ctx.payout);
        }

        if (ctx.coinClaimed) {
            coin.bonusCoinflip(msg.sender, ctx.coinAmount, true, 0);
        }
    }

    // ---------------------------------------------------------------------
    // Staking flows
    // ---------------------------------------------------------------------

    function setTrophyStake(uint256 tokenId, bool isMap, bool stake) external override {
        if (nft.rngLocked()) revert CoinPaused();

        address sender = msg.sender;
        if (address(uint160(nft.packedOwnershipOf(tokenId))) != sender) revert Unauthorized();

        bool currentlyStaked = _isTrophyStaked(tokenId);
        uint24 effectiveLevel = _effectiveStakeLevel();
        uint8 gameState = game.gameState();

        uint256 info = trophyData_[tokenId];
        if (info == 0) revert StakeInvalid();

        uint8 storedKind = _kindFromInfo(info);

        StakeParams memory params;
        params.player = sender;
        params.tokenId = tokenId;
        params.targetMap = isMap;
        params.targetStake = !isMap && storedKind == PURGE_TROPHY_KIND_STAKE;
        params.targetAffiliate = !isMap && storedKind == PURGE_TROPHY_KIND_AFFILIATE;
        params.targetLevel = !isMap && storedKind == PURGE_TROPHY_KIND_LEVEL;

        if (params.targetMap) {
            if (storedKind != PURGE_TROPHY_KIND_MAP) revert TrophyStakeViolation(_STAKE_ERR_NOT_MAP);
        } else if (params.targetStake) {
            if (storedKind != PURGE_TROPHY_KIND_STAKE) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKE);
        } else if (params.targetAffiliate) {
            // ok
        } else if (params.targetLevel) {
            // ok
        } else {
            if (storedKind == PURGE_TROPHY_KIND_MAP) revert TrophyStakeViolation(_STAKE_ERR_NOT_MAP);
            if (storedKind == PURGE_TROPHY_KIND_STAKE) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKE);
            revert TrophyStakeViolation(_STAKE_ERR_NOT_AFFILIATE);
        }

        if (stake && sender.code.length != 0) revert StakeInvalid();

        params.trophyBaseLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
        params.trophyLevelValue = params.targetStake ? params.trophyBaseLevel + 1 : params.trophyBaseLevel;
        params.pureLevelTrophy = storedKind == PURGE_TROPHY_KIND_LEVEL;
        params.effectiveLevel = effectiveLevel;

        StakeEventData memory eventData;
        if (stake) {
            if (currentlyStaked) revert TrophyStakeViolation(_STAKE_ERR_ALREADY_STAKED);
            coin.burnCoin(sender, 5_000 * COIN_BASE_UNIT);
            eventData = _stakeInternal(params);
            nft.clearApproval(tokenId);
        } else {
            if (gameState != 3) revert TrophyStakeViolation(_STAKE_ERR_LOCKED);
            if (!currentlyStaked) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKED);
            coin.burnCoin(sender, 25_000 * COIN_BASE_UNIT);
            eventData = _unstakeInternal(params);
        }

        nft.setTrophyPackedInfo(tokenId, storedKind, stake);

        emit TrophyStakeChanged(
            sender,
            tokenId,
            eventData.kind,
            stake,
            eventData.count,
            eventData.discountBps
        );
    }

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata levelTokenIds,
        uint256[] calldata stakeTokenIds
    ) external override {
        address player = msg.sender;
        _refreshMapBonus(player, mapTokenIds);
        _refreshLevelBonus(player, levelTokenIds);
        _refreshStakeBonus(player, stakeTokenIds);
    }

    function affiliateStakeBonus(address player) external view override returns (uint8) {
        uint24 effective = _effectiveStakeLevel();
        return _currentAffiliateBonus(player, effective);
    }

    function stakeTrophyBonus(address player) external view override returns (uint8) {
        return stakeStakeBonusPct_[player];
    }

    function mapStakeDiscount(address player) external view override returns (uint8) {
        return mapStakeBonusPct_[player];
    }

    function levelStakeDiscount(address player) external view override returns (uint8) {
        return levelStakeBonusPct_[player];
    }

    function purgeTrophy(uint256 tokenId) external override {
        if (_isTrophyStaked(tokenId)) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);
        if (trophyData_[tokenId] == 0) revert InvalidToken();

        address sender = msg.sender;
        if (address(uint160(nft.packedOwnershipOf(tokenId))) != sender) revert Unauthorized();

        nft.clearApproval(tokenId);

        uint256 info = trophyData_[tokenId];
        uint8 kind = _kindFromInfo(info);
        _eraseTrophy(tokenId, kind, true);

        coin.bonusCoinflip(sender, 100_000 * COIN_BASE_UNIT, false, 0);
    }

    function stakedTrophySample(uint64 salt) external view override returns (address owner) {
        uint256 count = stakedTrophyIds.length;
        if (count == 0) return address(0);
        uint256 mask = type(uint64).max;
        uint256 rand = uint256(keccak256(abi.encodePacked(salt, count, block.prevrandao)));
        uint256 idxA = count == 1 ? 0 : (rand & mask) % count;
        uint256 idxB = count == 1 ? idxA : (rand >> 64) % count;
        uint256 tokenA = stakedTrophyIds[idxA];
        uint256 tokenB = stakedTrophyIds[idxB];
        uint256 chosen = tokenA <= tokenB ? tokenA : tokenB;
        owner = address(uint160(nft.packedOwnershipOf(chosen)));
    }

    function hasTrophy(uint256 tokenId) external view override returns (bool) {
        return trophyData_[tokenId] != 0;
    }

    function trophyData(uint256 tokenId) external view override returns (uint256 rawData) {
        return trophyData_[tokenId];
    }

    /// @notice Drain any ETH held by the trophy module (deferred payouts) back to the coin contract.
    /// @dev Access: PURGE coin contract only. Used during emergency shutdown via `burnie`.
    function burnieTrophies() external onlyCoinCaller {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = payable(msg.sender).call{value: bal}("");
        if (!ok) revert TransferFailed();
    }

    // ---------------------------------------------------------------------
    // Internal randomness helpers
    // ---------------------------------------------------------------------

    function _selectAffiliateRecipients(uint256 randomWord)
        private
        view
        returns (address[6] memory recipients)
    {
        address[] memory leaders = coin.getLeaderboardAddresses(1);
        uint256 len = leaders.length;

        if (len == 0) {
            return recipients;
        }

        address top = leaders[0];
        recipients[0] = top;

        address second = len > 1 ? leaders[1] : top;
        recipients[1] = second;

        if (len <= 2) {
            for (uint8 idx = 2; idx < 6; ) {
                recipients[idx] = top;
                unchecked {
                    ++idx;
                }
            }
            return recipients;
        }

        unchecked {
            uint256 span = len - 2;
            uint256 rand = randomWord;
            uint256 mask = type(uint64).max;
            uint256 remaining = span;
            uint256 slotSeed;

            if (len <= 256) {
                uint256 usedMask = 3; // bits 0 and 1 consumed
                for (uint8 slot = 2; slot < 6; ) {
                    if (remaining == 0) {
                        recipients[slot] = top;
                        ++slot;
                        continue;
                    }
                    if (rand == 0) {
                        ++slotSeed;
                        rand = randomWord | slotSeed;
                    }
                    uint256 idx = 2 + (rand & mask) % span;
                    rand >>= 64;
                    if (idx >= len) idx = len - 1;
                    uint256 bit = uint256(1) << idx;
                    if (usedMask & bit != 0) {
                        continue;
                    }
                    usedMask |= bit;
                    recipients[slot] = leaders[idx];
                    --remaining;
                    ++slot;
                }
            } else {
                bool[] memory used = new bool[](len);
                used[0] = true;
                used[1] = true;
                for (uint8 slot = 2; slot < 6; ) {
                    if (remaining == 0) {
                        recipients[slot] = top;
                        ++slot;
                        continue;
                    }
                    if (rand == 0) {
                        ++slotSeed;
                        rand = randomWord | slotSeed;
                    }
                    uint256 idx = 2 + (rand & mask) % span;
                    rand >>= 64;
                    if (idx >= len) idx = len - 1;
                    if (used[idx]) {
                        continue;
                    }
                    used[idx] = true;
                    recipients[slot] = leaders[idx];
                    --remaining;
                    ++slot;
                }
            }

            for (uint8 slot = 2; slot < 6; ) {
                if (recipients[slot] == address(0)) {
                    recipients[slot] = top;
                }
                ++slot;
            }
        }

        return recipients;
    }

    function prepareNextLevel(uint24 nextLevel) external override {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        if (msg.sender != gameAddress) {
            if (msg.sender != coinAddress || currentBase != 0) revert Unauthorized();
        }
        uint256 newBase = _mintTrophyPlaceholders(nextLevel);
        nft.setBasePointers(previousBase, newBase);
    }

}
