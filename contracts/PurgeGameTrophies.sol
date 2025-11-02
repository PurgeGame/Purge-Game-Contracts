// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameNftModule} from "./interfaces/IPurgeGameNftModule.sol";
import {IPurgeGameTrophies} from "./interfaces/IPurgeGameTrophies.sol";

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
        bool bafTrophy;
        uint24 trophyBaseLevel;
        uint24 trophyLevelValue;
        uint24 effectiveLevel;
    }

    struct StakeEventData {
        uint8 kind;
        uint8 count;
        uint16 discountBps;
    }

    struct StakeExecutionRequest {
        address player;
        uint256 tokenId;
        bool isMap;
        bool stake;
        bool currentlyStaked;
        uint24 currentLevel;
        uint24 effectiveLevel;
        uint8 gameState;
    }

    struct StakeExecutionResult {
        StakeEventData eventData;
        bool deleteApproval;
        uint256 decimatorPayout;
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
    uint8 private constant LEVEL_STAKE_MAX = 20;
    uint8 private constant AFFILIATE_STAKE_MAX = 20;
    uint8 private constant STAKE_TROPHY_MAX = 20;

    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    uint16 private constant STAKE_TRAIT_SENTINEL = 0xFFFD;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;

    uint24 private constant STAKE_PREVIEW_START_LEVEL = 12;

    uint8 private constant _BONUS_MAP = 0;
    uint8 private constant _BONUS_LEVEL = 1;
    uint8 private constant _BONUS_STAKE = 2;
    uint8 private constant _BONUS_BAF = 3;

    uint256 private constant LUCKBOX_BYPASS_THRESHOLD = 100_000 * 1_000_000;

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
    mapping(address => uint8) private bafStakeCount_;
    mapping(address => uint16) private bafStakeBonusBps_;

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

    function _hasBafTrophy(uint24 level) private pure returns (bool) {
        if (level == 0) return false;
        return level % 20 == 0;
    }

    function _hasDecimatorTrophy(uint24 level) private pure returns (bool) {
        if (level < 25) return false;
        if (level % 10 != 5) return false;
        return (level % 100) != 95;
    }

    function _stakePreviewData(uint24 level) private pure returns (uint256) {
        uint24 baseLevel = level == 0 ? 0 : uint24(level - 1);
        return
            (uint256(STAKE_TRAIT_SENTINEL) << 152) |
            (uint256(baseLevel) << TROPHY_BASE_LEVEL_SHIFT) |
            TROPHY_FLAG_STAKE;
    }

    function _placeholderBase(uint24 level) private view returns (uint256 base) {
        (uint256 previousBase, uint256 currentBase) = nft.getBasePointers();
        uint24 currentLevel = game.level();
        if (level == currentLevel) {
            base = currentBase;
            if (base == 0) revert InvalidToken();
            return base;
        }
        if (level + 1 == currentLevel) {
            base = previousBase;
            if (base == 0) revert InvalidToken();
            return base;
        }
        revert InvalidToken();
    }

    function _placeholderTokenId(uint24 level, IPurgeGameTrophies.TrophyKind kind) private view returns (uint256) {
        uint256 base = _placeholderBase(level);
        if (kind == IPurgeGameTrophies.TrophyKind.Level) return base - 1;
        if (kind == IPurgeGameTrophies.TrophyKind.Map) return base - 2;
        if (kind == IPurgeGameTrophies.TrophyKind.Affiliate) return base - 3;
        if (kind == IPurgeGameTrophies.TrophyKind.Stake) return base - 4;
        if (kind == IPurgeGameTrophies.TrophyKind.Baf) {
            if (!_hasBafTrophy(level)) revert InvalidToken();
            return base - 5;
        }
        if (kind == IPurgeGameTrophies.TrophyKind.Decimator) {
            if (!_hasDecimatorTrophy(level)) revert InvalidToken();
            return base - 5;
        }
        revert InvalidToken();
    }


    function _setTrophyData(uint256 tokenId, uint256 data) private {
        trophyData_[tokenId] = data;
    }

    function _clearTrophy(uint256 tokenId) private returns (bool hadData) {
        if (trophyStaked[tokenId]) revert StakeInvalid();
        hadData = trophyData_[tokenId] != 0;
        delete trophyData_[tokenId];
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

    function _setDecimatorBaselineInternal(uint256 tokenId, uint24 level) private {
        uint256 info = trophyData_[tokenId];
        uint256 cleared = info & ~TROPHY_LAST_CLAIM_MASK;
        uint256 updated = cleared | (uint256(level & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
        trophyData_[tokenId] = updated;
    }

    function _payoutDecimatorStakeInternal(uint256 tokenId, uint24 currentLevel) private returns (uint256) {
        uint256 info = trophyData_[tokenId];
        uint24 lastClaim = uint24((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);
        if (currentLevel <= lastClaim) return 0;
        uint256 amount = _decimatorCoinBetween(lastClaim, currentLevel);
        if (amount == 0) return 0;
        uint256 newInfo = (info & ~TROPHY_LAST_CLAIM_MASK) | (uint256(currentLevel) << TROPHY_LAST_CLAIM_SHIFT);
        trophyData_[tokenId] = newInfo;
        return amount;
    }

    function _decimatorCoinBetween(uint24 fromLevel, uint24 toLevel) private pure returns (uint256 reward) {
        if (toLevel <= fromLevel) return 0;
        uint256 start = uint256(fromLevel) + 1;
        uint256 end = uint256(toLevel);
        uint256 bucketStart = (start - 1) / 10;
        uint256 bucketEnd = (end - 1) / 10;
        for (uint256 bucket = bucketStart; bucket <= bucketEnd; ) {
            uint256 bucketLow = bucket * 10 + 1;
            uint256 bucketHigh = bucketLow + 9;
            if (bucketHigh > end) bucketHigh = end;
            uint256 segStart = start > bucketLow ? start : bucketLow;
            uint256 segEnd = end < bucketHigh ? end : bucketHigh;
            if (segStart <= segEnd) {
                uint256 count = segEnd - segStart + 1;
                uint256 multiplier = bucket + 1;
                if (multiplier > 10) multiplier = 10;
                reward += count * multiplier;
            }
            if (bucket == bucketEnd) break;
            unchecked {
                bucket += 1;
            }
        }
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

    function _bafBonusFromLevel(uint24 level) private pure returns (uint16) {
        uint256 bonus = uint256(level) * 10;
        if (bonus > 220) bonus = 220;
        return uint16(bonus);
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

        if (params.bafTrophy) {
            uint8 current = bafStakeCount_[params.player];
            unchecked {
                current += 1;
            }
            bafStakeCount_[params.player] = current;
            uint16 candidate = _bafBonusFromLevel(params.trophyBaseLevel);
            uint16 prev = bafStakeBonusBps_[params.player];
            if (candidate > prev) {
                bafStakeBonusBps_[params.player] = candidate;
            }
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

        if (params.bafTrophy) {
            uint8 current = bafStakeCount_[params.player];
            if (current != 0) {
                unchecked {
                    current -= 1;
                }
            }
            bafStakeCount_[params.player] = current;
            if (current == 0) {
                bafStakeBonusBps_[params.player] = 0;
            }
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
            bool invalid = (info & TROPHY_FLAG_MAP) != 0 || (info & TROPHY_FLAG_AFFILIATE) != 0
                || (info & TROPHY_FLAG_STAKE) != 0 || (info & TROPHY_FLAG_BAF) != 0
                || (info & TROPHY_FLAG_DECIMATOR) != 0;
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

    function _refreshBafBonus(address player, uint256[] calldata tokenIds) private {
        uint8 expected = bafStakeCount_[player];
        if (tokenIds.length == 0) {
            if (expected == 0) {
                bafStakeBonusBps_[player] = 0;
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
            if ((info & TROPHY_FLAG_BAF) == 0) revert StakeInvalid();
            uint24 base = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
            if (base > best) best = base;
            unchecked {
                ++i;
            }
        }
        if (best == 0) revert StakeInvalid();
        bafStakeBonusBps_[player] = _bafBonusFromLevel(best);
    }

    function _mintTrophyPlaceholders(uint24 level) private returns (uint256 newBaseTokenId) {
        uint256 baseData = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT);
        bool mintBaf = _hasBafTrophy(level);
        bool mintDec = _hasDecimatorTrophy(level);

        uint256 placeholderCount = mintBaf || mintDec ? 5 : 4;
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

        if (mintBaf || mintDec) {
            uint256 specialTokenId = nextId++;
            if (mintBaf) {
                _setTrophyData(specialTokenId, baseData | TROPHY_FLAG_BAF);
                nft.setTrophyPackedInfo(specialTokenId, uint8(IPurgeGameTrophies.TrophyKind.Baf), false);
            } else {
                _setTrophyData(specialTokenId, baseData | TROPHY_FLAG_DECIMATOR);
                nft.setTrophyPackedInfo(specialTokenId, uint8(IPurgeGameTrophies.TrophyKind.Decimator), false);
            }
        }

        uint256 stakeTokenId = nextId++;
        if (level >= STAKE_PREVIEW_START_LEVEL) {
            _setTrophyData(stakeTokenId, _stakePreviewData(level));
        } else {
            _clearTrophy(stakeTokenId);
        }
        nft.setTrophyPackedInfo(stakeTokenId, uint8(IPurgeGameTrophies.TrophyKind.Stake), false);

        uint256 affiliateTokenId = nextId++;
        _setTrophyData(affiliateTokenId, baseData | TROPHY_FLAG_AFFILIATE);
        nft.setTrophyPackedInfo(affiliateTokenId, uint8(IPurgeGameTrophies.TrophyKind.Affiliate), false);

        uint256 mapTokenId = nextId++;
        _setTrophyData(mapTokenId, baseData | TROPHY_FLAG_MAP);
        nft.setTrophyPackedInfo(mapTokenId, uint8(IPurgeGameTrophies.TrophyKind.Map), false);

        uint256 levelTokenId = nextId++;
        _setTrophyData(levelTokenId, baseData);
        nft.setTrophyPackedInfo(levelTokenId, uint8(IPurgeGameTrophies.TrophyKind.Level), false);

        newBaseTokenId = startId + mintedCount;
    }

    // ---------------------------------------------------------------------
    // Trophy placeholder lifecycle
    // ---------------------------------------------------------------------

    function clearStakePreview(uint24 level) external override onlyCoinCaller {
        uint256 tokenId = _placeholderTokenId(level, IPurgeGameTrophies.TrophyKind.Stake);
        if (trophyData_[tokenId] == 0) return;
        address owner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (owner != gameAddress) return;
        _clearTrophy(tokenId);
    }

    function _awardTrophyInternal(
        address to,
        IPurgeGameTrophies.TrophyKind kind,
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

        nft.setTrophyPackedInfo(tokenId, uint8(kind), false);
    }

    // ---------------------------------------------------------------------
    // Trophy awarding & end-level flows
    // ---------------------------------------------------------------------

    function awardTrophy(
        address to,
        uint24 level,
        IPurgeGameTrophies.TrophyKind kind,
        uint256 data,
        uint256 deferredWei
    ) external payable override {
        bool fromGame = msg.sender == gameAddress;
        bool fromCoin = msg.sender == coinAddress;
        if (!fromGame && !fromCoin) revert Unauthorized();

        if (kind == IPurgeGameTrophies.TrophyKind.Stake) revert StakeInvalid();

        if (fromGame) {
            if (kind == IPurgeGameTrophies.TrophyKind.Baf || kind == IPurgeGameTrophies.TrophyKind.Decimator) revert StakeInvalid();
        } else {
            if (kind != IPurgeGameTrophies.TrophyKind.Baf && kind != IPurgeGameTrophies.TrophyKind.Decimator) revert OnlyCoin();
        }

        uint256 tokenId = _placeholderTokenId(level, kind);
        _awardTrophyInternal(to, kind, data, deferredWei, tokenId);
    }

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        override
        onlyGame
        returns (address mapImmediateRecipient, address[6] memory affiliateRecipients)
    {
        uint24 nextLevel = req.level + 1;
        uint256 mapTokenId = _placeholderTokenId(req.level, IPurgeGameTrophies.TrophyKind.Map);
        uint256 levelTokenId = _placeholderTokenId(req.level, IPurgeGameTrophies.TrophyKind.Level);
        uint256 affiliateTokenId = _placeholderTokenId(req.level, IPurgeGameTrophies.TrophyKind.Affiliate);

        bool traitWin = req.traitId != TRAIT_ID_TIMEOUT;
        uint256 randomWord = nft.currentRngWord();

        if (traitWin) {
            uint256 traitData = (uint256(req.traitId) << 152) | (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT);
            uint256 sharedPool = req.pool / 20;
            uint256 base = sharedPool / 100;
            uint256 remainder = sharedPool - (base * 100);
            uint256 affiliateTrophyShare = base * 20 + remainder;
            uint256 stakerRewardPool = base * 10;
            uint256 deferredAward = msg.value;

            if (deferredAward < affiliateTrophyShare + stakerRewardPool) revert InvalidToken();
            deferredAward -= affiliateTrophyShare + stakerRewardPool;

            _awardTrophyInternal(req.exterminator, IPurgeGameTrophies.TrophyKind.Level, traitData, deferredAward, levelTokenId);

            affiliateRecipients = _selectAffiliateRecipients(randomWord);
            address affiliateWinner = affiliateRecipients[0];
            if (affiliateWinner == address(0)) {
                affiliateWinner = req.exterminator;
                affiliateRecipients[0] = affiliateWinner;
            }

            uint256 affiliateData =
                (uint256(0xFFFE) << 152) |
                (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT) |
                TROPHY_FLAG_AFFILIATE;
            _awardTrophyInternal(affiliateWinner, IPurgeGameTrophies.TrophyKind.Affiliate, affiliateData, affiliateTrophyShare, affiliateTokenId);

            if (stakerRewardPool != 0) {
                uint256 trophyCount = stakedTrophyIds.length;
                if (trophyCount != 0) {
                    uint256 rounds = trophyCount == 1 ? 1 : 2;
                    uint256 baseShare = stakerRewardPool / rounds;
                    uint256 rand = randomWord;
                    uint256 mask = type(uint64).max;
                    for (uint256 i; i < rounds; ) {
                        uint256 idxA = trophyCount == 1 ? 0 : (rand & mask) % trophyCount;
                        rand >>= 64;
                        uint256 idxB = trophyCount == 1 ? idxA : (rand & mask) % trophyCount;
                        rand >>= 64;
                        uint256 tokenA = stakedTrophyIds[idxA];
                        uint256 chosen = tokenA;
                        if (trophyCount != 1) {
                            uint256 tokenB = stakedTrophyIds[idxB];
                            chosen = tokenA <= tokenB ? tokenA : tokenB;
                        }
                        _addTrophyRewardInternal(chosen, baseShare, nextLevel);
                        unchecked {
                            ++i;
                        }
                    }
                }
            }
        } else {
            uint256 poolCarry = req.pool;
            uint256 mapUnit = poolCarry / 20;

            mapImmediateRecipient = address(uint160(nft.packedOwnershipOf(mapTokenId)));

            _clearTrophy(levelTokenId);

            uint256 valueIn = msg.value;
            address affiliateWinner = req.exterminator;
            uint256 affiliateShare = mapUnit;
            if (affiliateWinner != address(0) && affiliateShare != 0) {
                uint256 affiliateData =
                    (uint256(0xFFFE) << 152) |
                    (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT) |
                    TROPHY_FLAG_AFFILIATE;
                _awardTrophyInternal(affiliateWinner, IPurgeGameTrophies.TrophyKind.Affiliate, affiliateData, affiliateShare, affiliateTokenId);
                if (valueIn < affiliateShare) revert InvalidToken();
                valueIn -= affiliateShare;
            }

            for (uint8 k; k < 6; ) {
                affiliateRecipients[k] = affiliateWinner;
                unchecked {
                    ++k;
                }
            }

            _addTrophyRewardInternal(mapTokenId, mapUnit, nextLevel);
            if (valueIn < mapUnit) revert InvalidToken();
            valueIn -= mapUnit;

            uint256 stakedCount = stakedTrophyIds.length;
            uint256 distributed;
            if (mapUnit != 0 && stakedCount != 0) {
                uint256 draws = valueIn / mapUnit;
                uint256 rand = randomWord;
                uint256 mask = type(uint64).max;
                for (uint256 j; j < draws; ) {
                    uint256 idx = stakedCount == 1 ? 0 : (rand & mask) % stakedCount;
                    uint256 tokenId = stakedTrophyIds[idx];
                    _addTrophyRewardInternal(tokenId, mapUnit, nextLevel);
                    distributed += mapUnit;
                    rand >>= 64;
                    unchecked {
                        ++j;
                    }
                }
                randomWord = rand;
            }

            uint256 leftover = valueIn - distributed;
            if (leftover != 0) {
                (bool ok, ) = payable(gameAddress).call{value: leftover}("");
                if (!ok) revert InvalidToken();
            }
        }

        return (mapImmediateRecipient, affiliateRecipients);
    }

    function _addTrophyReward(uint256 tokenId, uint256 amountWei, uint24 startLevel) private {
        _addTrophyRewardInternal(tokenId, amountWei, startLevel);
    }

    function _setDecimatorBaseline(uint256 tokenId, uint24 level) private {
        _setDecimatorBaselineInternal(tokenId, level);
    }

    function _payoutDecimatorStake(uint256 tokenId, uint24 currentLevel) private returns (uint256) {
        return _payoutDecimatorStakeInternal(tokenId, currentLevel);
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

    function _kindFromInfo(uint256 info) private pure returns (IPurgeGameTrophies.TrophyKind kind) {
        if (info & TROPHY_FLAG_MAP != 0) return IPurgeGameTrophies.TrophyKind.Map;
        if (info & TROPHY_FLAG_AFFILIATE != 0) return IPurgeGameTrophies.TrophyKind.Affiliate;
        if (info & TROPHY_FLAG_STAKE != 0) return IPurgeGameTrophies.TrophyKind.Stake;
        if (info & TROPHY_FLAG_BAF != 0) return IPurgeGameTrophies.TrophyKind.Baf;
        if (info & TROPHY_FLAG_DECIMATOR != 0) return IPurgeGameTrophies.TrophyKind.Decimator;
        return IPurgeGameTrophies.TrophyKind.Level;
    }

    // ---------------------------------------------------------------------
    // Claiming
    // ---------------------------------------------------------------------

    function claimTrophy(uint256 tokenId) external override {
        address owner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (owner != msg.sender) revert Unauthorized();

        uint256 info = trophyData_[tokenId];
        if (info == 0) revert InvalidToken();

        uint24 currentLevel = game.level();
        uint24 lastClaim = uint24((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);

        uint256 owed = info & TROPHY_OWED_MASK;
        uint256 newOwed = owed;
        uint256 payout;
        bool ethClaimed;
        uint24 updatedLast = lastClaim;

        if (owed != 0 && currentLevel > lastClaim) {
            uint24 baseStartLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + 1;
            if (currentLevel >= baseStartLevel) {
                uint32 vestEnd = uint32(baseStartLevel) + COIN_DRIP_STEPS;
                uint256 denom = vestEnd > currentLevel ? vestEnd - currentLevel : 1;
                payout = owed / denom;
                newOwed = owed - payout;
                ethClaimed = true;
                updatedLast = currentLevel;
            }
        }

        uint256 coinAmount;
        bool coinClaimed;
        bool isMap = (info & TROPHY_FLAG_MAP) != 0;
        bool isDecimator = (info & TROPHY_FLAG_DECIMATOR) != 0;
        bool replaceData = true;
        if (isMap) {
            uint32 start = uint32((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
            uint32 floor = start - 1;
            uint32 last = lastClaim;
            if (last < floor) last = floor;
            if (currentLevel > last) {
                if (nft.rngLocked()) revert CoinPaused();
                uint32 from = last + 1;
                uint32 offsetStart = from - start;
                uint32 offsetEnd = currentLevel - start;

                uint256 span = uint256(offsetEnd - offsetStart + 1);
                uint256 periodSize = COIN_DRIP_STEPS;
                uint256 blocksEnd = uint256(offsetEnd) / periodSize;
                uint256 blocksStart = uint256(offsetStart) / periodSize;
                uint256 remEnd = uint256(offsetEnd) % periodSize;
                uint256 remStart = uint256(offsetStart) % periodSize;

                uint256 prefixEnd =
                    ((blocksEnd * (blocksEnd - 1)) / 2) * periodSize + blocksEnd * (remEnd + 1);
                uint256 prefixStart =
                    ((blocksStart * (blocksStart - 1)) / 2) * periodSize + blocksStart * (remStart + 1);

                coinAmount = COIN_EMISSION_UNIT * (span + (prefixEnd - prefixStart));
                coinClaimed = true;
                updatedLast = currentLevel;
            }
        } else if (isDecimator) {
            if (!_isTrophyStaked(tokenId)) revert ClaimNotReady();
            if (currentLevel > lastClaim) {
                if (nft.rngLocked()) revert CoinPaused();
                uint256 decCoin = _payoutDecimatorStake(tokenId, currentLevel);
                if (decCoin != 0) {
                    coinAmount = decCoin;
                    coinClaimed = true;
                    replaceData = false;
                }
            }
        }

        if (!ethClaimed && !coinClaimed) revert ClaimNotReady();
        if (replaceData) {
            uint256 newInfo =
                (info & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK)) |
                (newOwed & TROPHY_OWED_MASK) |
                (uint256(updatedLast & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
            _setTrophyData(tokenId, newInfo);
        }

        if (ethClaimed) {
            (bool ok, ) = msg.sender.call{value: payout}("");
            if (!ok) revert TransferFailed();
            emit TrophyRewardClaimed(tokenId, msg.sender, payout);
        }

        if (coinClaimed) {
            coin.bonusCoinflip(msg.sender, coinAmount, true, 0);
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
        uint24 currentLevel = game.level();
        uint24 effectiveLevel = _effectiveStakeLevel();
        uint8 gameState = game.gameState();

        uint256 info = trophyData_[tokenId];
        if (info == 0) revert StakeInvalid();

        bool mapTrophy = (info & TROPHY_FLAG_MAP) != 0;
        bool affiliateTrophy = (info & TROPHY_FLAG_AFFILIATE) != 0;
        bool stakeTrophyKind = (info & TROPHY_FLAG_STAKE) != 0;
        bool levelTrophy = info != 0 && !mapTrophy && !affiliateTrophy && !stakeTrophyKind;
        bool bafTrophy = (info & TROPHY_FLAG_BAF) != 0;
        bool decimatorTrophy = (info & TROPHY_FLAG_DECIMATOR) != 0;

        uint24 trophyBaseLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
        uint24 trophyLevelValue = stakeTrophyKind ? trophyBaseLevel + 1 : trophyBaseLevel;
        bool pureLevelTrophy = levelTrophy && !bafTrophy && !decimatorTrophy;
        bool targetMap = isMap;
        bool targetAffiliate = !isMap && affiliateTrophy;
        bool targetLevel = !isMap && !affiliateTrophy && levelTrophy;
        bool targetStake = !isMap && stakeTrophyKind;

        if (targetMap) {
            if (!mapTrophy) revert TrophyStakeViolation(_STAKE_ERR_NOT_MAP);
        } else if (targetAffiliate) {
            // ok
        } else if (targetLevel) {
            // ok
        } else if (targetStake) {
            if (!stakeTrophyKind) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKE);
        } else if (mapTrophy) {
            revert TrophyStakeViolation(_STAKE_ERR_NOT_MAP);
        } else if (affiliateTrophy) {
            revert TrophyStakeViolation(_STAKE_ERR_NOT_LEVEL);
        } else if (stakeTrophyKind) {
            revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKE);
        } else {
            revert TrophyStakeViolation(_STAKE_ERR_NOT_AFFILIATE);
        }

        if (stake && sender.code.length != 0) revert StakeInvalid();

        StakeParams memory params = StakeParams({
            player: sender,
            tokenId: tokenId,
            targetMap: targetMap,
            targetAffiliate: targetAffiliate,
            targetLevel: targetLevel,
            targetStake: targetStake,
            pureLevelTrophy: pureLevelTrophy,
            bafTrophy: bafTrophy,
            trophyBaseLevel: trophyBaseLevel,
            trophyLevelValue: trophyLevelValue,
            effectiveLevel: effectiveLevel
        });

        StakeExecutionResult memory outcome;
        if (stake) {
            if (currentlyStaked) revert TrophyStakeViolation(_STAKE_ERR_ALREADY_STAKED);
            coin.burnCoin(sender, 5_000 * COIN_BASE_UNIT);
            outcome.eventData = _stakeInternal(params);
            outcome.deleteApproval = true;
            if (decimatorTrophy) {
                _setDecimatorBaselineInternal(tokenId, currentLevel);
            }
        } else {
            if (gameState != 3) revert TrophyStakeViolation(_STAKE_ERR_LOCKED);
            if (!currentlyStaked) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKED);
            coin.burnCoin(sender, 25_000 * COIN_BASE_UNIT);
            outcome.eventData = _unstakeInternal(params);
            if (decimatorTrophy) {
                outcome.decimatorPayout = _payoutDecimatorStakeInternal(tokenId, currentLevel);
            }
        }

        if (stake && outcome.deleteApproval) {
            nft.clearApproval(tokenId);
        }
        if (!stake && outcome.decimatorPayout != 0) {
            coin.bonusCoinflip(sender, outcome.decimatorPayout, true, 0);
        }
        IPurgeGameTrophies.TrophyKind kind = _kindFromInfo(info);
        nft.setTrophyPackedInfo(tokenId, uint8(kind), stake);

        emit TrophyStakeChanged(
            sender,
            tokenId,
            outcome.eventData.kind,
            stake,
            outcome.eventData.count,
            outcome.eventData.discountBps
        );
    }

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata levelTokenIds,
        uint256[] calldata stakeTokenIds,
        uint256[] calldata bafTokenIds
    ) external override {
        address player = msg.sender;
        _refreshMapBonus(player, mapTokenIds);
        _refreshLevelBonus(player, levelTokenIds);
        _refreshStakeBonus(player, stakeTokenIds);
        _refreshBafBonus(player, bafTokenIds);
    }

    function affiliateStakeBonus(address player) external view override returns (uint8) {
        uint24 effective = _effectiveStakeLevel();
        return _currentAffiliateBonus(player, effective);
    }

    function stakeTrophyBonus(address player) external view override returns (uint8) {
        return stakeStakeBonusPct_[player];
    }

    function bafStakeBonusBps(address player) external view override returns (uint16) {
        return bafStakeBonusBps_[player];
    }

    function mapStakeDiscount(address player) external view override returns (uint8) {
        return mapStakeBonusPct_[player];
    }

    function levelStakeDiscount(address player) external view override returns (uint8) {
        return levelStakeBonusPct_[player];
    }

    function awardStakeTrophy(address to, uint24 level, uint256 principal)
        external
        override
        onlyCoinCaller
        returns (uint256 tokenId)
    {
        uint256 data = _stakePreviewData(level);
        uint256 placeholderId = _placeholderTokenId(level, IPurgeGameTrophies.TrophyKind.Stake);

        _awardTrophyInternal(to, IPurgeGameTrophies.TrophyKind.Stake, data, 0, placeholderId);
        emit StakeTrophyAwarded(to, placeholderId, level, principal);
        return placeholderId;
    }

    function purgeTrophy(uint256 tokenId) external override {
        if (_isTrophyStaked(tokenId)) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);
        if (trophyData_[tokenId] == 0) revert InvalidToken();

        address sender = msg.sender;
        if (address(uint160(nft.packedOwnershipOf(tokenId))) != sender) revert Unauthorized();

        nft.clearApproval(tokenId);

        bool hadData = _clearTrophy(tokenId);
        if (hadData) {
            nft.decrementTrophySupply(1);
        }

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

    function prepareNextLevel(uint24 nextLevel) external override onlyGame {
        (, uint256 currentBase) = nft.getBasePointers();
        uint256 newBase = _mintTrophyPlaceholders(nextLevel);
        nft.setBasePointers(currentBase, newBase);
    }

}
