// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGame as IDegenerusGameCore} from "./interfaces/IDegenerusGame.sol";

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

interface IDegenerusGameVrf is IDegenerusGameCore {
    function rngStalledForThreeDays() external view returns (bool);
    function updateVrfCoordinatorAndSub(address newCoordinator, uint256 newSubId, bytes32 newKeyHash) external;
    function wireVrf(address coordinator_, uint256 subId) external;
}

interface IDegenerusBondsAdmin {
    function setVault(address vault_) external;
    function setCoin(address coin_) external;
    function setPurchaseToggles(bool externalEnabled, bool gameEnabled) external;
    function wire(address[] calldata addresses, uint256 vrfSubId, bytes32 vrfKeyHash_) external;
}

interface IDegenerusBondsGameOverFlag {
    function gameOverEntropyAttempted() external view returns (bool);
    function gameOverStarted() external view returns (bool);
}

interface ILinkTokenLike {
    function balanceOf(address account) external view returns (uint256);
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);
}

interface IDegenerusCoinPresaleLink {
    function creditPresaleFromLink(address player, uint256 amount) external;
}

interface IDegenerusCoinWire {
    function wire(address[] calldata addresses) external;
}

interface IDegenerusAffiliateWire {
    function wire(address[] calldata addresses) external;
}

interface IDegenerusJackpotsWire {
    function wire(address[] calldata addresses) external;
}

interface IDegenerusAffiliatePresalePrice {
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
 * @title DegenerusAdmin
 * @notice Central admin contract: owns the VRF subscription and performs one-time wiring for bonds/game/coin/affiliate.
 *         Deploy this first, pass its address into other contracts, and route all wiring through it.
 */
contract DegenerusAdmin {
    // -----------------------
    // Errors
    // -----------------------
    error NotOwner();
    error NotAuthorized();
    error ZeroAddress();
    error NotStalled();
    error AlreadyWired();
    error NotWired();
    error BondsNotReady();
    error NoSubscription();
    error InvalidAmount();
    error GameOver();
    error FeedHealthy();

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
    event VaultSet(address indexed vault);
    event CoinSet(address indexed coin);
    event PurchaseTogglesSet(bool externalEnabled, bool gameEnabled);
    event BondsGameWired(address indexed game);
    event BondsVrfWired(address indexed coordinator, uint256 indexed subId, bytes32 keyHash);

    // -----------------------
    // Storage
    // -----------------------
    address public immutable creator;
    address public bonds;
    address public immutable linkToken;
    address public coin;
    address public affiliate;
    address public game;
    address public vault;

    address public coordinator;
    uint256 public subscriptionId;
    uint256 public linkRewardPriceCoin = 1_000_000_000; // default to game priceCoin unit
    mapping(address => uint256) public pendingLinkCredit;
    address public linkEthPriceFeed; // Chainlink LINK/ETH price feed (optional; zero address disables)

    // -----------------------
    // Constructor
    // -----------------------

    constructor(address linkToken_) {
        if (linkToken_ == address(0)) revert ZeroAddress();
        creator = msg.sender;
        linkToken = linkToken_;
    }

    // -----------------------
    // Modifiers
    // -----------------------

    modifier onlyOwner() {
        if (msg.sender != creator) revert NotOwner();
        _;
    }

    // -----------------------
    // Wiring
    // -----------------------

    /// @notice One-time bonding of the bonds contract address after deploy.
    function setBonds(address bonds_) external onlyOwner {
        if (bonds != address(0)) revert AlreadyWired();
        if (bonds_ == address(0)) revert ZeroAddress();
        bonds = bonds_;
    }

    /// @notice Create the subscription (if needed) and wire bonds.
    function wire(address coordinator_, bytes32 bondKeyHash) external onlyOwner {
        _wire(coordinator_, bondKeyHash);
    }

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

        // Wire bonds exactly once.
        try IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subscriptionId, bonds) {
            emit ConsumerAdded(bonds);
        } catch {}
        IDegenerusBondsAdmin(bonds).wire(
            _packBondsWire(address(0), address(0), address(0), coordinator),
            subscriptionId,
            bondKeyHash
        );
    }

    /// @notice Wire the game as a VRF consumer after bonds have been wired.
    function wireGame(address game_) external onlyOwner {
        if (subscriptionId == 0) revert NotWired();
        if (game != address(0)) revert AlreadyWired();
        if (game_ == address(0)) revert ZeroAddress();

        game = game_;

        IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subscriptionId, game_);
        emit ConsumerAdded(game_);

        IDegenerusGameVrf(game_).wireVrf(coordinator, subscriptionId);
        IDegenerusBondsAdmin(bonds).wire(_packBondsWire(game_, address(0), address(0), address(0)), 0, bytes32(0));
    }

    /// @notice Consolidated wiring helper: creates VRF sub if needed, wires bonds, then downstream modules directly.
    /// @dev Order: bonds must be set; coordinator/keyHash are required when creating the sub. Downstream modules
    ///             are wired here (coin, affiliate, jackpots, quest module, NFT).
    function wireAll(
        address coordinator_,
        bytes32 bondKeyHash_,
        address game_,
        address coin_,
        address affiliate_,
        address jackpots_,
        address questModule_,
        address nft_,
        address vault_
    ) external onlyOwner {
        if (bonds == address(0)) revert NotWired();

        // Ensure VRF subscription exists and bonds are wired to it.
        if (subscriptionId == 0) {
            _wire(coordinator_, bondKeyHash_);
        } else {
            if (coordinator_ != address(0) && coordinator_ != coordinator) revert AlreadyWired();
        }

        address coord = coordinator_ == address(0) ? coordinator : coordinator_;
        IDegenerusBondsAdmin(bonds).wire(_packBondsWire(game_, vault_, coin_, coord), subscriptionId, bondKeyHash_);

        if (coin_ != address(0)) {
            address[] memory coinWire = new address[](5);
            coinWire[0] = game_;
            coinWire[1] = nft_;
            coinWire[2] = questModule_;
            coinWire[3] = jackpots_;
            coinWire[4] = address(this); // vrfSub (admin) for LINK reward minting
            try IDegenerusCoinWire(coin_).wire(coinWire) {} catch {}
        }

        if (affiliate_ != address(0)) {
            address[] memory affWire = new address[](2);
            affWire[0] = coin_;
            affWire[1] = game_;
            try IDegenerusAffiliateWire(affiliate_).wire(affWire) {} catch {}
        }

        if (jackpots_ != address(0)) {
            address[] memory jpWire = new address[](2);
            jpWire[0] = coin_;
            jpWire[1] = game_;
            try IDegenerusJackpotsWire(jackpots_).wire(jpWire) {} catch {}
        }
    }

    function _packBondsWire(
        address game_,
        address vault_,
        address coin_,
        address coord_
    ) private pure returns (address[] memory arr) {
        arr = new address[](4);
        arr[0] = game_;
        arr[1] = vault_;
        arr[2] = coin_;
        arr[3] = coord_;
    }

    /// @notice Wire the coin contract for link-based minting/claiming and optionally update the price unit.
    function wireCoin(address coin_, uint256 priceCoinUnit) external onlyOwner {
        if (coin != address(0) && coin_ != coin) revert AlreadyWired();
        if (coin_ != address(0)) {
            coin = coin_;
        }
        if (priceCoinUnit != 0) {
            linkRewardPriceCoin = priceCoinUnit;
        }
        emit CoinWired(coin, linkRewardPriceCoin);
    }

    /// @notice Wire the affiliate contract used to estimate presale priceCoin before the game is live.
    function wireAffiliate(address affiliate_) external onlyOwner {
        if (affiliate != address(0) && affiliate_ != affiliate) revert AlreadyWired();
        if (affiliate_ == address(0)) revert ZeroAddress();
        affiliate = affiliate_;
        emit AffiliateWired(affiliate_);
    }

    /// @notice Configure the LINK/ETH price feed used to value LINK donations (zero disables the oracle).
    function setLinkEthPriceFeed(address feed) external onlyOwner {
        address current = linkEthPriceFeed;
        if (current != address(0) && _feedHealthy(current)) revert FeedHealthy();
        linkEthPriceFeed = feed;
        emit LinkEthFeedUpdated(feed);
    }

    /// @notice Pass-through to set the bonds vault (one-time).
    function setBondsVault(address vault_) external onlyOwner {
        IDegenerusBondsAdmin(bonds).setVault(vault_);
        vault = vault_;
        emit VaultSet(vault_);
    }

    /// @notice Pass-through to set the bonds coin address.
    function setBondsCoin(address coin_) external onlyOwner {
        IDegenerusBondsAdmin(bonds).setCoin(coin_);
        emit CoinSet(coin_);
    }

    /// @notice Pass-through to set bond purchase toggles.
    function setBondsPurchaseToggles(bool externalEnabled, bool gameEnabled) external onlyOwner {
        IDegenerusBondsAdmin(bonds).setPurchaseToggles(externalEnabled, gameEnabled);
        emit PurchaseTogglesSet(externalEnabled, gameEnabled);
    }

    /// @notice Pass-through to set the bond game address.
    function wireBondsGame(address game_) external onlyOwner {
        IDegenerusBondsAdmin(bonds).wire(_packBondsWire(game_, address(0), address(0), address(0)), 0, bytes32(0));
        emit BondsGameWired(game_);
    }

    /// @notice Pass-through to (re)wire bond VRF settings.
    function wireBondsVrf(address coordinator_, bytes32 keyHash_) external onlyOwner {
        uint256 subId = subscriptionId;
        if (subId == 0) revert NotWired();
        IDegenerusBondsAdmin(bonds).wire(
            _packBondsWire(address(0), address(0), address(0), coordinator_),
            subId,
            keyHash_
        );
        emit BondsVrfWired(coordinator_, subId, keyHash_);
    }

    // -----------------------
    // Subscription management (stall-gated)
    // -----------------------

    /// @notice On a 3-day VRF stall, migrate to a new coordinator/subscription/key hash. Best-effort cancel + LINK top-up.
    function emergencyRecover(
        address newCoordinator,
        bytes32 newKeyHash
    ) external onlyOwner returns (uint256 newSubId) {
        if (subscriptionId == 0) revert NotWired();
        if (game != address(0) && !IDegenerusGameVrf(game).rngStalledForThreeDays()) revert NotStalled();
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

        try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, bonds) {
            emit ConsumerAdded(bonds);
        } catch {}
        IDegenerusBondsAdmin(bonds).wire(
            _packBondsWire(address(0), address(0), address(0), newCoordinator),
            newSubId,
            newKeyHash
        );

        if (game != address(0)) {
            // Add the game as consumer; ignore failure to avoid blocking recovery.
            try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, game) {
                emit ConsumerAdded(game);
            } catch {}
            // Push new config into the game; must succeed to keep contracts in sync once wired.
            IDegenerusGameVrf(game).updateVrfCoordinatorAndSub(newCoordinator, newSubId, newKeyHash);
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
    /// @dev Callable once endgame is complete to refund unused LINK. No RNG stall required.
    function shutdownAndRefund(address target) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        uint256 subId = subscriptionId;
        if (subId == 0) revert NoSubscription();
        if (!IDegenerusBondsGameOverFlag(bonds).gameOverEntropyAttempted()) revert BondsNotReady();

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
        if (msg.sender != linkToken) revert NotAuthorized();
        if (amount == 0) revert InvalidAmount();
        if (subscriptionId == 0) revert NotWired();
        if (bonds != address(0)) {
            if (IDegenerusBondsGameOverFlag(bonds).gameOverStarted()) revert GameOver();
        }

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

        if (coin != address(0)) {
            IDegenerusCoinPresaleLink(coin).creditPresaleFromLink(from, credit);
            emit LinkCreditRecorded(from, credit, true);
        } else {
            pendingLinkCredit[from] += credit;
            emit LinkCreditRecorded(from, credit, false);
        }
    }

    /// @notice Claim any pending LINK-based credit recorded before the coin was wired.
    function claimPendingLinkCredit() external {
        if (coin == address(0)) revert NotWired();
        address player = msg.sender;
        uint256 credit = pendingLinkCredit[player];
        if (credit == 0) return;
        pendingLinkCredit[player] = 0;
        IDegenerusCoinPresaleLink(coin).creditPresaleFromLink(player, credit);
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
        if (game != address(0)) return 0;
        address aff = affiliate;
        if (aff == address(0)) return 0;
        try IDegenerusAffiliatePresalePrice(aff).presalePriceCoinEstimate() returns (uint256 p) {
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

    function _feedHealthy(address feed) private view returns (bool) {
        if (feed == address(0)) return false;
        try IAggregatorV3(feed).latestRoundData() returns (uint80 roundId, int256 answer, uint256 /*startedAt*/, uint256 updatedAt, uint80 answeredInRound) {
            if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) return false;
            return true;
        } catch {
            return false;
        }
    }
}
