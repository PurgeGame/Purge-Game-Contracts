// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGame as IPurgeGameCore} from "./interfaces/IPurgeGame.sol";

/// @notice Minimal VRF coordinator surface needed for subscription admin actions.
interface IVRFCoordinatorV2_5Owner {
    function addConsumer(uint256 subId, address consumer) external;
    function cancelSubscription(uint256 subId, address to) external;
    function createSubscription() external returns (uint256 subId);
    function getSubscription(
        uint256 subId
    )
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);
}

interface IPurgeGameVrf is IPurgeGameCore {
    function rngStalledForThreeDays() external view returns (bool);
    function updateVrfCoordinatorAndSub(address newCoordinator, uint256 newSubId) external;
    function wireInitialVrf(address coordinator_, uint256 subId) external;
}

interface ILinkTokenLike {
    function balanceOf(address account) external view returns (uint256);
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);
}

/**
 * @title PurgeGameVRFSub
 * @notice Holds ownership of the Chainlink VRF subscription and gates sensitive actions behind the game contract.
 *         The bond contract triggers `wire` to create the subscription, add the game as consumer, and push VRF config
 *         into the game. After wiring, no actions are available unless the game reports a 3-day RNG stall, in which
 *         case `emergencyRecover` can migrate to a new coordinator/subscription (best-effort LINK refund + top-up).
 */
contract PurgeGameVRFSub {
    // -----------------------
    // Errors
    // -----------------------
    error NotBonds();
    error ZeroAddress();
    error NotStalled();
    error AlreadyWired();
    error NotWired();
    error NoSubscription();
    error NoVault();

    // -----------------------
    // Events
    // -----------------------
    event CoordinatorUpdated(address indexed coordinator, uint256 indexed subId);
    event ConsumerAdded(address indexed consumer);
    event SubscriptionCreated(uint256 indexed subId);
    event SubscriptionCancelled(uint256 indexed subId, address indexed to);
    event EmergencyRecovered(address indexed newCoordinator, uint256 indexed newSubId, uint256 fundedAmount);
    event SubscriptionShutdown(uint256 indexed subId, address indexed to, uint256 sweptAmount);

    // -----------------------
    // Storage
    // -----------------------
    address public immutable bongs;
    address public immutable linkToken;

    address public coordinator;
    address public game;
    uint256 public subscriptionId;
    bool public wired;

    // -----------------------
    // Constructor
    // -----------------------

    constructor(address coordinator_, address bongs_, address linkToken_) {
        if (coordinator_ == address(0) || bongs_ == address(0) || linkToken_ == address(0)) revert ZeroAddress();
        bongs = bongs_;
        coordinator = coordinator_;
        linkToken = linkToken_;
    }

    // -----------------------
    // Modifiers
    // -----------------------

    modifier onlyBongs() {
        if (msg.sender != bongs) revert NotBonds();
        _;
    }

    // -----------------------
    // Wiring
    // -----------------------

    /// @notice Wire the game address, create the subscription, add consumer, and push VRF config into the game.
    /// @dev Callable by the bond contract once; sets the game address immutably for this owner contract.
    function wire(address game_) external onlyBongs {
        if (wired) revert AlreadyWired();
        if (game_ == address(0)) revert ZeroAddress();
        if (subscriptionId != 0) revert AlreadyWired();

        uint256 subId = IVRFCoordinatorV2_5Owner(coordinator).createSubscription();
        subscriptionId = subId;
        game = game_;
        wired = true;

        emit CoordinatorUpdated(coordinator, subId);
        emit SubscriptionCreated(subId);

        IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subId, game_);
        emit ConsumerAdded(game_);

        IPurgeGameVrf(game_).wireInitialVrf(coordinator, subId);
    }

    // -----------------------
    // Subscription management (stall-gated)
    // -----------------------

    /// @notice On a 3-day VRF stall, migrate to a new coordinator/subscription. Best-effort cancel + LINK top-up.
    function emergencyRecover(address newCoordinator) external onlyBongs returns (uint256 newSubId) {
        if (!wired) revert NotWired();
        if (!IPurgeGameVrf(game).rngStalledForThreeDays()) revert NotStalled();
        if (newCoordinator == address(0)) revert ZeroAddress();

        uint256 oldSub = subscriptionId;
        address oldCoord = coordinator;

        // Best-effort cancel old subscription and reclaim LINK to this contract.
        if (oldSub != 0) {
            try IVRFCoordinatorV2_5Owner(oldCoord).cancelSubscription(oldSub, address(this)) {
                emit SubscriptionCancelled(oldSub, address(this));
            } catch {}
        }

        coordinator = newCoordinator;
        newSubId = IVRFCoordinatorV2_5Owner(newCoordinator).createSubscription();
        subscriptionId = newSubId;
        emit CoordinatorUpdated(newCoordinator, newSubId);
        emit SubscriptionCreated(newSubId);

        // Add the game as consumer; ignore failure to avoid blocking recovery.
        try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, game) {
            emit ConsumerAdded(game);
        } catch {}

        // Push new config into the game; must succeed to keep contracts in sync.
        IPurgeGameVrf(game).updateVrfCoordinatorAndSub(newCoordinator, newSubId);

        // Best-effort fund the new subscription with any LINK held here.
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

    /// @notice Cancel the VRF subscription and sweep any LINK to the provided target (best-effort).
    /// @dev Callable by bongs once endgame is complete to refund unused LINK. No RNG stall required.
    function shutdownAndRefund(address target) external onlyBongs {
        if (target == address(0)) revert NoVault();
        uint256 subId = subscriptionId;
        if (subId == 0) revert NoSubscription();

        // Cancel the subscription; LINK refunds go to the provided target.
        try IVRFCoordinatorV2_5Owner(coordinator).cancelSubscription(subId, target) {
            emit SubscriptionCancelled(subId, target);
        } catch {}

        subscriptionId = 0;

        // Sweep any LINK already sitting on this contract to the target.
        uint256 bal = ILinkTokenLike(linkToken).balanceOf(address(this));
        if (bal != 0) {
            try ILinkTokenLike(linkToken).transferAndCall(target, bal, "") {
                emit SubscriptionShutdown(subId, target, bal);
                return;
            } catch {}
        }

        emit SubscriptionShutdown(subId, target, 0);
    }
}
