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
        uint256 pool;
    }

    function wire(address game_, address coin_) external;
    function wireAndPrime(address game_, address coin_, uint24 firstLevel) external;

    function clearStakePreview(uint24 level) external;

    function prepareNextLevel(uint24 nextLevel) external;

    function awardTrophy(address to, uint24 level, uint8 kind, uint256 data, uint256 deferredWei) external payable;

    function burnBafPlaceholder(uint24 level) external;

    function burnDecPlaceholder(uint24 level) external;

    function processEndLevel(
        EndLevelRequest calldata req
    ) external payable returns (address mapImmediateRecipient, address[6] memory affiliateRecipients);

    function claimTrophy(uint256 tokenId) external;

    function setTrophyStake(uint256 tokenId, bool stake) external;

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata exterminatorTokenIds,
        uint256[] calldata stakeTokenIds
    ) external;

    function affiliateStakeBonus(address player) external view returns (uint8);

    function stakeTrophyBonus(address player) external view returns (uint8);

    function mapStakeDiscount(address player) external view returns (uint8);

    function exterminatorStakeDiscount(address player) external view returns (uint8);

    function hasExterminatorStake(address player) external view returns (bool);

    function purgeTrophy(uint256 tokenId) external;

    function stakedTrophySample(uint64 salt) external view returns (address owner);

    function hasTrophy(uint256 tokenId) external view returns (bool);

    function trophyData(uint256 tokenId) external view returns (uint256 rawData);

    function isTrophyStaked(uint256 tokenId) external view returns (bool);

    function burnieTrophies() external;

    function handleExterminatorTraitPurge(address player, uint16 traitId) external returns (uint8 newPercent);
}

interface IPurgeGameMinimal {
    function level() external view returns (uint24);
    function gameState() external view returns (uint8);
    function rngLocked() external view returns (bool);
    function currentRngWord() external view returns (uint256);
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
        bool targetExterminator;
        bool targetStake;
        bool targetBaf;
        bool pureExterminatorTrophy;
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

    struct BafStakeInfo {
        uint24 lastLevel;
        uint32 lastDay;
        uint32 claimedToday;
        uint8 count;
        uint256 pending;
    }

    // ---------------------------------------------------------------------
    // Trophy constants
    // ---------------------------------------------------------------------
    uint32 private constant COIN_DRIP_STEPS = 10;
    uint256 private constant COIN_BASE_UNIT = 1_000_000;
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * COIN_BASE_UNIT;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_FLAG_AFFILIATE = uint256(1) << 201;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;
    uint256 private constant TROPHY_LAST_CLAIM_MASK = uint256(0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT;

    uint8 private constant _STAKE_ERR_TRANSFER_BLOCKED = 1;
    uint8 private constant _STAKE_ERR_NOT_LEVEL = 2;
    uint8 private constant _STAKE_ERR_ALREADY_STAKED = 3;
    uint8 private constant _STAKE_ERR_NOT_STAKED = 4;
    uint8 private constant _STAKE_ERR_LOCKED = 5;
    uint8 private constant _STAKE_ERR_NOT_MAP = 6;
    uint8 private constant _STAKE_ERR_NOT_AFFILIATE = 7;
    uint8 private constant _STAKE_ERR_NOT_STAKE = 8;

    uint8 private constant MAP_STAKE_MAX = 20;
    uint8 private constant EXTERMINATOR_STAKE_MAX = 20;
    uint8 private constant AFFILIATE_STAKE_MAX = 20;
    uint8 private constant STAKE_TROPHY_MAX = 20;
    uint8 private constant EXTERMINATOR_STAKE_COIN_CAP = 25;
    uint256 private constant BAF_LEVEL_REWARD = 100 * COIN_BASE_UNIT;
    uint256 private constant BAF_DAILY_CAP = 2_000 * COIN_BASE_UNIT;

    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;

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
    mapping(address => uint8) private exterminatorStakeCount_;
    mapping(address => uint8) private exterminatorStakeBonusPct_;
    mapping(address => mapping(uint16 => uint8)) private exterminatorStakeTraitCount_;
    mapping(address => mapping(uint16 => uint8)) private exterminatorStakeTraitPct_;
    mapping(address => uint16[]) private exterminatorStakeTraits_;
    mapping(address => mapping(uint16 => uint256)) private exterminatorStakeTraitIndex_;
    mapping(address => uint8) private stakeStakeCount_;
    mapping(address => uint8) private stakeStakeBonusPct_;
    mapping(address => BafStakeInfo) private bafStakeInfo;

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
        _wire(game_, coin_);
    }

    function wireAndPrime(address game_, address coin_, uint24 firstLevel) external override {
        _wire(game_, coin_);
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

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _placeholderTokenId(uint24 level, uint8 kind) private view returns (uint256) {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();

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
        if ((level % 100) == 0) return false;
        return (level % 20) == 0;
    }

    function _shouldMintDec(uint24 level) private pure returns (bool) {
        if (level == DECIMATOR_SPECIAL_LEVEL) return true;
        if (level < 25) return false;
        if ((level % 10) != 5) return false;
        if ((level % 100) == 95) return false;
        return true;
    }

    function _setTrophyData(uint256 tokenId, uint256 data) private {
        trophyData_[tokenId] = data;
    }

    function _eraseTrophy(uint256 tokenId, uint8 kind, bool adjustSupply) private {
        if (trophyStaked[tokenId]) revert StakeInvalid();
        bool hadData = trophyData_[tokenId] != 0;
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
        uint256 updated = (info & ~(TROPHY_OWED_MASK | (uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT))) |
            (owed & TROPHY_OWED_MASK) |
            (base << TROPHY_BASE_LEVEL_SHIFT);
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
        uint8 count = exterminatorStakeTraitCount_[player][traitId];
        unchecked {
            count += 1;
        }
        exterminatorStakeTraitCount_[player][traitId] = count;
        if (count == 1) {
            exterminatorStakeTraitIndex_[player][traitId] = exterminatorStakeTraits_[player].length + 1;
            exterminatorStakeTraits_[player].push(traitId);
        }
        if (exterminatorStakeTraitPct_[player][traitId] > EXTERMINATOR_STAKE_COIN_CAP) {
            exterminatorStakeTraitPct_[player][traitId] = EXTERMINATOR_STAKE_COIN_CAP;
        }
        _recomputeExterminatorStakeBonus(player);
    }

    function _removeExterminatorStakeTrait(address player, uint16 traitId) private {
        uint8 count = exterminatorStakeTraitCount_[player][traitId];
        if (count == 0) return;
        unchecked {
            exterminatorStakeTraitCount_[player][traitId] = count - 1;
        }
        if (count == 1) {
            uint256 index = exterminatorStakeTraitIndex_[player][traitId];
            if (index != 0) {
                uint16[] storage list = exterminatorStakeTraits_[player];
                uint256 lastIndex = list.length;
                if (index != lastIndex) {
                    uint16 lastTrait = list[lastIndex - 1];
                    list[index - 1] = lastTrait;
                    exterminatorStakeTraitIndex_[player][lastTrait] = index;
                }
                list.pop();
                delete exterminatorStakeTraitIndex_[player][traitId];
            }
            exterminatorStakeTraitPct_[player][traitId] = 0;
        }
        _recomputeExterminatorStakeBonus(player);
    }

    function _recomputeExterminatorStakeBonus(address player) private {
        uint16[] storage traits = exterminatorStakeTraits_[player];
        uint8 best;
        for (uint256 i; i < traits.length; ) {
            uint16 traitId = traits[i];
            if (exterminatorStakeTraitCount_[player][traitId] != 0) {
                uint8 pct = exterminatorStakeTraitPct_[player][traitId];
                if (pct > best) {
                    best = pct;
                }
            }
            unchecked {
                ++i;
            }
        }
        exterminatorStakeBonusPct_[player] = best;
    }

    function _mapDiscountCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 7;
        if (count == 2) return 12;
        if (count == 3) return 15;
        if (count == 4) return 20;
        return 25;
    }

    function _exterminatorStakeDiscountCap(uint8 count) private pure returns (uint8) {
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
            uint256 updatedInfo = lastCleared |
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
        } else if (params.targetExterminator) {
            if (params.pureExterminatorTrophy) {
                uint8 current = exterminatorStakeCount_[params.player];
                if (current >= EXTERMINATOR_STAKE_MAX) revert StakeInvalid();
                unchecked {
                    current += 1;
                }
                exterminatorStakeCount_[params.player] = current;
                uint8 cap = _exterminatorStakeDiscountCap(current);
                uint8 candidate = params.trophyBaseLevel > cap ? cap : uint8(params.trophyBaseLevel);
                uint8 prev = exterminatorStakeBonusPct_[params.player];
                if (candidate > prev) {
                    exterminatorStakeBonusPct_[params.player] = candidate;
                }
            }
            uint16 traitId = uint16((trophyData_[params.tokenId] >> 152) & 0xFFFF);
            _addExterminatorStakeTrait(params.player, traitId);
            discountPct = 0;
            data.kind = 3;
            data.count = exterminatorStakeCount_[params.player];
        } else if (params.targetBaf) {
            BafStakeInfo storage state = bafStakeInfo[params.player];
            _syncBafStake(params.player, state);
            uint8 current = state.count;
            if (current == type(uint8).max) revert StakeInvalid();
            unchecked {
                current += 1;
            }
            state.count = current;
            if (state.lastDay == 0) {
                state.lastDay = uint32(block.timestamp / 1 days);
            }
            discountPct = 0;
            data.kind = 5;
            data.count = current;
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
        uint256 info = trophyData_[params.tokenId];
        if (info == 0) revert StakeInvalid();
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
            uint8 prevPct = mapStakeBonusPct_[params.player];
            if (current == 0) {
                if (prevPct != 0) {
                    mapStakeBonusPct_[params.player] = 0;
                }
            } else {
                uint8 cap = _mapDiscountCap(current);
                if (prevPct > cap) {
                    mapStakeBonusPct_[params.player] = cap;
                }
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
        } else if (params.targetExterminator) {
            uint8 current = exterminatorStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            exterminatorStakeCount_[params.player] = current;
            uint8 prevPct = exterminatorStakeBonusPct_[params.player];
            if (current == 0) {
                if (prevPct != 0) {
                    exterminatorStakeBonusPct_[params.player] = 0;
                }
            } else {
                uint8 cap = _exterminatorStakeDiscountCap(current);
                if (prevPct > cap) {
                    exterminatorStakeBonusPct_[params.player] = cap;
                }
            }
            uint16 traitId = uint16((info >> 152) & 0xFFFF);
            _removeExterminatorStakeTrait(params.player, traitId);
            data.kind = 3;
            data.count = current;
        } else if (params.targetBaf) {
            BafStakeInfo storage state = bafStakeInfo[params.player];
            _syncBafStake(params.player, state);
            uint8 current = state.count;
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            state.count = current;
            data.kind = 5;
            data.count = current;
        } else {
            uint8 current = stakeStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            stakeStakeCount_[params.player] = current;
            uint8 prevPct = stakeStakeBonusPct_[params.player];
            if (current == 0) {
                if (prevPct != 0) {
                    stakeStakeBonusPct_[params.player] = 0;
                }
            } else {
                uint8 cap = _stakeBonusCap(current);
                if (prevPct > cap) {
                    stakeStakeBonusPct_[params.player] = cap;
                }
            }
            data.kind = 4;
            data.count = current;
        }

        data.discountBps = 0;
        return data;
    }

    function _refreshMapBonus(address player, uint256[] calldata tokenIds) private {
        uint8 expected = mapStakeCount_[player];
        uint256 len = tokenIds.length;
        if (len == 0) {
            if (expected == 0) {
                mapStakeBonusPct_[player] = 0;
                return;
            }
            revert StakeInvalid();
        }
        if (expected == 0 || len != expected) revert StakeInvalid();
        uint8 cap = _mapDiscountCap(expected);
        uint24 cap24 = cap;
        uint24 best;
        bool found;
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            if ((info & TROPHY_FLAG_MAP) == 0) revert StakeInvalid();
            uint24 base = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
            if (base > best) {
                best = base;
                found = true;
                if (cap != 0 && best >= cap24) {
                    best = cap24;
                    break;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (!found) revert StakeInvalid();
        mapStakeBonusPct_[player] = uint8(best > cap24 ? cap : best);
    }

    function _refreshExterminatorStakeBonus(address player, uint256[] calldata tokenIds) private {
        uint8 expected = exterminatorStakeCount_[player];
        uint256 len = tokenIds.length;
        if (len == 0) {
            if (expected == 0) {
                exterminatorStakeBonusPct_[player] = 0;
                return;
            }
            revert StakeInvalid();
        }
        if (expected == 0 || len != expected) revert StakeInvalid();
        uint8 cap = _exterminatorStakeDiscountCap(expected);
        uint24 cap24 = cap;
        uint24 best;
        bool found;
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            bool invalid = (info & TROPHY_FLAG_MAP) != 0 ||
                (info & TROPHY_FLAG_AFFILIATE) != 0 ||
                (info & TROPHY_FLAG_STAKE) != 0 ||
                (info & TROPHY_FLAG_BAF) != 0;
            if (invalid) revert StakeInvalid();
            uint24 base = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
            if (base > best) {
                best = base;
                found = true;
                if (cap != 0 && best >= cap24) {
                    best = cap24;
                    break;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (!found) revert StakeInvalid();
        exterminatorStakeBonusPct_[player] = uint8(best > cap24 ? cap : best);
    }

    function _refreshStakeBonus(address player, uint256[] calldata tokenIds) private {
        uint8 expected = stakeStakeCount_[player];
        uint256 len = tokenIds.length;
        if (len == 0) {
            if (expected == 0) {
                stakeStakeBonusPct_[player] = 0;
                return;
            }
            revert StakeInvalid();
        }
        if (expected == 0 || len != expected) revert StakeInvalid();
        uint8 cap = _stakeBonusCap(expected);
        uint24 cap24 = cap;
        uint24 best;
        bool found;
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            _ensurePlayerOwnsStaked(player, tokenId);
            uint256 info = trophyData_[tokenId];
            if ((info & TROPHY_FLAG_STAKE) == 0) revert StakeInvalid();
            uint24 value = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
            if (value > best) {
                best = value;
                found = true;
                if (cap != 0 && best >= cap24) {
                    best = cap24;
                    break;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (!found) revert StakeInvalid();
        stakeStakeBonusPct_[player] = uint8(best > cap24 ? cap : best);
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

        uint256 mintedStart = nft.mintPlaceholders(mintedCount);
        if (mintedStart != startId) {
            // Defensive: NFT must mint sequentially.
            revert InvalidToken();
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
        address caller = msg.sender;
        bool fromGame = caller == gameAddress;
        bool fromCoin = caller == coinAddress;
        if (!fromGame && !fromCoin) {
            _returnValue(caller, deferredWei);
            return;
        }

        uint256 tokenId = _placeholderTokenId(level, kind);


        _awardTrophyInternal(to, kind, data, deferredWei, tokenId);
    }

    function clearStakePreview(uint24 level) external override onlyCoinCaller {
        uint256 tokenId = _placeholderTokenId(level, PURGE_TROPHY_KIND_STAKE);
        _eraseTrophy(tokenId, PURGE_TROPHY_KIND_STAKE, false);
    }

    function burnBafPlaceholder(uint24 level) external override onlyCoinCaller {
        uint256 tokenId = _placeholderTokenId(level, PURGE_TROPHY_KIND_BAF);
        if (tokenId == 0) return;
        _eraseTrophy(tokenId, PURGE_TROPHY_KIND_BAF, false);
    }

    function burnDecPlaceholder(uint24 level) external override onlyCoinCaller {
        uint256 tokenId = _placeholderTokenId(level, PURGE_TROPHY_KIND_DECIMATOR);
        if (tokenId == 0) return;
        _eraseTrophy(tokenId, PURGE_TROPHY_KIND_DECIMATOR, false);
    }

    function processEndLevel(
        EndLevelRequest calldata req
    )
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
        uint256 randomWord = game.currentRngWord();

        if (traitWin) {
            affiliateRecipients = _processTraitWin(req, nextLevel, levelTokenId, affiliateTokenId, randomWord);
        } else {
            (mapImmediateRecipient, affiliateRecipients) = _processTimeout(
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
        if (req.traitId == DECIMATOR_TRAIT_SENTINEL) {
            ctx.traitData |= TROPHY_FLAG_DECIMATOR;
        }
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

    function _processTimeout(
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

    function _processDecimatorClaim(ClaimContext memory ctx) private view {
        if (!ctx.isStaked) revert ClaimNotReady();
        uint32 start = uint32((ctx.info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
        uint32 floor = start - 1;
        uint32 last = ctx.lastClaim;
        if (last < floor) last = floor;
        if (ctx.currentLevel > last) {
            if (game.rngLocked()) revert CoinPaused();
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

    function _processBafClaim(address player, ClaimContext memory ctx) private {
        if (!ctx.isStaked) revert ClaimNotReady();
        BafStakeInfo storage state = bafStakeInfo[player];
        _syncBafStake(player, state);

        uint32 currentDay = uint32(block.timestamp / 1 days);
        if (state.lastDay != currentDay) {
            state.lastDay = currentDay;
            state.claimedToday = 0;
        }

        uint256 pending = state.pending;
        if (pending == 0) revert ClaimNotReady();

        uint256 dailyRemaining = BAF_DAILY_CAP - uint256(state.claimedToday);
        if (dailyRemaining == 0) revert ClaimNotReady();

        uint256 payout = pending;
        if (payout > dailyRemaining) {
            payout = dailyRemaining;
        }

        state.pending = pending - payout;
        state.claimedToday += uint32(payout);

        ctx.coinAmount = payout;
        ctx.coinClaimed = true;
    }

    function _isTrophyStaked(uint256 tokenId) private view returns (bool) {
        return trophyStaked[tokenId];
    }

    function _isDecimatorTrophy(uint256 info) private pure returns (bool) {
        if (info & TROPHY_FLAG_DECIMATOR != 0) return true;
        uint16 traitId = uint16((info >> 152) & 0xFFFF);
        return traitId == DECIMATOR_TRAIT_SENTINEL;
    }

    function _isBafTrophy(uint256 info) private pure returns (bool) {
        return (info & TROPHY_FLAG_BAF) != 0;
    }

    function _bootstrapBafStake(address player, BafStakeInfo storage state) private {
        if (state.count != 0) return;
        uint8 count;
        uint256 len = stakedTrophyIds.length;
        for (uint256 i; i < len; ) {
            uint256 tokenId = stakedTrophyIds[i];
            if (trophyStaked[tokenId] && _isBafTrophy(trophyData_[tokenId])) {
                address owner = address(uint160(nft.packedOwnershipOf(tokenId)));
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
            if (state.lastDay == 0) {
                state.lastDay = uint32(block.timestamp / 1 days);
            }
            if (state.lastLevel == 0) {
                state.lastLevel = game.level();
            }
        }
    }

    function _syncBafStake(address player, BafStakeInfo storage state) private {
        _bootstrapBafStake(player, state);
        uint24 currentLevel = game.level();
        if (state.lastLevel == 0) {
            state.lastLevel = currentLevel;
            if (state.lastDay == 0) {
                state.lastDay = uint32(block.timestamp / 1 days);
            }
            return;
        }
        if (state.count != 0 && currentLevel > state.lastLevel) {
            uint256 delta = uint256(currentLevel - state.lastLevel) * uint256(state.count);
            state.pending += delta * BAF_LEVEL_REWARD;
        }
        state.lastLevel = currentLevel;
    }

    function _effectiveStakeLevel() private view returns (uint24) {
        uint24 lvl = game.level();
        uint8 state = game.gameState();
        if (state == 3) {
            return lvl;
        }
        if (lvl == 0) {
            return 0;
        }
        unchecked {
            return uint24(lvl - 1);
        }
    }

    function _kindFromInfo(uint256 info) private pure returns (uint8 kind) {
        if (info & TROPHY_FLAG_MAP != 0) return PURGE_TROPHY_KIND_MAP;
        if (info & TROPHY_FLAG_AFFILIATE != 0) return PURGE_TROPHY_KIND_AFFILIATE;
        if (info & TROPHY_FLAG_STAKE != 0) return PURGE_TROPHY_KIND_STAKE;
        if (info & TROPHY_FLAG_BAF != 0) return PURGE_TROPHY_KIND_BAF;
        if (info & TROPHY_FLAG_DECIMATOR != 0) return PURGE_TROPHY_KIND_DECIMATOR;
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

        if (_isDecimatorTrophy(ctx.info)) {
            _processDecimatorClaim(ctx);
        } else if (_isBafTrophy(ctx.info)) {
            _processBafClaim(msg.sender, ctx);
        }

        if (!ctx.ethClaimed && !ctx.coinClaimed) revert ClaimNotReady();
        uint256 newInfo = (ctx.info & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK)) |
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

    function setTrophyStake(uint256 tokenId, bool stake) external override {
        if (game.rngLocked()) revert CoinPaused();

        address sender = msg.sender;
        if (address(uint160(nft.packedOwnershipOf(tokenId))) != sender) revert Unauthorized();

        bool currentlyStaked = _isTrophyStaked(tokenId);
        uint24 effectiveLevel = _effectiveStakeLevel();
        uint8 gameState = game.gameState();

        uint256 info = trophyData_[tokenId];
        if (info == 0) revert StakeInvalid();

        uint8 storedKind = _kindFromInfo(info);
        bool isBafTrophy = (info & TROPHY_FLAG_BAF) != 0;
        bool isDecTrophy = (info & TROPHY_FLAG_DECIMATOR) != 0;
        if (isDecTrophy) revert StakeInvalid();

        StakeParams memory params;
        params.player = sender;
        params.tokenId = tokenId;
        params.targetMap = storedKind == PURGE_TROPHY_KIND_MAP;
        params.targetStake = storedKind == PURGE_TROPHY_KIND_STAKE;
        params.targetAffiliate = storedKind == PURGE_TROPHY_KIND_AFFILIATE;
        params.targetBaf = isBafTrophy;
        params.targetExterminator = storedKind == PURGE_TROPHY_KIND_LEVEL && !isBafTrophy;

        if (stake && sender.code.length != 0) revert StakeInvalid();

        params.trophyBaseLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
        params.trophyLevelValue = params.trophyBaseLevel;
        params.pureExterminatorTrophy = params.targetExterminator;
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

        emit TrophyStakeChanged(sender, tokenId, eventData.kind, stake, eventData.count, eventData.discountBps);
    }

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata exterminatorTokenIds,
        uint256[] calldata stakeTokenIds
    ) external override {
        address player = msg.sender;
        _refreshMapBonus(player, mapTokenIds);
        _refreshExterminatorStakeBonus(player, exterminatorTokenIds);
        _refreshStakeBonus(player, stakeTokenIds);
    }

    function handleExterminatorTraitPurge(
        address player,
        uint16 traitId
    ) external override onlyGame returns (uint8 newPercent) {
        if (exterminatorStakeTraitCount_[player][traitId] == 0) return 0;
        uint8 current = exterminatorStakeTraitPct_[player][traitId];
        if (current < EXTERMINATOR_STAKE_COIN_CAP) {
            unchecked {
                current += 1;
            }
            if (current > EXTERMINATOR_STAKE_COIN_CAP) {
                current = EXTERMINATOR_STAKE_COIN_CAP;
            }
            exterminatorStakeTraitPct_[player][traitId] = current;
            _recomputeExterminatorStakeBonus(player);
        }
        return current;
    }

    function affiliateStakeBonus(address player) external view override returns (uint8) {
        uint24 effective = _effectiveStakeLevel();
        return _currentAffiliateBonus(player, effective);
    }

    function stakeTrophyBonus(address player) external view override returns (uint8) {
        return stakeStakeBonusPct_[player];
    }

    function exterminatorStakeDiscount(address player) external view override returns (uint8) {
        return exterminatorStakeBonusPct_[player];
    }

    function hasExterminatorStake(address player) external view override returns (bool) {
        return exterminatorStakeTraits_[player].length != 0;
    }

    function mapStakeDiscount(address player) external view override returns (uint8) {
        return mapStakeBonusPct_[player];
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

    function isTrophyStaked(uint256 tokenId) external view override returns (bool) {
        return trophyStaked[tokenId];
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

    function _selectAffiliateRecipients(uint256 randomWord) private view returns (address[6] memory recipients) {
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
                    uint256 idx = 2 + ((rand & mask) % span);
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
                    uint256 idx = 2 + ((rand & mask) % span);
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

    function prepareNextLevel(uint24 nextLevel) public override {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        if (msg.sender != gameAddress) {
            if (msg.sender != coinAddress || currentBase != 0) revert Unauthorized();
        }
        uint256 newBase = _mintTrophyPlaceholders(nextLevel);
        nft.setBasePointers(previousBase, newBase);
    }

    function _wire(address game_, address coin_) private {
        if (gameAddress != address(0)) revert AlreadyWired();
        if (game_ == address(0) || coin_ == address(0)) revert ZeroAddress();
        if (msg.sender != coin_) revert OnlyCoin();
        gameAddress = game_;
        coinAddress = coin_;
        game = IPurgeGameMinimal(game_);
        coin = IPurgecoinMinimal(coin_);
    }
}
