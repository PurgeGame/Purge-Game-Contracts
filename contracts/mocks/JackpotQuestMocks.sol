// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../modules/PurgeGameModuleInterfaces.sol";

contract JackpotCoinModuleMock is IPurgeCoinModule {
    uint48 public lastRollDay;
    uint256 public lastRollEntropy;
    uint256 public rollCount;
    bool public lastRollForceMint;
    bool public lastRollForcePurge;

    function jackpots() external pure override returns (address) {
        return address(0);
    }

    function affiliateProgram() external pure override returns (address) {
        return address(0);
    }

    function processCoinflipPayouts(
        uint24,
        uint32,
        bool,
        uint256,
        uint48,
        uint256
    ) external pure override returns (bool) {
        return false;
    }

    function bonusCoinflip(address, uint256) external pure override {}

    function addToBounty(uint256) external pure override {}

    function rewardTopFlipBonus(uint256) external pure override {}

    function resetCoinflipLeaderboard() external pure override {}

    function burnie(uint256, address) external payable override {}

    function rollDailyQuest(uint48 day, uint256 entropy) external override {
        lastRollDay = day;
        lastRollEntropy = entropy;
        lastRollForceMint = false;
        lastRollForcePurge = false;
        unchecked {
            ++rollCount;
        }
    }

    function rollDailyQuestWithOverrides(uint48 day, uint256 entropy, bool forceMintEth, bool forcePurge) external override {
        lastRollDay = day;
        lastRollEntropy = entropy;
        lastRollForceMint = forceMintEth;
        lastRollForcePurge = forcePurge;
        unchecked {
            ++rollCount;
        }
    }
}

contract JackpotTrophiesModuleMock is IPurgeGameTrophiesModule {
    function awardTrophy(
        address,
        uint24,
        uint8,
        uint256,
        uint256
    ) external override {}

    function stakedTrophySampleWithId(uint256) external pure returns (uint256 tokenId, address owner) {
        return (0, address(0));
    }

    function trophyToken(uint24, uint8) external pure override returns (uint256 tokenId) { return 0; }

    function trophyOwner(uint256) external pure override returns (address owner) {
        return address(0);
    }

    function rewardTrophyByToken(uint256, uint256, uint24) external override {}

    function burnBafPlaceholder(uint24) external pure override {}

    function burnDecPlaceholder(uint24) external pure override {}

    function rewardRandomStaked(uint256, uint256, uint24) external pure override returns (bool) { return false; }
    function rewardTrophy(uint24, uint8, uint256) external pure override returns (bool) { return false; }
    function processEndLevel(IPurgeGameTrophies.EndLevelRequest calldata, uint256) external pure override returns (uint256) { return 0; }
}
