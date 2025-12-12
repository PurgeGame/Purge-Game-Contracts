// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusTraitUtils} from "./DegenerusTraitUtils.sol";
import {IDegenerusGame, MintPaymentKind} from "./interfaces/IDegenerusGame.sol";
import {IDegenerusCoin} from "./interfaces/IDegenerusCoin.sol";
import {IDegenerusAffiliate} from "./interfaces/IDegenerusAffiliate.sol";

enum PurchaseKind {
    Player,
    Map
}

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

interface ITokenRenderer {
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory);
}

struct PurchaseParams {
    uint256 quantity;
    PurchaseKind kind;
    MintPaymentKind payKind;
    bool payInCoin;
    bytes32 affiliateCode;
}

interface IDegenerusGamepieces {
    function tokenTraitsPacked(uint256 tokenId) external view returns (uint32);
    function purchaseCount() external view returns (uint32);
    function processPendingMints(
        uint32 playersToProcess,
        uint32 multiplier,
        uint256 rngWord
    ) external returns (bool finished);
    function advanceBase() external;
    function nextTokenId() external view returns (uint256);
    function burnFromGame(address owner, uint256[] calldata tokenIds) external;
    function currentBaseTokenId() external view returns (uint256);
    function tokensOwed(address player) external view returns (uint32);
    function processDormant(uint32 maxCount) external returns (bool worked);
    function clearPlaceholderPadding(uint256 startTokenId, uint256 endTokenId) external;
    function purchase(PurchaseParams calldata params) external payable;
    function purchaseMapForAffiliate(address buyer, uint256 quantity) external;
    function purchaseMapForSynthetic(address synthetic, uint256 quantity, bool payInCoin) external payable;
}

interface IBurnieToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function burnCoin(address target, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title DegenerusGamepieces
/// @notice ERC721 surface for Degenerus player tokens.
/// @dev Uses a packed ownership layout inspired by ERC721A; relies on external wiring from the coin contract
///      to set the trusted game address.
contract DegenerusGamepieces {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ApprovalCallerNotOwnerNorApproved();

    error TransferFromIncorrectOwner();
    error TransferToNonERC721ReceiverImplementer();
    error Zero();
    error E();

    error OnlyCoin();
    error OnlyCoinAdmin();
    error InvalidToken();
    error NotTimeYet();
    error RngNotReady();
    error InvalidQuantity();
    error Expired();
    error Unauthorized();
    error PriceZero();
    error PaymentFailed();
    error InsufficientBalance();

    // ---------------------------------------------------------------------
    // Events & types
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event TokenPurchase(
        address indexed buyer,
        uint32 quantity,
        bool payInCoin,
        bool usedClaimable,
        uint256 costAmount,
        uint256 bonusCoinCredit
    );
    event MapPurchase(
        address indexed buyer,
        uint32 quantity,
        bool payInCoin,
        bool usedClaimable,
        uint256 costAmount,
        uint256 bonusCoinCredit
    );
    event AskPlaced(address indexed seller, uint256 indexed tokenId, uint256 price, uint256 expiry);
    event AskCanceled(address indexed seller, uint256 indexed tokenId);
    event AskFilled(address indexed buyer, address indexed seller, uint256 tokenId, uint256 price);
    event OfferPlaced(address indexed bidder, uint256 indexed tokenId, uint256 amount, uint256 expiry);
    event OfferCanceled(address indexed bidder, uint256 indexed tokenId);
    event OfferFilled(address indexed seller, address indexed buyer, uint256 tokenId, uint256 amount);

    struct Ask {
        address seller; // 160 bits
        uint40 expiry; // 40 bits
        uint256 price;
    }

    struct Offer {
        uint216 amount; // 216 bits
        uint40 expiry; // 40 bits
    }

    struct BestOffer {
        address bidder;
        uint216 amount;
        uint40 expiry;
    }

    // ---------------------------------------------------------------------
    // ERC721 storage
    // ---------------------------------------------------------------------
    // Packed address/ownership layout mirrors ERC721A style: balance/numberMinted/numberBurned are 64-bit fields
    // followed by startTimestamp.
    uint256 private constant _BITMASK_ADDRESS_DATA_ENTRY = (1 << 64) - 1;
    uint256 private constant _BITPOS_NUMBER_MINTED = 64;
    uint256 private constant _BITPOS_NUMBER_BURNED = 128;
    uint256 private constant _BITPOS_START_TIMESTAMP = 160;
    uint256 private constant _BITMASK_BURNED = 1 << 224;
    uint256 private constant _BITMASK_NEXT_INITIALIZED = 1 << 225;
    uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;
    uint256 private constant _BURN_COUNT_INCREMENT_UNIT = (uint256(1) << _BITPOS_NUMBER_BURNED);
    uint256 private constant SPECIAL_TOKEN_ID = 0;
    uint256 private constant BASE_TOKEN_START = 1;

    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    uint256 private _currentIndex;
    uint256 private _burnCounter;
    uint256 private _baseTokenId = BASE_TOKEN_START;

    string private _name = "Degenerus";
    string private _symbol = "DGN";

    mapping(uint256 => uint256) private _packedOwnerships;
    mapping(address => uint256) private _packedAddressData;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ---------------------------------------------------------------------
    // Degenerus game storage
    // ---------------------------------------------------------------------
    IDegenerusGame private game;
    ITokenRenderer private immutable regularRenderer;
    IDegenerusCoin private immutable coin;
    IBurnieToken private immutable burnie;
    address private immutable vault;
    address private immutable affiliateProgram;

    uint32 private _purchaseCount;
    // Pending mint queue holds players that bought tokens before the RNG roll; tokens are minted in batches later.
    address[] private _pendingMintQueue;
    mapping(address => uint32) private _tokensOwed;
    uint256 private _mintQueueIndex; // Tracks # of queue entries fully processed during airdrop rotation

    // Tracks how many level-100 mints (tokens + maps) a player has purchased with ETH for price scaling.
    mapping(address => uint32) private _levelHundredMintCount;

    uint32 private constant MINT_AIRDROP_PLAYER_BATCH_SIZE = 210; // Max unique recipients per airdrop batch
    uint32 private constant MINT_AIRDROP_TOKEN_CAP = 3_000; // Max tokens distributed per airdrop batch

    uint256 private constant CLAIMABLE_BONUS_DIVISOR = 10; // 10% of token coin cost
    uint256 private constant CLAIMABLE_MAP_BONUS_DIVISOR = 40; // 10% of per-map coin cost (priceUnit/4)
    uint256 private constant PRICE_COIN_UNIT = 1_000_000_000;

    uint32 private constant DORMANT_EMIT_BATCH = 3500;
    uint256 private constant OFFER_FEE = 10 * 1e6; // 10 BURNIE (6 decimals)
    uint256 private constant ASK_FEE = 10 * 1e6; // 10 BURNIE
    uint256 private constant BURN_BPS = 200; // 2%
    uint256 private constant BPS_DENOMINATOR = 10_000;

    mapping(uint256 => Ask) private asks;
    mapping(uint256 => mapping(address => Offer)) private offers;
    mapping(uint256 => address[]) private offerBidders;
    mapping(uint256 => mapping(address => bool)) private offerSeen;

    // Cursor over the most-recently-retired level range (used to emit burn Transfer events for indexers).
    uint256 private _dormantCursor;
    uint256 private _dormantEnd;
    uint256 private _dormantPacked;

    function _currentBaseTokenId() private view returns (uint256) {
        return _baseTokenId;
    }

    function nextTokenId() external view returns (uint256) {
        return _currentIndex;
    }

    constructor(address regularRenderer_, address coin_, address affiliateProgram_, address vault_) {
        regularRenderer = ITokenRenderer(regularRenderer_);
        coin = IDegenerusCoin(coin_);
        burnie = IBurnieToken(coin_);
        affiliateProgram = affiliateProgram_;
        vault = vault_;
        _mint(vault, 1); // Mint the eternal token #0 to vault
    }

    /// @notice Total supply = minted tokens (including the eternal token #0) minus burned tokens.
    function totalSupply() external view returns (uint256) {
        if (!_isLiveState()) {
            return 1;
        }
        uint256 minted = _currentIndex;
        uint256 burned = _burnCounter;
        return minted - burned;
    }

    /// @notice Returns balance for standard ERC721 semantics.
    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert Zero();
        if (!_isLiveState()) {
            if (owner == vault) return 1;
            return 0;
        }
        return _packedAddressData[owner] & _BITMASK_ADDRESS_DATA_ENTRY;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 interface ID for ERC165.
            interfaceId == 0x80ac58cd || // ERC165 interface ID for ERC721.
            interfaceId == 0x5b5e139f; // ERC165 interface ID for ERC721Metadata.
    }

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    /// @notice Renders metadata via the regular renderer; reverts for nonexistent/burned tokens.
    /// @dev Uses the regular renderer for all tokens.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        // Revert for nonexistent or burned tokens (keeps ERC721-consistent surface for indexers).
        _packedOwnershipOf(tokenId);

        if (tokenId != SPECIAL_TOKEN_ID && tokenId < _currentBaseTokenId()) revert InvalidToken();

        uint32 traitsPacked = DegenerusTraitUtils.packedTraitsForToken(tokenId);
        uint8 t0 = uint8(traitsPacked);
        uint8 t1 = uint8(traitsPacked >> 8);
        uint8 t2 = uint8(traitsPacked >> 16);
        uint8 t3 = uint8(traitsPacked >> 24);

        uint8[4] memory traitIds = [t0, t1, t2, t3];
        (uint16 lastExterminated, uint24 currentLevel, uint32[4] memory remaining) = game.getTraitRemainingQuad(
            traitIds
        );
        uint256 metaPacked = (uint256(lastExterminated) << 56) | (uint256(currentLevel) << 32) | uint256(traitsPacked);
        return regularRenderer.tokenURI(tokenId, metaPacked, remaining);
    }

    // ---------------------------------------------------------------------
    // Purchase entrypoints (proxy to game logic)
    // ---------------------------------------------------------------------

    function _syntheticMapInfo(address player) private view returns (address owner, bytes32 code) {
        address affiliateAddr = affiliateProgram;
        if (affiliateAddr == address(0)) {
            return (address(0), bytes32(0));
        }
        return IDegenerusAffiliate(affiliateAddr).syntheticMapInfo(player);
    }

    function _payoutAddress(address player) private view returns (address) {
        (address owner, ) = _syntheticMapInfo(player);
        return owner == address(0) ? player : owner;
    }

    function purchase(PurchaseParams calldata params) external payable {
        _routePurchase(msg.sender, msg.sender, params);
    }

    /// @notice Affiliate-only entry to purchase MAPs for a registered synthetic player (ETH or coin).
    function purchaseMapForSynthetic(address synthetic, uint256 quantity, bool payInCoin) external payable {
        (address synOwner, bytes32 code) = _syntheticMapInfo(synthetic);
        if (synOwner != msg.sender) revert E();
        PurchaseParams memory params = PurchaseParams({
            quantity: quantity,
            kind: PurchaseKind.Map,
            payKind: MintPaymentKind.DirectEth,
            payInCoin: payInCoin,
            affiliateCode: code
        });
        _routePurchase(synthetic, msg.sender, params);
    }

    /// @notice MAP purchase for affiliate rewards (affiliate-only, zero bonus/payout).
    /// @dev Access: affiliate program only; bypasses payments and just enqueues maps.
    function purchaseMapForAffiliate(address buyer, uint256 quantity) external {
        if (msg.sender != affiliateProgram) revert OnlyCoin();
        if (game.rngLocked()) revert RngNotReady();
        game.enqueueMap(buyer, uint32(quantity));

        emit MapPurchase(buyer, uint32(quantity), true, true, 0, 0);
    }

    function _routePurchase(address buyer, address payer, PurchaseParams memory params) private {
        bytes32 affiliateCode = params.payKind == MintPaymentKind.DirectEth ? params.affiliateCode : bytes32(0);
        if (params.kind == PurchaseKind.Player) {
            _purchase(buyer, payer, params.quantity, params.payInCoin, affiliateCode, params.payKind);
        } else if (params.kind == PurchaseKind.Map) {
            _mintAndBurn(buyer, payer, params.quantity, params.payInCoin, affiliateCode, params.payKind);
        } else {
            revert E();
        }
    }

    function _purchase(
        address buyer,
        address payer,
        uint256 quantity,
        bool payInCoin,
        bytes32 affiliateCode,
        MintPaymentKind payKind
    ) private {
        // Primary entry for player token purchases; pricing and bonuses are sourced from the game contract.
        if (quantity == 0 || quantity > type(uint32).max) revert InvalidQuantity();

        uint24 targetLevel;
        uint8 state;
        bool mapJackpotReady;
        bool rngLocked_;
        uint256 priceWei;
        (targetLevel, state, mapJackpotReady, rngLocked_, priceWei) = game.purchaseInfo();

        if ((targetLevel % 20) == 16) revert NotTimeYet();
        if (rngLocked_) revert RngNotReady();

        uint256 coinCost = quantity * PRICE_COIN_UNIT;
        uint256 expectedWei = priceWei * quantity;

        uint32 levelHundredCount;
        if (!payInCoin && targetLevel == 100) {
            // Level-100 ETH purchases scale price based on ETH mint history and prior level-100 mints.
            (expectedWei, levelHundredCount) = _levelHundredCost(payer, priceWei, uint32(quantity));
        }
        if (!payInCoin) {
            expectedWei += _initiationFee(targetLevel, payer, priceWei);
        }

        uint256 bonus;
        uint256 bonusCoinReward;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            _coinReceive(payer, uint32(quantity), quantity * PRICE_COIN_UNIT, targetLevel, 0);
        } else {
            bonusCoinReward = (quantity / 10) * PRICE_COIN_UNIT;
            bonus = _processEthPurchase(
                payer,
                buyer,
                quantity * 100,
                affiliateCode,
                targetLevel,
                state,
                rngLocked_,
                false,
                payKind,
                expectedWei
            );
            if (targetLevel == 100) {
                _levelHundredMintCount[payer] = levelHundredCount;
            }
            if (mapJackpotReady && (targetLevel % 100) > 90) {
                bonus += (quantity * PRICE_COIN_UNIT) / 5;
            }
        }

        if (payKind != MintPaymentKind.DirectEth) {
            unchecked {
                bonus += (quantity * PRICE_COIN_UNIT) / CLAIMABLE_BONUS_DIVISOR;
            }
        }

        bonus += bonusCoinReward;
        if (bonus != 0) {
            coin.creditFlip(buyer, bonus);
        }

        uint32 qty32 = uint32(quantity);
        if (!payInCoin && state == 3) {
            game.enqueueMap(buyer, qty32);
        }
        unchecked {
            _purchaseCount += qty32;
        }

        _recordPurchase(buyer, qty32);

        uint256 costAmount = payInCoin ? coinCost : expectedWei;
        emit TokenPurchase(buyer, qty32, payInCoin, payKind != MintPaymentKind.DirectEth, costAmount, bonus);
    }

    function _mintAndBurn(
        address buyer,
        address payer,
        uint256 quantity,
        bool payInCoin,
        bytes32 affiliateCode,
        MintPaymentKind payKind
    ) private {
        // Map purchase flow: mints 4:1 scaled quantity and immediately queues them for burn draws.
        uint24 lvl;
        uint8 state;
        bool mapJackpotReady;
        bool rngLocked_;
        uint256 priceWei;
        (lvl, state, mapJackpotReady, rngLocked_, priceWei) = game.purchaseInfo();
        if (state == 3 && payInCoin) revert NotTimeYet();
        if (quantity == 0 || quantity > type(uint32).max) revert InvalidQuantity();
        if (rngLocked_) revert RngNotReady();
        uint256 coinCost = quantity * (PRICE_COIN_UNIT / 4);
        uint256 scaledQty = quantity * 25;
        uint256 mapRebate = (quantity / 4) * (PRICE_COIN_UNIT / 10);
        uint256 mapBonus = (quantity / 40) * PRICE_COIN_UNIT;
        uint256 expectedWei = (priceWei * quantity) / 4;

        uint32 levelHundredCount;
        if (!payInCoin && lvl == 100) {
            // Level-100 ETH map mints share the same scaling rules as token mints.
            (expectedWei, levelHundredCount) = _levelHundredCost(payer, priceWei / 4, uint32(quantity));
        }
        if (!payInCoin) {
            expectedWei += _initiationFee(lvl, payer, priceWei);
        }

        uint256 bonus;
        uint256 claimableBonus;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            _coinReceive(payer, uint32(quantity), coinCost, lvl, 0);
            // Affiliate coin-triggered mints should not earn rebates/bonuses.
            bonus = payKind == MintPaymentKind.Claimable ? 0 : mapRebate;
        } else {
            bonus = _processEthPurchase(
                payer,
                buyer,
                scaledQty,
                affiliateCode,
                lvl,
                state,
                rngLocked_,
                true,
                payKind,
                expectedWei
            );
            if (lvl == 100) {
                _levelHundredMintCount[payer] = levelHundredCount;
            }
            if (mapJackpotReady && (lvl % 100) > 90) {
                bonus += coinCost / 5;
            }
            if (payKind != MintPaymentKind.DirectEth) {
                // Claimable MAP purchases earn the same bonus as the standard map rebate.
                claimableBonus = mapRebate;
            }
        }

        uint256 rebateMint = bonus;
        if (!payInCoin) {
            rebateMint += mapRebate + mapBonus;
        }
        if (claimableBonus != 0) {
            rebateMint += claimableBonus;
        }
        if (rebateMint != 0) {
            coin.creditFlip(_payoutAddress(buyer), rebateMint);
        }

        game.enqueueMap(buyer, uint32(quantity));

        uint256 costAmount = payInCoin ? coinCost : expectedWei;
        emit MapPurchase(
            buyer,
            uint32(quantity),
            payInCoin,
            payKind != MintPaymentKind.DirectEth,
            costAmount,
            rebateMint
        );
    }

    function _processEthPurchase(
        address payer,
        address buyer,
        uint256 scaledQty,
        bytes32 affiliateCode,
        uint24 lvl,
        uint8 gameState,
        bool rngLocked,
        bool mapPurchase,
        MintPaymentKind payKind,
        uint256 costWei
    ) private returns (uint256 bonusMint) {
        // ETH purchases optionally bypass payment when in-game credit is used; all flows are forwarded to game logic.
        if (payKind == MintPaymentKind.DirectEth) {
            if (msg.value != costWei) revert E();
        } else if (payKind == MintPaymentKind.Claimable) {
            if (msg.value != 0) revert E();
        } else if (payKind == MintPaymentKind.Combined) {
            if (msg.value > costWei) revert E();
        } else {
            revert E();
        }

        // Quest progress tracks full-price equivalents (4 map mints = 1 unit).
        uint32 mintedQuantity = uint32(scaledQty / 100);
        uint32 mintUnits = mapPurchase ? mintedQuantity : 4;

        uint256 streakBonus;
        if (payKind == MintPaymentKind.DirectEth) {
            streakBonus = game.recordMint{value: costWei}(payer, lvl, false, costWei, mintUnits, payKind);
        } else if (payKind == MintPaymentKind.Combined) {
            streakBonus = game.recordMint{value: msg.value}(payer, lvl, false, costWei, mintUnits, payKind);
        } else {
            streakBonus = game.recordMint(payer, lvl, false, costWei, mintUnits, payKind);
        }

        if (mintedQuantity != 0) {
            coin.notifyQuestMint(payer, mintedQuantity, true);
        }

        // Flat affiliate payout baseline and bonus conditions.
        uint256 affiliateAmount;
        if (lvl > 40) {
            uint256 pct = gameState != 3 ? 30 : 5;
            affiliateAmount = (PRICE_COIN_UNIT * pct) / 100;
        } else {
            affiliateAmount = PRICE_COIN_UNIT / 10; // 0.1 priceCoin
            bool affiliateBonus = lvl <= 3 || gameState != 3; // first 3 levels or any purchase phase
            if (affiliateBonus) {
                affiliateAmount = (affiliateAmount * 250) / 100; // +150% => 0.25 priceCoin
            }
        }

        uint256 rakebackMint;
        address affiliateAddr = affiliateProgram;
        if (affiliateAddr != address(0)) {
            rakebackMint = IDegenerusAffiliate(affiliateAddr).payAffiliate(
                affiliateAmount,
                affiliateCode,
                buyer,
                lvl,
                gameState,
                rngLocked
            );
        }

        if (rakebackMint != 0) {
            unchecked {
                bonusMint += rakebackMint;
            }
        }
        if (streakBonus != 0) {
            unchecked {
                bonusMint += streakBonus;
            }
        }
    }

    function _initiationFee(uint24 lvl, address player, uint256 priceWei) private view returns (uint256) {
        if (lvl <= 3 || priceWei == 0) return 0;
        if (game.ethMintLevelCount(player) != 0) return 0;
        return priceWei / 5;
    }

    function _levelHundredCost(
        address buyer,
        uint256 unitPriceWei,
        uint32 quantity
    ) private view returns (uint256 cost, uint32 newCount) {
        // Progressive ETH pricing for level-100 purchases: ramps up to full price after a history of prior mints.
        uint32 prev = _levelHundredMintCount[buyer];
        uint256 levelCount = game.ethMintLevelCount(buyer);
        uint256 streakCount = game.ethMintStreakCount(buyer);
        if (levelCount > 100) levelCount = 100;
        if (streakCount > 100) streakCount = 100;

        // Base factor is (1 - score/200), where score combines level count and streak.
        uint256 baseFactorBps = 10000 - ((levelCount + streakCount) * 50);

        for (uint32 i; i < quantity; ) {
            uint256 ramp = prev + i;
            if (ramp > 20) {
                ramp = 20;
            }
            uint256 factorBps = baseFactorBps + (ramp * 500); // +5% per prior mint, capped at full price
            if (factorBps > 10000) {
                factorBps = 10000;
            }
            cost += (unitPriceWei * factorBps) / 10000;
            unchecked {
                ++i;
            }
        }

        newCount = prev + quantity;
    }

    function _coinReceive(address payer, uint32 quantity, uint256 amount, uint24 lvl, uint256 discount) private {
        // Coin payments burn BURNIE (with level-based modifiers) and notify quest tracking without moving ETH.
        uint8 stepMod = uint8(lvl % 20);
        if (stepMod == 13) amount = (amount * 3) / 2;
        else if (stepMod == 18) amount = (amount * 9) / 10;
        if (discount != 0) amount -= discount;
        coin.burnCoin(payer, amount);
        game.recordMint(payer, lvl, true, 0, 0, MintPaymentKind.DirectEth);
        uint32 questQuantity = quantity / 4; // coin mints track full-price equivalents for quests
        if (questQuantity != 0) {
            coin.notifyQuestMint(payer, questQuantity, false);
        }
    }

    function _recordPurchase(address buyer, uint32 quantity) private {
        // Append buyer to the pending mint queue; mints are finalized in processPendingMints after RNG.
        uint32 owed = _tokensOwed[buyer];
        if (owed == 0) {
            _pendingMintQueue.push(buyer);
        }

        unchecked {
            _tokensOwed[buyer] = owed + quantity;
        }
    }

    /// @notice Batch-mint queued purchases, respecting an airdrop cap and optional multiplier for reward mints.
    /// @dev Called by the game contract; rotates through the queue using a VRF-provided offset for this airdrop.
    function processPendingMints(
        uint32 playersToProcess,
        uint32 multiplier,
        uint256 rngWord
    ) external onlyGame returns (bool finished) {
        uint256 total = _pendingMintQueue.length;

        uint256 index = _mintQueueIndex;
        if (index >= total) {
            finished = true;
        } else {
            uint256 offset = total > 1 ? (rngWord % total) : 0;

            uint32 players = playersToProcess == 0 ? MINT_AIRDROP_PLAYER_BATCH_SIZE : playersToProcess;
            uint256 end = index + players;
            if (end > total) {
                end = total;
            }

            uint32 minted;
            if (multiplier == 0) multiplier = 1;
            while (index < end) {
                uint256 rawIdx = (index + offset) % total;
                address player = _pendingMintQueue[rawIdx];
                uint32 owed = _tokensOwed[player];
                if (owed == 0) {
                    unchecked {
                        ++index;
                    }
                    continue;
                }

                uint32 room = MINT_AIRDROP_TOKEN_CAP - minted;
                if (room == 0) {
                    break;
                }

                uint256 outstandingTokens = uint256(owed) * uint256(multiplier);
                uint32 mintAmount = outstandingTokens > room ? room : uint32(outstandingTokens);
                mintAmount = (mintAmount / multiplier) * multiplier;
                if (mintAmount == 0) {
                    break;
                }

                _mint(player, mintAmount);

                minted += mintAmount;

                uint32 completedUnits = mintAmount / multiplier;
                if (completedUnits > owed) {
                    completedUnits = owed;
                }
                owed -= completedUnits;
                _tokensOwed[player] = owed;

                if (owed == 0) {
                    unchecked {
                        ++index;
                    }
                } else {
                    break;
                }
            }

            _mintQueueIndex = index;
            finished = index >= total;
        }

        if (finished) {
            delete _pendingMintQueue;
            _mintQueueIndex = 0;
            _purchaseCount = 0;
        }
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return address(uint160(_packedOwnershipOf(tokenId)));
    }

    /// @dev Resolve packed ownership; reverts for invalid or burned tokens. Backtracks to find the last initialized slot.
    function _isLiveState() private view returns (bool) {
        IDegenerusGame g = game;
        return g.gameState() == 3;
    }

    function _packedOwnershipOf(uint256 tokenId) private view returns (uint256 packed) {
        if (tokenId != SPECIAL_TOKEN_ID && tokenId < _currentBaseTokenId()) revert InvalidToken();
        if (tokenId >= _currentIndex) revert InvalidToken();

        packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            unchecked {
                uint256 curr = tokenId;
                while (curr > 0) {
                    --curr;
                    packed = _packedOwnerships[curr];
                    if (packed != 0) break;
                }
            }
        }

        if (packed & _BITMASK_BURNED != 0 || (packed & _BITMASK_ADDRESS) == 0) {
            revert InvalidToken();
        }
        return packed;
    }

    function _packOwnershipData(address owner, uint256 flags) private view returns (uint256 result) {
        assembly ("memory-safe") {
            owner := and(owner, _BITMASK_ADDRESS)
            result := or(owner, or(shl(_BITPOS_START_TIMESTAMP, timestamp()), flags))
        }
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (!_exists(tokenId)) revert InvalidToken();

        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        address sender = msg.sender;
        _operatorApprovals[sender][operator] = approved;
        emit ApprovalForAll(sender, operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view returns (bool) {
        if (operator == address(game)) return true;
        return _operatorApprovals[owner][operator];
    }

    /// @dev Lightweight existence check used by approval getters; trophies and game-owned placeholders are handled.
    function _exists(uint256 tokenId) internal view returns (bool) {
        if (!_isLiveState()) {
            return tokenId == SPECIAL_TOKEN_ID;
        }
        if (tokenId == SPECIAL_TOKEN_ID) return true;
        if (tokenId < _currentBaseTokenId()) return false;

        if (tokenId < _currentIndex) {
            uint256 packed;
            uint256 curr = tokenId;
            while ((packed = _packedOwnerships[curr]) == 0) {
                if (curr == 0) {
                    return false;
                }
                unchecked {
                    --curr;
                }
            }
            return packed & _BITMASK_BURNED == 0;
        }

        return false;
    }

    /// @dev Gas-optimized owner/approval check used by transferFrom.
    function _isSenderApprovedOrOwner(
        address approvedAddress,
        address owner,
        address msgSender
    ) private pure returns (bool result) {
        assembly ("memory-safe") {
            owner := and(owner, _BITMASK_ADDRESS)
            msgSender := and(msgSender, _BITMASK_ADDRESS)
            result := or(eq(msgSender, owner), eq(msgSender, approvedAddress))
        }
    }

    /// @notice Transfer; clears per-token approvals.
    function transferFrom(address from, address to, uint256 tokenId) public payable {
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);

        if (address(uint160(prevOwnershipPacked)) != from) revert TransferFromIncorrectOwner();
        if (to == address(0)) revert Zero();

        address approvedAddress = _tokenApprovals[tokenId];

        address sender = msg.sender;
        if (sender == address(game)) {
            approvedAddress = sender;
        }
        if (!_isSenderApprovedOrOwner(approvedAddress, from, sender))
            if (!isApprovedForAll(from, sender)) revert TransferFromIncorrectOwner();

        if (approvedAddress != address(0)) {
            delete _tokenApprovals[tokenId];
        }
        delete asks[tokenId];

        unchecked {
            --_packedAddressData[from]; // Updates: `balance -= 1`.
            ++_packedAddressData[to]; // Updates: `balance += 1`.

            _packedOwnerships[tokenId] = _packOwnershipData(to, _BITMASK_NEXT_INITIALIZED);

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextId = tokenId + 1;
                if (_packedOwnerships[nextId] == 0) {
                    if (nextId != _currentIndex) {
                        _packedOwnerships[nextId] = prevOwnershipPacked;
                    }
                }
            }
        }

        uint256 fromValue = uint256(uint160(from));
        uint256 toValue = uint256(uint160(to));
        assembly ("memory-safe") {
            log4(
                0, // Start of data (0, since no data).
                0, // End of data (0, since no data).
                _TRANSFER_EVENT_SIGNATURE, // Signature.
                fromValue, // `from`.
                toValue, // `to`.
                tokenId // `tokenId`.
            )
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public payable {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data) public payable {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0)
            if (!_checkContractOnERC721Received(from, to, tokenId, _data)) {
                revert TransferToNonERC721ReceiverImplementer();
            }
    }

    function _marketTransfer(address from, address to, uint256 tokenId, uint256 prevOwnershipPacked) private {
        if (address(uint160(prevOwnershipPacked)) != from) revert TransferFromIncorrectOwner();
        if (to == address(0)) revert Zero();
        if (_tokenApprovals[tokenId] != address(0)) {
            delete _tokenApprovals[tokenId];
        }
        delete asks[tokenId];

        unchecked {
            --_packedAddressData[from];
            ++_packedAddressData[to];

            _packedOwnerships[tokenId] = _packOwnershipData(to, _BITMASK_NEXT_INITIALIZED);

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextId = tokenId + 1;
                if (_packedOwnerships[nextId] == 0 && nextId != _currentIndex) {
                    _packedOwnerships[nextId] = prevOwnershipPacked;
                }
            }
        }

        emit Transfer(from, to, tokenId);
    }

    function _collectPayment(address payer, address seller, uint256 amount) private {
        uint256 burnCut = (amount * BURN_BPS) / BPS_DENOMINATOR;
        uint256 payout = amount - burnCut;
        if (!burnie.transferFrom(payer, seller, payout)) revert PaymentFailed();
        if (burnCut != 0) burnie.burnCoin(payer, burnCut);
    }

    /// @dev Minimal ERC721Receiver check with reason bubbling.
    function _checkContractOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) private returns (bool) {
        address sender = msg.sender;
        try IERC721Receiver(to).onERC721Received(sender, from, tokenId, _data) returns (bytes4 retval) {
            return retval == IERC721Receiver(to).onERC721Received.selector;
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                revert TransferToNonERC721ReceiverImplementer();
            }
            assembly ("memory-safe") {
                revert(add(32, reason), mload(reason))
            }
        }
    }

    /// @dev Internal batch mint; emits one Transfer event per token for ERC721 indexers.
    function _mint(address to, uint256 quantity) internal {
        uint256 startTokenId = _currentIndex;

        unchecked {
            _packedOwnerships[startTokenId] = _packOwnershipData(to, quantity == 1 ? _BITMASK_NEXT_INITIALIZED : 0);

            uint256 packedData = _packedAddressData[to];
            uint256 currentBalance = packedData & _BITMASK_ADDRESS_DATA_ENTRY; // Extract current balance
            uint256 currentNumberMinted = (packedData >> _BITPOS_NUMBER_MINTED) & _BITMASK_ADDRESS_DATA_ENTRY; // Extract current minted count

            // Safely increment balance
            uint256 newBalance = currentBalance + quantity;
            if (newBalance < currentBalance || newBalance > _BITMASK_ADDRESS_DATA_ENTRY) {
                // Check for overflow or exceeding field capacity
                revert E(); // Or a more specific error
            }

            // Safely increment minted count
            uint256 newNumberMinted = currentNumberMinted + quantity;
            if (newNumberMinted < currentNumberMinted || newNumberMinted > _BITMASK_ADDRESS_DATA_ENTRY) {
                // Check for overflow or exceeding field capacity
                revert E(); // Or a more specific error
            }

            // Clear old values and set new ones
            packedData &= ~(_BITMASK_ADDRESS_DATA_ENTRY | (_BITMASK_ADDRESS_DATA_ENTRY << _BITPOS_NUMBER_MINTED));
            packedData |= newBalance;
            packedData |= (newNumberMinted << _BITPOS_NUMBER_MINTED);

            _packedAddressData[to] = packedData;

            uint256 toMasked = uint256(uint160(to)) & _BITMASK_ADDRESS;

            uint256 end = startTokenId + quantity;
            uint256 tokenId = startTokenId;

            do {
                assembly ("memory-safe") {
                    log4(
                        0, // Start of data (0, since no data).
                        0, // End of data (0, since no data).
                        _TRANSFER_EVENT_SIGNATURE, // Signature.
                        0, // `address(0)`.
                        toMasked, // `to`.
                        tokenId // `tokenId`.
                    )
                }
            } while (++tokenId != end);

            _currentIndex = end;
        }
    }

    function approve(address to, uint256 tokenId) external payable {
        address owner = address(uint160(_packedOwnershipOf(tokenId)));

        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) {
            revert ApprovalCallerNotOwnerNorApproved();
        }

        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }
    // ---------------------------------------------------------------------
    // Degenerus game wiring
    // ---------------------------------------------------------------------

    modifier onlyGame() {
        if (msg.sender != address(game)) revert E();
        _;
    }

    modifier onlyCoinOrAdmin() {
        if (!_isCoinOrAdmin()) revert OnlyCoin();
        _;
    }

    modifier onlyCoinAdmin() {
        if (msg.sender != coin.admin()) revert OnlyCoinAdmin();
        _;
    }

    function _isCoinOrAdmin() private view returns (bool) {
        address sender = msg.sender;
        if (sender == address(coin)) return true;
        return sender == coin.admin();
    }

    /// @notice Wire the game module using an address array ([game]); set-once per slot.
    function wire(address[] calldata addresses) external onlyCoinOrAdmin {
        _setGame(addresses.length > 0 ? addresses[0] : address(0));
    }

    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(game);
        if (current == address(0)) {
            game = IDegenerusGame(gameAddr);
        } else if (gameAddr != current) {
            revert E();
        }
    }

    // ---------------------------------------------------------------------
    // Marketplace (offers/asks)
    // ---------------------------------------------------------------------

    /// @notice Place an on-chain ask (listing) for a tokenId.
    function placeAsk(uint256 tokenId, uint256 price, uint40 expiry) external {
        if (price == 0) revert PriceZero();
        if (expiry < block.timestamp) revert Expired();
        address seller = msg.sender;
        if (address(uint160(_packedOwnershipOf(tokenId))) != seller) revert Unauthorized();
        burnie.burnCoin(seller, ASK_FEE);
        asks[tokenId] = Ask({seller: seller, expiry: expiry, price: price});
        emit AskPlaced(seller, tokenId, price, expiry);
    }

    /// @notice Cancel an active ask.
    function cancelAsk(uint256 tokenId) external {
        Ask storage ask = asks[tokenId];
        if (ask.seller != msg.sender) revert Unauthorized();
        delete asks[tokenId];
        emit AskCanceled(msg.sender, tokenId);
    }

    /// @notice Buy an active on-chain ask.
    function buy(uint256 tokenId) external {
        Ask memory ask = asks[tokenId];
        if (ask.seller == address(0)) revert Unauthorized();
        if (ask.price == 0) revert PriceZero();
        if (ask.expiry < block.timestamp) revert Expired();

        address seller = ask.seller;
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        if (address(uint160(prevOwnershipPacked)) != seller) revert Unauthorized();

        delete asks[tokenId];

        address buyer = msg.sender;
        _collectPayment(buyer, seller, ask.price);
        _marketTransfer(seller, buyer, tokenId, prevOwnershipPacked);

        emit AskFilled(buyer, seller, tokenId, ask.price);
    }

    /// @notice Place an on-chain offer for a tokenId; burns the flat posting fee.
    function placeOffer(uint256 tokenId, uint216 amount, uint40 expiry) external {
        if (amount == 0) revert PriceZero();
        if (expiry < block.timestamp) revert Expired();
        if (burnie.balanceOf(msg.sender) < amount) revert InsufficientBalance();

        burnie.burnCoin(msg.sender, OFFER_FEE);
        offers[tokenId][msg.sender] = Offer({amount: amount, expiry: expiry});
        if (!offerSeen[tokenId][msg.sender]) {
            offerSeen[tokenId][msg.sender] = true;
            offerBidders[tokenId].push(msg.sender);
        }

        emit OfferPlaced(msg.sender, tokenId, amount, expiry);
    }

    /// @notice Cancel an active on-chain offer for a tokenId (no refund).
    function cancelOffer(uint256 tokenId) external {
        Offer storage offer = offers[tokenId][msg.sender];
        if (offer.amount == 0) revert Unauthorized();
        delete offers[tokenId][msg.sender];
        emit OfferCanceled(msg.sender, tokenId);
    }

    /// @notice Accept a specific offer by supplying the bidder/amount you observed off-chain (e.g., via `bestOffer`).
    function acceptOffer(uint256 tokenId, address bidder, uint216 amount) external {
        Offer memory offer = offers[tokenId][bidder];
        if (offer.amount == 0 || offer.amount != amount) revert Unauthorized();
        if (offer.expiry < block.timestamp) revert Expired();
        if (burnie.balanceOf(bidder) < amount) revert InsufficientBalance();

        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        address seller = msg.sender;
        if (address(uint160(prevOwnershipPacked)) != seller) revert Unauthorized();

        delete offers[tokenId][bidder];

        _collectPayment(bidder, seller, amount);
        _marketTransfer(seller, bidder, tokenId, prevOwnershipPacked);

        emit OfferFilled(seller, bidder, tokenId, amount);
    }

    /// @notice Return the highest active offer (funded + unexpired) for a token, if any.
    function bestOffer(uint256 tokenId) external view returns (BestOffer memory best) {
        address[] memory bidders = offerBidders[tokenId];
        uint256 len = bidders.length;
        for (uint256 i; i < len; i++) {
            address bidder = bidders[i];
            Offer memory offer = offers[tokenId][bidder];
            if (offer.amount == 0) continue;
            if (offer.expiry < block.timestamp) continue;
            if (burnie.balanceOf(bidder) < offer.amount) continue;
            if (offer.amount > best.amount) {
                best = BestOffer({bidder: bidder, amount: offer.amount, expiry: offer.expiry});
            }
        }
    }
    /// @notice Retire all tokens below `newBaseTokenId` (except token 0) at level transition.
    function advanceBase() external onlyGame {
        uint256 startTokenId = _baseTokenId;
        uint256 endTokenId = _currentIndex;
        if (startTokenId < endTokenId) {
            _dormantCursor = startTokenId;
            _dormantEnd = endTokenId;
            _dormantPacked = _packedOwnerships[startTokenId];
        } else {
            _dormantCursor = 0;
            _dormantEnd = 0;
            _dormantPacked = 0;
        }

        _baseTokenId = endTokenId;
        _burnCounter = endTokenId - 1;
    }

    /// @notice Burn a batch of player tokens
    function burnFromGame(address owner, uint256[] calldata tokenIds) external onlyGame {
        uint256 burnDelta;
        uint256 len = tokenIds.length;
        uint256 baseLimit = _currentBaseTokenId();
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            if (tokenId < baseLimit) revert InvalidToken();
            if (tokenId == SPECIAL_TOKEN_ID) revert InvalidToken();
            _burnToken(owner, tokenId);
            unchecked {
                burnDelta += _BURN_COUNT_INCREMENT_UNIT;
                ++i;
            }
        }

        if (burnDelta != 0) {
            _applyBurnAccounting(owner, burnDelta);
        }
    }

    function _burnToken(address owner, uint256 tokenId) private {
        uint256 packed = _packedOwnershipOf(tokenId);
        if (address(uint160(packed)) != owner) revert TransferFromIncorrectOwner();
        _burnPacked(tokenId, packed);
    }

    /// @dev Marks a token as burned and backfills ownership to keep scans efficient; approvals are cleared.
    function _burnPacked(uint256 tokenId, uint256 prevOwnershipPacked) private {
        address from = address(uint160(prevOwnershipPacked));
        if (_tokenApprovals[tokenId] != address(0)) {
            delete _tokenApprovals[tokenId];
        }
        _packedOwnerships[tokenId] = _packOwnershipData(from, _BITMASK_BURNED | _BITMASK_NEXT_INITIALIZED);

        if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
            uint256 nextId = tokenId + 1;
            if (_packedOwnerships[nextId] == 0 && nextId != _currentIndex) {
                _packedOwnerships[nextId] = prevOwnershipPacked;
            }
        }

        unchecked {
            ++_burnCounter;
        }
        emit Transfer(from, address(0), tokenId);
    }

    /// @dev Applies burn deltas to address data.
    function _applyBurnAccounting(address owner, uint256 burnDelta) private {
        uint256 currentPackedData = _packedAddressData[owner];
        uint256 currentNumberBurned = (currentPackedData >> _BITPOS_NUMBER_BURNED) & _BITMASK_ADDRESS_DATA_ENTRY;
        uint256 incrementAmount = burnDelta >> _BITPOS_NUMBER_BURNED;

        uint256 currentBalance = currentPackedData & _BITMASK_ADDRESS_DATA_ENTRY;
        if (incrementAmount > currentBalance) revert E();
        uint256 newBalance = currentBalance - incrementAmount;

        uint256 newNumberBurned = currentNumberBurned + incrementAmount;
        if (newNumberBurned < currentNumberBurned || newNumberBurned > _BITMASK_ADDRESS_DATA_ENTRY) {
            revert E(); // Or a more specific error
        }

        currentPackedData =
            (currentPackedData &
                ~(_BITMASK_ADDRESS_DATA_ENTRY | (_BITMASK_ADDRESS_DATA_ENTRY << _BITPOS_NUMBER_BURNED))) |
            newBalance |
            (newNumberBurned << _BITPOS_NUMBER_BURNED);

        _packedAddressData[owner] = currentPackedData;
    }

    /// @notice Emits burn Transfer events for the most-recently-retired level range to help indexers catch up.
    /// @dev Intentionally out-of-spec (events without state changes); advances an internal cursor so callers can
    ///      process the range over multiple transactions.
    function processDormant(uint32 limit) external returns (bool worked) {
        uint256 cursor = _dormantCursor;
        uint256 endTokenId = _dormantEnd;
        if (cursor == 0 || cursor >= endTokenId) {
            return false;
        }

        uint256 tokensRemaining = limit == 0 ? uint256(DORMANT_EMIT_BATCH) : uint256(limit);
        if (tokensRemaining == 0) tokensRemaining = uint256(DORMANT_EMIT_BATCH);

        uint256 currentIndex = _currentIndex;
        uint256 limitToken = cursor + tokensRemaining;
        if (limitToken > endTokenId) {
            limitToken = endTokenId;
        }
        if (limitToken > currentIndex) {
            limitToken = currentIndex;
        }

        uint256 lastPacked = _dormantPacked;
        uint256 startCursor = cursor;
        while (cursor < limitToken) {
            uint256 packed = _packedOwnerships[cursor];
            if (packed != 0) {
                lastPacked = packed;
            } else {
                packed = lastPacked;
            }
            if (packed != 0 && (packed & _BITMASK_BURNED) == 0) {
                address from = address(uint160(packed));
                if (from != address(0)) {
                    uint256 fromValue = uint256(uint160(from)) & _BITMASK_ADDRESS;
                    assembly ("memory-safe") {
                        log4(0, 0, _TRANSFER_EVENT_SIGNATURE, fromValue, 0, cursor)
                    }
                }
            }
            unchecked {
                ++cursor;
            }
        }

        _dormantCursor = cursor;
        _dormantPacked = lastPacked;
        if (cursor >= endTokenId) {
            _dormantCursor = 0;
            _dormantEnd = 0;
            _dormantPacked = 0;
        }

        return cursor != startCursor;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function currentBaseTokenId() external view returns (uint256) {
        return _currentBaseTokenId();
    }

    function tokenTraitsPacked(uint256 tokenId) external pure returns (uint32) {
        return DegenerusTraitUtils.packedTraitsForToken(tokenId);
    }

    function purchaseCount() external view returns (uint32) {
        return _purchaseCount;
    }

    /// @notice Pending owed mints for a player (used by processPendingMints).
    function tokensOwed(address player) external view returns (uint32) {
        return _tokensOwed[player];
    }
}
