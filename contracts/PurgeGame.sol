// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Purge Game — Core NFT game contract
 * @notice This file defines the on-chain game logic surface (interfaces + core state).
 */

// ===========================================================================
// External Interfaces
// ===========================================================================

/**
 * @dev Interface to the PURGE ERC20 + game-side coordinator.
 *      All calls are trusted (set via constructor in the ERC20 contract).
 */
interface IPurgeCoinInterface {
    function bonusCoinflip(address player, uint256 amount, bool rngReady, uint256 luckboxBonus) external;
    function burnie(uint256 amount) external payable;
    function burnCoin(address target, uint256 amount) external;
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external;
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip,
        uint256 rngWord
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
    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory);
    function playerLuckbox(address player) external view returns (uint256);
}

/**
 * @dev Interface to the on-chain renderer used for tokenURI generation.
 */
interface IPurgeRenderer {
    function setStartingTraitRemaining(uint32[256] calldata values) external;
}

/**
 * @dev Minimal interface to the dedicated NFT contract owned by the game.
 */
interface IPurgeGameNFT {
    struct EndLevelRequest {
        address exterminator;
        uint16 traitId;
        uint24 level;
        uint256 pool;
    }

    enum TrophyKind {
        Map,
        Level,
        Affiliate,
        Stake,
        Baf,
        Decimator
    }

    function gameMint(address to, uint256 quantity) external returns (uint256 startTokenId);

    function purge(address owner, uint256[] calldata tokenIds) external;

    function awardTrophy(
        address to,
        uint24 level,
        TrophyKind kind,
        uint256 data,
        uint256 deferredWei
    ) external payable;

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        returns (address mapImmediateRecipient, address[6] memory affiliateRecipients);

    function prepareNextLevel(uint24 nextLevel) external;

    function clearStakePreview(uint24 level) external;

    function currentBaseTokenId() external view returns (uint256);

    function recordSeasonMinted(uint256 minted) external;

    function requestRng() external;

    function currentRngWord() external view returns (uint256);

    function rngLocked() external view returns (bool);

    function releaseRngLock() external;

    function isRngFulfilled() external view returns (bool);

    function recordEthMint(address player, uint24 level)
        external
        returns (uint256 coinReward, uint256 luckboxReward);

    function ethMintLastLevel(address player) external view returns (uint24);

    function levelStakeDiscount(address player) external view returns (uint8);

    function mapStakeDiscount(address player) external view returns (uint8);

    function affiliateStakeBonus(address player) external view returns (uint8);

    function stakedTrophySample(uint64 salt) external view returns (address);
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
    event TokenCreated(uint256 tokenId, uint32 tokenTraits);
    event Advance(uint8 gameState, uint8 phase);

    // -----------------------
    // Immutable Addresses
    // -----------------------
    IPurgeRenderer private immutable renderer; // Trusted renderer; used for tokenURI composition
    IPurgeCoinInterface private immutable coin; // Trusted coin/game-side coordinator (PURGE ERC20)
    IPurgeGameNFT private immutable nft; // ERC721 interface for mint/burn/metadata surface


    // -----------------------
    // Game Constants
    // -----------------------
    uint48 private constant JACKPOT_RESET_TIME = 82620; // Offset anchor for "daily" windows
    uint32 private constant NFT_AIRDROP_PLAYER_BATCH_SIZE = 210; // Max unique recipients per airdrop batch
    uint32 private constant NFT_AIRDROP_TOKEN_CAP = 3_000; // Max tokens distributed per airdrop batch
    uint32 private constant DEFAULT_PAYOUTS_PER_TX = 500; // Keeps participant payouts under ~16M gas
    uint32 private constant PURCHASE_MINIMUM = 1_500; // Minimum purchases to unlock game start
    uint32 private constant WRITES_BUDGET_SAFE = 800; // Keeps map batching within the ~16M gas budget
    uint72 private constant MAP_PERMILLE = 0x0A0A07060304050564; // Payout permilles packed (9 bytes)
    uint64 private constant MAP_LCG_MULT = 0x5851F42D4C957F2D; // LCG multiplier for map RNG slices
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200; // Marks trophies sourced from MAP jackpots
    uint8 private constant MAP_FIRST_BATCH = 8; // Consecutive daily jackpots on map-only levels before normal cadence resumes
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint256 private constant LUCKBOX_BYPASS_THRESHOLD = 100_000 * 1_000_000; // 100k PURGED (6 decimals)
    uint8 private constant EP_THIRTY_MASK = 4; // 30% early-purge threshold bit
    uint256 private constant PURCHASE_WEIGHT_TOTAL = 30;

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
    uint256 private carryoverForNextLevel; // Carryover amount reserved for the next level (wei)

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
    uint8 private earlyPurgeJackpotPaidMask; // Bitmask for early purge jackpots paid (progressive)
    uint8 private phase; // Airdrop sub-phase (0..7)
    uint16 private lastExterminatedTrait = TRAIT_ID_TIMEOUT; // The winning trait from the previous season (timeout sentinel)
    bool private jackpotActivityThisCycle; // Tracks if a daily, early-purge, or map jackpot ran this cycle

    // -----------------------
    // RNG Liveness Flags
    // -----------------------

    // -----------------------
    // Minting / Airdrops
    // -----------------------
    uint32 private purchaseCount; // Total purchased NFTs this level
    uint32 private airdropMapsProcessedCount; // Progress inside current map-mint player's queue
    uint32 private airdropIndex; // Progress across players in pending arrays

    address[] private pendingNftMints; // Queue of players awaiting NFT mints
    address[] private pendingMapMints; // Queue of players awaiting map mints

    mapping(address => uint32) private playerTokensOwed; // Player => NFTs owed
    mapping(address => uint32) private playerMapMintsOwed; // Player => map mints owed

    // -----------------------
    // Token / Trait State
    // -----------------------
    mapping(uint256 => uint32) private tokenTraits; // Packed 4×8-bit traits (low to high)
    mapping(address => uint256) private claimableWinnings; // ETH claims accumulated on-chain
    mapping(uint24 => address[][256]) private traitPurgeTicket; // level => traitId => ticket holders

    struct PendingEndLevel {
        address exterminator; // Non-zero means trait win; zero means map timeout
        uint24 level; // Level that just ended (0 sentinel = none pending)
        uint16 traitId; // Winning trait (valid when exterminator != address(0))
        uint256 sidePool; // Trait win: pool snapshot for trophy/exterminator splits; Map timeout: full carry pool snapshot
    }
    PendingEndLevel private pendingEndLevel;

    struct JackpotSpec {
        bool payInCoin; // true for coin jackpot (payout in PURGE)
        bool mapTrophy; // true when awarding the map trophy on the final category
    }

    // -----------------------
    // Daily / Trait Counters
    // -----------------------
    uint32[80] internal dailyPurgeCount; // Layout: 8 symbol, 8 color, 64 trait buckets
    uint32[256] internal traitRemaining; // Remaining supply per trait (0..255)

    // -----------------------
    // Constructor
    // -----------------------

    /**
     * @param purgeCoinContract Trusted PURGE ERC20 / game coordinator address
     * @param renderer_         Trusted on-chain renderer
     *
     * @dev ERC721 sentinel trophy token is minted lazily during the first transition to state 2.
     */
    constructor(address purgeCoinContract, address renderer_, address nftContract) {
        coin = IPurgeCoinInterface(purgeCoinContract);
        renderer = IPurgeRenderer(renderer_);
        nft = IPurgeGameNFT(nftContract);
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
    /// @return earlyPurgeMask   Bitmask of early-purge jackpot thresholds crossed (10/20/30/40/50/75%)
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
            uint8 earlyPurgeMask
        )
    {
        gameState_ = gameState;
        phase_ = phase;
        jackpotCounter_ = jackpotCounter;
        price_ = price;
        carry_ = carryoverForNextLevel;
        prizePoolTarget = lastPrizePool;
        prizePoolCurrent = prizePool;

        enoughPurchases = purchaseCount >= PURCHASE_MINIMUM;
        earlyPurgeMask = earlyPurgeJackpotPaidMask;

    }

    // --- State machine: advance one tick ------------------------------------------------

    /// @notice Advances the game state machine. Anyone can call, but certain steps
    ///         require the caller to meet a luckbox threshold (payment for work/luckbox bonus).
    /// @param cap Emergency unstuck function, in case a necessary transaction is too large for a block.
    ///            Using cap removes Purgecoin payment.
    function advanceGame(uint32 cap) external {
        uint48 ts = uint48(block.timestamp);
        IPurgeCoinInterface coinContract = coin;
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
        bool rngReady  = true;
        uint48 day = uint48((ts - JACKPOT_RESET_TIME) / 1 days);

        do {
            // Luckbox rewards
            if (cap == 0 && coinContract.playerLuckbox(msg.sender) < priceCoin * lvl * (lvl / 100 + 1) << 1)
                revert LuckboxTooSmall();
            uint256 rngWord = rngAndTimeGate(day);
            if (rngWord == 1) {
                rngReady = false;
                break;
            }
            // --- State 1 - Pregame ---
            if (_gameState == 1) {
                _finalizeEndgame(lvl, cap, day, rngWord); // handles payouts, wipes, endgame dist, and jackpots
                break;
            }

            // --- State 2 - Purchase / Airdrop ---
            if (_gameState == 2) {
                if (_phase <= 2) {
                    _updateEarlyPurgeJackpots(lvl);
                    bool prizeReady = prizePool >= lastPrizePool;
                    bool levelGate = (purchaseCount >= PURCHASE_MINIMUM && prizeReady);
                    if (modTwenty == 16) {
                        levelGate = prizeReady;
                    }
                    if (_phase == 2 && levelGate) {
                        if (_endJackpot(lvl, cap, day, true, rngWord, _phase)) {
                            phase = 3;
                        }
                        break;
                    }
                    if (airdropIndex < pendingMapMints.length) {
                        _processMapBatch(cap);
                        break;
                    }
                    if (jackpotCounter > 0) {
                        payDailyJackpot(false, lvl, rngWord);
                        break;
                    }
                    _endJackpot(lvl, cap, day, false, rngWord, _phase);
                    break;
                }

                if (_phase == 3) {
                    if (
                        jackpotCounter == 0 && airdropIndex == 0 && airdropMapsProcessedCount == 0
                    ) {
                        renderer.setStartingTraitRemaining(traitRemaining);
                    }
                    if (_processMapBatch(cap)) {
                        phase = 4;
                        airdropIndex = 0;
                        airdropMapsProcessedCount = 0;
                    }
                    break;
                }

                if (_phase == 4) {
                    if (payMapJackpot(cap, lvl, rngWord)) {
                        phase = 5;
                    }
                    break;
                }

                if (_phase == 5) {
                    if (_processNftBatch(cap)) {
                        delete pendingNftMints;
                        delete pendingMapMints;
                        airdropIndex = 0;
                        airdropMapsProcessedCount = 0;
                        earlyPurgeJackpotPaidMask = 0;
                        phase = 6;
                    }
                    break;
                }

                if (_endJackpot(lvl, cap, day, false, rngWord, _phase)) {
                    nft.recordSeasonMinted(purchaseCount);
                    levelStartTime = ts;
                    gameState = 3;
                }
                break;
            }

            // --- State 3 - Purge ---
            if (_gameState == 3) {
                if (_phase == 6) {
                    if (modTwenty == 16 && jackpotCounter < MAP_FIRST_BATCH) {
                        while (jackpotCounter < MAP_FIRST_BATCH) {
                            payDailyJackpot(true, lvl, rngWord);
                            if (gameState != 3) break;
                        }
                    } else {
                        payDailyJackpot(true, lvl, rngWord);
                    }
                    if (gameState != 3) break;
                    phase = 7;
                    break;
                }
                if (_endJackpot(lvl, cap, day, false, rngWord, _phase)) phase = 6;
                break;
            }

            // --- State 0 ---
            if (_gameState == 0) {
                _endJackpot(lvl, cap, day, false, rngWord, _phase);
            }
        } while (false);

        emit Advance(_gameState, _phase);

        if (_gameState != 0 && cap == 0) coinContract.bonusCoinflip(msg.sender, priceCoin, rngReady, 0);
    }


    // --- Purchases: schedule NFT mints (traits precomputed) ----------------------------------------

    /// @notice Records a purchase during state 2, either paying in Purgecoin or ETH.
    /// @dev
    /// - ETH path forwards affiliate credit to the coin contract.
    /// - No NFTs are minted here; this only schedules mints and precomputes traits.
    /// - Traits are derived from the current VRF word snapshot (`rngWord`) at call time.
    /// @param quantity Number of base items to purchase (1..100).
    /// @param payInCoin If true, burn Purgecoin instead of paying ETH.
    /// @param affiliateCode Optional affiliate code for ETH purchases (ignored for coin payments).
    function purchase(uint256 quantity, bool payInCoin, bytes32 affiliateCode) external payable {
        uint8 _phase = phase;
        uint24 lvl = level;
        uint8 state = gameState;
        if (quantity == 0 || quantity > 100) revert InvalidQuantity();
        if (state == 3) revert NotTimeYet();
        if ((lvl % 20) == 16) revert NotTimeYet();
        uint256 _priceCoin = priceCoin;
        _enforceCenturyLuckbox(lvl, _priceCoin);
        if (nft.rngLocked()) revert RngNotReady();

        // Payment handling (ETH vs coin)
        uint256 bonusCoinReward = (quantity / 10) * _priceCoin;
        if (payInCoin) {
            if (msg.value != 0) revert E();
            _ensureEpThirtyUnlocked(lvl);
            _coinReceive(quantity * _priceCoin, lvl, bonusCoinReward);
        } else {
            // Scale quantity by 100 so `_ethReceive` can keep integer math.
            (uint256 bonus, uint256 luckboxBonus) = _ethReceive(quantity * 100, affiliateCode, quantity, lvl, false);
            if (_phase == 3 && (lvl % 100) > 90) {
                bonus += (quantity * _priceCoin) / 5;
            }
            bonus += bonusCoinReward;
            if (bonus != 0 || luckboxBonus != 0) coin.bonusCoinflip(msg.sender, bonus, true, luckboxBonus);
        }

        // Push buyer to the pending list once (de-dup)
        if (playerTokensOwed[msg.sender] == 0) {
            pendingNftMints.push(msg.sender);
        }

        // Precompute traits for future mints using the current RNG snapshot.
        // NOTE: tokenIds are not minted yet; only trait counters are updated.
        uint256 baseTokenId = nft.currentBaseTokenId();
        uint256 tokenIdStart = baseTokenId + uint256(purchaseCount);
        for (uint32 i; i < quantity; ) {
            uint256 _tokenId = tokenIdStart + i;
            uint256 rand = uint256(keccak256(abi.encodePacked(_tokenId, lvl)));
            uint8 tA = _getTrait(uint64(rand));
            uint8 tB = _getTrait(uint64(rand >> 64)) | 64;
            uint8 tC = _getTrait(uint64(rand >> 128)) | 128;
            uint8 tD = _getTrait(uint64(rand >> 192)) | 192;

            // Pack 4x8-bit traits (A,B,C,D) into 32 bits.
            uint32 _tokenTraits = uint32(tA) | (uint32(tB) << 8) | (uint32(tC) << 16) | (uint32(tD) << 24);
            tokenTraits[_tokenId] = _tokenTraits;

            // Increment remaining counts for each tier-mapped trait bucket.
            unchecked {
                traitRemaining[tA] += 1; // base 0..63
                traitRemaining[tB] += 1; // 64..127
                traitRemaining[tC] += 1; // 128..191
                traitRemaining[tD] += 1; // 192..255
            }
            unchecked {
                ++i;
            }
            emit TokenCreated(_tokenId, _tokenTraits);
        }

        // Accrue scheduled mints to the buyer
        unchecked {
            uint32 qty32 = uint32(quantity);
            playerTokensOwed[msg.sender] += qty32;
            purchaseCount += qty32;
        }
    }

    // --- “Mint & Purge” map flow: schedule symbol drops --------------------------------------------

    /// @notice Buys map symbols in state 2 and immediately schedules purge-map entries.
    /// @dev
    /// - Requires the current RNG word to be already consumed (fresh session).
    /// - ETH path: converts qualifying rebates into a bonus coinflip credit.
    /// - No on-chain burning/minting of NFTs here; symbols are scheduled and later batched.
    /// @param quantity Number of map entries requested (≥1).
    /// @param payInCoin If true, pay with Purgecoin (with level-conditional multiplier).
    /// @param affiliateCode Optional affiliate code for ETH payments.
    function mintAndPurge(uint256 quantity, bool payInCoin, bytes32 affiliateCode) external payable {
        uint256 priceUnit = priceCoin;
        uint8 _phase = phase;
        uint8 state = gameState;
        if (quantity == 0) revert InvalidQuantity();
        uint24 lvl = level;
        if (state == 3) {
            unchecked {
                ++lvl;
            }
        }
        if (nft.rngLocked()) revert RngNotReady();
        _enforceCenturyLuckbox(lvl, priceUnit);
        // Pricing / rebates
        uint256 coinCost = quantity * (priceUnit / 4);
        uint256 scaledQty = quantity * 25; // Scale to quarter units; divided by 100 within `_ethReceive`
        uint256 mapRebate = (quantity / 4) * (priceUnit / 10);
        uint256 mapBonus = (quantity / 40) * priceUnit;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            _ensureEpThirtyUnlocked(lvl);
            _coinReceive(coinCost - mapRebate, lvl, mapBonus);
        } else {
            (uint256 bonus, uint256 luckboxBonus) = _ethReceive(
                scaledQty,
                affiliateCode,
                (lvl < 10) ? quantity : 0,
                lvl,
                true
            );
            if (_phase == 3 && (lvl % 100) > 90) {
                bonus += coinCost / 5;
            }
            uint256 rebateMint = bonus + mapRebate + mapBonus;
            if (rebateMint != 0 || luckboxBonus != 0) coin.bonusCoinflip(msg.sender, rebateMint, true, luckboxBonus);
        }

        if (playerMapMintsOwed[msg.sender] == 0) pendingMapMints.push(msg.sender);
        unchecked {
            playerMapMintsOwed[msg.sender] += uint32(quantity);
        }
    }
    // --- Purging NFTs into tickets & potentially ending the level -----------------------------------

    /// @notice Burn up to 75 owned NFTs to contribute purge tickets; may end the level if a trait hits zero.
    /// @dev
    /// Security:
    /// - Requires `gameState == 3` and a consumed RNG session.
    /// Accounting:
    /// - For each token, burns it, updates daily counters and remaining-per-trait,
    ///   and appends four tickets (one per trait) to the current level’s buckets.
    /// - If any trait’s remaining count reaches 0 during the loop, `_endLevel(trait)` is invoked
    ///   and the function returns immediately (tickets for that *last* NFT are not recorded).
    /// Rewards:
    /// - Grants a Purgecoin coinflip credit: base `n` plus up to +0.9×n (in tenths) if the NFT
    ///   included last level’s exterminated trait.
    function purge(uint256[] calldata tokenIds) external {
        if (nft.rngLocked()) revert RngNotReady();
        if (gameState != 3) revert NotTimeYet();

        uint256 count = tokenIds.length;
        if (count == 0 || count > 75) revert InvalidQuantity();
        address caller = msg.sender;
        nft.purge(caller, tokenIds);

        uint24 lvl = level;

        uint16 prevExterminated = lastExterminatedTrait;
        uint256 bonusTenths;

        address[][256] storage tickets = traitPurgeTicket[lvl];

        uint16 winningTrait = TRAIT_ID_TIMEOUT;
        for (uint256 i; i < count; ) {
            uint256 tokenId = tokenIds[i];

            uint32 traits = tokenTraits[tokenId];
            uint8 trait0 = uint8(traits & 0xFF);
            uint8 trait1 = (uint8(traits >> 8) & 0xFF);
            uint8 trait2 = (uint8(traits >> 16) & 0xFF);
            uint8 trait3 = (uint8(traits >> 24) & 0xFF);

            uint8 color0 = trait0 >> 3;
            uint8 color1 = (trait1 & 0x3F) >> 3;
            uint8 color2 = (trait2 & 0x3F) >> 3;
            uint8 color3 = (trait3 & 0x3F) >> 3;
            if (color0 == color1 && color0 == color2 && color0 == color3) {
                unchecked {
                    bonusTenths += 49;
                }
            }

            if (lvl == 90) {
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

            unchecked {
                uint32 endLevel = (lvl % 10 == 7) ? 1 : 0;

                if (--traitRemaining[trait0] == endLevel) {
                    winningTrait = trait0;
                    break;
                }
                if (--traitRemaining[trait1] == endLevel) {
                    winningTrait = trait1;
                    break;
                }
                if (--traitRemaining[trait2] == endLevel) {
                    winningTrait = trait2;
                    break;
                }
                if (--traitRemaining[trait3] == endLevel) {
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

        if (lvl % 10 == 2) count <<= 1;
        coin.bonusCoinflip(caller, (count + bonusTenths) * (priceCoin / 10), true, 0);
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
            uint256 pool = prizePool;


            uint16 prev = lastExterminatedTrait;
            if (exterminated == prev ||levelSnapshot == 90) {
                uint256 keep = pool >> 1;
                carryoverForNextLevel += keep;
                pool -= keep;
            }

            uint256 ninetyPercent = (pool * 90) / 100;
            uint256 exterminatorShare = (levelSnapshot % 10 == 4 && levelSnapshot != 4)
                ? (pool * 40) / 100
                : (pool * 20) / 100;
            uint256 participantShare = ninetyPercent - exterminatorShare;

            uint256 ticketsLen = traitPurgeTicket[levelSnapshot][exTrait].length;
            prizePool = (ticketsLen == 0) ? 0 : (participantShare / ticketsLen);

            pend.exterminator = exterminator;
            pend.traitId = exTrait;
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
            pend.traitId = 0;
            pend.sidePool = poolCarry;

            prizePool = 0;
            lastExterminatedTrait = TRAIT_ID_TIMEOUT;
        }

        uint24 nextLevel = levelSnapshot + 1;
        nft.prepareNextLevel(nextLevel);

        unchecked {
            levelSnapshot++;
            level++;
        }

        for (uint16 t; t < 256; ) {
            traitRemaining[t] = 0;
            unchecked {
                ++t;
            }
        }
        jackpotCounter = 0;

        uint256 mod100 = levelSnapshot % 100;
        if (mod100 == 10 || mod100 == 0) {
            price <<= 1;
        } else if (levelSnapshot % 20 == 0) {
            price += (levelSnapshot < 100) ? 0.05 ether : 0.1 ether;
        }

        purchaseCount = 0;
        gameState = 1;
    }

    /// @notice Resolve prior level endgame in bounded slices and advance to purchase when ready.
    /// @dev Order: (A) participant payouts -> (B) ticket wipes -> (C) affiliate/trophy/exterminator
    ///      -> (D) finish coinflip payouts (jackpot end) and move to state 2.
    ///      Pass `cap` from advanceGame to keep tx gas ≤ target.
    function _finalizeEndgame(uint24 lvl, uint32 cap, uint48 day, uint256 rngWord) internal {
        PendingEndLevel storage pend = pendingEndLevel;

        uint8 _phase = phase;
        uint24 prevLevel = lvl - 1;
        uint8 prevMod10 = uint8(prevLevel % 10);
        uint8 prevMod100 = uint8(prevLevel % 100);

        if (_phase > 3) {
            if (lastExterminatedTrait != TRAIT_ID_TIMEOUT) {
                if (prizePool != 0) {
                    _payoutParticipants(cap, prevLevel);
                    return;
                }

                uint256 poolTotal = levelPrizePool;

                pend.level = prevLevel;
                pend.sidePool = poolTotal;

                levelPrizePool = 0;
            }

            if (_endJackpot(lvl, cap, day, false, rngWord, _phase)) {
                phase = 0;
                return;
            }
        } else {
            bool decWindow = prevLevel >= 25 && prevMod10 == 5 && prevMod100 != 95;
            if (decWindow) {
                uint256 decPoolWei = (carryoverForNextLevel * 15) / 100;
                (bool decFinished, ) = _progressExternal(1, decPoolWei, cap, prevLevel, rngWord);
                if (!decFinished) return;
            }

            if (lvl > 1) {
                _clearDailyPurgeCount();

                prizePool = 0;
                phase = 0;
            }
            uint256 pendingPool = nextPrizePool;
            if (pendingPool != 0) {
                prizePool = pendingPool;
                nextPrizePool = 0;
            }
            gameState = 2;
        }

        if (pend.level == 0) {
            return;
        }

        bool traitWin = pend.exterminator != address(0);
        uint24 prevLevelPending = pend.level;
        uint256 poolValue = pend.sidePool;

        if (traitWin) {
            uint256 exterminatorShare = (prevLevelPending % 10 == 4 && prevLevelPending != 4)
                ? (poolValue * 40) / 100
                : (poolValue * 20) / 100;

            uint256 immediate = exterminatorShare >> 1;
            uint256 deferredWei = exterminatorShare - immediate;
            _addClaimableEth(pend.exterminator, immediate);

            uint256 sharedPool = poolValue / 20;
            uint256 base = sharedPool / 100;
            uint256 remainder = sharedPool - (base * 100);
            uint256 affiliateTrophyShare = base * 20 + remainder;
            uint256 legacyAffiliateShare = base * 10;
            uint256[6] memory affiliatePayouts = [
                base * 20,
                base * 20,
                base * 10,
                base * 8,
                base * 7,
                base * 5
            ];

            address[] memory affLeaders = coin.getLeaderboardAddresses(1);
            address affiliateTrophyRecipient = affLeaders.length != 0 ? affLeaders[0] : pend.exterminator;
            if (affiliateTrophyRecipient == address(0)) {
                affiliateTrophyRecipient = pend.exterminator;
            }

            (, address[6] memory affiliateRecipients) = nft.processEndLevel{value: deferredWei + affiliateTrophyShare + legacyAffiliateShare}(
                IPurgeGameNFT.EndLevelRequest({
                    exterminator: pend.exterminator,
                    traitId: pend.traitId,
                    level: prevLevelPending,
                    pool: poolValue
                })
            );
            for (uint8 i; i < 6; ) {
                address recipient = affiliateRecipients[i];
                if (recipient == address(0)) {
                    recipient = affiliateTrophyRecipient;
                }
                uint256 amount = affiliatePayouts[i];
                if (amount != 0) {
                    _addClaimableEth(recipient, amount);
                }
                unchecked {
                    ++i;
                }
            }

            // mapImmediateRecipient is unused for trait wins
        } else {
            uint256 poolCarry = poolValue;
            uint256 mapUnit = poolCarry / 20;
            address[] memory affLeaders = coin.getLeaderboardAddresses(1);
            address topAffiliate = affLeaders.length != 0 ? affLeaders[0] : address(0);
            uint256 affiliateAward = topAffiliate == address(0) ? 0 : mapUnit;
            uint256 mapPayoutValue = mapUnit * 4 + affiliateAward;

            (address mapRecipient, address[6] memory mapAffiliates) = nft.processEndLevel{value: mapPayoutValue}(
                IPurgeGameNFT.EndLevelRequest({
                    exterminator: topAffiliate,
                    traitId: TRAIT_ID_TIMEOUT,
                    level: prevLevelPending,
                    pool: poolCarry
                })
            );
            mapAffiliates;
            _addClaimableEth(mapRecipient, mapUnit);
        }

        delete pendingEndLevel;

        coin.resetAffiliateLeaderboard(lvl);
    }

    function _payoutParticipants(uint32 capHint, uint24 prevLevel) internal {
        address[] storage arr = traitPurgeTicket[prevLevel][uint8(lastExterminatedTrait)];
        uint32 len = uint32(arr.length);
        if (len == 0) {
            prizePool = 0;
            return;
        }

        uint32 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint32 i = airdropIndex;
        uint32 end = i + cap;
        if (end > len) end = len;

        uint256 unitPayout = prizePool;
        if (end == len) {
            prizePool = 0;
        }

        while (i < end) {
            address w = arr[i];
            uint32 run = 1;
            unchecked {
                while (i + run < end && arr[i + run] == w) ++run; // coalesce contiguous
            }
            _addClaimableEth(w, unitPayout * run);
            unchecked {
                i += run;
            }
        }

        airdropIndex = i;
        if (i == len) {
            airdropIndex = 0;
        } // finished (tickets can be wiped)
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

    /// @notice Map jackpot specification for a given bucket index.
    /// @dev Returns the number of winners and the bucket’s permille share of the prize.
    ///      Index layout (0..8) corresponds to distinct trait groups.
    /// @param index Bucket index.
    /// @return winnersN Number of winners to draw for this bucket.
    /// @return permille Permille share (out of 1000) allocated to this bucket.
    function _mapSpec(uint8 index) internal pure returns (uint8 winnersN, uint8 permille) {
        winnersN = (index & 1) == 1 ? 1 : (index == 0 ? 1 : 20);
        permille = uint8(MAP_PERMILLE >> (uint256(index) * 8));
    }

    /// @notice Expose trait-ticket sampling (view helper for coinJackpot).
    function getJackpotWinners(
        uint256 randomWord,
        uint8 trait,
        uint8 numWinners,
        uint8 salt
    ) external view returns (address[] memory) {
        return _randTraitTicket(traitPurgeTicket[level], randomWord, trait, numWinners, salt);
    }

    // --- Map jackpot payout (end of purchase phase) -------------------------------------------------

    /// @notice Compute carry split, set the new prize pool, and pay the map jackpot using the shared trait flow.
    /// @dev The four traits each receive 20% of the pool; the final winner on trait[0] receives the map trophy (half direct, half deferred).
    function payMapJackpot(uint32 cap, uint24 lvl, uint256 rngWord) internal returns (bool finished) {
        uint256 carryWei = carryoverForNextLevel;
        uint8 lvlMod20 = uint8(lvl % 20);

        // External jackpots first (may need multiple calls)
        if (lvlMod20 == 0) {
            uint256 bafPoolWei = (carryWei * 24) / 100;
            (bool finishedBaf, ) = _progressExternal(0, bafPoolWei, cap, lvl, rngWord);
            if (!finishedBaf) return false;
            carryWei = carryoverForNextLevel;
        }

        uint256 totalWei = carryWei + prizePool;
        uint256 lvlMod100 = lvl % 100;
        uint8 lvlMod10 = uint8(lvlMod100 % 10);
        coin.burnie((totalWei * 5 * priceCoin) / 1 ether);

        // Save % for next level (randomized bands per range)
        uint256 rndWord = rngWord;
        uint256 savePct;
        if (lvlMod100 == 0) {
            // Two d12 rolls (capped at 20%) decide how much carryover persists into the next level.
            uint256 rollA = (uint256(uint64(rndWord)) * 12) >> 64;
            uint256 rollB = (uint256(uint64(rndWord >> 64)) * 12) >> 64;
            savePct = rollA + rollB + 2;
            if (savePct > 20) savePct = 20;
        } else {
            if ((rndWord % 1_000_000_000) == TRAIT_ID_TIMEOUT) {
                savePct = 10;
            } else if (lvl < 10) savePct = uint256(lvl) * 5;
            else if (lvl < 20) savePct = 55 + (rndWord % 16);
            else if (lvl < 40) savePct = 55 + (rndWord % 21);
            else if (lvl < 60) savePct = 60 + (rndWord % 21);
            else if (lvl < 80) savePct = 60 + (rndWord % 26);
            else if (lvl == 99) savePct = 93;
            else savePct = 65 + (rndWord % 26);
            if (lvlMod10 == 9) savePct += 5;
        }

        uint256 saveNextWei = (totalWei * savePct) / 100;
        carryoverForNextLevel = saveNextWei;
        uint256 effectiveWei = totalWei - saveNextWei;

        lastPrizePool = prizePool;
        prizePool = effectiveWei;

        uint8[4] memory winningTraits = _getRandomTraits(rndWord);

        JackpotSpec memory spec = JackpotSpec({payInCoin: false, mapTrophy: true});

        (uint256 paidWei, ) = _runJackpot(spec, lvl, effectiveWei, rndWord ^ (uint256(lvl) << 200), winningTraits);

        uint256 remainingPool = effectiveWei > paidWei ? effectiveWei - paidWei : 0;
        prizePool = remainingPool;
        levelPrizePool = remainingPool;

        jackpotActivityThisCycle = true;
        emit Jackpot(
            (uint256(9) << 248) |
                uint256(winningTraits[0]) |
                (uint256(winningTraits[1]) << 8) |
                (uint256(winningTraits[2]) << 16) |
                (uint256(winningTraits[3]) << 24)
        );
        return true;
    }

    // --- Daily & early‑purge jackpots ---------------------------------------------------------------

    /// @notice Pay daily or early‑purge jackpots (ETH payouts) using the shared trait distribution.
    /// @dev Rolls four traits, assigns 20% of the pool to each, and pays {25,15,10,1} winners (scaled by level band) evenly per trait.
    function payDailyJackpot(bool isDaily, uint24 lvl, uint256 randWord) internal {
        jackpotActivityThisCycle = true;
        uint8[4] memory winningTraits;
        if (isDaily) {
            winningTraits = _getWinningTraits(randWord, dailyPurgeCount);
        } else {
            unchecked {
                randWord = ((randWord << 64) | (randWord >> 192)) ^ (uint256(jackpotCounter) << 128) ^ 0x05;
            }
            winningTraits = _getRandomTraits(randWord);
        }

        uint256 poolWei;
        if (isDaily) {
            poolWei = (levelPrizePool * (250 + uint256(jackpotCounter) * 50)) / 10_000;
        } else {
            uint256 baseWei = carryoverForNextLevel;
            if ((lvl % 20) == 0) poolWei = baseWei / 100;
            else if (lvl >= 21 && (lvl % 10) == 1) poolWei = (baseWei * 6) / 100;
            else poolWei = baseWei / 40;
        }

        JackpotSpec memory spec = JackpotSpec({payInCoin: false, mapTrophy: false});

        (uint256 paidWei, ) = _runJackpot(spec, lvl, poolWei, randWord ^ (uint256(lvl) << 192), winningTraits);

        emit Jackpot(
            (uint256(4) << 248) |
                uint256(winningTraits[0]) |
                (uint256(winningTraits[1]) << 8) |
                (uint256(winningTraits[2]) << 16) |
                (uint256(winningTraits[3]) << 24)
        );

        if (isDaily) {
            unchecked {
                ++jackpotCounter;
            }
            uint256 currentPool = prizePool;
            prizePool = paidWei > currentPool ? 0 : currentPool - paidWei;
            if (jackpotCounter >= 15) {
                _endLevel(TRAIT_ID_TIMEOUT);
                return;
            }
            _clearDailyPurgeCount();
        } else {
            unchecked {
                if (jackpotCounter != 0) {
                    --jackpotCounter;
                }
            }
            uint256 carry = carryoverForNextLevel;
            carryoverForNextLevel = paidWei > carry ? 0 : carry - paidWei;
            if (jackpotCounter >= 15) {
                _endLevel(TRAIT_ID_TIMEOUT);
                return;
            }
        }
    }

    function _endJackpot(
        uint24 lvl,
        uint32 cap,
        uint48 dayIdx,
        bool bonusFlip,
        uint256 rngWord,
        uint8 phaseSnapshot
    )
        private
        returns (bool ok)
    {
        uint8 lvlMod20 = uint8(lvl % 20);
        bool triggerCoinJackpot = !jackpotActivityThisCycle;

        if (phaseSnapshot >= 3 || lvlMod20 != 0) {
            ok = coin.processCoinflipPayouts(lvl, cap, bonusFlip, rngWord);
            if (!ok) return false;
        }
        if (triggerCoinJackpot) {
            _executeCoinJackpot(lvl, uint256(keccak256(abi.encodePacked(rngWord, lvl, "coin"))));
        }
        jackpotActivityThisCycle = false;
        nft.releaseRngLock();
        dailyIdx = dayIdx;
        return true;
    }

    /// @notice Track early‑purge jackpot thresholds as the prize pool grows during purchase phase.
    /// @dev
    /// - Compares current `prizePool` to `lastPrizePool` as a percentage and sets a 6‑bit mask for
    ///   thresholds {10,20,30,40,50,75}%.
    /// - Increments `jackpotCounter` by the number of newly crossed thresholds since the last call
    ///   using a popcount trick on the delta mask.
    function _updateEarlyPurgeJackpots(uint24 lvl) internal {
        if (lvl == 99) return;

        uint256 prevPoolWei = lastPrizePool;

        uint256 pctOfLast = (prizePool * 100) / prevPoolWei;

        uint8 targetMask = (pctOfLast >= 10 ? uint8(1) : 0) |
            (pctOfLast >= 20 ? uint8(2) : 0) |
            (pctOfLast >= 30 ? uint8(4) : 0) |
            (pctOfLast >= 40 ? uint8(8) : 0) |
            (pctOfLast >= 50 ? uint8(16) : 0) |
            (pctOfLast >= 75 ? uint8(32) : 0);

        uint8 paidMask = earlyPurgeJackpotPaidMask;
        earlyPurgeJackpotPaidMask = targetMask;

        if (lvl < 10) return;

        uint8 addMask = targetMask & ~paidMask;
        if (addMask == 0) return;

        uint8 newCountBits = addMask;
        unchecked {
            newCountBits = newCountBits - ((newCountBits >> 1) & 0x55);
            newCountBits = (newCountBits & 0x33) + ((newCountBits >> 2) & 0x33);
            newCountBits = (newCountBits + (newCountBits >> 4)) & 0x0F;
        }

        jackpotCounter += newCountBits;
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
    function _ethReceive(
        uint256 scaledQty,
        bytes32 affiliateCode,
        uint256 bonusUnits,
        uint24 lvl,
        bool mapPurchase
    ) private returns (uint256 bonusMint, uint256 luckboxBonus) {
        uint256 expectedWei = (price * scaledQty) / 100;
        address payer = msg.sender;
        if (mapPurchase) {
            uint8 mapDiscount = nft.mapStakeDiscount(payer);
            if (mapDiscount != 0) {
                uint256 discountWei = (expectedWei * mapDiscount) / 100;
                expectedWei -= discountWei;
            }
        } else {
            uint8 levelDiscount = nft.levelStakeDiscount(payer);
            if (levelDiscount != 0) {
                uint256 discountWei = (expectedWei * levelDiscount) / 100;
                expectedWei -= discountWei;
            }
        }
        if (msg.value != expectedWei) revert E();

        uint8 state = gameState;
        if (state == 3 || state == 1) {
            unchecked {
                nextPrizePool += msg.value;
            }
        } else {
            unchecked {
                prizePool += msg.value;
            }
        }

        uint256 affiliateAmount = (scaledQty * priceCoin) / 1000;
        uint8 reached = earlyPurgeJackpotPaidMask & 0x3F;
        unchecked {
            reached -= (reached >> 1) & 0x55;
            reached = (reached & 0x33) + ((reached >> 2) & 0x33);
            reached = (reached + (reached >> 4)) & 0x0F;
        }
        uint256 steps = reached > 5 ? 5 : reached;
        uint256 pct = 25 - (steps * 5);
        unchecked {
            affiliateAmount += (affiliateAmount * pct) / 100;
        }
        unchecked {
            coin.payAffiliate(affiliateAmount, affiliateCode, payer, level);
        }

        (uint256 streakBonus, uint256 streakLuckbox) = nft.recordEthMint(payer, lvl);

        bonusMint = (bonusUnits * priceCoin * pct) / 100;
        if (streakBonus != 0) {
            unchecked {
                bonusMint += streakBonus;
            }
        }
        luckboxBonus = streakLuckbox;
    }

    /// @notice Handle Purgecoin coin payments for purchases;
    /// @dev 1.5x cost on steps where `level % 20 == 13`. 10% discount on 18. Applies post-adjustment discount.
    function _coinReceive(uint256 amount, uint24 lvl, uint256 discount) private {
        if (lvl % 20 == 13) amount = (amount * 3) / 2;
        else if (lvl % 20 == 18) amount = (amount * 9) / 10;
            amount -= discount;
        coin.burnCoin(msg.sender, amount);
    }

    function _enforceCenturyLuckbox(uint24 lvl, uint256 unit) private view {
        if (lvl != 0 && (lvl % 100 == 0)) {
            uint256 luck = coin.playerLuckbox(msg.sender);
            uint256 required = 20 * unit * ((lvl / 100) + 1);
            if (luck < required) revert LuckboxTooSmall();
            if (luck < required + LUCKBOX_BYPASS_THRESHOLD) {
                if (uint256(nft.ethMintLastLevel(msg.sender)) + 1 != uint256(lvl)) revert LuckboxTooSmall();
            }
        }
    }

    function _ensureEpThirtyUnlocked(uint24 lvl) private view {
        if (!_epUnlocked(lvl)) revert NotTimeYet();
    }

    // --- Map / NFT airdrop batching ------------------------------------------------------------------

    /// @notice Process a batch of map mints using a caller-provided writes budget (0 = auto).
    /// @param writesBudget Count of SSTORE writes allowed this tx; hard-clamped to ≤16M-safe.
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
            writesBudget -= writesBudget * 35 / 100; // 65% scaling
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

    /// @notice Mint a batch of NFTs owed to players, bounded by the number of players and a token cap.
    /// @dev
    /// - Processes up to `playersToProcess` players starting at `airdropIndex`.
    /// - Mints up to `NFT_AIRDROP_TOKEN_CAP` tokens in total for this transaction.
    /// @param playersToProcess If zero, defaults to `NFT_AIRDROP_PLAYER_BATCH_SIZE`.
    /// @return finished True if all pending NFT mints have been fully processed.
    function _processNftBatch(uint32 playersToProcess) private returns (bool finished) {
        uint256 totalPlayers = pendingNftMints.length;
        if (airdropIndex >= totalPlayers) return true;

        uint32 players = (playersToProcess == 0) ? NFT_AIRDROP_PLAYER_BATCH_SIZE : playersToProcess;
        uint256 endIdx = airdropIndex + players;
        if (endIdx > totalPlayers) endIdx = totalPlayers;

        // Hard cap on total NFTs minted per call to control work.
        uint32 tokenCap = NFT_AIRDROP_TOKEN_CAP;
        uint32 minted = 0;

        while (airdropIndex < endIdx) {
            address player = pendingNftMints[airdropIndex];
            uint32 owed = playerTokensOwed[player];
            if (owed == 0) {
                unchecked {
                    ++airdropIndex;
                }
                continue;
            }

            uint32 room = tokenCap - minted;
            if (room == 0) return false;

            uint32 chunk = owed > room ? room : owed;
            nft.gameMint(player, chunk);

            minted += chunk;
            owed -= chunk;
            playerTokensOwed[player] = owed;

            if (owed == 0) {
                unchecked {
                    ++airdropIndex;
                }
            }
        }
        return airdropIndex >= totalPlayers;
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
                for { let k := 0 } lt(k, occurrences) { k := add(k, 1) } {
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

    /// @notice Reset the per‑day purge counters (80 buckets).
    function _clearDailyPurgeCount() internal {
        for (uint8 i; i < 80; ) {
            dailyPurgeCount[i] = 0;
            unchecked {
                ++i;
            }
        }
    }

    // --- External jackpot coordination ---------------------------------------------------------------

    /// @notice Progress an external jackpot (BAF / Decimator) and account winners locally.
    /// @param kind            External jackpot kind (0 = BAF, 1 = Decimator).
    /// @param poolWei         Total wei allocated for this external jackpot stage.
    /// @param cap             Step cap forwarded to the external processor.
    /// @return finished True if the external stage reports completion.
    /// @return returnedWei Wei to be returned to carryover (non-zero only on completion).
    function _progressExternal(uint8 kind, uint256 poolWei, uint32 cap, uint24 lvl, uint256 rngWord)
        internal
        returns (bool finished, uint256 returnedWei)
    {

        if (kind == 0 && (rngWord & 1) == 0) return (true, 0);

        (bool isFinished, address[] memory winnersArr, uint256[] memory amountsArr, uint256 returnWei) = coin
            .runExternalJackpot(kind, poolWei, cap, lvl, rngWord);

        for (uint256 i; i < winnersArr.length; ) {
            _addClaimableEth(winnersArr[i], amountsArr[i]);
            unchecked {
                ++i;
            }
        }

        if (isFinished) {
            // Decrease carryover by the spent portion (poolWei - returnWei).
            carryoverForNextLevel -= (poolWei - returnWei);
            returnedWei = returnWei;
        }
        return (isFinished, returnedWei);
    }

    function _randTraitTicket(
        address[][256] storage traitPurgeTicket_,
        uint256 randomWord,
        uint8 trait,
        uint8 numWinners,
        uint8 salt
    ) internal view returns (address[] memory winners) {
        address[] storage holders = traitPurgeTicket_[trait];
        uint256 len = holders.length;
        if (len == 0 || numWinners == 0) return new address[](0);

        winners = new address[](numWinners);
        uint256 slice = randomWord ^ (uint256(trait) << 128) ^ (uint256(salt) << 192);
        for (uint256 i; i < numWinners; ) {
            uint256 idx = slice % len;
            winners[i] = holders[idx];
            unchecked {
                ++i;
                slice = (slice >> 16) | (slice << 240);
            }
        }
    }

    function _entropyStep(uint256 state) private pure returns (uint256) {
        unchecked {
            state ^= state << 7;
            state ^= state >> 9;
            state ^= state << 8;
        }
        return state;
    }

    function _creditJackpot(bool payInCoin, address beneficiary, uint256 amount) private returns (bool) {
        if (beneficiary == address(0) || amount == 0) return false;
        if (payInCoin) {
            coin.bonusCoinflip(beneficiary, amount, true, 0);
        } else {
            _addClaimableEth(beneficiary, amount);
        }
        return true;
    }

    function _payCategory(
        uint256 perWinner,
        address[] memory winners,
        uint8 length,
        bool payInCoin,
        uint24 lvl
    ) private returns (uint256 creditedAmount) {
        for (uint8 i; i < length; ) {
            address w = winners[i];
            if (_eligibleJackpotWinner(w, lvl) && _creditJackpot(payInCoin, w, perWinner)) {
                creditedAmount += perWinner;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _runTraitJackpot(
        bool payCoin,
        bool mapTrophy,
        uint24 lvl,
        uint8 traitId,
        uint8 traitIdx,
        uint8 band,
        uint256 traitShare,
        uint256 entropy,
        bool trophyGiven
    ) private returns (uint256 nextEntropy, bool trophyGivenOut, uint256 ethDelta, uint256 coinDelta) {
        nextEntropy = entropy;
        trophyGivenOut = trophyGiven;

        uint8 count0 = uint8(25 * band);
        uint8 count1 = uint8(15 * band);
        uint8 count2 = uint8(10 * band);
        uint16 totalCount = uint16(count0) + uint16(count1) + uint16(count2) + 1;
        if (totalCount == 0 || traitShare == 0) return (nextEntropy, trophyGivenOut, 0, 0);

        uint256 perWinner = traitShare / totalCount;
        if (perWinner == 0) return (nextEntropy, trophyGivenOut, 0, 0);

        if (count0 != 0) {
            nextEntropy = _entropyStep(nextEntropy ^ (uint256(traitIdx) + 1));
            address[] memory winners0 = _randTraitTicket(
                traitPurgeTicket[lvl],
                nextEntropy,
                traitId,
                count0,
                uint8(200 + traitIdx * 4)
            );
            uint256 credited0 = _payCategory(perWinner, winners0, count0, payCoin, lvl);
            if (payCoin) coinDelta += credited0; else ethDelta += credited0;
        }

        if (count1 != 0) {
            nextEntropy = _entropyStep(nextEntropy ^ (uint256(traitIdx) + 2));
            address[] memory winners1 = _randTraitTicket(
                traitPurgeTicket[lvl],
                nextEntropy,
                traitId,
                count1,
                uint8(200 + traitIdx * 4 + 1)
            );
            uint256 credited1 = _payCategory(perWinner, winners1, count1, payCoin, lvl);
            if (payCoin) coinDelta += credited1; else ethDelta += credited1;
        }

        if (count2 != 0) {
            nextEntropy = _entropyStep(nextEntropy ^ (uint256(traitIdx) + 3));
            address[] memory winners2 = _randTraitTicket(
                traitPurgeTicket[lvl],
                nextEntropy,
                traitId,
                count2,
                uint8(200 + traitIdx * 4 + 2)
            );
            uint256 credited2 = _payCategory(perWinner, winners2, count2, payCoin, lvl);
            if (payCoin) coinDelta += credited2; else ethDelta += credited2;
        }

        nextEntropy = _entropyStep(nextEntropy ^ (uint256(traitIdx) + 4));
        address[] memory finalWinnerArr = _randTraitTicket(
            traitPurgeTicket[lvl],
            nextEntropy,
            traitId,
            1,
            uint8(200 + traitIdx * 4 + 3)
        );
        address finalWinner = finalWinnerArr.length == 0 ? address(0) : finalWinnerArr[0];
        if (mapTrophy && !trophyGivenOut && traitIdx == 0 && _eligibleJackpotWinner(finalWinner, lvl)) {
            trophyGivenOut = true;
            uint256 half = perWinner / 2;
            uint256 deferred = perWinner - half;
            if (half != 0) { _addClaimableEth(finalWinner, half); ethDelta += half; }
            if (deferred != 0) {
                uint256 trophyData = (uint256(traitId) << 152) | (uint256(lvl) << 128) | TROPHY_FLAG_MAP;
                nft.awardTrophy{value: deferred}(finalWinner, lvl, IPurgeGameNFT.TrophyKind.Map, trophyData, deferred);
                ethDelta += deferred;
            }
        } else if (_eligibleJackpotWinner(finalWinner, lvl) && _creditJackpot(payCoin, finalWinner, perWinner)) {
            if (payCoin) coinDelta += perWinner; else ethDelta += perWinner;
        }
    }

    function _runJackpot(
        JackpotSpec memory spec,
        uint24 lvl,
        uint256 poolAmount,
        uint256 entropy,
        uint8[4] memory winningTraits
    ) private returns (uint256 totalPaidEth, uint256 remainingCoin) {
        uint256 ethPaid;
        uint256 coinPaid;
        uint8 band = uint8((lvl % 100) / 20) + 1; // 1..5
        uint256 traitShare = (poolAmount * 20) / 100;
        bool trophyGiven;

        uint256 ethDelta;
        uint256 coinDelta;
        for (uint8 traitIdx; traitIdx < 4; ) {
            (entropy, trophyGiven, ethDelta, coinDelta) = _runTraitJackpot(
                spec.payInCoin,
                spec.mapTrophy,
                lvl,
                winningTraits[traitIdx],
                traitIdx,
                band,
                traitShare,
                entropy,
                trophyGiven
            );
            ethPaid += ethDelta;
            coinPaid += coinDelta;
            unchecked { ++traitIdx; }
        }

        totalPaidEth = ethPaid;
        remainingCoin = spec.payInCoin ? (poolAmount > coinPaid ? poolAmount - coinPaid : 0) : 0;
        return (totalPaidEth, remainingCoin);
    }

    function _epUnlocked(uint24 lvl) private view returns (bool) {
        return lvl < 10 || (earlyPurgeJackpotPaidMask & EP_THIRTY_MASK) != 0;
    }

    function _eligibleJackpotWinner(address player, uint24 lvl) private view returns (bool) {
        if (player == address(0)) return false;
        if (!_epUnlocked(lvl)) return true;
        return nft.ethMintLastLevel(player) == lvl;
    }

    function _executeCoinJackpot(uint24 lvl, uint256 randWord) internal returns (uint8[4] memory winningTraits) {
        winningTraits = _getRandomTraits(randWord);

        (uint256 pool, ) = coin.prepareCoinJackpot();
        if (pool == 0) return winningTraits;

        JackpotSpec memory spec = JackpotSpec({payInCoin: true, mapTrophy: false});

        (, uint256 remaining) = _runJackpot(spec, lvl, pool, randWord ^ (uint256(lvl) << 192), winningTraits);
        if (remaining != 0) {
            coin.addToBounty(remaining);
        }
    }

    function _getRandomTraits(uint256 rw) internal pure returns (uint8[4] memory w) {
        w[0] = uint8(rw & 0x3F);
        w[1] = 64 + uint8((rw >> 6) & 0x3F);
        w[2] = 128 + uint8((rw >> 12) & 0x3F);
        w[3] = 192 + uint8((rw >> 18) & 0x3F);
    }

    function _getWinningTraits(
        uint256 randomWord,
        uint32[80] storage counters
    ) internal view returns (uint8[4] memory w) {
        uint8 sym = _maxIdxInRange(counters, 0, 8);

        uint8 col0 = uint8(randomWord & 7);
        w[0] = (col0 << 3) | sym;

        uint8 maxColor = _maxIdxInRange(counters, 8, 8);
        uint8 randSym = uint8((randomWord >> 3) & 7);
        w[1] = 64 + ((maxColor << 3) | randSym);

        uint8 maxTrait = _maxIdxInRange(counters, 16, 64);
        w[2] = 128 + maxTrait;

        w[3] = 192 + uint8((randomWord >> 6) & 63);
    }

    function _maxIdxInRange(uint32[80] storage counters, uint8 base, uint8 len) private view returns (uint8) {
        if (len == 0 || base >= 80) return 0;

        uint256 end = uint256(base) + uint256(len);
        if (end > 80) end = 80;

        uint8 maxRel = 0;
        uint32 maxVal = counters[base];

        for (uint256 i = uint256(base) + 1; i < end; ) {
            uint32 v = counters[i];
            if (v > maxVal) {
                maxVal = v;
                maxRel = uint8(i) - base;
            }
            unchecked {
                ++i;
            }
        }
        return maxRel;
    }

    // --- Views / metadata ---------------------------------------------------------------------------
    function describeBaseToken(uint256 tokenId)
        external
        view
        returns (uint256 metaPacked, uint32[4] memory remaining)
    {
        uint32 traitsPacked = tokenTraits[tokenId];

        uint8 t0 = uint8(traitsPacked);
        uint8 t1 = uint8(traitsPacked >> 8);
        uint8 t2 = uint8(traitsPacked >> 16);
        uint8 t3 = uint8(traitsPacked >> 24);

        uint256 lastExterminated = lastExterminatedTrait;
        metaPacked = (uint256(lastExterminated) << 56) | (uint256(level) << 32) | uint256(traitsPacked);

        remaining[0] = traitRemaining[t0];
        remaining[1] = traitRemaining[t1];
        remaining[2] = traitRemaining[t2];
        remaining[3] = traitRemaining[t3];
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
        mints = playerTokensOwed[player];
        maps = playerMapMintsOwed[player];
    }
    receive() external payable {}
}
