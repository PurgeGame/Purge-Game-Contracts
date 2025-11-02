// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameNftModule} from "./interfaces/IPurgeGameNftModule.sol";
import {IPurgeGameTrophies} from "./interfaces/IPurgeGameTrophies.sol";
import {IPurgeTrophyStaking} from "./PurgeTrophyStaking.sol";

interface IPurgeGameMinimal {
    function level() external view returns (uint24);
    function gameState() external view returns (uint8);
}

interface IPurgecoinMinimal {
    function bonusCoinflip(address player, uint256 amount, bool rngReady, uint256 luckboxBonus) external;

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
    IPurgeTrophyStaking private trophyStaking;

    address public gameAddress;
    address public coinAddress;

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

    function wireStaking(address staking_) external override {
        if (coinAddress == address(0)) revert AlreadyWired();
        if (msg.sender != coinAddress) revert OnlyCoin();
        if (staking_ == address(0)) revert ZeroAddress();
        trophyStaking = IPurgeTrophyStaking(staking_);
    }

    modifier onlyGame() {
        if (msg.sender != gameAddress) revert Unauthorized();
        _;
    }

    modifier onlyCoinCaller() {
        if (msg.sender != coinAddress) revert OnlyCoin();
        _;
    }

    modifier ensureStaking() {
        if (address(trophyStaking) == address(0)) revert StakeInvalid();
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

    function _mintTrophyPlaceholders(uint24 level) private ensureStaking returns (uint256 newBaseTokenId) {
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
                trophyStaking.setTrophyData(specialTokenId, baseData | TROPHY_FLAG_BAF);
                nft.setTrophyPackedInfo(specialTokenId, uint8(IPurgeGameTrophies.TrophyKind.Baf), false);
            } else {
                trophyStaking.setTrophyData(specialTokenId, baseData | TROPHY_FLAG_DECIMATOR);
                nft.setTrophyPackedInfo(specialTokenId, uint8(IPurgeGameTrophies.TrophyKind.Decimator), false);
            }
        }

        uint256 stakeTokenId = nextId++;
        if (level >= STAKE_PREVIEW_START_LEVEL) {
            trophyStaking.setTrophyData(stakeTokenId, _stakePreviewData(level));
        } else {
            trophyStaking.clearTrophy(stakeTokenId);
        }
        nft.setTrophyPackedInfo(stakeTokenId, uint8(IPurgeGameTrophies.TrophyKind.Stake), false);

        uint256 affiliateTokenId = nextId++;
        trophyStaking.setTrophyData(affiliateTokenId, baseData | TROPHY_FLAG_AFFILIATE);
        nft.setTrophyPackedInfo(affiliateTokenId, uint8(IPurgeGameTrophies.TrophyKind.Affiliate), false);

        uint256 mapTokenId = nextId++;
        trophyStaking.setTrophyData(mapTokenId, baseData | TROPHY_FLAG_MAP);
        nft.setTrophyPackedInfo(mapTokenId, uint8(IPurgeGameTrophies.TrophyKind.Map), false);

        uint256 levelTokenId = nextId++;
        trophyStaking.setTrophyData(levelTokenId, baseData);
        nft.setTrophyPackedInfo(levelTokenId, uint8(IPurgeGameTrophies.TrophyKind.Level), false);

        newBaseTokenId = startId + mintedCount;
    }

    // ---------------------------------------------------------------------
    // Trophy placeholder lifecycle
    // ---------------------------------------------------------------------

    function clearStakePreview(uint24 level) external override onlyCoinCaller ensureStaking {
        uint256 tokenId = _placeholderTokenId(level, IPurgeGameTrophies.TrophyKind.Stake);
        if (!trophyStaking.hasTrophy(tokenId)) return;
        address owner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (owner != gameAddress) return;
        trophyStaking.clearTrophy(tokenId);
    }

    function _awardTrophyInternal(
        address to,
        IPurgeGameTrophies.TrophyKind kind,
        uint256 data,
        uint256 deferredWei,
        uint256 tokenId
    ) private ensureStaking {
        address currentOwner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (currentOwner != to) {
            nft.transferTrophy(currentOwner, to, tokenId);
            if (currentOwner == gameAddress) {
                nft.incrementTrophySupply(1);
            }
        }

        bool incSupply = trophyStaking.awardTrophy(to, tokenId, data, deferredWei);
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

            if (stakerRewardPool != 0 && address(trophyStaking) != address(0)) {
                uint256 trophyCount = trophyStaking.stakedCount();
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
                        uint256 tokenA = trophyStaking.stakedTokenAt(idxA);
                        uint256 chosen = tokenA;
                        if (trophyCount != 1) {
                            uint256 tokenB = trophyStaking.stakedTokenAt(idxB);
                            chosen = tokenA <= tokenB ? tokenA : tokenB;
                        }
                        _addTrophyReward(chosen, baseShare, nextLevel);
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

            trophyStaking.clearTrophy(levelTokenId);

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

            _addTrophyReward(mapTokenId, mapUnit, nextLevel);
            if (valueIn < mapUnit) revert InvalidToken();
            valueIn -= mapUnit;

            uint256 stakedCount = address(trophyStaking) == address(0) ? 0 : trophyStaking.stakedCount();
            uint256 distributed;
            if (mapUnit != 0 && stakedCount != 0) {
                uint256 draws = valueIn / mapUnit;
                uint256 rand = randomWord;
                uint256 mask = type(uint64).max;
                for (uint256 j; j < draws; ) {
                    uint256 idx = stakedCount == 1 ? 0 : (rand & mask) % stakedCount;
                    uint256 tokenId = trophyStaking.stakedTokenAt(idx);
                    _addTrophyReward(tokenId, mapUnit, nextLevel);
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
        trophyStaking.addTrophyReward(tokenId, amountWei, startLevel);
    }

    function _setDecimatorBaseline(uint256 tokenId, uint24 level) private {
        trophyStaking.setDecimatorBaseline(tokenId, level);
    }

    function _payoutDecimatorStake(uint256 tokenId, uint24 currentLevel) private returns (uint256) {
        return trophyStaking.payoutDecimatorStake(tokenId, currentLevel);
    }

    function _isTrophyStaked(uint256 tokenId) private view returns (bool) {
        if (address(trophyStaking) == address(0)) return false;
        return trophyStaking.isStaked(tokenId);
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

    function claimTrophy(uint256 tokenId) external override ensureStaking {
        address owner = address(uint160(nft.packedOwnershipOf(tokenId)));
        if (owner != msg.sender) revert Unauthorized();

        uint256 info = trophyStaking.getTrophyData(tokenId);
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
            trophyStaking.setTrophyData(tokenId, newInfo);
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

    function setTrophyStake(uint256 tokenId, bool isMap, bool stake) external override ensureStaking {
        if (nft.rngLocked()) revert CoinPaused();

        address sender = msg.sender;
        if (address(uint160(nft.packedOwnershipOf(tokenId))) != sender) revert Unauthorized();

        bool currentlyStaked = _isTrophyStaked(tokenId);
        IPurgeTrophyStaking.StakeExecutionRequest memory params = IPurgeTrophyStaking.StakeExecutionRequest({
            player: sender,
            tokenId: tokenId,
            isMap: isMap,
            stake: stake,
            currentlyStaked: currentlyStaked,
            currentLevel: game.level(),
            effectiveLevel: _effectiveStakeLevel(),
            gameState: game.gameState()
        });

        IPurgeTrophyStaking.StakeExecutionResult memory outcome = trophyStaking.executeStake(params);
        if (stake && outcome.deleteApproval) {
            nft.clearApproval(tokenId);
        }
        if (!stake && outcome.decimatorPayout != 0) {
            coin.bonusCoinflip(sender, outcome.decimatorPayout, true, 0);
        }

        uint256 info = trophyStaking.getTrophyData(tokenId);
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
    ) external override ensureStaking {
        address player = msg.sender;
        trophyStaking.refreshStakeBonuses(player, _BONUS_MAP, mapTokenIds);
        trophyStaking.refreshStakeBonuses(player, _BONUS_LEVEL, levelTokenIds);
        trophyStaking.refreshStakeBonuses(player, _BONUS_STAKE, stakeTokenIds);
        trophyStaking.refreshStakeBonuses(player, _BONUS_BAF, bafTokenIds);
    }

    function affiliateStakeBonus(address player) external view override returns (uint8) {
        if (address(trophyStaking) == address(0)) return 0;
        uint24 effective = _effectiveStakeLevel();
        return trophyStaking.affiliateStakeBonus(player, effective);
    }

    function stakeTrophyBonus(address player) external view override returns (uint8) {
        if (address(trophyStaking) == address(0)) return 0;
        return trophyStaking.stakeTrophyBonus(player);
    }

    function bafStakeBonusBps(address player) external view override returns (uint16) {
        if (address(trophyStaking) == address(0)) return 0;
        return trophyStaking.bafStakeBonusBps(player);
    }

    function mapStakeDiscount(address player) external view override returns (uint8) {
        if (address(trophyStaking) == address(0)) return 0;
        return trophyStaking.mapStakeDiscount(player);
    }

    function levelStakeDiscount(address player) external view override returns (uint8) {
        if (address(trophyStaking) == address(0)) return 0;
        return trophyStaking.levelStakeDiscount(player);
    }

    function awardStakeTrophy(address to, uint24 level, uint256 principal)
        external
        override
        onlyCoinCaller
        ensureStaking
        returns (uint256 tokenId)
    {
        uint256 data = _stakePreviewData(level);
        uint256 placeholderId = _placeholderTokenId(level, IPurgeGameTrophies.TrophyKind.Stake);

        _awardTrophyInternal(to, IPurgeGameTrophies.TrophyKind.Stake, data, 0, placeholderId);
        emit StakeTrophyAwarded(to, placeholderId, level, principal);
        return placeholderId;
    }

    function purgeTrophy(uint256 tokenId) external override ensureStaking {
        if (_isTrophyStaked(tokenId)) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);
        if (!trophyStaking.hasTrophy(tokenId)) revert InvalidToken();

        address sender = msg.sender;
        if (address(uint160(nft.packedOwnershipOf(tokenId))) != sender) revert Unauthorized();

        nft.clearApproval(tokenId);

        bool hadData = trophyStaking.clearTrophy(tokenId);
        if (hadData) {
            nft.decrementTrophySupply(1);
        }

        coin.bonusCoinflip(sender, 100_000 * COIN_BASE_UNIT, false, 0);
    }

    function stakedTrophySample(uint64 salt) external view override returns (address owner) {
        if (address(trophyStaking) == address(0)) return address(0);
        uint256 count = trophyStaking.stakedCount();
        if (count == 0) return address(0);
        uint256 mask = type(uint64).max;
        uint256 rand = uint256(keccak256(abi.encodePacked(salt, count, block.prevrandao)));
        uint256 idxA = count == 1 ? 0 : (rand & mask) % count;
        uint256 idxB = count == 1 ? idxA : (rand >> 64) % count;
        uint256 tokenA = trophyStaking.stakedTokenAt(idxA);
        uint256 tokenB = trophyStaking.stakedTokenAt(idxB);
        uint256 chosen = tokenA <= tokenB ? tokenA : tokenB;
        owner = address(uint160(nft.packedOwnershipOf(chosen)));
    }

    function hasTrophy(uint256 tokenId) external view override returns (bool) {
        if (address(trophyStaking) == address(0)) return false;
        return trophyStaking.hasTrophy(tokenId);
    }

    function trophyData(uint256 tokenId) external view override returns (uint256 rawData) {
        if (address(trophyStaking) == address(0)) return 0;
        return trophyStaking.getTrophyData(tokenId);
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
