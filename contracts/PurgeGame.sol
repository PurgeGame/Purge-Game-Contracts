// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameNFT} from "./PurgeGameNFT.sol";
import {IPurgeCoinModule} from "./interfaces/PurgeGameModuleInterfaces.sol";
import {IPurgeCoin} from "./interfaces/IPurgeCoin.sol";
import {IPurgeAffiliate} from "./interfaces/IPurgeAffiliate.sol";
import {IPurgeRendererLike} from "./interfaces/IPurgeRendererLike.sol";
import {IPurgeJackpots} from "./interfaces/IPurgeJackpots.sol";
import {IPurgeTrophies} from "./interfaces/IPurgeTrophies.sol";
import {IPurgeGameEndgameModule, IPurgeGameJackpotModule} from "./interfaces/IPurgeGameModules.sol";
import {MintPaymentKind} from "./interfaces/IPurgeGame.sol";
import {PurgeGameExternalOp} from "./interfaces/IPurgeGameExternal.sol";
import {PurgeGameStorage, ClaimableBondInfo} from "./storage/PurgeGameStorage.sol";
import {PurgeGameCredit} from "./utils/PurgeGameCredit.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPurgeBonds {
    function payBonds(
        uint256 coinAmount,
        uint256 stEthAmount,
        uint48 rngDay,
        uint256 rngWord,
        uint256 maxBonds
    ) external payable;
    function resolvePendingBonds(uint256 maxBonds) external;
    function resolvePending() external view returns (bool);
    function notifyGameOver() external;
    function finalizeShutdown(uint256 maxIds) external returns (uint256 processedIds, uint256 burned, bool complete);
    function setTransfersLocked(bool locked, uint48 rngDay) external;
    function stakeRateBps() external view returns (uint16);
    function purchasesEnabled() external view returns (bool);
    function purchaseGameBonds(
        address[] calldata recipients,
        uint256 quantity,
        uint256 basePerBondWei,
        bool stake
    ) external returns (uint256 startTokenId);
}

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
    error RngLocked(); // RNG is already locked; nudge not allowed
    error BondsNotResolved(); // Pending bond resolution must be completed before requesting new RNG
    error InvalidQuantity(); // Invalid quantity or token count for the action
    error CoinPaused(); // LINK top-ups unavailable while RNG is locked
    error VrfUpdateNotReady(); // VRF swap not allowed yet (not stuck long enough or randomness already received)

    // -----------------------
    // Events
    // -----------------------
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);
    event BondCreditAdded(address indexed player, uint256 amount);
    event Jackpot(uint256 traits); // Encodes jackpot metadata
    event Purge(address indexed player, uint256[] tokenIds);
    event Advance(uint8 gameState, uint8 phase);
    event ReverseFlip(address indexed caller, uint256 totalQueued, uint256 cost);
    event VrfCoordinatorUpdated(address indexed previous, address indexed current);
    event PrizePoolBondBuy(uint256 spendWei, uint256 quantity);

    // -----------------------
    // Immutable Addresses
    // -----------------------
    IPurgeRendererLike private immutable renderer; // Trusted renderer; used for tokenURI composition
    IPurgeCoin private immutable coin; // Trusted coin/game-side coordinator (PURGE ERC20)
    IPurgeGameNFT private immutable nft; // ERC721 interface for mint/burn/metadata surface
    address public immutable bonds; // Bond contract for resolution and metadata
    address private immutable affiliateProgram; // Cached affiliate program for payout routing
    IStETH private immutable steth; // stETH token held by the game
    address private immutable jackpots; // PurgeJackpots contract
    address private immutable endgameModule; // Delegate module for endgame settlement
    address private immutable jackpotModule; // Delegate module for jackpot routines
    IVRFCoordinator private vrfCoordinator; // Chainlink VRF coordinator (mutable for emergencies)
    bytes32 private immutable vrfKeyHash; // VRF key hash
    uint256 private immutable vrfSubscriptionId; // VRF subscription identifier
    address private immutable linkToken; // LINK token contract for top-ups
    // Trusted collaborators: coin/nft/jackpots/modules are expected to be non-reentrant and non-malicious.

    uint256 private constant DEPLOY_IDLE_TIMEOUT = (365 days * 5) / 2; // 2.5 years
    uint48 private constant LEVEL_START_SENTINEL = type(uint48).max;
    uint16 private constant BOND_LIQUIDATION_DISCOUNT_BPS = 6500; // 65% of face value when liquidating bond credit to coin

    // -----------------------
    // Game Constants
    // -----------------------
    uint48 private constant JACKPOT_RESET_TIME = 82620; // "Day" windows are offset from unix midnight by this anchor
    uint32 private constant TRAIT_REBUILD_TOKENS_PER_TX = 2500; // Max tokens processed per trait rebuild slice (post-level-1)
    uint32 private constant TRAIT_REBUILD_TOKENS_LEVEL1 = 1800; // Level 1 first-slice cap
    uint8 private constant JACKPOT_LEVEL_CAP = 10;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100;
    uint16 private constant LUCK_PER_LINK_PERCENT = 22; // flip credit per LINK before multiplier (as % of priceCoin)
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;
    uint256 private constant RNG_NUDGE_BASE_COST = 100 * 1e6; // PURGE has 6 decimals
    uint256 private constant REWARD_POOL_MIN_STAKE = 0.5 ether;
    uint256 private constant BOND_RNG_RESOLVE_LIMIT = 150; // mirrors bonds GAS_LIMITED_RESOLVE_MAX
    uint8 private constant BOND_RNG_RESOLVE_PASSES = 3; // cap iterations to stay gas-safe
    uint16 private constant PRIZE_POOL_BOND_BPS_PER_DAILY = 20; // 0.2% per daily (~2% total across 10) = 10% of the ~20% daily float
    uint256 private constant PRIZE_POOL_BOND_BASE = 0.02 ether;

    // mintPacked_ layout (LSB ->):
    // [0-23]=last ETH level, [24-47]=total ETH level count, [48-71]=ETH level streak,
    // [72-103]=last ETH day, [104-123]=ETH day streak, [124-155]=last COIN day,
    // [156-175]=COIN day streak, [176-207]=aggregate last day, [208-227]=aggregate day streak,
    // [228-243]=units minted at current level, [244]=level bonus paid flag.
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant MINT_MASK_16 = (uint256(1) << 16) - 1;
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
    uint256 private constant ETH_LEVEL_UNITS_SHIFT = 228;
    uint256 private constant ETH_LEVEL_BONUS_SHIFT = 244;

    // -----------------------
    // Constructor
    // -----------------------

    /**
     * @param purgeCoinContract Trusted PURGE ERC20 / game coordinator address
     * @param renderer_         Trusted on-chain renderer
     * @param nftContract       ERC721 game contract
     * @param endgameModule_    Delegate module handling endgame settlement
     * @param jackpotModule_    Delegate module handling jackpot distribution
     * @param vrfCoordinator_   Chainlink VRF coordinator
     * @param vrfKeyHash_       VRF key hash
     * @param vrfSubscriptionId_ VRF subscription identifier
     * @param linkToken_        LINK token contract (ERC677) for VRF billing
     * @param stEthToken_       stETH token address
     * @param jackpots_         PurgeJackpots contract address (wires Decimator/BAF jackpots)
     * @param bonds_            Bonds contract address
     * @param trophies_         Standalone trophy ERC721 contract (cosmetic only)
     */
    constructor(
        address purgeCoinContract,
        address renderer_,
        address nftContract,
        address endgameModule_,
        address jackpotModule_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint256 vrfSubscriptionId_,
        address linkToken_,
        address stEthToken_,
        address jackpots_,
        address bonds_,
        address trophies_
    ) {
        coin = IPurgeCoin(purgeCoinContract);
        renderer = IPurgeRendererLike(renderer_);
        nft = IPurgeGameNFT(nftContract);
        endgameModule = endgameModule_;
        jackpotModule = jackpotModule_;
        vrfCoordinator = IVRFCoordinator(vrfCoordinator_);
        affiliateProgram = coin.affiliateProgram();
        affiliateProgramAddr = affiliateProgram;
        vrfKeyHash = vrfKeyHash_;
        vrfSubscriptionId = vrfSubscriptionId_;
        linkToken = linkToken_;
        steth = IStETH(stEthToken_);
        if (stEthToken_ == address(0) || jackpots_ == address(0) || bonds_ == address(0) || trophies_ == address(0))
            revert E();
        jackpots = jackpots_;
        bonds = bonds_;
        trophies = trophies_;
        if (!steth.approve(bonds_, type(uint256).max)) revert E();
        deployTimestamp = uint48(block.timestamp);
    }

    // --- View: lightweight game status -------------------------------------------------

    function jackpotCounterView() external view returns (uint8) {
        return jackpotCounter;
    }

    function rewardPoolView() external view returns (uint256) {
        return rewardPool;
    }

    function prizePoolTargetView() external view returns (uint256) {
        return lastPrizePool;
    }

    function prizePoolCurrentView() external view returns (uint256) {
        return currentPrizePool;
    }

    function nextPrizePoolView() external view returns (uint256) {
        return nextPrizePool;
    }

    function trophiesAddress() external view returns (address) {
        return trophies;
    }

    function affiliateProgramAddress() external view returns (address) {
        return affiliateProgramAddr;
    }

    /// @notice Resolve the payout recipient for a player, routing synthetic MAP-only players to their affiliate owner.
    function affiliatePayoutAddress(address player) public view returns (address recipient, address affiliateOwner) {
        address affiliateAddr = affiliateProgram;
        if (affiliateAddr == address(0)) {
            return (player, address(0));
        }
        (affiliateOwner, ) = IPurgeAffiliate(affiliateAddr).syntheticMapInfo(player);
        recipient = affiliateOwner == address(0) ? player : affiliateOwner;
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

    function principalStEthBalance() external view returns (uint256) {
        return principalStEth;
    }

    function rngWordForDay(uint48 day) external view returns (uint256) {
        return rngWordByDay[day];
    }

    function getEarlyPurgePercent() external view returns (uint8) {
        return earlyPurgePercent;
    }

    function rngLocked() public view returns (bool) {
        return rngLockedFlag;
    }

    function isRngFulfilled() external view returns (bool) {
        return rngFulfilled;
    }

    function _currentDayIndex() private view returns (uint48) {
        return uint48((uint48(block.timestamp) - JACKPOT_RESET_TIME) / 1 days);
    }

    function _threeDayRngGap(uint48 day) private view returns (bool) {
        if (rngWordByDay[day] != 0) return false;
        if (day == 0 || rngWordByDay[day - 1] != 0) return false;
        if (day < 2 || rngWordByDay[day - 2] != 0) return false;
        return true;
    }

    function decWindow() external view returns (bool on, uint24 lvl) {
        on = decWindowOpen;
        lvl = level;
    }

    function isBafLevelActive(uint24 lvl) external view returns (bool) {
        if (lvl == 0) return false;
        if ((lvl % 10) != 0) return false;
        if (rngLockedFlag && jackpotCounter >= 9) return false; // freeze BAF once the 10th jackpot RNG is in-flight
        return gameState == 3;
    }

    function purchaseInfo()
        external
        view
        returns (uint24 lvl, uint8 gameState_, uint8 phase_, bool rngLocked_, uint256 priceWei, uint256 priceCoinUnit)
    {
        lvl = level;
        gameState_ = gameState;
        phase_ = phase;
        rngLocked_ = rngLockedFlag;
        priceWei = price;
        priceCoinUnit = priceCoin;

        if (gameState_ == 3) {
            unchecked {
                ++lvl;
            }
        }
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

    /// @notice Ticket counts per trait for a given level (useful for paging the arrays off-chain).
    function traitTicketLengths(uint24 lvl) external view returns (uint256[256] memory lengths) {
        address[][256] storage tickets = traitPurgeTicket[lvl];
        for (uint256 i; i < 256; ) {
            lengths[i] = tickets[i].length;
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Paged read of ticket holders for a specific trait at a level.
    function traitTicketSlice(
        uint24 lvl,
        uint8 trait,
        uint256 start,
        uint256 count
    ) external view returns (address[] memory slice) {
        address[] storage arr = traitPurgeTicket[lvl][trait];
        uint256 len = arr.length;
        if (start >= len) return new address[](0);
        uint256 n = count;
        uint256 remaining = len - start;
        if (n > remaining) n = remaining;

        slice = new address[](n);
        for (uint256 i; i < n; ) {
            slice[i] = arr[start + i];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Record a mint, funded by ETH (`msg.value`), claimable winnings, or bond credit.
    /// @dev ETH paths require `msg.value == costWei`. Claimable paths deduct from `claimableWinnings` and fund prize pools.
    ///      Bond credit uses the same `costWei` accounting but does not increase prize pools and must send zero ETH.
    ///      Combined allows any mix of ETH, claimable, and bond credit (in that order) to cover `costWei`.
    function recordMint(
        address player,
        uint24 lvl,
        bool coinMint,
        uint256 costWei,
        uint32 mintUnits,
        MintPaymentKind payKind
    ) external payable returns (uint256 coinReward) {
        if (msg.sender != address(nft)) revert E();

        if (coinMint) {
            if (msg.value != 0 || payKind != MintPaymentKind.DirectEth) revert E();
            return _recordMintData(player, lvl, true, 0);
        }

        uint256 amount = costWei;
        uint256 prizeContribution = _processMintPayment(player, amount, payKind);
        if (prizeContribution != 0) {
            nextPrizePool += prizeContribution;
        }

        coinReward = _recordMintData(player, lvl, false, mintUnits);
    }

    function _processMintPayment(
        address player,
        uint256 amount,
        MintPaymentKind payKind
    ) private returns (uint256 prizeContribution) {
        (bool ok, uint256 prize, uint256 creditUsed) = PurgeGameCredit.processMintPayment(
            claimableWinnings,
            bondCredit,
            player,
            amount,
            payKind,
            msg.value
        );
        if (!ok) revert E();
        if (creditUsed != 0) {
            uint256 escrow = bondCreditEscrow;
            if (escrow != 0) {
                uint256 applied = creditUsed < escrow ? creditUsed : escrow;
                unchecked {
                    prize += applied;
                    bondCreditEscrow = escrow - applied;
                }
            }
        }
        return prize;
    }

    /// @notice Advances the game state machine. Anyone can call, but standard flows
    ///         require the caller to have completed an ETH mint for the current day.
    /// @param cap Emergency unstuck function, in case a necessary transaction is too large for a block.
    ///            Using cap removes Purgecoin payment.
    function advanceGame(uint32 cap) external {
        address caller = msg.sender;
        uint48 ts = uint48(block.timestamp);
        // Day index uses JACKPOT_RESET_TIME offset instead of unix midnight to align jackpots/quests.
        uint48 day = _currentDayIndex();
        IPurgeCoin coinContract = coin;
        uint48 lst = levelStartTime;
        if (lst == LEVEL_START_SENTINEL) {
            uint48 deployTs = deployTimestamp;
            if (
                deployTs != 0 && uint256(ts) >= uint256(deployTs) + DEPLOY_IDLE_TIMEOUT // uint256 to avoid uint48 overflow
            ) {
                _drainToBonds(day);
                gameState = 0;
                return;
            }
        }
        uint8 _gameState = gameState;
        // Liveness drain
        if (ts - 365 days > lst && _gameState != 0) {
            _drainToBonds(day);
            gameState = 0;
        }
        uint24 lvl = level;

        uint8 _phase = phase;

        uint48 gateIdx = dailyIdx;
        uint32 currentDay = uint32(day);
        uint32 minAllowedDay = gateIdx == 0 ? currentDay : uint32(gateIdx);

        do {
            if (cap == 0 && _gameState != 0) {
                uint256 mintData = mintPacked_[caller];
                uint32 lastEthDay = uint32((mintData >> ETH_DAY_SHIFT) & MINT_MASK_32);
                if (lastEthDay < minAllowedDay) revert MustMintToday();
            }

            // Allow dormant cleanup bounty even before the daily gate unlocks. If no work is done,
            // we continue to normal gating and will revert via rngAndTimeGate when not time yet.
            if (_gameState == 1) {
                (, bool dormantWorked) = nft.processDormant(cap);
                if (dormantWorked) {
                    break;
                }
            }

            uint256 rngWord = rngAndTimeGate(day, lvl);
            if (rngWord == 1) {
                break;
            }

            // --- State 1 - Pregame ---
            if (_gameState == 1) {
                _runEndgameModule(lvl, cap, rngWord); // handles payouts, wipes, endgame dist, and jackpots
                if (gameState == 2) {
                    if (lvl != 0) {
                        address topStake = coinContract.recordStakeResolution(lvl, day);
                        address trophyAddr = trophies;
                        if (trophyAddr != address(0) && topStake != address(0)) {
                            try IPurgeTrophies(trophyAddr).mintStake(topStake, lvl) {} catch {}
                        }
                    }
                    if (lastExterminatedTrait != TRAIT_ID_TIMEOUT) {
                        payDailyJackpot(false, level, rngWord);
                    }
                    _stakeForTargetRatio(lvl);
                    bool decOpen = ((lvl >= 25) && ((lvl % 10) == 5) && ((lvl % 100) != 95));
                    // Preserve an already-open window for the level-100 decimator special until its RNG request closes it.
                    if (!decWindowOpen && decOpen) {
                        decWindowOpen = true;
                    }
                    if (lvl % 100 == 99) decWindowOpen = true;
                    _unlockRng(day);
                }
                break;
            }

            // --- State 2 - Purchase / Airdrop ---
            if (_gameState == 2) {
                if (_phase <= 2) {
                    bool advanceToAirdrop = (_phase == 2 && nextPrizePool >= lastPrizePool);

                    bool batchesPending = airdropIndex < pendingMapMints.length;
                    if (batchesPending) {
                        bool batchesFinished = _processMapBatch(cap);
                        if (!batchesFinished) break;
                        batchesPending = false;
                    }
                    payDailyJackpot(false, lvl, rngWord);

                    if (advanceToAirdrop && !batchesPending) {
                        airdropMultiplier = _calculateAirdropMultiplier(nft.purchaseCount(), lvl);
                        phase = 3;
                    }
                    _unlockRng(day);

                    break;
                }

                if (_phase == 3) {
                    bool ranDecHundred;
                    bool decHundredFinished = true;
                    if (lvl % 100 == 0) {
                        ranDecHundred = true;
                        decHundredFinished = _runDecimatorHundredJackpot(lvl, rngWord);
                        if (!decHundredFinished) {
                            break; // keep working this jackpot slice before moving on
                        }
                    }

                    phase = 4;
                    _phase = 4; // fall through to phase 4 logic in the same call when nothing ran
                    if (ranDecHundred && !decHundredFinished) {
                        break; // level-100 decimator work consumes this tick
                    }
                }

                if (_phase == 4) {
                    if (!_processMapBatch(cap)) {
                        break;
                    }
                    uint256 totalWeiForBond = rewardPool + currentPrizePool;
                    if (_bondMaintenanceForMap(day, totalWeiForBond, rngWord, cap)) {
                        break; // bond batch consumed this tick; rerun advanceGame to continue
                    }
                    uint256 mapEffectiveWei = _calcPrizePoolForJackpot(lvl, rngWord);
                    payMapJackpot(lvl, rngWord, mapEffectiveWei);

                    airdropMapsProcessedCount = 0;
                    if (airdropIndex >= pendingMapMints.length) {
                        airdropIndex = 0;
                        delete pendingMapMints;
                    }
                    phase = 5;
                    break;
                }

                if (_phase == 5) {
                    uint32 purchaseCountRaw = nft.purchaseCount();
                    if (!traitCountsSeedQueued) {
                        uint32 multiplier_ = airdropMultiplier;
                        if (!nft.processPendingMints(cap, multiplier_)) {
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

                    uint32 mintedCount = _purchaseTargetCountFromRaw(purchaseCountRaw);
                    nft.finalizePurchasePhase(mintedCount, rngWordCurrent);
                    _maybeResolveBonds(cap);
                    traitRebuildCursor = 0;
                    airdropMultiplier = 1;
                    earlyPurgePercent = 0;
                    levelStartTime = ts;
                    gameState = 3;
                    if (lvl % 100 == 99) decWindowOpen = true;
                    _unlockRng(day); // open RNG after map jackpot is finalized
                }
                break;
            }

            // --- State 3 - Purge ---
            if (_gameState == 3) {
                // Purge begins only after phase 5 is latched during purchase finalization.
                bool batchesPending = airdropIndex < pendingMapMints.length;
                if (batchesPending) {
                    bool batchesFinished = _processMapBatch(cap);
                    if (!batchesFinished) break;
                }

                payDailyJackpot(true, lvl, rngWord);
                if (!_handleJackpotLevelCap()) break;
                _unlockRng(day);
                break;
            }
        } while (false);

        emit Advance(_gameState, _phase);

        if (_gameState != 0 && cap == 0) coinContract.creditFlip(caller, priceCoin >> 1);
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

            bool tokenHasPrevExterminated = prevExterminated != TRAIT_ID_TIMEOUT &&
                (uint16(trait0) == prevExterminated ||
                    uint16(trait1) == prevExterminated ||
                    uint16(trait2) == prevExterminated ||
                    uint16(trait3) == prevExterminated);

            if ((tokenHasPrevExterminated && !levelNinety) || (levelNinety && !tokenHasPrevExterminated)) {
                unchecked {
                    bonusTenths += 4;
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
    /// - Split prize pool: 90% to participants (including the exterminator slice below) and 10% as a bonus
    ///   split across three winning tickets weighted by ETH mint streaks (even split if all streaks are zero).
    ///   From within the 90%, the “exterminator” gets 30% (or 40% on levels where `prevLevel % 10 == 4` and `prevLevel > 4`),
    ///   and the rest is divided evenly per ticket for the exterminated trait.
    ///
    /// When a non-trait end occurs (>=256, e.g. daily jackpots path):
    /// - Carry the remainder forward and reset leaderboards.
    /// - On L%100==0: adjust price and `lastPrizePool`.
    ///
    /// After either path:
    /// - Reset per-level state, set default exterminated sentinel to TRAIT_ID_TIMEOUT, and request fresh VRF.
    function _endLevel(uint16 exterminated) private {
        address callerExterminator = msg.sender;
        uint24 levelSnapshot = level;
        bool traitExterminated = exterminated < 256;
        if (traitExterminated) {
            uint8 exTrait = uint8(exterminated);
            uint16 prevTrait = lastExterminatedTrait;
            bool repeatTrait = prevTrait == uint16(exTrait);
            exterminationInvertFlag = repeatTrait;
            bool repeatOrNinety = (levelSnapshot == 90) ? !repeatTrait : repeatTrait;
            uint256 pool = currentPrizePool;

            if (repeatOrNinety) {
                uint256 keep = pool >> 1;
                rewardPool += keep;
                pool -= keep;
            }

            currentPrizePool = pool;
            _setExterminatorForLevel(levelSnapshot, callerExterminator);

            address trophyAddr = trophies;
            if (trophyAddr != address(0)) {
                try IPurgeTrophies(trophyAddr).mintExterminator(
                    callerExterminator,
                    levelSnapshot,
                    exTrait,
                    exterminationInvertFlag
                ) {} catch {}
            }

            lastExterminatedTrait = exTrait;
        } else {
            exterminationInvertFlag = false;
            _setExterminatorForLevel(levelSnapshot, address(0));

            currentPrizePool = 0;
            lastExterminatedTrait = TRAIT_ID_TIMEOUT;
        }

        if (levelSnapshot % 100 == 0) {
            price = 0.05 ether;
            priceCoin >>= 1;
            lastPrizePool = rewardPool;
        }

        unchecked {
            levelSnapshot++;
            level++;
        }
        traitRebuildCursor = 0;
        jackpotCounter = 0;
        // Reset daily purge counters so the next level's jackpots start fresh.
        for (uint8 i; i < 80; ) {
            dailyPurgeCount[i] = 0;
            unchecked {
                ++i;
            }
        }

        uint256 mod100 = levelSnapshot % 100;
        uint256 mod20 = levelSnapshot % 20;
        if (mod100 == 10 || mod100 == 0) {
            price <<= 1;
        } else if (mod20 == 0) {
            price += (levelSnapshot < 100) ? 0.05 ether : 0.1 ether;
        }

        gameState = 1;
        if (traitExterminated) {
            coin.normalizeActivePurgeQuests();
        }

        uint256 nextId = nft.nextTokenId();
        uint256 base = nft.currentBaseTokenId();
        if (nextId > base) {
            nft.advanceBase(nextId);
        }
    }

    /// @notice Delegatecall into the endgame module to resolve slow settlement paths.
    function _runEndgameModule(uint24 lvl, uint32 cap, uint256 rngWord) internal {
        // Endgame settlement logic lives in PurgeGameEndgameModule (delegatecall keeps state on this contract).
        (bool ok, ) = endgameModule.delegatecall(
            abi.encodeWithSelector(
                IPurgeGameEndgameModule.finalizeEndgame.selector,
                lvl,
                cap,
                rngWord,
                jackpots
            )
        );
        if (!ok) return;
    }

    /// @notice Unified external hook for trusted modules to adjust PurgeGame accounting.
    /// @param op      Operation selector.
    /// @param account Player to credit (when applicable).
    /// @param amount  Wei amount associated with the operation.
    /// @param lvl     Level context for the operation (unused by the game, used by callers).
    function applyExternalOp(PurgeGameExternalOp op, address account, uint256 amount, uint24 lvl) external {
        lvl;
        if (op == PurgeGameExternalOp.DecJackpotClaim) {
            address jackpotsAddr = jackpots;
            if (jackpotsAddr == address(0) || msg.sender != jackpotsAddr) revert E();
            _addClaimableEth(account, amount);
        } else {
            revert E();
        }
    }

    // --- Claiming winnings (ETH) --------------------------------------------------------------------

    /// @notice Claim the caller’s accrued ETH winnings (affiliates, jackpots, endgame payouts).
    /// @dev Leaves a 1 wei sentinel so subsequent credits remain non-zero -> cheaper SSTORE.
    ///      burnCoin runs before zeroing state and assumes the PURGE coin cannot reenter or grief claims.
    function claimWinnings() external {
        address player = msg.sender;
        uint256 amount = claimableWinnings[player];
        if (amount <= 1) revert E();
        coin.burnCoin(player, priceCoin / 10); // Burn cost = 10% of current coin unit price
        _mintClaimableBonds(player, 0);
        uint256 payout;
        unchecked {
            claimableWinnings[player] = 1;
            payout = amount - 1;
        }
        _payoutWithStethFallback(player, payout);
    }

    function getWinnings() external view returns (uint256) {
        uint256 stored = claimableWinnings[msg.sender];
        if (stored <= 1) return 0;
        return stored - 1;
    }

    /// @notice Mint any claimable bond credits without claiming ETH winnings.
    /// @param maxBatches Optional cap on batches processed this call (0 = all).
    function claimBondCredits(uint32 maxBatches) external {
        _mintClaimableBonds(msg.sender, maxBatches);
    }

    function bondCreditOf(address player) external view returns (uint256) {
        return bondCredit[player];
    }

    /// @notice Convert bond credit (earmarked for bonds) into PURGE at a discounted rate.
    /// @param minCoinOut Slippage guard on credited coin.
    function liquidateBondCreditForCoin(uint256 minCoinOut) external {
        ClaimableBondInfo storage info = claimableBondInfo[msg.sender];
        uint256 creditWei = info.weiAmount;
        if (creditWei == 0) revert E();
        uint256 escrow = bondCreditEscrow;
        if (escrow < creditWei) revert E();
        uint256 priceWei = price;
        if (priceWei == 0) revert E();

        uint256 coinOut = (creditWei * priceCoin) / priceWei;
        coinOut = (coinOut * BOND_LIQUIDATION_DISCOUNT_BPS) / 10_000; // apply poor rate
        if (coinOut == 0 || coinOut < minCoinOut) revert E();

        uint256 paidValueWei = (coinOut * priceWei) / priceCoin;
        uint256 profitWei = creditWei > paidValueWei ? (creditWei - paidValueWei) : 0;

        info.weiAmount = 0;
        bondCreditEscrow = escrow - creditWei;
        if (profitWei != 0) {
            uint256 toReward = profitWei / 2;
            rewardPool += toReward;
            unchecked {
                bondCreditEscrow += profitWei - toReward; // bondholder share stays in escrow
            }
        }
        coin.creditFlip(msg.sender, coinOut);
    }

    /// @notice Mint any claimable bonds owed to `player` before paying ETH winnings.
    /// @param maxBatches Ignored (kept for interface parity; single bucket model).
    function _mintClaimableBonds(address player, uint32 maxBatches) private {
        maxBatches; // unused
        ClaimableBondInfo storage info = claimableBondInfo[player];
        uint256 creditWei = info.weiAmount;
        if (creditWei == 0) return;
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) return;
        if (!IPurgeBonds(bondsAddr).purchasesEnabled()) return;

        uint256 base = info.basePerBondWei == 0 ? 0.5 ether : info.basePerBondWei;
        uint256 maxQuantity = creditWei / base;
        uint256 escrow = bondCreditEscrow;
        if (maxQuantity == 0 || escrow < base) return;
        uint256 maxEscrowQty = escrow / base;
        uint256 quantity = maxQuantity < maxEscrowQty ? maxQuantity : maxEscrowQty;
        if (quantity == 0) return;

        address[] memory recipients = new address[](1);
        recipients[0] = player;
        uint256 spend = quantity * base;
        bool stake = info.stake || info.basePerBondWei == 0; // default to staked when unset
        info.weiAmount = uint128(creditWei - spend);
        bondCreditEscrow = escrow - spend;
        IPurgeBonds(bondsAddr).payBonds{value: spend}(0, 0, 0, 0, 0);
        IPurgeBonds(bondsAddr).purchaseGameBonds(recipients, quantity, base, stake);
    }

    /// @notice Credit claimable ETH for a player from bond redemptions (bonds contract only).
    function creditBondWinnings(address player) external payable {
        if (msg.sender != bonds || player == address(0) || msg.value == 0) revert E();
        if (player == address(this)) {
            currentPrizePool += msg.value;
            return;
        }
        _addClaimableEth(player, msg.value);
    }

    /// @notice Deposit bond purchase reward share into the tracked reward pool (bonds only).
    function bondRewardDeposit() external payable {
        if (msg.sender != bonds || msg.value == 0) revert E();
        rewardPool += msg.value;
    }

    /// @notice Deposit bond purchase yield share without touching tracked pools (bonds only).
    function bondYieldDeposit() external payable {
        if (msg.sender != bonds || msg.value == 0) revert E();
        // Intentionally left untracked; balance stays on contract.
    }

    /// @notice Spend claimable ETH to purchase either NFTs or MAPs using the full available balance.
    /// @param mapPurchase If true, purchase MAPs; otherwise purchase NFTs.
    // Credit-based purchase entrypoints handled directly on the NFT contract to keep the game slimmer.

    /// @notice Sample up to 100 trait purge tickets from a random trait and recent level (last 20 levels).
    /// @param entropy Random seed used to select level, trait, and starting offset.
    function sampleTraitTickets(
        uint256 entropy
    ) external view returns (uint24 lvlSel, uint8 traitSel, address[] memory tickets) {
        uint24 currentLvl = level;
        if (currentLvl <= 1) {
            return (0, 0, new address[](0));
        }

        uint24 maxOffset = currentLvl > 20 ? 20 : currentLvl - 1;
        uint256 levelEntropy = uint256(keccak256(abi.encode(entropy, currentLvl)));
        uint24 offset = uint24((levelEntropy % maxOffset) + 1); // 1..maxOffset
        lvlSel = currentLvl - offset;

        traitSel = uint8(uint256(keccak256(abi.encode(entropy, lvlSel))) & 0xFF);
        address[] storage arr = traitPurgeTicket[lvlSel][traitSel];
        uint256 len = arr.length;
        if (len == 0) {
            return (lvlSel, traitSel, new address[](0));
        }

        uint256 take = len < 100 ? len : 100;
        tickets = new address[](take);
        uint256 start = uint256(keccak256(abi.encode(entropy, traitSel))) % len;
        for (uint256 i; i < take; ) {
            tickets[i] = arr[(start + i) % len];
            unchecked {
                ++i;
            }
        }
    }

    // --- Credits & jackpot helpers ------------------------------------------------------------------

    /// @notice Credit non-withdrawable bond proceeds to a player; callable only by the bonds contract.
    function addBondCredit(address player, uint256 amount) external {
        if (msg.sender != bonds || player == address(0) || amount == 0) revert E();
        unchecked {
            bondCredit[player] += amount;
        }
        emit BondCreditAdded(player, amount);
    }

    /// @notice Credit ETH winnings to a player’s claimable balance and emit an accounting event.
    /// @param beneficiary Player to credit.
    /// @param weiAmount   Amount in wei to add.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) internal {
        (address recipient, ) = affiliatePayoutAddress(beneficiary);
        unchecked {
            claimableWinnings[recipient] += weiAmount;
        }
        emit PlayerCredited(beneficiary, recipient, weiAmount);
    }

    function _recordMintData(
        address player,
        uint24 lvl,
        bool coinMint,
        uint32 mintUnits
    ) private returns (uint256 coinReward) {
        uint256 prevData = mintPacked_[player];
        uint32 day = _currentMintDay();
        uint256 data;

        if (coinMint) {
            data = _applyMintDay(prevData, day, COIN_DAY_SHIFT, MINT_MASK_32, COIN_DAY_STREAK_SHIFT, MINT_MASK_20);
        } else {
            uint256 priceCoinLocal = priceCoin;
            uint24 prevLevel = uint24((prevData >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
            uint24 total = uint24((prevData >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
            uint24 streak = uint24((prevData >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
            bool sameLevel = prevLevel == lvl;
            bool newCentury = (prevLevel / 100) != (lvl / 100);
            uint256 levelUnitsBefore = (prevData >> ETH_LEVEL_UNITS_SHIFT) & MINT_MASK_16;
            if (!sameLevel && prevLevel + 1 != lvl) {
                levelUnitsBefore = 0;
            }
            bool bonusPaid = sameLevel && (((prevData >> ETH_LEVEL_BONUS_SHIFT) & 1) == 1);
            uint256 levelUnitsAfter = levelUnitsBefore + uint256(mintUnits);
            if (levelUnitsAfter > MINT_MASK_16) {
                levelUnitsAfter = MINT_MASK_16;
            }
            bool awardBonus = (!bonusPaid) && levelUnitsAfter >= 400;
            if (awardBonus) {
                coinReward += (priceCoinLocal * 5) / 2;
                bonusPaid = true;
            }

            if (!sameLevel && levelUnitsAfter < 4) {
                data = _setPacked(prevData, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
                data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);
                if (data != prevData) {
                    mintPacked_[player] = data;
                }
                return coinReward;
            }

            data = _applyMintDay(prevData, day, ETH_DAY_SHIFT, MINT_MASK_32, ETH_DAY_STREAK_SHIFT, MINT_MASK_20);

            if (sameLevel) {
                data = _setPacked(data, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
                data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);
                if (data != prevData) {
                    mintPacked_[player] = data;
                }
                return coinReward;
            }

            if (newCentury) {
                total = 1;
            } else if (total < type(uint24).max) {
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
            data = _setPacked(data, ETH_LEVEL_UNITS_SHIFT, MINT_MASK_16, levelUnitsAfter);
            data = _setPacked(data, ETH_LEVEL_BONUS_SHIFT, 1, bonusPaid ? 1 : 0);

            uint256 rewardUnit = priceCoinLocal / 10;
            uint256 streakReward;
            if (streak >= 2) {
                uint256 capped = streak >= 61 ? 60 : uint256(streak - 1);
                streakReward = capped * rewardUnit;
            }

            uint256 totalReward;
            if (total >= 2) {
                uint256 cappedTotal = total >= 61 ? 60 : uint256(total - 1);
                totalReward = (cappedTotal * rewardUnit * 30) / 100;
            }

            if (streakReward != 0 || totalReward != 0) {
                unchecked {
                    coinReward += streakReward + totalReward;
                }
            }

            if (streak == lvl && lvl >= 20 && (lvl % 10 == 0)) {
                uint256 milestoneBonus = (uint256(lvl) / 2) * priceCoinLocal;
                coinReward += milestoneBonus;
            }

            if (total >= 20 && (total % 10 == 0)) {
                uint256 totalMilestone = (uint256(total) / 2) * priceCoinLocal;
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
            // Matches the JACKPOT_RESET_TIME-offset day index used in advanceGame.
            day = _currentDayIndex();
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

    function _runDecimatorHundredJackpot(uint24 lvl, uint256 rngWord) internal returns (bool finished) {
        // Decimator/BAF jackpots are promotional side-games; odds/payouts live in the jackpots module.
        if (!decimatorHundredReady) {
            uint256 basePool = rewardPool;
            uint256 decPool = (basePool * 40) / 100;
            uint256 bafPool = (basePool * 10) / 100;
            decimatorHundredPool = decPool;
            bafHundredPool = bafPool;
            rewardPool -= decPool;
            decimatorHundredReady = true;
        }

        uint256 pool = decimatorHundredPool;

        address jackpotsAddr = jackpots;
        if (jackpotsAddr == address(0)) revert E();
        uint256 returnWei = IPurgeJackpots(jackpotsAddr).runDecimatorJackpot(pool, lvl, rngWord);

        if (returnWei != 0) {
            rewardPool += returnWei;
        }
        decimatorHundredPool = 0;
        decimatorHundredReady = false;
        return true;
    }

    // --- Map jackpot payout (end of purchase phase) -------------------------------------------------

    function payMapJackpot(uint24 lvl, uint256 rngWord, uint256 effectiveWei) internal {
        (bool ok, ) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IPurgeGameJackpotModule.payMapJackpot.selector,
                lvl,
                rngWord,
                effectiveWei,
                IPurgeCoinModule(address(coin))
            )
        );
        if (!ok) return;
    }

    function _calcPrizePoolForJackpot(uint24 lvl, uint256 rngWord) internal returns (uint256 effectiveWei) {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IPurgeGameJackpotModule.calcPrizePoolForJackpot.selector,
                lvl,
                rngWord,
                address(steth)
            )
        );
        if (!ok || data.length == 0) return 0;
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
                IPurgeCoinModule(address(coin))
            )
        );
        if (!ok) return;
    }

    function _handleJackpotLevelCap() internal returns (bool) {
        if (jackpotCounter >= JACKPOT_LEVEL_CAP) {
            _endLevel(TRAIT_ID_TIMEOUT);
            return false;
        }
        return true;
    }

    function _purchasePrizePoolBondSlice() private {
        uint256 base = dailyJackpotBase;
        if (base == 0) return;

        uint256 budget = (base * PRIZE_POOL_BOND_BPS_PER_DAILY) / 10_000; // small skim per daily jackpot
        uint256 available = currentPrizePool;
        if (budget == 0 || available < budget) {
            budget = available;
        }
        if (budget < PRIZE_POOL_BOND_BASE) return;

        uint256 quantity = budget / PRIZE_POOL_BOND_BASE;
        uint256 spend = quantity * PRIZE_POOL_BOND_BASE;
        if (spend == 0) return;

        currentPrizePool = available - spend;

        if (!IPurgeBonds(bonds).purchasesEnabled()) {
            currentPrizePool += spend; // revert the deduction so funds remain in prize pool
            return;
        }

        address[] memory recipients = new address[](1);
        recipients[0] = address(this);

        IPurgeBonds(bonds).purchaseGameBonds(recipients, quantity, PRIZE_POOL_BOND_BASE, true);
        emit PrizePoolBondBuy(spend, quantity);
    }

    function _drainToBonds(uint48 day) private {
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) return;

        IPurgeBonds bondContract = IPurgeBonds(bondsAddr);
        bondContract.notifyGameOver();

        uint256 stBal = steth.balanceOf(address(this));
        if (stBal != 0) {
            principalStEth = 0;
        }

        uint256 ethBal = address(this).balance;
        // Inform bonds of shutdown and transfer pooled assets; bonds will resolve once it has RNG.
        bondContract.payBonds{value: ethBal}(0, stBal, day, 0, 0);
    }

    // --- Reward vault & liquidity -----------------------------------------------------

    function _stakeEth(uint256 amount) private {
        // Best-effort staking; skip if stETH deposits are paused or unavailable.
        try steth.submit{value: amount}(address(0)) returns (uint256 minted) {
            principalStEth += minted;
        } catch {
            return;
        }
    }

    /// @notice Swap ETH <-> stETH with the bonds contract to rebalance liquidity.
    /// @dev Access: bonds only. stEthForEth=true pulls stETH from bonds and sends back ETH; false stakes incoming ETH and forwards minted stETH.
    function swapWithBonds(bool stEthForEth, uint256 amount) external payable {
        if (msg.sender != bonds || amount == 0) revert E();

        if (stEthForEth) {
            if (msg.value != 0) revert E();
            if (!steth.transferFrom(msg.sender, address(this), amount)) revert E();
            principalStEth += amount;

            if (address(this).balance < amount) revert E();
            if (rewardPool >= amount) {
                rewardPool -= amount;
            } else {
                rewardPool = 0;
            }

            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            if (!ok) revert E();
        } else {
            if (msg.value != amount) revert E();
            uint256 minted;
            try steth.submit{value: amount}(address(0)) returns (uint256 m) {
                minted = m;
            } catch {
                revert E();
            }
            if (minted != 0) {
                _sendStethOrEth(msg.sender, minted);
            }
        }
    }

    function _stakeForTargetRatio(uint24 lvl) private {
        // Skip only for levels ending in 99 or 00 to avoid endgame edge cases.
        uint24 cycle = lvl % 100;
        if (cycle == 99 || cycle == 0) return;

        uint256 pool = rewardPool;
        if (pool == 0) return;

        uint256 rateBps = 10_000;
        address bondsAddr = bonds;
        if (bondsAddr != address(0)) {
            rateBps = IPurgeBonds(bondsAddr).stakeRateBps();
        }
        if (rateBps == 0) return;

        uint256 targetSt = (pool * rateBps) / 10_000; // stake against configured share of reward pool
        uint256 stBal = principalStEth;
        if (stBal >= targetSt) return;

        uint256 stakeAmount = targetSt - stBal;
        if (stakeAmount < REWARD_POOL_MIN_STAKE) return;

        _stakeEth(stakeAmount);
    }

    function _resolveBondsBeforeRng(uint48 day) private {
        if (lastBondResolutionDay == day) return;

        address bondsAddr = bonds;
        if (bondsAddr == address(0)) {
            lastBondResolutionDay = day;
            return;
        }

        IPurgeBonds bondContract = IPurgeBonds(bondsAddr);
        if (!bondContract.resolvePending()) {
            lastBondResolutionDay = day;
            return;
        }

        uint8 passes;
        do {
            bondContract.resolvePendingBonds(BOND_RNG_RESOLVE_LIMIT);
            unchecked {
                ++passes;
            }
        } while (bondContract.resolvePending() && passes < BOND_RNG_RESOLVE_PASSES);

        if (bondContract.resolvePending()) revert BondsNotResolved();

        lastBondResolutionDay = day;
    }

    // --- Flips, VRF, payments, rarity ----------------------------------------------------------------

    function rngAndTimeGate(uint48 day, uint24 lvl) internal returns (uint256 word) {
        if (day == dailyIdx) revert NotTimeYet();

        _resolveBondsBeforeRng(day);

        uint256 currentWord = rngFulfilled ? rngWordCurrent : 0;

        if (currentWord == 0 && rngLockedFlag && rngRequestTime != 0) {
            uint48 elapsed = uint48(block.timestamp) - rngRequestTime;
            if (elapsed >= 18 hours) {
                _requestRng(gameState, phase, lvl, day);
                return 1;
            }
        }

        if (currentWord == 0) {
            if (rngLockedFlag) revert RngNotReady();
            _requestRng(gameState, phase, lvl, day);
            return 1;
        }

        if (!rngLockedFlag) {
            // Stale entropy from previous cycle; request a fresh word.
            _requestRng(gameState, phase, lvl, day);
            return 1;
        }

        // Record the word once per day; using a zero sentinel since VRF returning 0 is effectively impossible.
        if (rngWordByDay[day] == 0) {
            rngWordByDay[day] = currentWord;
            if (lvl != 0) {
                coin.processCoinflipPayouts(lvl, false, currentWord, day, priceCoin);
            }
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
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(IPurgeGameJackpotModule.processMapBatch.selector, writesBudget)
        );
        if (!ok || data.length == 0) return false;
        return abi.decode(data, (bool));
    }

    /// @notice Process pending jackpot bond mints outside the main game tick.
    /// @param maxMints Max bonds to mint this call (0 = default chunk size).
    function workJackpotBondMints(uint256 maxMints) external {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(IPurgeGameJackpotModule.processPendingJackpotBonds.selector, maxMints)
        );
        if (!ok || data.length == 0) return;

        (, uint256 processed) = abi.decode(data, (bool, uint256));
        if (processed != 0 && maxMints == 0 && gameState != 0) {
            coin.creditFlip(msg.sender, priceCoin >> 1);
        }
    }

    function _maybeResolveBonds(uint32 cap) private returns (bool worked) {
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) return false;
        IPurgeBonds bondContract = IPurgeBonds(bondsAddr);
        if (!bondContract.resolvePending()) return false;

        uint256 limit = cap == 0 ? 40 : uint256(cap);
        bondContract.resolvePendingBonds(limit);
        return true;
    }

    function _bondMaintenanceForMap(uint48 day, uint256 totalWei, uint256 rngWord, uint32 cap) private returns (bool) {
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) return false;
        IPurgeBonds bondContract = IPurgeBonds(bondsAddr);

        uint256 maxBonds = cap == 0 ? 100 : uint256(cap);
        // If a batch is already pending, just resolve more and skip new funding.
        if (bondContract.resolvePending()) {
            // Resolve existing batch in one hop (no new funding).
            bondContract.payBonds{value: 0}(0, 0, day, rngWord, maxBonds);
            return true;
        }

        // Only fund once per level; subsequent calls act as resolve-only.
        if (lastBondFundingLevel == level) {
            return false;
        }

        uint256 stBal = steth.balanceOf(address(this));
        uint256 stYield = stBal > principalStEth ? (stBal - principalStEth) : 0;
        uint256 ethBal = address(this).balance;
        uint256 tracked = currentPrizePool + nextPrizePool + rewardPool + bondCreditEscrow;
        uint256 ethYield = ethBal > tracked ? ethBal - tracked : 0;
        uint256 yieldPool = stYield + ethYield;

        // Mint 5% of totalWei (priced in PURGE) to the bonds contract.
        uint256 bondMint = (totalWei * priceCoin) / (20 * price);

        uint256 bondSkim = yieldPool / 4; // 25% to bonds
        uint256 rewardTopUp = yieldPool / 20; // 5% to reward pool

        uint256 ethForBonds = ethYield >= bondSkim ? bondSkim : ethYield;
        uint256 stForBonds = bondSkim > ethForBonds ? bondSkim - ethForBonds : 0;
        if (stForBonds > stYield) {
            stForBonds = stYield;
            bondSkim = ethForBonds + stForBonds;
        }

        uint256 availableEthAfterBond = ethYield > ethForBonds ? ethYield - ethForBonds : 0;
        uint256 rewardFromEth = availableEthAfterBond >= rewardTopUp ? rewardTopUp : availableEthAfterBond;
        if (rewardFromEth != 0) {
            rewardPool += rewardFromEth;
        }

        bondContract.payBonds{value: ethForBonds}(bondMint, stForBonds, day, rngWord, maxBonds);
        lastBondFundingLevel = level;
        return (bondSkim != 0 || bondMint != 0 || rewardFromEth != 0);
    }

    /// @notice After the liveness drain has notified the bonds contract, permissionlessly burn remaining unmatured bonds.
    /// @param maxIds Number of token ids to scan in this call (0 = default chunk size in bonds).
    /// @return processedIds Token ids scanned.
    /// @return burned Bonds burned.
    /// @return complete True if shutdown burning is finished.
    function finalizeBondShutdown(
        uint256 maxIds
    ) external returns (uint256 processedIds, uint256 burned, bool complete) {
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) revert E();
        return IPurgeBonds(bondsAddr).finalizeShutdown(maxIds);
    }

    function _requestRng(uint8 gameState_, uint8 phase_, uint24 lvl, uint48 day) private {
        bool shouldLockBonds = (gameState_ == 2 && phase_ == 3) || (gameState_ == 0);
        if (shouldLockBonds) {
            IPurgeBonds(bonds).setTransfersLocked(true, day);
        }

        // Hard revert if Chainlink request fails; this intentionally halts game progress until VRF funding/config is fixed.
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
        rngRequestTime = uint48(block.timestamp);

        bool decClose = (((lvl % 100 != 0 && (lvl % 100 != 99) && gameState_ == 1) ||
            (lvl % 100 == 0 && phase_ == 3)) && decWindowOpen);
        if (decClose) decWindowOpen = false;
    }

    /// @notice Emergency hook for the bonds contract to repoint VRF after prolonged downtime.
    /// @dev Requires three consecutive day slots to have zeroed RNG entries.
    function emergencyUpdateVrfCoordinator(address newCoordinator) external {
        if (msg.sender != bonds) revert E();
        address current = address(vrfCoordinator);
        if (!_threeDayRngGap(_currentDayIndex())) revert VrfUpdateNotReady();

        vrfCoordinator = IVRFCoordinator(newCoordinator);

        rngLockedFlag = false;
        rngFulfilled = true;
        vrfRequestId = 0;
        rngRequestTime = 0;
        rngWordCurrent = 0;

        emit VrfCoordinatorUpdated(current, newCoordinator);
    }

    function _unlockRng(uint48 day) private {
        dailyIdx = day;
        rngLockedFlag = false;
        vrfRequestId = 0;
        rngRequestTime = 0;
    }

    /// @notice Pay PURGE to nudge the next RNG word by +1; cost scales +50% per queued nudge and resets after fulfillment.
    /// @dev Only available while RNG is unlocked (before a VRF request is in-flight).
    function reverseFlip() external {
        if (rngLockedFlag) revert RngLocked();
        uint256 reversals = totalFlipReversals;
        uint256 cost = _currentNudgeCost(reversals);
        coin.burnCoin(msg.sender, cost);
        uint256 newCount = reversals + 1;
        totalFlipReversals = newCount;
        emit ReverseFlip(msg.sender, newCount, cost);
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert E();
        if (requestId != vrfRequestId || rngFulfilled) return;
        uint256 word = randomWords[0];
        uint256 rngNudge = totalFlipReversals;
        if (rngNudge != 0) {
            word += rngNudge;
            totalFlipReversals = 0;
        }
        rngFulfilled = true;
        rngWordCurrent = word;
    }

    function _currentNudgeCost(uint256 reversals) private pure returns (uint256 cost) {
        cost = RNG_NUDGE_BASE_COST;
        while (reversals != 0) {
            cost = (cost * 15) / 10; // compound 10% per queued reversal
            unchecked {
                --reversals;
            }
        }
    }

    function _sendStethOrEth(address to, uint256 amount) private {
        if (amount == 0 || to == address(0)) revert E();

        uint256 stBal = steth.balanceOf(address(this));
        uint256 stSend = amount <= stBal ? amount : stBal;
        if (stSend != 0) {
            if (!steth.transfer(to, stSend)) revert E();
            if (principalStEth >= stSend) {
                principalStEth -= stSend;
            } else {
                principalStEth = 0;
            }
        }

        uint256 remaining = amount - stSend;
        if (remaining != 0) {
            uint256 ethBal = address(this).balance;
            if (ethBal < remaining) revert E();
            (bool ok, ) = payable(to).call{value: remaining}("");
            if (!ok) revert E();
        }
    }

    function _payoutWithStethFallback(address to, uint256 amount) private {
        if (amount == 0) return;

        uint256 ethBal = address(this).balance;
        uint256 ethSend = amount <= ethBal ? amount : ethBal;
        if (ethSend != 0) {
            (bool okEth, ) = payable(to).call{value: ethSend}("");
            if (!okEth) revert E();
        }
        uint256 remaining = amount - ethSend;
        if (remaining == 0) return;

        uint256 stBal = steth.balanceOf(address(this));
        uint256 stSend = remaining <= stBal ? remaining : stBal;
        if (stSend != 0) {
            if (!steth.transfer(to, stSend)) revert E();
            if (principalStEth >= stSend) {
                principalStEth -= stSend;
            } else {
                principalStEth = 0;
            }
        }

        uint256 leftover = remaining - stSend;
        if (leftover != 0) {
            // Retry with any refreshed ETH (e.g., if stETH was short but ETH arrived).
            uint256 ethRetry = address(this).balance;
            if (ethRetry < leftover) revert E();
            (bool ok, ) = payable(to).call{value: leftover}("");
            if (!ok) revert E();
        }
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

        coin.creditFlip(caller, flipCredit);
    }

    function onTokenTransfer(address from, uint256 amount, bytes calldata) external {
        if (msg.sender != linkToken) revert E();
        if (amount == 0) revert E();

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
        uint256 luckPerLink = (priceCoin * LUCK_PER_LINK_PERCENT) / 100;
        uint256 baseCredit = (amount * luckPerLink) / 1 ether;
        uint256 credit = (baseCredit * mult) / 1000;
        if (credit != 0) {
            coin.creditFlip(from, credit);
        }
    }

    function _tierMultPermille(uint256 subBal) private pure returns (uint16) {
        if (subBal < 100 ether) return 2000;
        if (subBal < 200 ether) return 1500;
        if (subBal < 400 ether) return 1000;
        if (subBal < 600 ether) return 200;
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
    function _rebuildTraitCounts(uint32 tokenBudget, uint32 target) internal returns (bool finished) {
        uint32 cursor = traitRebuildCursor;
        if (cursor >= target) return true;

        uint32 batch = (tokenBudget == 0) ? TRAIT_REBUILD_TOKENS_PER_TX : tokenBudget;
        bool startingSlice = cursor == 0;
        if (startingSlice) {
            uint32 firstBatch = (level == 1) ? TRAIT_REBUILD_TOKENS_LEVEL1 : TRAIT_REBUILD_TOKENS_PER_TX;
            batch = firstBatch;
        }
        uint32 remaining = target - cursor;
        if (batch > remaining) batch = remaining;

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
                // Assumes the first slice will touch all traits to overwrite stale counts from the previous level.
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

    function _calculateAirdropMultiplier(uint32 purchaseCount, uint24 lvl) private pure returns (uint32) {
        if (purchaseCount == 0) {
            return 1;
        }
        uint256 target = (lvl % 10 == 8) ? 10_000 : 5_000;
        if (purchaseCount >= target) {
            return 1;
        }
        uint256 numerator = target + uint256(purchaseCount) - 1;
        return uint32(numerator / purchaseCount);
    }

    function _purchaseTargetCountFromRaw(uint32 rawCount) private view returns (uint32) {
        if (rawCount == 0) {
            return 0;
        }
        uint32 multiplier = airdropMultiplier;
        uint256 scaled = uint256(rawCount) * uint256(multiplier);
        if (scaled > type(uint32).max) revert E();
        return uint32(scaled);
    }

    function _consumeTrait(uint8 traitId, uint32 endLevel) private returns (bool reachedZero) {
        // Trait counts are expected to be seeded for the current level; hitting zero here should only occur via purge flow.
        uint32 stored = traitRemaining[traitId];

        unchecked {
            stored -= 1;
        }
        traitRemaining[traitId] = stored;
        return stored == endLevel;
    }

    function _setExterminatorForLevel(uint24 lvl, address ex) private {
        if (lvl == 0) return;
        address[] storage arr = levelExterminators;
        uint256 idx = uint256(lvl) - 1;
        uint256 len = arr.length;
        if (len == idx) {
            arr.push(ex);
        } else if (len > idx) {
            arr[idx] = ex;
        } else {
            while (arr.length < idx) {
                arr.push();
            }
            arr.push(ex);
        }
    }

    function levelExterminator(uint24 lvl) external view returns (address) {
        if (lvl == 0) return address(0);
        address[] storage arr = levelExterminators;
        if (arr.length < lvl) return address(0);
        return arr[uint256(lvl) - 1];
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
        rewardPool += msg.value;
    }
}
