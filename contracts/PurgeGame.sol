// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameNFT} from "./PurgeGameNFT.sol";
import {IPurgeGameTrophies} from "./PurgeGameTrophies.sol";
import {IPurgeCoinModule, IPurgeGameNFTModule, IPurgeGameTrophiesModule} from "./modules/PurgeGameModuleInterfaces.sol";

/**
 * @title Purge Game — Core NFT game contract
 * @notice This file defines the on-chain game logic surface (interfaces + core state).
 */

// ===========================================================================
// External Interfaces
// ===========================================================================

/**
 * @dev Interface to the delegate module handling slow-path endgame settlement.
 */
interface IPurgeCoin {
    function bonusCoinflip(address player, uint256 amount, bool rngReady, uint256 luckboxBonus) external;
    function burnie(uint256 amount) external payable;
    function burnCoin(address target, uint256 amount) external;
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external;
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch
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

interface IPurgeRendererLike {
    function setStartingTraitRemaining(uint32[256] calldata values) external;
}

interface IPurgeGameEndgameModule {
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint48 day,
        uint256 rngWord,
        IPurgeCoin coinContract,
        IPurgeGameTrophies trophiesContract
    ) external;
}

interface IPurgeGameJackpotModule {
    function payDailyJackpot(
        bool isDaily,
        uint24 lvl,
        uint256 randWord,
        IPurgeCoinModule coinContract,
        IPurgeGameNFTModule nftContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external;

    function payMapJackpot(
        uint24 lvl,
        uint256 rngWord,
        uint256 effectiveWei,
        IPurgeCoinModule coinContract,
        IPurgeGameNFTModule nftContract,
        IPurgeGameTrophiesModule trophiesContract
    ) external returns (bool finished);

    function calcPrizePoolForJackpot(
        uint24 lvl,
        uint256 rngWord,
        IPurgeCoinModule coinContract
    ) external returns (uint256 effectiveWei);
}
// ===========================================================================
// Contract
// ===========================================================================

contract PurgeGame {
    // -----------------------
    // Custom Errors
    // -----------------------
    error E(); // Generic guard (reverts in multiple paths)
    error LuckboxTooSmall(); // Caller does not meet luckbox threshold for the action
    error NotTimeYet(); // Called in a phase where the action is not permitted
    error RngNotReady(); // VRF request still pending
    error InvalidQuantity(); // Invalid quantity or token count for the action

    // -----------------------
    // Events
    // -----------------------
    event PlayerCredited(address indexed player, uint256 amount);
    event Jackpot(uint256 traits); // Encodes jackpot metadata
    event Purge(address indexed player, uint256[] tokenIds);
    event Advance(uint8 gameState, uint8 phase);

    // -----------------------
    // Immutable Addresses
    // -----------------------
    IPurgeRendererLike private immutable renderer; // Trusted renderer; used for tokenURI composition
    IPurgeCoin private immutable coin; // Trusted coin/game-side coordinator (PURGE ERC20)
    IPurgeGameNFT private immutable nft; // ERC721 interface for mint/burn/metadata surface
    IPurgeGameTrophies private immutable trophies; // Dedicated trophy module
    address private immutable endgameModule; // Delegate module for endgame settlement
    address private immutable jackpotModule; // Delegate module for jackpot routines

    // -----------------------
    // Game Constants
    // -----------------------
    uint48 private constant JACKPOT_RESET_TIME = 82620; // Offset anchor for "daily" windows
    uint32 private constant DEFAULT_PAYOUTS_PER_TX = 420; // Keeps participant payouts safely under ~15M gas
    uint32 private constant PURCHASE_MINIMUM = 1_500; // Minimum purchases to unlock game start
    uint32 private constant WRITES_BUDGET_SAFE = 800; // Keeps map batching within the ~15M gas budget
    uint32 private constant TRAIT_REBUILD_TOKENS_PER_TX = 4_096; // Max tokens processed per trait rebuild slice
    uint64 private constant MAP_LCG_MULT = 0x5851F42D4C957F2D; // LCG multiplier for map RNG slices
    uint8 private constant JACKPOTS_PER_DAY = 5;
    uint8 private constant JACKPOT_LEVEL_CAP = 10;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint8 private constant EARLY_PURGE_UNLOCK_PERCENT = 30; // 30% early-purge threshold gate
    uint256 private constant COIN_BASE_UNIT = 1_000_000; // 1 PURGED (6 decimals)

    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant MINT_MASK_20 = (uint256(1) << 20) - 1;
    uint256 private constant MINT_MASK_32 = (uint256(1) << 32) - 1;
    uint256 private constant ETH_LAST_LEVEL_SHIFT = 0;
    uint256 private constant ETH_LEVEL_COUNT_SHIFT = 24;
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;
    uint256 private constant ETH_DAY_SHIFT = 72;
    uint256 private constant ETH_DAY_STREAK_SHIFT = 104;
    uint256 private constant COIN_DAY_SHIFT = 124;
    uint256 private constant COIN_DAY_STREAK_SHIFT = 156;
    uint256 private constant AGG_DAY_SHIFT = 176;
    uint256 private constant AGG_DAY_STREAK_SHIFT = 208;

    // -----------------------
    // Price
    // -----------------------
    uint256 private price = 0.025 ether; // Base mint price
    uint256 private priceCoin = 1_000_000_000; // 1,000 Purgecoin (6d) base unit

    // -----------------------
    // Prize Pools and RNG
    // -----------------------
    uint256 private lastPrizePool = 125 ether; // Snapshot from previous epoch (non-zero post L1)
    uint256 private levelPrizePool; // Snapshot for endgame distribution of current level
    uint256 private prizePool; // Live ETH pool for current level
    uint256 private nextPrizePool; // ETH collected during purge for upcoming level
    uint256 private carryOver; // Carryover amount reserved for the next level (wei)

    // -----------------------
    // Time / Session Tracking
    // -----------------------
    uint48 private levelStartTime = type(uint48).max; // Wall-clock start of current level
    uint48 private dailyIdx; // Daily session index (derived from JACKPOT_RESET_TIME)

    // -----------------------
    // Game Progress
    // -----------------------
    uint24 public level = 1; // 1-based level counter
    uint8 public gameState = 1; // Phase FSM
    uint8 private jackpotCounter; // # of daily jackpots paid in current level
    uint8 private earlyPurgePercent; // Cached ratio of current prize pool relative to the prior level (0-255)
    uint8 private phase; // Airdrop sub-phase (0..7)
    uint16 private lastExterminatedTrait = TRAIT_ID_TIMEOUT; // The winning trait from the previous season (timeout sentinel)

    // -----------------------
    // RNG Liveness Flags
    // -----------------------

    // -----------------------
    // Minting / Airdrops
    // -----------------------
    uint32 private airdropMapsProcessedCount; // Progress inside current map-mint player's queue
    uint32 private airdropIndex; // Progress across players in pending arrays
    uint32 private traitRebuildCursor; // Tokens processed during trait rebuild
    bool private traitCountsSeedQueued; // Trait seeding pending after pending mints finish
    bool private traitCountsShouldOverwrite; // On next rebuild slice, overwrite instead of accumulate

    address[] private pendingMapMints; // Queue of players awaiting map mints
    mapping(address => uint32) private playerMapMintsOwed; // Player => map mints owed

    // -----------------------
    // Token / Trait State
    // -----------------------
    mapping(address => uint256) private claimableWinnings; // ETH claims accumulated on-chain
    mapping(uint24 => address[][256]) private traitPurgeTicket; // level => traitId => ticket holders

    struct PendingEndLevel {
        address exterminator; // Non-zero means trait win; zero means map timeout
        uint24 level; // Level that just ended (0 sentinel = none pending)
        uint256 sidePool; // Trait win: pool snapshot for trophy/exterminator splits; Map timeout: full carry pool snapshot
    }
    PendingEndLevel private pendingEndLevel;

    // -----------------------
    // Daily / Trait Counters
    // -----------------------
    uint32[80] internal dailyPurgeCount; // Layout: 8 symbol, 8 color, 64 trait buckets
    uint32[256] internal traitRemaining; // Remaining supply per trait (0 means exhausted)
    mapping(address => uint256) private mintPacked_;

    // -----------------------
    // Constructor
    // -----------------------

    /**
     * @param purgeCoinContract Trusted PURGE ERC20 / game coordinator address
     * @param renderer_         Trusted on-chain renderer
     * @param nftContract       ERC721 game contract
     * @param trophiesContract  Trophy manager contract
     * @param endgameModule_    Delegate module handling endgame settlement
     * @param jackpotModule_    Delegate module handling jackpot distribution
     *
     * @dev ERC721 sentinel trophy token is minted lazily during the first transition to state 2.
     */
    constructor(
        address purgeCoinContract,
        address renderer_,
        address nftContract,
        address trophiesContract,
        address endgameModule_,
        address jackpotModule_
    ) {
        coin = IPurgeCoin(purgeCoinContract);
        renderer = IPurgeRendererLike(renderer_);
        nft = IPurgeGameNFT(nftContract);
        trophies = IPurgeGameTrophies(trophiesContract);
        if (endgameModule_ == address(0)) revert E();
        endgameModule = endgameModule_;
        if (jackpotModule_ == address(0)) revert E();
        jackpotModule = jackpotModule_;
    }

    // --- View: lightweight game status -------------------------------------------------

    /// @notice Snapshot key game state for UI/indexers.
    /// @return gameState_       FSM state (0=idle,1=pregame,2=purchase/airdrop,3=purge)
    /// @return phase_           Airdrop sub-phase (0..7)
    /// @return jackpotCounter_  Daily jackpots processed this level
    /// @return price_           Current mint price (wei)
    /// @return carry_           Carryover earmarked for next level (wei)
    /// @return prizePoolTarget  Last level's prize pool snapshot (wei)
    /// @return prizePoolCurrent Active prize pool (levelPrizePool when purging)
    /// @return enoughPurchases  True if purchaseCount >= 1,500
    /// @return earlyPurgePercent_ Ratio of current prize pool vs. prior level prize pool (percent, capped at 255)
    function gameInfo()
        external
        view
        returns (
            uint8 gameState_,
            uint8 phase_,
            uint8 jackpotCounter_,
            uint256 price_,
            uint256 carry_,
            uint256 prizePoolTarget,
            uint256 prizePoolCurrent,
            bool enoughPurchases,
            uint8 earlyPurgePercent_
        )
    {
        gameState_ = gameState;
        phase_ = phase;
        jackpotCounter_ = jackpotCounter;
        price_ = price;
        carry_ = carryOver;
        prizePoolTarget = lastPrizePool;
        prizePoolCurrent = prizePool;
        enoughPurchases = nft.purchaseCount() >= PURCHASE_MINIMUM;
        earlyPurgePercent_ = earlyPurgePercent;
    }

    // --- State machine: advance one tick ------------------------------------------------

    function currentPhase() external view returns (uint8) {
        return phase;
    }

    function mintPrice() external view returns (uint256) {
        return price;
    }

    function coinPriceUnit() external view returns (uint256) {
        return priceCoin;
    }

    function getEarlyPurgePercent() external view returns (uint8) {
        return earlyPurgePercent;
    }

    function coinMintUnlock(uint24 lvl) external view returns (bool) {
        return lvl < 5 || earlyPurgePercent >= EARLY_PURGE_UNLOCK_PERCENT;
    }

    function ethMintLastLevel(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
    }

    function ethMintLevelCount(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
    }

    function ethMintStreakCount(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
    }

    function ethMintLastDay(address player) external view returns (uint48) {
        return uint48((mintPacked_[player] >> ETH_DAY_SHIFT) & MINT_MASK_32);
    }

    function ethMintDayStreak(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> ETH_DAY_STREAK_SHIFT) & MINT_MASK_20);
    }

    function coinMintLastDay(address player) external view returns (uint48) {
        return uint48((mintPacked_[player] >> COIN_DAY_SHIFT) & MINT_MASK_32);
    }

    function coinMintDayStreak(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> COIN_DAY_STREAK_SHIFT) & MINT_MASK_20);
    }

    function mintLastDay(address player) external view returns (uint48) {
        return uint48((mintPacked_[player] >> AGG_DAY_SHIFT) & MINT_MASK_32);
    }

    function mintDayStreak(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> AGG_DAY_STREAK_SHIFT) & MINT_MASK_20);
    }

    function playerMintData(
        address player
    )
        external
        view
        returns (
            uint24 ethLastLevel,
            uint24 ethLevelCount,
            uint24 ethLevelStreak,
            uint48 ethLastDay,
            uint24 ethDayStreak,
            uint48 coinLastDay,
            uint24 coinDayStreak,
            uint48 overallLastDay,
            uint24 overallDayStreak
        )
    {
        uint256 packed = mintPacked_[player];
        ethLastLevel = uint24((packed >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
        ethLevelCount = uint24((packed >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
        ethLevelStreak = uint24((packed >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
        ethLastDay = uint48((packed >> ETH_DAY_SHIFT) & MINT_MASK_32);
        ethDayStreak = uint24((packed >> ETH_DAY_STREAK_SHIFT) & MINT_MASK_20);
        coinLastDay = uint48((packed >> COIN_DAY_SHIFT) & MINT_MASK_32);
        coinDayStreak = uint24((packed >> COIN_DAY_STREAK_SHIFT) & MINT_MASK_20);
        overallLastDay = uint48((packed >> AGG_DAY_SHIFT) & MINT_MASK_32);
        overallDayStreak = uint24((packed >> AGG_DAY_STREAK_SHIFT) & MINT_MASK_20);
    }

    function recordMint(
        address player,
        uint24 lvl,
        bool creditNext,
        bool coinMint
    ) external payable returns (uint256 coinReward, uint256 luckboxReward) {
        if (msg.sender != address(nft)) revert E();
        if (coinMint) {
            if (creditNext || msg.value != 0) revert E();
        } else {
            if (creditNext) {
                nextPrizePool += msg.value;
            } else {
                prizePool += msg.value;
            }
        }
        return _recordMintData(player, lvl, coinMint);
    }

    /// @notice Advances the game state machine. Anyone can call, but certain steps
    ///         require the caller to meet a luckbox threshold (payment for work/luckbox bonus).
    /// @param cap Emergency unstuck function, in case a necessary transaction is too large for a block.
    ///            Using cap removes Purgecoin payment.
    function advanceGame(uint32 cap) external {
        uint48 ts = uint48(block.timestamp);
        IPurgeCoin coinContract = coin;
        // Liveness drain
        if (ts - 365 days > levelStartTime) {
            gameState = 0;
            uint256 bal = address(this).balance;
            if (bal > 0) coinContract.burnie{value: bal}(0);
        }
        uint24 lvl = level;
        uint8 modTwenty = uint8(lvl % 20);
        uint8 _gameState = gameState;
        uint8 _phase = phase;
        bool rngReady = true;
        uint48 day = uint48((ts - JACKPOT_RESET_TIME) / 1 days);

        do {
            // Luckbox rewards
            if (cap == 0 && coinContract.playerLuckbox(msg.sender) < (priceCoin * lvl * (lvl / 100 + 1)) << 1)
                revert LuckboxTooSmall();
            uint256 rngWord;
            rngWord = rngAndTimeGate(day);
            if (rngWord == 1) {
                rngReady = false;
                break;
            }
            // --- State 1 - Pregame ---
            if (_gameState == 1) {
                _runEndgameModule(lvl, cap, day, rngWord); // handles payouts, wipes, endgame dist, and jackpots
                if (gameState == 2 && pendingEndLevel.level == 0 && nft.rngLocked()) {
                    dailyIdx = day;
                    nft.releaseRngLock();
                }
                break;
            }

            // --- State 2 - Purchase / Airdrop ---
            if (_gameState == 2) {
                if (_phase <= 2) {
                    bool prizeReady = prizePool >= lastPrizePool;
                    bool levelGate = (nft.purchaseCount() >= PURCHASE_MINIMUM && prizeReady);
                    if (modTwenty == 16) {
                        levelGate = prizeReady;
                    }

                    bool advanceToAirdrop;
                    if (_phase == 2 && levelGate) {
                        if (modTwenty != 0 && !coinContract.processCoinflipPayouts(lvl, cap, true, rngWord, day)) break;
                        advanceToAirdrop = true;
                    } else if (modTwenty != 0) {
                        if (!coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day)) break;
                    }

                    bool batchesPending = airdropIndex < pendingMapMints.length;
                    if (batchesPending) {
                        bool batchesFinished = _processMapBatch(cap);
                        if (!batchesFinished) break;
                        batchesPending = false;
                    }

                    endDayJackpot(lvl, day, rngWord);

                    if (advanceToAirdrop && !batchesPending) {
                        phase = 3;
                    }

                    break;
                }

                if (_phase == 3) {
                    if (_processMapBatch(cap)) {
                        phase = 4;
                        airdropIndex = 0;
                        airdropMapsProcessedCount = 0;
                    }
                    break;
                }

                if (_phase == 4) {
                    bool coinflipMapOk = true;
                    if (modTwenty != 0) {
                        coinflipMapOk = coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day);
                    }
                    if (!coinflipMapOk) break;
                    uint256 mapEffectiveWei = _calcPrizePoolForJackpot(lvl, rngWord);
                    if (payMapJackpot(lvl, rngWord, mapEffectiveWei)) {
                        phase = 5;
                    }
                    break;
                }

                if (_phase == 5) {
                    if (nft.processPendingMints(cap)) {
                        traitCountsSeedQueued = true;
                        traitRebuildCursor = 0;
                        delete pendingMapMints;
                        airdropIndex = 0;
                        airdropMapsProcessedCount = 0;
                        earlyPurgePercent = 0;
                        phase = 6;
                    }
                    break;
                }

                uint32 purchases = nft.purchaseCount();
                if (traitCountsSeedQueued) {
                    if (purchases != 0 && traitRebuildCursor < purchases) {
                        _rebuildTraitCounts(cap);
                        break;
                    }
                    _seedTraitCounts();
                    traitCountsSeedQueued = false;
                }

                levelStartTime = ts;
                nft.finalizePurchasePhase(purchases);
                dailyIdx = day;
                traitRebuildCursor = 0;
                gameState = 3;

                break;
            }

            // --- State 3 - Purge ---
            if (_gameState == 3) {
                if (_phase == 6) {
                    uint24 coinflipLevel = uint24(lvl + (jackpotCounter >= 9 ? 1 : 0));
                    if (!coinContract.processCoinflipPayouts(coinflipLevel, cap, false, rngWord, day)) break;

                    uint8 remaining = jackpotCounter >= JACKPOT_LEVEL_CAP
                        ? 0
                        : uint8(JACKPOT_LEVEL_CAP - jackpotCounter);
                    uint8 toPay = remaining > JACKPOTS_PER_DAY ? JACKPOTS_PER_DAY : remaining;

                    bool keepGoing = true;
                    for (uint8 i; i < toPay; ) {
                        payDailyJackpot(true, lvl, rngWord);
                        if (!_handleJackpotLevelCap() || gameState != 3) {
                            keepGoing = false;
                            break;
                        }
                        unchecked {
                            ++i;
                        }
                    }
                    if (!keepGoing || gameState != 3) break;
                    dailyIdx = day;
                    nft.releaseRngLock();
                    break;
                }

                if (coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day)) {
                    phase = 6;
                }
                break;
            }

            // --- State 0 ---
            if (_gameState == 0) {
                coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day);
            }
        } while (false);

        emit Advance(_gameState, _phase);

        if (_gameState != 0 && cap == 0) coinContract.bonusCoinflip(msg.sender, priceCoin, rngReady, 0);
    }

    // --- Purchases: schedule NFT mints (traits precomputed) ----------------------------------------

    /// @notice Queue map mints owed after NFT-side processing.
    /// @param buyer    Player to credit.
    /// @param quantity Map entries purchased (1+).
    function enqueueMap(address buyer, uint32 quantity) external {
        if (msg.sender != address(nft)) revert E();

        if (playerMapMintsOwed[buyer] == 0) {
            pendingMapMints.push(buyer);
        }

        unchecked {
            playerMapMintsOwed[buyer] += quantity;
        }
    }

    // --- Purging NFTs into tickets & potentially ending the level -----------------------------------

    function purge(uint256[] calldata tokenIds) external {
        if (nft.rngLocked()) revert RngNotReady();
        if (gameState != 3) revert NotTimeYet();

        uint256 count = tokenIds.length;
        if (count == 0 || count > 75) revert InvalidQuantity();
        address caller = msg.sender;
        nft.purge(caller, tokenIds);

        uint24 lvl = level;
        bool isSeventhStep = (lvl % 10 == 7);
        bool isDoubleCountStep = (lvl % 10 == 2);
        bool levelNinety = (lvl == 90);
        uint32 endLevelFlag = isSeventhStep ? 1 : 0;

        uint16 prevExterminated = lastExterminatedTrait;
        uint256 bonusTenths;
        uint256 stakeBonusCoin;

        address[][256] storage tickets = traitPurgeTicket[lvl];
        IPurgeGameTrophies trophiesContract = trophies;

        uint16 winningTrait = TRAIT_ID_TIMEOUT;
        for (uint256 i; i < count; ) {
            uint256 tokenId = tokenIds[i];

            uint32 traits = nft.tokenTraitsPacked(tokenId);
            uint8 trait0 = uint8(traits);
            uint8 trait1 = uint8(traits >> 8);
            uint8 trait2 = uint8(traits >> 16);
            uint8 trait3 = uint8(traits >> 24);

            uint8 color0 = trait0 >> 3;
            uint8 color1 = (trait1 & 0x3F) >> 3;
            uint8 color2 = (trait2 & 0x3F) >> 3;
            uint8 color3 = (trait3 & 0x3F) >> 3;
            if (color0 == color1 && color0 == color2 && color0 == color3) {
                unchecked {
                    bonusTenths += 49;
                }
            }

            if (levelNinety) {
                unchecked {
                    bonusTenths += 9;
                }
            } else if (
                uint16(trait0) == prevExterminated ||
                uint16(trait1) == prevExterminated ||
                uint16(trait2) == prevExterminated ||
                uint16(trait3) == prevExterminated
            ) {
                unchecked {
                    bonusTenths += 9;
                }
            }

            {
                uint8 levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait0));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoin * uint256(levelPercent)) / 100;
                    }
                }
                levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait1));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoin * uint256(levelPercent)) / 100;
                    }
                }
                levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait2));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoin * uint256(levelPercent)) / 100;
                    }
                }
                levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait3));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoin * uint256(levelPercent)) / 100;
                    }
                }
            }

            unchecked {
                if (_consumeTrait(trait0, endLevelFlag)) {
                    winningTrait = trait0;
                    break;
                }
                if (_consumeTrait(trait1, endLevelFlag)) {
                    winningTrait = trait1;
                    break;
                }
                if (_consumeTrait(trait2, endLevelFlag)) {
                    winningTrait = trait2;
                    break;
                }
                if (_consumeTrait(trait3, endLevelFlag)) {
                    winningTrait = trait3;
                    break;
                }
                dailyPurgeCount[trait0 & 0x07] += 1;
                dailyPurgeCount[((trait1 - 64) >> 3) + 8] += 1;
                dailyPurgeCount[trait2 - 128 + 16] += 1;
                ++i;
            }

            tickets[trait0].push(caller);
            tickets[trait1].push(caller);
            tickets[trait2].push(caller);
            tickets[trait3].push(caller);
        }

        if (isDoubleCountStep) count <<= 1;
        uint256 priceUnit = priceCoin / 10;
        if (stakeBonusCoin != 0) {
            coin.bonusCoinflip(caller, stakeBonusCoin, false, 0);
        }
        coin.bonusCoinflip(caller, (count + bonusTenths) * priceUnit, true, 0);
        emit Purge(msg.sender, tokenIds);

        if (winningTrait != TRAIT_ID_TIMEOUT) {
            _endLevel(winningTrait);
            return;
        }
    }

    // --- Level finalization -------------------------------------------------------------------------

    /// @notice Finalize the current level either due to a trait being exterminated (<256) or a timed-out “TRAIT_ID_TIMEOUT” end.
    /// @dev
    /// When a trait is exterminated (<256):
    /// - Lock the exterminated trait in the current level’s storage.
    /// - Split prize pool: 90% to participants, 10% to trophies and affiliates (handled elsewhere),
    ///   from which the “exterminator” gets 20% (or 40% for 7th steps since L25),
    ///   and the rest is divided evenly per ticket for the exterminated trait.
    /// - Mint the level trophy (transfers the placeholder token owned by the contract).
    /// - Start next level and seed `levelPrizePool`.
    ///
    /// When a non-trait end occurs (>=256, e.g. daily jackpots path):
    /// - Allocate 10% of the remaining `prizePool` to the current MAP trophy holder and 5% each to three
    ///   random MAP trophies still receiving drip payouts (with replacement).
    /// - Carry the remainder forward and reset leaderboards.
    /// - On L%100==0: adjust price and `lastPrizePool`.
    ///
    /// After either path:
    /// - Reset per-level state, mint the next level’s trophy placeholder,
    ///   set default exterminated sentinel to TRAIT_ID_TIMEOUT, and request fresh VRF.
    function _endLevel(uint16 exterminated) private {
        PendingEndLevel storage pend = pendingEndLevel;

        address exterminator = msg.sender;
        uint24 levelSnapshot = level;
        pend.level = levelSnapshot;

        if (exterminated < 256) {
            uint8 exTrait = uint8(exterminated);
            bool repeatOrNinety = (uint16(exTrait) == lastExterminatedTrait) || (levelSnapshot == 90);
            uint256 pool = prizePool;

            if (repeatOrNinety) {
                uint256 keep = pool >> 1;
                carryOver += keep;
                pool -= keep;
            }

            uint256 ninetyPercent = (pool * 90) / 100;
            uint256 mod10 = levelSnapshot % 10;
            uint256 exterminatorShare = (mod10 == 4 && levelSnapshot != 4) ? (pool * 40) / 100 : (pool * 20) / 100;
            uint256 participantShare = ninetyPercent - exterminatorShare;

            uint256 ticketsLen = traitPurgeTicket[levelSnapshot][exTrait].length;
            prizePool = (ticketsLen == 0) ? 0 : (participantShare / ticketsLen);

            pend.exterminator = exterminator;
            pend.sidePool = pool;

            levelPrizePool = pool;
            lastExterminatedTrait = exTrait;
        } else {
            if (levelSnapshot % 100 == 0) {
                price = 0.05 ether;
                priceCoin >>= 1;
                lastPrizePool = prizePool >> 3;
            }

            uint256 poolCarry = prizePool;

            pend.exterminator = address(0);
            pend.sidePool = poolCarry;

            prizePool = 0;
            lastExterminatedTrait = TRAIT_ID_TIMEOUT;
        }

        uint24 nextLevel = levelSnapshot + 1;
        trophies.prepareNextLevel(nextLevel);

        unchecked {
            levelSnapshot++;
            level++;
        }

        traitRebuildCursor = 0;
        jackpotCounter = 0;

        uint256 mod100 = levelSnapshot % 100;
        uint256 mod20 = levelSnapshot % 20;
        if (mod100 == 10 || mod100 == 0) {
            price <<= 1;
        } else if (mod20 == 0) {
            price += (levelSnapshot < 100) ? 0.05 ether : 0.1 ether;
        }

        gameState = 1;
    }

    /// @notice Delegatecall into the endgame module to resolve slow settlement paths.
    function _runEndgameModule(uint24 lvl, uint32 cap, uint48 day, uint256 rngWord) private {
        endgameModule.delegatecall(
            abi.encodeWithSelector(
                IPurgeGameEndgameModule.finalizeEndgame.selector,
                lvl,
                cap,
                day,
                rngWord,
                coin,
                trophies
            )
        );
    }

    // --- Claiming winnings (ETH) --------------------------------------------------------------------

    /// @notice Claim the caller’s accrued ETH winnings (affiliates, jackpots, endgame payouts).
    /// @dev Leaves a 1 wei sentinel so subsequent credits remain non-zero -> cheaper SSTORE.
    function claimWinnings() external {
        address player = msg.sender;
        uint256 amount = claimableWinnings[player];
        if (amount <= 1) revert E();
        unchecked {
            claimableWinnings[player] = 1;
            amount -= 1;
        }
        (bool ok, ) = payable(player).call{value: amount}("");
        if (!ok) revert E();
    }

    function getWinnings() external view returns (uint256) {
        return claimableWinnings[msg.sender];
    }

    // --- Credits & jackpot helpers ------------------------------------------------------------------

    /// @notice Credit ETH winnings to a player’s claimable balance and emit an accounting event.
    /// @param beneficiary Player to credit.
    /// @param weiAmount   Amount in wei to add.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) internal {
        unchecked {
            claimableWinnings[beneficiary] += weiAmount;
        }
        emit PlayerCredited(beneficiary, weiAmount);
    }

    function _recordMintData(
        address player,
        uint24 lvl,
        bool coinMint
    ) private returns (uint256 coinReward, uint256 luckboxReward) {
        uint256 prevData = mintPacked_[player];
        uint32 day = _currentMintDay();
        uint256 data;

        if (coinMint) {
            uint24 prevAggStreak = uint24((prevData >> AGG_DAY_STREAK_SHIFT) & MINT_MASK_20);
            data = _applyMintDay(prevData, day, COIN_DAY_SHIFT, MINT_MASK_32, COIN_DAY_STREAK_SHIFT, MINT_MASK_20);

            uint24 aggStreak = uint24((data >> AGG_DAY_STREAK_SHIFT) & MINT_MASK_20);
            if (aggStreak > prevAggStreak) {
                uint256 dailyBonus = _dailyStreakBonus(aggStreak);
                if (dailyBonus != 0) {
                    unchecked {
                        coinReward += dailyBonus;
                    }
                }
            }
        } else {
            uint24 prevLevel = uint24((prevData >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
            uint24 total = uint24((prevData >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
            uint24 streak = uint24((prevData >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
            uint24 prevAggStreak = uint24((prevData >> AGG_DAY_STREAK_SHIFT) & MINT_MASK_20);
            uint24 prevEthDayStreak = uint24((prevData >> ETH_DAY_STREAK_SHIFT) & MINT_MASK_20);

            data = _applyMintDay(prevData, day, ETH_DAY_SHIFT, MINT_MASK_32, ETH_DAY_STREAK_SHIFT, MINT_MASK_20);

            uint24 aggStreak = uint24((data >> AGG_DAY_STREAK_SHIFT) & MINT_MASK_20);
            if (aggStreak > prevAggStreak) {
                uint256 dailyBonus = _dailyStreakBonus(aggStreak);
                if (dailyBonus != 0) {
                    unchecked {
                        coinReward += dailyBonus;
                    }
                }
            }

            uint24 ethDayStreak = uint24((data >> ETH_DAY_STREAK_SHIFT) & MINT_MASK_20);
            if (ethDayStreak > prevEthDayStreak) {
                uint256 ethDailyBonus = _dailyStreakBonus(ethDayStreak);
                if (ethDailyBonus != 0) {
                    unchecked {
                        coinReward += ethDailyBonus;
                    }
                }
            }

            if (prevLevel == lvl) {
                if (data != prevData) {
                    mintPacked_[player] = data;
                }
                return (coinReward, luckboxReward);
            }

            if (total < type(uint24).max) {
                unchecked {
                    total = uint24(total + 1);
                }
            }

            if (prevLevel != 0 && prevLevel + 1 == lvl) {
                if (streak < type(uint24).max) {
                    unchecked {
                        streak = uint24(streak + 1);
                    }
                }
            } else {
                streak = 1;
            }

            data = _setPacked(data, ETH_LAST_LEVEL_SHIFT, MINT_MASK_24, lvl);
            data = _setPacked(data, ETH_LEVEL_COUNT_SHIFT, MINT_MASK_24, total);
            data = _setPacked(data, ETH_LEVEL_STREAK_SHIFT, MINT_MASK_24, streak);

            uint256 streakReward;
            if (streak >= 2) {
                uint256 capped = streak >= 61 ? 60 : uint256(streak - 1);
                streakReward = capped * 100 * COIN_BASE_UNIT;
            }

            uint256 totalReward;
            if (total >= 2) {
                uint256 cappedTotal = total >= 61 ? 60 : uint256(total - 1);
                totalReward = (cappedTotal * 100 * COIN_BASE_UNIT * 30) / 100;
            }

            if (streakReward != 0 || totalReward != 0) {
                unchecked {
                    luckboxReward = streakReward + totalReward;
                    coinReward = luckboxReward;
                }
            }

            if (streak == lvl && lvl >= 20 && (lvl % 10 == 0)) {
                uint256 milestoneBonus = (uint256(lvl) / 2) * 1000 * COIN_BASE_UNIT;
                coinReward += milestoneBonus;
            }

            if (total >= 20 && (total % 10 == 0)) {
                uint256 totalMilestone = (uint256(total) / 2) * 1000 * COIN_BASE_UNIT;
                coinReward += (totalMilestone * 30) / 100;
            }
        }

        if (data != prevData) {
            mintPacked_[player] = data;
        }
        return (coinReward, luckboxReward);
    }

    function _applyMintDay(
        uint256 data,
        uint32 day,
        uint256 dayShift,
        uint256 dayMask,
        uint256 streakShift,
        uint256 streakMask
    ) private pure returns (uint256) {
        data = _bumpMintDay(data, day, dayShift, dayMask, streakShift, streakMask);
        if (dayShift != AGG_DAY_SHIFT) {
            data = _bumpMintDay(data, day, AGG_DAY_SHIFT, MINT_MASK_32, AGG_DAY_STREAK_SHIFT, MINT_MASK_20);
        }
        return data;
    }

    function _currentMintDay() private view returns (uint32) {
        uint48 day = dailyIdx;
        if (day == 0) {
            day = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        }
        return uint32(day);
    }

    function _bumpMintDay(
        uint256 data,
        uint32 day,
        uint256 dayShift,
        uint256 dayMask,
        uint256 streakShift,
        uint256 streakMask
    ) private pure returns (uint256) {
        uint32 prevDay = uint32((data >> dayShift) & dayMask);
        if (prevDay == day) {
            return data;
        }

        uint256 streak = (data >> streakShift) & streakMask;
        if (prevDay != 0 && day == prevDay + 1) {
            if (streak < streakMask) {
                unchecked {
                    streak += 1;
                }
            }
        } else {
            streak = 1;
        }

        uint256 clearedDay = data & ~(dayMask << dayShift);
        uint256 updated = clearedDay | (uint256(day) << dayShift);
        uint256 clearedStreak = updated & ~(streakMask << streakShift);
        return clearedStreak | (streak << streakShift);
    }

    function _setPacked(uint256 data, uint256 shift, uint256 mask, uint256 value) private pure returns (uint256) {
        return (data & ~(mask << shift)) | ((value & mask) << shift);
    }

    function _dailyStreakBonus(uint256 streak) private pure returns (uint256) {
        if (streak < 2) return 0;
        uint256 bonus = 50 + (streak - 2) * 10;
        if (bonus > 320) bonus = 320;
        return bonus * COIN_BASE_UNIT;
    }

    // --- Shared jackpot helpers ----------------------------------------------------------------------

    // --- Map jackpot payout (end of purchase phase) -------------------------------------------------

    function payMapJackpot(uint24 lvl, uint256 rngWord, uint256 effectiveWei) internal returns (bool finished) {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IPurgeGameJackpotModule.payMapJackpot.selector,
                lvl,
                rngWord,
                effectiveWei,
                IPurgeCoinModule(address(coin)),
                IPurgeGameNFTModule(address(nft)),
                IPurgeGameTrophiesModule(address(trophies))
            )
        );
        if (!ok) revert E();
        return abi.decode(data, (bool));
    }

    function _calcPrizePoolForJackpot(uint24 lvl, uint256 rngWord) private returns (uint256 effectiveWei) {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IPurgeGameJackpotModule.calcPrizePoolForJackpot.selector,
                lvl,
                rngWord,
                IPurgeCoinModule(address(coin))
            )
        );
        if (!ok) revert E();
        return abi.decode(data, (uint256));
    }

    // --- Daily & early‑purge jackpots ---------------------------------------------------------------

    function payDailyJackpot(bool isDaily, uint24 lvl, uint256 randWord) internal {
        (bool ok, ) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IPurgeGameJackpotModule.payDailyJackpot.selector,
                isDaily,
                lvl,
                randWord,
                IPurgeCoinModule(address(coin)),
                IPurgeGameNFTModule(address(nft)),
                IPurgeGameTrophiesModule(address(trophies))
            )
        );
        if (!ok) revert E();
    }

    function _handleJackpotLevelCap() private returns (bool) {
        if (jackpotCounter >= JACKPOT_LEVEL_CAP) {
            _endLevel(TRAIT_ID_TIMEOUT);
            return false;
        }
        return true;
    }

    // --- Flips, VRF, payments, rarity ----------------------------------------------------------------

    function rngAndTimeGate(uint48 day) internal returns (uint256 word) {
        if (day == dailyIdx) revert NotTimeYet();

        bool locked = nft.rngLocked();
        uint256 currentWord = nft.currentRngWord();

        if (currentWord == 0) {
            if (locked) revert RngNotReady();
            nft.requestRng();
            return 1;
        }

        if (!locked) {
            // Stale entropy from previous cycle; request a fresh word.
            nft.requestRng();
            return 1;
        }

        return currentWord;
    }

    /// @notice Handle ETH payments for purchases; forwards affiliate rewards as coinflip credits.
    /// @param scaledQty Quantity scaled by 100 (to keep integer math with `price`).
    /// @param affiliateCode Affiliate/referral code provided by the buyer.
    // --- Map / NFT airdrop batching ------------------------------------------------------------------

    /// @notice Process a batch of map mints using a caller-provided writes budget (0 = auto).
    /// @param writesBudget Count of SSTORE writes allowed this tx; hard-clamped to stay ≤15M-safe.
    /// @return finished True if all pending map mints have been fully processed.
    function _processMapBatch(uint32 writesBudget) private returns (bool finished) {
        uint256 total = pendingMapMints.length;
        if (airdropIndex >= total) return true;

        if (writesBudget == 0) writesBudget = WRITES_BUDGET_SAFE;
        uint24 lvl = level;
        bool throttleWrites;
        if (phase <= 1) {
            throttleWrites = true;
            phase = 2;
        } else if (phase == 3) {
            bool firstAirdropBatch = (airdropIndex == 0 && airdropMapsProcessedCount == 0);
            if (firstAirdropBatch) {
                throttleWrites = true;
            }
        }
        if (throttleWrites) {
            writesBudget -= (writesBudget * 35) / 100; // 65% scaling
        }
        uint32 used = 0;
        uint256 entropy = nft.currentRngWord();

        while (airdropIndex < total && used < writesBudget) {
            address player = pendingMapMints[airdropIndex];
            uint32 owed = playerMapMintsOwed[player];
            if (owed == 0) {
                unchecked {
                    ++airdropIndex;
                }
                airdropMapsProcessedCount = 0;
                continue;
            }

            uint32 room = writesBudget - used;

            // per-address overhead (reserve before sizing 'take')
            uint32 baseOv = 2;
            if (airdropMapsProcessedCount == 0 && owed <= 2) {
                baseOv += 2;
            }
            if (room <= baseOv) break;
            room -= baseOv;

            // existing writes-based clamp
            uint32 maxT = (room <= 256) ? (room / 2) : (room - 256);
            uint32 take = owed > maxT ? maxT : owed;
            if (take == 0) break;

            // do the work
            uint256 baseKey = (uint256(lvl) << 224) | (uint256(airdropIndex) << 192) | (uint256(uint160(player)) << 32);
            _raritySymbolBatch(player, baseKey, airdropMapsProcessedCount, take, entropy);

            // writes accounting: ticket writes + per-address overhead + finish overhead
            uint32 writesThis = (take <= 256) ? (take * 2) : (take + 256);
            writesThis += baseOv;
            if (take == owed) {
                writesThis += 1;
            }

            unchecked {
                playerMapMintsOwed[player] = owed - take;
                airdropMapsProcessedCount += take;
                used += writesThis;
                if (playerMapMintsOwed[player] == 0) {
                    ++airdropIndex;
                    airdropMapsProcessedCount = 0;
                }
            }
        }
        return airdropIndex >= total;
    }

    function endDayJackpot(uint24 lvl, uint48 day, uint256 rngWord) private {
        payDailyJackpot(false, lvl, rngWord);
        dailyIdx = day;
        if (nft.rngLocked()) {
            nft.releaseRngLock();
        }
    }

    function _seedTraitCounts() private {
        uint32[256] memory snapshot;
        uint32[256] storage remaining = traitRemaining;

        for (uint16 t; t < 256; ) {
            snapshot[t] = remaining[t];
            unchecked {
                ++t;
            }
        }

        renderer.setStartingTraitRemaining(snapshot);
        traitCountsShouldOverwrite = true;
    }

    /// @notice Rebuild `traitRemaining` by scanning scheduled token traits in capped slices.
    /// @param tokenBudget Max tokens to process this call (0 => default 4,096).
    /// @return finished True when all tokens for the level have been incorporated.
    function _rebuildTraitCounts(uint32 tokenBudget) private returns (bool finished) {
        uint32 target = nft.purchaseCount();

        uint32 cursor = traitRebuildCursor;
        if (cursor >= target) return true;

        uint32 batch = (tokenBudget == 0) ? TRAIT_REBUILD_TOKENS_PER_TX : tokenBudget;
        uint32 remaining = target - cursor;
        if (batch > remaining) batch = remaining;

        bool startingSlice = cursor == 0;

        uint32[256] memory localCounts;

        uint256 baseTokenId = nft.currentBaseTokenId();

        for (uint32 i; i < batch; ) {
            uint32 tokenOffset = cursor + i;
            uint32 traitsPacked = nft.tokenTraitsPacked(baseTokenId + tokenOffset);
            uint8 t0 = uint8(traitsPacked);
            uint8 t1 = uint8(traitsPacked >> 8);
            uint8 t2 = uint8(traitsPacked >> 16);
            uint8 t3 = uint8(traitsPacked >> 24);

            unchecked {
                ++localCounts[t0];
                ++localCounts[t1];
                ++localCounts[t2];
                ++localCounts[t3];
                ++i;
            }
        }

        uint32[256] storage remainingCounts = traitRemaining;
        for (uint16 traitId; traitId < 256; ) {
            uint32 incoming = localCounts[traitId];
            if (incoming != 0) {
                if (startingSlice) {
                    remainingCounts[traitId] = incoming;
                } else {
                    remainingCounts[traitId] += incoming;
                }
            }
            unchecked {
                ++traitId;
            }
        }

        traitRebuildCursor = cursor + batch;
        finished = (traitRebuildCursor == target);
        if (finished) {
            traitCountsShouldOverwrite = false;
        } else if (startingSlice) {
            // After the first slice we always accumulate, leveraging that all traits were hit once.
            traitCountsShouldOverwrite = false;
        }
    }

    function _consumeTrait(uint8 traitId, uint32 endLevel) private returns (bool reachedZero) {
        uint32 stored = traitRemaining[traitId];

        unchecked {
            stored -= 1;
        }
        traitRemaining[traitId] = stored;
        return stored == endLevel;
    }

    /// @notice Generate `count` random “map symbols” for `player`, record tickets & contributions.
    /// @dev
    /// - Uses a xorshift* PRNG seeded per 16‑symbol group from `(baseKey + group, entropyWord)`.
    /// - Each symbol maps to one of 256 trait buckets (0..63 | 64..127 | 128..191 | 192..255) via `_getTrait`.
    /// - After counting occurrences per trait in memory, appends `player` into the purge ticket list
    ///   for each touched trait exactly `occurrences` times and increases contribution counters.
    /// @param player      Recipient whose tickets/contributions are updated.
    /// @param baseKey     Per‑player base key (e.g., derived from `baseTokenId` and player index).
    /// @param startIndex  Starting symbol index for this player (resume support).
    /// @param count       Number of symbols to generate in this call.
    /// @param entropyWord Global RNG word for this level-step; combined with `baseKey` for per-group seeds.
    function _raritySymbolBatch(
        address player,
        uint256 baseKey,
        uint32 startIndex,
        uint32 count,
        uint256 entropyWord
    ) private {
        uint32[256] memory counts;
        uint8[256] memory touchedTraits;
        uint16 touchedLen;

        uint32 endIndex = startIndex + count;
        uint32 i = startIndex;

        while (i < endIndex) {
            uint32 groupIdx = i >> 4; // per 16 symbols

            uint256 seed;
            unchecked {
                seed = (baseKey + groupIdx) ^ entropyWord;
            }
            uint64 s = uint64(seed) | 1;
            uint8 offset = uint8(i & 15);
            unchecked {
                s = s * (MAP_LCG_MULT + uint64(offset)) + uint64(offset);
            }

            for (uint8 j = offset; j < 16 && i < endIndex; ) {
                unchecked {
                    s = s * MAP_LCG_MULT + 1;

                    uint8 quadrant = uint8(i & 3);
                    uint8 traitId = _getTrait(s) + (quadrant << 6);

                    if (counts[traitId]++ == 0) {
                        touchedTraits[touchedLen++] = traitId;
                    }
                    ++i;
                    ++j;
                }
            }
        }

        uint24 lvl = level; // NEW: write into the current level’s buckets

        uint256 levelSlot;
        assembly {
            mstore(0x00, lvl)
            mstore(0x20, traitPurgeTicket.slot)
            levelSlot := keccak256(0x00, 0x40)
        }

        // One length SSTORE per touched trait, then contiguous ticket writes
        for (uint16 u; u < touchedLen; ) {
            uint8 traitId = touchedTraits[u];
            uint32 occurrences = counts[traitId];

            assembly {
                let elem := add(levelSlot, traitId)
                let len := sload(elem)
                sstore(elem, add(len, occurrences))

                mstore(0x00, elem)
                let data := keccak256(0x00, 0x20)
                for {
                    let k := 0
                } lt(k, occurrences) {
                    k := add(k, 1)
                } {
                    sstore(add(data, add(len, k)), player)
                }
            }
            unchecked {
                ++u;
            }
        }
    }

    // --- Trait weighting / helpers -------------------------------------------------------------------

    /// @notice Map a 32-bit random input to an 0..7 bucket with a fixed piecewise distribution.
    /// @dev Distribution over 75 slots: [10,10,10,10,9,9,9,8] -> buckets 0..7 respectively.
    function _w8(uint32 rnd) private pure returns (uint8) {
        unchecked {
            uint32 scaled = uint32((uint64(rnd) * 75) >> 32);
            if (scaled < 10) return 0;
            if (scaled < 20) return 1;
            if (scaled < 30) return 2;
            if (scaled < 40) return 3;
            if (scaled < 49) return 4;
            if (scaled < 58) return 5;
            if (scaled < 67) return 6;
            return 7;
        }
    }

    /// @notice Produce a 6-bit trait id from a 64-bit random value.
    /// @dev High‑level: two weighted 3‑bit values (category, sub) -> pack to a single 6‑bit trait.
    function _getTrait(uint64 rnd) private pure returns (uint8) {
        uint8 category = _w8(uint32(rnd));
        uint8 sub = _w8(uint32(rnd >> 32));
        return (category << 3) | sub;
    }

    function getLastExterminatedTrait() external view returns (uint16) {
        return lastExterminatedTrait;
    }

    function getTraitRemainingQuad(
        uint8[4] calldata traitIds
    ) external view returns (uint16 lastExterminated, uint24 currentLevel, uint32[4] memory remaining) {
        currentLevel = level;
        lastExterminated = lastExterminatedTrait;
        remaining[0] = traitRemaining[traitIds[0]];
        remaining[1] = traitRemaining[traitIds[1]];
        remaining[2] = traitRemaining[traitIds[2]];
        remaining[3] = traitRemaining[traitIds[3]];
    }

    function getTickets(
        uint8 trait,
        uint24 lvl,
        uint32 offset,
        uint32 limit,
        address player
    ) external view returns (uint24 count, uint32 nextOffset, uint32 total) {
        address[] storage a = traitPurgeTicket[lvl][trait];
        total = uint32(a.length);
        if (offset >= total) return (0, total, total);

        uint256 end = offset + limit;
        if (end > total) end = total;

        for (uint256 i = offset; i < end; ) {
            if (a[i] == player) count++;
            unchecked {
                ++i;
            }
        }
        nextOffset = uint32(end);
    }

    /// @notice Return pending mints/maps owed to a player (airdrop queues).
    function getPlayerPurchases(address player) external view returns (uint32 mints, uint32 maps) {
        mints = nft.tokensOwed(player);
        maps = playerMapMintsOwed[player];
    }
    receive() external payable {
        carryOver += msg.value;
    }
}
