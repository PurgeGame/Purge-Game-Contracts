// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGamepieces} from "./DegenerusGamepieces.sol";
import {IDegenerusCoinModule} from "./interfaces/DegenerusGameModuleInterfaces.sol";
import {IDegenerusCoin} from "./interfaces/IDegenerusCoin.sol";
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
import {DegenerusGameStorage} from "./storage/DegenerusGameStorage.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IDegenerusBonds {
    function bondMaintenance(uint256 rngWord, uint32 workCapOverride) external returns (bool done);
    function setRngLock(bool locked) external;
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
    error InvalidQuantity(); // Invalid quantity or token count for the action
    error VrfUpdateNotReady(); // VRF swap not allowed yet (not stuck long enough or randomness already received)

    // -----------------------
    // Events
    // -----------------------
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);
    event Degenerus(address indexed player, uint256[] tokenIds);
    event Advance(uint8 gameState);
    event ReverseFlip(address indexed caller, uint256 totalQueued, uint256 cost);
    event VrfCoordinatorUpdated(address indexed previous, address indexed current);

    // -----------------------
    // Immutable Addresses
    // -----------------------
    IDegenerusCoin private immutable coin; // Trusted coin/game-side coordinator (BURNIE ERC20)
    IDegenerusGamepieces private immutable nft; // ERC721 interface for mint/burn/metadata surface
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
    // [72-103]=last ETH day, [104-227]=reserved (legacy day/coin/agg tracking),
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
     * @param nftContract       ERC721 game contract
     * @param endgameModule_    Delegate module handling endgame settlement
     * @param jackpotModule_    Delegate module handling jackpot distribution
     * @param mintModule_       Delegate module handling mint packing and trait rebuild helpers
     * @param bondModule_       Delegate module handling bond upkeep, staking, and shutdown gameOvers
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
        address nftContract,
        address endgameModule_,
        address jackpotModule_,
        address mintModule_,
        address bondModule_,
        address stEthToken_,
        address jackpots_,
        address bonds_,
        address trophies_,
        address affiliateProgram_,
        address vault_,
        address vrfAdmin_
    ) {
        coin = IDegenerusCoin(degenerusCoinContract);
        nft = IDegenerusGamepieces(nftContract);
        endgameModule = endgameModule_;
        jackpotModule = jackpotModule_;
        mintModule = mintModule_;
        bondModule = bondModule_;
        if (vrfAdmin_ == address(0)) revert E();
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

    /// @notice Accept ETH for bond obligations or untracked yield; callable only by the bond contract.
    /// @param trackPool If true, credit to the tracked bondPool; if false, leave untracked as yield.
    function bondDeposit(bool trackPool) external payable onlyBonds {
        if (trackPool) {
            bondPool += msg.value;
        }
        // Untracked deposits fall through; yieldPool() treats excess balance as available.
    }

    /// @notice Credit bond winnings into claimable balance and burn from the bond pool.
    function bondCreditToClaimable(address player, uint256 amount) external onlyBonds {
        bondPool -= amount;
        claimablePool += amount;
        _addClaimableEth(player, amount);
    }

    /// @notice Batch credit bond winnings into claimable balance, burning from the bond pool once.
    function bondCreditToClaimableBatch(address[] calldata players, uint256[] calldata amounts) external onlyBonds {
        uint256 len = players.length;
        if (len != amounts.length) revert E();

        uint256 total;
        for (uint256 i; i < len; ) {
            uint256 amt = amounts[i];
            address player = players[i];
            if (amt != 0 && player != address(0)) {
                _addClaimableEth(player, amt);
                unchecked {
                    total += amt;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (total != 0) {
            bondPool -= total;
            claimablePool += total;
        }
    }

    /// @notice Convert a bond payout into MAP mints, debiting the bond pool.
    function bondSpendToMaps(address player, uint256 amount, uint32 quantity) external onlyBonds {
        if (bondGameOver) revert E();
        if (amount == 0 || quantity == 0 || player == address(0)) return;
        bondPool -= amount;
        nextPrizePool += amount;

        uint32 owed = playerMapMintsOwed[player];
        if (owed == 0) {
            pendingMapMints.push(player);
        }
        unchecked {
            playerMapMintsOwed[player] = owed + quantity;
        }
    }

    /// @notice View helper for bonds to know available ETH in the game-held bond pool.
    function bondAvailable() external view returns (uint256) {
        if (bondGameOver) return 0;
        return bondPool;
    }

    // --- View: lightweight game status -------------------------------------------------

    function prizePoolTargetView() external view returns (uint256) {
        return lastPrizePool;
    }

    function nextPrizePoolView() external view returns (uint256) {
        return nextPrizePool;
    }

    // --- State machine: advance one tick ------------------------------------------------

    function mintPrice() external view returns (uint256) {
        return price;
    }

    function coinPriceUnit() external pure returns (uint256) {
        return PRICE_COIN_UNIT;
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

    /// @notice One-time wiring of VRF config from the VRF admin contract.
    function wireVrf(address coordinator_, uint256 subId, bytes32 keyHash_) external {
        if (msg.sender != vrfAdmin) revert E();
        if (coordinator_ == address(0) || subId == 0 || keyHash_ == bytes32(0)) revert E();

        // Idempotent once wired: allow only no-op repeats with identical config.
        if (vrfSubscriptionId != 0) {
            if (subId != vrfSubscriptionId) revert E();
            if (coordinator_ != address(vrfCoordinator)) revert E();
            if (keyHash_ != vrfKeyHash) revert E();
            return;
        }

        address current = address(vrfCoordinator);
        vrfCoordinator = IVRFCoordinator(coordinator_);
        vrfSubscriptionId = subId;
        vrfKeyHash = keyHash_;
        emit VrfCoordinatorUpdated(current, coordinator_);
    }

    function decWindow() external view returns (bool on, uint24 lvl) {
        on = decWindowOpen && !rngLockedFlag;
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
        returns (uint24 lvl, uint8 gameState_, bool lastPurchaseDay_, bool rngLocked_, uint256 priceWei)
    {
        lvl = level;
        gameState_ = gameState;
        lastPurchaseDay_ = (gameState_ == 2) && lastPurchaseDay;
        rngLocked_ = rngLockedFlag;
        priceWei = price;

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

    function ethMintStats(address player) external view returns (uint24 lvl, uint24 levelCount, uint24 streak) {
        uint256 packed = mintPacked_[player];
        lvl = level;
        levelCount = uint24((packed >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
        streak = uint24((packed >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
    }

    /// @notice Record a mint, funded by ETH (`msg.value`) or claimable winnings.
    /// @dev ETH paths require `msg.value == costWei`. Claimable paths deduct from `claimableWinnings` and fund prize pools.
    ///      Combined allows any mix of ETH and claimable winnings (in that order) to cover `costWei`.
    function recordMint(
        address player,
        uint24 lvl,
        uint256 costWei,
        uint32 mintUnits,
        MintPaymentKind payKind
    ) external payable returns (uint256 coinReward) {
        if (msg.sender != address(nft)) revert E();
        uint256 amount = costWei;
        uint256 prizeContribution = _processMintPayment(player, amount, payKind);
        if (prizeContribution != 0) {
            nextPrizePool += prizeContribution;
        }

        coinReward = _recordMintDataModule(player, lvl, mintUnits);
    }

    /// @notice Track coinflip deposits during the last purchase day for prize pool tuning.
    function recordCoinflipDeposit(uint256 amount) external {
        if (msg.sender != address(coin)) revert E();
        if (amount == 0) return;
        if (gameState == 2 && lastPurchaseDay) {
            lastPurchaseDayFlipTotal += amount;
        }
    }

    function _processMintPayment(
        address player,
        uint256 amount,
        MintPaymentKind payKind
    ) private returns (uint256 prizeContribution) {
        uint256 claimableUsed;
        if (payKind == MintPaymentKind.DirectEth) {
            if (msg.value != amount) revert E();
            prizeContribution = amount;
        } else if (payKind == MintPaymentKind.Claimable) {
            if (msg.value != 0) revert E();
            uint256 claimable = claimableWinnings[player];
            if (claimable <= amount) revert E();
            unchecked {
                claimableWinnings[player] = claimable - amount;
            }
            claimableUsed = amount;
            prizeContribution = amount;
        } else if (payKind == MintPaymentKind.Combined) {
            if (msg.value > amount) revert E();
            uint256 remaining = amount - msg.value;
            if (remaining != 0) {
                uint256 claimable = claimableWinnings[player];
                if (claimable > 1) {
                    uint256 available = claimable - 1;
                    claimableUsed = remaining < available ? remaining : available;
                    if (claimableUsed != 0) {
                        unchecked {
                            claimableWinnings[player] = claimable - claimableUsed;
                        }
                        remaining -= claimableUsed;
                    }
                }
            }
            if (remaining != 0) revert E();
            prizeContribution = msg.value + claimableUsed;
        } else {
            revert E();
        }
        if (claimableUsed != 0) {
            if (claimablePool >= claimableUsed) {
                claimablePool -= claimableUsed;
            } else {
                claimablePool = 0;
            }
        }
        return prizeContribution;
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
        bool gameOver;
        uint8 _gameState = gameState;
        if (_gameState == 0) revert NotTimeYet(); //shutdown;
        // Liveness gameOver
        if (lst == LEVEL_START_SENTINEL) {
            uint48 deployTs = deployTimestamp;
            if (deployTs != 0 && uint256(ts) >= uint256(deployTs) + DEPLOY_IDLE_TIMEOUT) {
                gameOver = true;
            }
        } else if (ts - 365 days > lst && _gameState != 0) {
            gameOver = true;
        }
        if (gameOver) {
            gameOverDrainToBonds();
            return;
        }

        uint24 lvl = level;

        bool lastPurchase = (_gameState == 2) && lastPurchaseDay;

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
                bool dormantWorked = nft.processDormant(cap);
                if (dormantWorked) {
                    break;
                }
            }

            uint256 rngWord = rngAndTimeGate(day, lvl, lastPurchase);
            if (rngWord == 1) {
                break;
            }

            // Always run a map batch upfront; it no-ops when nothing is queued.
            (bool batchWorked, bool batchesFinished) = _runProcessMapBatch(cap); // single batch per call; break if any work was done
            if (batchWorked || !batchesFinished) break;

            if (bondMaintenancePending) {
                _runBondMaintenance(bonds, rngWord, cap, day);
                break;
            }

            // --- State 1 - Pregame ---
            if (_gameState == 1) {
                _runEndgameModule(lvl, rngWord); // handles payouts, wipes, endgame dist, and jackpots
                if (lastExterminatedTrait != TRAIT_ID_TIMEOUT) {
                    payCarryoverExterminationJackpot(lvl, uint8(lastExterminatedTrait), rngWord);
                }
                _stakeForTargetRatioModule(lvl);
                bool decOpen = ((lvl >= 25) && ((lvl % 10) == 5) && ((lvl % 100) != 95));
                // Preserve an already-open window for the level-100 decimator special until its RNG request closes it.
                if (!decWindowOpen && decOpen) {
                    decWindowOpen = true;
                }
                if (lvl % 100 == 99) decWindowOpen = true;
                _bondSetup(rngWord);
                break;
            }

            // --- State 2 - Purchase / Airdrop ---
            if (_gameState == 2) {
                if (!lastPurchaseDay) {
                    payDailyJackpot(false, lvl, rngWord);
                    if (nextPrizePool >= lastPrizePool) {
                        lastPurchaseDay = true;
                        lastPurchaseDayFlipTotal = 0;
                    }
                    _unlockRng(day);
                    break;
                }
                if (!mapJackpotPaid) {
                    if (lvl % 100 == 0) {
                        if (!_runDecimatorHundredJackpot(lvl, rngWord)) {
                            break; // keep working this jackpot slice before moving on
                        }
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
                if (airdropMultiplier == 0) {
                    airdropMultiplier = _calculateAirdropMultiplierModule(purchaseCountRaw, lvl);
                }
                if (!traitCountsSeedQueued) {
                    uint32 multiplier_ = airdropMultiplier;
                    if (!nft.processPendingMints(cap, multiplier_, rngWord)) {
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

                traitRebuildCursor = 0;
                airdropMultiplier = 0;
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
                payDailyJackpot(true, lvl, rngWord);
                if (!_handleJackpotLevelCap()) break;
                _unlockRng(day);
                break;
            }
        } while (false);

        emit Advance(_gameState);

        if (_gameState != 0 && cap == 0) coinContract.creditFlip(caller, PRICE_COIN_UNIT >> 1);
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
        uint256 priceCoinLocal = PRICE_COIN_UNIT;
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

            bool tokenWon;
            if (_consumeTrait(trait0, endLevelFlag)) {
                if (winningTrait == TRAIT_ID_TIMEOUT) winningTrait = trait0;
                tokenWon = true;
            }
            if (_consumeTrait(trait1, endLevelFlag)) {
                if (winningTrait == TRAIT_ID_TIMEOUT) winningTrait = trait1;
                tokenWon = true;
            }
            if (_consumeTrait(trait2, endLevelFlag)) {
                if (winningTrait == TRAIT_ID_TIMEOUT) winningTrait = trait2;
                tokenWon = true;
            }
            if (_consumeTrait(trait3, endLevelFlag)) {
                if (winningTrait == TRAIT_ID_TIMEOUT) winningTrait = trait3;
                tokenWon = true;
            }
            unchecked {
                dailyBurnCount[trait0 & 0x07] += 1;
                dailyBurnCount[((trait1 - 64) >> 3) + 8] += 1;
                dailyBurnCount[trait2 - 128 + 16] += 1;
                ++i;
            }

            tickets[trait0].push(caller);
            tickets[trait1].push(caller);
            tickets[trait2].push(caller);
            tickets[trait3].push(caller);

            if (tokenWon) {
                break;
            }
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
    /// - Pay the exterminator slice immediately (roll 20-40%, or fixed 40% when `prevLevel % 10 == 4` and `prevLevel > 4`).
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
        lastPurchaseDayFlipTotalPrev = lastPurchaseDayFlipTotal;
        lastPurchaseDayFlipTotal = 0;
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
    function _runEndgameModule(uint24 lvl, uint256 rngWord) internal {
        // Endgame settlement logic lives in DegenerusGameEndgameModule (delegatecall keeps state on this contract).
        (bool ok, bytes memory data) = endgameModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameEndgameModule.finalizeEndgame.selector,
                lvl,
                rngWord,
                jackpots,
                jackpotModule,
                IDegenerusCoinModule(address(coin)),
                address(nft)
            )
        );
        if (!ok) _revertDelegate(data);
    }

    function _revertDelegate(bytes memory reason) private pure {
        if (reason.length == 0) revert E();
        assembly ("memory-safe") {
            revert(add(32, reason), mload(reason))
        }
    }

    // --- Delegate helpers (mint module) --------------------------------------------------------------

    function _recordMintDataModule(address player, uint24 lvl, uint32 mintUnits) private returns (uint256 coinReward) {
        (bool ok, bytes memory data) = mintModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameMintModule.recordMintData.selector, player, lvl, mintUnits)
        );
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint256));
    }

    function _calculateAirdropMultiplierModule(uint32 purchaseCount, uint24 lvl) private returns (uint32) {
        (bool ok, bytes memory data) = mintModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameMintModule.calculateAirdropMultiplier.selector, purchaseCount, lvl)
        );
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint32));
    }

    function _purchaseTargetCountFromRawModule(uint32 rawCount) private returns (uint32) {
        (bool ok, bytes memory data) = mintModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameMintModule.purchaseTargetCountFromRaw.selector, rawCount)
        );
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint32));
    }

    function _rebuildTraitCountsModule(uint32 tokenBudget, uint32 target, uint256 baseTokenId) private {
        (bool ok, bytes memory data) = mintModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameMintModule.rebuildTraitCounts.selector,
                tokenBudget,
                target,
                baseTokenId
            )
        );
        if (!ok) _revertDelegate(data);
    }

    function _bondSetup(uint256 rngWord) private {
        (bool ok, bytes memory data) = bondModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameBondModule.bondUpkeep.selector,
                bonds,
                address(steth),
                address(coin),
                rngWord
            )
        );
        if (!ok) _revertDelegate(data);
        // Queue maintenance so the next advanceGame call runs it in isolation.
        bondMaintenancePending = true;
    }

    function _runBondMaintenance(address bondsAddr, uint256 rngWord, uint32 cap, uint48 day) private {
        bool done = IDegenerusBonds(bondsAddr).bondMaintenance(rngWord, cap);
        if (done) {
            gameState = 2; // enter purchase/airdrop state once bond maintenance is fully settled

            if (bondMaintenancePending) {
                bondMaintenancePending = false;
            }
            _unlockRng(day);
        } else if (!bondMaintenancePending) {
            bondMaintenancePending = true;
        }
    }

    function _stakeForTargetRatioModule(uint24 lvl) private {
        (bool ok, bytes memory data) = bondModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameBondModule.stakeForTargetRatio.selector, bonds, address(steth), lvl)
        );
        if (!ok) _revertDelegate(data);
    }

    /// @notice Unified external hook for trusted modules to adjust DegenerusGame accounting.
    /// @param op      Operation selector.
    /// @param account Player to credit (when applicable).
    /// @param amount  Wei amount associated with the operation.
    function applyExternalOp(DegenerusGameExternalOp op, address account, uint256 amount) external {
        if (op == DegenerusGameExternalOp.DecJackpotClaim) {
            _applyDecJackpotClaim(account, amount);
            return;
        }
        revert E();
    }

    /// @notice Batch variant for external modules to aggregate claimable accounting.
    function applyExternalOpBatch(
        DegenerusGameExternalOp op,
        address[] calldata accounts,
        uint256[] calldata amounts
    ) external {
        if (op == DegenerusGameExternalOp.DecJackpotClaim) {
            uint256 len = accounts.length;
            if (len != amounts.length) revert E();
            address jackpotsAddr = jackpots;
            if (msg.sender != jackpotsAddr) revert E();

            for (uint256 i; i < len; ) {
                uint256 amt = amounts[i];
                address account = accounts[i];
                if (amt != 0 && account != address(0)) {
                    _addClaimableEth(account, amt);
                }
                unchecked {
                    ++i;
                }
            }
            return;
        }
        revert E();
    }

    function _applyDecJackpotClaim(address account, uint256 amount) private {
        address jackpotsAddr = jackpots;
        if (jackpotsAddr == address(0) || msg.sender != jackpotsAddr) revert E();
        if (amount == 0 || account == address(0)) return;
        _addClaimableEth(account, amount);
    }

    // --- Claiming winnings (ETH) --------------------------------------------------------------------

    /// @notice Claim the caller’s accrued ETH winnings (affiliates, jackpots, bonds, endgame payouts).
    /// @dev Leaves a 1 wei sentinel so subsequent credits remain non-zero -> cheaper SSTORE.
    function claimWinnings() external {
        address player = msg.sender;
        uint256 amount = claimableWinnings[player];
        if (amount <= 1) revert E();
        uint256 payout;
        unchecked {
            claimableWinnings[player] = 1;
            payout = amount - 1;
        }
        claimablePool -= payout;
        _payoutWithStethFallback(player, payout);
    }

    function getWinnings() external view returns (uint256) {
        uint256 stored = claimableWinnings[msg.sender];
        if (stored <= 1) return 0;
        return stored - 1;
    }

    /// @notice Spend claimable ETH to purchase either NFTs or MAPs using the full available balance.
    /// @param mapPurchase If true, purchase MAPs; otherwise purchase NFTs.
    // Credit-based purchase entrypoints handled directly on the NFT contract to keep the game slimmer.

    /// @notice Sample up to 4 trait burn tickets from a random trait and recent level (last 20 levels).
    /// @param entropy Random seed used to select level, trait, and starting offset.
    function sampleTraitTickets(
        uint256 entropy
    ) external view returns (uint24 lvlSel, uint8 traitSel, address[] memory tickets) {
        uint24 currentLvl = level;
        if (currentLvl <= 1) {
            return (0, 0, new address[](0));
        }

        uint24 maxOffset = currentLvl - 1;
        if (maxOffset > 20) maxOffset = 20;

        uint256 word = entropy;
        uint24 offset;
        unchecked {
            offset = uint24(word % maxOffset) + 1; // 1..maxOffset
            lvlSel = currentLvl - offset;
        }

        traitSel = uint8(word >> 24); // use a disjoint byte from the VRF word
        address[] storage arr = traitBurnTicket[lvlSel][traitSel];
        uint256 len = arr.length;
        if (len == 0) {
            return (lvlSel, traitSel, new address[](0));
        }

        uint256 take = len > 4 ? 4 : len; // only need a small sample for scatter draws
        tickets = new address[](take);
        uint256 start = (word >> 40) % len; // consume another slice for the start offset
        for (uint256 i; i < take; ) {
            tickets[i] = arr[(start + i) % len];
            unchecked {
                ++i;
            }
        }
    }

    // --- Credits & jackpot helpers ------------------------------------------------------------------

    /// @notice Credit ETH winnings to a player’s claimable balance and emit an accounting event.
    /// @param beneficiary Player to credit.
    /// @param weiAmount   Amount in wei to add.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) internal {
        address recipient = beneficiary;
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
            rewardPool -= decPool + bafPool;
            decimatorHundredReady = true;
        }

        uint256 pool = decimatorHundredPool;

        address jackpotsAddr = jackpots;
        if (jackpotsAddr == address(0)) revert E();
        uint256 returnWei = IDegenerusJackpots(jackpotsAddr).runDecimatorJackpot(pool, lvl, rngWord);
        uint256 netSpend = pool - returnWei;
        if (netSpend != 0) {
            // Reserve the full decimator pool in `claimablePool` immediately; player credits occur on claim.
            claimablePool += netSpend;
        }

        if (returnWei != 0) {
            rewardPool += returnWei;
        }
        decimatorHundredPool = 0;
        decimatorHundredReady = false;
        return true;
    }

    // --- Map jackpot payout (end of purchase phase) -------------------------------------------------

    function payMapJackpot(uint24 lvl, uint256 rngWord, uint256 effectiveWei) internal {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameJackpotModule.payMapJackpot.selector,
                lvl,
                rngWord,
                effectiveWei,
                IDegenerusCoinModule(address(coin))
            )
        );
        if (!ok) _revertDelegate(data);
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
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint256));
    }

    // --- Daily & early‑burn jackpots ---------------------------------------------------------------

    function payDailyJackpot(bool isDaily, uint24 lvl, uint256 randWord) internal {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameJackpotModule.payDailyJackpot.selector,
                isDaily,
                lvl,
                randWord,
                IDegenerusCoinModule(address(coin))
            )
        );
        if (!ok) _revertDelegate(data);
    }

    function payCarryoverExterminationJackpot(uint24 lvl, uint8 traitId, uint256 randWord) internal {
        (bool ok, bytes memory data) = jackpotModule.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameJackpotModule.payCarryoverExterminationJackpot.selector,
                lvl,
                traitId,
                randWord,
                IDegenerusCoinModule(address(coin))
            )
        );
        if (!ok) _revertDelegate(data);
    }

    function _handleJackpotLevelCap() internal returns (bool) {
        if (jackpotCounter >= JACKPOT_LEVEL_CAP) {
            _endLevel(TRAIT_ID_TIMEOUT);
            return false;
        }
        return true;
    }

    function gameOverDrainToBonds() private {
        (bool ok, bytes memory data) = bondModule.delegatecall(
            abi.encodeWithSelector(IDegenerusGameBondModule.drainToBonds.selector, bonds, address(steth))
        );
        if (!ok) _revertDelegate(data);
        gameState = 0;
    }

    // --- Reward vault & liquidity -----------------------------------------------------

    /// @notice Swap ETH <-> stETH with the bonds contract to rebalance liquidity.
    /// @dev Access: bonds only. stEthForEth=true pulls stETH from bonds and sends back ETH; false stakes incoming ETH and forwards minted stETH.
    function swapWithBonds(bool stEthForEth, uint256 amount) external payable {
        if (msg.sender != bonds) revert E();

        if (stEthForEth) {
            if (msg.value != 0) revert E();
            if (!steth.transferFrom(msg.sender, address(this), amount)) revert E();

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

    /// @notice Admin-only swap: owner sends ETH in and receives game-held stETH.
    function adminSwapEthForStEth(address recipient, uint256 amount) external payable {
        if (msg.sender != vrfAdmin) revert E();
        if (recipient == address(0)) revert E();
        if (amount == 0 || msg.value != amount) revert E();

        uint256 stBal = steth.balanceOf(address(this));
        if (stBal < amount) revert E();
        if (!steth.transfer(recipient, amount)) revert E();
    }

    /// @notice Admin-only stake of game-held ETH into stETH.
    function adminStakeEthForStEth(uint256 amount) external {
        if (msg.sender != vrfAdmin) revert E();
        if (amount == 0) revert E();

        uint256 ethBal = address(this).balance;
        if (ethBal < amount) revert E();
        uint256 reserve = claimablePool;
        if (ethBal <= reserve) revert E();
        uint256 stakeable = ethBal - reserve;
        if (amount > stakeable) revert E();

        try steth.submit{value: amount}(address(0)) returns (uint256) {} catch {
            revert E();
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
                coin.processCoinflipPayouts(lvl, false, currentWord, day);
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
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (bool));
    }

    /// @dev Helper to run one map batch and detect whether any progress was made.
    /// @return worked True if airdropIndex or airdropMapsProcessedCount changed.
    /// @return finished True if all pending map mints have been fully processed.
    function _runProcessMapBatch(uint32 writesBudget) private returns (bool worked, bool finished) {
        uint32 prevIdx = airdropIndex;
        uint32 prevProcessed = airdropMapsProcessedCount;
        finished = _processMapBatch(writesBudget);
        worked = (airdropIndex != prevIdx) || (airdropMapsProcessedCount != prevProcessed);
    }

    function _requestRng(uint8 gameState_, bool isMapJackpotDay, uint24 lvl, uint48 /*day*/) private {
        bool shouldLockBonds = (gameState_ == 1) || (gameState_ == 3 && (jackpotCounter + 1) >= JACKPOT_LEVEL_CAP);
        if (shouldLockBonds) {
            IDegenerusBonds(bonds).setRngLock(true);
        }

        // Hard revert if Chainlink request fails; this intentionally halts game progress until VRF funding/config is fixed.
        uint256 id = vrfCoordinator.requestRandomWords(
            VRFRandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
                numWords: 1
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
        // In case bonds were locked during a stuck RNG window, attempt to release the lock during recovery.
        try IDegenerusBonds(bonds).setRngLock(false) {} catch {}
        emit VrfCoordinatorUpdated(current, newCoordinator);
    }

    function _unlockRng(uint48 day) private {
        dailyIdx = day;
        rngLockedFlag = false;
        vrfRequestId = 0;
        rngRequestTime = 0;
        // If bonds were locked for an RNG window, release the lock once this RNG window is over.
        try IDegenerusBonds(bonds).setRngLock(false) {} catch {}
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
        uint32[256] storage remaining = traitRemaining;
        uint32[256] storage startRemaining = traitStartRemaining;

        for (uint16 t; t < 256; ) {
            uint32 value = remaining[t];
            startRemaining[t] = value;
            unchecked {
                ++t;
            }
        }
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

    function startTraitRemaining(uint8 traitId) external view returns (uint32) {
        return traitStartRemaining[traitId];
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
