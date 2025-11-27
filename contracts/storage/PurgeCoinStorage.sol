// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGame} from "../interfaces/IPurgeGame.sol";
import {PurgeGameNFT} from "../PurgeGameNFT.sol";
import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";
import {IPurgeQuestModule} from "../interfaces/IPurgeQuestModule.sol";

/**
 * @title PurgeCoinStorage
 * @notice Shared storage layout for Purgecoin and lightweight helper view functions.
 */
abstract contract PurgeCoinStorage {
    // ---------------------------------------------------------------------
    // ERC20 state
    // ---------------------------------------------------------------------
    string public name = "Purgecoin";
    string public symbol = "PURGE";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---------------------------------------------------------------------
    // Types used in storage
    // ---------------------------------------------------------------------
    struct PlayerScore {
        address player;
        uint96 score;
    }

    struct AffiliateCodeInfo {
        address owner;
        uint8 rakeback;
    }

    struct StakeTrophyCandidate {
        address player;
        uint72 principal;
        uint24 level;
    }

    // ---------------------------------------------------------------------
    // Game wiring & session state
    // ---------------------------------------------------------------------
    IPurgeGame internal purgeGame;
    PurgeGameNFT internal purgeGameNFT;
    IPurgeGameTrophies internal purgeGameTrophies;
    IPurgeQuestModule internal questModule;
    address public jackpots;

    bool internal bonusActive;

    uint8 internal affiliateLen;
    uint8 internal topLen;

    uint24 internal stakeLevelComplete;
    uint32 internal scanCursor = type(uint32).max;
    uint32 internal payoutIndex;

    address[] internal cfPlayers;
    uint128 internal cfHead;
    uint128 internal cfTail;
    uint24 internal lastBafFlipLevel;

    mapping(address => uint256) public coinflipAmount;

    PlayerScore[8] public topBettors;

    mapping(bytes32 => AffiliateCodeInfo) internal affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned;
    mapping(address => bytes32) internal playerReferralCode;
    mapping(address => uint256) public playerLuckbox;
    PlayerScore public biggestLuckbox;
    PlayerScore[8] public affiliateLeaderboard;

    mapping(uint24 => address[]) internal stakeAddr;
    mapping(uint24 => mapping(address => uint256)) internal stakeAmt;
    StakeTrophyCandidate internal stakeTrophyCandidate;

    mapping(address => uint8) internal affiliatePos;
    mapping(address => uint8) internal topPos;

    uint128 public currentBounty = 1_000_000_000;
    uint128 public biggestFlipEver = 1_000_000_000;
    address internal bountyOwedTo;
    uint96 public totalPresaleSold;

    uint256 internal coinflipRewardPercent;
}
