// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

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

/**
 * @title PurgeGameTrophies (stub)
 * @notice Trophies have been removed; this contract now satisfies the interface with no-ops/defaults.
 */
contract PurgeGameTrophies is IPurgeGameTrophies {
    constructor(address nft_, address coin_) {
        nft_;
        coin_;
    }

    function wireAndPrime(address[] calldata addresses, uint24 firstLevel) external pure override {
        addresses;
        firstLevel;
    }

    function clearStakePreview(uint24 level) external pure override {
        level;
    }

    function prepareNextLevel(uint24 nextLevel) external pure override {
        nextLevel;
    }

    function awardTrophy(address to, uint24 level, uint8 kind, uint256 data, uint256 deferredWei) external pure override {
        to;
        level;
        kind;
        data;
        deferredWei;
    }

    function burnBafPlaceholder(uint24 level) external pure override {
        level;
    }

    function burnDecPlaceholder(uint24 level) external pure override {
        level;
    }

    function claimTrophy(uint256 tokenId) external pure override {
        tokenId;
    }

    function setTrophyStake(uint256 tokenId, bool stake) external pure override {
        tokenId;
        stake;
    }

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata exterminatorTokenIds,
        uint256[] calldata stakeTokenIds,
        uint256[] calldata affiliateTokenIds
    ) external pure override {
        mapTokenIds;
        exterminatorTokenIds;
        stakeTokenIds;
        affiliateTokenIds;
    }

    function affiliateStakeBonus(address player) external pure override returns (uint8) {
        player;
        return 0;
    }

    function stakeTrophyBonus(address player) external pure override returns (uint8) {
        player;
        return 0;
    }

    function decStakeBonus(address player) external pure override returns (uint8) {
        player;
        return 0;
    }

    function mapStakeDiscount(address player) external pure override returns (uint8) {
        player;
        return 0;
    }

    function exterminatorStakeDiscount(address player) external pure override returns (uint8) {
        player;
        return 0;
    }

    function hasExterminatorStake(address player) external pure override returns (bool) {
        player;
        return false;
    }

    function purgeTrophy(uint256 tokenId) external pure override {
        tokenId;
    }

    function stakedTrophySampleWithId(uint256 rngSeed) external pure override returns (uint256 tokenId, address owner) {
        rngSeed;
        return (0, address(0));
    }

    function trophyToken(uint24 level, uint8 kind) external pure override returns (uint256 tokenId) {
        level;
        kind;
        return 0;
    }

    function trophyOwner(uint256 tokenId) external pure override returns (address owner) {
        tokenId;
        return address(0);
    }

    function rewardTrophyByToken(uint256 tokenId, uint256 amountWei, uint24 level) external pure override {
        tokenId;
        amountWei;
        level;
    }

    function rewardTrophy(uint24 level, uint8 kind, uint256 amountWei) external pure override returns (bool paid) {
        level;
        kind;
        amountWei;
        return false;
    }

    function rewardRandomStaked(uint256 rngSeed, uint256 amountWei, uint24 level) external pure override returns (bool paid) {
        rngSeed;
        amountWei;
        level;
        return false;
    }

    function processEndLevel(EndLevelRequest calldata req, uint256 scaledPool) external pure override returns (uint256 paidTotal) {
        req;
        scaledPool;
        return 0;
    }

    function isTrophy(uint256 tokenId) external pure override returns (bool) {
        tokenId;
        return false;
    }

    function trophyData(uint256 tokenId) external pure override returns (uint256 rawData) {
        tokenId;
        return 0;
    }

    function isTrophyStaked(uint256 tokenId) external pure override returns (bool) {
        tokenId;
        return false;
    }

    function handleExterminatorTraitPurge(address player, uint16 traitId) external pure override returns (uint8 newPercent) {
        player;
        traitId;
        return 0;
    }
}
