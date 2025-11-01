// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeGameNFTView {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPurgeTrophyStaking {
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

    function stake(StakeParams calldata params) external returns (StakeEventData memory);

    function unstake(StakeParams calldata params) external returns (StakeEventData memory);

    function isStaked(uint256 tokenId) external view returns (bool);

    function stakedCount() external view returns (uint256);

    function stakedTokenAt(uint256 index) external view returns (uint256);

    function mapStakeDiscount(address player) external view returns (uint8);

    function levelStakeDiscount(address player) external view returns (uint8);

    function stakeTrophyBonus(address player) external view returns (uint8);

    function affiliateStakeBonus(address player, uint24 effectiveLevel) external view returns (uint8);

    function bafStakeBonusBps(address player) external view returns (uint16);

    function mapStakeCount(address player) external view returns (uint8);

    function levelStakeCount(address player) external view returns (uint8);

    function stakeStakeCount(address player) external view returns (uint8);

    function bafStakeCount(address player) external view returns (uint8);

    function affiliateStakeCount(address player) external view returns (uint8);

    function affiliateStakeBaseLevel(address player) external view returns (uint24);

    function updateMapBonus(address player, uint8 bonus) external;

    function updateLevelBonus(address player, uint8 bonus) external;

    function updateStakeBonus(address player, uint8 bonus) external;

    function updateBafBonus(address player, uint16 bonus) external;

    function refreshStakeBonuses(address player, uint8 kind, uint256[] calldata tokenIds) external;

    function getTrophyData(uint256 tokenId) external view returns (uint256);

    function hasTrophy(uint256 tokenId) external view returns (bool);

    function setTrophyData(uint256 tokenId, uint256 data) external;

    function clearTrophy(uint256 tokenId) external returns (bool);

    function setGame(address game_) external;

    function awardTrophy(address to, uint256 tokenId, uint256 data, uint256 deferredWei) external returns (bool);

    function addTrophyReward(uint256 tokenId, uint256 amountWei, uint24 startLevel) external;

    function setDecimatorBaseline(uint256 tokenId, uint24 level) external;

    function payoutDecimatorStake(uint256 tokenId, uint24 currentLevel) external returns (uint256);

    function executeStake(StakeExecutionRequest calldata req) external returns (StakeExecutionResult memory);
}

contract PurgeTrophyStaking is IPurgeTrophyStaking {
    error OnlyNFT();
    error StakeInvalid();
    error AlreadyStaked();
    error NotStaked();
    error TrophyStakeViolation(uint8 reason);

    address public immutable nft;

    uint256[] private stakedTrophyIds;
    mapping(uint256 => uint256) private stakedTrophyIndex; // 1-based index
    mapping(uint256 => bool) private trophyStaked;
    mapping(uint256 => uint256) private trophyData_;
    address private game;

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
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;
    uint256 private constant TROPHY_LAST_CLAIM_MASK = uint256(0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT;
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_FLAG_AFFILIATE = uint256(1) << 201;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;

    uint8 private constant MAP_STAKE_MAX = 20;
    uint8 private constant LEVEL_STAKE_MAX = 20;
    uint8 private constant AFFILIATE_STAKE_MAX = 20;
    uint8 private constant STAKE_TROPHY_MAX = 20;
    uint8 private constant BONUS_MAP = 0;
    uint8 private constant BONUS_LEVEL = 1;
    uint8 private constant BONUS_STAKE = 2;
    uint8 private constant BONUS_BAF = 3;

    constructor(address nft_) {
        if (nft_ == address(0)) revert OnlyNFT();
        nft = nft_;
    }

    modifier onlyNFT() {
        if (msg.sender != nft) revert OnlyNFT();
        _;
    }

    function getTrophyData(uint256 tokenId) external view returns (uint256) {
        return trophyData_[tokenId];
    }

    function hasTrophy(uint256 tokenId) external view returns (bool) {
        return trophyData_[tokenId] != 0;
    }

    function setTrophyData(uint256 tokenId, uint256 data) external onlyNFT {
        trophyData_[tokenId] = data;
    }

    function clearTrophy(uint256 tokenId) external onlyNFT returns (bool hadData) {
        if (trophyStaked[tokenId]) revert StakeInvalid();
        hadData = trophyData_[tokenId] != 0;
        delete trophyData_[tokenId];
    }

    function setGame(address game_) external onlyNFT {
        game = game_;
    }

    function awardTrophy(address to, uint256 tokenId, uint256 data, uint256 deferredWei) external onlyNFT returns (bool incrementSupply) {
        uint256 prevData = trophyData_[tokenId];
        uint256 newData = (data & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK)) | (deferredWei & TROPHY_OWED_MASK);
        trophyData_[tokenId] = newData;
        if (prevData == 0 && newData != 0 && to != game) {
            incrementSupply = true;
        }
    }

    function addTrophyReward(uint256 tokenId, uint256 amountWei, uint24 startLevel) external onlyNFT {
        uint256 info = trophyData_[tokenId];
        uint256 owed = (info & TROPHY_OWED_MASK) + amountWei;
        uint256 base = uint256((startLevel - 1) & 0xFFFFFF);
        uint256 updated = (info & ~(TROPHY_OWED_MASK | (uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT)))
            | (owed & TROPHY_OWED_MASK)
            | (base << TROPHY_BASE_LEVEL_SHIFT);
        trophyData_[tokenId] = updated;
    }

    function setDecimatorBaseline(uint256 tokenId, uint24 level) external onlyNFT {
        _setDecimatorBaselineInternal(tokenId, level);
    }

    function payoutDecimatorStake(uint256 tokenId, uint24 currentLevel) external onlyNFT returns (uint256) {
        return _payoutDecimatorStakeInternal(tokenId, currentLevel);
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

    function stake(StakeParams calldata params) external onlyNFT returns (StakeEventData memory data) {
        data = _stakeInternal(params);
    }

    function unstake(StakeParams calldata params) external onlyNFT returns (StakeEventData memory data) {
        data = _unstakeInternal(params);
    }

    function executeStake(StakeExecutionRequest calldata req)
        external
        onlyNFT
        returns (StakeExecutionResult memory result)
    {
        uint256 info = trophyData_[req.tokenId];
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
        bool targetMap = req.isMap;
        bool targetAffiliate = !req.isMap && affiliateTrophy;
        bool targetLevel = !req.isMap && !affiliateTrophy && levelTrophy;
        bool targetStake = !req.isMap && stakeTrophyKind;

        if (targetMap) {
            if (!mapTrophy) revert TrophyStakeViolation(6);
        } else if (targetAffiliate) {
            // ok
        } else if (targetLevel) {
            // ok
        } else if (targetStake) {
            if (!stakeTrophyKind) revert TrophyStakeViolation(8);
        } else if (mapTrophy) {
            revert TrophyStakeViolation(6);
        } else if (affiliateTrophy) {
            revert TrophyStakeViolation(2);
        } else if (stakeTrophyKind) {
            revert TrophyStakeViolation(8);
        } else {
            revert TrophyStakeViolation(7);
        }

        StakeParams memory params = StakeParams({
            player: req.player,
            tokenId: req.tokenId,
            targetMap: targetMap,
            targetAffiliate: targetAffiliate,
            targetLevel: targetLevel,
            targetStake: targetStake,
            pureLevelTrophy: pureLevelTrophy,
            bafTrophy: bafTrophy,
            trophyBaseLevel: trophyBaseLevel,
            trophyLevelValue: trophyLevelValue,
            effectiveLevel: req.effectiveLevel
        });

        if (req.stake) {
            if (req.currentlyStaked) revert TrophyStakeViolation(3);
            result.eventData = _stakeInternal(params);
            result.deleteApproval = true;
            if (decimatorTrophy) {
                _setDecimatorBaselineInternal(req.tokenId, req.currentLevel);
            }
        } else {
            if (req.gameState != 3) revert TrophyStakeViolation(5);
            if (!req.currentlyStaked) revert TrophyStakeViolation(4);
            result.eventData = _unstakeInternal(params);
            if (decimatorTrophy) {
                result.decimatorPayout = _payoutDecimatorStakeInternal(req.tokenId, req.currentLevel);
            }
        }
    }

    function refreshStakeBonuses(address player, uint8 kind, uint256[] calldata tokenIds) external onlyNFT {
        if (kind == BONUS_MAP) {
            _refreshMapBonus(player, tokenIds);
            return;
        }
        if (kind == BONUS_LEVEL) {
            _refreshLevelBonus(player, tokenIds);
            return;
        }
        if (kind == BONUS_STAKE) {
            _refreshStakeBonus(player, tokenIds);
            return;
        }
        if (kind == BONUS_BAF) {
            _refreshBafBonus(player, tokenIds);
            return;
        }
        revert StakeInvalid();
    }

    function isStaked(uint256 tokenId) external view returns (bool) {
        return trophyStaked[tokenId];
    }

    function stakedCount() external view returns (uint256) {
        return stakedTrophyIds.length;
    }

    function stakedTokenAt(uint256 index) external view returns (uint256) {
        if (index >= stakedTrophyIds.length) revert StakeInvalid();
        return stakedTrophyIds[index];
    }

    function mapStakeDiscount(address player) external view returns (uint8) {
        return mapStakeBonusPct_[player];
    }

    function levelStakeDiscount(address player) external view returns (uint8) {
        return levelStakeBonusPct_[player];
    }

    function stakeTrophyBonus(address player) external view returns (uint8) {
        return stakeStakeBonusPct_[player];
    }

    function affiliateStakeBonus(address player, uint24 effectiveLevel) external view returns (uint8) {
        return _currentAffiliateBonus(player, effectiveLevel);
    }

    function bafStakeBonusBps(address player) external view returns (uint16) {
        return bafStakeBonusBps_[player];
    }

    function mapStakeCount(address player) external view returns (uint8) {
        return mapStakeCount_[player];
    }

    function levelStakeCount(address player) external view returns (uint8) {
        return levelStakeCount_[player];
    }

    function stakeStakeCount(address player) external view returns (uint8) {
        return stakeStakeCount_[player];
    }

    function bafStakeCount(address player) external view returns (uint8) {
        return bafStakeCount_[player];
    }

    function affiliateStakeCount(address player) external view returns (uint8) {
        return affiliateStakeCount_[player];
    }

    function affiliateStakeBaseLevel(address player) external view returns (uint24) {
        return affiliateStakeBaseLevel_[player];
    }

    function _stakeInternal(StakeParams memory params) private returns (StakeEventData memory data) {
        if (trophyData_[params.tokenId] == 0) revert StakeInvalid();
        if (trophyStaked[params.tokenId]) revert AlreadyStaked();
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
        if (!trophyStaked[params.tokenId]) revert NotStaked();
        trophyStaked[params.tokenId] = false;
        _removeStakedTrophy(params.tokenId);

        uint8 discountPct;

        if (params.targetMap) {
            uint8 current = mapStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            mapStakeCount_[params.player] = current;
            mapStakeBonusPct_[params.player] = 0;
            data.kind = 1;
            data.count = current;
            discountPct = 0;
        } else if (params.targetAffiliate) {
            uint8 current = affiliateStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            affiliateStakeCount_[params.player] = current;
            affiliateStakeBaseLevel_[params.player] = params.effectiveLevel;
            discountPct = _currentAffiliateBonus(params.player, params.effectiveLevel);
            data.kind = 2;
            data.count = current;
        } else if (params.targetLevel) {
            uint8 current = levelStakeCount_[params.player];
            if (params.pureLevelTrophy) {
                if (current == 0) revert StakeInvalid();
                unchecked {
                    current -= 1;
                }
                levelStakeCount_[params.player] = current;
                levelStakeBonusPct_[params.player] = 0;
                discountPct = 0;
            } else {
                discountPct = levelStakeBonusPct_[params.player];
            }
            data.kind = 3;
            data.count = levelStakeCount_[params.player];
        } else {
            uint8 current = stakeStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            stakeStakeCount_[params.player] = current;
            stakeStakeBonusPct_[params.player] = 0;
            discountPct = 0;
            data.kind = 4;
            data.count = current;
        }

        if (params.bafTrophy) {
            uint8 current = bafStakeCount_[params.player];
            if (current == 0) revert StakeInvalid();
            unchecked {
                current -= 1;
            }
            bafStakeCount_[params.player] = current;
            bafStakeBonusBps_[params.player] = 0;
        }

        data.discountBps = uint16(discountPct) * 100;
        return data;
    }

    function updateMapBonus(address player, uint8 bonus) external onlyNFT {
        uint8 count = mapStakeCount_[player];
        if (count == 0) {
            if (bonus != 0) revert StakeInvalid();
        } else {
            uint8 cap = _mapDiscountCap(count);
            if (bonus > cap) revert StakeInvalid();
        }
        mapStakeBonusPct_[player] = bonus;
    }

    function updateLevelBonus(address player, uint8 bonus) external onlyNFT {
        uint8 count = levelStakeCount_[player];
        if (count == 0) {
            if (bonus != 0) revert StakeInvalid();
        } else {
            uint8 cap = _levelDiscountCap(count);
            if (bonus > cap) revert StakeInvalid();
        }
        levelStakeBonusPct_[player] = bonus;
    }

    function updateStakeBonus(address player, uint8 bonus) external onlyNFT {
        uint8 count = stakeStakeCount_[player];
        if (count == 0) {
            if (bonus != 0) revert StakeInvalid();
        } else {
            uint8 cap = _stakeBonusCap(count);
            if (bonus > cap) revert StakeInvalid();
        }
        stakeStakeBonusPct_[player] = bonus;
    }

    function updateBafBonus(address player, uint16 bonus) external onlyNFT {
        uint8 count = bafStakeCount_[player];
        if (count == 0) {
            if (bonus != 0) revert StakeInvalid();
        } else {
            uint16 cap = _bafBonusFromLevel(255);
            if (bonus > cap) revert StakeInvalid();
        }
        bafStakeBonusBps_[player] = bonus;
    }

    function _addStakedTrophy(uint256 tokenId) private {
        if (stakedTrophyIndex[tokenId] != 0) return;
        stakedTrophyIds.push(tokenId);
        stakedTrophyIndex[tokenId] = stakedTrophyIds.length;
    }

    function _removeStakedTrophy(uint256 tokenId) private {
        uint256 indexPlus = stakedTrophyIndex[tokenId];
        if (indexPlus == 0) return;
        uint256 idx = indexPlus - 1;
        uint256 lastIdx = stakedTrophyIds.length - 1;
        if (idx != lastIdx) {
            uint256 lastToken = stakedTrophyIds[lastIdx];
            stakedTrophyIds[idx] = lastToken;
            stakedTrophyIndex[lastToken] = idx + 1;
        }
        stakedTrophyIds.pop();
        delete stakedTrophyIndex[tokenId];
    }

    function _mapDiscountCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 10;
        if (count == 2) return 16;
        return 20;
    }

    function _levelDiscountCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 10;
        if (count == 2) return 16;
        return 20;
    }

    function _stakeBonusCap(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count == 1) return 7;
        if (count == 2) return 12;
        return 15;
    }

    function _bafBonusFromLevel(uint24 level) private pure returns (uint16) {
        uint256 bonus = uint256(level) * 10;
        if (bonus > 220) bonus = 220;
        return uint16(bonus);
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

    function _ensurePlayerOwnsStaked(address player, uint256 tokenId) private view {
        if (!trophyStaked[tokenId]) revert StakeInvalid();
        if (IPurgeGameNFTView(nft).ownerOf(tokenId) != player) revert StakeInvalid();
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
}
