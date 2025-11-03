// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeCoinModule {
    function bonusCoinflip(address player, uint256 amount, bool rngReady, uint256 luckboxBonus) external;
    function burnie(uint256 amount) external payable;
    function burnCoin(address target, uint256 amount) external;
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external;
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord
    ) external returns (bool);
    function prepareCoinJackpot() external returns (uint256 poolAmount, address biggestFlip);
    function addToBounty(uint256 amount) external;
    function lastBiggestFlip() external view returns (address);
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    ) external returns (bool finished, address[] memory winners, uint256[] memory amounts, uint256 returnAmountWei);
    function resetAffiliateLeaderboard(uint24 lvl) external;
    function resetCoinflipLeaderboard() external;
    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory);
    function playerLuckbox(address player) external view returns (uint256);
}

interface IPurgeGameNFTModule {
    function rngLocked() external view returns (bool);
    function releaseRngLock() external;
    function currentRngWord() external view returns (uint256);
}

interface IPurgeGameTrophiesModule {
    struct EndLevelRequest {
        address exterminator;
        uint16 traitId;
        uint24 level;
        uint256 pool;
    }

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        returns (address mapImmediateRecipient, address[6] memory affiliateRecipients);

    function awardTrophy(address to, uint24 level, uint8 kind, uint256 data, uint256 deferredWei) external payable;
}
