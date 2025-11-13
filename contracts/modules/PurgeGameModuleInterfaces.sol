// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";

interface IPurgeCoinModule {
    function coinflipWorkPending(uint24 level) external view returns (bool);

    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch
    ) external returns (bool);

    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl,
        uint256 rngWord
    )
        external
        returns (bool finished, address[] memory winners, uint256[] memory amounts, uint256 returnAmountWei);

    function prepareCoinJackpot() external returns (uint256 poolAmount, address biggestFlip);

    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory);

    function bonusCoinflip(address player, uint256 amount, bool rngReady) external;

    function addToBounty(uint256 amount) external;

    function resetCoinflipLeaderboard() external;

    function resetAffiliateLeaderboard(uint24 lvl) external;

    function burnie(uint256 amount) external payable;

    function primeMintEthQuest(uint48 day) external;

    function rollDailyQuest(uint48 day, uint256 entropy) external;
}

interface IPurgeGameTrophiesModule {
    function processEndLevel(
        IPurgeGameTrophies.EndLevelRequest calldata req
    ) external payable returns (address mapImmediateRecipient, address[6] memory affiliateRecipients);

    function awardTrophy(address to, uint24 level, uint8 kind, uint256 data, uint256 deferredWei) external payable;

    function stakedTrophySample(uint64 salt) external view returns (address owner);

    function burnBafPlaceholder(uint24 level) external;

    function burnDecPlaceholder(uint24 level) external;
}
