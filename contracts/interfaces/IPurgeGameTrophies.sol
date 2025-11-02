// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeGameTrophies {
    enum TrophyKind {
        Map,
        Level,
        Affiliate,
        Stake,
        Baf,
        Decimator
    }

    struct EndLevelRequest {
        address exterminator;
        uint16 traitId;
        uint24 level;
        uint256 pool;
    }

    function wire(address game_, address coin_) external;

    function wireStaking(address staking_) external;

    function clearStakePreview(uint24 level) external;

    function prepareNextLevel(uint24 nextLevel) external;

    function awardTrophy(
        address to,
        uint24 level,
        TrophyKind kind,
        uint256 data,
        uint256 deferredWei
    ) external payable;

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        returns (address mapImmediateRecipient, address[6] memory affiliateRecipients);

    function claimTrophy(uint256 tokenId) external;

    function setTrophyStake(uint256 tokenId, bool isMap, bool stake) external;

    function refreshStakeBonuses(
        uint256[] calldata mapTokenIds,
        uint256[] calldata levelTokenIds,
        uint256[] calldata stakeTokenIds,
        uint256[] calldata bafTokenIds
    ) external;

    function affiliateStakeBonus(address player) external view returns (uint8);

    function stakeTrophyBonus(address player) external view returns (uint8);

    function bafStakeBonusBps(address player) external view returns (uint16);

    function mapStakeDiscount(address player) external view returns (uint8);

    function levelStakeDiscount(address player) external view returns (uint8);

    function awardStakeTrophy(address to, uint24 level, uint256 principal) external returns (uint256 tokenId);

    function purgeTrophy(uint256 tokenId) external;

    function stakedTrophySample(uint64 salt) external view returns (address owner);

    function hasTrophy(uint256 tokenId) external view returns (bool);

    function trophyData(uint256 tokenId) external view returns (uint256 rawData);
}
