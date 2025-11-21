// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeTraitUtils} from "./PurgeTraitUtils.sol";
import {IPurgeGameNFT} from "./PurgeGameNFT.sol";
import {IPurgeGameTrophies} from "./PurgeGameTrophies.sol";
import {IPurgeCoinModule, IPurgeGameTrophiesModule} from "./modules/PurgeGameModuleInterfaces.sol";
import {IPurgeCoin} from "./interfaces/IPurgeCoin.sol";
import {IPurgeRendererLike} from "./interfaces/IPurgeRendererLike.sol";
import {IPurgeGameEndgameModule, IPurgeGameJackpotModule} from "./interfaces/IPurgeGameModules.sol";
import {PurgeGameStorage} from "./storage/PurgeGameStorage.sol";

/**
 * @title Purge Game — Core NFT game contract
 * @notice This file defines the on-chain game logic surface (interfaces + core state).
 */

// ===========================================================================
// External Interfaces
// ===========================================================================

struct VRFRandomWordsRequest {
    bytes32 keyHash;
    uint256 subId;
    uint16 requestConfirmations;
    uint32 callbackGasLimit;
    uint32 numWords;
    bytes extraArgs;
}

interface IVRFCoordinator {
    function requestRandomWords(VRFRandomWordsRequest calldata request) external returns (uint256);

    function getSubscription(
        uint256 subId
    )
        external
        view
        returns (uint96 balance, uint96 premium, uint64 reqCount, address owner, address[] memory consumers);
}

interface ILinkToken {
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);
}
// ===========================================================================
// Contract
// ===========================================================================

contract PurgeGame is PurgeGameStorage {
    // -----------------------
    // Custom Errors
    // -----------------------
    error E(); // Generic guard (reverts in multiple paths)
    error MustMintToday(); // Caller must have completed an ETH mint for the current day before advancing
    error NotTimeYet(); // Called in a phase where the action is not permitted
    error RngNotReady(); // VRF request still pending
    error InvalidQuantity(); // Invalid quantity or token count for the action
    error CoinPaused(); // LINK top-ups unavailable while RNG is locked

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
    IVRFCoordinator private immutable vrfCoordinator; // Chainlink VRF coordinator
    bytes32 private immutable vrfKeyHash; // VRF key hash
    uint256 private immutable vrfSubscriptionId; // VRF subscription identifier
    address private immutable linkToken; // LINK token contract for top-ups

    // -----------------------
    // Game Constants
    // -----------------------
    uint48 private constant JACKPOT_RESET_TIME = 82620; // Offset anchor for "daily" windows
    uint32 private constant WRITES_BUDGET_SAFE = 800; // Keeps map batching within the ~15M gas budget
    uint32 private constant TRAIT_REBUILD_TOKENS_PER_TX = 1800; // Max tokens processed per trait rebuild slice
    uint64 private constant MAP_LCG_MULT = 0x5851F42D4C957F2D; // LCG multiplier for map RNG slices
    uint8 private constant JACKPOTS_PER_DAY = 5;
    uint8 private constant JACKPOT_LEVEL_CAP = 10;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint8 private constant EARLY_PURGE_UNLOCK_PERCENT = 30; // 30% early-purge threshold gate
    uint256 private constant COIN_BASE_UNIT = 1_000_000; // 1 PURGED (6 decimals)
    uint256 private constant LUCK_PER_LINK = 220 * COIN_BASE_UNIT; // flip credit per LINK before multiplier
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;

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
        address jackpotModule_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint256 vrfSubscriptionId_,
        address linkToken_
    ) {
        coin = IPurgeCoin(purgeCoinContract);
        renderer = IPurgeRendererLike(renderer_);
        nft = IPurgeGameNFT(nftContract);
        trophies = IPurgeGameTrophies(trophiesContract);
        if (endgameModule_ == address(0)) revert E();
        endgameModule = endgameModule_;
        if (jackpotModule_ == address(0)) revert E();
        jackpotModule = jackpotModule_;
        if (vrfCoordinator_ == address(0) || linkToken_ == address(0)) revert E();
        vrfCoordinator = IVRFCoordinator(vrfCoordinator_);
        vrfKeyHash = vrfKeyHash_;
        vrfSubscriptionId = vrfSubscriptionId_;
        linkToken = linkToken_;
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

    function purchaseMultiplier() external view returns (uint32) {
        uint32 multiplier = airdropMultiplier;
        return multiplier == 0 ? 1 : multiplier;
    }

    function rngLocked() public view returns (bool) {
        return rngLockedFlag;
    }

    function currentRngWord() public view returns (uint256) {
        return rngFulfilled ? rngWordCurrent : 0;
    }

    function isRngFulfilled() external view returns (bool) {
        return rngFulfilled;
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

    function recordMint(
        address player,
        uint24 lvl,
        bool creditNext,
        bool coinMint
    ) external payable returns (uint256 coinReward) {
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

    /// @notice Advances the game state machine. Anyone can call, but standard flows
    ///         require the caller to have completed an ETH mint for the current day.
    /// @param cap Emergency unstuck function, in case a necessary transaction is too large for a block.
    ///            Using cap removes Purgecoin payment.
    function advanceGame(uint32 cap) external {
        address caller = msg.sender;
        uint48 ts = uint48(block.timestamp);
        IPurgeCoin coinContract = coin;
        // Liveness drain
        if (ts - 365 days > levelStartTime) {
            gameState = 0;
            uint256 bal = address(this).balance;
            if (bal > 0) coinContract.burnie{value: bal}(0);
        }
        uint24 lvl = level;
        uint8 _gameState = gameState;
        uint8 _phase = phase;

        uint48 day = uint48((ts - JACKPOT_RESET_TIME) / 1 days);
        uint48 gateIdx = dailyIdx;
        uint32 currentDay = uint32(day);
        uint32 minAllowedDay = gateIdx == 0 ? currentDay : uint32(gateIdx);

        do {
            if (cap == 0) {
                uint256 mintData = mintPacked_[caller];
                uint32 lastEthDay = uint32((mintData >> ETH_DAY_SHIFT) & MINT_MASK_32);
                if ((lastEthDay < minAllowedDay || ((lastEthDay > currentDay) && cap == 0))) revert MustMintToday();
            }
            uint256 rngWord = rngAndTimeGate(day);
            if (rngWord == 1) {
                break;
            }
            // --- State 1 - Pregame ---
            if (_gameState == 1) {
                (, bool dormantWorked) = nft.processDormant(cap);
                if (dormantWorked) {
                    break;
                }
                _runEndgameModule(lvl, cap, day, rngWord); // handles payouts, wipes, endgame dist, and jackpots
                if (!firstEarlyJackpotPaid && pendingEndLevel.level == 0) {
                    payDailyJackpot(false, level, rngWord);
                }
                if (gameState == 2 && pendingEndLevel.level == 0 && rngLockedFlag) {
                    dailyIdx = day;
                    _unlockRng();
                }
                break;
            }

            // --- State 2 - Purchase / Airdrop ---
            if (_gameState == 2) {
                if (_phase <= 2) {
                    bool advanceToAirdrop;
                    bool flipsPending = coinContract.coinflipWorkPending(lvl);
                    if (_phase == 2 && prizePool >= lastPrizePool) {
                        if (flipsPending) {
                            coinContract.processCoinflipPayouts(lvl, cap, true, rngWord, day);
                            break;
                        }
                        advanceToAirdrop = true;
                    } else if (flipsPending) {
                        coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day);
                        break;
                    }

                    bool batchesPending = airdropIndex < pendingMapMints.length;
                    if (batchesPending) {
                        bool batchesFinished = _processMapBatch(cap);
                        if (!batchesFinished) break;
                        batchesPending = false;
                    }
                    payDailyJackpot(false, lvl, rngWord);

                    if (advanceToAirdrop && !batchesPending) {
                        airdropMultiplier = _calculateAirdropMultiplier(nft.purchaseCount());
                        phase = 3;
                    }
                    dailyIdx = day;
                    _unlockRng();

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
                    if (coinContract.coinflipWorkPending(lvl)) {
                        coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day);
                        break;
                    }
                    uint256 mapEffectiveWei = _calcPrizePoolForJackpot(lvl, rngWord);
                    if (payMapJackpot(lvl, rngWord, mapEffectiveWei)) {
                        phase = 5;
                    }
                    break;
                }
                uint32 purchaseCountRaw = nft.purchaseCount();
                if (_phase == 5) {
                    if (!traitCountsSeedQueued) {
                        if (!nft.processPendingMints(cap)) {
                            break;
                        }
                        if (purchaseCountRaw != 0) {
                            traitCountsSeedQueued = true;
                            traitRebuildCursor = 0;
                        }
                    }

                    if (traitCountsSeedQueued) {
                        uint32 targetCount = _purchaseTargetCountFromRaw(purchaseCountRaw);
                        if (traitRebuildCursor < targetCount) {
                            _rebuildTraitCounts(cap, targetCount);
                            break;
                        }
                        _seedTraitCounts();
                        traitCountsSeedQueued = false;
                    }

                    delete pendingMapMints;
                    airdropIndex = 0;
                    airdropMapsProcessedCount = 0;
                    earlyPurgePercent = 0;
                    phase = 6;
                    break;
                }

                levelStartTime = ts;
                uint32 mintedCount = _purchaseTargetCountFromRaw(nft.purchaseCount());
                nft.finalizePurchasePhase(mintedCount);
                dailyIdx = day;
                traitRebuildCursor = 0;
                airdropMultiplier = 1;
                gameState = 3;
                firstPurgeJackpotPaid = false;
                _unlockRng();
                break;
            }

            // --- State 3 - Purge ---
            if (_gameState == 3) {
                // Purge begins only after phase 6 is latched during purchase finalization.
                uint24 coinflipLevel = uint24(lvl + (jackpotCounter >= 9 ? 1 : 0));
                if (coinContract.coinflipWorkPending(coinflipLevel)) {
                    coinContract.processCoinflipPayouts(coinflipLevel, cap, false, rngWord, day);
                    break;
                }

                bool batchesPending = airdropIndex < pendingMapMints.length;
                if (batchesPending) {
                    bool batchesFinished = _processMapBatch(cap);
                    if (!batchesFinished) break;
                }

                payDailyJackpot(true, lvl, rngWord);
                if (!_handleJackpotLevelCap() || gameState != 3) break;
                dailyIdx = day;
                _unlockRng();
                break;
            }

            // --- State 0 ---
            if (_gameState == 0) {
                if (coinContract.coinflipWorkPending(lvl)) {
                    coinContract.processCoinflipPayouts(lvl, cap, false, rngWord, day);
                    break;
                }
            }
        } while (false);

        emit Advance(_gameState, _phase);

        if (_gameState != 0 && cap == 0) coinContract.bonusCoinflip(caller, priceCoin, false);
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
        if (rngLockedFlag) revert RngNotReady();
        if (gameState != 3) revert NotTimeYet();

        uint256 count = tokenIds.length;
        if (count == 0 || count > 75) revert InvalidQuantity();
        address caller = msg.sender;
        nft.purge(caller, tokenIds);
        coin.notifyQuestPurge(caller, uint32(count));

        uint24 lvl = level;
        uint8 mod10 = uint8(lvl % 10);
        bool isSeventhStep = mod10 == 7;
        bool isDoubleCountStep = mod10 == 2;
        bool levelNinety = (lvl == 90);
        uint32 endLevelFlag = isSeventhStep ? 1 : 0;
        uint256 priceCoinLocal = priceCoin;
        uint16 prevExterminated = lastExterminatedTrait;

        uint256 bonusTenths;
        uint256 stakeBonusCoin;

        address[][256] storage tickets = traitPurgeTicket[lvl];
        IPurgeGameTrophies trophiesContract = trophies;
        bool hasExterminatorStake = trophiesContract.hasExterminatorStake(caller);

        uint16 winningTrait = TRAIT_ID_TIMEOUT;
        for (uint256 i; i < count; ) {
            uint256 tokenId = tokenIds[i];

            uint32 traitPack = _traitsForToken(tokenId);
            uint8 trait0 = uint8(traitPack);
            uint8 trait1 = uint8(traitPack >> 8);
            uint8 trait2 = uint8(traitPack >> 16);
            uint8 trait3 = uint8(traitPack >> 24);

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

            if (hasExterminatorStake) {
                uint8 levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait0));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoinLocal * uint256(levelPercent)) / 100;
                    }
                }
                levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait1));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoinLocal * uint256(levelPercent)) / 100;
                    }
                }
                levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait2));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoinLocal * uint256(levelPercent)) / 100;
                    }
                }
                levelPercent = trophiesContract.handleExterminatorTraitPurge(caller, uint16(trait3));
                if (levelPercent != 0) {
                    unchecked {
                        stakeBonusCoin += (priceCoinLocal * uint256(levelPercent)) / 100;
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
        _creditPurgeFlip(caller, stakeBonusCoin, priceCoinLocal, count, bonusTenths);
        emit Purge(caller, tokenIds);

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
            pend.sidePool = 0;

            if (poolCarry != 0) {
                carryOver += poolCarry;
            }
            prizePool = 0;
            lastExterminatedTrait = TRAIT_ID_TIMEOUT;
        }

        dailyJackpotBase = 0;
        dailyJackpotPaid = 0;

        trophies.prepareNextLevel(levelSnapshot + 1);

        unchecked {
            levelSnapshot++;
            level++;
        }

        if (level == 100 && !decimatorHundredReady) {
            decimatorHundredPool = carryOver;
            carryOver = 0;
            decimatorHundredReady = true;
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
        firstEarlyJackpotPaid = false;
    }

    /// @notice Delegatecall into the endgame module to resolve slow settlement paths.
    function _runEndgameModule(uint24 lvl, uint32 cap, uint48 day, uint256 rngWord) internal {
        (bool ok, ) = endgameModule.delegatecall(
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
        if (!ok) revert E();
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

    function _recordMintData(address player, uint24 lvl, bool coinMint) private returns (uint256 coinReward) {
        uint256 prevData = mintPacked_[player];
        uint32 day = _currentMintDay();
        uint256 data;

        if (coinMint) {
            data = _applyMintDay(prevData, day, COIN_DAY_SHIFT, MINT_MASK_32, COIN_DAY_STREAK_SHIFT, MINT_MASK_20);
        } else {
            uint24 prevLevel = uint24((prevData >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
            uint24 total = uint24((prevData >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
            uint24 streak = uint24((prevData >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);

            data = _applyMintDay(prevData, day, ETH_DAY_SHIFT, MINT_MASK_32, ETH_DAY_STREAK_SHIFT, MINT_MASK_20);

            if (prevLevel == lvl) {
                if (data != prevData) {
                    mintPacked_[player] = data;
                }
                return coinReward;
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
                    coinReward += streakReward + totalReward;
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
        return coinReward;
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
                IPurgeGameTrophiesModule(address(trophies))
            )
        );
        if (!ok) revert E();
        return abi.decode(data, (bool));
    }

    function _calcPrizePoolForJackpot(uint24 lvl, uint256 rngWord) internal returns (uint256 effectiveWei) {
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
                IPurgeGameTrophiesModule(address(trophies))
            )
        );
        if (!ok) revert E();
    }

    function _handleJackpotLevelCap() internal returns (bool) {
        if (jackpotCounter >= JACKPOT_LEVEL_CAP) {
            _endLevel(TRAIT_ID_TIMEOUT);
            return false;
        }
        return true;
    }

    // --- Flips, VRF, payments, rarity ----------------------------------------------------------------

    function rngAndTimeGate(uint48 day) internal returns (uint256 word) {
        if (day == dailyIdx) revert NotTimeYet();

        uint256 currentWord = currentRngWord();

        if (currentWord == 0) {
            if (rngLockedFlag) revert RngNotReady();
            _requestRng();
            return 1;
        }

        if (!rngLockedFlag) {
            // Stale entropy from previous cycle; request a fresh word.
            _requestRng();
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
    function _processMapBatch(uint32 writesBudget) internal returns (bool finished) {
        uint256 total = pendingMapMints.length;
        if (airdropIndex >= total) return true;

        if (writesBudget == 0) writesBudget = WRITES_BUDGET_SAFE;
        uint24 lvl = level;
        if (gameState == 3) {
            unchecked {
                ++lvl;
            }
        }
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
        uint256 entropy = currentRngWord();

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

            uint32 remainingOwed;
            unchecked {
                remainingOwed = owed - take;
                playerMapMintsOwed[player] = remainingOwed;
                airdropMapsProcessedCount += take;
                used += writesThis;
            }
            if (remainingOwed == 0) {
                unchecked {
                    ++airdropIndex;
                }
                airdropMapsProcessedCount = 0;
            }
        }
        return airdropIndex >= total;
    }

    function _requestRng() private {
        uint256 id = vrfCoordinator.requestRandomWords(
            VRFRandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
                numWords: 1,
                extraArgs: bytes("")
            })
        );
        vrfRequestId = id;
        rngFulfilled = false;
        rngWordCurrent = 0;
        rngLockedFlag = true;
    }

    function _unlockRng() private {
        rngLockedFlag = false;
        vrfRequestId = 0;
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert E();
        if (requestId != vrfRequestId || rngFulfilled) return;
        rngFulfilled = true;
        rngWordCurrent = randomWords[0];
    }

    function _creditPurgeFlip(
        address caller,
        uint256 stakeBonusCoin,
        uint256 priceCoinLocal,
        uint256 count,
        uint256 bonusTenths
    ) private {
        uint256 priceUnit = priceCoinLocal / 10;
        uint256 flipCredit = stakeBonusCoin;
        unchecked {
            flipCredit += (count + bonusTenths) * priceUnit;
        }

        coin.bonusCoinflip(caller, flipCredit, true);
    }

    function onTokenTransfer(address from, uint256 amount, bytes calldata) external {
        if (msg.sender != linkToken) revert E();
        if (amount == 0) revert E();
        if (rngLockedFlag) revert CoinPaused();

        try
            ILinkToken(linkToken).transferAndCall(address(vrfCoordinator), amount, abi.encode(vrfSubscriptionId))
        returns (bool ok) {
            if (!ok) revert E();
        } catch {
            revert E();
        }
        (uint96 bal, , , , ) = vrfCoordinator.getSubscription(vrfSubscriptionId);
        uint16 mult = _tierMultPermille(uint256(bal));
        if (mult == 0) return;
        uint256 baseCredit = (amount * LUCK_PER_LINK) / 1 ether;
        uint256 credit = (baseCredit * mult) / 1000;
        if (credit != 0) {
            coin.bonusCoinflip(from, credit, true);
        }
    }

    function _tierMultPermille(uint256 subBal) private pure returns (uint16) {
        if (subBal < 100 ether) return 2000;
        if (subBal < 200 ether) return 1500;
        if (subBal < 600 ether) return 1000;
        if (subBal < 1000 ether) return 500;
        if (subBal < 2000 ether) return 100;
        return 0;
    }

    function _traitWeight(uint32 rnd) private pure returns (uint8) {
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

    function _deriveTrait(uint64 rnd) private pure returns (uint8) {
        uint8 category = _traitWeight(uint32(rnd));
        uint8 sub = _traitWeight(uint32(rnd >> 32));
        return (category << 3) | sub;
    }

    function _traitsForToken(uint256 tokenId) private pure returns (uint32 packed) {
        uint256 rand = uint256(keccak256(abi.encodePacked(tokenId)));
        uint8 trait0 = _deriveTrait(uint64(rand));
        uint8 trait1 = _deriveTrait(uint64(rand >> 64)) | 64;
        uint8 trait2 = _deriveTrait(uint64(rand >> 128)) | 128;
        uint8 trait3 = _deriveTrait(uint64(rand >> 192)) | 192;
        packed = uint32(trait0) | (uint32(trait1) << 8) | (uint32(trait2) << 16) | (uint32(trait3) << 24);
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
    function _rebuildTraitCounts(uint32 tokenBudget, uint32 target) private returns (bool finished) {
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
            uint32 traitPack = _traitsForToken(baseTokenId + tokenOffset);
            uint8 t0 = uint8(traitPack);
            uint8 t1 = uint8(traitPack >> 8);
            uint8 t2 = uint8(traitPack >> 16);
            uint8 t3 = uint8(traitPack >> 24);

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

    function _calculateAirdropMultiplier(uint32 purchaseCount) private pure returns (uint32) {
        if (purchaseCount == 0) {
            return 1;
        }
        if (purchaseCount >= 5000) {
            return 1;
        }
        uint256 numerator = 5000 + uint256(purchaseCount) - 1;
        uint32 multiplier = uint32(numerator / purchaseCount);
        return multiplier == 0 ? 1 : multiplier;
    }

    function _purchaseTargetCountFromRaw(uint32 rawCount) private view returns (uint32) {
        if (rawCount == 0) {
            return 0;
        }
        uint32 multiplier = airdropMultiplier == 0 ? 1 : airdropMultiplier;
        uint256 scaled = uint256(rawCount) * uint256(multiplier);
        if (scaled > type(uint32).max) revert E();
        return uint32(scaled);
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
    /// - Each symbol maps to one of 256 trait buckets (0..63 | 64..127 | 128..191 | 192..255) via `PurgeTraitUtils.traitFromWord`.
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
                    uint8 traitId = PurgeTraitUtils.traitFromWord(s) + (quadrant << 6);

                    if (counts[traitId]++ == 0) {
                        touchedTraits[touchedLen++] = traitId;
                    }
                    ++i;
                    ++j;
                }
            }
        }

        uint24 lvl = uint24(baseKey >> 224); // level is encoded into the base key

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
