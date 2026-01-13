// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DegenerusGame
 * @author Burnie Degenerus
 * @notice Core gamepiece game contract managing state machine, VRF integration, ContractAddresses.JACKPOTS, and prize pools.
 *
 * @dev ARCHITECTURE:
 *      - 3-state FSM: SETUP(1) → PURCHASE(2) → BURN(3) → SETUP(1) → (cycle)
 *      - GAMEOVER(86) is terminal
 *      - Presale is a toggle (lootboxPresaleActive), not a state
 *      - Chainlink VRF for randomness with RNG lock to prevent manipulation
 *      - Delegatecall modules: endgame, jackpot, mint (must inherit DegenerusGameStorage)
 *      - Prize pool flow: futurePrizePool → nextPrizePool → currentPrizePool → ContractAddresses.JACKPOTS/rewardPool → claimableWinnings
 *
 * @dev CRITICAL INVARIANTS:
 *      - address(this).balance + steth.balanceOf(this) >= claimablePool
 *      - gameState transitions: 1→2→3→1→2 (starts at 1, 86 = terminal)
 *      - lootboxPresaleActive is one-way (true→false, never false→true)
 *
 * @dev SECURITY:
 *      - Pull pattern for ETH/stETH withdrawals (claimWinnings)
 *      - RNG lock prevents state manipulation during VRF callback window
 *      - Access control via msg.sender checks
 *      - Delegatecall modules use constant addresses from ContractAddresses
 *      - 18h VRF timeout, 3-day stall detection, 365-day inactivity guard
 */

import {IDegenerusGamepieces} from "./interfaces/IDegenerusGamepieces.sol";
import {IDegenerusCoin} from "./interfaces/IDegenerusCoin.sol";
import {IDegenerusAffiliate} from "./interfaces/IDegenerusAffiliate.sol";
import {IDegenerusJackpots} from "./interfaces/IDegenerusJackpots.sol";
import {IStETH} from "./interfaces/IStETH.sol";
import {
    IDegenerusGameEndgameModule,
    IDegenerusGameJackpotModule,
    IDegenerusGameMintModule
} from "./interfaces/IDegenerusGameModules.sol";
import {MintPaymentKind} from "./interfaces/IDegenerusGame.sol";
import {DegenerusGameStorage} from "./storage/DegenerusGameStorage.sol";
import {ContractAddresses} from "./ContractAddresses.sol";

/*+==============================================================================+
  |                     EXTERNAL INTERFACE DEFINITIONS                           |
  +==============================================================================+
  |  Minimal interfaces for external contracts this contract interacts with.     |
  |  These are defined locally to avoid circular import dependencies.            |
  +==============================================================================+*/

/// @notice Interface for reading player quest states.
interface IDegenerusQuestView {
    /// @notice Get a player's quest progress and streak information.
    function playerQuestStates(
        address player
    )
        external
        view
        returns (uint32 streak, uint32 lastCompletedDay, uint128[2] memory progress, bool[2] memory completed);
}

/// @notice Interface for normalizing burn quests when burn window ends.
interface IDegenerusQuestNormalize {
    /// @notice Called when extermination ends the burn window mid-day.
    function normalizeActiveBurnQuests() external;
}

/// @notice Minimal ERC721 interface for trophy balance checks.
interface IERC721BalanceOf {
    /// @notice Get gamepiece count for an owner.
    function balanceOf(address owner) external view returns (uint256);
}

/*+==============================================================================+
  |                         VRF (CHAINLINK) TYPES                                |
  +==============================================================================+*/

/// @notice Request structure for Chainlink VRF V2.5 Plus.
/// @dev Matches VRFV2PlusClient.RandomWordsRequest for real Chainlink VRF V2.5 Plus coordinator.
struct VRFRandomWordsRequest {
    bytes32 keyHash; // VRF key hash (identifies the oracle)
    uint256 subId; // Subscription ID for billing
    uint16 requestConfirmations; // Blocks before VRF is considered final
    uint32 callbackGasLimit; // Gas limit for fulfillment callback
    uint32 numWords; // Number of random words requested (always 1 here)
    bytes extraArgs; // Additional arguments (empty for LINK payment, or encoded ExtraArgsV1 for native payment)
}

/// @notice Interface for Chainlink VRF Coordinator.
interface IVRFCoordinator {
    /// @notice Request random words from Chainlink VRF.
    /// @return requestId The ID to match with fulfillment callback.
    function requestRandomWords(VRFRandomWordsRequest calldata request) external returns (uint256);
}

// ===========================================================================
// Contract
// ===========================================================================

/**
 * @title DegenerusGame
 * @author Burnie Degenerus
 * @notice Core gamepiece game contract implementing the game state machine, VRF integration,
 *         and orchestration of all gameplay mechanics.
 * @dev Inherits DegenerusGameStorage for shared storage layout with delegate modules.
 *      Uses delegatecall pattern for complex logic (endgame, jackpot, mint modules).
 * @custom:security-contact burnie@degener.us
 */
contract DegenerusGame is DegenerusGameStorage {
    /*+======================================================================+
      |                              ERRORS                                  |
      +======================================================================+
      |  Custom errors for gas-efficient reverts. Each error maps to a       |
      |  specific failure condition in the game flow.                        |
      +======================================================================+*/

    /// @notice Generic guard error for failed validation checks.
    /// @dev Used in multiple paths where specific error context isn't critical.
    error E();

    /// @notice Caller must have completed an ETH mint today before advancing.
    /// @dev Gate prevents advancing without skin-in-the-game (except when cap != 0).
    error MustMintToday();

    /// @notice Called in a phase where the action is not permitted.
    /// @dev Game state machine enforces phase-specific operations.
    error NotTimeYet();

    /// @notice VRF request is still pending; cannot proceed.
    /// @dev Operations requiring randomness must wait for VRF fulfillment.
    error RngNotReady();

    /// @notice RNG is locked (VRF pending); nudge operations blocked.
    /// @dev reverseFlip() is only available before RNG request starts.
    error RngLocked();

    /// @notice Invalid quantity for burn or other batched operations.
    /// @dev Enforces bounds: 1-75 tokens per burn call.
    error InvalidQuantity();

    /// @notice VRF coordinator swap not allowed yet.
    /// @dev Requires 3-day RNG stall before emergency rotation is permitted.
    error VrfUpdateNotReady();

    /*+======================================================================+
      |                              EVENTS                                  |
      +======================================================================+
      |  Events for off-chain indexers and UIs. All critical state changes   |
      |  emit events for transparency and auditability.                      |
      +======================================================================+*/

    /// @notice Emitted when ETH winnings are credited to a player's claimable balance.
    /// @param player The original beneficiary (may be same as recipient).
    /// @param recipient The address receiving the credit.
    /// @param amount The wei amount credited.
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);

    /// @notice Emitted when a player burns tokens for jackpot tickets.
    /// @param player The player who burned the tokens.
    /// @param tokenIds Array of token IDs that were burned.
    event Degenerus(address indexed player, uint256[] tokenIds);

    /// @notice Emitted each time the game advances (state machine tick).
    /// @param gameState The current game state after advancement.
    event Advance(uint8 gameState);

    /// @notice Emitted when a player pays BURNIE to nudge the next RNG word.
    /// @param caller The player who paid for the nudge.
    /// @param totalQueued Total nudges queued for next fulfillment.
    /// @param cost The BURNIE cost paid for this nudge.
    event ReverseFlip(address indexed caller, uint256 totalQueued, uint256 cost);

    /// @notice Emitted when the VRF coordinator is rotated (emergency or initial wire).
    /// @param previous The previous coordinator address (address(0) if first wire).
    /// @param current The new coordinator address.
    event VrfCoordinatorUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when a loot box purchase is recorded.
    /// @param buyer Loot box purchaser.
    /// @param day Purchase day index.
    /// @param amount Total ETH contributed.
    /// @param presale True if purchased during loot box presale mode.
    /// @param futureShare ETH reserved for future prize pool funding.
    /// @param nextPrizeShare ETH added to nextPrizePool.
    /// @param vaultShare ETH forwarded to the vault (presale only).
    /// @param rewardShare ETH added to rewardPool.
    event LootBoxPurchased(
        address indexed buyer,
        uint48 indexed day,
        uint256 amount,
        bool presale,
        uint256 futureShare,
        uint256 nextPrizeShare,
        uint256 vaultShare,
        uint256 rewardShare
    );

    /// @notice Emitted when a loot box is opened.
    /// @param player Loot box owner.
    /// @param day Purchase day index.
    /// @param amount ETH amount resolved.
    /// @param futureLevel Base future level (level+1 at purchase).
    /// @param futureTickets Total future tickets awarded across futureLevel..futureLevel+4.
    /// @param currentTickets Current-level tickets awarded (always 0 for loot box rolls).
    /// @param burnie BURNIE credited for loot box EV.
    /// @param bonusBurnie Bonus BURNIE from presale pool (if any).
    event LootBoxOpened(
        address indexed player,
        uint48 indexed day,
        uint256 amount,
        uint24 futureLevel,
        uint32 futureTickets,
        uint32 currentTickets,
        uint256 burnie,
        uint256 bonusBurnie
    );

    /// @notice Emitted when loot box presale mode is toggled.
    /// @param active True if presale mode is active.
    event LootBoxPresaleStatus(bool active);

    /*+=======================================================================+
      |                   PRECOMPUTED ADDRESSES (CONSTANT)                    |
      +=======================================================================+
      |  Core contract references are read from ContractAddresses and baked   |
      |  into bytecode. They cannot change after deployment.                  |
      +=======================================================================+*/

    /// @notice The BURNIE ERC20 token contract.
    /// @dev Trusted for creditFlip, burnCoin, processCoinflipPayouts, etc.
    IDegenerusCoin internal constant coin = IDegenerusCoin(ContractAddresses.COIN);

    /// @notice The gamepieces gamepiece contract (ERC721).
    /// @dev Trusted for mint/burn/metadata operations.
    IDegenerusGamepieces internal constant nft = IDegenerusGamepieces(ContractAddresses.GAMEPIECES);

    /// @notice Lido stETH token contract.
    /// @dev Used for staking ETH and managing yield.
    IStETH internal constant steth = IStETH(ContractAddresses.STETH_TOKEN);

    /// @notice DegenerusJackpots contract for decimator/BAF jackpots.
    IDegenerusJackpots internal constant jackpots = IDegenerusJackpots(ContractAddresses.JACKPOTS);

    /// @notice Affiliate program contract for bonus points and referrers.
    IDegenerusAffiliate internal constant affiliate = IDegenerusAffiliate(ContractAddresses.AFFILIATE);

    /// @notice Quest module view interface for streak lookups.
    IDegenerusQuestView internal constant questView = IDegenerusQuestView(ContractAddresses.QUESTS);

    /// @notice Quest module interface for burn quest normalization.
    IDegenerusQuestNormalize internal constant questNormalize = IDegenerusQuestNormalize(ContractAddresses.QUESTS);

    /// @notice Trophy contract for balance checks.
    IERC721BalanceOf internal constant trophies = IERC721BalanceOf(ContractAddresses.TROPHIES);

    /*+======================================================================+
      |                        VRF CONFIGURATION                             |
      +======================================================================+
      |  Chainlink VRF settings. Mutable to allow emergency rotation if      |
      |  the VRF coordinator becomes unresponsive (3-day stall required).    |
      +======================================================================+*/

    /// @notice Chainlink VRF V2.5 coordinator contract.
    /// @dev Mutable for emergency rotation; see updateVrfCoordinatorAndSub().
    IVRFCoordinator private vrfCoordinator;

    /// @notice VRF key hash identifying the oracle and gas lane.
    /// @dev Rotatable with coordinator; determines gas price tier.
    bytes32 private vrfKeyHash;

    /// @notice VRF subscription ID for LINK billing.
    /// @dev Mutable to allow subscription rotation without redeploying.
    uint256 private vrfSubscriptionId;

    /*+======================================================================+
      |                           CONSTANTS                                  |
      +======================================================================+
      |  Game parameters and bit manipulation constants. All constants are   |
      |  private to prevent external dependency on specific values.          |
      +======================================================================+*/

    /// @dev Maximum idle time before game-over drain (2.5 years).
    ///      Triggers if game is deployed but never started.
    uint256 private constant DEPLOY_IDLE_TIMEOUT = (365 days * 5) / 2;

    /// @dev Sentinel value for levelStartTime indicating "not started".
    uint48 private constant LEVEL_START_SENTINEL = type(uint48).max;

    /// @dev Anchor timestamp for day window calculations.
    ///      Days are offset from unix midnight by this value (~23 hours).
    uint48 private constant JACKPOT_RESET_TIME = 82620;

    /// @dev Minimum wait before using fallback entropy in game-over mode.
    uint48 private constant GAMEOVER_RNG_FALLBACK_DELAY = 3 days;

    /// @dev Maximum ContractAddresses.JACKPOTS per level before forced advancement.
    uint8 private constant JACKPOT_LEVEL_CAP = 10;

    /// @dev MAP jackpot type: no MAP jackpot pending.
    uint8 private constant MAP_JACKPOT_NONE = 0;

    /// @dev Sentinel value for "no trait exterminated" (outside valid 0-255 range).
    uint16 private constant TRAIT_ID_TIMEOUT = 420;

    /// @dev Gas limit for VRF callback (200k is sufficient for simple fulfillment).
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;

    /// @dev Block confirmations required before VRF result is final.
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;

    /// @dev Base BURNIE cost for reverseFlip() nudge (100 BURNIE).
    ///      Compounds +50% per queued nudge.
    uint256 private constant RNG_NUDGE_BASE_COST = 100 ether;

    /// @dev Max players processed per future-mint activation batch.
    uint32 private constant FUTURE_MINT_PLAYER_BATCH_SIZE = 96;

    /// @dev Loot box minimum purchase amount (0.01 ETH).
    ///      Allows flexible amounts so players can spend exact claimable balances.
    uint256 private constant LOOTBOX_MIN = 0.01 ether;

    /// @dev Loot box EV configuration (basis points of total ETH).
    ///      Both modes: 60% tickets/gamepieces, 20% small BURNIE, 20% large BURNIE (d20 roll).
    ///      Within the 60% ticket outcome, there's a 1/6 chance for a gamepiece if budget allows.
    uint16 private constant LOOTBOX_TICKET_EV_BPS = 6000;
    uint16 private constant LOOTBOX_SMALL_BURNIE_EV_BPS = 2000;
    uint16 private constant LOOTBOX_LARGE_BURNIE_EV_BPS = 2000;

    /// @dev Loot box per-roll payouts (same for both modes, presale applies 2x multiplier to BURNIE).
    ///      Normal mode:
    ///      - Tickets/Gamepieces: 60% × 116.67% = 70% (1/6 chance gamepiece if budget >= 4 MAP price)
    ///      - Small BURNIE: 20% × 5% = 1%
    ///      - Large BURNIE: 20% × 195% = 39%
    ///      - Total EV: 110%
    ///      Presale mode (2x BURNIE multiplier applied after roll):
    ///      - Tickets/Gamepieces: 60% × 116.67% = 70%
    ///      - Small BURNIE: 20% × 5% × 2 = 2%
    ///      - Large BURNIE: 20% × 195% × 2 = 78%
    ///      - Total EV: 150%
    ///
    ///      Note: If ticket budget < 1 MAP price, fallback converts to BURNIE at 80% value (20% penalty).
    uint16 private constant LOOTBOX_TICKET_ROLL_BPS = 11667; // 116.67%
    uint16 private constant LOOTBOX_SMALL_BURNIE_ROLL_BPS = 500; // 5%
    uint16 private constant LOOTBOX_LARGE_BURNIE_ROLL_BPS = 19500; // 195%

    /// @dev Loot box amount split threshold (two rolls when exceeded).
    uint256 private constant LOOTBOX_SPLIT_THRESHOLD = 1 ether;

    /// @dev Loot box pool split (basis points of total ETH).
    uint16 private constant LOOTBOX_SPLIT_FUTURE_BPS = 6000;
    uint16 private constant LOOTBOX_SPLIT_NEXT_BPS = 2000;

    /// @dev Loot box presale pool split (basis points of total ETH).
    uint16 private constant LOOTBOX_PRESALE_SPLIT_FUTURE_BPS = 1000;
    uint16 private constant LOOTBOX_PRESALE_SPLIT_NEXT_BPS = 1000;
    uint16 private constant LOOTBOX_PRESALE_SPLIT_VAULT_BPS = 3000;


    /*+======================================================================+
      |                    MINT PACKED BIT LAYOUT                            |
      +======================================================================+
      |  Player mint history is packed into a single uint256 for gas         |
      |  efficiency. Layout (LSB first):                                     |
      |                                                                      |
      |  [0-23]   lastEthLevel     - Last level where player minted with ETH |
      |  [24-47]  ethLevelCount    - Total levels with ETH mints             |
      |  [48-71]  ethLevelStreak   - Consecutive levels with ETH mints       |
      |  [72-103] lastEthDay       - Day index of last ETH mint              |
      |  [104-127] unitsLevel      - Level index for unitsAtLevel tracking   |
      |  [128-227] reserved        - Reserved for forward compatibility      |
      |  [228-243] unitsAtLevel    - Mints at current level                  |
      |  [244]    bonusPaid        - Level bonus claimed flag                |
      +======================================================================+*/

    /// @dev Bit mask for 24-bit fields.
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;

    /// @dev Bit mask for 32-bit fields.
    uint256 private constant MINT_MASK_32 = (uint256(1) << 32) - 1;

    /// @dev Bit shift for lastEthLevel field.
    uint256 private constant ETH_LAST_LEVEL_SHIFT = 0;

    /// @dev Bit shift for ethLevelCount field.
    uint256 private constant ETH_LEVEL_COUNT_SHIFT = 24;

    /// @dev Bit shift for ethLevelStreak field.
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;

    /// @dev Bit shift for lastEthDay field.
    uint256 private constant ETH_DAY_SHIFT = 72;

    /*+======================================================================+
      |                          CONSTRUCTOR                                 |
      +======================================================================+
      |  Initialize storage wiring and set up initial approvals.             |
      |  The constructor wires together the entire game ecosystem.           |
      +======================================================================+*/

    /**
     * @notice Initialize the game with precomputed contract references.
     * @dev All addresses are compile-time constants from ContractAddresses for gas optimization.
     *      Records deploy timestamp to make day 1 = deploy day.
     */
    constructor() {
        // Initialize game in setup state (purchase phase starts via admin control).
        gameState = GAME_STATE_SETUP;
        levelStartTime = LEVEL_START_SENTINEL;

        // Record deploy time for relative day calculation (day 1 = deploy day)
        deployTime = uint48(block.timestamp);

        // Set deploy time on BurnieCoin contract for synchronized day calculations
        coin.setDeployTime(deployTime);
    }

    /*+======================================================================+
      |                           MODIFIERS                                  |
      +======================================================================+*/

    /*+======================================================================+
      |                   VIEW: GAME STATUS & STATE                          |
      +======================================================================+
      |  Lightweight view functions for UI/frontend consumption. These       |
      |  provide read-only access to game state without gas costs.           |
      +======================================================================+*/

    /// @notice Get the prize pool target for the current 100-level cycle.
    /// @dev Target is reset at level % 100 == 0 based on reward pool size.
    /// @return The lastPrizePool value (ETH wei).
    function prizePoolTargetView() external view returns (uint256) {
        return lastPrizePool;
    }

    /// @notice Get the prize pool accumulated for the next level.
    /// @dev Mint fees flow into nextPrizePool until target is met.
    /// @return The nextPrizePool value (ETH wei).
    function nextPrizePoolView() external view returns (uint256) {
        return nextPrizePool;
    }

    /// @notice Get the prize pool reserved for a future level.
    /// @param lvl Target level for the reserved pool.
    /// @return The futurePrizePool value (ETH wei).
    function futurePrizePoolView(uint24 lvl) external view returns (uint256) {
        return futurePrizePool[lvl];
    }

    /// @notice Get the aggregate future prize pool across all levels.
    /// @return The futurePrizePoolTotal value (ETH wei).
    function futurePrizePoolTotalView() external view returns (uint256) {
        return futurePrizePoolTotal;
    }

    /// @notice Get queued future reward mints owed for a level.
    /// @param lvl Target level for the queued mints.
    /// @param player Player address to query.
    /// @return The number of reward mints owed.
    function futureMintsOwedView(uint24 lvl, address player) external view returns (uint32) {
        return futureMintsOwed[lvl][player];
    }

    /// @notice Get loot box status for a player/day.
    /// @param player Player address to query.
    /// @param day Day index of the loot box purchase.
    /// @return amount ETH amount recorded for the loot box (wei).
    /// @return presale True if the loot box was purchased during presale mode.
    function lootboxStatus(address player, uint48 day) external view returns (uint256 amount, bool presale) {
        amount = lootboxEth[day][player];
        presale = lootboxPresale[day][player];
    }

    /// @notice Get the current prize pool (jackpots are paid from this).
    /// @return The currentPrizePool value (ETH wei).
    function currentPrizePoolView() external view returns (uint256) {
        return currentPrizePool;
    }

    /// @notice Get the reward pool (accumulates exterminator keeps and feeds decimator/BAF jackpots).
    /// @return The rewardPool value (ETH wei).
    function rewardPoolView() external view returns (uint256) {
        return rewardPool;
    }

    /// @notice Get the claimable pool (reserved for player winnings claims).
    /// @return The claimablePool value (ETH wei).
    function claimablePoolView() external view returns (uint256) {
        return claimablePool;
    }

    /// @notice Get the untracked yield pool (excess ETH+stETH available for operations).
    /// @dev Calculated as: (ETH balance + stETH balance) - claimablePool
    /// @return The yieldPool value (ETH wei).
    function yieldPoolView() external view returns (uint256) {
        uint256 totalBalance = address(this).balance + steth.balanceOf(address(this));
        uint256 tracked = claimablePool;
        if (totalBalance <= tracked) return 0;
        return totalBalance - tracked;
    }

    /// @notice Get the current mint price in wei.
    /// @dev Price varies by level cycle: 0.05/0.05/0.1/0.15/0.25 ETH.
    /// @return Current price in wei.
    function mintPrice() external view returns (uint256) {
        return price;
    }

    /// @notice Get the VRF random word recorded for a specific day.
    /// @dev Days are indexed from deploy time (day 1 = deploy day).
    /// @param day The day index to query.
    /// @return The random word (0 if no word recorded for that day).
    function rngWordForDay(uint48 day) external view returns (uint256) {
        return rngWordByDay[day];
    }

    /// @notice Get the most recently recorded RNG word.
    /// @dev Uses dailyIdx to locate the last completed day.
    function lastRngWord() external view returns (uint256) {
        return rngWordByDay[dailyIdx];
    }

    /// @notice Check if RNG is currently locked (VRF request pending).
    /// @dev When locked, burns and certain operations are blocked.
    /// @return True if RNG lock is active.
    function rngLocked() public view returns (bool) {
        return rngLockedFlag;
    }

    /// @notice Check if VRF has been fulfilled for current request.
    /// @return True if random word is available for use.
    function isRngFulfilled() external view returns (bool) {
        return rngFulfilled;
    }

    /// @dev Calculate current day index from block timestamp.
    ///      Day 1 = deploy day. Days reset at JACKPOT_RESET_TIME (22:57 UTC), not midnight.
    /// @return Current day index since deploy (1-indexed).
    function _currentDayIndex() private view returns (uint48) {
        // Calculate day boundaries with JACKPOT_RESET_TIME offset
        uint48 deployDayBoundary = uint48((deployTime - JACKPOT_RESET_TIME) / 1 days);
        uint48 currentDayBoundary = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        return currentDayBoundary - deployDayBoundary + 1;
    }

    /// @dev Record loot box purchase as an ETH mint day for daily gate eligibility.
    ///      Updates the lastEthDay field in mintPacked_ storage.
    /// @param player Address of the loot box buyer.
    /// @param day Current day index.
    function _recordLootboxMintDay(address player, uint32 day) private {
        uint256 prevData = mintPacked_[player];
        uint32 prevDay = uint32((prevData >> ETH_DAY_SHIFT) & MINT_MASK_32);
        if (prevDay == day) {
            return; // Already recorded for today
        }
        uint256 clearedDay = prevData & ~(MINT_MASK_32 << ETH_DAY_SHIFT);
        mintPacked_[player] = clearedDay | (uint256(day) << ETH_DAY_SHIFT);
    }

    /// @dev Check if there's a 3-consecutive-day gap in VRF words.
    ///      Used to detect VRF coordinator failures requiring emergency rotation.
    /// @param day The day index to check from.
    /// @return True if day, day-1, and day-2 all have no recorded VRF word.
    function _threeDayRngGap(uint48 day) private view returns (bool) {
        if (rngWordByDay[day] != 0) return false;
        if (day == 0 || rngWordByDay[day - 1] != 0) return false;
        if (day < 2 || rngWordByDay[day - 2] != 0) return false;
        return true;
    }

    /// @notice Check if VRF has stalled for 3 consecutive days.
    /// @dev Enables emergency VRF coordinator rotation via updateVrfCoordinatorAndSub().
    /// @return True if no VRF word has been recorded for the last 3 day slots.
    function rngStalledForThreeDays() external view returns (bool) {
        return _threeDayRngGap(_currentDayIndex());
    }

    /*+========================================================================================+
      |                    ADMIN VRF FUNCTIONS                                                 |
      +========================================================================================+
      |  One-time VRF setup function called by ContractAddresses.ADMIN during deployment phase.|
      +========================================================================================+*/

    /// @notice One-time wiring of VRF config from the VRF ContractAddresses.ADMIN contract.
    /// @dev Access: ContractAddresses.ADMIN only. Idempotent after first wire (repeats must match).
    ///      SECURITY: Once wired, config cannot be changed except via emergency rotation.
    /// @param coordinator_ Chainlink VRF V2.5 coordinator address.
    /// @param subId VRF subscription ID for LINK billing.
    /// @param keyHash_ VRF key hash identifying the oracle and gas lane.
    function wireVrf(address coordinator_, uint256 subId, bytes32 keyHash_) external {
        if (msg.sender != ContractAddresses.ADMIN) revert E();

        // Idempotent once wired: allow only no-op repeats with identical config.
        if (vrfSubscriptionId != 0) {
            if (subId != vrfSubscriptionId) revert E();
            if (coordinator_ != address(vrfCoordinator)) revert E();
            if (keyHash_ != vrfKeyHash) revert E();
            return;
        }

        if (coordinator_ == address(0) || keyHash_ == bytes32(0) || subId == 0) revert E();

        address current = address(vrfCoordinator);
        vrfCoordinator = IVRFCoordinator(coordinator_);
        vrfSubscriptionId = subId;
        vrfKeyHash = keyHash_;
        emit VrfCoordinatorUpdated(current, coordinator_);
    }

    /*+======================================================================+
      |                   VIEW: DECIMATOR & PURCHASE INFO                    |
      +======================================================================+
      |  Status views for decimator window and purchase state.               |
      +======================================================================+*/

    /// @notice Check if decimator window is open and accessible.
    /// @dev Window is only "on" if flag is set AND RNG is not locked.
    /// @return on True if decimator entries are currently allowed.
    /// @return lvl Current game level.
    function decWindow() external view returns (bool on, uint24 lvl) {
        on = decWindowOpen && !rngLockedFlag;
        lvl = level;
    }

    /// @notice Raw check of decimator window flag (ignores RNG lock).
    /// @return open True if decimator window flag is set.
    function decWindowOpenFlag() external view returns (bool open) {
        return decWindowOpen;
    }

    /// @notice Comprehensive purchase info for UI consumption.
    /// @dev Bundles level, state, flags, and price into single call.
    ///      NOTE: lvl is incremented in state 3 to show "next level" being played.
    /// @return lvl Current level (or next level if in degenerus state).
    /// @return gameState_ Current game state (0-3, 86 for game over).
    /// @return lastPurchaseDay_ True if prize pool target is met.
    /// @return rngLocked_ True if VRF request is pending.
    /// @return priceWei Current mint price in wei.
    function purchaseInfo()
        external
        view
        returns (uint24 lvl, uint8 gameState_, bool lastPurchaseDay_, bool rngLocked_, uint256 priceWei)
    {
        lvl = level;
        gameState_ = gameState;
        lastPurchaseDay_ = (gameState_ == GAME_STATE_PURCHASE) && lastPurchaseDay;
        rngLocked_ = rngLockedFlag;
        priceWei = price;

        if (gameState_ == GAME_STATE_BURN) {
            unchecked {
                ++lvl;
            }
        }
    }

    /*+======================================================================+
      |                   VIEW: PLAYER MINT STATISTICS                       |
      +======================================================================+
      |  Unpack player mint history from the bit-packed mintPacked_ storage. |
      |  See MINT PACKED BIT LAYOUT above for field positions.               |
      +======================================================================+*/

    /// @notice Get the last level where player minted with ETH.
    /// @param player The player address to query.
    /// @return The level number (0 if never minted).
    function ethMintLastLevel(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> ETH_LAST_LEVEL_SHIFT) & MINT_MASK_24);
    }

    /// @notice Get total count of levels where player minted with ETH.
    /// @param player The player address to query.
    /// @return Number of distinct levels with ETH mints.
    function ethMintLevelCount(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
    }

    /// @notice Get player's current consecutive ETH mint streak.
    /// @param player The player address to query.
    /// @return Number of consecutive levels with ETH mints.
    function ethMintStreakCount(address player) external view returns (uint24) {
        return uint24((mintPacked_[player] >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
    }

    /// @notice Get combined mint statistics for a player.
    /// @dev Batches multiple stats into single call for gas efficiency.
    /// @param player The player address to query.
    /// @return lvl Current game level.
    /// @return levelCount Total levels with ETH mints.
    /// @return streak Consecutive level mint streak.
    function ethMintStats(address player) external view returns (uint24 lvl, uint24 levelCount, uint24 streak) {
        uint256 packed = mintPacked_[player];
        lvl = level;
        levelCount = uint24((packed >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
        streak = uint24((packed >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
    }

    /*+======================================================================+
      |                   VIEW: BONUS MULTIPLIER CALCULATION                 |
      +======================================================================+
      |  Player bonus multiplier determines airdrop rewards. Components:     |
      |  • Mint streak: +1% per consecutive level (cap 25%)                  |
      |  • Quest streak: +0.5% per consecutive quest (cap 25%)               |
      |  • Affiliate bonus: +1% per affiliate point (from referral scores)   |
      |  • Mint count bonus: +1% per mint level (scaled by cycle index/pos)  |
      |  • Trophy bonus: +10% per trophy (cap 50%)                           |
      +======================================================================+*/

    /// @notice Calculate player's total bonus multiplier in basis points.
    /// @dev 10000 bps = 1.0x multiplier. Max theoretical ~225% (22500 bps).
    ///      Components are additive and uncapped in aggregate.
    /// @param player The player address to calculate for.
    /// @return multiplierBps Total multiplier in basis points.
    function playerBonusMultiplier(address player) external view returns (uint256 multiplierBps) {
        if (player == address(0)) return 10000;

        uint256 packed = mintPacked_[player];
        uint24 levelCount = uint24((packed >> ETH_LEVEL_COUNT_SHIFT) & MINT_MASK_24);
        uint24 streak = uint24((packed >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24);
        uint24 currLevel = level;

        uint256 bonusBps;

        unchecked {
            // Mint streak: cap at 25, worth 1% each (100 bps)
            uint256 mintStreakPoints = streak > 25 ? 25 : uint256(streak);
            bonusBps = mintStreakPoints * 100;

            // Quest streak: cap at 50, worth 0.5% each (50 bps)

            (uint32 questStreakRaw, , , ) = questView.playerQuestStates(player);
            uint256 questStreak = questStreakRaw > 50 ? 50 : uint256(questStreakRaw);
            bonusBps += questStreak * 50;

            // Affiliate bonus: only if currLevel >= 1 and affiliate is set

            bonusBps += affiliate.affiliateBonusPointsBest(currLevel, player) * 100;

            // Mint count bonus: 1% each
            bonusBps += _mintCountBonusPoints(levelCount, currLevel) * 100;

            // Trophy bonus: +10% per trophy, capped at +50%

            uint256 trophyCount = trophies.balanceOf(player);
            if (trophyCount > 5) trophyCount = 5;
            bonusBps += trophyCount * 1000;
        }

        multiplierBps = 10000 + bonusBps;
    }

    /// @dev Calculate mint count bonus points based on level participation.
    ///      Rewards players who have minted on more levels with up to 25 bonus points (25% multiplier).
    ///      Requirement scales with game progress but caps at 75 level mints for reachability.
    /// @param mintCount Player's total level mint count.
    /// @param currLevel Current game level.
    /// @return Bonus points (0-25) for multiplier calculation.
    function _mintCountBonusPoints(uint24 mintCount, uint24 currLevel) private pure returns (uint256) {
        // Calculate required mints for max bonus (25 points)
        uint256 requiredForMax;

        if (currLevel <= 25) {
            // Early game: 1:1 ratio, need 25 mints for max
            requiredForMax = 25;
        } else if (currLevel <= 100) {
            // Mid game: scale up to 50 mints needed by level 100
            // Linear progression: 25 at level 25, 50 at level 100
            requiredForMax = 25 + ((uint256(currLevel) - 25) / 3);
        } else {
            // Late game: cap at 75 mints to keep it achievable
            // Players need to have minted on 75 different levels for max bonus
            requiredForMax = 75;
        }

        // Calculate bonus points: linear scale from 0 to 25
        uint256 points = (uint256(mintCount) * 25) / requiredForMax;
        return points > 25 ? 25 : points;
    }

    /*+======================================================================+
      |                       MINT RECORDING                                 |
      +======================================================================+
      |  Functions called by the gamepiece contract to record mints and process    |
      |  payments. ETH and claimable winnings can both fund purchases.       |
      +======================================================================+*/

    /// @notice Record a mint, funded by ETH or claimable winnings.
    /// @dev Access: nft contract only.
    ///      Payment modes:
    ///      - DirectEth: msg.value must exactly equal costWei
    ///      - Claimable: deduct from claimableWinnings (msg.value must be 0)
    ///      - Combined: ETH first, then claimable for remainder
    ///
    ///      SECURITY: Validates exact payment amounts to prevent over/underpayment.
    ///      Prize contribution flows to nextPrizePool for jackpot distribution.
    ///
    /// @param player The player address to record mint for.
    /// @param lvl The level at which mint is occurring.
    /// @param costWei Total cost in wei for this mint.
    /// @param mintUnits Number of mint units purchased.
    /// @param payKind Payment method (DirectEth, Claimable, or Combined).
    /// @return coinReward BURNIE reward credited for this mint.
    /// @return newClaimableBalance Player's claimable balance after deduction (0 if DirectEth).
    function recordMint(
        address player,
        uint24 lvl,
        uint256 costWei,
        uint32 mintUnits,
        MintPaymentKind payKind
    ) external payable returns (uint256 coinReward, uint256 newClaimableBalance) {
        if (msg.sender != ContractAddresses.GAMEPIECES) revert E();
        uint256 prizeContribution;
        (prizeContribution, newClaimableBalance) = _processMintPayment(player, costWei, payKind);
        if (prizeContribution != 0) {
            nextPrizePool += prizeContribution;
        }

        coinReward = _recordMintDataModule(player, lvl, mintUnits);
    }

    /// @notice Queue reward mints and prize funding for a future level.
    /// @dev Access: ContractAddresses.ADMIN or this contract (delegatecall modules).
    ///      Pool funding is accounting-only; caller is responsible for debiting source pools.
    /// @param player Recipient of future reward mints.
    /// @param targetLevel Level at which the queued mints should activate.
    /// @param quantity Number of reward mints to queue (0 allowed).
    /// @param poolWei Amount to reserve in futurePrizePool for the target level.
    function queueFutureRewardMints(
        address player,
        uint24 targetLevel,
        uint32 quantity,
        uint256 poolWei
    ) external {
        if (msg.sender != ContractAddresses.ADMIN && msg.sender != address(this)) revert E();
        _queueFutureRewardMints(player, targetLevel, quantity, poolWei);
    }

    function _queueFutureRewardMints(
        address player,
        uint24 targetLevel,
        uint32 quantity,
        uint256 poolWei
    ) private {
        if (targetLevel <= level) revert E();
        if (quantity != 0 && player == address(0)) revert E();

        if (poolWei != 0) {
            futurePrizePool[targetLevel] += poolWei;
            futurePrizePoolTotal += poolWei;
        }

        if (quantity == 0) return;

        uint32 owed = futureMintsOwed[targetLevel][player];
        if (owed == 0) {
            futureMintQueue[targetLevel].push(player);
        }
        futureMintsOwed[targetLevel][player] = owed + quantity;
    }

    /// @notice Track coinflip deposits for prize pool tuning on last purchase day.
    /// @dev Access: coin contract only.
    ///      Coinflip activity on last purchase day affects jackpot calculations.
    /// @param amount The wei amount deposited to coinflip.
    function recordCoinflipDeposit(uint256 amount) external {
        if (msg.sender != ContractAddresses.COIN) revert E();
        if (gameState == GAME_STATE_PURCHASE && lastPurchaseDay) {
            lastPurchaseDayFlipTotal += amount;
        }
    }

    /*+======================================================================+
      |                       LOOT BOX CONTROLS                             |
      +======================================================================+*/

    /// @notice Start loot box presale mode (2x BURNIE rewards + bonusFlip active).
    /// @dev Access: ContractAddresses.ADMIN only. Can only be started once (one-way toggle).
    function startLootboxPresale() external {
        if (msg.sender != ContractAddresses.ADMIN) revert E();
        if (lootboxPresaleActive) revert E();
        if (lootboxPresaleEnded) revert E(); // Cannot restart after ending

        lootboxPresaleActive = true;
        emit LootBoxPresaleStatus(true);
    }

    /// @notice End loot box presale mode (one-way: cannot be re-enabled).
    /// @dev Access: ContractAddresses.ADMIN only.
    function endLootboxPresale() external {
        if (msg.sender != ContractAddresses.ADMIN) revert E();
        if (!lootboxPresaleActive) revert E();

        lootboxPresaleActive = false;
        lootboxPresaleEnded = true; // Mark as permanently ended
        emit LootBoxPresaleStatus(false);
    }

    /// @notice Start the normal purchase phase.
    /// @dev Access: ContractAddresses.ADMIN only. Must be in SETUP state.
    function startPurchasing() external {
        if (msg.sender != ContractAddresses.ADMIN) revert E();
        if (gameState != GAME_STATE_SETUP) revert E();

        gameState = GAME_STATE_PURCHASE;
        levelStartTime = uint48(block.timestamp);
        lastPurchaseDay = false;
        levelJackpotPaid = false;
    }

    /// @notice Purchase any combination of gamepieces, MAPs, and loot boxes with ETH or claimable.
    /// @dev Main entry point for all ETH/claimable purchases. For BURNIE purchases, use DegenerusGamepieces.purchase().
    ///      Spending all claimable winnings earns a 10% bonus across the combined purchase.
    ///      Adds affiliate support for loot box purchases.
    ///      SECURITY: Blocked when RNG is locked.
    /// @param gamepieceQuantity Number of gamepieces to purchase (0 to skip).
    /// @param mapQuantity Number of MAP tickets to purchase (0 to skip).
    /// @param lootBoxAmount ETH amount for loot boxes, minimum 0.01 ETH (0 to skip).
    /// @param affiliateCode Affiliate/referral code for all purchases.
    /// @param payKind Payment method (DirectEth, Claimable, or Combined).
    function purchase(
        uint256 gamepieceQuantity,
        uint256 mapQuantity,
        uint256 lootBoxAmount,
        bytes32 affiliateCode,
        MintPaymentKind payKind
    ) external payable {
        if (rngLockedFlag) revert RngNotReady();

        address buyer = msg.sender;
        uint24 currentLevel = level;
        uint8 currentState = gameState;
        uint256 priceWei = price;

        // Validate loot box amount (must be at least minimum)
        if (lootBoxAmount != 0 && lootBoxAmount < LOOTBOX_MIN) revert E();

        // Calculate total cost
        uint256 gamepieceCost = 0;
        uint256 mapCost = 0;

        if (gamepieceQuantity > 0) {
            if (gamepieceQuantity > type(uint32).max) revert E();
            gamepieceCost = priceWei * gamepieceQuantity;
        }

        if (mapQuantity > 0) {
            if (mapQuantity > type(uint32).max) revert E();
            mapCost = (priceWei * mapQuantity) / 4; // MAPs cost 1/4 of gamepiece price
        }

        uint256 totalCost = gamepieceCost + mapCost + lootBoxAmount;
        if (totalCost == 0) revert E(); // Must purchase something

        // Track initial claimable balance for full-spend bonus detection
        uint256 initialClaimable = claimableWinnings[buyer];

        // Calculate how much ETH to allocate to each purchase type
        uint256 ethForGamepieces = 0;
        uint256 ethForMaps = 0;

        // Loot boxes always paid with ETH, deduct from total first
        uint256 remainingEth = msg.value;
        if (remainingEth < lootBoxAmount) revert E();
        unchecked {
            remainingEth -= lootBoxAmount;
        }

        // Allocate remaining ETH to gamepieces and MAPs proportionally
        if (remainingEth > 0 && (gamepieceCost + mapCost) > 0) {
            ethForGamepieces = (remainingEth * gamepieceCost) / (gamepieceCost + mapCost);
            ethForMaps = remainingEth - ethForGamepieces;
        }

        // Execute gamepiece purchases if requested
        if (gamepieceCost > 0 && gamepieceQuantity > 0) {
            // Build PurchaseParams struct and call
            (bool success, ) = ContractAddresses.GAMEPIECES.call{value: ethForGamepieces}(
                abi.encodeWithSignature(
                    "purchase((uint256,uint8,uint8,bool,bytes32))",
                    gamepieceQuantity,
                    uint8(0), // PurchaseKind.Player
                    uint8(payKind),
                    false, // payInCoin
                    affiliateCode
                )
            );
            if (!success) revert E();
        }

        // Execute MAP purchases if requested
        if (mapCost > 0 && mapQuantity > 0) {
            // Build PurchaseParams struct and call
            (bool success, ) = ContractAddresses.GAMEPIECES.call{value: ethForMaps}(
                abi.encodeWithSignature(
                    "purchase((uint256,uint8,uint8,bool,bytes32))",
                    mapQuantity,
                    uint8(1), // PurchaseKind.Map
                    uint8(payKind),
                    false, // payInCoin
                    affiliateCode
                )
            );
            if (!success) revert E();
        }

        // Execute loot box purchase
        if (lootBoxAmount > 0) {
            uint48 day = _currentDayIndex();
            bool presale = lootboxPresaleActive;

            // Record this as an ETH mint for daily gate eligibility
            _recordLootboxMintDay(buyer, uint32(day));

            uint256 existing = lootboxEth[day][buyer];
            if (existing != 0 && lootboxPresale[day][buyer] != presale) revert E();

            if (existing == 0) {
                // Target level will be rolled at opening time, not locked at purchase
                if (presale) {
                    lootboxPresale[day][buyer] = true;
                }
            }
            lootboxEth[day][buyer] = existing + lootBoxAmount;

            // Split loot box ETH into pools
            uint256 futureBps = presale ? LOOTBOX_PRESALE_SPLIT_FUTURE_BPS : LOOTBOX_SPLIT_FUTURE_BPS;
            uint256 nextBps = presale ? LOOTBOX_PRESALE_SPLIT_NEXT_BPS : LOOTBOX_SPLIT_NEXT_BPS;
            uint256 vaultBps = presale ? LOOTBOX_PRESALE_SPLIT_VAULT_BPS : 0;

            uint256 futureShare = (lootBoxAmount * futureBps) / 10_000;
            uint256 nextShare = (lootBoxAmount * nextBps) / 10_000;
            uint256 vaultShare = (lootBoxAmount * vaultBps) / 10_000;
            uint256 rewardShare;
            unchecked {
                rewardShare = lootBoxAmount - futureShare - nextShare - vaultShare;
            }

            if (futureShare != 0) {
                // Hold in reserve pool until opening, when target level is rolled
                lootboxReservePool += futureShare;
            }
            if (nextShare != 0) {
                nextPrizePool += nextShare;
            }
            if (vaultShare != 0) {
                (bool ok, ) = payable(ContractAddresses.VAULT).call{value: vaultShare}("");
                if (!ok) revert E();
            }
            if (rewardShare != 0) {
                rewardPool += rewardShare;
            }

            // Add affiliate support for loot box purchases
            if (affiliateCode != bytes32(0)) {
                uint256 affiliateAmount = _calculateLootboxAffiliateAmount(currentLevel, currentState, lootBoxAmount, priceWei);
                affiliate.payAffiliate(affiliateAmount, affiliateCode, buyer, currentLevel);
            }

            emit LootBoxPurchased(buyer, day, lootBoxAmount, presale, futureShare, nextShare, vaultShare, rewardShare);

            // Notify quest module of loot box purchase
            coin.notifyQuestLootBox(buyer, lootBoxAmount);
        }

        // Check if player spent all claimable across all purchases
        uint256 finalClaimable = claimableWinnings[buyer];
        uint256 totalClaimableUsed = initialClaimable > finalClaimable ? initialClaimable - finalClaimable : 0;
        bool spentAllClaimable = (finalClaimable <= 1 && totalClaimableUsed > 0);

        // Apply combined full-spend bonus if player spent all claimable (minimum 3 gamepiece-equivalents)
        if (spentAllClaimable && totalClaimableUsed >= priceWei * 3) {
            // Award 10% bonus on total claimable spent as BURNIE
            uint256 bonusAmount = (totalClaimableUsed * PRICE_COIN_UNIT * 10) / (priceWei * 100);
            if (bonusAmount > 0) {
                coin.creditFlip(buyer, bonusAmount);
            }
        }
    }

    /// @dev Calculate affiliate amount for loot box purchases.
    /// @param lvl Current game level.
    /// @param gameState Current game state.
    /// @param lootBoxAmount Loot box purchase amount in wei.
    /// @param priceWei Current gamepiece price.
    /// @return Affiliate reward amount.
    function _calculateLootboxAffiliateAmount(
        uint24 lvl,
        uint8 gameState,
        uint256 lootBoxAmount,
        uint256 priceWei
    ) private pure returns (uint256) {
        // Calculate loot box purchase as gamepiece-equivalents
        // Loot boxes have ~110-150% EV, so use a conservative 50% affiliate rate of a gamepiece
        uint256 gamepieceEquivalent = lootBoxAmount / priceWei;
        if (gamepieceEquivalent == 0) return 0;

        // Use similar logic to gamepiece affiliate rewards but at 50% rate
        uint256 baseAmount;
        if (lvl > 40) {
            uint256 pct = gameState != 3 ? 30 : 5;
            baseAmount = (PRICE_COIN_UNIT * pct) / 100;
        } else {
            baseAmount = PRICE_COIN_UNIT / 10;
            if (lvl <= 3 || gameState != 3) {
                baseAmount = (baseAmount * 250) / 100;
            }
        }

        // Apply 50% rate for loot boxes and scale by equivalent gamepieces
        return (baseAmount * gamepieceEquivalent) / 2;
    }

    /// @notice Open a loot box from a previous day once next-day RNG is available.
    /// @param day Day index when the loot box was purchased.
    function openLootBox(uint48 day) external {
        uint256 amount = lootboxEth[day][msg.sender];
        if (amount == 0) revert E();

        uint48 rngDay = day + 1;
        uint256 rngWord = rngWordByDay[rngDay];
        if (rngWord == 0) revert RngNotReady();

        lootboxEth[day][msg.sender] = 0;
        bool presale = lootboxPresale[day][msg.sender];
        if (presale) {
            lootboxPresale[day][msg.sender] = false;
        }

        uint256 entropy = uint256(keccak256(abi.encode(rngWord, msg.sender, day, amount)));

        // Roll target level: current level + 0 to 5 (6 possibilities)
        uint24 currentLevel = level;
        uint256 levelOffset = entropy % 6;
        uint24 targetLevel = currentLevel + uint24(levelOffset);

        // Calculate price for the rolled target level
        uint256 targetPrice = _priceForLevel(targetLevel);
        if (targetPrice == 0) revert E();

        // Transfer the future prize pool share from reserve to the rolled target level
        // Recalculate the futureShare using the same formula as purchase
        uint256 futureBps = presale ? LOOTBOX_PRESALE_SPLIT_FUTURE_BPS : LOOTBOX_SPLIT_FUTURE_BPS;
        uint256 futureShare = (amount * futureBps) / 10_000;
        if (futureShare != 0) {
            lootboxReservePool -= futureShare;
            _queueFutureRewardMints(address(0), targetLevel, 0, futureShare);
        }

        uint256 amountFirst = amount;
        uint256 amountSecond = 0;
        if (amount > LOOTBOX_SPLIT_THRESHOLD) {
            amountFirst = amount / 2;
            amountSecond = amount - amountFirst;
        }

        uint256 burniePresale; // BURNIE eligible for 2x multiplier
        uint256 burnieNoMultiplier; // BURNIE from ticket conversions (no multiplier)
        uint32 futureTickets;
        (uint256 burnieOut, uint32 ticketsOut, uint256 nextEntropy, bool applyMultiplier) =
            _resolveLootboxRoll(msg.sender, amountFirst, targetLevel, targetPrice, entropy, presale);
        if (burnieOut != 0) {
            if (applyMultiplier) {
                burniePresale += burnieOut;
            } else {
                burnieNoMultiplier += burnieOut;
            }
        }
        if (ticketsOut != 0) {
            uint256 totalTickets = uint256(futureTickets) + ticketsOut;
            if (totalTickets > type(uint32).max) revert E();
            futureTickets = uint32(totalTickets);
        }
        entropy = nextEntropy;

        if (amountSecond != 0) {
            (burnieOut, ticketsOut, nextEntropy, applyMultiplier) =
                _resolveLootboxRoll(msg.sender, amountSecond, targetLevel, targetPrice, entropy, presale);
            if (burnieOut != 0) {
                if (applyMultiplier) {
                    burniePresale += burnieOut;
                } else {
                    burnieNoMultiplier += burnieOut;
                }
            }
            if (ticketsOut != 0) {
                uint256 totalTickets = uint256(futureTickets) + ticketsOut;
                if (totalTickets > type(uint32).max) revert E();
                futureTickets = uint32(totalTickets);
            }
            entropy = nextEntropy;
        }

        // Presale loot boxes give 2x BURNIE rewards (only for actual BURNIE rolls, not conversions)
        uint256 burnieAmount = burnieNoMultiplier;
        if (presale && burniePresale != 0) {
            burnieAmount += burniePresale * 2;
        } else {
            burnieAmount += burniePresale;
        }

        if (burnieAmount != 0) {
            coin.creditFlip(msg.sender, burnieAmount);
        }

        emit LootBoxOpened(
            msg.sender,
            day,
            amount,
            targetLevel,
            futureTickets,
            0,
            burnieAmount,
            0
        );
    }

    /// @dev Process mint payment and return amount contributed to prize pool.
    ///      Handles three payment modes with strict validation:
    ///
    ///      DirectEth: msg.value must exactly match amount
    ///      Claimable: msg.value must be 0, deduct from claimableWinnings
    ///      Combined: ETH first (any amount ≤ cost), then claimable for rest
    ///
    ///      SECURITY: Leaves 1 wei sentinel in claimable to prevent zeroing.
    ///      INVARIANT: claimablePool is decremented by claimableUsed.
    ///
    /// @param player Player whose claimable balance to check/deduct.
    /// @param amount Total cost in wei to cover.
    /// @param payKind Payment method enum.
    /// @return prizeContribution Amount flowing to nextPrizePool.
    /// @return newClaimableBalance Player's claimable balance after deduction (0 if DirectEth).
    function _processMintPayment(
        address player,
        uint256 amount,
        MintPaymentKind payKind
    ) private returns (uint256 prizeContribution, uint256 newClaimableBalance) {
        uint256 claimableUsed;
        if (payKind == MintPaymentKind.DirectEth) {
            // Direct ETH: exact match required
            if (msg.value != amount) revert E();
            prizeContribution = amount;
            // newClaimableBalance stays 0 (caller checks claimableUsed first)
        } else if (payKind == MintPaymentKind.Claimable) {
            // Pure claimable: no ETH allowed, must have sufficient balance
            if (msg.value != 0) revert E();
            uint256 claimable = claimableWinnings[player];
            // Require claimable > amount to preserve 1 wei sentinel (prevents cold→warm SSTORE)
            if (claimable <= amount) revert E();
            unchecked {
                newClaimableBalance = claimable - amount;
            }
            claimableWinnings[player] = newClaimableBalance;
            claimableUsed = amount;
            prizeContribution = amount;
        } else if (payKind == MintPaymentKind.Combined) {
            // Combined: ETH first, then fill remainder from claimable
            if (msg.value > amount) revert E();
            uint256 remaining = amount - msg.value;
            if (remaining != 0) {
                uint256 claimable = claimableWinnings[player];
                if (claimable > 1) {
                    uint256 available = claimable - 1; // Preserve 1 wei sentinel
                    claimableUsed = remaining < available ? remaining : available;
                    if (claimableUsed != 0) {
                        unchecked {
                            newClaimableBalance = claimable - claimableUsed;
                        }
                        claimableWinnings[player] = newClaimableBalance;
                        remaining -= claimableUsed;
                    }
                }
            }
            if (remaining != 0) revert E(); // Must fully cover cost
            prizeContribution = msg.value + claimableUsed;
        } else {
            revert E();
        }
        // Update claimablePool accounting
        if (claimableUsed != 0) {
            claimablePool -= claimableUsed;
        }
    }

    /*+========================================================================================+
      |                    CORE STATE MACHINE: advanceGame()                                   |
      +========================================================================================+
      |  The heart of the game. This function progresses the state machine                     |
      |  through its 3 states: SETUP(1), PURCHASE(2), DEGENERUS(3).                            |
      |  Each call performs one "tick" of work. GAMEOVER(86) is terminal.                      |
      |                                                                                        |
      |  State Transitions:                                                                    |
      |  • State 1 (SETUP): Run endgame settlement, then → 2                                   |
      |  • State 2 (PURCHASE): Process airdrops until target met, then → 3                     |
      |  • State 3 (DEGENERUS): Pay daily ContractAddresses.JACKPOTS, wait for burns, then → 1 |
      |  • State 86 (GAMEOVER): Terminal state, no transitions                                 |
      |                                                                                        |
      |  Gating:                                                                               |
      |  • Standard calls require caller to have minted today (skin-in-game)                   |
      |  • cap != 0 bypasses gate but forfeits BURNIE reward                                   |
      |  • RNG must be ready (not locked) or recently stale (18h timeout)                      |
      |                                                                                        |
      |  Presale: lootboxPresaleActive toggle (orthogonal to state machine)                    |
      |  • When true: 2x BURNIE from loot boxes, bonusFlip active                              |
      |  • Creator can end presale (one-way, cannot re-enable)                                 |
      +========================================================================================+*/

    /// @notice Advance the game state machine by one tick.
    /// @dev Anyone can call, but standard flows require an ETH mint today.
    ///      This is the primary driver of game progression - called repeatedly
    ///      to move through states and process batched operations.
    ///
    ///      FLOW OVERVIEW:
    ///      1. Check liveness guards (2.5yr deploy timeout, 365-day inactivity)
    ///      2. Apply daily gate (must have minted today unless cap != 0)
    ///      3. Process dormant cleanup if in setup state
    ///      4. Gate on RNG readiness (request new VRF if needed)
    ///      5. Process map mint batches
    ///      6. Execute state-specific logic (setup/purchase/degenerus)
    ///      7. Credit caller with BURNIE reward (if cap == 0)
    ///
    ///      SECURITY:
    ///      - Liveness guards prevent abandoned game lockup
    ///      - Daily gate prevents non-participants from advancing
    ///      - RNG gating ensures fairness (no manipulation during VRF window)
    ///      - Batched processing prevents DoS from large queues
    ///
    /// @param cap Gas budget override for batched operations.
    ///            0 = standard flow with BURNIE reward.
    ///            >0 = emergency unstuck mode (no BURNIE reward).
    function advanceGame(uint32 cap) external {
        address caller = msg.sender;
        uint48 ts = uint48(block.timestamp);
        // Day index is relative to deploy time (day 1 = deploy day).
        uint48 day = _currentDayIndex();
        IDegenerusCoin coinContract = coin;
        uint48 lst = levelStartTime;
        bool gameOver;
        uint8 _gameState = gameState;
        uint24 lvl = level;

        // === GAMEOVER CHECK ===
        if (_gameState == GAME_STATE_GAMEOVER) {
            // Check for final sweep (1 month after gameover)
            _gameOverFinalSweep();
            return;
        }

        // === LIVENESS GUARDS ===
        // Prevent permanent lockup if game is abandoned
        if (lvl == 1 && uint256(ts) >= uint256(lst) + DEPLOY_IDLE_TIMEOUT) {
            // Still at level 1 after 2.5 years - game abandoned
            gameOver = true;
        } else if (ts - 365 days > lst && _gameState != GAME_STATE_GAMEOVER) {
            // Game inactive for 365 days - trigger game over
            gameOver = true;
        }
        if (gameOver) {
            if (rngWordByDay[dailyIdx] == 0) {
                bool lastPurchaseFlag = (_gameState == GAME_STATE_PURCHASE) && lastPurchaseDay;
                uint256 rngWord = _gameOverEntropy(day, lvl, lastPurchaseFlag);
                if (rngWord == 1 || rngWord == 0) return;
                _unlockRng(day);
            }
            // Sweep all funds to the vault for final distribution
            gameOverDrainToVault(dailyIdx);
            return;
        }

        bool lastPurchase = (_gameState == GAME_STATE_PURCHASE) && lastPurchaseDay;

        // Single-iteration do-while pattern allows structured breaks for early exit
        do {
            // === DAILY GATE ===
            // Standard flow requires caller to have minted today (prevents gaming by non-participants)
            // Skip for CREATOR address to allow maintenance advances
            if (cap == 0 && caller != ContractAddresses.CREATOR) {
                uint32 gateIdx = uint32(dailyIdx);
                if (gateIdx != 0) {
                    uint256 mintData = mintPacked_[caller];
                    uint32 lastEthDay = uint32((mintData >> ETH_DAY_SHIFT) & MINT_MASK_32);
                    // Allow mints from current day or previous day
                    if (lastEthDay + 1 < gateIdx) revert MustMintToday();
                }
            }

            // === DORMANT CLEANUP (State 1 only) ===
            // Allow dormant cleanup bounty even before the daily gate unlocks. If no work is done,
            // we continue to normal gating and will revert via rngAndTimeGate when not time yet.
            if (_gameState == GAME_STATE_SETUP) {
                bool dormantWorked = nft.processDormant(cap);
                if (dormantWorked) {
                    break; // Work done - exit this tick
                }
            }

            // === RNG GATING ===
            // Either use existing VRF word or request new one. Returns 1 if request just made.
            uint256 rngWord = rngAndTimeGate(day, lvl, lastPurchase);
            if (rngWord == 1) {
                break; // VRF requested - must wait for fulfillment
            }

            // === FUTURE MINT ACTIVATION (State 2 only) ===
            // Process queued future mints before other purchase-phase work.
            if (_gameState == GAME_STATE_PURCHASE) {
                (bool futureWorked, bool futureFinished) = _processFutureMintBatch(cap, lvl);
                if (futureWorked || !futureFinished) break;
            }

            // === MAP BATCH PROCESSING ===
            // Always run a map batch upfront; it no-ops when nothing is queued.
            // Single batch per call prevents gas exhaustion.
            (bool batchWorked, bool batchesFinished) = _runProcessMapBatch(cap);
            if (batchWorked || !batchesFinished) break;

            // +================================================================+
            // |                    STATE 1: SETUP                              |
            // |  Endgame settlement phase after level completion.              |
            // |  • Open decimator window at specific level positions           |
            // |  • Run endgame module (payouts, wipes, ContractAddresses.JACKPOTS)               |
            // |  • Pay carryover extermination jackpot if applicable           |
            // |  • Transition to State 2                                       |
            // +================================================================+
            if (_gameState == GAME_STATE_SETUP) {
                // Decimator window opens at level 5, levels ending in 5 (except 95), and at level 99
                bool decOpen = (lvl == 5) || ((lvl >= 25) && ((lvl % 10) == 5) && ((lvl % 100) != 95));
                // Preserve an already-open window for the level-100 decimator special until its RNG request closes it.
                if (!decWindowOpen && decOpen) {
                    decWindowOpen = true;
                }
                if (lvl % 100 == 99) decWindowOpen = true;

                // Endgame module handles: payouts, wipes, endgame dist, and jackpots
                _runEndgameModule(lvl, rngWord);

                // Pay carryover jackpot for the trait that was exterminated last level
                if (lastExterminatedTrait != TRAIT_ID_TIMEOUT) {
                    payCarryoverExterminationJackpot(lvl, uint8(lastExterminatedTrait), rngWord);
                }

                break;
            }

            // +================================================================+
            // |                    STATE 2: PURCHASE / AIRDROP                 |
            // |  Mint phase where players purchase gamepieces and receive airdrops.  |
            // |  • Pay daily jackpot until prize pool target is met            |
            // |  • Pay level jackpot once target is met                        |
            // |  • Process pending mint batches                                |
            // |  • Rebuild trait counts for new level                          |
            // |  • Transition to State 3 when all processing complete          |
            // +================================================================+
            if (_gameState == GAME_STATE_PURCHASE) {
                if (mapJackpotType != MAP_JACKPOT_NONE) {
                    payMapJackpot(lvl, rngWord);
                    _unlockRng(day);
                    break;
                }
                // --- Pre-target: daily ContractAddresses.JACKPOTS while building up prize pool ---
                if (!lastPurchaseDay) {
                    payDailyJackpot(false, lvl, rngWord);
                    _payFutureTicketJackpot(lvl, rngWord); // Award future ticket holders
                    // Check if prize pool target is now met
                    if (nextPrizePool >= lastPrizePool) {
                        lastPurchaseDay = true;
                        lastPurchaseDayFlipTotal = 0;
                    }
                    if (mapJackpotType != MAP_JACKPOT_NONE) {
                        break; // MAP jackpot queued, will process next tick
                    }
                    _unlockRng(day);
                    break;
                }

                // --- Target met: pay level jackpot ---
                if (!levelJackpotPaid) {
                    // Level 100 multiples get special decimator/BAF jackpot
                    if (lvl % 100 == 0) {
                        if (!_runDecimatorHundredJackpot(lvl, rngWord)) {
                            break; // Keep working this jackpot slice before moving on
                        }
                    }

                    // Calculate and pay level jackpot
                    uint256 levelJackpotWei = _calcPrizePoolForLevelJackpot(lvl, rngWord);
                    payLevelJackpot(lvl, rngWord, levelJackpotWei);
                    levelJackpotPaid = true;

                    // Reset airdrop processing state
                    airdropMapsProcessedCount = 0;
                    if (airdropIndex >= pendingMapMints.length) {
                        airdropIndex = 0;
                        delete pendingMapMints;
                    }
                    break;
                }

                // --- Process pending gamepiece mints ---
                (uint32 purchaseCountPre, uint32 purchaseCountPhase) = nft.purchaseCounts();
                uint256 purchaseCountTotal = uint256(purchaseCountPre) + uint256(purchaseCountPhase);
                if (purchaseCountTotal > type(uint32).max) revert E();
                uint32 purchaseCountRaw = uint32(purchaseCountTotal);
                if (airdropMultiplier == 0) {
                    airdropMultiplier = _calculateAirdropMultiplierModule(purchaseCountPre, purchaseCountPhase, lvl);
                }
                if (!traitCountsSeedQueued) {
                    uint32 multiplier_ = airdropMultiplier;
                    if (!nft.processPendingMints(cap, multiplier_, rngWord)) {
                        break; // More mints to process
                    }
                    if (purchaseCountRaw != 0) {
                        traitCountsSeedQueued = true;
                        traitRebuildCursor = 0;
                    }
                }

                // --- Rebuild trait counts for new level ---
                if (traitCountsSeedQueued) {
                    uint32 targetCount = _purchaseTargetCountFromRawModule(purchaseCountPre, purchaseCountPhase);
                    if (traitRebuildCursor < targetCount) {
                        uint256 baseTokenId = nft.currentBaseTokenId();
                        _rebuildTraitCountsModule(cap, targetCount, baseTokenId);
                        break; // More trait counts to rebuild
                    }
                    _seedTraitCounts(); // Copy traitRemaining to traitStartRemaining
                    traitCountsSeedQueued = false;
                }

                // --- Transition to State 3 (DEGENERUS) ---
                traitRebuildCursor = 0;
                airdropMultiplier = 0;
                earlyBurnPercent = 0;
                gameState = GAME_STATE_BURN;
                levelJackpotPaid = false;
                lastPurchaseDay = false;
                if (lvl % 100 == 99) decWindowOpen = true;
                _unlockRng(day); // Open RNG after level jackpot is finalized
                break;
            }

            // +================================================================+
            // |                    STATE 3: DEGENERUS (BURN)                   |
            // |  Active burn phase where players burn gamepieces for jackpot tickets.|
            // |  • Pay daily jackpot each day                                  |
            // |  • Level ends via trait extermination OR jackpot cap (10 days) |
            // |  • Transition to State 1 on level end                          |
            // +================================================================+
            if (_gameState == GAME_STATE_BURN) {
                if (mapJackpotType != MAP_JACKPOT_NONE) {
                    payMapJackpot(lvl, rngWord);
                    // Check timeout on-the-fly (jackpotCounter was incremented before pending was set)
                    if (jackpotCounter >= JACKPOT_LEVEL_CAP) {
                        _endLevel(TRAIT_ID_TIMEOUT);
                        break;
                    }
                    _unlockRng(day);
                    break;
                }

                payDailyJackpot(true, lvl, rngWord);
                _payFutureTicketJackpot(lvl, rngWord); // Award future ticket holders
                if (mapJackpotType != MAP_JACKPOT_NONE) {
                    break; // MAP jackpot queued, will process next tick
                }
                // Check for timeout end (10 ContractAddresses.JACKPOTS paid without extermination)
                if (jackpotCounter >= JACKPOT_LEVEL_CAP) {
                    _endLevel(TRAIT_ID_TIMEOUT); // Force level end
                    break;
                }
                _unlockRng(day);
                break;
            }
        } while (false);

        // Emit state change event for indexers
        emit Advance(gameState);

        // Credit caller with BURNIE reward for advancing (skip emergency cap mode)
        if (cap == 0) {
            coinContract.creditFlip(caller, PRICE_COIN_UNIT >> 1);
        }
    }

    /*+======================================================================+
      |                       MAP MINT QUEUEING                              |
      +======================================================================+
      |  Maps are queued for batch processing rather than minted immediately.|
      |  This prevents gas exhaustion from large purchases.                  |
      +======================================================================+*/

    /// @notice Queue map mints owed after gamepiece-side processing.
    /// @dev Access: nft contract only.
    ///      Maps are processed in batches during advanceGame to prevent DoS.
    ///      If player already has maps owed, they're not re-added to pendingMapMints array.
    /// @param buyer Player to credit maps to.
    /// @param quantity Number of map entries to queue (1+).
    function enqueueMap(address buyer, uint32 quantity) external {
        if (msg.sender != ContractAddresses.GAMEPIECES) revert E();

        // Only add to pending array if player doesn't already have maps queued
        if (playerMapMintsOwed[buyer] == 0) {
            pendingMapMints.push(buyer);
        }

        unchecked {
            playerMapMintsOwed[buyer] += quantity;
        }
    }

    /*+======================================================================+
      |                       gamepiece BURNING (DEGENERUS)                        |
      +======================================================================+
      |  Players burn gamepieces to earn jackpot tickets and potentially trigger   |
      |  trait extermination, ending the current level.                      |
      |                                                                      |
      |  Each burned token:                                                  |
      |  • Adds 4 tickets (one per trait) to the trait burn ticket pools     |
      |  • Decrements each trait's remaining count                           |
      |  • May trigger extermination if a trait count hits 0 (or 1 on L%10=7)|
      |  • Awards bonus BURNIE for matching colors or carrying prev trait    |
      |                                                                      |
      |  SECURITY:                                                           |
      |  • RNG must not be locked (prevents manipulation during VRF window)  |
      |  • Can only burn in State 3 (DEGENERUS)                              |
      |  • Max 75 tokens per call (gas limit protection)                     |
      +======================================================================+*/

    /// @notice Burn gamepieces for jackpot tickets, potentially ending the level.
    /// @dev Access: any player during State 3 (DEGENERUS) when RNG is not locked.
    ///
    ///      For each token burned:
    ///      1. Extract 4 traits from token ID (deterministic hash)
    ///      2. Add ticket to each trait's burn pool for this level
    ///      3. Decrement trait remaining counts
    ///      4. Check for extermination (trait count hits threshold)
    ///      5. Track daily burn counts for jackpot calculations
    ///      6. Award bonus BURNIE for matching colors / carrying prev trait
    ///
    ///      BONUSES:
    ///      • +4.9x BURNIE if all 4 traits share the same color category
    ///      • +0.4x BURNIE if token has previous exterminated trait (or inverse on L90)
    ///      • 2x ticket count on L%10=2 (double count step)
    ///
    ///      EXTERMINATION:
    ///      • Normally triggered when trait count = 0
    ///      • On L%10=7, triggered when trait count = 1 (early end)
    ///      • First token to trigger wins; remaining tokens skip
    ///
    /// @param tokenIds Array of token IDs to burn (1-75 tokens).
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
        bool isDoubleCountStep = mod10 == 2;
        bool levelNinety = (lvl == 90);
        uint32 endLevelFlag = mod10 == 7 ? 1 : 0;
        uint16 prevExterminated = lastExterminatedTrait;
        bool hasPrevExterminated = prevExterminated != TRAIT_ID_TIMEOUT;

        uint256 bonusTenths;

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

            bool tokenHasPrevExterminated = hasPrevExterminated &&
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
        _creditBurnFlip(caller, count, bonusTenths);
        emit Degenerus(caller, tokenIds);

        if (winningTrait != TRAIT_ID_TIMEOUT) {
            _endLevel(winningTrait);
            return;
        }
    }

    /*+========================================================================================+
      |                       LEVEL FINALIZATION                                               |
      +========================================================================================+
      |  Level ends occur either via trait extermination (player burns the                     |
      |  last token with a trait) or timeout (10 daily ContractAddresses.JACKPOTS paid).       |
      |                                                                                        |
      |  Extermination End (<256):                                                             |
      |  • Record exterminator address (trophy minted during settlement)                       |
      |  • Apply repeat-trait penalty if same trait as last level                              |
      |  • Preserve current prize pool for endgame settlement                                  |
      |  • Normalize active burn quests                                                        |
      |                                                                                        |
      |  Timeout End (TRAIT_ID_TIMEOUT):                                                       |
      |  • Clear current prize pool                                                            |
      |  • No exterminator recorded                                                            |
      |                                                                                        |
      |  Both Paths:                                                                           |
      |  • Transition to State 1 (SETUP)                                                       |
      |  • Reset per-level state (jackpot counter, trait cursor)                               |
      |  • Update price schedule at 100-level boundaries                                       |
      |  • Advance gamepiece base token ID                                                           |
      +========================================================================================+*/

    /// @notice Finalize the current level (extermination or timeout).
    /// @dev Called when:
    ///      1. A trait count hits 0 (or 1 on L%10=7) - EXTERMINATION
    ///      2. 10 daily ContractAddresses.JACKPOTS paid without extermination - TIMEOUT
    ///
    ///      EXTERMINATION PATH (exterminated < 256):
    ///      - Record exterminator (trophy minted during settlement)
    ///      - If repeat trait or level 90 special: keep 50% in reward pool
    ///      - Set exterminationInvertFlag for trait ticket jackpot
    ///      - Normalize burn quests (called on quest module)
    ///
    ///      TIMEOUT PATH (exterminated >= 256):
    ///      - Clear prize pool (carried forward to next level)
    ///      - No exterminator trophy
    ///
    ///      PRICE SCHEDULE (100-level cycle):
    ///      - L1-L10: 0.05 ETH
    ///      - L11-L30: 0.05 ETH
    ///      - L31-L80: 0.1 ETH
    ///      - L81-L99: 0.15 ETH
    ///      - L100: 0.25 ETH
    ///
    /// @param exterminated Trait ID (0-255) if exterminated, TRAIT_ID_TIMEOUT (420) if timeout.
    function _endLevel(uint16 exterminated) private {
        address callerExterminator = msg.sender;
        uint24 levelSnapshot = level;
        gameState = GAME_STATE_SETUP;
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

            lastExterminatedTrait = exTrait;
            questNormalize.normalizeActiveBurnQuests();
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
        uint8 jackpotCounterSnapshot = jackpotCounter;
        lastLevelJackpotCount = jackpotCounterSnapshot;
        jackpotCounter = 0;
        // Reset daily burn counters so the next level's ContractAddresses.JACKPOTS start fresh.
        if (jackpotCounterSnapshot < JACKPOT_LEVEL_CAP) {
            _clearDailyBurnCount();
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

        nft.advanceBase(); // let gamepiece pull its own nextTokenId to avoid redundant calls here
    }

    /*+================================================================================================================+
      |                    DELEGATE MODULE HELPERS                                                                     |
      +================================================================================================================+
      |  Internal functions that delegatecall into specialized modules.                                                |
      |  All modules MUST inherit DegenerusGameStorage for slot alignment.                                             |
      |                                                                                                                |
      |  Modules:                                                                                                      |
      |  • ContractAddresses.GAME_ENDGAME_MODULE  - Endgame settlement (payouts, wipes, ContractAddresses.JACKPOTS)    |
      |  • ContractAddresses.GAME_MINT_MODULE     - Mint data recording, airdrop multipliers                           |
      |  • ContractAddresses.GAME_JACKPOT_MODULE  - Jackpot calculations and payouts                                   |
      |                                                                                                                |
      |  SECURITY: delegatecall executes module code in this contract's                                                |
      |  context, with access to all storage. Modules are constant.                                                    |
      +================================================================================================================+*/

    /// @dev Delegatecall into the endgame module to resolve settlement paths.
    ///      Handles: payouts, wipes, endgame distribution, and ContractAddresses.JACKPOTS.
    /// @param lvl Current level snapshot.
    /// @param rngWord VRF random word for RNG-dependent operations.
    function _runEndgameModule(uint24 lvl, uint256 rngWord) internal {
        // Endgame settlement logic lives in DegenerusGameEndgameModule (delegatecall keeps state on this contract).
        (bool ok, bytes memory data) = ContractAddresses.GAME_ENDGAME_MODULE.delegatecall(
            abi.encodeWithSelector(IDegenerusGameEndgameModule.finalizeEndgame.selector, lvl, rngWord)
        );
        if (!ok) _revertDelegate(data);
    }

    /// @dev Bubble up revert reason from delegatecall failure.
    ///      Uses assembly to preserve original error data.
    /// @param reason The error bytes from failed delegatecall.
    function _revertDelegate(bytes memory reason) private pure {
        if (reason.length == 0) revert E();
        assembly ("memory-safe") {
            revert(add(32, reason), mload(reason))
        }
    }

    /// @dev Record mint data via mint module delegatecall.
    ///      Updates player's mint history and calculates BURNIE reward.
    /// @param player Player address being credited.
    /// @param lvl Level at which mint occurred.
    /// @param mintUnits Number of mint units purchased.
    /// @return coinReward BURNIE tokens to credit to player.
    function _recordMintDataModule(address player, uint24 lvl, uint32 mintUnits) private returns (uint256 coinReward) {
        (bool ok, bytes memory data) = ContractAddresses.GAME_MINT_MODULE.delegatecall(
            abi.encodeWithSelector(IDegenerusGameMintModule.recordMintData.selector, player, lvl, mintUnits)
        );
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint256));
    }

    /// @dev Calculate airdrop multiplier via mint module delegatecall.
    ///      Multiplier determines bonus gamepieces in airdrops.
    /// @param prePurchaseCount Raw count before purchase phase (eligible for multiplier).
    /// @param purchasePhaseCount Raw count during purchase phase (not multiplied).
    /// @param lvl Current level.
    /// @return Multiplier value for airdrop calculations.
    function _calculateAirdropMultiplierModule(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount,
        uint24 lvl
    ) private returns (uint32) {
        (bool ok, bytes memory data) = ContractAddresses.GAME_MINT_MODULE.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameMintModule.calculateAirdropMultiplier.selector,
                prePurchaseCount,
                purchasePhaseCount,
                lvl
            )
        );
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint32));
    }

    /// @dev Convert raw purchase count to target count via mint module.
    /// @param prePurchaseCount Raw count before purchase phase (eligible for multiplier).
    /// @param purchasePhaseCount Raw count during purchase phase (not multiplied).
    /// @return Target count for trait rebuild operations.
    function _purchaseTargetCountFromRawModule(
        uint32 prePurchaseCount,
        uint32 purchasePhaseCount
    ) private returns (uint32) {
        (bool ok, bytes memory data) = ContractAddresses.GAME_MINT_MODULE.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameMintModule.purchaseTargetCountFromRaw.selector,
                prePurchaseCount,
                purchasePhaseCount
            )
        );
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint32));
    }

    /// @dev Rebuild trait counts via mint module delegatecall.
    ///      Processes tokens in batches to avoid gas exhaustion.
    /// @param tokenBudget Maximum tokens to process this call.
    /// @param target Total tokens to process.
    /// @param baseTokenId Starting token ID for this level.
    function _rebuildTraitCountsModule(uint32 tokenBudget, uint32 target, uint256 baseTokenId) private {
        (bool ok, bytes memory data) = ContractAddresses.GAME_MINT_MODULE.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameMintModule.rebuildTraitCounts.selector,
                tokenBudget,
                target,
                baseTokenId
            )
        );
        if (!ok) _revertDelegate(data);
    }

    /*+========================================================================================+
      |                    DECIMATOR JACKPOT CREDITS                                           |
      +========================================================================================+
      |  Credits from decimator/BAF jackpot wins flow through these                            |
      |  functions. Called by the ContractAddresses.JACKPOTS contract.                         |
      +========================================================================================+*/

    /// @notice Credit a decimator jackpot claim into the game's claimable balance.
    /// @dev Access: ContractAddresses.JACKPOTS contract only.
    ///      Silently returns if amount=0 or account=address(0).
    /// @param account Player to credit.
    /// @param amount Wei amount associated with the claim.
    function creditDecJackpotClaim(address account, uint256 amount) external {
        if (msg.sender != ContractAddresses.JACKPOTS) revert E();
        if (amount == 0 || account == address(0)) return;
        _addClaimableEth(account, amount);
    }

    /// @notice Batch variant to aggregate decimator jackpot claim credits.
    /// @dev Access: ContractAddresses.JACKPOTS contract only.
    ///      Gas-optimized for multiple credits in single transaction.
    /// @param accounts Array of player addresses to credit.
    /// @param amounts Array of corresponding wei amounts.
    function creditDecJackpotClaimBatch(address[] calldata accounts, uint256[] calldata amounts) external {
        if (msg.sender != ContractAddresses.JACKPOTS) revert E();
        uint256 len = accounts.length;
        if (len != amounts.length) revert E();

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
    }

    /*+========================================================================================+
      |                    CLAIMING WINNINGS (ETH)                                             |
      +========================================================================================+
      |  Players claim accumulated winnings from ContractAddresses.JACKPOTS, affiliates,       |
      |  and endgame payouts through the claimWinnings() function.                              |
      |                                                                                        |
      |  SECURITY:                                                                             |
      |  • Uses CEI pattern (Checks-Effects-Interactions)                                      |
      |  • Leaves 1 wei sentinel for gas optimization on future credits                        |
      |  • Falls back to stETH if ETH balance insufficient                                     |
      |  • claimablePool is decremented before external call                                   |
      +========================================================================================+*/

    /// @notice Claim the caller's accrued ETH winnings.
    /// @dev Aggregates all winnings: affiliates, ContractAddresses.JACKPOTS, endgame payouts.
    ///      Uses pull pattern for security (CEI: check balance, update state, then transfer).
    ///
    ///      GAS OPTIMIZATION: Leaves 1 wei sentinel so subsequent credits remain
    ///      non-zero → cheaper SSTORE (cold→warm vs cold→zero→warm).
    ///
    ///      SECURITY: Reverts if balance ≤ 1 wei (nothing to claim).
    function claimWinnings() external {
        address player = msg.sender;
        uint256 amount = claimableWinnings[player];
        if (amount <= 1) revert E();
        uint256 payout;
        unchecked {
            claimableWinnings[player] = 1; // Leave sentinel
            payout = amount - 1;
        }
        claimablePool -= payout; // CEI: update state before external call
        _payoutWithStethFallback(player, payout);
    }

    /// @notice Get the caller's claimable winnings balance.
    /// @dev Returns 0 if balance is only the 1 wei sentinel.
    /// @return Claimable amount in wei (excludes sentinel).
    function getWinnings() external view returns (uint256) {
        uint256 stored = claimableWinnings[msg.sender];
        if (stored <= 1) return 0;
        return stored - 1;
    }

    /// @notice Get a player's raw claimable balance (includes the 1 wei sentinel).
    function claimableWinningsOf(address player) external view returns (uint256) {
        return claimableWinnings[player];
    }

    /*+======================================================================+
      |                    TRAIT TICKET SAMPLING                             |
      +======================================================================+
      |  View function for sampling burn ticket holders from recent levels.  |
      |  Used for scatter draws and promotional mechanics.                   |
      +======================================================================+*/

    /// @notice Sample up to 4 trait burn tickets from a random trait and recent level.
    /// @dev Samples from last 20 levels. Uses entropy to select level, trait, and offset.
    ///      Returns empty array if no tickets exist for selected level/trait.
    /// @param entropy Random seed (typically VRF word) for selection.
    /// @return lvlSel Selected level.
    /// @return traitSel Selected trait ID.
    /// @return tickets Array of up to 4 ticket holder addresses.
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

    /*+========================================================================================+
      |                    CREDITS & JACKPOT HELPERS                                           |
      +========================================================================================+
      |  Internal functions for crediting winnings and managing ContractAddresses.JACKPOTS.    |
      +========================================================================================+*/

    /// @dev Credit ETH winnings to a player's claimable balance.
    ///      Uses unchecked math as overflow is practically impossible.
    ///      Emits PlayerCredited for off-chain tracking.
    /// @param beneficiary Player to credit.
    /// @param weiAmount Amount in wei to add.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) internal {
        address recipient = beneficiary;
        unchecked {
            claimableWinnings[recipient] += weiAmount;
        }
        emit PlayerCredited(beneficiary, recipient, weiAmount);
    }

    /*+===============================================================================================+
      |                    JACKPOT PAYOUT FUNCTIONS                                                   |
      +===============================================================================================+
      |  Functions for distributing jackpot winnings. Most jackpot logic                              |
      |  lives in the ContractAddresses.GAME_JACKPOT_MODULE (via delegatecall).                       |
      |                                                                                               |
      |  Jackpot Types:                                                                               |
      |  • Daily jackpot - Paid each day to burn ticket holders                                       |
      |  • Level jackpot - Paid when prize pool target is met                                         |
      |  • Decimator - Special 100-level milestone jackpot (40% of pool)                              |
      |  • BAF - Big-ass-flip jackpot (10% of pool at L%100=0)                                        |
      |  • Carryover extermination - Trait-specific jackpot                                           |
      +===============================================================================================+*/

    /// @dev Run the decimator/BAF jackpot at level 100 milestones.
    ///      Allocates 40% to decimator, 10% to BAF from reward pool.
    /// @param lvl Current level (should be divisible by 100).
    /// @param rngWord VRF random word for winner selection.
    /// @return finished True when jackpot processing is complete.
    function _runDecimatorHundredJackpot(uint24 lvl, uint256 rngWord) internal returns (bool finished) {
        // Decimator/BAF ContractAddresses.JACKPOTS are promotional side-games; odds/payouts live in the ContractAddresses.JACKPOTS module.
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

        uint256 returnWei = jackpots.runDecimatorJackpot(pool, lvl, rngWord);
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

    /// @dev Pay level jackpot via jackpot module delegatecall.
    ///      Called when prize pool target is met during State 2.
    /// @param lvl Current level.
    /// @param rngWord VRF random word for winner selection.
    /// @param effectiveWei Prize pool amount to distribute.
    function payLevelJackpot(uint24 lvl, uint256 rngWord, uint256 effectiveWei) internal {
        (bool ok, bytes memory data) = ContractAddresses.GAME_JACKPOT_MODULE.delegatecall(
            abi.encodeWithSelector(IDegenerusGameJackpotModule.payLevelJackpot.selector, lvl, rngWord, effectiveWei)
        );
        if (!ok) _revertDelegate(data);
    }

    /// @dev Calculate prize pool for level jackpot via jackpot module delegatecall.
    ///      Factors in stETH balance and other pool considerations.
    /// @param lvl Current level.
    /// @param rngWord VRF random word.
    /// @return effectiveWei The prize pool amount available for jackpot.
    function _calcPrizePoolForLevelJackpot(uint24 lvl, uint256 rngWord) internal returns (uint256 effectiveWei) {
        (bool ok, bytes memory data) = ContractAddresses.GAME_JACKPOT_MODULE.delegatecall(
            abi.encodeWithSelector(IDegenerusGameJackpotModule.calcPrizePoolForLevelJackpot.selector, lvl, rngWord)
        );
        if (!ok) _revertDelegate(data);
        if (data.length == 0) revert E();
        return abi.decode(data, (uint256));
    }

    /// @dev Pay daily jackpot via jackpot module delegatecall.
    ///      Called each day during States 2 and 3.
    /// @param isDaily True if degenerus phase (State 3), false if purchase phase (State 2).
    /// @param lvl Current level.
    /// @param randWord VRF random word for winner selection.
    function payDailyJackpot(bool isDaily, uint24 lvl, uint256 randWord) internal {
        (bool ok, bytes memory data) = ContractAddresses.GAME_JACKPOT_MODULE.delegatecall(
            abi.encodeWithSelector(IDegenerusGameJackpotModule.payDailyJackpot.selector, isDaily, lvl, randWord)
        );
        if (!ok) _revertDelegate(data);
    }

    /// @dev Pay the queued MAP jackpot (daily or purchase) via jackpot module delegatecall.
    /// @param lvl Current level.
    /// @param randWord VRF random word for winner selection.
    function payMapJackpot(uint24 lvl, uint256 randWord) internal {
        (bool ok, bytes memory data) = ContractAddresses.GAME_JACKPOT_MODULE.delegatecall(
            abi.encodeWithSelector(IDegenerusGameJackpotModule.payMapJackpot.selector, lvl, randWord)
        );
        if (!ok) _revertDelegate(data);
    }

    /// @dev Pay daily future ticket jackpot: 500 BURNIE flip credit to 20 random future ticket holders.
    ///      Samples 5 players from each of levels +2, +3, +4, +5 (loot box exclusive levels).
    ///      Gas-efficient: unweighted sampling, no duplicates within a level.
    /// @param lvl Current level.
    /// @param randWord VRF random word for winner selection.
    function _payFutureTicketJackpot(uint24 lvl, uint256 randWord) private {
        uint256 entropy = randWord;
        uint256 totalAwarded;

        // Sample from levels +2, +3, +4, +5 (can only get these from loot boxes)
        for (uint256 offset = 2; offset <= 5; offset++) {
            uint24 targetLevel = lvl + uint24(offset);
            address[] storage players = futureMintQueue[targetLevel];
            uint256 playerCount = players.length;

            if (playerCount == 0) continue;

            // Award up to 5 players from this level
            uint256 winnersFromLevel = playerCount < 5 ? playerCount : 5;

            for (uint256 i; i < winnersFromLevel; i++) {
                entropy = _entropyStep(entropy);
                uint256 idx = entropy % playerCount;
                address winner = players[idx];

                // Only award if they still have tickets (could have been consumed)
                if (futureMintsOwed[targetLevel][winner] > 0) {
                    coin.creditFlip(winner, 500 ether); // 500 BURNIE flip credit
                    totalAwarded++;
                }

                // Swap selected player to end and reduce pool size (avoid duplicates)
                players[idx] = players[playerCount - 1];
                playerCount--;
            }
        }

        // Emit event for tracking (optional, can be added later)
        // emit FutureTicketJackpot(lvl, totalAwarded, totalAwarded * 500 ether);
    }

    /// @dev Pay carryover extermination jackpot for the previously exterminated trait.
    ///      Called during setup if a trait was exterminated last level.
    /// @param lvl Current level.
    /// @param traitId The trait that was exterminated.
    /// @param randWord VRF random word for winner selection.
    function payCarryoverExterminationJackpot(uint24 lvl, uint8 traitId, uint256 randWord) internal {
        (bool ok, bytes memory data) = ContractAddresses.GAME_JACKPOT_MODULE.delegatecall(
            abi.encodeWithSelector(
                IDegenerusGameJackpotModule.payCarryoverExterminationJackpot.selector,
                lvl,
                traitId,
                randWord
            )
        );
        if (!ok) _revertDelegate(data);
    }

    /// @dev Sweep game funds on gameover - distributes remaining funds via jackpot or vault sweep.
    ///      Called when liveness guards trigger (2.5yr deploy or 365-day inactivity).
    ///      Transitions game to GAMEOVER (86).
    ///
    ///      LEVEL 1 TIMEOUT (2.5 years): Award all remaining funds via daily jackpot.
    ///      OTHER TIMEOUTS (365 days): Split 50/50 - half to vault, half to cross-level jackpot.
    ///      Final sweep of all remaining funds occurs 1 month after gameover.
    ///
    ///      VRF FALLBACK: Uses rngWordByDay which is set by _gameOverEntropy. If Chainlink VRF
    ///      is broken, waits 3 days then uses earliest historical VRF word as secure fallback.
    ///      This prevents manipulation since historical VRF was already verified on-chain.
    /// @param day Day index for RNG word lookup.
    function gameOverDrainToVault(uint48 day) private {
        if (gameOverFinalJackpotPaid) return; // Already processed

        uint256 ethBal = address(this).balance;
        uint256 stBal = steth.balanceOf(address(this));
        uint256 totalFunds = ethBal + stBal;

        // Calculate available funds (excluding claimable winnings reserve)
        uint256 available = totalFunds > claimablePool ? totalFunds - claimablePool : 0;

        gameState = GAME_STATE_GAMEOVER; // Terminal state
        gameOverTime = uint48(block.timestamp);
        gameOverFinalJackpotPaid = true;

        if (available == 0) return; // Nothing to distribute

        // Get RNG word for jackpot selection (includes VRF fallback after 3 days)
        uint256 rngWord = rngWordByDay[day];
        if (rngWord == 0) return; // RNG not ready yet (wait for fallback)

        // LEVEL 1 TIMEOUT: Award all remaining funds via daily jackpot
        if (level == 1) {
            // Convert stETH to ETH if needed for jackpot pool
            if (stBal > 0) {
                rewardPool += stBal;
            }
            // Award all available funds via daily jackpot mechanism
            payDailyJackpot(true, level, rngWord);
            return;
        }

        // OTHER TIMEOUTS: Split 50/50 between vault and cross-level jackpot
        uint256 halfToVault = available / 2;
        uint256 halfToJackpot = available - halfToVault;

        // Send half to vault (prioritize ETH, then stETH)
        if (halfToVault > 0) {
            if (ethBal >= halfToVault) {
                (bool ok, ) = payable(ContractAddresses.VAULT).call{value: halfToVault}("");
                if (!ok) revert E();
            } else {
                // Send all ETH to vault
                if (ethBal > 0) {
                    (bool ok, ) = payable(ContractAddresses.VAULT).call{value: ethBal}("");
                    if (!ok) revert E();
                }
                // Send remaining from stETH
                uint256 stethToVault = halfToVault - ethBal;
                if (!steth.transfer(ContractAddresses.VAULT, stethToVault)) revert E();
            }
        }

        // Award other half via cross-level jackpot
        if (halfToJackpot > 0) {
            _payGameOverCrossLevelJackpot(halfToJackpot, rngWord);
        }
    }

    /// @dev Distributes gameover jackpot to one random ticket from each level.
    ///      Selects one ticket from each level before the current level, splits pot evenly.
    /// @param amount Total ETH amount to distribute.
    /// @param rngWord VRF random word for winner selection.
    function _payGameOverCrossLevelJackpot(uint256 amount, uint256 rngWord) private {
        if (amount == 0) return;

        uint24 currentLevel = level;
        if (currentLevel <= 1) return; // No previous levels to award

        // First pass: count eligible levels (levels with at least one ticket)
        uint24 eligibleLevels = 0;
        for (uint24 lvl = 1; lvl < currentLevel; ) {
            bool hasTickets = false;
            for (uint16 traitId = 0; traitId < 256; ) {
                if (traitBurnTicket[lvl][uint8(traitId)].length > 0) {
                    hasTickets = true;
                    break;
                }
                unchecked { ++traitId; }
            }
            if (hasTickets) {
                unchecked { ++eligibleLevels; }
            }
            unchecked { ++lvl; }
        }

        if (eligibleLevels == 0) {
            // No tickets found - send all to vault instead
            if (amount <= address(this).balance) {
                (bool ok, ) = payable(ContractAddresses.VAULT).call{value: amount}("");
                if (!ok) revert E();
            } else {
                uint256 ethAvailable = address(this).balance;
                if (ethAvailable > 0) {
                    (bool ok, ) = payable(ContractAddresses.VAULT).call{value: ethAvailable}("");
                    if (!ok) revert E();
                }
                uint256 stethAmount = amount - ethAvailable;
                if (!steth.transfer(ContractAddresses.VAULT, stethAmount)) revert E();
            }
            return;
        }

        // Calculate payout per winner
        uint256 payoutPerWinner = amount / eligibleLevels;
        if (payoutPerWinner == 0) return;

        // Second pass: select winners and distribute
        uint256 entropyState = rngWord;
        for (uint24 lvl = 1; lvl < currentLevel; ) {
            // Count total tickets for this level
            uint256 totalTickets = 0;
            for (uint16 traitId = 0; traitId < 256; ) {
                totalTickets += traitBurnTicket[lvl][uint8(traitId)].length;
                unchecked { ++traitId; }
            }

            if (totalTickets == 0) {
                unchecked { ++lvl; }
                continue;
            }

            // Select a random ticket index
            entropyState = _entropyStep(entropyState);
            uint256 targetTicketIdx = entropyState % totalTickets;

            // Find the winner
            address winner;
            uint256 ticketCount = 0;
            for (uint16 traitId = 0; traitId < 256; ) {
                address[] storage holders = traitBurnTicket[lvl][uint8(traitId)];
                uint256 len = holders.length;
                if (ticketCount + len > targetTicketIdx) {
                    // Winner is in this trait's ticket array
                    winner = holders[targetTicketIdx - ticketCount];
                    break;
                }
                ticketCount += len;
                unchecked { ++traitId; }
            }

            // Credit the winner
            if (winner != address(0)) {
                claimableWinnings[winner] += payoutPerWinner;
                claimablePool += payoutPerWinner;
            }

            unchecked { ++lvl; }
        }
    }

    /// @dev Final sweep of all remaining funds to vault after 1 month post-gameover.
    ///      Called automatically by advanceGame when appropriate time has passed.
    ///      Only sweeps funds beyond claimablePool (preserves player winnings).
    function _gameOverFinalSweep() private {
        if (gameOverTime == 0) return; // Game not over yet
        if (block.timestamp < uint256(gameOverTime) + 30 days) return; // Too early

        uint256 ethBal = address(this).balance;
        uint256 stBal = steth.balanceOf(address(this));
        uint256 totalFunds = ethBal + stBal;

        // Calculate available funds (excluding claimable winnings reserve)
        uint256 available = totalFunds > claimablePool ? totalFunds - claimablePool : 0;

        if (available == 0) return; // Nothing to sweep

        // Send all available funds to vault
        if (ethBal > claimablePool) {
            uint256 ethToVault = ethBal - claimablePool;
            (bool ok, ) = payable(ContractAddresses.VAULT).call{value: ethToVault}("");
            if (!ok) revert E();
        }

        // Sweep any remaining stETH
        if (stBal > 0) {
            if (!steth.transfer(ContractAddresses.VAULT, stBal)) revert E();
        }
    }

    /*+======================================================================+
      |                    ADMIN: REWARD VAULT & LIQUIDITY                   |
      +======================================================================+
      |  Admin-only functions for managing ETH/stETH liquidity.              |
      |  Used to optimize yield and maintain sufficient ETH for payouts.     |
      |                                                                      |
      |  SECURITY:                                                           |
      |  • Admin-only access (VRF owner contract)                            |
      |  • Cannot touch claimablePool reserve (protected for player claims)  |
      |  • All operations are value-preserving (no fund extraction)          |
      +======================================================================+*/

    /// @notice Admin-only swap: owner sends ETH in and receives game-held stETH.
    /// @dev Used to rebalance when stETH yield should be converted to ETH.
    ///      Admin must send exact ETH amount equal to stETH received.
    ///      SECURITY: Value-neutral swap, ContractAddresses.ADMIN cannot extract funds.
    /// @param recipient Address to receive stETH.
    /// @param amount ETH amount to swap (must match msg.value).
    function adminSwapEthForStEth(address recipient, uint256 amount) external payable {
        if (msg.sender != ContractAddresses.ADMIN) revert E();
        if (recipient == address(0)) revert E();
        if (amount == 0 || msg.value != amount) revert E();

        uint256 stBal = steth.balanceOf(address(this));
        if (stBal < amount) revert E();
        if (!steth.transfer(recipient, amount)) revert E();
    }

    /// @notice Admin-only stake of game-held ETH into stETH via Lido.
    /// @dev Used to earn yield on excess ETH held by the game.
    ///      SECURITY: Cannot stake ETH reserved for player claims (claimablePool).
    /// @param amount ETH amount to stake.
    function adminStakeEthForStEth(uint256 amount) external {
        if (msg.sender != ContractAddresses.ADMIN) revert E();
        if (amount == 0) revert E();

        uint256 ethBal = address(this).balance;
        if (ethBal < amount) revert E();
        uint256 reserve = claimablePool;
        if (ethBal <= reserve) revert E();
        uint256 stakeable = ethBal - reserve;
        if (amount > stakeable) revert E();

        // stETH return value intentionally ignored: Lido mints 1:1 for ETH, validated by input checks
        try steth.submit{value: amount}(address(0)) returns (uint256) {} catch {
            revert E();
        }
    }

    /*+======================================================================+
      |                    VRF (CHAINLINK) INTEGRATION                       |
      +======================================================================+
      |  Chainlink VRF V2.5 integration for provably fair randomness.        |
      |                                                                      |
      |  LIFECYCLE:                                                          |
      |  1. advanceGame() calls rngAndTimeGate()                             |
      |  2. If no valid RNG word, _requestRng() is called                    |
      |  3. Chainlink calls rawFulfillRandomWords() with random word         |
      |  4. Next advanceGame() uses the fulfilled word                       |
      |  5. After processing, _unlockRng() resets for next cycle             |
      |                                                                      |
      |  SECURITY:                                                           |
      |  • RNG lock prevents state manipulation during VRF window            |
      |  • 18-hour timeout allows recovery from stale requests               |
      |  • 3-day stall enables emergency coordinator rotation                |
      |  • Nudge system allows players to influence (not predict) RNG        |
      +======================================================================+*/

    /// @dev Gate function for RNG readiness and day transition.
    ///      Returns existing word if available, or requests new one.
    /// @param day Current day index.
    /// @param lvl Current level.
    /// @param isMapJackpotDay True if this is the last purchase day.
    /// @return word VRF random word (returns 1 as sentinel if request just made).
    function rngAndTimeGate(uint48 day, uint24 lvl, bool isMapJackpotDay) internal returns (uint256 word) {
        if (day == dailyIdx) revert NotTimeYet();

        uint256 currentWord = rngFulfilled ? rngWordCurrent : 0;

        if (currentWord == 0 && rngLockedFlag && rngRequestTime != 0) {
            uint48 elapsed = uint48(block.timestamp) - rngRequestTime;
            if (elapsed >= 18 hours) {
                _requestRng(gameState, isMapJackpotDay, lvl);
                return 1;
            }
        }

        if (currentWord == 0) {
            if (rngLockedFlag) revert RngNotReady();
            _requestRng(gameState, isMapJackpotDay, lvl);
            return 1;
        }

        if (!rngLockedFlag) {
            // Stale entropy from previous cycle; request a fresh word.
            _requestRng(gameState, isMapJackpotDay, lvl);
            return 1;
        }

        // Record the word once per day; using a zero sentinel since VRF returning 0 is effectively impossible.
        if (rngWordByDay[day] == 0) {
            rngWordByDay[day] = currentWord;
            bool bonusFlip = isMapJackpotDay || lootboxPresaleActive;
            // Always run coinflip payouts once game has started (lvl always >= 1)
            coin.processCoinflipPayouts(lvl, bonusFlip, currentWord, day);
        }
        return currentWord;
    }

    /// @dev Game-over RNG gate with fallback for stalled VRF.
    ///      After 3-day timeout, uses earliest historical VRF word as fallback (more secure
    ///      than blockhash since it's already verified on-chain and cannot be manipulated).
    /// @return word RNG word, 1 if request sent, or 0 if waiting on fallback.
    function _gameOverEntropy(uint48 day, uint24 lvl, bool isMapJackpotDay) private returns (uint256 word) {
        if (rngWordByDay[day] != 0) return rngWordByDay[day];

        uint256 currentWord = rngFulfilled ? rngWordCurrent : 0;
        if (currentWord != 0 && rngLockedFlag) {
            rngWordByDay[day] = currentWord;
            if (lvl != 0) {
                coin.processCoinflipPayouts(lvl, isMapJackpotDay, currentWord, day);
            }
            return currentWord;
        }

        if (rngLockedFlag) {
            if (rngRequestTime != 0) {
                uint48 elapsed = uint48(block.timestamp) - rngRequestTime;
                if (elapsed >= GAMEOVER_RNG_FALLBACK_DELAY) {
                    // Use earliest historical VRF word as fallback (more secure than blockhash)
                    uint256 fallbackWord = _getHistoricalRngFallback(day);
                    rngWordByDay[day] = fallbackWord;
                    if (lvl != 0) {
                        coin.processCoinflipPayouts(lvl, isMapJackpotDay, fallbackWord, day);
                    }
                    return fallbackWord;
                }
            }
            return 0;
        }

        if (_tryRequestRng(gameState, isMapJackpotDay, lvl)) {
            return 1;
        }

        // VRF request failed; lock RNG and start fallback timer.
        rngLockedFlag = true;
        rngFulfilled = false;
        rngWordCurrent = 0;
        rngRequestTime = uint48(block.timestamp);
        return 0;
    }

    /// @dev Get historical VRF word as fallback for gameover RNG.
    ///      Searches backwards from current day to find earliest available RNG word.
    ///      Only uses blockhash-based fallback if no historical words exist.
    /// @param currentDay Current day index.
    /// @return word Historical RNG word or blockhash-based fallback.
    function _getHistoricalRngFallback(uint48 currentDay) private view returns (uint256 word) {
        // Search for earliest available historical RNG word
        // Start from day 1 (day 0 might not exist if game started at different time)
        for (uint48 searchDay = 1; searchDay < currentDay; ) {
            word = rngWordByDay[searchDay];
            if (word != 0) {
                // Found a historical VRF word - use it (XOR with current day for uniqueness)
                return uint256(keccak256(abi.encodePacked(word, currentDay)));
            }
            unchecked { ++searchDay; }
        }

        // No historical words found - use blockhash fallback (shouldn't happen in practice)
        word = _fallbackRng(currentDay, level);
    }

    function _fallbackRng(uint48 day, uint24 lvl) private view returns (uint256 word) {
        uint256 prevWord = day == 0 ? 0 : rngWordByDay[day - 1];
        word = uint256(
            keccak256(
                abi.encodePacked(
                    blockhash(block.number - 1),
                    block.prevrandao,
                    block.timestamp,
                    address(this),
                    day,
                    lvl,
                    prevWord
                )
            )
        );
        if (word == 0) word = 1;
    }

    /*+======================================================================+
      |                    FUTURE MINT ACTIVATION                           |
      +======================================================================+
      |  Future reward mints are staged per level and activated at the       |
      |  start of that level's purchase phase.                               |
      +======================================================================+*/

    /// @dev Process a batch of future reward mints for the current level.
    ///      Also pulls any reserved pool into nextPrizePool once per level.
    /// @param playersToProcess Max players to process this call (0 = default batch size).
    /// @param lvl Current level.
    /// @return worked True if any queued entries were processed.
    /// @return finished True if all queued entries for this level are processed.
    function _processFutureMintBatch(
        uint32 playersToProcess,
        uint24 lvl
    ) private returns (bool worked, bool finished) {
        uint256 reserved = futurePrizePool[lvl];
        if (reserved != 0) {
            nextPrizePool += reserved;
            futurePrizePool[lvl] = 0;
            futurePrizePoolTotal -= reserved;
        }

        address[] storage queue = futureMintQueue[lvl];
        uint256 total = queue.length;
        if (total > type(uint32).max) revert E();
        if (total == 0) {
            futureMintCursor = 0;
            futureMintLevel = 0;
            return (false, true);
        }

        if (futureMintLevel != lvl) {
            futureMintLevel = lvl;
            futureMintCursor = 0;
        }

        uint256 idx = futureMintCursor;
        if (idx >= total) {
            delete futureMintQueue[lvl];
            futureMintCursor = 0;
            futureMintLevel = 0;
            return (false, true);
        }

        uint32 batch = playersToProcess == 0 ? FUTURE_MINT_PLAYER_BATCH_SIZE : playersToProcess;
        uint256 end = idx + batch;
        if (end > total) {
            end = total;
        }

        while (idx < end) {
            address player = queue[idx];
            uint32 owed = futureMintsOwed[lvl][player];
            if (owed != 0) {
                futureMintsOwed[lvl][player] = 0;
                nft.queueRewardMints(player, owed);
            }
            unchecked {
                ++idx;
            }
        }

        worked = end != futureMintCursor;
        futureMintCursor = uint32(idx);
        finished = idx >= total;
        if (finished) {
            delete futureMintQueue[lvl];
            futureMintCursor = 0;
            futureMintLevel = 0;
        }
    }

    /// @dev Deterministic price lookup by level (independent of claim time).
    function _priceForLevel(uint24 targetLevel) private pure returns (uint256) {
        if (targetLevel == 0) return 0;
        if (targetLevel < 10) {
            return 0.025 ether / ContractAddresses.COST_DIVISOR;
        }
        uint24 offset = targetLevel % 100;
        if (offset == 0 || offset < 10) {
            return 0.25 ether;
        }
        if (offset < 30) {
            return 0.05 ether;
        }
        if (offset < 80) {
            return 0.1 ether;
        }
        return 0.15 ether;
    }

    /// @dev Xorshift PRNG step for deterministic entropy progression.
    function _entropyStep(uint256 state) private pure returns (uint256) {
        unchecked {
            state ^= state << 7;
            state ^= state >> 9;
            state ^= state << 8;
        }
        return state;
    }

    function _lootboxTicketCount(
        uint256 budgetWei,
        uint256 priceWei,
        uint256 entropy
    ) private pure returns (uint32 count, uint256 nextEntropy) {
        if (budgetWei == 0 || priceWei == 0) {
            return (0, entropy);
        }

        // Apply jackpot variance: 20% chance for 3x tickets, 80% chance for 0.6x tickets
        // Maintains 1.08x EV: (0.2 × 3) + (0.8 × 0.6) = 1.08
        nextEntropy = _entropyStep(entropy);
        uint256 multiplierRoll = nextEntropy % 10;
        uint256 adjustedBudget;
        if (multiplierRoll < 2) {
            // Jackpot! 3x tickets
            adjustedBudget = (budgetWei * 3);
        } else {
            // Below average: 0.6x tickets
            adjustedBudget = (budgetWei * 6) / 10;
        }

        uint256 base = adjustedBudget / priceWei;
        uint256 remainder = adjustedBudget - (base * priceWei);
        if (remainder != 0) {
            nextEntropy = _entropyStep(nextEntropy);
            if (nextEntropy % priceWei < remainder) {
                unchecked {
                    ++base;
                }
            }
        }

        if (base > type(uint32).max) revert E();
        count = uint32(base);
    }

    function _resolveLootboxRoll(
        address player,
        uint256 amount,
        uint24 targetLevel,
        uint256 targetPrice,
        uint256 entropy,
        bool /* isPresale - unused after removing level distribution logic */
    ) private returns (uint256 burnieOut, uint32 ticketsOut, uint256 nextEntropy, bool applyPresaleMultiplier) {
        nextEntropy = entropy;
        if (amount == 0) return (0, 0, nextEntropy, false);

        nextEntropy = _entropyStep(nextEntropy);

        // Both modes: 60% tickets/gamepieces (0-11), 20% small BURNIE (12-15), 20% large BURNIE (16-19) using d20 roll
        // Target level is rolled by caller (current level + 0-5)
        // Within ticket outcome: 1/6 chance for gamepiece (if budget >= 4× MAP price), else tickets
        uint256 rollMax = 20;
        uint256 ticketThreshold = 12; // rolls 0-11 = tickets
        uint256 largeBurnieThreshold = 16; // rolls 16-19 = large BURNIE
        uint16 ticketBps = LOOTBOX_TICKET_ROLL_BPS;
        uint16 smallBurnieBps = LOOTBOX_SMALL_BURNIE_ROLL_BPS;
        uint16 largeBurnieBps = LOOTBOX_LARGE_BURNIE_ROLL_BPS;

        uint256 roll = nextEntropy % rollMax;

        if (roll < ticketThreshold) {
            // Target level already rolled by caller, use its price for ticket calculations
            uint256 price = targetPrice;

            uint256 ticketBudget = (amount * ticketBps) / 10_000;

            // If budget would give less than 1 ticket, convert to BURNIE at 80% value (20% penalty)
            if (ticketBudget < price) {
                uint256 burnieValue = (ticketBudget * PRICE_COIN_UNIT) / targetPrice;
                burnieOut = (burnieValue * 80) / 100; // 20% penalty for insufficient budget
                applyPresaleMultiplier = false;
            } else {
                // Check if budget allows for a gamepiece (4 MAP tickets = 1 gamepiece)
                uint256 gamepiecePrice = price * 4;
                bool canAffordGamepiece = ticketBudget >= gamepiecePrice;

                // If can afford gamepiece, do 1/6 roll for gamepiece vs tickets
                bool awardGamepiece = false;
                if (canAffordGamepiece) {
                    nextEntropy = _entropyStep(nextEntropy);
                    uint256 gamepieceRoll = nextEntropy % 6;
                    awardGamepiece = (gamepieceRoll == 0);
                }

                if (awardGamepiece) {
                    // Award 1 gamepiece for target level
                    if (targetLevel <= level) {
                        // Current level: convert to BURNIE equivalent
                        burnieOut = 4 * PRICE_COIN_UNIT;
                    } else {
                        // Future level: queue gamepiece mint
                        _queueFutureRewardMints(player, targetLevel, 4, 0);
                        ticketsOut = 4;
                    }
                    applyPresaleMultiplier = false;
                } else {
                    // Award tickets as normal
                    (uint32 tickets, uint256 entropyAfter) = _lootboxTicketCount(ticketBudget, price, nextEntropy);
                    nextEntropy = entropyAfter;
                    if (tickets == 0) return (0, 0, nextEntropy, false);

                    if (targetLevel <= level) {
                        burnieOut = uint256(tickets) * PRICE_COIN_UNIT;
                    } else {
                        _queueFutureRewardMints(player, targetLevel, tickets, 0);
                        ticketsOut = tickets;
                    }
                    applyPresaleMultiplier = false;
                }
            }
        } else if (roll < largeBurnieThreshold) {
            // Small BURNIE (rolls 12-15): 5% of amount as BURNIE
            uint256 burnieBudget = (amount * smallBurnieBps) / 10_000;
            burnieOut = (burnieBudget * PRICE_COIN_UNIT) / targetPrice;
            applyPresaleMultiplier = true;
        } else {
            // Large BURNIE (rolls 16-19): 195% of amount as BURNIE
            uint256 burnieBudget = (amount * largeBurnieBps) / 10_000;
            burnieOut = (burnieBudget * PRICE_COIN_UNIT) / targetPrice;
            applyPresaleMultiplier = true;
        }
    }

    /*+======================================================================+
      |                    MAP / gamepiece AIRDROP BATCHING                        |
      +======================================================================+
      |  Map mints are processed in batches to prevent gas exhaustion.       |
      |  Large purchases are queued and processed across multiple txs.       |
      +======================================================================+*/

    /// @dev Process a batch of map mints via jackpot module delegatecall.
    /// @param writesBudget Count of SSTORE writes allowed (0 = use default).
    ///                     Hard-clamped to stay within gas limits.
    /// @return finished True if all pending map mints have been processed.
    function _processMapBatch(uint32 writesBudget) internal returns (bool finished) {
        (bool ok, bytes memory data) = ContractAddresses.GAME_JACKPOT_MODULE.delegatecall(
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

    /// @dev Request new VRF random word from Chainlink.
    ///      Sets RNG lock to prevent manipulation during pending window.
    /// @param gameState_ Current game state.
    /// @param isMapJackpotDay True if this is the last purchase day.
    /// @param lvl Current level.
    function _requestRng(uint8 gameState_, bool isMapJackpotDay, uint24 lvl) private {
        // Hard revert if Chainlink request fails; this intentionally halts game progress until VRF funding/config is fixed.
        uint256 id = vrfCoordinator.requestRandomWords(
            VRFRandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
                numWords: 1,
                extraArgs: hex"" // Empty for LINK payment (default)
            })
        );
        _finalizeRngRequest(gameState_, isMapJackpotDay, lvl, id);
    }

    function _tryRequestRng(uint8 gameState_, bool isMapJackpotDay, uint24 lvl) private returns (bool requested) {
        if (address(vrfCoordinator) == address(0) || vrfKeyHash == bytes32(0) || vrfSubscriptionId == 0) {
            return false;
        }

        try
            vrfCoordinator.requestRandomWords(
                VRFRandomWordsRequest({
                    keyHash: vrfKeyHash,
                    subId: vrfSubscriptionId,
                    requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                    callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
                    numWords: 1,
                    extraArgs: hex"" // Empty for LINK payment (default)
                })
            )
        returns (uint256 id) {
            _finalizeRngRequest(gameState_, isMapJackpotDay, lvl, id);
            requested = true;
        } catch {}
    }

    function _finalizeRngRequest(uint8 gameState_, bool isMapJackpotDay, uint24 lvl, uint256 requestId) private {
        vrfRequestId = requestId;
        rngFulfilled = false;
        rngWordCurrent = 0;
        rngLockedFlag = true;
        rngRequestTime = uint48(block.timestamp);

        bool decClose = (((lvl % 100 != 0 && (lvl % 100 != 99) && gameState_ == GAME_STATE_SETUP) ||
            (lvl % 100 == 0 && isMapJackpotDay)) && decWindowOpen);
        if (decClose) decWindowOpen = false;
    }

    /// @notice Emergency VRF coordinator rotation after 3-day stall.
    /// @dev Access: ContractAddresses.ADMIN only. Only available when VRF has stalled for 3+ days.
    ///      This is a recovery mechanism for Chainlink outages.
    ///      SECURITY: Requires 3-day gap to prevent abuse.
    /// @param newCoordinator New VRF coordinator address.
    /// @param newSubId New subscription ID.
    /// @param newKeyHash New key hash for the gas lane.
    function updateVrfCoordinatorAndSub(address newCoordinator, uint256 newSubId, bytes32 newKeyHash) external {
        if (msg.sender != ContractAddresses.ADMIN) revert E();
        if (!_threeDayRngGap(_currentDayIndex())) revert VrfUpdateNotReady();
        _setVrfConfig(newCoordinator, newSubId, newKeyHash, address(vrfCoordinator));
    }

    /// @dev Set new VRF configuration and reset RNG state.
    ///      Clears any pending request and unlocks RNG usage.
    /// @param newCoordinator New VRF coordinator address.
    /// @param newSubId New subscription ID.
    /// @param newKeyHash New key hash.
    /// @param current Previous coordinator address (for event).
    function _setVrfConfig(address newCoordinator, uint256 newSubId, bytes32 newKeyHash, address current) private {
        if (newCoordinator == address(0) || newKeyHash == bytes32(0) || newSubId == 0) revert E();

        vrfCoordinator = IVRFCoordinator(newCoordinator);
        vrfSubscriptionId = newSubId;
        vrfKeyHash = newKeyHash;

        // Reset RNG state to allow immediate advancement
        rngLockedFlag = false;
        rngFulfilled = true;
        vrfRequestId = 0;
        rngRequestTime = 0;
        rngWordCurrent = 0;
        emit VrfCoordinatorUpdated(current, newCoordinator);
    }

    /// @dev Unlock RNG after processing is complete for the day.
    ///      Resets VRF state and re-enables RNG usage.
    /// @param day Current day index to record.
    function _unlockRng(uint48 day) private {
        dailyIdx = day;
        rngLockedFlag = false;
        vrfRequestId = 0;
        rngRequestTime = 0;
    }

    /// @notice Pay BURNIE to nudge the next RNG word by +1.
    /// @dev Cost scales +50% per queued nudge and resets after fulfillment.
    ///      Only available while RNG is unlocked (before VRF request is in-flight).
    ///      MECHANISM: Adds 1 to the VRF word for each nudge, changing outcomes.
    ///      SECURITY: Players cannot predict the base word, only influence it.
    function reverseFlip() external {
        if (rngLockedFlag) revert RngLocked();
        uint256 reversals = totalFlipReversals;
        uint256 cost = _currentNudgeCost(reversals);
        coin.burnCoin(msg.sender, cost);
        uint256 newCount = reversals + 1;
        totalFlipReversals = newCount;
        emit ReverseFlip(msg.sender, newCount, cost);
    }

    /// @notice Chainlink VRF callback for random word fulfillment.
    /// @dev Access: VRF coordinator only.
    ///      Applies any queued nudges before storing the word.
    ///      SECURITY: Validates requestId and coordinator address.
    /// @param requestId The request ID to match.
    /// @param randomWords Array containing the random word (length 1).
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(vrfCoordinator)) revert E();
        if (requestId != vrfRequestId || rngFulfilled) return;
        uint256 word = randomWords[0];
        // Apply any queued nudges (reverseFlip)
        uint256 rngNudge = totalFlipReversals;
        if (rngNudge != 0) {
            unchecked {
                word += rngNudge;
            }
            totalFlipReversals = 0;
        }
        if (word == 0) word = 1;
        rngFulfilled = true;
        rngWordCurrent = word;
    }

    /// @dev Calculate nudge cost with compounding.
    ///      Base cost is 100 BURNIE, +50% per queued nudge.
    /// @param reversals Number of nudges already queued.
    /// @return cost BURNIE cost for the next nudge.
    function _currentNudgeCost(uint256 reversals) private pure returns (uint256 cost) {
        cost = RNG_NUDGE_BASE_COST;
        while (reversals != 0) {
            cost = (cost * 15) / 10; // Compound 50% per queued reversal
            unchecked {
                --reversals;
            }
        }
    }

    /*+======================================================================+
      |                    PAYMENT HELPERS                                   |
      +======================================================================+
      |  Internal functions for ETH/stETH payouts.                           |
      |  Implements fallback logic when one asset is insufficient.           |
      +======================================================================+*/

    /// @dev Send ETH first, then stETH for remainder.
    ///      Used for player claim payouts (ETH preferred).
    ///      Includes retry logic if stETH is short but ETH arrives.
    /// @param to Recipient address.
    /// @param amount Total wei to send.
    function _payoutWithStethFallback(address to, uint256 amount) private {
        if (amount == 0) return;

        // Try ETH first (preferred for player claims)
        uint256 ethBal = address(this).balance;
        uint256 ethSend = amount <= ethBal ? amount : ethBal;
        if (ethSend != 0) {
            (bool okEth, ) = payable(to).call{value: ethSend}("");
            if (!okEth) revert E();
        }
        uint256 remaining = amount - ethSend;
        if (remaining == 0) return;

        // Fall back to stETH for remainder
        uint256 stBal = steth.balanceOf(address(this));
        uint256 stSend = remaining <= stBal ? remaining : stBal;
        if (stSend != 0) {
            if (!steth.transfer(to, stSend)) revert E();
        }

        // Retry ETH for any remaining (handles edge cases)
        uint256 leftover = remaining - stSend;
        if (leftover != 0) {
            // Retry with any refreshed ETH (e.g., if stETH was short but ETH arrived).
            uint256 ethRetry = address(this).balance;
            if (ethRetry < leftover) revert E();
            (bool ok, ) = payable(to).call{value: leftover}("");
            if (!ok) revert E();
        }
    }

    /*+======================================================================+
      |                    BURN & TRAIT HELPERS                              |
      +======================================================================+
      |  Internal functions for burn credit calculation and trait management.|
      +======================================================================+*/

    /// @dev Credit BURNIE coinflip balance for burning gamepieces.
    ///      Bonus is calculated from count + bonus tenths.
    /// @param caller The player who burned tokens.
    /// @param count Number of tokens burned.
    /// @param bonusTenths Additional bonus in tenths (e.g., 49 = 4.9x bonus).
    function _creditBurnFlip(address caller, uint256 count, uint256 bonusTenths) private {
        uint256 priceUnit = PRICE_COIN_UNIT / 10;
        uint256 flipCredit;
        unchecked {
            flipCredit = (count + bonusTenths) * priceUnit;
        }

        coin.creditFlip(caller, flipCredit);
    }

    /// @dev Clear daily burn count array efficiently using assembly.
    ///      Resets 80 uint32 values packed into 10 storage slots.
    function _clearDailyBurnCount() private {
        // 80 uint32 values packed into 10 consecutive storage slots.
        assembly ("memory-safe") {
            let slot := dailyBurnCount.slot
            let end := add(slot, 10)
            for {
                let s := slot
            } lt(s, end) {
                s := add(s, 1)
            } {
                sstore(s, 0)
            }
        }
    }

    /*+======================================================================+
      |                    TRAIT DERIVATION & MANAGEMENT                     |
      +======================================================================+
      |  Deterministic trait derivation from token ID using keccak256.       |
      |  Each token has 4 traits, each with category (0-7) and sub (0-7).    |
      |  Trait ID = (category << 3) | sub, with category offset per slot:    |
      |  • Slot 0: traits 0-63   (category 0-7)                              |
      |  • Slot 1: traits 64-127 (category 8-15)                             |
      |  • Slot 2: traits 128-191                                            |
      |  • Slot 3: traits 192-255                                            |
      +======================================================================+*/

    /// @dev Calculate trait weight from random value.
    ///      Weighted distribution: lower weights more common.
    /// @param rnd Random 32-bit value.
    /// @return Weight 0-7 with non-uniform probability.
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

    /// @dev Derive a single trait from 64-bit random value.
    ///      Combines category and sub-weight into 6-bit trait ID.
    /// @param rnd 64-bit random value (uses low 32 bits for category, high 32 for sub).
    /// @return 6-bit trait ID (0-63 for base slot).
    function _deriveTrait(uint64 rnd) private pure returns (uint8) {
        uint8 category = _traitWeight(uint32(rnd));
        uint8 sub = _traitWeight(uint32(rnd >> 32));
        return (category << 3) | sub;
    }

    /// @dev Derive all 4 traits for a token deterministically.
    ///      Uses keccak256(tokenId) and splits into 4 x 64-bit segments.
    ///      Each trait is offset by 64 to place in correct slot.
    /// @param tokenId The gamepiece token ID.
    /// @return packed 4 x 8-bit trait IDs packed into uint32.
    function _traitsForToken(uint256 tokenId) private pure returns (uint32 packed) {
        uint256 rand = uint256(keccak256(abi.encodePacked(tokenId)));
        uint8 trait0 = _deriveTrait(uint64(rand));
        uint8 trait1 = _deriveTrait(uint64(rand >> 64)) | 64; // Slot 1 offset
        uint8 trait2 = _deriveTrait(uint64(rand >> 128)) | 128; // Slot 2 offset
        uint8 trait3 = _deriveTrait(uint64(rand >> 192)) | 192; // Slot 3 offset
        packed = uint32(trait0) | (uint32(trait1) << 8) | (uint32(trait2) << 16) | (uint32(trait3) << 24);
    }

    /// @dev Seed trait start counts from current remaining counts.
    ///      Called at level start to capture initial distribution.
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

    /// @dev Consume one count of a trait, check for extermination.
    ///      Called during burn processing for each trait on burned token.
    /// @param traitId The trait being consumed.
    /// @param endLevel Threshold for extermination (0 normally, 1 on L%10=7).
    /// @return reachedZero True if trait count hit the threshold.
    function _consumeTrait(uint8 traitId, uint32 endLevel) private returns (bool reachedZero) {
        // Trait counts are expected to be seeded for the current level; hitting zero here should only occur via burn flow.
        uint32 stored = traitRemaining[traitId];

        unchecked {
            stored -= 1;
        }
        traitRemaining[traitId] = stored;
        return stored == endLevel;
    }

    /// @dev Record exterminator address for a level.
    ///      address(0) is stored for timeout ends.
    /// @param lvl The level that ended.
    /// @param ex The player who triggered extermination (or address(0)).
    function _setExterminatorForLevel(uint24 lvl, address ex) private {
        if (lvl == 0) return;
        levelExterminators[lvl] = ex;
    }

    /*+======================================================================+
      |                    VIEW: TRAIT & EXTERMINATOR QUERIES                |
      +======================================================================+
      |  Read-only functions for querying trait state and game history.      |
      +======================================================================+*/

    /// @notice Get the exterminator address for a level.
    /// @param lvl The level to query.
    /// @return The address that triggered extermination (address(0) if timeout or not reached).
    function levelExterminator(uint24 lvl) external view returns (address) {
        if (lvl == 0) return address(0);
        return levelExterminators[lvl];
    }

    /// @notice Get the starting trait count for a trait at current level.
    /// @param traitId The trait ID to query.
    /// @return The count at level start.
    function startTraitRemaining(uint8 traitId) external view returns (uint32) {
        return traitStartRemaining[traitId];
    }

    /// @notice Get remaining counts for 4 traits at once.
    /// @dev Batched for gas efficiency when checking token traits.
    /// @param traitIds Array of 4 trait IDs.
    /// @return lastExterminated The last exterminated trait (or TRAIT_ID_TIMEOUT).
    /// @return currentLevel Current game level.
    /// @return remaining Array of remaining counts for each trait.
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

    /// @notice Count a player's tickets for a specific trait and level.
    /// @dev Paginated for large ticket arrays.
    /// @param trait The trait ID.
    /// @param lvl The level to query.
    /// @param offset Starting index for pagination.
    /// @param limit Maximum entries to scan.
    /// @param player The player address to count.
    /// @return count Number of tickets found in this page.
    /// @return nextOffset Next offset for pagination.
    /// @return total Total tickets in the array.
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

    /// @notice Get pending mints and maps owed to a player.
    /// @param player The player address.
    /// @return mints Number of gamepiece mints owed.
    /// @return maps Number of map entries owed.
    function getPlayerPurchases(address player) external view returns (uint32 mints, uint32 maps) {
        mints = nft.tokensOwed(player);
        maps = playerMapMintsOwed[player];
    }

    /*+======================================================================+
      |                    RECEIVE FUNCTION                                  |
      +======================================================================+
      |  Accept plain ETH transfers and route to reward pool.                |
      |  This allows external contributions to jackpot rewards.              |
      +======================================================================+*/

    /// @notice Accept ETH and add to reward pool.
    /// @dev Plain ETH transfers are routed to jackpot rewards.
    receive() external payable {
        rewardPool += msg.value;
    }
}
