// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../modules/PurgeGameModuleInterfaces.sol";

contract JackpotCoinModuleMock is IPurgeCoinModule {
    address[] private leaderboard;

    uint48 public lastRollDay;
    uint256 public lastRollEntropy;
    uint256 public rollCount;
    bool public lastRollForceMint;
    bool public lastRollForcePurge;
    uint48 public lastPrimeDay;

    function setLeaderboard(address[] calldata addrs) external {
        leaderboard = addrs;
    }

    function coinflipWorkPending(uint24) external pure override returns (bool) {
        return false;
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

    function runExternalJackpot(
        uint8,
        uint256,
        uint32,
        uint24,
        uint256
    )
        external
        pure
        override
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 trophyPoolDelta,
            uint256 returnAmountWei
        )
    {
        finished = true;
        winners = new address[](0);
        amounts = new uint256[](0);
        trophyPoolDelta = 0;
        returnAmountWei = 0;
    }

    function getLeaderboardAddresses(uint8) external view override returns (address[] memory) {
        address[] memory copy = new address[](leaderboard.length);
        for (uint256 i; i < leaderboard.length; ) {
            copy[i] = leaderboard[i];
            unchecked {
                ++i;
            }
        }
        return copy;
    }

    function getTopAffiliate() external pure override returns (address) {
        return address(0);
    }

    function bonusCoinflip(address, uint256, bool) external pure override {}

    function addToBounty(uint256) external pure override {}

    function rewardTopFlipBonus(uint256) external pure override {}

    function resetCoinflipLeaderboard() external pure override {}

    function resetAffiliateLeaderboard(uint24) external pure override {}

    function burnie(uint256) external payable override {}

    function primeMintEthQuest(uint48 day) external override {
        lastPrimeDay = day;
    }

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
