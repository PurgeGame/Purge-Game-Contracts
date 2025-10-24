// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Purge Game — Core NFT game contract
 * @notice This file defines the on-chain game logic surface (interfaces + core state).
 * @dev The full audit will annotate each function as it is reviewed. This section covers
 *      declarations, configuration, and constructor. No state-variable renames are applied here
 *      to avoid breaking linkages in later functions; comments call out semantics and risks.
 */

// ===========================================================================
// External Interfaces
// ===========================================================================

/**
 * @dev Interface to the PURGE ERC20 + game-side coordinator.
 *      All calls are trusted (set via constructor in the ERC20 contract).
 */
interface IPurgeCoinInterface {
    function mintInGame(address recipient, uint256 amount) external;
    function burnInGame(address target, uint256 amount) external;
    function payAffiliate(
        uint256 amount,
        bytes32 code,
        address sender,
        uint24 lvl
    ) external;
    function requestRngPurgeGame(bool pauseBetting) external;
    function pullRng() external view returns (uint256 word);
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip
    ) external returns (bool);
    function triggerCoinJackpot() external;
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl
    )
        external
        returns (
            bool finished,
            address[] memory winners,
            uint256[] memory amounts,
            uint256 returnAmountWei
        );
    function resetAffiliateLeaderboard() external;
    function getLeaderboardAddresses(
        uint8 which
    ) external view returns (address[] memory);
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
    function gameMint(
        address to,
        uint256 quantity
    ) external returns (uint256 startTokenId);

    function gameBurn(uint256 tokenId) external;

    function ownerOf(uint256 tokenId) external view returns (address);

    function exists(uint256 tokenId) external view returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external payable;
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

    // -----------------------
    // Events
    // -----------------------
    event PlayerCredited(address indexed player, uint256 amount);
    event Jackpot(uint256 traits); // Encodes jackpot metadata
    event Purge(address indexed player, uint256[] tokenIds);
    event TokenCreated(uint256 tokenId, uint32 tokenTraits);

    // -----------------------
    // Immutable Addresses
    // -----------------------
    address private immutable _renderer; // Trusted renderer; used for tokenURI composition
    address private immutable _coin; // Trusted coin/game-side coordinator (PURGE ERC20)
    address private immutable _nft; // ERC721 contract handling mint/burn/metadata surface
    address private immutable creator; // Receives protocol PURGE (end-game drains, etc.)
    // -----------------------
    // Game Constants
    // -----------------------
    uint48 private constant JACKPOT_RESET_TIME = 82620; // Offset anchor for "daily" windows
    uint256 private constant MILLION = 1_000_000; // 6-decimal unit helper
    uint32 private constant NFT_AIRDROP_PLAYER_BATCH_SIZE = 210; // Mint batch cap (# players)
    uint32 private constant NFT_AIRDROP_TOKEN_CAP = 3_000; // Mint batch cap (# tokens)
    uint32 private constant DEFAULT_PAYOUTS_PER_TX = 500; // ≤16M worst-case
    uint32 private constant WRITES_BUDGET_SAFE = 800; // <16M gas  budget
    uint72 private constant MAP_PERMILLE = 0x0A0A07060304050564; // Payout permilles packed (9 bytes)

    // -----------------------
    // Price
    // -----------------------
    uint256 private price = 0.025 ether; // Base mint price
    uint256 private priceCoin = 1000 * MILLION; // 1,000 Purgecoin (6d) base unit

    // -----------------------
    // Prize Pools and RNG
    // -----------------------
    uint256 private lastPrizePool = 125 ether; // Snapshot from previous epoch (non-zero post L1)
    uint256 private levelPrizePool; // Snapshot for endgame distribution of current level
    uint256 private prizePool; // Live ETH pool for current level
    uint256 private carryoverForNextLevel; // Saved carryover % for next level
    uint256 private rngWord; // Cached fulfilled RNG word (game-level scope)

    // -----------------------
    // Time / Session Tracking
    // -----------------------
    uint48 private levelStartTime = type(uint48).max; // Wall-clock start of current level
    uint48 private dailyIdx; // Daily session index (derived from JACKPOT_RESET_TIME)
    uint48 private rngTs; // Timestamp of last RNG request/fulfillment

    // -----------------------
    // Game Progress
    // -----------------------
    uint24 public level = 1; // 1-based level counter
    uint8 public gameState = 1; // Phase FSM (audited in advanceGame() review)
    uint8 private jackpotCounter; // # of daily jackpots paid in current level
    uint8 private earlyPurgeJackpotPaidMask; // Bitmask for early purge jackpots paid (progressive)
    uint8 private phase; // Airdrop sub-phase (0..7)
    uint16 private lastExterminatedTrait = 420; // The winning trait from the previous season (420 sentinel)

    // -----------------------
    // RNG Liveness Flags
    // -----------------------
    bool private rngFulfilled; // Last RNG request has been fulfilled
    bool private rngConsumed; // Current RNG has been consumed by game logic

    // -----------------------
    // Minting / Airdrops
    // -----------------------
    uint32 private purchaseCount; // Total purchased NFTs this level
    uint64 private _baseTokenId = 0; // Rolling base for token IDs across levels
    uint32 private airdropMapsProcessedCount; // Progress inside current map-mint player's queue
    uint32 private airdropIndex; // Progress across players in pending arrays

    address[] private pendingNftMints; // Queue of players with owed NFTs
    address[] private pendingMapMints; // Queue of players with owed "map" mints

    mapping(address => uint32) private playerTokensOwed; // Player => NFTs owed
    mapping(address => uint32) private playerMapMintsOwed; // Player => Maps owed

    // -----------------------
    // Token / Trait State
    // -----------------------
    mapping(uint256 => uint32) private tokenTraits; // Packed 4×8-bit traits (low to high)
    mapping(address => uint256) private claimableWinnings; // ETH claims accumulated on-chain
    mapping(uint256 => uint256) private trophyData; // Trophy metadata by tokenId
    uint256[] private trophyTokenIds; // Historical trophies
    mapping(uint24 => address[][256]) private traitPurgeTicket; // level => trait => tickets

    // -----------------------
    // Daily / Trait Counters
    // -----------------------
    uint32[80] internal dailyPurgeCount; // 8 + 8 + 64
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
    constructor(
        address purgeCoinContract,
        address renderer_,
        address nftContract
    ) {
        creator = msg.sender;
        _coin = purgeCoinContract;
        _renderer = renderer_;
        _nft = nftContract;
    }

    // --- View: lightweight game status -------------------------------------------------

    /// @notice Public snapshot of selected game state for UI/indexers.
    /// @return phase_                   Current airdrop sub-phase (0..7)
    /// @return jackpotCounter_          Number of daily jackpots processed this level
    /// @return price_                   Current mint price (wei)
    /// @return carry_                   Carryover for next level (wei)
    /// @return prizePoolTarget          Prize pool minimum to end mint for current level (wei)
    /// @return prizePoolCurrent         Current level’s live prize pool (wei)
    /// @return enoughPurchases          True if purchaseCount >= 1500
    /// @return rngFulfilled_            Last VRF request fulfilled
    /// @return rngConsumed_             Last VRF word consumed by game logic
    function gameInfo()
        external
        view
        returns (
            uint8 phase_,
            uint8 jackpotCounter_,
            uint256 price_,
            uint256 carry_,
            uint256 prizePoolTarget,
            uint256 prizePoolCurrent,
            bool enoughPurchases,
            bool rngFulfilled_,
            bool rngConsumed_
        )
    {
        phase_ = phase;
        jackpotCounter_ = jackpotCounter;
        price_ = price;
        carry_ = carryoverForNextLevel;
        prizePoolTarget = lastPrizePool;
        prizePoolCurrent = (gameState == 4) ? levelPrizePool : (prizePool);
        enoughPurchases = (purchaseCount >= 1500);
        rngFulfilled_ = rngFulfilled;
        rngConsumed_ = rngConsumed;
    }

    // --- State machine: advance one tick ------------------------------------------------

    /// @notice Advances the game state machine. Anyone can call, but certain steps
    ///         require the caller to meet a luckbox threshold (payment for work/luckbox bonus).
    /// @param cap Emergency unstuck function, in case a necessary transaction is too large for a block.
    ///            Using cap removes Purgecoin payment.
    function advanceGame(uint32 cap) external {
        uint48 ts = uint48(block.timestamp);

        // Liveness drain
        if (ts - 365 days > levelStartTime) {
            gameState = 0;
            uint256 bal = address(this).balance;
            if (bal > 0) {
                address dst = creator;
                assembly {
                    pop(call(gas(), dst, bal, 0, 0, 0, 0))
                }
            }
        }

        uint24 lvl = level;
        uint8 s = gameState;
        uint8 ph = phase;
        bool pauseBetting = !((s == 2) && (ph < 3) && (lvl % 20 == 0));

        IPurgeCoinInterface coin = IPurgeCoinInterface(_coin);
        uint48 day = uint48((ts - JACKPOT_RESET_TIME) / 1 days);
        uint48 dayIdx = dailyIdx;

        do {
            // RNG pull / SLA
            if (rngTs != 0 && !rngFulfilled) {
                uint256 w = coin.pullRng();
                if (w != 0) {
                    rngFulfilled = true;
                    rngWord = w;
                    rngTs = ts;
                } else if (ts - rngTs > 6 hours) {
                    _requestVrf(ts, pauseBetting);
                    break;
                } else revert NotTimeYet();
            }

            // luckbox rewards
            if (
                cap == 0 &&
                coin.playerLuckbox(msg.sender) <
                priceCoin * lvl * (lvl / 100 + 1)
            ) revert LuckboxTooSmall();

            // Arm VRF when due/new (reward allowed)
            if ((rngConsumed && day != dayIdx) || rngTs == 0) {
                _requestVrf(ts, pauseBetting);
                break;
            }
            if (day == dayIdx && s != 1) revert NotTimeYet();
            // --- State 1 - Pregame ---
            if (s == 1) {
                _finalizeEndgame(lvl, cap, day); // handles payouts, wipes, endgame dist, and jackpots
                break;
            }

            // --- State 2 - Purchase ---
            if (s == 2) {
                _updateEarlyPurgeJackpots(lvl);
                if (
                    ph == 2 &&
                    purchaseCount >= 1500 &&
                    prizePool >= lastPrizePool
                ) {
                    if (_endJackpot(lvl, cap, day, true, pauseBetting)) {
                        phase = 3;
                    }
                    break;
                } else if (ph == 3 && jackpotCounter == 0) {
                    gameState = 3;
                    IPurgeRenderer(_renderer).setStartingTraitRemaining(
                        traitRemaining
                    );
                    if (_processMapBatch(cap)) {
                        phase = 4;
                        airdropIndex = 0;
                        airdropMapsProcessedCount = 0;
                    }
                    break;
                }
                if (airdropIndex < pendingMapMints.length) {
                    _processMapBatch(cap);
                    break;
                }
                if (jackpotCounter > 0) {
                    payDailyJackpot(false, lvl);
                    break;
                }
                _endJackpot(lvl, cap, day, false, pauseBetting);
                break;
            }

            // --- State 3 - Airdrop ---
            if (s == 3) {
                if (ph == 3) {
                    if (_processMapBatch(cap)) {
                        phase = 4;
                        airdropIndex = 0;
                        airdropMapsProcessedCount = 0;
                    }
                    break;
                }
                if (ph == 4) {
                    if (payMapJackpot(cap, lvl)) {
                        phase = 5;
                    }
                    break;
                }
                if (ph == 5) {
                    if (_processNftBatch(cap)) {
                        phase = 6;
                    }
                    break;
                }
                if (_endJackpot(lvl, cap, day, false, pauseBetting)) {
                    levelStartTime = ts;
                    gameState = 4;
                }
                break;
            }

            // --- State 4 - Purge ---
            if (s == 4) {
                if (ph == 6) {
                    payDailyJackpot(true, lvl);
                    coin.triggerCoinJackpot();
                    phase = 7;
                    break;
                }
                if (_endJackpot(lvl, cap, day, false, pauseBetting)) phase = 6;
                break;
            }

            // --- State 0 ---
            if (s == 0) {
                _endJackpot(lvl, cap, day, false, pauseBetting);
            }
        } while (false);

        if (s != 0 && cap == 0) coin.mintInGame(msg.sender, priceCoin);
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
    function purchase(
        uint256 quantity,
        bool payInCoin,
        bytes32 affiliateCode
    ) external payable {
        uint8 ph = phase;
        if (
            quantity == 0 ||
            quantity > 100 ||
            gameState != 2 ||
            (!rngConsumed && ph == 3)
        ) revert NotTimeYet();
        uint24 lvl = level;
        uint256 _priceCoin = priceCoin;
        _enforceCenturyLuckbox(lvl, _priceCoin);
        // Payment handling (ETH vs coin)
        uint256 bonusCoinReward = (quantity / 10) * _priceCoin;
        if (payInCoin) {
            if (msg.value != 0) revert E();
            _coinReceive(quantity * _priceCoin, lvl, bonusCoinReward);
        } else {
            uint256 bonus = _ethReceive(
                quantity * 100,
                affiliateCode,
                quantity
            ); // price × (quantity * 100) / 100
            if (ph == 3 && (lvl % 100) > 90) {
                bonus += (quantity * _priceCoin) / 5;
            }
            bonus += bonusCoinReward;
            if (bonus != 0)
                IPurgeCoinInterface(_coin).mintInGame(msg.sender, bonus);
        }

        // Push buyer to the pending list once (de-dup)
        if (playerTokensOwed[msg.sender] == 0) {
            pendingNftMints.push(msg.sender);
        }

        // Precompute traits for future mints using the current RNG snapshot.
        // NOTE: tokenIds are not minted yet; only trait counters are updated.
        uint256 randomWord = rngWord; // 0 is allowed by design here
        uint256 tokenIdStart = uint256(_baseTokenId) + uint256(purchaseCount);
        for (uint32 i; i < quantity; ) {
            uint256 _tokenId = tokenIdStart + i;
            uint256 rand = uint256(
                keccak256(abi.encodePacked(_tokenId, randomWord))
            );
            uint8 tA = _getTrait(uint64(rand));
            uint8 tB = _getTrait(uint64(rand >> 64)) | 64;
            uint8 tC = _getTrait(uint64(rand >> 128)) | 128;
            uint8 tD = _getTrait(uint64(rand >> 192)) | 192;

            // Pack 4x8-bit traits (A,B,C,D) into 32 bits.
            uint32 _tokenTraits = uint32(tA) |
                (uint32(tB) << 8) |
                (uint32(tC) << 16) |
                (uint32(tD) << 24);
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
    /// - ETH path: mints a coin rebate if quantity > 3.
    /// - No on-chain burning/minting of NFTs here; symbols are scheduled and later batched.
    /// @param quantity Number of map entries requested (≥1).
    /// @param payInCoin If true, pay with Purgecoin (with level-conditional multiplier).
    /// @param affiliateCode Optional affiliate code for ETH payments.
    function mintAndPurge(
        uint256 quantity,
        bool payInCoin,
        bytes32 affiliateCode
    ) external payable {
        uint256 priceUnit = priceCoin;
        uint8 ph = phase;
        if (gameState != 2 || quantity == 0 || !rngConsumed)
            revert NotTimeYet();
        uint24 lvl = level;
        _enforceCenturyLuckbox(lvl, priceUnit);
        // Pricing / rebates
        uint256 coinCost = quantity * (priceUnit / 4);
        uint256 scaledQty = quantity * 25; // ETH path scale factor (÷100 later)
        uint256 mapRebate = (quantity / 4) * (priceUnit / 10);
        uint256 mapBonus = (quantity / 40) * priceUnit;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            _coinReceive(coinCost - mapRebate, lvl, mapBonus);
        } else {
            uint256 bonus = _ethReceive(
                scaledQty,
                affiliateCode,
                (lvl < 10) ? quantity : 0
            );
            if (ph == 3 && (lvl % 100) > 90) {
                bonus += coinCost / 5;
            }
            uint256 rebateMint = bonus + mapRebate + mapBonus;
            if (rebateMint != 0)
                IPurgeCoinInterface(_coin).mintInGame(msg.sender, rebateMint);
        }

        if (playerMapMintsOwed[msg.sender] == 0)
            pendingMapMints.push(msg.sender);
        unchecked {
            playerMapMintsOwed[msg.sender] += uint32(quantity);
        }
    }
    // --- Purging NFTs into tickets & potentially ending the level -----------------------------------

    /// @notice Burn up to 75 owned NFTs to contribute purge tickets; may end the level if a trait hits zero.
    /// @dev
    /// Security:
    /// - Blocks contract calls (`extcodesize(caller()) != 0`) and `tx.origin` relays.
    /// - Requires `gameState == 4` and a consumed RNG session.
    /// Accounting:
    /// - For each token, burns it, updates daily counters and remaining-per-trait,
    ///   and appends four tickets (one per trait) to the current level’s buckets.
    /// - If any trait’s remaining count reaches 0 during the loop, `_endLevel(trait)` is invoked
    ///   and the function returns immediately (tickets for that *last* NFT are not recorded).
    /// Rewards:
    /// - Mints Purgecoin to the caller: base `n` plus up to +0.9×n (in tenths) if the NFT
    ///   included last level’s exterminated trait.
    function purge(uint256[] calldata tokenIds) external {
        uint256 extSize;
        assembly {
            extSize := extcodesize(caller())
        }
        if (extSize != 0 || tx.origin != msg.sender) revert E();
        if (gameState != 4 || !rngConsumed) revert NotTimeYet();

        uint256 count = tokenIds.length;
        if (count == 0 || count > 75) revert E();
        uint24 lvl = level;

        uint16 prevExterminated = lastExterminatedTrait;
        address caller = msg.sender;
        uint256 bonusTenths;

        for (uint256 i; i < count; ) {
            uint256 tokenId = tokenIds[i];
            if (
                IPurgeGameNFT(_nft).ownerOf(tokenId) != caller ||
                trophyData[tokenId] != 0
            ) revert E();

            uint32 traits = tokenTraits[tokenId];
            uint8 trait0 = uint8(traits & 0xFF);
            uint8 trait1 = (uint8(traits >> 8) & 0xFF);
            uint8 trait2 = (uint8(traits >> 16) & 0xFF);
            uint8 trait3 = (uint8(traits >> 24) & 0xFF);

            if (
                uint16(trait0) == prevExterminated ||
                uint16(trait1) == prevExterminated ||
                uint16(trait2) == prevExterminated ||
                uint16(trait3) == prevExterminated
            ) {
                unchecked {
                    bonusTenths += 9;
                }
            }

            IPurgeGameNFT(_nft).gameBurn(tokenId);

            unchecked {
                dailyPurgeCount[trait0 & 0x07] += 1;
                dailyPurgeCount[((trait1 - 64) >> 3) + 8] += 1;
                dailyPurgeCount[trait2 - 128 + 16] += 1;

                if (--traitRemaining[trait0] == 0) {
                    _endLevel(trait0);
                    return;
                }
                if (--traitRemaining[trait1] == 0) {
                    _endLevel(trait1);
                    return;
                }
                if (--traitRemaining[trait2] == 0) {
                    _endLevel(trait2);
                    return;
                }
                if (--traitRemaining[trait3] == 0) {
                    _endLevel(trait3);
                    return;
                }

                ++i;
            }

            traitPurgeTicket[lvl][trait0].push(caller);
            traitPurgeTicket[lvl][trait1].push(caller);
            traitPurgeTicket[lvl][trait2].push(caller);
            traitPurgeTicket[lvl][trait3].push(caller);
        }

        if (lvl % 10 == 2) count <<= 1;
        IPurgeCoinInterface(_coin).mintInGame(
            caller,
            (count + bonusTenths) * (priceCoin / 10)
        );
        emit Purge(msg.sender, tokenIds);
    }

    // --- Level finalization -------------------------------------------------------------------------

    /// @notice Finalize the current level either due to a trait being exterminated (<256) or a timed-out “420” end.
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
    /// - Carry the entire `prizePool` forward and reset leaderboards.
    /// - On L%100==0: adjust price and `lastPrizePool`.
    ///
    /// After either path:
    /// - Reset per-level state, mint the next level’s trophy placeholder,
    ///   set default exterminated sentinel to 420, and request fresh VRF.
    function _endLevel(uint16 exterminated) private {
        address exterminator = msg.sender;
        uint256 trophyId = _baseTokenId - 1;

        uint24 levelSnapshot = level;

        if (exterminated < 256) {
            uint8 exTrait = uint8(exterminated);

            uint256 pool = prizePool;

            // Halving if same trait as prior level
            uint16 prev = lastExterminatedTrait;
            if (exterminated == prev) {
                uint256 keep = pool >> 1;
                carryoverForNextLevel += keep;
                pool -= keep;
            }

            // Participant vs exterminator split
            uint256 ninetyPercent = (pool * 90) / 100;
            uint256 exterminatorShare = (levelSnapshot % 10 == 7 &&
                levelSnapshot >= 25)
                ? (pool * 40) / 100
                : (pool * 20) / 100;
            uint256 participantShare = ninetyPercent - exterminatorShare;

            // Cache per-ticket payout into prizePool (payEach). Payout happens in state 1.
            uint256 ticketsLen = traitPurgeTicket[levelSnapshot][exTrait]
                .length;
            prizePool = (ticketsLen == 0) ? 0 : (participantShare / ticketsLen);

            // Award trophy (transfer placeholder owned by contract)
            IPurgeGameNFT(_nft).transferFrom(
                address(this),
                exterminator,
                trophyId
            );
            trophyTokenIds.push(trophyId);
            trophyData[trophyId] =
                (uint256(exTrait) << 152) |
                (uint256(levelSnapshot) << 128);

            // Seed finalize() pool snapshot and book last trait
            levelPrizePool = pool;
            lastExterminatedTrait = exTrait;
        } else {
            // Non-trait end (e.g., daily jackpot progression end)
            trophyData[trophyId] = 0;

            if (levelSnapshot % 100 == 0) {
                price = 0.05 ether;
                priceCoin >>= 1;
                lastPrizePool = prizePool >> 3;
            }

            carryoverForNextLevel += prizePool;

            lastExterminatedTrait = 420;
        }

        // Advance level
        unchecked {
            levelSnapshot++;
            level++;
        }

        // Reset level state
        for (uint16 t; t < 256; ) {
            traitRemaining[t] = 0;
            unchecked {
                ++t;
            }
        }
        delete pendingNftMints;
        delete pendingMapMints;
        airdropIndex = 0;
        airdropMapsProcessedCount = 0;
        jackpotCounter = 0;
        earlyPurgeJackpotPaidMask = 0;

        // Mint next level’s trophy placeholder to the contract
        uint256 newTrophyId = IPurgeGameNFT(_nft).gameMint(address(this), 1);
        _baseTokenId = uint64(newTrophyId + 1);
        trophyData[newTrophyId] = (0xFFFF << 152);

        // Price schedule
        uint256 mod100 = levelSnapshot % 100;
        if (mod100 == 10 || mod100 == 0) {
            price <<= 1;
        } else if (levelSnapshot % 20 == 0) {
            price += (levelSnapshot < 100) ? 0.05 ether : 0.1 ether;
        }

        purchaseCount = 0;
        gameState = 1;

        _requestVrf(uint48(block.timestamp), true);
    }

    /// @notice Resolve prior level endgame in bounded slices and advance to purchase when ready.
    /// @dev Order: (A) participant payouts → (B) ticket wipes → (C) affiliate/trophy/exterminator
    ///      → (D) finish coinflip payouts (jackpot end) and move to state 2.
    ///      Pass `cap` from advanceGame to keep tx gas ≤ target.
    function _finalizeEndgame(uint24 lvl, uint32 cap, uint48 day) internal {
        uint24 ph = phase;
        if (lvl == 1 && _baseTokenId == 0) {
            uint256 sentinelId = IPurgeGameNFT(_nft).gameMint(address(this), 1);
            trophyData[sentinelId] = (0xFFFF << 152);
            _baseTokenId = uint64(sentinelId + 1);
        }
        if (ph > 3) {
            // (C) Endgame distributions (skip this block if prior level ended non-trait, i.e. 420)
            if (lastExterminatedTrait != 420) {
                uint24 prevLevel;
                unchecked {
                    prevLevel = lvl - 1;
                }
                if (prizePool != 0) {
                    _payoutParticipants(cap, prevLevel);
                    return;
                }
                uint256 poolTotal = levelPrizePool;
                if (poolTotal != 0) {
                    // Affiliate reward (10% for L1, 5% otherwise)
                    uint256 affPool = (prevLevel == 1)
                        ? (poolTotal * 10) / 100
                        : (poolTotal * 5) / 100;
                    address[] memory affLeaders = IPurgeCoinInterface(_coin)
                        .getLeaderboardAddresses(1);
                    uint256 affLen = affLeaders.length;
                    if (affLen != 0) {
                        uint256 top = affLen < 3 ? affLen : 3;
                        for (uint256 i; i < top; ) {
                            uint256 pct = i == 0
                                ? 50
                                : i == 1
                                    ? 25
                                    : 15;
                            _addClaimableEth(
                                affLeaders[i],
                                (affPool * pct) / 100
                            );
                            unchecked {
                                ++i;
                            }
                        }
                        if (affLen > 3) {
                            address rndAddr = affLeaders[
                                3 + (rngWord % (affLen - 3))
                            ];
                            _addClaimableEth(rndAddr, (affPool * 10) / 100);
                        }
                    }

                    // Historical trophy bonus (5% across two past trophies)
                    if (prevLevel > 1) {
                        uint256 trophyPool = poolTotal / 20;
                        uint256 trophiesLen = trophyTokenIds.length;

                        if (trophiesLen > 1) {
                            uint256 idA = trophyTokenIds[
                                rngWord % (trophiesLen - 1)
                            ];
                            uint256 idB = trophyTokenIds[
                                (rngWord >> 128) % (trophiesLen - 1)
                            ];
                            uint256 halfA = trophyPool >> 1;
                            uint256 halfB = trophyPool - halfA;
                            if (IPurgeGameNFT(_nft).exists(idA)) {
                                _addClaimableEth(
                                    IPurgeGameNFT(_nft).ownerOf(idA),
                                    halfA
                                );
                                trophyPool -= halfA;
                            }
                            if (IPurgeGameNFT(_nft).exists(idB)) {
                                _addClaimableEth(
                                    IPurgeGameNFT(_nft).ownerOf(idB),
                                    halfB
                                );
                                trophyPool -= halfB;
                            }
                        }
                        if (trophyPool != 0)
                            carryoverForNextLevel += trophyPool;
                    }

                    // Exterminator’s share (20% or 40%), plus epoch carry if prevLevel%100==0
                    uint256 exterminatorShare = (prevLevel % 10 == 7 &&
                        prevLevel >= 25)
                        ? (poolTotal * 40) / 100
                        : (poolTotal * 20) / 100;
                    if ((prevLevel % 100) == 0) {
                        exterminatorShare += carryoverForNextLevel;
                    }
                    address exterminatorOwner = IPurgeGameNFT(_nft).ownerOf(
                        trophyTokenIds[trophyTokenIds.length - 1]
                    );
                    _addClaimableEth(exterminatorOwner, exterminatorShare);

                    levelPrizePool = 0;

                    // Century boundary ends the epoch here
                    if ((prevLevel % 100) == 0) {
                        gameState = 0;
                        return;
                    }
                }
            }
            // (D) Finish coinflip / stake payouts for the day;
            if (_endJackpot(lvl, cap, day, false, true)) {
                phase = 0;
                return;
            }
        } else {
            // on completion move to purchase state
            if (lvl > 1) {
                _clearDailyPurgeCount();
                IPurgeCoinInterface(_coin).resetAffiliateLeaderboard();

                prizePool = 0;
                phase = 0;
            }
            gameState = 2;
        }
    }

    function _payoutParticipants(uint32 capHint, uint24 prevLevel) internal {
        address[] storage arr = traitPurgeTicket[prevLevel][
            uint8(lastExterminatedTrait)
        ];
        uint32 len = uint32(arr.length);
        if (len == 0) {
            prizePool = 0;
            return;
        }

        uint32 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint32 i = airdropIndex;
        uint32 end = i + cap;
        if (end > len) end = len;

        uint256 payEach = prizePool; // cached unit payout

        while (i < end) {
            address w = arr[i];
            uint32 run = 1;
            unchecked {
                while (i + run < end && arr[i + run] == w) ++run; // coalesce contiguous
            }
            _addClaimableEth(w, payEach * run);
            unchecked {
                i += run;
            }
        }

        airdropIndex = i;
        if (i == len) {
            prizePool = 0;
            airdropIndex = 0;
        } // finished (tickets can be wiped)
    }

    // --- Claiming winnings (ETH) --------------------------------------------------------------------

    /// @notice Claim the caller’s accrued ETH winnings (affiliates, jackpots, endgame payouts).
    /// @dev Leaves a 1 wei sentinel so subsequent credits remain non-zero → cheaper SSTORE.

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
    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
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
    function _mapSpec(
        uint8 index
    ) internal pure returns (uint8 winnersN, uint8 permille) {
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
        return
            _randTraitTicket(
                traitPurgeTicket[level],
                randomWord,
                trait,
                numWinners,
                salt
            );
    }

    // --- Map jackpot payout (end of purchase phase) -------------------------------------------------

    /// @notice Compute carry split, set the new prize pool, and pay the 9 map buckets.
    /// @dev
    /// - External jackpots (BAF/Decimator) may short‑circuit for continuation.
    /// - Trait selection:
    ///     * idx 0: one random full‑range trait (0..255)
    ///     * idx 1–2: same random Q0 trait (big payout, then many small)
    ///     * idx 3–4: same random Q1 trait
    ///     * idx 5–6: same random Q2 trait
    ///     * idx 7–8: same random Q3 trait
    /// - `_mapSpec(idx)` drives winners count & permille for each bucket.
    function payMapJackpot(
        uint32 cap,
        uint24 lvl
    ) internal returns (bool finished) {
        uint256 carryWei = carryoverForNextLevel;

        // External jackpots first (may need multiple calls)
        if (lvl % 20 == 0) {
            uint256 bafPoolWei = (carryWei * 24) / 100;
            if (!_progressExternal(0, bafPoolWei, cap, lvl)) return false;
        } else if (lvl >= 25 && (lvl % 10) == 5 && lvl % 100 != 95) {
            uint256 decPoolWei = (carryWei * 15) / 100;
            if (!_progressExternal(1, decPoolWei, cap, lvl)) return false;
        }

        // Recompute after any external stage updated carryover
        carryWei = carryoverForNextLevel;
        uint256 totalWei = carryWei + prizePool;
        uint256 lvlMod100 = lvl % 100;

        // Small creator payout in PURGE (proportional to total ETH processed)
        IPurgeCoinInterface(_coin).mintInGame(
            creator,
            (totalWei * 5 * priceCoin) / 1 ether
        );

        // Save % for next level (randomized bands per range)
        uint256 rndWord = uint256(keccak256(abi.encode(rngWord, uint8(3))));
        uint256 savePct;
        if ((rndWord % 1_000_000_000) == MILLION) {
            savePct = 10;
        } else if (lvl < 10) savePct = uint256(lvl) * 5;
        else if (lvl < 20) savePct = 55 + (rndWord % 16);
        else if (lvl < 40) savePct = 55 + (rndWord % 21);
        else if (lvl < 60) savePct = 60 + (rndWord % 21);
        else if (lvl < 80) savePct = 60 + (rndWord % 26);
        else if (lvl == 99) savePct = 93;
        else savePct = 65 + (rndWord % 26);
        if (lvl % 10 == 9) savePct += 5;

        uint256 effectiveWei;
        if (lvlMod100 == 0) {
            effectiveWei = totalWei;
            carryoverForNextLevel = 0;
        } else {
            uint256 saveNextWei = (totalWei * savePct) / 100;
            carryoverForNextLevel = saveNextWei;
            effectiveWei = totalWei - saveNextWei;
        }

        lastPrizePool = prizePool;
        prizePool = effectiveWei;

        // --- Trait plan: 1 full‑range + 2×(Q0,Q1,Q2,Q3), paired per quadrant ---
        uint8 fullTrait = uint8(rndWord & 0xFF);
        uint8[4] memory quadTrait;
        {
            uint256 r = rndWord >> 8;
            quadTrait[0] = uint8((r & 0x3F) + 0);
            r >>= 6; // Q0: 0..63
            quadTrait[1] = uint8((r & 0x3F) + 64);
            r >>= 6; // Q1: 64..127
            quadTrait[2] = uint8((r & 0x3F) + 128);
            r >>= 6; // Q2: 128..191
            quadTrait[3] = uint8((r & 0x3F) + 192); // Q3: 192..255
        }

        uint256 packedTraits;
        uint256 totalPaidWei;
        bool doubleMap = (lvlMod100 == 30) ||
            (lvlMod100 == 50) ||
            (lvlMod100 == 70) ||
            (lvlMod100 == 0);

        for (uint8 idx; idx < 9; ) {
            (uint8 winnersN, uint8 permille) = _mapSpec(idx);

            // idx 0 = full range; then pairs per quadrant: (1,2)=Q0, (3,4)=Q1, (5,6)=Q2, (7,8)=Q3
            uint8 traitId = (idx == 0) ? fullTrait : quadTrait[(idx - 1) >> 1];

            packedTraits |= uint256(traitId) << (idx * 8);

            address[] memory winners = _randTraitTicket(
                traitPurgeTicket[lvl],
                rndWord,
                traitId,
                winnersN, // odd idx → 1 big payout; even idx → 20 small payouts
                uint8(42 + idx)
            );

            uint256 bucketWei = (effectiveWei * permille) / 1000;
            if (doubleMap) bucketWei <<= 1;

            uint256 winnersLen = winners.length;
            if (winnersLen != 0) {
                uint256 prizeEachWei = bucketWei / winnersLen;

                uint256 paidWei = prizeEachWei * winnersLen;
                unchecked {
                    totalPaidWei += paidWei;
                }
                for (uint256 k; k < winnersLen; ) {
                    _addClaimableEth(winners[k], prizeEachWei);
                    unchecked {
                        ++k;
                    }
                }
            }
            unchecked {
                ++idx;
            }
        }

        unchecked {
            prizePool -= totalPaidWei;
            levelPrizePool = prizePool;
        }

        emit Jackpot((uint256(9) << 248) | packedTraits);
        return true;
    }

    // --- Daily & early‑purge jackpots ---------------------------------------------------------------

    /// @notice Pay four jackpot groups either during daily payouts or early‑purge sessions.
    /// @dev
    /// - For daily runs, the RNG word is the current VRF word; for early‑purge runs it is salted with the
    ///   current `jackpotCounter`.
    /// - Winning traits come from either observed purge counts (daily) or uniform draw (early).
    /// - Group sizes scale with the step within the 100‑level epoch: 1× for L..00–19, 2× for 20–39, …, 5× for 80–99.
    /// - Per‑group allocation is an equal split of `dailyTotal / 4` across sampled winners (integer division).
    /// - Updates `jackpotCounter` up/down depending on the mode and emits a `Jackpot(kind=4, traits...)` event.
    function payDailyJackpot(bool isDaily, uint24 lvl) internal {
        uint256 randWord = isDaily
            ? rngWord
            : uint256(keccak256(abi.encode(rngWord, uint8(5), jackpotCounter)));

        uint8[4] memory winningTraits = isDaily
            ? _getWinningTraits(randWord, dailyPurgeCount)
            : _getRandomTraits(randWord);

        uint256 multiplier = 1 + ((lvl % 100) / 20); // 1..5

        uint256 dailyTotalWei;
        if (isDaily) {
            dailyTotalWei =
                (levelPrizePool * (250 + uint256(jackpotCounter) * 50)) /
                10_000;
        } else {
            uint256 baseWei = carryoverForNextLevel;
            if ((lvl % 20) == 0) dailyTotalWei = baseWei / 100;
            else if (lvl >= 21 && (lvl % 10) == 1)
                dailyTotalWei = (baseWei * 6) / 100;
            else dailyTotalWei = baseWei / 40;
        }

        uint256 perGroupWei = dailyTotalWei / 4;
        uint256 totalPaidWei;

        for (uint8 groupIdx; groupIdx < 4; ) {
            uint256 wantWinners;
            if (groupIdx < 3) {
                wantWinners =
                    (
                        groupIdx == 0
                            ? 30
                            : groupIdx == 1
                                ? 20
                                : 10
                    ) *
                    multiplier;
            } else wantWinners = 1;

            address[] memory winners = _randTraitTicket(
                traitPurgeTicket[lvl],
                randWord,
                winningTraits[groupIdx],
                uint8(wantWinners),
                uint8(69 + groupIdx)
            );

            uint256 winnersLen = winners.length;
            uint256 prizeEachWei = winnersLen == 0
                ? 0
                : perGroupWei / winnersLen;
            if (prizeEachWei != 0) {
                unchecked {
                    totalPaidWei += prizeEachWei * winnersLen;
                }
                for (uint256 k; k < winnersLen; ) {
                    _addClaimableEth(winners[k], prizeEachWei);
                    unchecked {
                        ++k;
                    }
                }
            }
            unchecked {
                ++groupIdx;
            }
        }

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
            prizePool -= totalPaidWei;
            if (
                jackpotCounter >= 15 || (lvl % 100 == 0 && jackpotCounter == 14)
            ) {
                _endLevel(420);
                return;
            }
            _clearDailyPurgeCount();
        } else {
            unchecked {
                carryoverForNextLevel -= totalPaidWei;
                --jackpotCounter;
            }
        }
    }

    function _endJackpot(
        uint24 lvl,
        uint32 cap,
        uint48 dayIdx,
        bool bonusFlip,
        bool pauseBetting
    ) private returns (bool ok) {
        if (pauseBetting) {
            ok = IPurgeCoinInterface(_coin).processCoinflipPayouts(
                lvl,
                cap,
                bonusFlip
            );
            if (!ok) return false;
        }
        dailyIdx = dayIdx;
        rngConsumed = true;
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

    /// @notice Arm a new VRF request and reset RNG state.
    /// @param ts Current block timestamp (48-bit truncated).
    /// @param pauseBetting If false, keeps coinflip betting running on the coin contract during VRF wait.
    function _requestVrf(uint48 ts, bool pauseBetting) internal {
        rngFulfilled = false;
        rngWord = 0;
        rngTs = ts;
        rngConsumed = false;
        IPurgeCoinInterface(_coin).requestRngPurgeGame(pauseBetting);
    }

    /// @notice Handle ETH payments for purchases; forwards affiliate rewards in Purgecoin.
    /// @param scaledQty Quantity scaled by 100 (to keep integer math with `price`).
    /// @param affiliateCode Affiliate/referral code provided by the buyer.
    function _ethReceive(
        uint256 scaledQty,
        bytes32 affiliateCode,
        uint256 bonusUnits
    ) private returns (uint256 bonusMint) {
        uint256 expectedWei = (price * scaledQty) / 100;
        if (msg.value != expectedWei) revert E();

        unchecked {
            prizePool += msg.value;
        }

        IPurgeCoinInterface coin = IPurgeCoinInterface(_coin);
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
            coin.payAffiliate(
                affiliateAmount,
                affiliateCode,
                msg.sender,
                level
            );
        }

        bonusMint = (bonusUnits * priceCoin * pct) / 100;
    }

    /// @notice Handle Purgecoin coin payments for purchases;
    /// @dev 1.5x cost on steps where `level % 20 == 13`. 10% discount on 18. Applies post-adjustment discount.
    function _coinReceive(
        uint256 amount,
        uint24 lvl,
        uint256 discount
    ) private {
        if (lvl % 20 == 13) amount = (amount * 3) / 2;
        else if (lvl % 20 == 18) amount = (amount * 9) / 10;
        amount -= discount;
        IPurgeCoinInterface(_coin).burnInGame(msg.sender, amount);
    }

    function _enforceCenturyLuckbox(uint24 lvl, uint256 unit) private view {
        if (lvl % 100 == 0) {
            if (
                IPurgeCoinInterface(_coin).playerLuckbox(msg.sender) <
                10 * unit * ((lvl / 100) + 1)
            ) revert LuckboxTooSmall();
        }
    }

    // --- Map / NFT airdrop batching ------------------------------------------------------------------

    /// @notice Process a batch of map mints using a caller-provided writes budget (0 = auto).
    /// @param writesBudget Count of SSTORE writes allowed this tx; hard-clamped to ≤16M-safe.
    /// @return finished True if all pending map mints have been fully processed.
    function _processMapBatch(
        uint32 writesBudget
    ) private returns (bool finished) {
        uint256 total = pendingMapMints.length;
        if (airdropIndex >= total) return true;

        if (writesBudget == 0) writesBudget = WRITES_BUDGET_SAFE;
        if (phase < 2) {
            writesBudget = (writesBudget * 3) / 4;
            phase = 2;
        } else if (phase == 3) writesBudget = (writesBudget * 3) / 4;
        uint32 used = 0;
        uint256 entropy = rngWord;

        while (airdropIndex < total && used < writesBudget) {
            address p = pendingMapMints[airdropIndex];
            uint32 owed = playerMapMintsOwed[p];
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
            uint256 baseKey = _baseTokenId + (uint256(airdropIndex) << 20);
            _raritySymbolBatch(
                p,
                baseKey,
                airdropMapsProcessedCount,
                take,
                entropy
            );

            // writes accounting: ticket writes + per-address overhead + finish overhead
            uint32 writesThis = (take <= 256) ? (take * 2) : (take + 256);
            writesThis += baseOv;
            if (take == owed) {
                writesThis += 1;
            }

            unchecked {
                playerMapMintsOwed[p] = owed - take;
                airdropMapsProcessedCount += take;
                used += writesThis;
                if (playerMapMintsOwed[p] == 0) {
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
    function _processNftBatch(
        uint32 playersToProcess
    ) private returns (bool finished) {
        uint256 totalPlayers = pendingNftMints.length;
        if (airdropIndex >= totalPlayers) return true;

        uint32 players = (playersToProcess == 0)
            ? NFT_AIRDROP_PLAYER_BATCH_SIZE
            : playersToProcess;
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
            IPurgeGameNFT(_nft).gameMint(player, chunk);

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
            assembly {
                mstore(0x00, add(baseKey, groupIdx))
                mstore(0x20, entropyWord)
                seed := keccak256(0x00, 0x40)
            }
            uint64 s = uint64(seed) | 1;

            uint8 offset = uint8(i & 15);
            unchecked {
                for (uint8 skip; skip < offset; ++skip) {
                    s ^= (s >> 12);
                    s ^= (s << 25);
                    s ^= (s >> 27);
                    s *= 2685821657736338717;
                }
            }

            for (uint8 j = offset; j < 16 && i < endIndex; ) {
                unchecked {
                    s ^= (s >> 12);
                    s ^= (s << 25);
                    s ^= (s >> 27);
                    uint64 rnd64 = s * 2685821657736338717;

                    uint8 quadrant = uint8(i & 3);
                    uint8 traitId = _getTrait(rnd64) + (quadrant << 6);

                    if (counts[traitId]++ == 0) {
                        touchedTraits[touchedLen++] = traitId;
                    }
                    ++i;
                    ++j;
                }
            }
        }

        uint24 lvl = level; // NEW: write into the current level’s buckets

        // One length SSTORE per touched trait, then contiguous ticket writes
        for (uint16 u; u < touchedLen; ) {
            uint8 traitId = touchedTraits[u];
            uint32 occurrences = counts[traitId];

            assembly {
                // mapping(uint24 => address[][256]) traitPurgeTicket;
                // base slot for this level: keccak256(level, traitPurgeTicket.slot)
                mstore(0x00, lvl)
                mstore(0x20, traitPurgeTicket.slot)
                let base := keccak256(0x00, 0x40)

                // fixed-size array element slot = base + traitId
                let elem := add(base, traitId)
                let len := sload(elem)
                sstore(elem, add(len, occurrences)) // grow once

                // data area for the dynamic array: keccak256(elem)
                mstore(0x00, elem)
                let data := keccak256(0x00, 0x20)
                let addr := player

                for {
                    let k := 0
                } lt(k, occurrences) {
                    k := add(k, 1)
                } {
                    sstore(add(data, add(len, k)), addr)
                }
            }
            unchecked {
                ++u;
            }
        }
    }

    // --- Trait weighting / helpers -------------------------------------------------------------------

    /// @notice Map a 32-bit random input to an 0..7 bucket with a fixed piecewise distribution.
    /// @dev Distribution over 75 slots: [10,10,10,10,9,9,9,8] → buckets 0..7 respectively.
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
    /// @dev High‑level: two weighted 3‑bit values (category, sub) → pack to a single 6‑bit trait.
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
    /// @param kind  External jackpot kind (0 = BAF, 1 = Decimator).
    /// @param poolWei Total wei allocated for this external jackpot stage.
    /// @param cap   Step cap forwarded to the external processor.
    /// @return finished True if the external stage reports completion.
    function _progressExternal(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl
    ) internal returns (bool finished) {
        if (kind == 0 && (rngWord & 1) == 0) return true;

        (
            bool isFinished,
            address[] memory winnersArr,
            uint256[] memory amountsArr,
            uint256 returnWei
        ) = IPurgeCoinInterface(_coin).runExternalJackpot(
                kind,
                poolWei,
                cap,
                lvl
            );

        for (uint256 i; i < winnersArr.length; ) {
            _addClaimableEth(winnersArr[i], amountsArr[i]);
            unchecked {
                ++i;
            }
        }

        if (isFinished) {
            // Decrease carryover by the spent portion (poolWei - returnWei).
            carryoverForNextLevel -= (poolWei - returnWei);
        }
        return isFinished;
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
        bytes32 base = keccak256(abi.encode(randomWord, salt, trait));
        for (uint256 i; i < numWinners; ) {
            uint256 idx = uint256(keccak256(abi.encode(base, i))) % len;
            winners[i] = holders[idx];
            unchecked {
                ++i;
            }
        }
    }

    function _getRandomTraits(
        uint256 rw
    ) internal pure returns (uint8[4] memory w) {
        w[0] = uint8(rw & 0x3F);
        w[1] = 64 + uint8((rw >> 6) & 0x3F);
        w[2] = 128 + uint8((rw >> 12) & 0x3F);
        w[3] = 192 + uint8((rw >> 18) & 0x3F);
    }

    function _getWinningTraits(
        uint256 randomWord,
        uint32[80] storage counters
    ) internal view returns (uint8[4] memory w) {
        uint256 seed = uint256(
            keccak256(abi.encodePacked(randomWord, uint256(0xBAF)))
        );

        uint8 sym = _maxIdxInRange(counters, 0, 8);
        uint8 col0 = uint8(
            uint256(keccak256(abi.encodePacked(seed, uint256(0)))) & 7
        );
        w[0] = (col0 << 3) | sym;

        uint8 maxColor = _maxIdxInRange(counters, 8, 8);
        uint8 randSym = uint8(
            uint256(keccak256(abi.encodePacked(seed, uint256(1)))) & 7
        );
        w[1] = 64 + ((maxColor << 3) | randSym);

        uint8 maxTrait = _maxIdxInRange(counters, 16, 64);
        w[2] = 128 + maxTrait;

        w[3] = 192 +
            uint8(
                uint256(keccak256(abi.encodePacked(seed, uint256(2)))) & 63
            );
    }

    function _maxIdxInRange(
        uint32[80] storage counters,
        uint8 base,
        uint8 len
    ) private view returns (uint8) {
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
    function describeToken(
        uint256 tokenId
    )
        external
        view
        returns (
            bool isTrophy,
            uint256 trophyInfo,
            uint256 metaPacked,
            uint32[4] memory remaining
        )
    {
        trophyInfo = trophyData[tokenId];
        if (tokenId < _baseTokenId - 1 && trophyInfo == 0) revert E();

        if (trophyInfo != 0) {
            return (true, trophyInfo, 0, remaining);
        }

        uint32 traitsPacked = tokenTraits[tokenId];
        uint8 t0 = uint8(traitsPacked);
        uint8 t1 = uint8(traitsPacked >> 8);
        uint8 t2 = uint8(traitsPacked >> 16);
        uint8 t3 = uint8(traitsPacked >> 24);

        uint256 lastExterminated = lastExterminatedTrait;
        metaPacked =
            (uint256(lastExterminated) << 56) |
            (uint256(level) << 32) |
            uint256(traitsPacked);

        remaining[0] = traitRemaining[t0];
        remaining[1] = traitRemaining[t1];
        remaining[2] = traitRemaining[t2];
        remaining[3] = traitRemaining[t3];

        return (false, 0, metaPacked, remaining);
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
    function getPlayerPurchases(
        address player
    ) external view returns (uint32 mints, uint32 maps) {
        mints = playerTokensOwed[player];
        maps = playerMapMintsOwed[player];
    }
}
