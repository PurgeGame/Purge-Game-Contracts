// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PurgeGameStorage
 * @notice Shared storage layout between the core game contract and its delegatecall modules.
 *         Keeping all slot definitions in a single contract prevents layout drift.
 */
abstract contract PurgeGameStorage {
    // -----------------------
    // Price
    // -----------------------
    uint256 internal price = 0.025 ether;
    uint256 internal priceCoin = 1_000_000_000;

    // -----------------------
    // Prize Pools and RNG
    // -----------------------
    uint256 internal lastPrizePool = 125 ether;
    uint256 internal levelPrizePool;
    uint256 internal prizePool;
    uint256 internal nextPrizePool;
    uint256 internal carryOver;
    uint256 internal decimatorHundredPool;
    bool internal decimatorHundredReady;
    uint256 internal dailyJackpotBase;
    uint256 internal dailyJackpotPaid;

    // -----------------------
    // Time / Session Tracking
    // -----------------------
    uint48 internal levelStartTime = type(uint48).max;
    uint48 internal dailyIdx;

    // -----------------------
    // Game Progress
    // -----------------------
    uint24 public level = 1;
    uint8 public gameState = 1;
    uint8 internal jackpotCounter;
    uint8 internal earlyPurgePercent;
    bool internal firstEarlyJackpotPending;
    uint8 internal phase;
    uint16 internal lastExterminatedTrait = 420;
    bool internal rngLockedFlag;
    bool internal rngFulfilled = true;
    uint256 internal rngWordCurrent;
    uint256 internal vrfRequestId;

    // -----------------------
    // Minting / Airdrops
    // -----------------------
    uint32 internal airdropMapsProcessedCount;
    uint32 internal airdropIndex;
    uint32 internal traitRebuildCursor;
    uint32 internal airdropMultiplier = 1;
    bool internal traitCountsSeedQueued;
    bool internal traitCountsShouldOverwrite;

    address[] internal pendingMapMints;
    mapping(address => uint32) internal playerMapMintsOwed;

    // -----------------------
    // Token / Trait State
    // -----------------------
    mapping(address => uint256) internal claimableWinnings;
    mapping(uint24 => address[][256]) internal traitPurgeTicket;

    struct PendingEndLevel {
        address exterminator;
        uint24 level;
        uint256 sidePool;
    }

    PendingEndLevel internal pendingEndLevel;

    // -----------------------
    // Daily / Trait Counters
    // -----------------------
    uint32[80] internal dailyPurgeCount;
    uint32[256] internal traitRemaining;
    mapping(address => uint256) internal mintPacked_;
}
