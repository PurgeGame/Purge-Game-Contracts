// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGamepieces} from "./DegenerusGamepieces.sol";
import {IDegenerusCoinModule} from "./interfaces/DegenerusGameModuleInterfaces.sol";
import {IDegenerusCoin} from "./interfaces/IDegenerusCoin.sol";
import {IDegenerusAffiliate} from "./interfaces/IDegenerusAffiliate.sol";
import {IDegenerusRendererLike} from "./interfaces/IDegenerusRendererLike.sol";
import {IDegenerusJackpots} from "./interfaces/IDegenerusJackpots.sol";
import {IDegenerusTrophies} from "./interfaces/IDegenerusTrophies.sol";
import {
    IDegenerusGameEndgameModule,
    IDegenerusGameJackpotModule,
    IDegenerusGameMintModule,
    IDegenerusGameBondModule
} from "./interfaces/IDegenerusGameModules.sol";
import {MintPaymentKind} from "./interfaces/IDegenerusGame.sol";
import {DegenerusGameExternalOp} from "./interfaces/IDegenerusGameExternal.sol";
import {DegenerusGameStorage, ClaimableBondInfo} from "./storage/DegenerusGameStorage.sol";
import {DegenerusGameCredit} from "./utils/DegenerusGameCredit.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IDegenerusBonds {
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded);
    function payBonds(
        uint256 coinAmount,
        uint256 stEthAmount,
        uint256 rngWord
    ) external payable;
    function resolveBonds(uint256 rngWord) external returns (bool worked);
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

interface IDegenerusBondsGameOver {
    function gameOver() external payable;
}

/**
 * @title Degenerus — Core NFT game contract
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
}

// ===========================================================================
// Contract
// ===========================================================================

contract DegenerusGame is DegenerusGameStorage {
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
    error VrfUpdateNotReady(); // VRF swap not allowed yet (not stuck long enough or randomness already received)

    // -----------------------
    // Events
    // -----------------------
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);
    event BondCreditAdded(address indexed player, uint256 amount);
    event Jackpot(uint256 traits); // Encodes jackpot metadata
    event Degenerus(address indexed player, uint256[] tokenIds);
    event Advance(uint8 gameState);
    event ReverseFlip(address indexed caller, uint256 totalQueued, uint256 cost);
    event VrfCoordinatorUpdated(address indexed previous, address indexed current);
    event PrizePoolBondBuy(uint256 spendWei, uint256 quantity);
    event BondCreditLiquidated(address indexed player, uint256 amount);

    // -----------------------
    // Immutable Addresses
    // -----------------------
    IDegenerusRendererLike private immutable renderer; // Trusted renderer; used for tokenURI composition
    IDegenerusCoin private immutable coin; // Trusted coin/game-side coordinator (BURNIE ERC20)
    IDegenerusGamepieces private immutable nft; // ERC721 interface for mint/burn/metadata surface
    address private immutable affiliateProgram; // Cached affiliate program for payout routing
    IStETH private immutable steth; // stETH token held by the game
    address private immutable jackpots; // DegenerusJackpots contract
    address private immutable endgameModule; // Delegate module for endgame settlement
    address private immutable jackpotModule; // Delegate module for jackpot routines
    address private immutable mintModule; // Delegate module for mint packing + trait rebuild helpers
    address private immutable bondModule; // Delegate module for bond upkeep and staking
    IVRFCoordinator private vrfCoordinator; // Chainlink VRF coordinator (mutable for emergencies)
    bytes32 private vrfKeyHash; // VRF key hash (rotatable with coordinator/sub)
    uint256 private vrfSubscriptionId; // VRF subscription identifier (mutable for coordinator swaps)
    address private immutable vrfAdmin; // VRF subscription owner contract allowed to rotate/wire VRF config
    // Trusted collaborators: coin/nft/jackpots/modules are expected to be non-reentrant and non-malicious.

    uint256 private constant DEPLOY_IDLE_TIMEOUT = (365 days * 5) / 2; // 2.5 years
    uint48 private constant LEVEL_START_SENTINEL = type(uint48).max;

    // -----------------------
    // Game Constants
    // -----------------------
    uint48 private constant JACKPOT_RESET_TIME = 82620; // "Day" windows are offset from unix midnight by this anchor
    uint8 private constant JACKPOT_LEVEL_CAP = 10;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;
    uint256 private constant RNG_NUDGE_BASE_COST = 100 * 1e6; // BURNIE has 6 decimals

    // mintPacked_ layout (LSB ->):
    // [0-23]=last ETH level, [24-47]=total ETH level count, [48-71]=ETH level streak,
    // [72-103]=last ETH day, [104-123]=ETH day streak, [124-155]=last COIN day,
    // [156-175]=COIN day streak, [176-207]=aggregate last day, [208-227]=aggregate day streak,
    // [228-243]=units minted at current level, [244]=level bonus paid flag.
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant MINT_MASK_32 = (uint256(1) << 32) - 1;
    uint256 private constant ETH_LAST_LEVEL_SHIFT = 0;
    uint256 private constant ETH_LEVEL_COUNT_SHIFT = 24;
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;
    uint256 private constant ETH_DAY_SHIFT = 72;

    // -----------------------
    // Constructor
    // -----------------------

    /**
     * @param degenerusCoinContract Trusted BURNIE ERC20 / game coordinator address
     * @param renderer_         Trusted on-chain renderer
     * @param nftContract       ERC721 game contract
     * @param endgameModule_    Delegate module handling endgame settlement
     * @param jackpotModule_    Delegate module handling jackpot distribution
     * @param mintModule_       Delegate module handling mint packing and trait rebuild helpers
     * @param bondModule_       Delegate module handling bond upkeep, staking, and shutdown drains
     * @param vrfCoordinator_   Chainlink VRF coordinator
     * @param vrfKeyHash_       VRF key hash
     * @param stEthToken_       stETH token address
     * @param jackpots_         DegenerusJackpots contract address (wires Decimator/BAF jackpots)
     * @param bonds_            Bonds contract address
     * @param trophies_         Standalone trophy ERC721 contract (cosmetic only)
     * @param affiliateProgram_ Affiliate program contract address (for payouts/trophies)
     * @param vault_            Reward vault contract address
     * @param vrfAdmin_         VRF owner/admin contract authorized to rotate the coordinator/subscription on stalls
     */
    constructor(
        address degenerusCoinContract,
        address renderer_,
        address nftContract,
        address endgameModule_,
        address jackpotModule_,
        address mintModule_,
        address bondModule_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        address stEthToken_,
        address jackpots_,
        address bonds_,
        address trophies_,
        address affiliateProgram_,
        address vault_,
        address vrfAdmin_
    ) {
        coin = IDegenerusCoin(degenerusCoinContract);
        renderer = IDegenerusRendererLike(renderer_);
        nft = IDegenerusGamepieces(nftContract);
        endgameModule = endgameModule_;
        jackpotModule = jackpotModule_;
        mintModule = mintModule_;
        bondModule = bondModule_;
        vrfCoordinator = IVRFCoordinator(vrfCoordinator_);
        affiliateProgram = affiliateProgram_;
        vrfKeyHash = vrfKeyHash_;
        vrfAdmin = vrfAdmin_;
        steth = IStETH(stEthToken_);
        jackpots = jackpots_;
        bonds = bonds_;
        trophies = trophies_;
        affiliateProgramAddr = affiliateProgram_;
        vault = vault_;
        if (!steth.approve(bonds_, type(uint256).max)) revert E();
        deployTimestamp = uint48(block.timestamp);
    }

    modifier onlyBonds() {
        if (msg.sender != bonds) revert E();
        _;
    }

    /// @notice Accept ETH for bond obligations; callable only by the bond contract.
    function bondDeposit() external payable onlyBonds {
        bondPool += msg.value;
    }

    /// @notice Credit bond winnings into claimable balance and burn from the bond pool.
    function bondCreditToClaimable(address player, uint256 amount) external onlyBonds {
        if (bondGameOver || amount == 0 || amount > bondPool) revert E();
        bondPool -= amount;
        claimableWinningsLiability += amount;
        _addClaimableEth(player, amount);
    }

    /// @notice View helper for bonds to know available ETH in the game-held bond pool.
    function bondAvailable() external view returns (uint256) {
        if (bondGameOver) return 0;
        return bondPool;
    }

    /// @notice Shutdown path: flush bond pool to the bonds contract and let it resolve internally.
    /// @dev Access: vrfAdmin acts as an owner surrogate; bonds may also call to complete shutdown.
    function shutdownBonds() external {
        address bondsAddr = bonds;
        if (bondsAddr == address(0) || bondGameOver) revert E();
        if (msg.sender != vrfAdmin && msg.sender != bondsAddr) revert E();
        bondGameOver = true;
        uint256 ethAmount = address(this).balance;
        bondPool = 0;

        // Forward all stETH to bonds as part of final settlement.
        uint256 stAmount = steth.balanceOf(address(this));
        if (stAmount != 0) {
            principalStEth = 0;
            if (!steth.transfer(bondsAddr, stAmount)) revert E();
        }

        (bool ok, ) = payable(bondsAddr).call{value: ethAmount}("");
        if (!ok) revert E();
        IDegenerusBondsGameOver(bondsAddr).gameOver{value: 0}();
    }

    // --- View: lightweight game status -------------------------------------------------

    function prizePoolTargetView() external view returns (uint256) {
        return lastPrizePool;
    }

    function nextPrizePoolView() external view returns (uint256) {
        return nextPrizePool;
    }

    /// @notice Resolve the payout recipient for a player, routing synthetic MAP-only players to their affiliate owner.
    function affiliatePayoutAddress(address player) public view returns (address recipient, address affiliateOwner) {
        address affiliateAddr = affiliateProgram;
        (affiliateOwner, ) = IDegenerusAffiliate(affiliateAddr).syntheticMapInfo(player);
        recipient = affiliateOwner == address(0) ? player : affiliateOwner;
    }

    // --- State machine: advance one tick ------------------------------------------------

    function mintPrice() external view returns (uint256) {
        return price;
    }

    function coinPriceUnit() external view returns (uint256) {
        return priceCoin;
    }

    function rngWordForDay(uint48 day) external view returns (uint256) {
        return rngWordByDay[day];
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

    /// @notice True if no VRF word has been recorded for the last 3 day slots.
    function rngStalledForThreeDays() external view returns (bool) {
        return _threeDayRngGap(_currentDayIndex());
    }

    /// @notice One-time wiring of VRF config from the VRF admin contract (on deployment).
    function wireInitialVrf(address coordinator_, uint256 subId) external {
        address current = address(vrfCoordinator);
        vrfCoordinator = IVRFCoordinator(coordinator_);
        vrfSubscriptionId = subId;
        emit VrfCoordinatorUpdated(current, coordinator_);
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
        returns (
            uint24 lvl,
            uint8 gameState_,
            bool lastPurchaseDay_,
            bool rngLocked_,
            uint256 priceWei,
            uint256 priceCoinUnit
        )
    {
        lvl = level;
        gameState_ = gameState;
        lastPurchaseDay_ = (gameState_ == 2) && lastPurchaseDay;
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
            if (msg.value != 0) revert E();
            if (payKind != MintPaymentKind.DirectEth) revert E(); // coin mints are keyed by DirectEth sentinel

            uint256 priceWei = price;
            if (priceWei == 0) revert E();

            // Charge BURNIE for the equivalent ETH cost at current priceWei.
            uint256 burnCost = (priceWei * mintUnits) / 1 ether;
            coin.burnCoin(player, burnCost);
            return _recordMintDataModule(player, lvl, true, 0);
        }

        uint256 amount = costWei;
        uint256 prizeContribution = _processMintPayment(player, amount, payKind);
        if (prizeContribution != 0) {
            nextPrizePool += prizeContribution;
        }

        coinReward = _recordMintDataModule(player, lvl, false, mintUnits);
    }

    function _processMintPayment(
        address player,
        uint256 amount,
        MintPaymentKind payKind
    ) private returns (uint256 prizeContribution) {
        (bool ok, uint256 prize, uint256 creditUsed, uint256 claimableUsed) = DegenerusGameCredit.processMintPayment(
            claimableWinnings,
            bondCredit,
            player,
            amount,
            payKind,
            msg.value
        );
        if (!ok) revert E();
        if (claimableUsed != 0) {
            if (claimableWinningsLiability >= claimableUsed) {
                claimableWinningsLiability -= claimableUsed;
            } else {
                claimableWinningsLiability = 0;
            }
        }
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
    ///            Using cap removes DegenerusCoin payment.
    function advanceGame(uint32 cap) external {
        address caller = msg.sender;
        uint48 ts = uint48(block.timestamp);
        // Day index uses JACKPOT_RESET_TIME offset instead of unix midnight to align jackpots/quests.
        uint48 day = _currentDayIndex();
        IDegenerusCoin coinContract = coin;
        uint48 lst = levelStartTime;
        if (lst == LEVEL_START_SENTINEL) {
            uint48 deployTs = deployTimestamp;
            if (
                deployTs != 0 && uint256(ts) >= uint256(deployTs) + DEPLOY_IDLE_TIMEOUT // uint256 to avoid uint48 overflow
            ) {
                drainToBonds();
                return;
            }
        }
        uint8 _gameState = gameState;
        // Liveness drain
        if (ts - 365 days > lst && _gameState != 0) {
            drainToBonds();
            return;
        }
        uint24 lvl = level;

        bool lastPurchase = (_gameState == 2) ? lastPurchaseDay : false;
        bool mapRngDay = (_gameState == 2) && lastPurchase;

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

            uint256 rngWord = rngAndTimeGate(day, lvl, mapRngDay);
            if (rngWord == 1) {
                break;
            }

            // --- State 1 - Pregame ---
            if (_gameState == 1) {
                _runEndgameModule(lvl, cap, rngWord); // handles payouts, wipes, endgame dist, and jackpots
                if (gameState == 2) {
                    if (lvl != 0) {
                        address topStake = coinContract.recordStakeResolution(lvl, day);
                        if (topStake != address(0)) {
                            IDegenerusTrophies(trophies).mintStake(topStake, lvl);
                        }
                    }
                    if (lastExterminatedTrait != TRAIT_ID_TIMEOUT) {
                        payDailyJackpot(false, level, rngWord);
                    }
                    _stakeForTargetRatioModule(lvl);
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
                if (!lastPurchaseDay) {
                    bool batchesPending = airdropIndex < pendingMapMints.length;
                    if (batchesPending) {
                        bool batchesFinished = _processMapBatch(cap);
                        if (!batchesFinished) break;
                        batchesPending = false;
                    }
                    payDailyJackpot(false, lvl, rngWord);
                    if (!batchesPending && nextPrizePool >= lastPrizePool) {
                        airdropMultiplier = _calculateAirdropMultiplierModule(nft.purchaseCount(), lvl);
                        lastPurchaseDay = true;
                    }
                    _unlockRng(day);
                    break;
                }

                if (!mapJackpotPaid) {
                    if (!_processMapBatch(cap)) {
                        break;
                    }
                    if (lvl % 100 == 0) {
                        if (!_runDecimatorHundredJackpot(lvl, rngWord)) {
                            break; // keep working this jackpot slice before moving on
                        }
                    }

                    uint256 totalWeiForBond = rewardPool + currentPrizePool;
                    if (_bondMaintenanceForMapModule(day, totalWeiForBond, rngWord, cap)) {
                        break; // bond batch consumed this tick; rerun advanceGame to continue
                    }
                    uint256 mapEffectiveWei = _calcPrizePoolForJackpot(lvl, rngWord);
                    payMapJackpot(lvl, rngWord, mapEffectiveWei);
                    mapJackpotPaid = true;

                    airdropMapsProcessedCount = 0;
                    if (airdropIndex >= pendingMapMints.length) {
                        airdropIndex = 0;
                        delete pendingMapMints;
                    }
                }

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
                    uint32 targetCount = _purchaseTargetCountFromRawModule(purchaseCountRaw);
                    if (traitRebuildCursor < targetCount) {
                        uint256 baseTokenId = nft.currentBaseTokenId();
                        _rebuildTraitCountsModule(cap, targetCount, baseTokenId);
                        break;
                    }
                    _seedTraitCounts();
                    traitCountsSeedQueued = false;
                }

                uint32 mintedCount = _purchaseTargetCountFromRawModule(purchaseCountRaw);
                nft.finalizePurchasePhase(mintedCount, rngWordCurrent);
                traitRebuildCursor = 0;
                airdropMultiplier = 1;
                earlyBurnPercent = 0;
                levelStartTime = ts;
                gameState = 3;
                mapJackpotPaid = false;
                lastPurchaseDay = false;
                if (lvl % 100 == 99) decWindowOpen = true;
                _unlockRng(day); // open RNG after map jackpot is finalized
                break;
            }

            // --- State 3 - Degenerus ---
            if (_gameState == 3) {
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

        emit Advance(_gameState);

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

    // --- Burning NFTs into tickets & potentially ending the level -----------------------------------

    function burnTokens(uint256[] calldata tokenIds) external {
        if (rngLockedFlag) revert RngNotReady();
        if (gameState != 3) revert NotTimeYet();

        uint256 count = tokenIds.length;
        if (count == 0 || count > 75) revert InvalidQuantity();
        address caller = msg.sender;
        nft.burnFromGame(caller, tokenIds);
        coin.notifyQuestBurn(caller, uint32(count));

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

        address[][256] storage tickets = traitBurnTicket[lvl];

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
                dailyBurnCount[trait0 & 0x07] += 1;
                dailyBurnCount[((trait1 - 64) >> 3) + 8] += 1;
                dailyBurnCount[trait2 - 128 + 16] += 1;
                ++i;
            }

            tickets[trait0].push(caller);
            tickets[trait1].push(caller);
            tickets[trait2].push(caller);
            tickets[trait3].push(caller);
        }

        if (isDoubleCountStep) count <<= 1;
        _creditBurnFlip(caller, stakeBonusCoin, priceCoinLocal, count, bonusTenths);
        emit Degenerus(caller, tokenIds);

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
    /// - Pay the exterminator slice immediately (30%, or 40% on levels where `prevLevel % 10 == 4` and `prevLevel > 4`).
    /// - Route the remaining prize pool into a trait-only daily-style jackpot during endgame settlement (no equal-split bonus path).
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
        gameState = 1;
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

            IDegenerusTrophies(trophies).mintExterminator(
                callerExterminator,
                levelSnapshot,
                exTrait,
                exterminationInvertFlag
            );

            lastExterminatedTrait = exTrait;
            coin.normalizeActiveBurnQuests();
        } else {
            exterminationInvertFlag = false;
            _setExterminatorForLevel(levelSnapshot, address(0));

            currentPrizePool = 0;
            lastExterminatedTrait = TRAIT_ID_TIMEOUT;
        }

        if (levelSnapshot % 100 == 0) {
            lastPrizePool = rewardPool;
            price = 0.05 ether;
        }

        unchecked {
            levelSnapshot++;
            level++;
        }

        traitRebuildCursor = 0;
        jackpotCounter = 0;
        // Reset daily burn counters so the next level's jackpots start fresh.
        for (uint8 i; i < 80; ) {
            dailyBurnCount[i] = 0;
            unchecked {
                ++i;
            }
        }

        uint256 cycleOffset = levelSnapshot % 100; // position within the 100-level schedule (0 == 100)

        if (cycleOffset == 10) {
            price = 0.05 ether;
        } else if (cycleOffset == 30) {
            price = 0.1 ether;
        } else if (cycleOffset == 80) {
            price = 0.15 ether;
        } else if (cycleOffset == 0) {
            price = 0.25 ether;
        }

        nft.advanceBase(); // let NFT pull its own nextTokenId to avoid redundant calls here
    }

    /// @notice Delegatecall into the endgame module to resolve slow settlement paths.
    function _runEndgameModule(uint24 lvl, uint32 cap, uint256 rngWord) internal {
        // Endgame settlement logic lives in DegenerusGameEndgameModule (delegatecall keeps state on this contract).
        (bool ok, bytes memory data) = endgameModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameEndgameModule.finalizeEndgame.selector, lvl, cap, rngWord, jackpots)
        );
        if (!ok || data.length == 0) return;

        bool readyForPurchase = abi.decode(data, (bool));
        if (readyForPurchase) {
            gameState = 2; // No endgame work pending; move directly into the purchase/airdrop state.
        }
    }

    // --- Delegate helpers (mint module) --------------------------------------------------------------

    function _recordMintDataModule(
        address player,
        uint24 lvl,
        bool coinMint,
        uint32 mintUnits
    ) private returns (uint256 coinReward) {
        (bool ok, bytes memory data) = mintModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameMintModule.recordMintData.selector, player, lvl, coinMint, mintUnits)
        );
        if (!ok || data.length == 0) revert E();
        return abi.decode(data, (uint256));
    }

    function _calculateAirdropMultiplierModule(uint32 purchaseCount, uint24 lvl) private returns (uint32) {
        (bool ok, bytes memory data) = mintModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameMintModule.calculateAirdropMultiplier.selector, purchaseCount, lvl)
        );
        if (!ok || data.length == 0) revert E();
        return abi.decode(data, (uint32));
    }

    function _purchaseTargetCountFromRawModule(uint32 rawCount) private returns (uint32) {
        (bool ok, bytes memory data) = mintModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameMintModule.purchaseTargetCountFromRaw.selector, rawCount)
        );
        if (!ok || data.length == 0) revert E();
        return abi.decode(data, (uint32));
    }

    function _rebuildTraitCountsModule(uint32 tokenBudget, uint32 target, uint256 baseTokenId) private {
        (bool ok, ) = mintModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameMintModule.rebuildTraitCounts.selector,
                tokenBudget,
                target,
                baseTokenId
            )
        );
        if (!ok) revert E();
    }

    function _bondMaintenanceForMapModule(
        uint48 day,
        uint256 totalWei,
        uint256 rngWord,
        uint32 cap
    ) private returns (bool worked) {
        (bool ok, bytes memory data) = bondModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameBondModule.bondMaintenanceForMap.selector,
                bonds,
                address(steth),
                day,
                totalWei,
                rngWord,
                cap
            )
        );
        if (!ok || data.length == 0) revert E();
        return abi.decode(data, (bool));
    }

    function _stakeForTargetRatioModule(uint24 lvl) private {
        (bool ok, bytes memory data) = bondModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameBondModule.stakeForTargetRatio.selector, bonds, address(steth), lvl)
        );
        if (!ok) {
            _revertWith(data);
        }
    }

    function _drainToBondsModule() private {
        (bool ok, bytes memory data) = bondModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameBondModule.drainToBonds.selector, bonds, address(steth))
        );
        if (!ok) {
            _revertWith(data);
        }
    }

    function _revertWith(bytes memory data) private pure {
        if (data.length == 0) revert E();
        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }

    /// @notice Unified external hook for trusted modules to adjust DegenerusGame accounting.
    /// @param op      Operation selector.
    /// @param account Player to credit (when applicable).
    /// @param amount  Wei amount associated with the operation.
    /// @param lvl     Level context for the operation (unused by the game, used by callers).
    function applyExternalOp(DegenerusGameExternalOp op, address account, uint256 amount, uint24 lvl) external {
        lvl;
        if (op == DegenerusGameExternalOp.DecJackpotClaim) {
            address jackpotsAddr = jackpots;
            if (jackpotsAddr == address(0) || msg.sender != jackpotsAddr) revert E();
            claimableWinningsLiability += amount;
            _addClaimableEth(account, amount);
        } else {
            revert E();
        }
    }

    // --- Claiming winnings (ETH) --------------------------------------------------------------------

    /// @notice Claim the caller’s accrued ETH winnings (affiliates, jackpots, bonds, endgame payouts).
    /// @dev Leaves a 1 wei sentinel so subsequent credits remain non-zero -> cheaper SSTORE.
    function claimWinnings() external {
        address player = msg.sender;
        uint256 amount = claimableWinnings[player];
        if (amount <= 1) revert E();
        _applyBondCredit(player, 0);
        uint256 payout;
        unchecked {
            claimableWinnings[player] = 1;
            payout = amount - 1;
            if (claimableWinningsLiability >= payout) {
                claimableWinningsLiability -= payout;
            } else {
                claimableWinningsLiability = 0;
            }
        }
        _payoutWithStethFallback(player, payout);
    }

    function getWinnings() external view returns (uint256) {
        uint256 stored = claimableWinnings[msg.sender];
        if (stored <= 1) return 0;
        return stored - 1;
    }

    /// @notice Toggle auto-liquidation of bond credits into claimable winnings (tax applies on withdrawal).
    /// @dev When enabled, any existing bond credit is immediately converted if escrowed funds are available.
    function setAutoBondLiquidate(bool enabled) external {
        autoBondLiquidate[msg.sender] = enabled;
        if (enabled) {
            _autoLiquidateBondCredit(msg.sender);
        }
    }

    function _autoLiquidateBondCredit(address player) private returns (bool converted) {
        if (!autoBondLiquidate[player]) return false;
        ClaimableBondInfo storage info = claimableBondInfo[player];
        uint256 creditWei = info.weiAmount;
        if (creditWei == 0) return false;

        info.weiAmount = 0;
        info.basePerBondWei = 0;
        info.stake = false;
        bondCreditEscrow = bondCreditEscrow - creditWei;
        claimableWinningsLiability += creditWei;
        _addClaimableEth(player, creditWei);
        emit BondCreditLiquidated(player, creditWei);
        return true;
    }

    /// @notice Spend any claimable bond credits without claiming ETH winnings.
    /// @param amountWei Optional cap on spend this call (0 = all).
    function claimBondCredits(uint256 amountWei) external {
        _applyBondCredit(msg.sender, amountWei);
    }

    /// @notice Spend bond credits into the active bond series; falls back to crediting ETH if bonds are unavailable.
    /// @param amountWei Optional face amount to spend; 0 means use full credit.
    function cashoutBondCredits(uint256 amountWei) external {
        _applyBondCredit(msg.sender, amountWei);
    }

    function bondCreditOf(address player) external view returns (uint256) {
        return bondCredit[player];
    }

    /// @notice Spend any claimable bond credits owed to `player` before paying ETH winnings.
    /// @param amountWei Optional cap on spend this call (0 = spend all).
    function _applyBondCredit(address player, uint256 amountWei) private {
        if (_autoLiquidateBondCredit(player)) return;
        ClaimableBondInfo storage info = claimableBondInfo[player];
        uint256 creditWei = info.weiAmount;
        if (creditWei == 0) return;
        if (amountWei == 0 || amountWei > creditWei) {
            amountWei = creditWei;
        }
        uint256 spend = amountWei;
        uint256 escrow = bondCreditEscrow;
        if (spend > escrow) {
            spend = escrow;
        }
        if (spend == 0) return;

        info.weiAmount = uint128(creditWei - spend);
        bondCreditEscrow = escrow - spend;

        address bondsAddr = bonds;
        if (bondsAddr == address(0)) {
            claimableWinningsLiability += spend;
            _addClaimableEth(player, spend);
            return;
        }

        try IDegenerusBonds(bondsAddr).depositCurrentFor{value: spend}(player) {
            // bond purchase succeeded
        } catch {
            // fallback to crediting winnings if bond deposit fails
            claimableWinningsLiability += spend;
            _addClaimableEth(player, spend);
        }
    }

    /// @notice Credit claimable ETH for a player from bond redemptions (bonds contract only).
    function creditBondWinnings(address player) external payable {
        if (msg.sender != bonds || player == address(0) || msg.value == 0) revert E();
        if (player == address(this)) {
            currentPrizePool += msg.value;
            return;
        }
        claimableWinningsLiability += msg.value;
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

    /// @notice Sample up to 100 trait burn tickets from a random trait and recent level (last 20 levels).
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
        address[] storage arr = traitBurnTicket[lvlSel][traitSel];
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
        uint256 returnWei = IDegenerusJackpots(jackpotsAddr).runDecimatorJackpot(pool, lvl, rngWord);

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
                IDegenerusGameJackpotModule.payMapJackpot.selector,
                lvl,
                rngWord,
                effectiveWei,
                IDegenerusCoinModule(address(coin))
            )
        );
        if (!ok) return;
    }

    function _calcPrizePoolForJackpot(uint24 lvl, uint256 rngWord) internal returns (uint256 effectiveWei) {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameJackpotModule.calcPrizePoolForJackpot.selector,
                lvl,
                rngWord,
                address(steth)
            )
        );
        if (!ok || data.length == 0) return 0;
        return abi.decode(data, (uint256));
    }

    // --- Daily & early‑burn jackpots ---------------------------------------------------------------

    function payDailyJackpot(bool isDaily, uint24 lvl, uint256 randWord) internal {
        (bool ok, ) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameJackpotModule.payDailyJackpot.selector,
                isDaily,
                lvl,
                randWord,
                IDegenerusCoinModule(address(coin))
            )
        );
        if (!ok) return;
    }

    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 randWord,
        uint256 ethPool
    ) external returns (uint256 paidEth) {
        if (msg.sender != address(this)) revert E();
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameJackpotModule.payExterminationJackpot.selector,
                lvl,
                traitId,
                randWord,
                ethPool,
                IDegenerusCoinModule(address(coin))
            )
        );
        if (!ok || data.length == 0) return 0;
        return abi.decode(data, (uint256));
    }

    function _handleJackpotLevelCap() internal returns (bool) {
        if (jackpotCounter >= JACKPOT_LEVEL_CAP) {
            _endLevel(TRAIT_ID_TIMEOUT);
            return false;
        }
        return true;
    }

    function drainToBonds() private {
        _drainToBondsModule();
        uint48 day = _currentDayIndex();
        gameState = 0;
        _requestRngBestEffort(day);
    }

    // --- Reward vault & liquidity -----------------------------------------------------

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

    // --- Flips, VRF, payments, rarity ----------------------------------------------------------------

    function rngAndTimeGate(uint48 day, uint24 lvl, bool isMapJackpotDay) internal returns (uint256 word) {
        if (day == dailyIdx) revert NotTimeYet();

        uint256 currentWord = rngFulfilled ? rngWordCurrent : 0;

        if (currentWord == 0 && rngLockedFlag && rngRequestTime != 0) {
            uint48 elapsed = uint48(block.timestamp) - rngRequestTime;
            if (elapsed >= 18 hours) {
                _requestRng(gameState, isMapJackpotDay, lvl, day);
                return 1;
            }
        }

        if (currentWord == 0) {
            if (rngLockedFlag) revert RngNotReady();
            _requestRng(gameState, isMapJackpotDay, lvl, day);
            return 1;
        }

        if (!rngLockedFlag) {
            // Stale entropy from previous cycle; request a fresh word.
            _requestRng(gameState, isMapJackpotDay, lvl, day);
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
            abi.encodeWithSelector(IDegenerusGameJackpotModule.processMapBatch.selector, writesBudget)
        );
        if (!ok || data.length == 0) return false;
        return abi.decode(data, (bool));
    }

    /// @notice Process pending jackpot bond mints outside the main game tick.
    /// @param maxMints Max bonds to mint this call (0 = default chunk size).
    function workJackpotBondMints(uint256 maxMints) external {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameJackpotModule.processPendingJackpotBonds.selector, maxMints)
        );
        if (!ok || data.length == 0) return;

        (, uint256 processed) = abi.decode(data, (bool, uint256));
        if (processed != 0 && maxMints == 0 && gameState != 0) {
            coin.creditFlip(msg.sender, priceCoin >> 1);
        }
    }

    /// @notice After the liveness drain has notified the bonds contract, permissionlessly burn remaining unmatured bonds.
    /// @param maxIds Number of token ids to scan in this call (0 = default chunk size in bonds).
    /// @return processedIds Token ids scanned.
    /// @return burned Bonds burned.
    /// @return complete True if shutdown burning is finished.
    function finalizeBondShutdown(uint256 maxIds) public returns (uint256 processedIds, uint256 burned, bool complete) {
        return IDegenerusBonds(bonds).finalizeShutdown(maxIds);
    }

    function _requestRngBestEffort(uint48 day) private returns (bool requested) {
        // Best-effort request that swallows VRF failures (used during idle shutdown).
        try
            vrfCoordinator.requestRandomWords(
                VRFRandomWordsRequest({
                    keyHash: vrfKeyHash,
                    subId: vrfSubscriptionId,
                    requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                    callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
                    numWords: 1,
                    extraArgs: bytes("")
                })
            )
        returns (uint256 id) {
            IDegenerusBonds(bonds).setTransfersLocked(true, day);
            vrfRequestId = id;
            rngFulfilled = false;
            rngWordCurrent = 0;
            rngLockedFlag = true;
            rngRequestTime = uint48(block.timestamp);

            return true;
        } catch {
            return false;
        }
    }

    function _requestRng(uint8 gameState_, bool isMapJackpotDay, uint24 lvl, uint48 day) private {
        bool shouldLockBonds = (gameState_ == 2 && isMapJackpotDay) || (gameState_ == 0);
        if (shouldLockBonds) {
            IDegenerusBonds(bonds).setTransfersLocked(true, day);
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
            (lvl % 100 == 0 && isMapJackpotDay)) && decWindowOpen);
        if (decClose) decWindowOpen = false;
    }

    /// @notice Rotate VRF coordinator + subscription id after a 3-day RNG stall.
    /// @dev Access: vrfAdmin (VRF owner contract).
    function updateVrfCoordinatorAndSub(address newCoordinator, uint256 newSubId, bytes32 newKeyHash) external {
        if (msg.sender != vrfAdmin) revert E();
        if (!_threeDayRngGap(_currentDayIndex())) revert VrfUpdateNotReady();
        _setVrfConfig(newCoordinator, newSubId, newKeyHash, address(vrfCoordinator));
    }

    function _setVrfConfig(address newCoordinator, uint256 newSubId, bytes32 newKeyHash, address current) private {
        if (newCoordinator == address(0) || newKeyHash == bytes32(0)) revert E();

        vrfCoordinator = IVRFCoordinator(newCoordinator);
        vrfSubscriptionId = newSubId;
        vrfKeyHash = newKeyHash;

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

    /// @notice Pay BURNIE to nudge the next RNG word by +1; cost scales +50% per queued nudge and resets after fulfillment.
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

    function _creditBurnFlip(
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
    }

    function _consumeTrait(uint8 traitId, uint32 endLevel) private returns (bool reachedZero) {
        // Trait counts are expected to be seeded for the current level; hitting zero here should only occur via burn flow.
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
        address[] storage a = traitBurnTicket[lvl][trait];
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
