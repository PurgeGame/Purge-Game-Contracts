// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameExternal, PurgeGameExternalOp} from "./interfaces/IPurgeGameExternal.sol";
import {IPurgeAffiliate} from "./interfaces/IPurgeAffiliate.sol";

interface IPurgeGameNftModule {
    function nextTokenId() external view returns (uint256);
    function mintPlaceholders(uint256 quantity, uint24 level) external returns (uint256 startTokenId);
    function getBasePointers() external view returns (uint256 previousBase, uint256 currentBase);
    function setBasePointers(uint256 previousBase, uint256 currentBase) external;
    function scheduleDormantRange(uint256 startTokenId, uint256 endTokenId) external;
    function processDormant(uint32 limit) external returns (bool finished, bool worked);
    function clearPlaceholderPadding(uint256 startTokenId, uint256 endTokenId) external;
    function packedOwnershipOf(uint256 tokenId) external view returns (uint256 packed);
    function transferTrophy(address from, address to, uint256 tokenId) external;
    function setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool staked) external;
    function clearApproval(uint256 tokenId) external;
    function incrementTrophySupply(uint256 amount) external;
    function decrementTrophySupply(uint256 amount) external;
}

uint8 constant PURGE_TROPHY_KIND_MAP = 0;
uint8 constant PURGE_TROPHY_KIND_LEVEL = 1;
uint8 constant PURGE_TROPHY_KIND_AFFILIATE = 2;
uint8 constant PURGE_TROPHY_KIND_STAKE = 3;
uint8 constant PURGE_TROPHY_KIND_BAF = 4;
uint8 constant PURGE_TROPHY_KIND_DECIMATOR = 5;

interface IPurgeGameTrophies {
    struct EndLevelRequest {
        address exterminator;
        uint16 traitId;
        uint24 level;
        uint256 rngWord;
        uint256 deferredWei;
        bool invertTrophy;
    }

    function wireAndPrime(address[] calldata addresses, uint24 firstLevel) external;

    function clearStakePreview(uint24 level) external;

    function prepareNextLevel(uint24 nextLevel) external;

    function awardTrophy(address to, uint24 level, uint8 kind, uint256 data, uint256 deferredWei) external;

    function burnBafPlaceholder(uint24 level) external;

    function burnDecPlaceholder(uint24 level) external;

    function claimTrophy(uint256 tokenId) external;

    function setTrophyStake(uint256 tokenId, bool stake) external;

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata exterminatorTokenIds,
        uint256[] calldata stakeTokenIds,
        uint256[] calldata affiliateTokenIds
    ) external;

    function affiliateStakeBonus(address player) external view returns (uint8);

    function stakeTrophyBonus(address player) external view returns (uint8);
    function decStakeBonus(address player) external view returns (uint8);

    function mapStakeDiscount(address player) external view returns (uint8);

    function exterminatorStakeDiscount(address player) external view returns (uint8);

    function hasExterminatorStake(address player) external view returns (bool);

    function purgeTrophy(uint256 tokenId) external;

    function stakedTrophySampleWithId(uint256 rngSeed) external view returns (uint256 tokenId, address owner);

    function trophyToken(uint24 level, uint8 kind) external view returns (uint256 tokenId);

    function trophyOwner(uint256 tokenId) external view returns (address owner);

    function rewardTrophyByToken(uint256 tokenId, uint256 amountWei, uint24 level) external;

    function rewardTrophy(uint24 level, uint8 kind, uint256 amountWei) external returns (bool paid);

    function rewardRandomStaked(uint256 rngSeed, uint256 amountWei, uint24 level) external returns (bool paid);

    function processEndLevel(EndLevelRequest calldata req, uint256 scaledPool) external returns (uint256 paidTotal);

    function isTrophy(uint256 tokenId) external view returns (bool);

    function trophyData(uint256 tokenId) external view returns (uint256 rawData);

    function isTrophyStaked(uint256 tokenId) external view returns (bool);

    function handleExterminatorTraitPurge(address player, uint16 traitId) external view returns (uint8 newPercent);
}

interface IPurgeGameMinimal is IPurgeGameExternal {
    function level() external view returns (uint24);
    function gameState() external view returns (uint8);
    function rngLocked() external view returns (bool);
    function coinPriceUnit() external view returns (uint256);
}

interface IPurgecoinMinimal {
    function creditFlip(address player, uint256 amount) external;
    function burnCoin(address target, uint256 amount) external;

    function affiliateProgram() external view returns (address);
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

    struct StakeParams {
        address player;
        uint256 tokenId;
        bool targetMap;
        bool targetAffiliate;
        bool targetExterminator;
        bool targetStake;
        bool targetBaf;
        bool targetDec;
        uint24 effectiveLevel;
        uint24 currentLevel;
        uint256 priceUnit;
    }

    struct StakeEventData {
        uint8 kind;
        uint8 count;
        uint16 discountBps;
    }

    struct TraitWinContext {
        uint256 levelBits;
        uint256 traitData;
        uint256 deferredAward;
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
        uint8 claimsRemaining;
        bool ethClaimed;
        bool coinClaimed;
        bool isStaked;
    }

    struct BafStakeInfo {
        uint24 lastLevel;
        uint24 lastClaimLevel;
        uint32 claimedThisLevel;
        uint8 count;
        uint256 pending;
    }

    struct PlayerStakeCache {
        uint256[] tokenIds;
        uint24 earliest;
    }

    // ---------------------------------------------------------------------
    // Trophy constants
    // ---------------------------------------------------------------------
    // `trophyData_` packed layout (lsb → msb):
    // [0..127]   accrued ETH/coin rewards
    // [128..151] base level (24 bits, offset by 1 to keep 0 as sentinel)
    // [152..167] trait id (0xFFFE = affiliate, 0xFFFF = placeholder sentinel)
    // [168..191] last claim level (24 bits)
    // [192..199] remaining vesting claims (8 bits)
    // [200]      map flag
    // [201]      affiliate flag
    // [202]      stake flag
    // [203]      BAF flag
    // [204]      decimator flag (or special trait sentinel)
    // [205..228] explicit stake level override (24 bits)
    // [229]      invert trophy flag (trait-based)
    // Remaining bits currently unused.
    uint32 private constant COIN_DRIP_STEPS = 10;
    uint256 private constant COIN_BASE_UNIT = 1_000_000;
    uint8 private constant BAF_LEVEL_REWARD_DIVISOR = 10; // priceCoin / 10
    uint16 private constant PURGE_TROPHY_REWARD_MULTIPLIER = 100; // priceCoin * 100
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_FLAG_AFFILIATE = uint256(1) << 201;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;
    uint256 private constant TROPHY_STAKE_LEVEL_SHIFT = 205;
    uint256 private constant TROPHY_STAKE_LEVEL_MASK = uint256(0xFFFFFF) << TROPHY_STAKE_LEVEL_SHIFT;
    uint256 private constant TROPHY_FLAG_INVERT = uint256(1) << 229;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;
    uint256 private constant TROPHY_LAST_CLAIM_MASK = uint256(0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT;
    uint256 private constant TROPHY_CLAIMS_SHIFT = 192;
    uint256 private constant TROPHY_CLAIMS_MASK = uint256(0xFF) << TROPHY_CLAIMS_SHIFT;

    uint8 private constant _STAKE_ERR_TRANSFER_BLOCKED = 1;
    uint8 private constant _STAKE_ERR_ALREADY_STAKED = 3;
    uint8 private constant _STAKE_ERR_NOT_STAKED = 4;
    uint8 private constant _STAKE_ERR_LOCKED = 5;

    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    uint256 private constant TROPHY_BOND_MIN_BASE = 0.02 ether;
    uint256 private constant TROPHY_BOND_MAX_BASE = 0.5 ether;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------
    IPurgeGameNftModule public immutable nft;
    IPurgeGameMinimal private game;
    IPurgecoinMinimal private immutable coin;

    address public gameAddress;
    address public immutable coinAddress;

    // Staked list keeps 1-based indexes so zero is a clean sentinel for "not staked".
    uint256[] private stakedTrophyIds;
    mapping(uint256 => uint256) private stakedTrophyIndex; // 1-based index
    mapping(uint256 => uint256) private trophyData_;
    mapping(address => uint8) private mapStakeBonusPct_;
    mapping(address => uint8) private affiliateStakeBonusPct_;
    mapping(address => uint8) private exterminatorStakeDiscountPct_;
    mapping(address => bool[256]) private exterminatorStakeTraits_;
    mapping(address => uint16) private exterminatorStakeTraitCount;
    mapping(address => uint8) private stakeStakeBonusPct_;
    // Decimator stake bonus is computed on-demand; no cached mapping to avoid stale values.
    mapping(address => BafStakeInfo) private bafStakeInfo;
    mapping(address => PlayerStakeCache) private exterminatorStakeCache;
    mapping(address => PlayerStakeCache) private decStakeCache;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address nft_, address coin_) {
        if (nft_ == address(0) || coin_ == address(0)) revert ZeroAddress();
        nft = IPurgeGameNftModule(nft_);
        coinAddress = coin_;
        coin = IPurgecoinMinimal(coin_);
    }

    // ---------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------
    function wireAndPrime(address[] calldata addresses, uint24 firstLevel) external override {
        address gameAddr = addresses.length > 0 ? addresses[0] : address(0);
        address coinAddr = addresses.length > 1 ? addresses[1] : address(0);
        _wire(gameAddr, coinAddr);
        prepareNextLevel(firstLevel);
    }

    modifier onlyGame() {
        if (msg.sender != gameAddress) revert Unauthorized();
        _;
    }

    modifier onlyCoinCaller() {
        if (msg.sender != coinAddress) revert OnlyCoin();
        _;
    }

    modifier onlyGameOrCoin() {
        address sender = msg.sender;
        if (sender != gameAddress && sender != coinAddress) revert Unauthorized();
        _;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _bafLevelReward(uint256 priceUnit) private pure returns (uint256) {
        return priceUnit / BAF_LEVEL_REWARD_DIVISOR;
    }

    function _bafLevelCap() private pure returns (uint256) {
        // Cap BAF claims to 2,500 coins per level regardless of stack size.
        return 2_500 * COIN_BASE_UNIT;
    }

    function _purgeTrophyReward(uint256 priceUnit) private pure returns (uint256) {
        return priceUnit * PURGE_TROPHY_REWARD_MULTIPLIER;
    }

    function _placeholderTokenId(
        uint24 level,
        uint8 kind,
        uint256 previousBase,
        uint256 currentBase,
        uint24 currentLevel
    ) private pure returns (uint256) {
        // Placeholders are minted in reverse order (dec -> baf -> stake -> affiliate -> map -> level)
        // with separate base pointers for the active and prior level; return 0 if the placeholder is already gone.
        uint256 base;
        if (level == currentLevel) {
            base = currentBase;
        } else if (level + 1 == currentLevel) {
            base = previousBase;
        }
        if (base == 0) return 0;

        bool mintBaf = _shouldMintBaf(level);
        bool mintDec = _shouldMintDec(level);

        uint256 cursor = base;
        uint256 levelTokenId = --cursor;
        uint256 mapTokenId = --cursor;
        uint256 affiliateTokenId = --cursor;
        uint256 stakeTokenId = --cursor;
        uint256 bafTokenId;
        if (mintBaf) {
            bafTokenId = --cursor;
        }
        uint256 decTokenId;
        if (mintDec) {
            decTokenId = --cursor;
        }

        if (kind == PURGE_TROPHY_KIND_LEVEL) return levelTokenId;
        if (kind == PURGE_TROPHY_KIND_MAP) return mapTokenId;
        if (kind == PURGE_TROPHY_KIND_AFFILIATE) return affiliateTokenId;
        if (kind == PURGE_TROPHY_KIND_STAKE) return stakeTokenId;
        if (kind == PURGE_TROPHY_KIND_BAF) return mintBaf ? bafTokenId : 0;
        if (kind == PURGE_TROPHY_KIND_DECIMATOR) return mintDec ? decTokenId : 0;
        return 0;
    }

    function _shouldMintBaf(uint24 level) private pure returns (bool) {
        if (level == 0) return false;
        return (level % 10) == 0;
    }

    function _shouldMintDec(uint24 level) private pure returns (bool) {
        if (level != 0 && (level % DECIMATOR_SPECIAL_LEVEL) == 0) return true;
        if (level < 25) return false;
        if ((level % 10) != 5) return false;
        if ((level % 100) == 95) return false;
        return true;
    }

    function _setTrophyData(uint256 tokenId, uint256 data) private {
        trophyData_[tokenId] = data;
    }

    function _ownerOf(uint256 tokenId) private view returns (address) {
        return address(uint160(nft.packedOwnershipOf(tokenId)));
    }

    function _eraseTrophy(uint256 tokenId, uint8 kind, bool adjustSupply) private {
        if (stakedTrophyIndex[tokenId] != 0) revert StakeInvalid();
        bool hadData = trophyData_[tokenId] != 0;
        delete trophyData_[tokenId];
        nft.setTrophyPackedInfo(tokenId, kind, false);
        if (adjustSupply && hadData) {
            nft.decrementTrophySupply(1);
        }
    }

    function _awardTrophyData(
        address to,
        uint256 tokenId,
        uint256 data,
        uint256 deferredWei
    ) private returns (bool incrementSupply) {
        // Replace owed/claim metadata but preserve other flags; initial deferredWei sets a 10-claim vest.
        uint256 prevData = trophyData_[tokenId];
        uint256 newData = (data & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK | TROPHY_CLAIMS_MASK)) |
            (deferredWei & TROPHY_OWED_MASK);
        if (deferredWei != 0) {
            newData |= uint256(10) << TROPHY_CLAIMS_SHIFT;
        }
        trophyData_[tokenId] = newData;
        if (prevData == 0 && newData != 0 && to != gameAddress) {
            incrementSupply = true;
        }
    }

    function _addTrophyRewardInternal(uint256 tokenId, uint256 amountWei, uint24 startLevel) private {
        uint256 info = trophyData_[tokenId];
        uint256 owed = (info & TROPHY_OWED_MASK) + amountWei;
        uint256 claims = (info >> TROPHY_CLAIMS_SHIFT) & 0xFF;
        // Any new reward enforces at least a 3-claim schedule and bumps an existing one by 1 up to 255.
        if (amountWei != 0) {
            if (claims < 3) claims = 3;
            else if (claims < 0xFF) claims += 1;
        }
        uint256 base = uint256((startLevel - 1) & 0xFFFFFF);
        uint256 updated = (info &
            ~(TROPHY_OWED_MASK | (uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_CLAIMS_MASK)) |
            (owed & TROPHY_OWED_MASK) |
            (base << TROPHY_BASE_LEVEL_SHIFT) |
            (claims << TROPHY_CLAIMS_SHIFT);
        trophyData_[tokenId] = updated;
    }

    // Assign reward with a 10-claim schedule (used for stake/affiliate 1% slices).
    function _addTrophyRewardInternalClaimsTen(uint256 tokenId, uint256 amountWei, uint24 startLevel) private {
        if (amountWei == 0) return;
        uint256 info = trophyData_[tokenId];
        uint256 owed = (info & TROPHY_OWED_MASK) + amountWei;
        uint256 base = uint256((startLevel - 1) & 0xFFFFFF);
        uint256 updated = (info &
            ~(TROPHY_OWED_MASK | (uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_CLAIMS_MASK)) |
            (owed & TROPHY_OWED_MASK) |
            (base << TROPHY_BASE_LEVEL_SHIFT) |
            (uint256(10) << TROPHY_CLAIMS_SHIFT);
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

    function _addExterminatorStakeTrait(address player, uint16 traitId) private {
        if (traitId >= 256) revert StakeInvalid();
        bool[256] storage traits = exterminatorStakeTraits_[player];
        if (!traits[traitId]) {
            traits[traitId] = true;
            exterminatorStakeTraitCount[player] += 1;
        }
    }

    function _removeExterminatorStakeTrait(address player, uint16 traitId) private {
        if (traitId >= 256) revert StakeInvalid();
        bool[256] storage traits = exterminatorStakeTraits_[player];
        if (traits[traitId]) {
            traits[traitId] = false;
            uint16 current = exterminatorStakeTraitCount[player];
            if (current != 0) {
                exterminatorStakeTraitCount[player] = current - 1;
            }
        }
    }

    function _mapDiscountCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 5;
        if (count == 2) return 8;
        return 10;
    }

    function _stakeLevelFromInfo(uint256 info) private pure returns (uint24) {
        uint24 stakeLevel = uint24((info >> TROPHY_STAKE_LEVEL_SHIFT) & 0xFFFFFF);
        if (stakeLevel != 0) return stakeLevel;
        return uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
    }

    function _addStakeCache(PlayerStakeCache storage cache, uint256 tokenId, uint24 stakeLevel) private {
        cache.tokenIds.push(tokenId);
        uint24 earliest = cache.earliest;
        if (earliest == 0 || stakeLevel < earliest) {
            cache.earliest = stakeLevel;
        }
    }

    function _removeStakeCache(PlayerStakeCache storage cache, uint256 tokenId) private {
        uint256 len = cache.tokenIds.length;
        bool found;
        for (uint256 i; i < len; ) {
            if (cache.tokenIds[i] == tokenId) {
                found = true;
                uint256 lastIdx = len - 1;
                if (i != lastIdx) {
                    cache.tokenIds[i] = cache.tokenIds[lastIdx];
                }
                cache.tokenIds.pop();
                break;
            }
            unchecked {
                ++i;
            }
        }
        if (!found) revert StakeInvalid();

        uint24 newEarliest;
        uint256 remaining = cache.tokenIds.length;
        for (uint256 i; i < remaining; ) {
            uint256 tid = cache.tokenIds[i];
            uint24 lvl = _stakeLevelFromInfo(trophyData_[tid]);
            if (lvl != 0 && (newEarliest == 0 || lvl < newEarliest)) {
                newEarliest = lvl;
            }
            unchecked {
                ++i;
            }
        }
        cache.earliest = newEarliest;
    }

    function _exterminatorDiscountCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 5;
        if (count == 2) return 8;
        return 10;
    }

    function _stakeBonusCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 5;
        if (count == 2) return 10;
        if (count == 3) return 15;
        return 20;
    }

    function _decBonusCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 5;
        if (count == 2) return 8;
        return 10;
    }

    function _timeBasedDiscount(
        uint8 count,
        uint24 earliestLevel,
        uint24 effectiveLevel,
        uint8 cap
    ) private pure returns (uint8) {
        if (count == 0 || earliestLevel == 0 || cap == 0) return 0;
        if (effectiveLevel <= earliestLevel) return 0;
        uint24 levelsHeld = effectiveLevel - earliestLevel;
        if (levelsHeld > cap) return cap;
        return uint8(levelsHeld);
    }

    function _exterminatorStakeStats(address player) private view returns (uint8 total, uint24 earliest) {
        PlayerStakeCache storage cache = exterminatorStakeCache[player];
        uint256 len = cache.tokenIds.length;
        if (len == 0) return (0, 0);
        total = len > type(uint8).max ? type(uint8).max : uint8(len);
        earliest = cache.earliest;
    }

    function _decStakeStats(address player) private view returns (uint8 total, uint24 earliest) {
        PlayerStakeCache storage cache = decStakeCache[player];
        uint256 len = cache.tokenIds.length;
        if (len == 0) return (0, 0);
        total = len > type(uint8).max ? type(uint8).max : uint8(len);
        earliest = cache.earliest;
    }

    function _ensurePlayerOwnsStaked(address player, uint256 tokenId) private view {
        if (stakedTrophyIndex[tokenId] == 0) revert StakeInvalid();
        address owner = _ownerOf(tokenId);
        if (owner != player) revert StakeInvalid();
    }

    function _currentAffiliateBonus(uint8 count, uint24 baseLevel, uint24 effectiveLevel) private pure returns (uint8) {
        if (count == 0) return 0;
        uint24 levelsHeld = effectiveLevel > baseLevel ? effectiveLevel - baseLevel : 0;
        uint256 effectiveBonus = uint256(levelsHeld) * uint256(count);
        uint256 cap = 10 + (uint256(count - 1) * 5);
        if (cap > 25) cap = 25;
        if (effectiveBonus > cap) effectiveBonus = cap;
        return uint8(effectiveBonus);
    }

    function _stakeInternal(StakeParams memory params) private returns (StakeEventData memory data) {
        if (trophyData_[params.tokenId] == 0) revert StakeInvalid();
        if (stakedTrophyIndex[params.tokenId] != 0) revert TrophyStakeViolation(_STAKE_ERR_ALREADY_STAKED);
        uint256 info = trophyData_[params.tokenId];
        // Reset claim accrual to the stake level to avoid backdating, then set explicit stakeLevel bits.
        uint256 levelValue = uint256(params.effectiveLevel & 0xFFFFFF);
        uint256 owed = info & TROPHY_OWED_MASK;
        if (owed != 0) {
            uint256 baseCleared = info & ~(uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT);
            uint256 lastCleared = baseCleared & ~TROPHY_LAST_CLAIM_MASK;
            uint256 updatedInfo = lastCleared |
                (levelValue << TROPHY_BASE_LEVEL_SHIFT) |
                (levelValue << TROPHY_LAST_CLAIM_SHIFT);
            trophyData_[params.tokenId] = updatedInfo;
            info = updatedInfo;
        }
        uint256 stakeLevelBits = levelValue << TROPHY_STAKE_LEVEL_SHIFT;
        uint256 infoWithStakeLevel = (info & ~TROPHY_STAKE_LEVEL_MASK) | stakeLevelBits;
        if (infoWithStakeLevel != info) {
            trophyData_[params.tokenId] = infoWithStakeLevel;
            info = infoWithStakeLevel;
        }
        _addStakedTrophy(params.tokenId);

        if (params.targetMap) {
            data.kind = 1;
            data.count = 0;
        } else if (params.targetAffiliate) {
            data.kind = 2;
            data.count = 0;
        } else if (params.targetExterminator) {
            uint16 traitId = uint16((trophyData_[params.tokenId] >> 152) & 0xFFFF);
            _addExterminatorStakeTrait(params.player, traitId);
            _addStakeCache(exterminatorStakeCache[params.player], params.tokenId, params.effectiveLevel);
            data.kind = 3;
            data.count = 0;
        } else if (params.targetBaf) {
            BafStakeInfo storage state = bafStakeInfo[params.player];
            _syncBafStake(params.player, state, params.currentLevel, params.priceUnit);
            uint8 current = state.count;
            if (current == type(uint8).max) revert StakeInvalid();
            unchecked {
                current += 1;
            }
            state.count = current;
            data.kind = 5;
            data.count = current;
        } else if (params.targetDec) {
            // Decimator trophies stake purely to enable burn bonuses; no discounts or counters.
            _addStakeCache(decStakeCache[params.player], params.tokenId, params.effectiveLevel);
            data.kind = 6;
            data.count = 0;
        } else {
            data.kind = 4;
            data.count = 0;
        }

        data.discountBps = 0;
        return data;
    }

    function _unstakeInternal(StakeParams memory params) private returns (StakeEventData memory data) {
        uint256 info = trophyData_[params.tokenId];
        if (info == 0) revert StakeInvalid();
        if (stakedTrophyIndex[params.tokenId] == 0) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKED);
        _removeStakedTrophy(params.tokenId);
        // Clear cached bonuses and trait tracking; stake level override removed below.
        if (params.targetMap) {
            mapStakeBonusPct_[params.player] = 0;
            data.kind = 1;
            data.count = 0;
        } else if (params.targetAffiliate) {
            affiliateStakeBonusPct_[params.player] = 0;
            data.kind = 2;
            data.count = 0;
        } else if (params.targetExterminator) {
            uint16 traitId = uint16((info >> 152) & 0xFFFF);
            _removeExterminatorStakeTrait(params.player, traitId);
            exterminatorStakeDiscountPct_[params.player] = 0;
            _removeStakeCache(exterminatorStakeCache[params.player], params.tokenId);
            data.kind = 3;
            data.count = 0;
        } else if (params.targetBaf) {
            BafStakeInfo storage state = bafStakeInfo[params.player];
            _syncBafStake(params.player, state, params.currentLevel, params.priceUnit);
            uint8 current = state.count;
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            state.count = current;
            data.kind = 5;
            data.count = current;
        } else if (params.targetDec) {
            // Decimator trophies have no counters or discounts; just remove stake state.
            _removeStakeCache(decStakeCache[params.player], params.tokenId);
            data.kind = 6;
            data.count = 0;
        } else {
            stakeStakeBonusPct_[params.player] = 0;
            data.kind = 4;
            data.count = 0;
        }

        uint256 storedInfo = trophyData_[params.tokenId];
        if ((storedInfo & TROPHY_STAKE_LEVEL_MASK) != 0) {
            trophyData_[params.tokenId] = storedInfo & ~TROPHY_STAKE_LEVEL_MASK;
        }

        data.discountBps = 0;
        return data;
    }

    function _refreshMapBonus(address player, uint256[] calldata tokenIds) private {
        // Caller supplies their staked map trophies; enforce max 10 to bound loop gas.
        uint256 len = tokenIds.length;
        if (len == 0) {
            return;
        }
        if (len > 10) revert StakeInvalid();
        uint8 cap = _mapDiscountCap(uint8(len));
        uint24 earliest = type(uint24).max;
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            if ((info & TROPHY_FLAG_MAP) == 0) revert StakeInvalid();
            uint24 stakeLevel = uint24((info >> TROPHY_STAKE_LEVEL_SHIFT) & 0xFFFFFF);
            uint24 base = stakeLevel == 0 ? uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) : stakeLevel;
            if (base < earliest) earliest = base;
            unchecked {
                ++i;
            }
        }
        if (earliest == type(uint24).max) revert StakeInvalid();
        uint24 effective = _currentEffectiveStakeLevel();
        mapStakeBonusPct_[player] = _timeBasedDiscount(uint8(len), earliest, effective, cap);
    }

    function _refreshExterminatorStakeBonus(address player, uint256[] calldata tokenIds) private {
        // Exterminator stake cannot mix with other trophy flags; traits are tracked per-player for purge logic.
        uint256 len = tokenIds.length;
        if (len == 0) {
            return;
        }
        if (len > 10) revert StakeInvalid();
        uint24 earliest = type(uint24).max;
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            bool invalid = (info & TROPHY_FLAG_MAP) != 0 ||
                (info & TROPHY_FLAG_AFFILIATE) != 0 ||
                (info & TROPHY_FLAG_STAKE) != 0 ||
                (info & TROPHY_FLAG_BAF) != 0;
            if (invalid) revert StakeInvalid();
            uint24 stakeLevel = uint24((info >> TROPHY_STAKE_LEVEL_SHIFT) & 0xFFFFFF);
            uint24 base = stakeLevel == 0 ? uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) : stakeLevel;
            if (base < earliest) earliest = base;
            uint16 traitId = uint16((info >> 152) & 0xFFFF);
            _addExterminatorStakeTrait(player, traitId);
            unchecked {
                ++i;
            }
        }
        if (earliest == type(uint24).max) revert StakeInvalid();
        uint24 effective = _currentEffectiveStakeLevel();
        uint8 cap = _exterminatorDiscountCap(uint8(len));
        exterminatorStakeDiscountPct_[player] = _timeBasedDiscount(uint8(len), earliest, effective, cap);
    }

    function _refreshStakeBonus(address player, uint256[] calldata tokenIds) private {
        // Stake bonuses accrue over time per staked stake trophies.
        uint256 len = tokenIds.length;
        if (len == 0) {
            return;
        }
        if (len > 10) revert StakeInvalid();
        uint8 cap = _stakeBonusCap(uint8(len));
        uint24 earliest = type(uint24).max;
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            if ((info & TROPHY_FLAG_STAKE) == 0) revert StakeInvalid();
            uint24 stakeLevel = uint24((info >> TROPHY_STAKE_LEVEL_SHIFT) & 0xFFFFFF);
            uint24 value = stakeLevel == 0 ? uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) : stakeLevel;
            if (value < earliest) earliest = value;
            unchecked {
                ++i;
            }
        }
        if (earliest == type(uint24).max) revert StakeInvalid();
        uint24 effective = _currentEffectiveStakeLevel();
        stakeStakeBonusPct_[player] = _timeBasedDiscount(uint8(len), earliest, effective, cap);
    }

    function _refreshAffiliateBonus(address player, uint256[] calldata tokenIds) private {
        // Affiliate bonus scales with both count and levels held; bounded to 10 ids for predictable gas.
        uint256 len = tokenIds.length;
        if (len == 0) {
            return;
        }
        if (len > 10) revert StakeInvalid();
        uint24 earliest = type(uint24).max;
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            if ((info & TROPHY_FLAG_AFFILIATE) == 0) revert StakeInvalid();
            uint24 stakeLevel = uint24((info >> TROPHY_STAKE_LEVEL_SHIFT) & 0xFFFFFF);
            uint24 base = stakeLevel == 0 ? uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) : stakeLevel;
            if (base < earliest) earliest = base;
            unchecked {
                ++i;
            }
        }
        if (earliest == type(uint24).max) revert StakeInvalid();
        uint24 effective = _currentEffectiveStakeLevel();
        affiliateStakeBonusPct_[player] = _currentAffiliateBonus(uint8(len), earliest, effective);
    }

    function _mintTrophyPlaceholders(uint24 level) private returns (uint256 newBaseTokenId) {
        uint256 baseData = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT);
        bool mintBafPlaceholder = _shouldMintBaf(level);
        bool mintDecPlaceholder = _shouldMintDec(level);
        uint256 placeholderCount = 4 + (mintBafPlaceholder ? 1 : 0) + (mintDecPlaceholder ? 1 : 0);

        uint256 startId = nft.nextTokenId();
        uint256 mintedEnd = startId + placeholderCount;
        uint256 remainder = (mintedEnd - 1) % 100;
        if (remainder != 0) {
            mintedEnd += 100 - remainder;
        }
        uint256 mintedCount = mintedEnd - startId;

        uint256 mintedStart = nft.mintPlaceholders(mintedCount, level);
        if (mintedStart != startId) {
            // Defensive: NFT must mint sequentially.
            revert InvalidToken();
        }

        uint256 paddingEnd = mintedEnd - placeholderCount;
        if (paddingEnd > startId) {
            nft.clearPlaceholderPadding(startId, paddingEnd);
        }

        uint256 cursor = mintedEnd;

        uint256 levelTokenId = --cursor;
        _setTrophyData(levelTokenId, baseData);
        nft.setTrophyPackedInfo(levelTokenId, PURGE_TROPHY_KIND_LEVEL, false);

        uint256 mapTokenId = --cursor;
        _setTrophyData(mapTokenId, baseData | TROPHY_FLAG_MAP);
        nft.setTrophyPackedInfo(mapTokenId, PURGE_TROPHY_KIND_MAP, false);

        uint256 affiliateTokenId = --cursor;
        _setTrophyData(affiliateTokenId, baseData | TROPHY_FLAG_AFFILIATE);
        nft.setTrophyPackedInfo(affiliateTokenId, PURGE_TROPHY_KIND_AFFILIATE, false);

        uint256 stakeTokenId = --cursor;
        uint256 stakeData = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_STAKE;
        _setTrophyData(stakeTokenId, stakeData);
        nft.setTrophyPackedInfo(stakeTokenId, PURGE_TROPHY_KIND_STAKE, false);

        if (mintBafPlaceholder) {
            uint256 bafTokenId = --cursor;
            _setTrophyData(bafTokenId, baseData | TROPHY_FLAG_BAF);
            nft.setTrophyPackedInfo(bafTokenId, PURGE_TROPHY_KIND_BAF, false);
        }

        if (mintDecPlaceholder) {
            uint256 decTokenId = --cursor;
            _setTrophyData(decTokenId, baseData | TROPHY_FLAG_DECIMATOR);
            nft.setTrophyPackedInfo(decTokenId, PURGE_TROPHY_KIND_DECIMATOR, false);
        }

        newBaseTokenId = mintedEnd;
    }

    // ---------------------------------------------------------------------
    // Trophy awarding & end-level flows
    // ---------------------------------------------------------------------
    function _awardTrophyInternal(address to, uint8 kind, uint256 data, uint256 deferredWei, uint256 tokenId) private {
        // Placeholder may still be owned by the game; move before stamping updated packed data.
        address currentOwner = _ownerOf(tokenId);
        if (currentOwner != to) {
            nft.transferTrophy(currentOwner, to, tokenId);
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
    ) external override onlyGameOrCoin {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        uint256 tokenId = _placeholderTokenId(level, kind, previousBase, currentBase, currentLevel);

        _awardTrophyInternal(to, kind, data, deferredWei, tokenId);
    }

    function clearStakePreview(uint24 level) external override onlyCoinCaller {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        uint256 tokenId = _placeholderTokenId(level, PURGE_TROPHY_KIND_STAKE, previousBase, currentBase, currentLevel);
        if (tokenId == 0) return;
        _eraseTrophy(tokenId, PURGE_TROPHY_KIND_STAKE, true);
    }

    function burnBafPlaceholder(uint24 level) external override onlyCoinCaller {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        uint256 tokenId = _placeholderTokenId(level, PURGE_TROPHY_KIND_BAF, previousBase, currentBase, currentLevel);
        if (tokenId == 0) return;
        _eraseTrophy(tokenId, PURGE_TROPHY_KIND_BAF, true);
    }

    function burnDecPlaceholder(uint24 level) external override onlyCoinCaller {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        uint256 tokenId = _placeholderTokenId(
            level,
            PURGE_TROPHY_KIND_DECIMATOR,
            previousBase,
            currentBase,
            currentLevel
        );
        if (tokenId == 0) return;
        _eraseTrophy(tokenId, PURGE_TROPHY_KIND_DECIMATOR, true);
    }

    function _processEndLevel(EndLevelRequest calldata req) private {
        // Resolve placeholder ids for the just-finished level using current/previous base pointers; if missing, exit.
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();

        uint256 base = req.level == currentLevel ? currentBase : (req.level + 1 == currentLevel ? previousBase : 0);
        if (base <= 4) return;

        uint256 levelTokenId = base - 1;
        uint256 affiliateTokenId = base - 3;
        uint256 stakeTokenId = base - 4;

        if (levelTokenId == 0 || affiliateTokenId == 0) return;
        bool traitWin = req.traitId != TRAIT_ID_TIMEOUT;

        _processEnd(req, levelTokenId, affiliateTokenId, stakeTokenId, traitWin);
    }

    function _processEnd(
        EndLevelRequest calldata req,
        uint256 levelTokenId,
        uint256 affiliateTokenId,
        uint256 stakeTokenId,
        bool traitWin
    ) private {
        address gameAddr = gameAddress;

        // Level trophy: award on trait win with exterminator data, otherwise burn if still unassigned.
        if (traitWin) {
            uint256 levelPlaceholder = levelTokenId;

            TraitWinContext memory ctx;
            ctx.levelBits = uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT;
            ctx.traitData = (uint256(req.traitId) << 152) | ctx.levelBits;
            if (req.invertTrophy) {
                ctx.traitData |= TROPHY_FLAG_INVERT;
            }
            ctx.deferredAward = req.deferredWei;
            _awardTrophyInternal(
                req.exterminator,
                PURGE_TROPHY_KIND_LEVEL,
                ctx.traitData,
                ctx.deferredAward,
                levelPlaceholder
            );
        } else {
            if (levelTokenId != 0 && _ownerOf(levelTokenId) == gameAddr) {
                _eraseTrophy(levelTokenId, PURGE_TROPHY_KIND_LEVEL, true);
            }
        }

        // Affiliate trophy: same handling for both paths (fall back to exterminator if leaderboard winner absent).
        address affiliateWinner;
        address affiliateAddr = coin.affiliateProgram();
        if (affiliateAddr != address(0)) {
            affiliateWinner = IPurgeAffiliate(affiliateAddr).getTopAffiliate(req.level);
        }
        if (affiliateWinner == address(0)) {
            affiliateWinner = req.exterminator;
        }

        uint256 affiliateData = (uint256(0xFFFE) << 152) |
            (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT) |
            TROPHY_FLAG_AFFILIATE;
        if (affiliateWinner != address(0)) {
            _awardTrophyInternal(affiliateWinner, PURGE_TROPHY_KIND_AFFILIATE, affiliateData, 0, affiliateTokenId);
        } else if (affiliateTokenId != 0 && _ownerOf(affiliateTokenId) == gameAddr) {
            _eraseTrophy(affiliateTokenId, PURGE_TROPHY_KIND_AFFILIATE, true);
        }

        // Stake placeholder: burn if still unassigned.
        if (stakeTokenId != 0 && _ownerOf(stakeTokenId) == gameAddr) {
            _eraseTrophy(stakeTokenId, PURGE_TROPHY_KIND_STAKE, true);
        }
    }

    function _processBafClaim(address player, ClaimContext memory ctx, uint256 priceUnit) private {
        // BAF trophies pay in coin, capped per-level and only when staked.
        if (!ctx.isStaked) revert ClaimNotReady();
        BafStakeInfo storage state = bafStakeInfo[player];
        _syncBafStake(player, state, ctx.currentLevel, priceUnit);

        if (state.lastClaimLevel != ctx.currentLevel) {
            state.lastClaimLevel = ctx.currentLevel;
            state.claimedThisLevel = 0;
        }

        uint256 pending = state.pending;
        if (pending == 0) revert ClaimNotReady();

        uint256 levelCap = _bafLevelCap();
        uint256 claimedLevel = uint256(state.claimedThisLevel);
        if (claimedLevel >= levelCap) revert ClaimNotReady();
        uint256 remaining = levelCap - claimedLevel;

        uint256 payout = pending;
        if (payout > remaining) {
            payout = remaining;
        }

        state.pending = pending - payout;
        state.claimedThisLevel += uint32(payout);

        ctx.coinAmount = payout;
        ctx.coinClaimed = true;
    }

    function _isTrophyStaked(uint256 tokenId) private view returns (bool) {
        return stakedTrophyIndex[tokenId] != 0;
    }

    function _isDecimatorTrophy(uint256 info) private pure returns (bool) {
        if (info & TROPHY_FLAG_DECIMATOR != 0) return true;
        uint16 traitId = uint16((info >> 152) & 0xFFFF);
        return traitId == DECIMATOR_TRAIT_SENTINEL;
    }

    function _isBafTrophy(uint256 info) private pure returns (bool) {
        return (info & TROPHY_FLAG_BAF) != 0;
    }

    function _bootstrapBafStake(address player, BafStakeInfo storage state, uint24 currentLevel) private {
        // Lazily reconstruct BAF stake counters from staked set to survive upgrades or partial state.
        if (state.count != 0) return;
        uint8 count;
        uint256 len = stakedTrophyIds.length;
        for (uint256 i; i < len; ) {
            uint256 tokenId = stakedTrophyIds[i];
            if (_isBafTrophy(trophyData_[tokenId])) {
                address owner = _ownerOf(tokenId);
                if (owner == player) {
                    unchecked {
                        count += 1;
                    }
                }
            }
            unchecked {
                ++i;
            }
        }
        if (count != 0) {
            state.count = count;
            if (state.lastLevel == 0) {
                state.lastLevel = currentLevel;
            }
            if (state.lastClaimLevel == 0) {
                state.lastClaimLevel = currentLevel;
            }
        }
    }

    function _syncBafStake(address player, BafStakeInfo storage state, uint24 currentLevel, uint256 priceUnit) private {
        // Accrue pending BAF rewards per level since last sync; count comes from stake hooks.
        _bootstrapBafStake(player, state, currentLevel);
        if (state.lastLevel == 0) {
            state.lastLevel = currentLevel;
            if (state.lastClaimLevel == 0) {
                state.lastClaimLevel = currentLevel;
            }
            return;
        }
        if (state.count != 0 && currentLevel > state.lastLevel) {
            uint256 delta = uint256(currentLevel - state.lastLevel) * uint256(state.count);
            uint256 rewardPerLevel = _bafLevelReward(priceUnit);
            if (rewardPerLevel != 0) {
                state.pending = state.pending + (delta * rewardPerLevel);
            }
        }
        state.lastLevel = currentLevel;
    }

    function _effectiveStakeLevel(uint24 lvl, uint8 state) private pure returns (uint24) {
        if (state == 3) return lvl;
        if (lvl == 0) return 0;
        unchecked {
            return uint24(lvl - 1);
        }
    }

    function _currentEffectiveStakeLevel() private view returns (uint24) {
        uint24 lvl = game.level();
        uint8 state = game.gameState();
        return _effectiveStakeLevel(lvl, state);
    }

    function _kindFromInfo(uint256 info) private pure returns (uint8 kind) {
        if (info & TROPHY_FLAG_MAP != 0) return PURGE_TROPHY_KIND_MAP;
        if (info & TROPHY_FLAG_AFFILIATE != 0) return PURGE_TROPHY_KIND_AFFILIATE;
        if (info & TROPHY_FLAG_STAKE != 0) return PURGE_TROPHY_KIND_STAKE;
        if (info & TROPHY_FLAG_BAF != 0) return PURGE_TROPHY_KIND_BAF;
        if (info & TROPHY_FLAG_DECIMATOR != 0) return PURGE_TROPHY_KIND_DECIMATOR;
        return PURGE_TROPHY_KIND_LEVEL;
    }

    function _trophyBondSpend(uint256 amount) private pure returns (uint256 spend) {
        if (amount < TROPHY_BOND_MIN_BASE) {
            return 0;
        }
        uint256 quantity = (amount + TROPHY_BOND_MAX_BASE - 1) / TROPHY_BOND_MAX_BASE;
        uint256 basePerBond = amount / quantity;
        if (basePerBond < TROPHY_BOND_MIN_BASE) {
            basePerBond = TROPHY_BOND_MIN_BASE;
            quantity = amount / basePerBond;
            if (quantity == 0) {
                quantity = 1;
            }
        }
        spend = basePerBond * quantity;
    }

    // ---------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------

    function claimTrophy(uint256 tokenId) external override {
        // Owner-only claim; staking is enforced by the vesting logic paths below.
        address owner = _ownerOf(tokenId);
        if (owner != msg.sender) revert Unauthorized();
        if (game.rngLocked()) revert CoinPaused();

        ClaimContext memory ctx;
        ctx.info = trophyData_[tokenId];
        if (ctx.info == 0) revert InvalidToken();

        ctx.currentLevel = game.level();
        uint256 priceUnit = game.coinPriceUnit();
        ctx.lastClaim = uint24((ctx.info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);
        ctx.claimsRemaining = uint8((ctx.info >> TROPHY_CLAIMS_SHIFT) & 0xFF);
        ctx.updatedLast = ctx.lastClaim;
        ctx.isStaked = _isTrophyStaked(tokenId);

        ctx.owed = ctx.info & TROPHY_OWED_MASK;
        ctx.newOwed = ctx.owed;

        // Payout path is either an explicit multi-claim vest or a linear drip over COIN_DRIP_STEPS after base level.
        if (ctx.claimsRemaining != 0) {
            if (ctx.currentLevel <= ctx.lastClaim) revert ClaimNotReady();
            if (!ctx.isStaked) revert ClaimNotReady();
            uint256 denom = ctx.claimsRemaining;
            ctx.payout = ctx.owed / denom;
            if (ctx.payout == 0) revert ClaimNotReady();
            ctx.ethClaimed = true;
            ctx.updatedLast = ctx.currentLevel;
            ctx.claimsRemaining = uint8(ctx.claimsRemaining - 1);
        } else if (ctx.owed != 0 && ctx.currentLevel > ctx.lastClaim) {
            if (!ctx.isStaked) revert ClaimNotReady();
            uint24 baseStartLevel = uint24((ctx.info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + 1;
            if (ctx.currentLevel >= baseStartLevel) {
                uint32 vestEnd = uint32(baseStartLevel) + COIN_DRIP_STEPS;
                uint256 denom = vestEnd > ctx.currentLevel ? vestEnd - ctx.currentLevel : 1;
                ctx.payout = ctx.owed / denom;
                ctx.ethClaimed = true;
                ctx.updatedLast = ctx.currentLevel;
            }
        }

        if (_isBafTrophy(ctx.info)) {
            _processBafClaim(msg.sender, ctx, priceUnit);
        }

        if (ctx.ethClaimed) {
            uint256 bondSpend = _trophyBondSpend(ctx.payout);
            if (bondSpend == 0 || bondSpend > ctx.owed) revert ClaimNotReady();
            ctx.payout = bondSpend;
            ctx.newOwed = ctx.owed - bondSpend;
        }

        if (!ctx.ethClaimed && !ctx.coinClaimed) revert ClaimNotReady();
        uint256 newInfo = (ctx.info & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK | TROPHY_CLAIMS_MASK)) |
            (ctx.newOwed & TROPHY_OWED_MASK) |
            (uint256(ctx.updatedLast & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT) |
            (uint256(ctx.claimsRemaining) << TROPHY_CLAIMS_SHIFT);
        _setTrophyData(tokenId, newInfo);

        if (ctx.ethClaimed) {
            game.applyExternalOp(PurgeGameExternalOp.TrophyPayout, msg.sender, ctx.payout, ctx.currentLevel);
            emit TrophyRewardClaimed(tokenId, msg.sender, ctx.payout);
        }

        if (ctx.coinClaimed) {
            coin.creditFlip(msg.sender, ctx.coinAmount);
        }
    }

    // ---------------------------------------------------------------------
    // Staking flows
    // ---------------------------------------------------------------------

    function setTrophyStake(uint256 tokenId, bool stake) external override {
        // Entry gate: RNG must be unlocked and caller must be EOAs (anti-bot), coin burns enforce cost to toggle.
        if (game.rngLocked()) revert CoinPaused();

        address sender = msg.sender;
        if (_ownerOf(tokenId) != sender) revert Unauthorized();

        bool currentlyStaked = _isTrophyStaked(tokenId);
        uint24 currentLevel = game.level();
        uint8 gameState = game.gameState();
        uint256 priceUnit = game.coinPriceUnit();
        uint24 effectiveLevel = _effectiveStakeLevel(currentLevel, gameState);

        uint256 info = trophyData_[tokenId];
        if (info == 0) revert StakeInvalid();

        uint8 storedKind = _kindFromInfo(info);
        bool isBafTrophy = (info & TROPHY_FLAG_BAF) != 0;

        StakeParams memory params;
        params.player = sender;
        params.tokenId = tokenId;
        params.targetMap = storedKind == PURGE_TROPHY_KIND_MAP;
        params.targetStake = storedKind == PURGE_TROPHY_KIND_STAKE;
        params.targetAffiliate = storedKind == PURGE_TROPHY_KIND_AFFILIATE;
        params.targetBaf = isBafTrophy;
        params.targetExterminator = storedKind == PURGE_TROPHY_KIND_LEVEL && !isBafTrophy;
        params.targetDec = storedKind == PURGE_TROPHY_KIND_DECIMATOR;

        if (stake && sender.code.length != 0) revert StakeInvalid();

        params.effectiveLevel = effectiveLevel;
        params.currentLevel = currentLevel;
        params.priceUnit = priceUnit;

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

        emit TrophyStakeChanged(sender, tokenId, eventData.kind, stake, eventData.count, eventData.discountBps);
    }

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata exterminatorTokenIds,
        uint256[] calldata stakeTokenIds,
        uint256[] calldata affiliateTokenIds
    ) external override {
        address player = msg.sender;
        _refreshMapBonus(player, mapTokenIds);
        _refreshExterminatorStakeBonus(player, exterminatorTokenIds);
        _refreshStakeBonus(player, stakeTokenIds);
        _refreshAffiliateBonus(player, affiliateTokenIds);
    }

    function handleExterminatorTraitPurge(
        address player,
        uint16 traitId
    ) external view override onlyGame returns (uint8 newPercent) {
        if (traitId >= 256) return 0;
        if (!exterminatorStakeTraits_[player][traitId]) return 0;
        (, uint24 earliest) = _exterminatorStakeStats(player);
        if (earliest == 0) return 0;
        uint24 effective = _currentEffectiveStakeLevel();
        if (effective <= earliest) return 0;
        uint24 levelsHeld = effective - earliest;
        if (levelsHeld > 10) {
            return 10;
        }
        return uint8(levelsHeld);
    }

    function affiliateStakeBonus(address player) external view override returns (uint8) {
        return affiliateStakeBonusPct_[player];
    }

    function stakeTrophyBonus(address player) external view override returns (uint8) {
        return stakeStakeBonusPct_[player];
    }

    function decStakeBonus(address player) external view override returns (uint8) {
        (uint8 count, uint24 earliest) = _decStakeStats(player);
        if (count == 0 || earliest == 0) return 0;
        uint24 effective = _currentEffectiveStakeLevel();
        if (effective <= earliest) return 0;
        uint8 cap = _decBonusCap(count);
        uint256 heldLevels = effective - earliest;
        uint256 bonus = heldLevels / 2; // 0.5% per level (rounded down)
        if (bonus > cap) bonus = cap;
        return uint8(bonus);
    }

    function exterminatorStakeDiscount(address player) external view override returns (uint8) {
        return exterminatorStakeDiscountPct_[player];
    }

    function hasExterminatorStake(address player) external view override returns (bool) {
        return exterminatorStakeTraitCount[player] != 0;
    }

    function mapStakeDiscount(address player) external view override returns (uint8) {
        return mapStakeBonusPct_[player];
    }

    function purgeTrophy(uint256 tokenId) external override {
        // Irreversible burn path; blocked for staked trophies to keep accounting consistent.
        if (_isTrophyStaked(tokenId)) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);
        uint256 info = trophyData_[tokenId];
        if (info == 0) revert InvalidToken();
        uint24 baseLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);

        address sender = msg.sender;
        if (_ownerOf(tokenId) != sender) revert Unauthorized();

        nft.clearApproval(tokenId);

        uint256 owed = info & TROPHY_OWED_MASK;
        uint8 kind = _kindFromInfo(info);
        _eraseTrophy(tokenId, kind, true);

        if (owed != 0) {
            game.applyExternalOp(PurgeGameExternalOp.TrophyRecycle, address(0), owed, baseLevel);
        }

        uint256 priceUnit = game.coinPriceUnit();
        coin.creditFlip(sender, _purgeTrophyReward(priceUnit));
    }

    function isTrophy(uint256 tokenId) external view override returns (bool) {
        return trophyData_[tokenId] != 0;
    }

    function stakedTrophySampleWithId(uint256 rngSeed) public view override returns (uint256 tokenId, address owner) {
        uint256 count = stakedTrophyIds.length;
        if (count == 0) return (0, address(0));
        // Double-sample and pick lowest id to smooth modulo bias from count.
        uint256 rand = uint256(keccak256(abi.encodePacked(rngSeed, count)));
        uint256 idxA = count == 1 ? 0 : rand % count;
        uint256 idxB = count == 1 ? idxA : (rand >> 64) % count;
        tokenId = stakedTrophyIds[idxA];
        if (count != 1) {
            uint256 otherToken = stakedTrophyIds[idxB];
            if (otherToken < tokenId) {
                tokenId = otherToken;
            }
        }
        owner = _ownerOf(tokenId);
    }

    function trophyToken(uint24 level, uint8 kind) external view override returns (uint256 tokenId) {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        tokenId = _placeholderTokenId(level, kind, previousBase, currentBase, currentLevel);
        if (tokenId == 0) return 0;
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) {
            return 0; // burned placeholder
        }
    }

    function trophyOwner(uint256 tokenId) external view override returns (address owner) {
        owner = _ownerOf(tokenId);
    }

    function rewardTrophyByToken(uint256 tokenId, uint256 amountWei, uint24 level) external override onlyGameOrCoin {
        _addTrophyRewardInternal(tokenId, amountWei, level);
    }

    function rewardTrophy(
        uint24 level,
        uint8 kind,
        uint256 amountWei
    ) public override onlyGameOrCoin returns (bool paid) {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        uint256 tokenId = _placeholderTokenId(level, kind, previousBase, currentBase, currentLevel);
        if (tokenId == 0) return false;
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) return false; // burned placeholder
        _addTrophyRewardInternal(tokenId, amountWei, level);
        return true;
    }

    function _rewardTrophyClaimsTen(
        uint24 level,
        uint8 kind,
        uint256 amountWei
    ) private returns (bool paid) {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        uint256 tokenId = _placeholderTokenId(level, kind, previousBase, currentBase, currentLevel);
        if (tokenId == 0) return false;
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) return false; // burned placeholder
        _addTrophyRewardInternalClaimsTen(tokenId, amountWei, level);
        return true;
    }

    function rewardRandomStaked(
        uint256 rngSeed,
        uint256 amountWei,
        uint24 level
    ) public override onlyGameOrCoin returns (bool paid) {
        // Sample twice and split reward across the lowest id to reduce duplicate-bias; pseudo-randomness seeded by caller.
        (uint256 tokenIdA, ) = stakedTrophySampleWithId(rngSeed);
        (uint256 tokenIdB, ) = stakedTrophySampleWithId(uint256(keccak256(abi.encodePacked(rngSeed, uint256(7777)))));

        if (tokenIdA == 0 && tokenIdB == 0) {
            return false;
        }
        if (tokenIdA != 0 && (tokenIdB == 0 || tokenIdB == tokenIdA)) {
            _addTrophyRewardInternal(tokenIdA, amountWei, level);
            return true;
        }
        if (tokenIdA == 0) {
            _addTrophyRewardInternal(tokenIdB, amountWei, level);
            return true;
        }

        if (tokenIdB < tokenIdA) {
            uint256 tmp = tokenIdA;
            tokenIdA = tokenIdB;
            tokenIdB = tmp;
        }
        uint256 half = amountWei >> 1;
        uint256 rem = amountWei - half;
        _addTrophyRewardInternal(tokenIdA, half, level);
        _addTrophyRewardInternal(tokenIdB, rem, level);
        return true;
    }

    function _rewardEndgame(uint24 level, uint256 rngSeed, uint256 scaledPool) private returns (uint256 paidTotal) {
        // Scale off the reward pool (already scaled by caller); stake + affiliate trophies each get 1%, random staked gets 0.5%.
        uint256 onePercent = scaledPool / 100;
        uint256 halfPercent = scaledPool / 200;
        uint256 affiliateAmount = onePercent;
        uint256 stakeAmount = onePercent;
        uint256 randomAmount = halfPercent;

        // Treat the stake/affiliate slices as assignment-style rewards so they vest over 10 claims.
        if (_rewardTrophyClaimsTen(level, PURGE_TROPHY_KIND_AFFILIATE, affiliateAmount)) {
            paidTotal += affiliateAmount;
        }
        if (_rewardTrophyClaimsTen(level, PURGE_TROPHY_KIND_STAKE, stakeAmount)) {
            paidTotal += stakeAmount;
        }
        if (rewardRandomStaked(rngSeed, randomAmount, level)) {
            paidTotal += randomAmount;
        }
    }

    function processEndLevel(
        EndLevelRequest calldata req,
        uint256 scaledPool
    ) external override onlyGame returns (uint256 paidTotal) {
        _processEndLevel(req);
        paidTotal = _rewardEndgame(req.level, req.rngWord, scaledPool);
    }

    function isTrophyStaked(uint256 tokenId) external view override returns (bool) {
        return stakedTrophyIndex[tokenId] != 0;
    }

    function trophyData(uint256 tokenId) external view override returns (uint256 rawData) {
        return trophyData_[tokenId];
    }

    // ---------------------------------------------------------------------
    // Internal randomness helpers
    // ---------------------------------------------------------------------

    function prepareNextLevel(uint24 nextLevel) public override {
        (, uint256 currentBase) = nft.getBasePointers();
        // Coin can prime the initial level when no base pointer is set; only the game advances thereafter.
        if (msg.sender != gameAddress) {
            if (msg.sender != coinAddress || currentBase != 0) revert Unauthorized();
        }
        uint256 newBase = _mintTrophyPlaceholders(nextLevel);
        nft.setBasePointers(currentBase, newBase);
    }

    function _wire(address game_, address coin_) private {
        if (gameAddress != address(0)) revert AlreadyWired();
        if (game_ == address(0)) revert ZeroAddress();
        if (msg.sender != coinAddress) revert OnlyCoin();
        if (coin_ != address(0) && coin_ != coinAddress) revert Unauthorized();
        // One-time wiring invoked by coin; locks in trusted game address.
        gameAddress = game_;
        game = IPurgeGameMinimal(game_);
    }
}
