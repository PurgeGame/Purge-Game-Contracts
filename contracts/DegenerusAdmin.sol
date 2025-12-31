// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DegenerusAdmin
 * @author Burnie Degenerus
 * @notice Central administration contract for the Degenerus game ecosystem.
 *
 * @dev ARCHITECTURE OVERVIEW
 * ─────────────────────────────────────────────────────────────────────────────
 * This contract serves as the single point of authority for:
 *   1. VRF subscription ownership and management
 *   2. One-time wiring of all game contracts
 *   3. Emergency recovery during VRF failures
 *   4. LINK token donation handling with reward multipliers
 *   5. Presale administration functions
 *
 * DEPLOYMENT ORDER:
 *   1. Deploy DegenerusAdmin (passing LINK token address)
 *   2. Deploy all other game contracts (passing admin address where needed)
 *   3. Call wireAll() to connect everything with VRF subscription creation
 *
 * OWNERSHIP MODEL:
 *   - Single owner (creator) set immutably at construction
 *   - No ownership transfer capability (intentional simplicity)
 *   - Owner cannot change after deployment
 *
 * VRF SUBSCRIPTION LIFECYCLE:
 *   1. Created during first wireAll() call
 *   2. Consumers (game, bonds) added automatically
 *   3. LINK funding via onTokenTransfer (ERC-677)
 *   4. Emergency recovery if stalled 3+ days
 *   5. Shutdown after game-over with LINK refund
 *
 * SECURITY CONSIDERATIONS
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. IMMUTABLE OWNER: Creator is set once and cannot be changed, eliminating
 *    ownership transfer attack vectors.
 *
 * 2. ONE-TIME WIRING: Most wiring operations use AlreadyWired guards to prevent
 *    re-pointing contracts to malicious addresses after initial setup.
 *
 * 3. STALL-GATED RECOVERY: Emergency VRF migration requires 3-day stall proof
 *    from the game contract, preventing premature or malicious migration.
 *
 * 4. GAME-OVER GUARD: Shutdown functions check gameOverStarted/Attempted flags
 *    to prevent premature subscription cancellation.
 *
 * 5. LINK CALLBACK VALIDATION: onTokenTransfer validates msg.sender == linkToken
 *    to prevent fake LINK transfer attacks.
 *
 * 6. PRICE FEED STALENESS: _feedHealthy() checks roundId, answer sign, and
 *    updatedAt to reject stale or invalid price data.
 */

// =============================================================================
// EXTERNAL INTERFACES
// =============================================================================

/// @dev Minimal VRF coordinator surface for subscription management.
///      Only the functions needed for admin operations are included.
interface IVRFCoordinatorV2_5Owner {
    /// @notice Add a consumer contract to a VRF subscription.
    /// @param subId The subscription ID to add the consumer to.
    /// @param consumer The address of the consumer contract.
    function addConsumer(uint256 subId, address consumer) external;

    /// @notice Cancel a VRF subscription and refund remaining LINK.
    /// @param subId The subscription ID to cancel.
    /// @param to The address to receive the LINK refund.
    function cancelSubscription(uint256 subId, address to) external;

    /// @notice Create a new VRF subscription.
    /// @return subId The newly created subscription ID.
    function createSubscription() external returns (uint256 subId);

    /// @notice Get subscription details including balance and consumers.
    /// @param subId The subscription ID to query.
    /// @return balance LINK balance in the subscription.
    /// @return nativeBalance Native token balance (if applicable).
    /// @return reqCount Number of requests made.
    /// @return owner The subscription owner.
    /// @return consumers Array of consumer addresses.
    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);
}

/// @dev Game contract interface for VRF-related operations.
interface IDegenerusGameVrf {
    /// @notice Check if RNG has been stalled for 3+ days (enables emergency recovery).
    function rngStalledForThreeDays() external view returns (bool);

    /// @notice Emergency update of VRF configuration during recovery.
    /// @param newCoordinator New VRF coordinator address.
    /// @param newSubId New subscription ID.
    /// @param newKeyHash New key hash for the coordinator.
    function updateVrfCoordinatorAndSub(address newCoordinator, uint256 newSubId, bytes32 newKeyHash) external;

    /// @notice Initial VRF wiring during setup.
    function wireVrf(address coordinator_, uint256 subId, bytes32 keyHash_) external;
}

/// @dev Game contract interface for quest module wiring.
interface IDegenerusGameQuest {
    function wireQuestModule(address questModule_) external;
}

/// @dev Bonds contract admin interface.
interface IDegenerusBondsAdmin {
    /// @notice Wire the bonds contract with all dependencies.
    /// @param addresses Array: [game, vault, coin, coordinator, questModule, trophies, affiliate].
    /// @param vrfSubId The VRF subscription ID.
    /// @param vrfKeyHash_ The VRF key hash.
    function wire(address[] calldata addresses, uint256 vrfSubId, bytes32 vrfKeyHash_) external;

    /// @notice Emergency VRF reconfiguration during recovery.
    function emergencySetVrf(address coordinator_, uint256 vrfSubId, bytes32 vrfKeyHash_) external;
}

/// @dev Bonds contract presale admin interface.
interface IDegenerusBondsPresaleAdmin {
    /// @notice Permanently disable presale purchases.
    function shutdownPresale() external;

    /// @notice Trigger the presale jackpot distribution.
    /// @return advanced True if the jackpot phase advanced.
    function runPresaleJackpot() external returns (bool advanced);
}

/// @dev Bonds contract game-over status interface.
interface IDegenerusBondsGameOverFlag {
    /// @notice True if final entropy request has been attempted.
    function gameOverEntropyAttempted() external view returns (bool);

    /// @notice True if game-over sequence has started.
    function gameOverStarted() external view returns (bool);
}

/// @dev Game contract liquidity management interface.
interface IDegenerusGameLiquidityAdmin {
    /// @notice Swap owner ETH for game-held stETH (1:1 exchange).
    /// @param recipient Address to receive the stETH.
    /// @param amount Amount of ETH/stETH to swap.
    function adminSwapEthForStEth(address recipient, uint256 amount) external payable;

    /// @notice Stake game-held ETH into stETH via Lido.
    /// @param amount Amount of ETH to stake.
    function adminStakeEthForStEth(uint256 amount) external;
}

/// @dev LINK token interface (ERC-677 with transferAndCall).
interface ILinkTokenLike {
    function balanceOf(address account) external view returns (uint256);

    /// @notice ERC-677 transfer with callback to recipient.
    /// @param to Recipient address (must implement onTokenTransfer).
    /// @param value Amount of LINK to transfer.
    /// @param data Additional data passed to the callback.
    /// @return success True if transfer and callback succeeded.
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool success);
}

/// @dev Coin contract interface for LINK reward credits.
interface IDegenerusCoinPresaleLink {
    /// @notice Credit BURNIE tokens to a player for LINK donation.
    /// @param player Address to credit.
    /// @param amount Amount of BURNIE to credit (6 decimals).
    function creditLinkReward(address player, uint256 amount) external;
}

/// @dev Affiliate contract presale credit interface.
interface IAffiliatePresaleCredit {
    /// @notice Check if presale is currently active.
    function presaleActive() external view returns (bool);

    /// @notice Credit presale BURNIE to a player's escrow.
    /// @param player Address to credit.
    /// @param amount Amount to credit.
    function addPresaleCoinCredit(address player, uint256 amount) external;
}

/// @dev Generic wiring interface for game contracts.
interface IWiring {
    /// @notice Wire contract dependencies.
    /// @param addresses Array of dependency addresses (order varies by contract).
    function wire(address[] calldata addresses) external;
}

/// @dev Chainlink price feed interface (AggregatorV3).
interface IAggregatorV3 {
    /// @notice Get latest price data.
    /// @return roundId The round ID.
    /// @return answer The price (sign and decimals vary by feed).
    /// @return startedAt Timestamp when round started.
    /// @return updatedAt Timestamp when answer was updated.
    /// @return answeredInRound The round ID in which the answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Get the number of decimals in the answer.
    function decimals() external view returns (uint8);
}

/**
 * @title DegenerusAdmin
 * @notice Central admin contract: owns the VRF subscription and performs one-time wiring
 *         for bonds/game/coin/affiliate. Deploy this first, pass its address into other
 *         contracts, and route all wiring through it.
 *
 * @dev TRUST ASSUMPTIONS
 * ─────────────────────────────────────────────────────────────────────────────
 * - The `creator` is a trusted EOA or multisig that won't act maliciously before all contracts are deployed.
 * - The LINK token address is correct and immutable.
 * - External contracts (game, bonds, coin, etc.) are correctly implemented.
 * - Chainlink VRF coordinator and price feeds are trusted oracles.
 *
 * GAS CONSIDERATIONS
 * ─────────────────────────────────────────────────────────────────────────────
 * - wireAll() is gas-intensive (~500k-1M gas) due to multiple external calls.
 * - Should only be called once during initial setup.
 * - Emergency functions are designed for rare use and prioritize safety over gas.
 */
contract DegenerusAdmin {
    // =========================================================================
    // CUSTOM ERRORS
    // =========================================================================
    // Using custom errors for gas efficiency and clear failure reasons.

    /// @dev Caller is not the contract creator/owner.
    error NotOwner();

    /// @dev Caller is not authorized for this operation (e.g., wrong token sender).
    error NotAuthorized();

    /// @dev A required address parameter was zero.
    error ZeroAddress();

    /// @dev Array length mismatch in batch operations.
    error LengthMismatch();

    /// @dev VRF is not stalled; emergency recovery not allowed.
    error NotStalled();

    /// @dev Attempting to re-wire an already-wired component.
    error AlreadyWired();

    /// @dev Required component not yet wired.
    error NotWired();

    /// @dev Bonds contract not ready for requested operation.
    error BondsNotReady();

    /// @dev VRF subscription doesn't exist.
    error NoSubscription();

    /// @dev Invalid amount (zero or mismatch).
    error InvalidAmount();

    /// @dev Game-over has started; operation not allowed.
    error GameOver();

    /// @dev Price feed is healthy; replacement not allowed.
    error FeedHealthy();

    /// @dev Game contract not wired yet.
    error GameNotWired();

    // =========================================================================
    // EVENTS
    // =========================================================================
    // Events provide an audit trail for all administrative actions.

    /// @notice Emitted when the VRF coordinator is updated.
    /// @param coordinator New coordinator address.
    /// @param subId Associated subscription ID.
    event CoordinatorUpdated(address indexed coordinator, uint256 indexed subId);

    /// @notice Emitted when a consumer is added to the VRF subscription.
    /// @param consumer Address of the newly added consumer.
    event ConsumerAdded(address indexed consumer);

    /// @notice Emitted when a new VRF subscription is created.
    /// @param subId The newly created subscription ID.
    event SubscriptionCreated(uint256 indexed subId);

    /// @notice Emitted when a VRF subscription is cancelled.
    /// @param subId The cancelled subscription ID.
    /// @param to Address receiving the LINK refund.
    event SubscriptionCancelled(uint256 indexed subId, address indexed to);

    /// @notice Emitted after emergency VRF recovery completes.
    /// @param newCoordinator New coordinator address.
    /// @param newSubId New subscription ID.
    /// @param fundedAmount LINK transferred to new subscription.
    event EmergencyRecovered(address indexed newCoordinator, uint256 indexed newSubId, uint256 fundedAmount);

    /// @notice Emitted when subscription is shutdown and LINK swept.
    /// @param subId The shutdown subscription ID.
    /// @param to Address receiving the LINK.
    /// @param sweptAmount LINK amount swept.
    event SubscriptionShutdown(uint256 indexed subId, address indexed to, uint256 sweptAmount);

    /// @notice Emitted when the coin contract is wired.
    /// @param coin Address of the coin contract.
    event CoinWired(address indexed coin);

    /// @notice Emitted when LINK donation credit is recorded.
    /// @param player Address receiving the credit.
    /// @param amount BURNIE amount credited.
    /// @param minted True if credited to live coin, false if pending.
    event LinkCreditRecorded(address indexed player, uint256 amount, bool minted);

    /// @notice Emitted when LINK/ETH price feed is updated.
    /// @param feed New feed address (zero disables oracle).
    event LinkEthFeedUpdated(address indexed feed);

    /// @notice Emitted when affiliate contract is wired.
    /// @param affiliate Address of the affiliate contract.
    event AffiliateWired(address indexed affiliate);

    /// @notice Emitted when vault address is set.
    /// @param vault Address of the vault.
    event VaultSet(address indexed vault);

    /// @notice Emitted when presale is shutdown.
    event PresaleShutdown();

    /// @notice Emitted when presale jackpot is run.
    /// @param advanced True if jackpot phase advanced.
    event PresaleJackpotRun(bool advanced);

    // =========================================================================
    // IMMUTABLE STATE
    // =========================================================================
    // Set once at construction; cannot be changed.

    /// @notice The contract creator/owner. Set immutably at construction.
    /// @dev No ownership transfer mechanism exists by design — simplifies security model.
    address public immutable creator;

    /// @notice LINK token address (ERC-677 compatible).
    /// @dev Immutable to prevent token address manipulation attacks.
    address public immutable linkToken;

    // =========================================================================
    // WIRING STATE
    // =========================================================================
    // External contract addresses, wired once during setup.

    /// @notice Bonds contract address.
    /// @dev Wired via wireAll(). One-time set with AlreadyWired guard.
    address public bonds;

    /// @notice BURNIE coin contract address.
    /// @dev Wired via wireAll(). One-time set with AlreadyWired guard.
    address public coin;

    /// @notice Affiliate program contract address.
    /// @dev Wired via wireAll(). One-time set with AlreadyWired guard.
    address public affiliate;

    /// @notice Main game contract address.
    /// @dev Wired via wireAll(). One-time set with AlreadyWired guard.
    address public game;

    /// @notice Vault contract address for reward routing.
    /// @dev Wired via wireAll(). One-time set with AlreadyWired guard.
    address public vault;

    // =========================================================================
    // VRF STATE
    // =========================================================================
    // Chainlink VRF subscription management.

    /// @notice Current VRF coordinator address.
    /// @dev Can be updated during emergency recovery (stall-gated).
    address public coordinator;

    /// @notice Current VRF subscription ID.
    /// @dev Created during first wireAll(); can change during emergency recovery.
    uint256 public subscriptionId;

    /// @notice VRF key hash for the current coordinator.
    /// @dev Different coordinators may require different key hashes.
    bytes32 public vrfKeyHash;

    // =========================================================================
    // LINK REWARD STATE
    // =========================================================================
    // Tracks LINK donation rewards before coin is wired.

    /// @notice Pending BURNIE credits for LINK donors (before coin wiring).
    /// @dev Cleared when user calls claimPendingLinkCredit() after coin is wired.
    ///      SECURITY: Uses pull pattern — users claim their own credits.
    mapping(address => uint256) public pendingLinkCredit;

    /// @notice Chainlink LINK/ETH price feed address.
    /// @dev Zero address disables oracle-based valuation.
    ///      Only replaceable if current feed is unhealthy.
    address public linkEthPriceFeed;

    /// @dev True if price needs to be scaled up (feed decimals < 18).
    bool private linkEthPriceScaleUp;

    /// @dev Scale factor for price normalization to 18 decimals.
    uint256 private linkEthPriceScale;

    /// @dev BURNIE conversion constant: 1000 BURNIE = 1e9 base units (6 decimals).
    ///      Used to convert ETH-equivalent value to BURNIE credit amount.
    uint256 private constant PRICE_COIN_UNIT = 1_000_000_000;

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /// @notice Initialize the admin contract.
    /// @param linkToken_ Address of the LINK token (ERC-677).
    /// @dev SECURITY: linkToken_ is set immutably — verify correct address before deploy.
    constructor(address linkToken_) {
        creator = msg.sender;
        linkToken = linkToken_;
    }

    // =========================================================================
    // ACCESS CONTROL
    // =========================================================================

    /// @dev Restricts function to the contract creator only.
    ///      SECURITY: Simple and auditable — no complex role hierarchy.
    modifier onlyOwner() {
        if (msg.sender != creator) revert NotOwner();
        _;
    }

    // =========================================================================
    // INTERNAL WIRING HELPERS
    // =========================================================================

    /// @dev Internal wiring logic: creates VRF subscription if needed, validates parameters.
    /// @param coordinator_ VRF coordinator address (required on first call).
    /// @param bondKeyHash VRF key hash (required).
    ///
    /// SECURITY NOTES:
    /// - First call creates subscription and sets coordinator immutably-ish (can only change via emergency).
    /// - Subsequent calls validate parameters match existing config (AlreadyWired guard).
    /// - Prevents accidental or malicious re-pointing to different coordinator.
    function _wire(address coordinator_, bytes32 bondKeyHash) private {
        if (bonds == address(0)) revert NotWired();

        // Create subscription on first call.
        if (subscriptionId == 0) {
            if (coordinator_ == address(0) || bondKeyHash == bytes32(0)) revert ZeroAddress();
            uint256 subId = IVRFCoordinatorV2_5Owner(coordinator_).createSubscription();
            coordinator = coordinator_;
            subscriptionId = subId;
            emit CoordinatorUpdated(coordinator_, subId);
            emit SubscriptionCreated(subId);
        } else {
            // Prevent accidental re-pointing via a different coordinator.
            if (coordinator_ != address(0) && coordinator_ != coordinator) revert AlreadyWired();
            if (bondKeyHash == bytes32(0)) revert ZeroAddress();
        }

        bytes32 currentKeyHash = vrfKeyHash;
        if (currentKeyHash == bytes32(0)) {
            vrfKeyHash = bondKeyHash;
        } else {
            if (bondKeyHash != currentKeyHash) revert AlreadyWired();
        }
    }

    /// @dev Pack addresses for bonds.wire() call.
    /// @return arr Array of 7 addresses in bonds-expected order.
    function _packBondsWire(
        address game_,
        address vault_,
        address coin_,
        address coord_,
        address questModule_,
        address trophies_,
        address affiliate_
    ) private pure returns (address[] memory arr) {
        arr = new address[](7);
        arr[0] = game_;
        arr[1] = vault_;
        arr[2] = coin_;
        arr[3] = coord_;
        arr[4] = questModule_;
        arr[5] = trophies_;
        arr[6] = affiliate_;
    }

    // =========================================================================
    // MAIN WIRING FUNCTION
    // =========================================================================

    /// @notice Consolidated wiring: creates VRF sub if needed, wires all game contracts.
    /// @dev This is the primary setup function. Call once with all contract addresses.
    ///
    ///      EXECUTION ORDER:
    ///      1. Set bonds address (one-time)
    ///      2. Set vault address (one-time)
    ///      3. Set coin address (one-time)
    ///      4. Set affiliate address (one-time)
    ///      5. Create VRF subscription if needed
    ///      6. Wire game contract with VRF
    ///      7. Wire quest module to game
    ///      8. Add bonds as VRF consumer
    ///      9. Wire bonds with all dependencies
    ///      10. Wire coin, questModule, nft, affiliate, jackpots, trophies
    ///      11. Wire any additional modules from arrays
    ///
    ///      SECURITY NOTES:
    ///      - All address setters use one-time pattern (AlreadyWired guard).
    ///      - try/catch on addConsumer allows graceful handling if already added.
    ///      - External calls are to trusted contracts only.
    ///
    /// @param bonds_ Bonds contract address (required on first call).
    /// @param coordinator_ VRF coordinator address (required on first call).
    /// @param bondKeyHash_ VRF key hash (required on first call).
    /// @param game_ Game contract address.
    /// @param coin_ BURNIE coin contract address.
    /// @param affiliate_ Affiliate program contract address.
    /// @param jackpots_ Jackpots contract address.
    /// @param questModule_ Quest module contract address.
    /// @param trophies_ Trophies contract address.
    /// @param nft_ NFT contract address.
    /// @param vault_ Vault contract address.
    /// @param modules Additional modules to wire.
    /// @param moduleWires Wiring arrays for additional modules (parallel to modules).
    function wireAll(
        address bonds_,
        address coordinator_,
        bytes32 bondKeyHash_,
        address game_,
        address coin_,
        address affiliate_,
        address jackpots_,
        address questModule_,
        address trophies_,
        address nft_,
        address vault_,
        address[] calldata modules,
        address[][] calldata moduleWires
    ) external onlyOwner {
        // --- BONDS WIRING (one-time) ---
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) {
            if (bonds_ == address(0)) revert ZeroAddress();
            bonds = bonds_;
            bondsAddr = bonds_;
        } else if (bonds_ != address(0) && bonds_ != bondsAddr) {
            revert AlreadyWired();
        }

        // --- VAULT WIRING (one-time) ---
        if (vault_ != address(0)) {
            address currentVault = vault;
            if (currentVault == address(0)) {
                vault = vault_;
                emit VaultSet(vault_);
            } else if (currentVault != vault_) {
                revert AlreadyWired();
            }
        }

        // --- COIN WIRING (one-time) ---
        if (coin_ != address(0)) {
            address currentCoin = coin;
            if (currentCoin == address(0)) {
                coin = coin_;
                emit CoinWired(coin_);
            } else if (currentCoin != coin_) {
                revert AlreadyWired();
            }
        }

        // --- AFFILIATE WIRING (one-time) ---
        if (affiliate_ != address(0)) {
            address currentAffiliate = affiliate;
            if (currentAffiliate == address(0)) {
                affiliate = affiliate_;
                emit AffiliateWired(affiliate_);
            } else if (currentAffiliate != affiliate_) {
                revert AlreadyWired();
            }
        }

        // --- VRF SUBSCRIPTION SETUP ---
        // Ensure VRF subscription exists and validate parameters.
        if (subscriptionId == 0) {
            _wire(coordinator_, bondKeyHash_);
        } else {
            if (coordinator_ != address(0) && coordinator_ != coordinator) revert AlreadyWired();
            bytes32 currentKeyHash = vrfKeyHash;
            if (currentKeyHash == bytes32(0)) {
                if (bondKeyHash_ == bytes32(0)) revert ZeroAddress();
                vrfKeyHash = bondKeyHash_;
            } else {
                if (bondKeyHash_ != bytes32(0) && bondKeyHash_ != currentKeyHash) revert AlreadyWired();
            }
        }

        address coord = coordinator_ == address(0) ? coordinator : coordinator_;
        bytes32 keyHash = vrfKeyHash;

        // --- GAME WIRING ---
        if (game_ != address(0)) {
            address currentGame = game;
            if (currentGame == address(0)) {
                game = game_;
            } else if (currentGame != game_) {
                revert AlreadyWired();
            }

            // Add game as VRF consumer. try/catch handles already-added case.
            try IVRFCoordinatorV2_5Owner(coord).addConsumer(subscriptionId, game_) {
                emit ConsumerAdded(game_);
            } catch {}

            if (keyHash == bytes32(0)) revert NotWired();
            IDegenerusGameVrf(game_).wireVrf(coord, subscriptionId, keyHash);
        }

        // --- QUEST MODULE → GAME WIRING ---
        address gameAddr = game_ == address(0) ? game : game_;
        if (questModule_ != address(0) && gameAddr != address(0)) {
            IDegenerusGameQuest(gameAddr).wireQuestModule(questModule_);
        }

        // --- BONDS VRF CONSUMER + WIRING ---
        // Add bonds as VRF consumer.
        try IVRFCoordinatorV2_5Owner(coord).addConsumer(subscriptionId, bondsAddr) {
            emit ConsumerAdded(bondsAddr);
        } catch {}

        // Wire bonds with all its dependencies.
        IDegenerusBondsAdmin(bondsAddr).wire(
            _packBondsWire(game_, vault_, coin_, coord, questModule_, trophies_, affiliate_),
            subscriptionId,
            keyHash
        );

        // --- DOWNSTREAM CONTRACT WIRING ---
        // Each contract has its own wire() expectations.

        if (coin_ != address(0)) {
            address[] memory coinWire = new address[](4);
            coinWire[0] = game_;
            coinWire[1] = nft_;
            coinWire[2] = questModule_;
            coinWire[3] = jackpots_;
            IWiring(coin_).wire(coinWire);
        }

        if (questModule_ != address(0)) {
            address[] memory questWire = new address[](1);
            questWire[0] = game_;
            IWiring(questModule_).wire(questWire);
        }

        if (nft_ != address(0)) {
            address[] memory nftWire = new address[](1);
            nftWire[0] = game_;
            IWiring(nft_).wire(nftWire);
        }

        if (affiliate_ != address(0)) {
            address[] memory affWire = new address[](3);
            affWire[0] = coin_;
            affWire[1] = game_;
            affWire[2] = nft_;
            IWiring(affiliate_).wire(affWire);
        }

        if (jackpots_ != address(0)) {
            address[] memory jpWire = new address[](3);
            jpWire[0] = coin_;
            jpWire[1] = game_;
            jpWire[2] = affiliate_;
            IWiring(jackpots_).wire(jpWire);
        }

        if (trophies_ != address(0)) {
            address[] memory trophyWire = new address[](1);
            trophyWire[0] = game_;
            IWiring(trophies_).wire(trophyWire);
        }

        // --- ADDITIONAL MODULE WIRING ---
        uint256 moduleCount = modules.length;
        if (moduleCount != moduleWires.length) revert LengthMismatch();
        for (uint256 i; i < moduleCount;) {
            address module = modules[i];
            if (module == address(0)) revert ZeroAddress();
            IWiring(module).wire(moduleWires[i]);
            unchecked {
                ++i;
            }
        }
    }

    // =========================================================================
    // PRICE FEED MANAGEMENT
    // =========================================================================

    /// @notice Configure the LINK/ETH price feed for LINK donation valuation.
    /// @dev Zero address disables oracle-based valuation (LINK donations earn no rewards).
    ///      Only replaceable if current feed is unhealthy (prevents unnecessary changes).
    ///
    ///      SECURITY NOTES:
    ///      - FeedHealthy guard prevents changing a working feed.
    ///      - Decimal normalization handles feeds with different precisions.
    ///      - Invalid feed data (answer <= 0) causes _linkAmountToEth to return 0.
    ///
    /// @param feed New price feed address (zero to disable).
    function setLinkEthPriceFeed(address feed) external onlyOwner {
        address current = linkEthPriceFeed;
        // Only allow replacement if current feed is unhealthy or doesn't exist.
        if (current != address(0) && _feedHealthy(current)) revert FeedHealthy();
        linkEthPriceFeed = feed;

        if (feed == address(0)) {
            linkEthPriceScale = 0;
            linkEthPriceScaleUp = true;
            emit LinkEthFeedUpdated(feed);
            return;
        }

        // Configure decimal scaling for price normalization.
        uint8 dec = IAggregatorV3(feed).decimals();
        if (dec <= 18) {
            linkEthPriceScale = 10 ** (18 - dec);
            linkEthPriceScaleUp = true;
        } else {
            linkEthPriceScale = 10 ** (dec - 18);
            linkEthPriceScaleUp = false;
        }

        emit LinkEthFeedUpdated(feed);
    }

    // =========================================================================
    // PRESALE ADMINISTRATION
    // =========================================================================

    /// @notice Permanently disable presale bond purchases.
    /// @dev One-way operation; cannot be undone.
    function shutdownPresale() external onlyOwner {
        address bondsAddr = bonds;
        IDegenerusBondsPresaleAdmin(bondsAddr).shutdownPresale();
        emit PresaleShutdown();
    }

    /// @notice Trigger the presale jackpot distribution.
    /// @return advanced True if the jackpot phase advanced.
    function runPresaleJackpot() external onlyOwner returns (bool advanced) {
        address bondsAddr = bonds;
        advanced = IDegenerusBondsPresaleAdmin(bondsAddr).runPresaleJackpot();
        emit PresaleJackpotRun(advanced);
    }

    // =========================================================================
    // LIQUIDITY MANAGEMENT
    // =========================================================================

    /// @notice Swap owner ETH for game-held stETH (1:1 exchange).
    /// @dev Allows owner to provide ETH liquidity in exchange for stETH yield.
    ///
    ///      SECURITY NOTES:
    ///      - msg.value must exactly equal amount parameter.
    ///      - stETH sent to msg.sender (owner), not arbitrary address.
    ///      - Game contract validates the swap internally.
    ///
    /// @param amount Amount of ETH to swap.
    function swapGameEthForStEth(uint256 amount) external payable onlyOwner {
        address gameAddr = game;
        if (gameAddr == address(0)) revert GameNotWired();
        if (amount == 0 || msg.value != amount) revert InvalidAmount();
        IDegenerusGameLiquidityAdmin(gameAddr).adminSwapEthForStEth{value: msg.value}(msg.sender, amount);
    }

    /// @notice Stake game-held ETH into stETH via Lido.
    /// @dev Converts idle ETH to yield-bearing stETH.
    /// @param amount Amount of ETH to stake.
    function stakeGameEthToStEth(uint256 amount) external onlyOwner {
        address gameAddr = game;
        if (gameAddr == address(0)) revert GameNotWired();
        IDegenerusGameLiquidityAdmin(gameAddr).adminStakeEthForStEth(amount);
    }

    // =========================================================================
    // VRF EMERGENCY RECOVERY (Stall-Gated)
    // =========================================================================

    /// @notice Migrate to a new VRF coordinator/subscription after 3-day stall.
    /// @dev Emergency recovery path when Chainlink VRF becomes unavailable.
    ///
    ///      EXECUTION ORDER:
    ///      1. Verify 3-day stall via game.rngStalledForThreeDays()
    ///      2. Cancel old subscription (LINK refunds to this contract)
    ///      3. Create new subscription on new coordinator
    ///      4. Add bonds and game as consumers
    ///      5. Push new config to bonds and game
    ///      6. Transfer any LINK balance to new subscription
    ///
    ///      SECURITY NOTES:
    ///      - 3-day stall requirement prevents premature migration.
    ///      - try/catch on cancelSubscription handles edge cases.
    ///      - New coordinator/keyHash must be non-zero.
    ///      - Both bonds and game are updated atomically.
    ///
    /// @param newCoordinator Address of the new VRF coordinator.
    /// @param newKeyHash Key hash for the new coordinator.
    /// @return newSubId The newly created subscription ID.
    function emergencyRecover(
        address newCoordinator,
        bytes32 newKeyHash
    ) external onlyOwner returns (uint256 newSubId) {
        if (subscriptionId == 0) revert NotWired();
        address gameAddr = game;
        // SECURITY: Require provable 3-day VRF stall before allowing migration.
        if (!IDegenerusGameVrf(gameAddr).rngStalledForThreeDays()) revert NotStalled();
        if (newCoordinator == address(0) || newKeyHash == bytes32(0)) revert ZeroAddress();

        uint256 oldSub = subscriptionId;
        address oldCoord = coordinator;

        // Cancel old subscription to recover LINK.
        if (oldSub != 0) {
            try IVRFCoordinatorV2_5Owner(oldCoord).cancelSubscription(oldSub, address(this)) {
                emit SubscriptionCancelled(oldSub, address(this));
            } catch {}
        }

        // Create new subscription.
        coordinator = newCoordinator;
        newSubId = IVRFCoordinatorV2_5Owner(newCoordinator).createSubscription();
        subscriptionId = newSubId;
        vrfKeyHash = newKeyHash;
        emit CoordinatorUpdated(newCoordinator, newSubId);
        emit SubscriptionCreated(newSubId);

        // Add consumers to new subscription.
        try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, bonds) {
            emit ConsumerAdded(bonds);
        } catch {}
        IDegenerusBondsAdmin(bonds).emergencySetVrf(newCoordinator, newSubId, newKeyHash);

        try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, gameAddr) {
            emit ConsumerAdded(gameAddr);
        } catch {}
        // Push new config to game — must succeed to maintain consistency.
        IDegenerusGameVrf(gameAddr).updateVrfCoordinatorAndSub(newCoordinator, newSubId, newKeyHash);

        // Transfer any LINK to new subscription.
        uint256 bal = ILinkTokenLike(linkToken).balanceOf(address(this));
        uint256 funded;
        if (bal != 0) {
            try ILinkTokenLike(linkToken).transferAndCall(newCoordinator, bal, abi.encode(newSubId)) returns (bool ok) {
                if (ok) {
                    funded = bal;
                }
            } catch {}
        }

        emit EmergencyRecovered(newCoordinator, newSubId, funded);
    }

    /// @notice Cancel VRF subscription and sweep LINK after game-over.
    /// @dev Final cleanup function. No VRF stall required — only game-over flag.
    ///
    ///      SECURITY NOTES:
    ///      - Requires gameOverEntropyAttempted() to be true.
    ///      - LINK refunded to specified target address.
    ///      - Sets subscriptionId to 0 to prevent re-use.
    ///
    /// @param target Address to receive the LINK refund.
    function shutdownAndRefund(address target) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        uint256 subId = subscriptionId;
        if (subId == 0) revert NoSubscription();

        // SECURITY: Only allow shutdown after game-over entropy has been attempted.
        if (!IDegenerusBondsGameOverFlag(bonds).gameOverEntropyAttempted()) revert BondsNotReady();

        // Cancel subscription; LINK refunds go to target.
        try IVRFCoordinatorV2_5Owner(coordinator).cancelSubscription(subId, target) {
            emit SubscriptionCancelled(subId, target);
        } catch {}
        subscriptionId = 0;

        // Sweep any LINK sitting on this contract to target.
        uint256 bal = ILinkTokenLike(linkToken).balanceOf(address(this));
        if (bal != 0) {
            try ILinkTokenLike(linkToken).transferAndCall(target, bal, "") {
                emit SubscriptionShutdown(subId, target, bal);
                return;
            } catch {}
        }

        emit SubscriptionShutdown(subId, target, 0);
    }

    // =========================================================================
    // LINK DONATION HANDLING (ERC-677 Callback)
    // =========================================================================

    /// @notice ERC-677 callback: handles LINK donations to fund VRF subscription.
    /// @dev Called automatically when LINK is transferred via transferAndCall().
    ///
    ///      FLOW:
    ///      1. Validate sender is LINK token contract
    ///      2. Forward LINK to VRF subscription
    ///      3. Calculate reward multiplier based on subscription balance
    ///      4. Convert LINK to ETH-equivalent using price feed
    ///      5. Credit BURNIE reward to donor (presale escrow or live coin)
    ///
    ///      SECURITY NOTES:
    ///      - msg.sender validation prevents fake LINK attacks.
    ///      - GameOver guard prevents donations after game ends.
    ///      - Multiplier decreases as subscription fills (incentivizes early donations).
    ///      - No rewards if price feed unavailable.
    ///
    /// @param from Address that sent the LINK.
    /// @param amount Amount of LINK received.
    function onTokenTransfer(address from, uint256 amount, bytes calldata) external {
        // SECURITY: Only accept calls from the LINK token contract.
        if (msg.sender != linkToken) revert NotAuthorized();
        if (amount == 0) revert InvalidAmount();
        if (subscriptionId == 0) revert NotWired();

        // Prevent donations after game-over.
        if (bonds != address(0)) {
            if (IDegenerusBondsGameOverFlag(bonds).gameOverStarted()) revert GameOver();
        }

        // Forward LINK to VRF subscription.
        try ILinkTokenLike(linkToken).transferAndCall(address(coordinator), amount, abi.encode(subscriptionId)) returns (
            bool ok
        ) {
            if (!ok) revert InvalidAmount();
        } catch {
            revert InvalidAmount();
        }

        // Calculate reward using tiered multiplier.
        (uint96 bal,,,, ) = IVRFCoordinatorV2_5Owner(coordinator).getSubscription(subscriptionId);
        uint256 mult = _linkRewardMultiplier(uint256(bal));
        if (mult == 0) return; // No reward if subscription is fully funded.

        // Convert LINK amount to ETH-equivalent.
        uint256 ethEquivalent = _linkAmountToEth(amount);
        if (ethEquivalent == 0) return; // Disable rewards if oracle unavailable.

        // Calculate BURNIE credit.
        uint256 baseCredit = (ethEquivalent * PRICE_COIN_UNIT) / 1 ether;
        uint256 credit = (baseCredit * mult) / 1e18;
        if (credit == 0) return;

        bool minted;
        bool presaleCredited;
        address affiliateAddr = affiliate;

        // Try presale escrow first if available.
        if (affiliateAddr != address(0)) {
            try IAffiliatePresaleCredit(affiliateAddr).presaleActive() returns (bool active) {
                if (active) {
                    IAffiliatePresaleCredit(affiliateAddr).addPresaleCoinCredit(from, credit);
                    presaleCredited = true;
                }
            } catch {}
        }

        // If not presale, credit to live coin or pending balance.
        if (!presaleCredited) {
            if (coin != address(0)) {
                IDegenerusCoinPresaleLink(coin).creditLinkReward(from, credit);
                minted = true;
            } else {
                // Store pending credit until coin is wired.
                pendingLinkCredit[from] += credit;
                minted = false;
            }
        }
        emit LinkCreditRecorded(from, credit, minted);
    }

    /// @notice Claim pending LINK donation credits after coin is wired.
    /// @dev Pull pattern — users claim their own credits.
    ///
    ///      SECURITY NOTES:
    ///      - Only callable after coin is wired.
    ///      - Clears pending balance before external call (CEI pattern).
    ///      - User can only claim their own balance.
    function claimPendingLinkCredit() external {
        if (coin == address(0)) revert NotWired();
        address player = msg.sender;
        uint256 credit = pendingLinkCredit[player];
        if (credit == 0) return;

        // Clear balance before external call (CEI pattern).
        pendingLinkCredit[player] = 0;
        IDegenerusCoinPresaleLink(coin).creditLinkReward(player, credit);
        bool minted = true;
        emit LinkCreditRecorded(player, credit, minted);
    }

    // =========================================================================
    // INTERNAL HELPERS — LINK VALUATION
    // =========================================================================

    /// @dev Convert LINK amount to ETH-equivalent using price feed.
    /// @param amount LINK amount (18 decimals).
    /// @return ethAmount ETH-equivalent amount (18 decimals), or 0 if unavailable.
    ///
    /// SECURITY NOTES:
    /// - Returns 0 on missing feed, zero amount, invalid price, or zero scale.
    /// - Handles feeds with different decimal precisions.
    /// - Negative price answers are rejected.
    function _linkAmountToEth(uint256 amount) private view returns (uint256 ethAmount) {
        address feed = linkEthPriceFeed;
        if (feed == address(0) || amount == 0) return 0;

        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) return 0;

        uint256 price = uint256(answer);
        uint256 scale = linkEthPriceScale;
        if (scale == 0) return 0;

        // Normalize to 18 decimals.
        uint256 priceWei = linkEthPriceScaleUp ? price * scale : price / scale;

        if (priceWei == 0) return 0;
        ethAmount = (amount * priceWei) / 1 ether;
    }

    /// @dev Calculate reward multiplier based on subscription LINK balance.
    /// @param subBal Current subscription LINK balance (18 decimals).
    /// @return mult Multiplier in 18-decimal fixed point (e.g., 3e18 = 3x).
    ///
    /// TIERED STRUCTURE:
    /// - 0-200 LINK: Linear 3x → 1x (incentivizes early donations)
    /// - 200-1000 LINK: Linear 1x → 0x (diminishing returns)
    /// - 1000+ LINK: 0x (no reward, subscription is fully funded)
    function _linkRewardMultiplier(uint256 subBal) private pure returns (uint256 mult) {
        if (subBal >= 1000 ether) return 0; // Fully funded, no reward.
        if (subBal <= 200 ether) {
            // Linear from 3x at 0 LINK down to 1x at 200 LINK.
            uint256 delta = (subBal * 2e18) / 200 ether;
            return 3e18 - delta;
        }
        // Between 200 and 1000 LINK: decay from 1x to 0x.
        uint256 excess = subBal - 200 ether;
        uint256 delta2 = (excess * 1e18) / 800 ether;
        return delta2 >= 1e18 ? 0 : 1e18 - delta2;
    }

    /// @dev Check if a price feed is healthy (fresh and valid).
    /// @param feed Price feed address.
    /// @return True if feed is responding with valid, fresh data.
    ///
    /// HEALTH CHECKS:
    /// - answer > 0 (positive price)
    /// - updatedAt != 0 (has been updated)
    /// - answeredInRound >= roundId (not stale round)
    function _feedHealthy(address feed) private view returns (bool) {
        if (feed == address(0)) return false;
        try IAggregatorV3(feed).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256, /*startedAt*/
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) return false;
            return true;
        } catch {
            return false;
        }
    }
}
