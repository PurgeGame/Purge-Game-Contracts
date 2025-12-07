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
    function updateVrfCoordinatorAndSub(address newCoordinator, uint256 newSubId, bytes32 newKeyHash) external;
    function wireInitialVrf(address coordinator_, uint256 subId) external;
}

interface IPurgeBondsVrf {
    function wireBondVrf(address coordinator_, uint256 subId, bytes32 keyHash_) external;
}

interface ILinkTokenLike {
    function balanceOf(address account) external view returns (uint256);
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);
}

interface IPurgeCoinPresaleLink {
    function creditPresaleFromLink(address player, uint256 amount) external;
}

interface IPurgeAffiliatePresalePrice {
    function presalePriceCoinEstimate() external view returns (uint256);
}

/// @notice Minimal Chainlink price feed surface (used for LINK/ETH conversion).
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/**
 * @title PurgeGameVRFSub
 * @notice Holds ownership of the Chainlink VRF subscription and gates sensitive actions behind the game contract.
 *         A single `wire` call always boots bonds and optionally the game (if provided), each exactly once.
 *         After wiring, no actions are available unless the game reports a 3-day RNG stall, in which case
 *         `emergencyRecover` can migrate to a new coordinator/subscription (best-effort LINK refund + top-up).
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
    error InvalidAmount();

    // -----------------------
    // Events
    // -----------------------
    event CoordinatorUpdated(address indexed coordinator, uint256 indexed subId);
    event ConsumerAdded(address indexed consumer);
    event SubscriptionCreated(uint256 indexed subId);
    event SubscriptionCancelled(uint256 indexed subId, address indexed to);
    event EmergencyRecovered(address indexed newCoordinator, uint256 indexed newSubId, uint256 fundedAmount);
    event SubscriptionShutdown(uint256 indexed subId, address indexed to, uint256 sweptAmount);
    event CoinWired(address indexed coin, uint256 priceCoinUnit);
    event LinkCreditRecorded(address indexed player, uint256 amount, bool minted);
    event LinkEthFeedUpdated(address indexed feed);
    event AffiliateWired(address indexed affiliate);

    // -----------------------
    // Storage
    // -----------------------
    address public immutable bonds;
    address public immutable linkToken;
    address public coin;
    address public affiliate;

    address public coordinator;
    address public game;
    uint256 public subscriptionId;
    bool public wired; // true once a subscription exists
    bool public bondsWired; // true once bonds are added as consumer + configured
    bool public gameWired; // true once the game consumer has been added + configured
    bool public coinWired; // true once the coin contract is set
    uint256 public linkRewardPriceCoin = 1_000_000_000; // default to game priceCoin unit
    mapping(address => uint256) public pendingLinkCredit;
    address public linkEthPriceFeed; // Chainlink LINK/ETH price feed (optional; zero address disables)

    // -----------------------
    // Constructor
    // -----------------------

    constructor(address bonds_, address linkToken_) {
        bonds = bonds_;
        linkToken = linkToken_;
    }

    // -----------------------
    // Modifiers
    // -----------------------

    modifier onlyBonds() {
        if (msg.sender != bonds) revert NotBonds();
        _;
    }

    // -----------------------
    // Wiring
    // -----------------------

    /// @notice Single entrypoint: create the subscription (if needed), wire bonds (always), and wire game if provided.
    /// @dev Bonds are always wired on the first call. If `game_` is nonzero and the game is not yet wired, it will be added as a consumer.
    function wire(address game_, address coordinator_, bytes32 bondKeyHash) external onlyBonds {
        // Create subscription on first call.
        if (!wired) {
            if (coordinator_ == address(0) || bondKeyHash == bytes32(0)) revert ZeroAddress();
            uint256 subId = IVRFCoordinatorV2_5Owner(coordinator_).createSubscription();
            coordinator = coordinator_;
            subscriptionId = subId;
            wired = true;
            emit CoordinatorUpdated(coordinator_, subId);
            emit SubscriptionCreated(subId);
        } else {
            // Prevent accidental re-pointing via a different coordinator.
            if (coordinator_ != address(0) && coordinator_ != coordinator) revert AlreadyWired();
            // Reuse bondKeyHash from first wire; require nonzero only if bonds not wired yet.
            if (!bondsWired && bondKeyHash == bytes32(0)) revert ZeroAddress();
        }

        // Wire bonds exactly once.
        if (!bondsWired) {
            IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subscriptionId, bonds);
            emit ConsumerAdded(bonds);
            IPurgeBondsVrf(bonds).wireBondVrf(coordinator, subscriptionId, bondKeyHash);
            bondsWired = true;
        }

        // Wire game if provided and not yet wired.
        if (game_ != address(0) && !gameWired) {
            game = game_;
            IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subscriptionId, game_);
            emit ConsumerAdded(game_);
            IPurgeGameVrf(game_).wireInitialVrf(coordinator, subscriptionId);
            gameWired = true;
        } else if (gameWired && game_ != address(0) && game != game_) {
            revert AlreadyWired(); // game already set; ignore mismatched wiring attempts
        }
    }

    /// @notice Wire the coin contract for link-based minting/claiming and optionally update the price unit.
    function wireCoin(address coin_, uint256 priceCoinUnit) external onlyBonds {
        if (coinWired && coin_ != coin) revert AlreadyWired();
        if (coin_ != address(0)) {
            coin = coin_;
            coinWired = true;
        }
        if (priceCoinUnit != 0) {
            linkRewardPriceCoin = priceCoinUnit;
        }
        emit CoinWired(coin, linkRewardPriceCoin);
    }

    /// @notice Wire the affiliate contract used to estimate presale priceCoin before the game is live.
    function wireAffiliate(address affiliate_) external onlyBonds {
        if (affiliate != address(0) && affiliate_ != affiliate) revert AlreadyWired();
        if (affiliate_ == address(0)) revert ZeroAddress();
        affiliate = affiliate_;
        emit AffiliateWired(affiliate_);
    }

    /// @notice Configure the LINK/ETH price feed used to value LINK donations (zero disables the oracle).
    function setLinkEthPriceFeed(address feed) external onlyBonds {
        linkEthPriceFeed = feed;
        emit LinkEthFeedUpdated(feed);
    }

    /// @notice Add the game as a consumer after bonds have already been wired (via wireBondsOnly).
    function wireGame(address game_) external onlyBonds {
        if (!wired) revert NotWired();
        if (gameWired) revert AlreadyWired();
        if (game_ == address(0)) revert ZeroAddress();

        game = game_;
        gameWired = true;

        IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subscriptionId, game_);
        emit ConsumerAdded(game_);

        IPurgeGameVrf(game_).wireInitialVrf(coordinator, subscriptionId);
    }

    // -----------------------
    // Subscription management (stall-gated)
    // -----------------------

    /// @notice On a 3-day VRF stall, migrate to a new coordinator/subscription/key hash. Best-effort cancel + LINK top-up.
    function emergencyRecover(
        address newCoordinator,
        bytes32 newKeyHash
    ) external onlyBonds returns (uint256 newSubId) {
        if (!wired) revert NotWired();
        if (gameWired && game != address(0) && !IPurgeGameVrf(game).rngStalledForThreeDays()) revert NotStalled();
        if (newCoordinator == address(0) || newKeyHash == bytes32(0)) revert ZeroAddress();

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

        if (bondsWired) {
            try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, bonds) {
                emit ConsumerAdded(bonds);
            } catch {}
            IPurgeBondsVrf(bonds).wireBondVrf(newCoordinator, newSubId, newKeyHash);
        }
        if (gameWired && game != address(0)) {
            // Add the game as consumer; ignore failure to avoid blocking recovery.
            try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, game) {
                emit ConsumerAdded(game);
            } catch {}
            // Push new config into the game; must succeed to keep contracts in sync once wired.
            IPurgeGameVrf(game).updateVrfCoordinatorAndSub(newCoordinator, newSubId, newKeyHash);
        }

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
    /// @dev Callable by bonds once endgame is complete to refund unused LINK. No RNG stall required.
    function shutdownAndRefund(address target) external onlyBonds {
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

    // -----------------------
    // LINK funding + rewards
    // -----------------------

    function onTokenTransfer(address from, uint256 amount, bytes calldata) external {
        if (msg.sender != linkToken) revert NotBonds();
        if (amount == 0) revert InvalidAmount();
        if (!wired) revert NotWired();

        // Top up subscription.
        try ILinkTokenLike(linkToken).transferAndCall(address(coordinator), amount, abi.encode(subscriptionId)) returns (bool ok) {
            if (!ok) revert InvalidAmount();
        } catch {
            revert InvalidAmount();
        }

        // Compute credit using the same tier logic as the game.
        (uint96 bal, , , , ) = IVRFCoordinatorV2_5Owner(coordinator).getSubscription(subscriptionId);
        uint256 mult = _linkRewardMultiplier(uint256(bal));
        if (mult == 0) return;

        uint256 priceCoinUnit = _presalePriceCoin();
        if (priceCoinUnit == 0) {
            priceCoinUnit = linkRewardPriceCoin;
        }

        uint256 ethEquivalent = _linkAmountToEth(amount);
        if (ethEquivalent == 0) {
            ethEquivalent = amount; // fallback to legacy behavior if oracle unavailable or invalid
        }

        uint256 baseCredit = (ethEquivalent * priceCoinUnit) / 1 ether;
        uint256 credit = (baseCredit * mult) / 1e18;
        if (credit == 0) return;

        if (coinWired && coin != address(0)) {
            IPurgeCoinPresaleLink(coin).creditPresaleFromLink(from, credit);
            emit LinkCreditRecorded(from, credit, true);
        } else {
            pendingLinkCredit[from] += credit;
            emit LinkCreditRecorded(from, credit, false);
        }
    }

    /// @notice Claim any pending LINK-based credit recorded before the coin was wired.
    function claimPendingLinkCredit() external {
        if (!coinWired || coin == address(0)) revert NotWired();
        address player = msg.sender;
        uint256 credit = pendingLinkCredit[player];
        if (credit == 0) return;
        pendingLinkCredit[player] = 0;
        IPurgeCoinPresaleLink(coin).creditPresaleFromLink(player, credit);
        emit LinkCreditRecorded(player, credit, true);
    }

    /// @dev Convert LINK amount to equivalent ETH using the configured price feed. Returns 0 on missing/invalid feed.
    function _linkAmountToEth(uint256 amount) private view returns (uint256 ethAmount) {
        address feed = linkEthPriceFeed;
        if (feed == address(0) || amount == 0) return 0;

        (, int256 answer, , , ) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) return 0;

        uint256 price = uint256(answer);
        uint8 dec = IAggregatorV3(feed).decimals();

        uint256 priceWei;
        if (dec < 18) {
            priceWei = price * (10 ** (18 - dec));
        } else if (dec > 18) {
            priceWei = price / (10 ** (dec - 18));
        } else {
            priceWei = price;
        }

        if (priceWei == 0) return 0;
        ethAmount = (amount * priceWei) / 1 ether;
    }

    /// @dev If the game is not yet wired, try to use the affiliate's presale priceCoin estimate for LINK rewards.
    function _presalePriceCoin() private view returns (uint256 priceCoinUnit) {
        if (gameWired) return 0;
        address aff = affiliate;
        if (aff == address(0)) return 0;
        try IPurgeAffiliatePresalePrice(aff).presalePriceCoinEstimate() returns (uint256 p) {
            return p;
        } catch {
            return 0;
        }
    }

    function _linkRewardMultiplier(uint256 subBal) private pure returns (uint256 mult) {
        if (subBal >= 1000 ether) return 0; // zero reward once fully funded
        if (subBal <= 200 ether) {
            // Linear from 3x at 0 LINK down to 1x at 200 LINK.
            uint256 delta = (subBal * 2e18) / 200 ether;
            return 3e18 - delta;
        }
        // Between 200 and 1000 LINK: decay from 1x at 200 LINK to 0 at 1000 LINK.
        uint256 excess = subBal - 200 ether;
        uint256 delta2 = (excess * 1e18) / 800 ether;
        return delta2 >= 1e18 ? 0 : 1e18 - delta2;
    }
}
