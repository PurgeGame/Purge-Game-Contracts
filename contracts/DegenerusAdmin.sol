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
    function wireVrf(address coordinator_, uint256 subId, bytes32 keyHash_) external;
}

interface IDegenerusBondsAdmin {
    function wire(address[] calldata addresses, uint256 vrfSubId, bytes32 vrfKeyHash_) external;
    function emergencySetVrf(address coordinator_, uint256 vrfSubId, bytes32 vrfKeyHash_) external;
}

interface IDegenerusBondsPresaleAdmin {
    function shutdownPresale() external;
    function runPresaleJackpot() external returns (bool advanced);
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
    function creditLinkReward(address player, uint256 amount) external;
}

interface IWiring {
    function wire(address[] calldata addresses) external;
}

interface IDegenerusAffiliateLink {
    function presaleActive() external view returns (bool);
    function addPresaleLinkCredit(address player, uint256 amount) external;
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
    error LengthMismatch();
    error NotStalled();
    error AlreadyWired();
    error NotWired();
    error BondsNotReady();
    error NoSubscription();
    error InvalidAmount();
    error GameOver();
    error FeedHealthy();
    error GameNotWired();

    // -----------------------
    // Events
    // -----------------------
    event CoordinatorUpdated(address indexed coordinator, uint256 indexed subId);
    event ConsumerAdded(address indexed consumer);
    event SubscriptionCreated(uint256 indexed subId);
    event SubscriptionCancelled(uint256 indexed subId, address indexed to);
    event EmergencyRecovered(address indexed newCoordinator, uint256 indexed newSubId, uint256 fundedAmount);
    event SubscriptionShutdown(uint256 indexed subId, address indexed to, uint256 sweptAmount);
    event CoinWired(address indexed coin);
    event LinkCreditRecorded(address indexed player, uint256 amount, bool minted);
    event LinkEthFeedUpdated(address indexed feed);
    event AffiliateWired(address indexed affiliate);
    event VaultSet(address indexed vault);
    event CoinSet(address indexed coin);
    event BondsGameWired(address indexed game);
    event BondsVrfWired(address indexed coordinator, uint256 indexed subId, bytes32 keyHash);
    event PresaleShutdown();
    event PresaleJackpotRun(bool advanced);

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
    bytes32 public vrfKeyHash;
    mapping(address => uint256) public pendingLinkCredit;
    address public linkEthPriceFeed; // Chainlink LINK/ETH price feed (optional; zero address disables)
    uint256 private constant PRICE_COIN_UNIT = 1_000_000_000; // 1000 BURNIE (6 decimals)

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

        // Wire bonds exactly once.
        try IVRFCoordinatorV2_5Owner(coordinator).addConsumer(subscriptionId, bonds) {
            emit ConsumerAdded(bonds);
        } catch {}
        IDegenerusBondsAdmin(bonds).wire(
            _packBondsWire(address(0), address(0), address(0), coordinator, address(0), address(0), address(0)),
            subscriptionId,
            vrfKeyHash
        );
    }

    /// @notice Consolidated wiring helper: creates VRF sub if needed, wires bonds, then downstream modules directly.
    /// @dev Order: bonds must be set; coordinator/keyHash are required when creating the sub. Downstream modules
    ///             are wired here (coin, affiliate, jackpots, quest module, trophies, NFT).
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
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) {
            if (bonds_ == address(0)) revert ZeroAddress();
            bonds = bonds_;
            bondsAddr = bonds_;
        } else if (bonds_ != address(0) && bonds_ != bondsAddr) {
            revert AlreadyWired();
        }

        if (vault_ != address(0)) {
            address currentVault = vault;
            if (currentVault == address(0)) {
                vault = vault_;
                emit VaultSet(vault_);
            } else if (currentVault != vault_) {
                revert AlreadyWired();
            }
        }

        if (coin_ != address(0)) {
            address currentCoin = coin;
            if (currentCoin == address(0)) {
                coin = coin_;
                emit CoinWired(coin_);
            } else if (currentCoin != coin_) {
                revert AlreadyWired();
            }
        }

        if (affiliate_ != address(0)) {
            address currentAffiliate = affiliate;
            if (currentAffiliate == address(0)) {
                affiliate = affiliate_;
                emit AffiliateWired(affiliate_);
            } else if (currentAffiliate != affiliate_) {
                revert AlreadyWired();
            }
        }

        // Ensure VRF subscription exists and bonds are wired to it.
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

        if (game_ != address(0)) {
            address currentGame = game;
            if (currentGame == address(0)) {
                game = game_;
            } else if (currentGame != game_) {
                revert AlreadyWired();
            }

            try IVRFCoordinatorV2_5Owner(coord).addConsumer(subscriptionId, game_) {
                emit ConsumerAdded(game_);
            } catch {}

            if (keyHash == bytes32(0)) revert NotWired();
            IDegenerusGameVrf(game_).wireVrf(coord, subscriptionId, keyHash);
        }

        IDegenerusBondsAdmin(bondsAddr).wire(
            _packBondsWire(game_, vault_, coin_, coord, questModule_, trophies_, affiliate_),
            subscriptionId,
            keyHash
        );

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

        uint256 moduleCount = modules.length;
        if (moduleCount != moduleWires.length) revert LengthMismatch();
        for (uint256 i; i < moduleCount; ) {
            address module = modules[i];
            if (module == address(0)) revert ZeroAddress();
            IWiring(module).wire(moduleWires[i]);
            unchecked {
                ++i;
            }
        }
    }

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

    /// @notice Configure the LINK/ETH price feed used to value LINK donations (zero disables the oracle).
    function setLinkEthPriceFeed(address feed) external onlyOwner {
        address current = linkEthPriceFeed;
        if (current != address(0) && _feedHealthy(current)) revert FeedHealthy();
        linkEthPriceFeed = feed;
        emit LinkEthFeedUpdated(feed);
    }

    /// @notice Pass-through to set bond purchase toggles.
    function shutdownPresale() external onlyOwner {
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) revert NotWired();
        IDegenerusBondsPresaleAdmin(bondsAddr).shutdownPresale();
        emit PresaleShutdown();
    }

    function runPresaleJackpot() external onlyOwner returns (bool advanced) {
        address bondsAddr = bonds;
        if (bondsAddr == address(0)) revert NotWired();
        advanced = IDegenerusBondsPresaleAdmin(bondsAddr).runPresaleJackpot();
        emit PresaleJackpotRun(advanced);
    }

    // -----------------------
    // Subscription management (stall-gated)
    // -----------------------

    /// @notice On a 3-day VRF stall, migrate to a new coordinator/subscription/key hash. Cancels the old sub and moves LINK.
    function emergencyRecover(
        address newCoordinator,
        bytes32 newKeyHash
    ) external onlyOwner returns (uint256 newSubId) {
        if (subscriptionId == 0) revert NotWired();
        address gameAddr = game;
        if (gameAddr == address(0)) revert GameNotWired();
        if (!IDegenerusGameVrf(gameAddr).rngStalledForThreeDays()) revert NotStalled();
        if (newCoordinator == address(0) || newKeyHash == bytes32(0)) revert ZeroAddress();

        uint256 oldSub = subscriptionId;
        address oldCoord = coordinator;

        if (oldSub != 0) {
            try IVRFCoordinatorV2_5Owner(oldCoord).cancelSubscription(oldSub, address(this)) {
                emit SubscriptionCancelled(oldSub, address(this));
            } catch {}
        }

        coordinator = newCoordinator;
        newSubId = IVRFCoordinatorV2_5Owner(newCoordinator).createSubscription();
        subscriptionId = newSubId;
        vrfKeyHash = newKeyHash;
        emit CoordinatorUpdated(newCoordinator, newSubId);
        emit SubscriptionCreated(newSubId);

        try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, bonds) {
            emit ConsumerAdded(bonds);
        } catch {}
        IDegenerusBondsAdmin(bonds).emergencySetVrf(newCoordinator, newSubId, newKeyHash);

        try IVRFCoordinatorV2_5Owner(newCoordinator).addConsumer(newSubId, gameAddr) {
            emit ConsumerAdded(gameAddr);
        } catch {}
        // Push new config into the game; must succeed to keep contracts in sync once wired.
        IDegenerusGameVrf(gameAddr).updateVrfCoordinatorAndSub(newCoordinator, newSubId, newKeyHash);

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

    /// @notice Cancel the VRF subscription and sweep any LINK to the provided target.
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

        uint256 ethEquivalent = _linkAmountToEth(amount);
        if (ethEquivalent == 0) {
            ethEquivalent = amount; // fallback to legacy behavior if oracle unavailable or invalid
        }

        uint256 baseCredit = (ethEquivalent * PRICE_COIN_UNIT) / 1 ether;
        uint256 credit = (baseCredit * mult) / 1e18;
        if (credit == 0) return;

        bool minted;
        // LINK funding rewards are not part of presale claimable; if the coin isn't wired yet, cache them here.
        if (coin != address(0)) {
            IDegenerusCoinPresaleLink(coin).creditLinkReward(from, credit);
            minted = true;
        } else {
            pendingLinkCredit[from] += credit;
            minted = false;
        }
        emit LinkCreditRecorded(from, credit, minted);
    }

    /// @notice Claim any pending LINK-based credit recorded before the coin was wired.
    function claimPendingLinkCredit() external {
        if (coin == address(0)) revert NotWired();
        address player = msg.sender;
        uint256 credit = pendingLinkCredit[player];
        if (credit == 0) return;
        pendingLinkCredit[player] = 0;
        IDegenerusCoinPresaleLink(coin).creditLinkReward(player, credit);
        bool minted = true;
        emit LinkCreditRecorded(player, credit, minted);
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
