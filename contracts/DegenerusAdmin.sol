// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContractAddresses} from "./ContractAddresses.sol";

/**
 * @title DegenerusAdmin
 * @author Burnie Degenerus
 * @notice Central administration contract for the Degenerus ContractAddresses.GAME ecosystem.
 *
 * @dev ARCHITECTURE OVERVIEW
 * -----------------------------------------------------------------------------
 * This contract serves as the single point of authority for:
 *   1. VRF subscription ownership and management
 *   2. Emergency recovery during VRF failures
 *   3. LINK token donation handling with reward multipliers
 *   4. Presale administration functions
 *
 * DEPLOYMENT ORDER:
 *   1. Deploy all contracts using the precomputed ContractAddresses order
 *   2. Call wireVrf() to configure VRF and add the ContractAddresses.GAME consumer
 *
 * OWNERSHIP MODEL:
 *   - Single owner (ContractAddresses.CREATOR) set via ContractAddresses
 *   - No ownership transfer capability (intentional simplicity)
 *   - Owner cannot change after deployment
 *
 * VRF SUBSCRIPTION LIFECYCLE:
 *   1. Created during first wireVrf() call (if subId not provided)
 *   2. Consumer (ContractAddresses.GAME) added automatically
 *   3. LINK funding via onTokenTransfer (ERC-677)
 *   4. Emergency recovery if stalled 3+ days
 *   5. Shutdown after ContractAddresses.GAME-over with LINK refund
 *
 * SECURITY CONSIDERATIONS
 * -----------------------------------------------------------------------------
 * 1. CONSTANT OWNER: Creator is fixed and cannot be changed, eliminating
 *    ownership transfer attack vectors.
 *
 * 2. ONE-TIME VRF WIRING: wireVrf() is idempotent to prevent re-pointing
 *    contracts to malicious coordinators after initial setup.
 *
 * 3. STALL-GATED RECOVERY: Emergency VRF migration requires 3-day stall proof
 *    from the ContractAddresses.GAME contract, preventing premature or malicious migration.
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
/// @dev Bonds contract admin interface.
interface IDegenerusBondsAdmin {
    /// @notice Configure the target stETH share (in bps) for ContractAddresses.GAME-held liquidity; 0 disables staking.
    function setRewardStakeTargetBps(uint16 bps) external;
}

/// @dev Bonds contract presale admin interface.
interface IDegenerusBondsPresaleAdmin {
    /// @notice Queue presale shutdown after the next jackpot time.
    function shutdownPresale() external;
}

/// @dev Game contract presale minting interface.
interface IDegenerusGamePresaleMinting {
    /// @notice Enable or disable presale minting (tokens/maps).
    function setPresaleMintingEnabled(bool enabled) external;
}

/// @dev Bonds contract ContractAddresses.GAME-over status interface.
interface IDegenerusBondsGameOverFlag {
    /// @notice True if final entropy request has been attempted.
    function gameOverEntropyAttempted() external view returns (bool);

    /// @notice True if ContractAddresses.GAME-over sequence has started.
    function gameOverStarted() external view returns (bool);
}

/// @dev Game contract liquidity management interface.
interface IDegenerusGameLiquidityAdmin {
    /// @notice Swap owner ETH for ContractAddresses.GAME-held stETH (1:1 exchange).
    /// @param recipient Address to receive the stETH.
    /// @param amount Amount of ETH/stETH to swap.
    function adminSwapEthForStEth(address recipient, uint256 amount) external payable;

    /// @notice Stake ContractAddresses.GAME-held ETH into stETH via Lido.
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
    /// @param amount Amount of BURNIE to credit (18 decimals).
    function creditLinkReward(address player, uint256 amount) external;
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
 * @notice Central admin contract: owns the VRF subscription and wires VRF
 *         configuration for the ContractAddresses.GAME. Deployed using precomputed constants.
 *
 * @dev TRUST ASSUMPTIONS
 * -----------------------------------------------------------------------------
 * - The `ContractAddresses.CREATOR` is a trusted EOA or multisig that won't act maliciously before all contracts are deployed.
 * - The LINK token address is correct and constant.
 * - External contracts (ContractAddresses.GAME, ContractAddresses.BONDS, ContractAddresses.COIN, etc.) are correctly implemented.
 * - Chainlink VRF coordinator and price feeds are trusted oracles.
 *
 * GAS CONSIDERATIONS
 * -----------------------------------------------------------------------------
 * - wireVrf() adds the ContractAddresses.GAME consumer and sets VRF config; should only be called once.
 * - Should only be called once during initial setup.
 * - Emergency functions are designed for rare use and prioritize safety over gas.
 */
contract DegenerusAdmin {
    // =========================================================================
    // CUSTOM ERRORS
    // =========================================================================
    // Using custom errors for gas efficiency and clear failure reasons.

    /// @dev Caller is not the contract ContractAddresses.CREATOR/owner.
    error NotOwner();

    /// @dev Caller is not authorized for this operation (e.g., wrong token sender).
    error NotAuthorized();

    /// @dev A required address parameter was zero.
    error ZeroAddress();

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

    /// @notice Emitted when LINK donation credit is recorded.
    /// @param player Address receiving the credit.
    /// @param amount BURNIE amount credited.
    /// @param minted True if credited to live ContractAddresses.COIN, false if presale-escrowed.
    event LinkCreditRecorded(address indexed player, uint256 amount, bool minted);

    /// @notice Emitted when LINK/ETH price feed is updated.
    /// @param feed New feed address (zero disables oracle).
    event LinkEthFeedUpdated(address indexed feed);

    /// @notice Emitted when presale shutdown is queued.
    event PresaleShutdown();

    // =========================================================================
    // OWNER STATE
    // =========================================================================
    // Set once at construction; cannot be changed.

    /// @notice The contract ContractAddresses.CREATOR/owner. Fixed via ContractAddresses.
    /// @dev No ownership transfer mechanism exists by design — simplifies security model.

    /// @notice LINK token address (ERC-677 compatible).

    // =========================================================================
    // CONSTANT REFERENCES
    // =========================================================================
    // External contract addresses, fixed at deployment.

    /// @notice Bonds contract address.

    /// @notice BURNIE ContractAddresses.COIN contract address.

    /// @notice Main ContractAddresses.GAME contract address.

    /// @notice Vault contract address for reward routing.

    // =========================================================================
    // VRF STATE
    // =========================================================================
    // Chainlink VRF subscription management.

    /// @notice Current VRF coordinator address.
    /// @dev Can be updated during emergency recovery (stall-gated).
    address public coordinator;

    /// @notice Current VRF subscription ID.
    /// @dev Created during first wireVrf(); can change during emergency recovery.
    uint256 public subscriptionId;

    /// @notice VRF key hash for the current coordinator.
    /// @dev Different coordinators may require different key hashes.
    bytes32 public vrfKeyHash;

    // =========================================================================
    // LINK REWARD STATE
    // =========================================================================

    /// @notice Chainlink LINK/ETH price feed address.
    /// @dev Zero address disables oracle-based valuation.
    ///      Only replaceable if current feed is unhealthy.
    address public linkEthPriceFeed;

    /// @dev True if price needs to be scaled up (feed decimals < 18).
    bool private linkEthPriceScaleUp;

    /// @dev Scale factor for price normalization to 18 decimals.
    uint256 private linkEthPriceScale;

    /// @dev BURNIE conversion constant: 1000 BURNIE = 1e21 base units (18 decimals).
    ///      Used to convert ETH-equivalent value to BURNIE credit amount.
    uint256 private constant PRICE_COIN_UNIT = 1000 ether;

    // =========================================================================
    // ACCESS CONTROL
    // =========================================================================

    /// @dev Restricts function to the contract ContractAddresses.CREATOR only.
    ///      SECURITY: Simple and auditable — no complex role hierarchy.
    modifier onlyOwner() {
        if (msg.sender != ContractAddresses.CREATOR) revert NotOwner();
        _;
    }

    // =========================================================================
    // VRF SETUP
    // =========================================================================

    /// @notice Initialize VRF configuration and wire ContractAddresses.GAME consumer.
    /// @dev If subId is zero, a new subscription is created on the coordinator.
    ///      Subsequent calls must match existing config.
    /// @param coordinator_ VRF coordinator address.
    /// @param subId Existing VRF subscription ID (0 to create).
    /// @param bondKeyHash_ VRF key hash (gas lane).
    function wireVrf(address coordinator_, uint256 subId, bytes32 bondKeyHash_) external onlyOwner {
        if (coordinator_ == address(0) || bondKeyHash_ == bytes32(0)) revert ZeroAddress();

        if (subscriptionId == 0) {
            if (subId == 0) {
                subId = IVRFCoordinatorV2_5Owner(coordinator_).createSubscription();
                emit SubscriptionCreated(subId);
            }
            coordinator = coordinator_;
            subscriptionId = subId;
            vrfKeyHash = bondKeyHash_;
            emit CoordinatorUpdated(coordinator_, subId);
        } else {
            if (coordinator_ != coordinator) revert AlreadyWired();
            if (subId != 0 && subId != subscriptionId) revert AlreadyWired();
            if (bondKeyHash_ != vrfKeyHash) revert AlreadyWired();
            if (subId == 0) {
                subId = subscriptionId;
            }
        }

        address gameAddr = ContractAddresses.GAME;

        // Add consumers; try/catch handles already-added case.
        try IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subscriptionId, gameAddr) {
            emit ConsumerAdded(gameAddr);
        } catch {}

        IDegenerusGameVrf(gameAddr).wireVrf(coordinator, subscriptionId, vrfKeyHash);
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

    /// @notice Queue presale shutdown after the next jackpot time.
    function shutdownPresale() external onlyOwner {
        address bondsAddr = ContractAddresses.BONDS;
        IDegenerusBondsPresaleAdmin(bondsAddr).shutdownPresale();
        emit PresaleShutdown();
    }

    /// @notice Enable or disable presale minting (tokens/maps).
    function setPresaleMintingEnabled(bool enabled) external onlyOwner {
        address gameAddr = ContractAddresses.GAME;
        IDegenerusGamePresaleMinting(gameAddr).setPresaleMintingEnabled(enabled);
    }

    // =========================================================================
    // BONDS ADMINISTRATION
    // =========================================================================

    /// @notice Configure the target stETH share (in bps) for ContractAddresses.GAME-held liquidity; 0 disables staking.
    function setRewardStakeTargetBps(uint16 bps) external onlyOwner {
        address bondsAddr = ContractAddresses.BONDS;
        IDegenerusBondsAdmin(bondsAddr).setRewardStakeTargetBps(bps);
    }

    // =========================================================================
    // LIQUIDITY MANAGEMENT
    // =========================================================================

    /// @notice Swap owner ETH for ContractAddresses.GAME-held stETH (1:1 exchange).
    /// @dev Allows owner to provide ETH liquidity in exchange for stETH yield.
    ///
    ///      SECURITY NOTES:
    ///      - msg.value must exactly equal amount parameter.
    ///      - stETH sent to msg.sender (owner), not arbitrary address.
    ///      - Game contract validates the swap internally.
    ///
    /// @param amount Amount of ETH to swap.
    function swapGameEthForStEth(uint256 amount) external payable onlyOwner {
        address gameAddr = ContractAddresses.GAME;
        if (amount == 0 || msg.value != amount) revert InvalidAmount();
        IDegenerusGameLiquidityAdmin(gameAddr).adminSwapEthForStEth{value: msg.value}(msg.sender, amount);
    }

    /// @notice Stake ContractAddresses.GAME-held ETH into stETH via Lido.
    /// @dev Converts idle ETH to yield-bearing stETH.
    /// @param amount Amount of ETH to stake.
    function stakeGameEthToStEth(uint256 amount) external onlyOwner {
        address gameAddr = ContractAddresses.GAME;
        IDegenerusGameLiquidityAdmin(gameAddr).adminStakeEthForStEth(amount);
    }

    // =========================================================================
    // VRF EMERGENCY RECOVERY (Stall-Gated)
    // =========================================================================

    /// @notice Migrate to a new VRF coordinator/subscription after 3-day stall.
    /// @dev Emergency recovery path when Chainlink VRF becomes unavailable.
    ///
    ///      EXECUTION ORDER:
    ///      1. Verify 3-day stall via ContractAddresses.GAME.rngStalledForThreeDays()
    ///      2. Cancel old subscription (LINK refunds to this contract)
    ///      3. Create new subscription on new coordinator
    ///      4. Add ContractAddresses.GAME as consumer
    ///      5. Push new config to game
    ///      6. Transfer any LINK balance to new subscription
    ///
    ///      SECURITY NOTES:
    ///      - 3-day stall requirement prevents premature migration.
    ///      - try/catch on cancelSubscription handles edge cases.
    ///      - New coordinator/keyHash must be non-zero.
    ///      - Game is updated atomically.
    ///
    /// @param newCoordinator Address of the new VRF coordinator.
    /// @param newKeyHash Key hash for the new coordinator.
    /// @return newSubId The newly created subscription ID.
    function emergencyRecover(
        address newCoordinator,
        bytes32 newKeyHash
    ) external onlyOwner returns (uint256 newSubId) {
        if (subscriptionId == 0) revert NotWired();
        address gameAddr = ContractAddresses.GAME;
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
        try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, gameAddr) {
            emit ConsumerAdded(gameAddr);
        } catch {}
        // Push new config to ContractAddresses.GAME — must succeed to maintain consistency.
        IDegenerusGameVrf(gameAddr).updateVrfCoordinatorAndSub(newCoordinator, newSubId, newKeyHash);

        // Transfer any LINK to new subscription.
        uint256 bal = ILinkTokenLike(ContractAddresses.LINK_TOKEN).balanceOf(address(this));
        uint256 funded;
        if (bal != 0) {
            try ILinkTokenLike(ContractAddresses.LINK_TOKEN).transferAndCall(newCoordinator, bal, abi.encode(newSubId)) returns (bool ok) {
                if (ok) {
                    funded = bal;
                }
            } catch {}
        }

        emit EmergencyRecovered(newCoordinator, newSubId, funded);
    }

    /// @notice Cancel VRF subscription and sweep LINK after ContractAddresses.GAME-over.
    /// @dev Final cleanup function. No VRF stall required — only ContractAddresses.GAME-over flag.
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

        // SECURITY: Only allow shutdown after ContractAddresses.GAME-over entropy has been attempted.
        if (!IDegenerusBondsGameOverFlag(ContractAddresses.BONDS).gameOverEntropyAttempted()) revert BondsNotReady();

        // Cancel subscription; LINK refunds go to target.
        try IVRFCoordinatorV2_5Owner(coordinator).cancelSubscription(subId, target) {
            emit SubscriptionCancelled(subId, target);
        } catch {}
        subscriptionId = 0;

        // Sweep any LINK sitting on this contract to target.
        uint256 bal = ILinkTokenLike(ContractAddresses.LINK_TOKEN).balanceOf(address(this));
        if (bal != 0) {
            try ILinkTokenLike(ContractAddresses.LINK_TOKEN).transferAndCall(target, bal, "") {
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
    ///      5. Credit BURNIE reward to donor (live ContractAddresses.COIN)
    ///
    ///      SECURITY NOTES:
    ///      - msg.sender validation prevents fake LINK attacks.
    ///      - GameOver guard prevents donations after ContractAddresses.GAME ends.
    ///      - Multiplier decreases as subscription fills (incentivizes early donations).
    ///      - No rewards if price feed unavailable.
    ///
    /// @param from Address that sent the LINK.
    /// @param amount Amount of LINK received.
    function onTokenTransfer(address from, uint256 amount, bytes calldata) external {
        // SECURITY: Only accept calls from the LINK token contract.
        if (msg.sender != ContractAddresses.LINK_TOKEN) revert NotAuthorized();
        if (amount == 0) revert InvalidAmount();
        if (subscriptionId == 0) revert NotWired();

        // Prevent donations after ContractAddresses.GAME-over.
        if (IDegenerusBondsGameOverFlag(ContractAddresses.BONDS).gameOverStarted()) revert GameOver();

        // Forward LINK to VRF subscription.
        try ILinkTokenLike(ContractAddresses.LINK_TOKEN).transferAndCall(address(coordinator), amount, abi.encode(subscriptionId)) returns (
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

        IDegenerusCoinPresaleLink(ContractAddresses.COIN).creditLinkReward(from, credit);
        emit LinkCreditRecorded(from, credit, true);
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
