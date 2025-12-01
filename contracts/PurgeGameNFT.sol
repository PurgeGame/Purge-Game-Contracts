// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeTraitUtils} from "./PurgeTraitUtils.sol";
import {IPurgeGameTrophies} from "./PurgeGameTrophies.sol";
import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeCoin} from "./interfaces/IPurgeCoin.sol";
import {IPurgeAffiliate} from "./interfaces/IPurgeAffiliate.sol";

enum TrophyKind {
    Map,
    Level,
    Affiliate,
    Stake,
    Baf,
    Decimator
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

interface IPurgeGameNFT {
    function tokenTraitsPacked(uint256 tokenId) external view returns (uint32);
    function purchaseCount() external view returns (uint32);
    function finalizePurchasePhase(uint32 minted, uint256 rngWord) external;
    function purge(address owner, uint256[] calldata tokenIds) external;
    function currentBaseTokenId() external view returns (uint256);
    function processPendingMints(uint32 playersToProcess, uint32 multiplier) external returns (bool finished);
    function tokensOwed(address player) external view returns (uint32);
    function processDormant(uint32 maxCount) external returns (bool finished, bool worked);
    function clearPlaceholderPadding(uint256 startTokenId, uint256 endTokenId) external;
    function purchaseWithClaimable(address buyer, uint256 quantity) external;
    function mintAndPurgeWithClaimable(address buyer, uint256 quantity) external;
}

/// @title PurgeGameNFT
/// @notice ERC721 surface for Purge player tokens and trophy placeholders. The contract is intentionally
///         minimalistic and delegates gameplay rules to the game and trophy modules.
/// @dev Uses a packed ownership layout inspired by ERC721A; relies on external wiring from the coin contract
///      to set the trusted game and trophy module addresses.
contract PurgeGameNFT {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ApprovalCallerNotOwnerNorApproved();

    error TransferFromIncorrectOwner();
    error TransferToNonERC721ReceiverImplementer();
    error Zero();
    error E();

    error OnlyCoin();
    error InvalidToken();
    error TrophyStakeViolation(uint8 reason);
    error NotTimeYet();
    error RngNotReady();
    error InvalidQuantity();

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

    // ---------------------------------------------------------------------
    // ERC721 storage
    // ---------------------------------------------------------------------
    // Packed address/ownership layout mirrors ERC721A style: balance/numberMinted/numberBurned are 64-bit fields,
    // followed by startTimestamp and trophy metadata bits. The extra trophy flags keep trophy state in the same slot
    // as ownership to avoid additional mappings.
    uint256 private constant _BITMASK_ADDRESS_DATA_ENTRY = (1 << 64) - 1;
    uint256 private constant _BITPOS_NUMBER_MINTED = 64;
    uint256 private constant _BITPOS_NUMBER_BURNED = 128;
    uint256 private constant _BITPOS_START_TIMESTAMP = 160;
    uint256 private constant _BITMASK_BURNED = 1 << 224;
    uint256 private constant _BITMASK_NEXT_INITIALIZED = 1 << 225;
    uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;
    uint256 private constant _BITPOS_TROPHY_KIND = 232;
    uint256 private constant _BITMASK_TROPHY_KIND = uint256(0xFF) << _BITPOS_TROPHY_KIND;
    uint256 private constant _BITPOS_TROPHY_STAKED = 240;
    uint256 private constant _BITMASK_TROPHY_STAKED = uint256(1) << _BITPOS_TROPHY_STAKED;
    uint256 private constant _BITPOS_TROPHY_ACTIVE = 241;
    uint256 private constant _BITMASK_TROPHY_ACTIVE = uint256(1) << _BITPOS_TROPHY_ACTIVE;
    uint256 private constant _BITPOS_TROPHY_BALANCE = 192;
    uint256 private constant _BITMASK_TROPHY_BALANCE = ((uint256(1) << 32) - 1) << _BITPOS_TROPHY_BALANCE;
    uint256 private constant _BITPOS_BALANCE_LEVEL = 224;
    uint256 private constant _BITMASK_BALANCE_LEVEL = ((uint256(1) << 24) - 1) << _BITPOS_BALANCE_LEVEL;
    uint256 private constant _BURN_COUNT_INCREMENT_UNIT = (uint256(1) << _BITPOS_NUMBER_BURNED);

    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    uint256 private _currentIndex;

    string private _name = "Purge Game";
    string private _symbol = "PG";

    mapping(uint256 => uint256) private _packedOwnerships;
    mapping(address => uint256) private _packedAddressData;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ---------------------------------------------------------------------
    // Purge game storage
    // ---------------------------------------------------------------------
    IPurgeGame private game;
    ITokenRenderer private immutable regularRenderer;
    ITokenRenderer private immutable trophyRenderer;
    IPurgeCoin private immutable coin;
    IPurgeGameTrophies private trophyModule;

    // Token id progression is segmented by "base" pointers: currentBaseTokenId marks the first active player token
    // for the current season, and previousBaseTokenId (stored in the high 128 bits) allows the trophy module to
    // reason about historical placeholders.
    uint256 private basePointers; // high 128 bits = previous base token id, low 128 bits = current base token id

    uint256 private totalTrophySupply;

    uint256 private seasonMintedSnapshot;
    uint256 private seasonPurgedCount;
    uint32 private _purchaseCount;
    uint256 private _nextBaseTokenIdHint;
    // Pending mint queue holds players that bought tokens before the RNG roll; tokens are minted in batches later.
    address[] private _pendingMintQueue;
    mapping(address => uint32) private _tokensOwed;
    uint256 private _mintQueueIndex; // Tracks # of queue entries fully processed during airdrop rotation
    uint256 private _mintQueueStartOffset;

    // Tracks how many level-100 mints (tokens + maps) a player has purchased with ETH for price scaling.
    mapping(address => uint32) private _levelHundredMintCount;

    uint256[] private _dormantCursor; // processing cursor for each dormant range
    uint256[] private _dormantEnd; // exclusive end token id per dormant range
    uint256 private _dormantHead;

    uint32 private constant MINT_AIRDROP_PLAYER_BATCH_SIZE = 210; // Max unique recipients per airdrop batch
    uint32 private constant MINT_AIRDROP_TOKEN_CAP = 3_000; // Max tokens distributed per airdrop batch

    uint256 private constant CLAIMABLE_BONUS_DIVISOR = 10; // 10% of token coin cost
    uint256 private constant CLAIMABLE_MAP_BONUS_DIVISOR = 40; // 10% of per-map coin cost (priceUnit/4)
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_FLAG_AFFILIATE = uint256(1) << 201;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;

    uint8 private constant _STAKE_ERR_TRANSFER_BLOCKED = 1;
    uint32 private constant DORMANT_EMIT_BATCH = 3500;

    function _currentBaseTokenId() private view returns (uint256) {
        return uint256(uint128(basePointers));
    }

    /// @dev Store historical/current base token ids in a single slot to minimize writes.
    function _setBasePointers(uint256 previousBase, uint256 currentBase) private {
        basePointers = (uint256(uint128(previousBase)) << 128) | uint128(currentBase);
    }

    function _packedTrophyBalance(uint256 packed) private pure returns (uint32) {
        return uint32((packed & _BITMASK_TROPHY_BALANCE) >> _BITPOS_TROPHY_BALANCE);
    }

    function _packedBalanceLevel(uint256 packed) private pure returns (uint24) {
        return uint24((packed & _BITMASK_BALANCE_LEVEL) >> _BITPOS_BALANCE_LEVEL);
    }

    /// @dev Updates address data for trophy balance + balance-level watermark. Trophy deltas are bounded to 32 bits.
    function _updateTrophyBalance(address owner, int32 delta, uint24 lvl, bool setLevel) private {
        if (owner == address(0)) return;
        if (delta == 0 && !setLevel) return;

        uint256 packedData = _packedAddressData[owner];

        // Safely update trophyBalance (32-bit field)
        uint32 currentTrophyBalance = uint32((packedData & _BITMASK_TROPHY_BALANCE) >> _BITPOS_TROPHY_BALANCE);
        uint32 newTrophyBalance = currentTrophyBalance;

        if (delta > 0) {
            // Check for overflow before addition
            if (currentTrophyBalance > type(uint32).max - uint32(delta)) revert E(); // More specific error can be used
            newTrophyBalance = currentTrophyBalance + uint32(delta);
        } else if (delta < 0) {
            uint32 absDelta = uint32(-delta);
            // Check for underflow
            if (currentTrophyBalance < absDelta) revert E(); // More specific error can be used
            newTrophyBalance = currentTrophyBalance - absDelta;
        }

        // Safely update balanceLevel (24-bit field)
        uint24 newBalanceLevel = setLevel
            ? lvl
            : uint24((packedData & _BITMASK_BALANCE_LEVEL) >> _BITPOS_BALANCE_LEVEL);

        // Clear old fields and set new ones
        packedData &= ~(_BITMASK_TROPHY_BALANCE | _BITMASK_BALANCE_LEVEL);
        packedData |= (uint256(newTrophyBalance) << _BITPOS_TROPHY_BALANCE);
        packedData |= (uint256(newBalanceLevel) << _BITPOS_BALANCE_LEVEL);

        _packedAddressData[owner] = packedData;
    }

    constructor(address regularRenderer_, address trophyRenderer_, address coin_) {
        regularRenderer = ITokenRenderer(regularRenderer_);
        trophyRenderer = ITokenRenderer(trophyRenderer_);
        coin = IPurgeCoin(coin_);
        _currentIndex = 97;
    }

    /// @notice Total supply counts active trophies plus active player tokens during a purchase phase.
    /// @dev During purchase phase (gameState == 3) supply is derived from the snapshot and purge count;
    ///      otherwise we only surface trophy supply so indexers avoid stale player token ids.
    function totalSupply() external view returns (uint256) {
        uint256 trophyCount = totalTrophySupply;

        if (game.gameState() == 3) {
            uint256 minted = seasonMintedSnapshot;
            uint256 purged = seasonPurgedCount;
            uint256 active = minted > purged ? minted - purged : 0;
            return trophyCount + active;
        }

        return trophyCount;
    }

    /// @notice Returns balance, resetting to trophy count when the game advances a level.
    /// @dev Address data stores a balance-level watermark so historic balances do not leak into new levels.
    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert Zero();
        uint256 packed = _packedAddressData[owner];
        uint256 balance = packed & _BITMASK_ADDRESS_DATA_ENTRY;
        if (balance == 0) {
            return 0;
        }

        uint24 lastLevel = _packedBalanceLevel(packed);

        uint24 currentLevel = game.level();
        if (currentLevel > lastLevel) {
            return _packedTrophyBalance(packed);
        }

        return balance;
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

    /// @notice Renders metadata via the trophy or regular renderer; reverts for nonexistent/burned tokens.
    /// @dev Trophy renderer receives staking/claim flags; regular tokens are validated against the base token window.
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        // Revert for nonexistent or burned tokens (keeps ERC721-consistent surface for indexers).
        _packedOwnershipOf(tokenId);

        uint256 info = trophyModule.trophyData(tokenId);
        if (info != 0) {
            uint32[4] memory extras;
            uint32 flags;
            if (trophyModule.isTrophyStaked(tokenId)) {
                flags |= 1;
            }
            if ((info & TROPHY_OWED_MASK) != 0) {
                flags |= 2;
            }
            extras[0] = flags;
            return trophyRenderer.tokenURI(tokenId, info, extras);
        } else if (tokenId < _currentBaseTokenId()) {
            revert InvalidToken();
        }

        uint32 traitsPacked = PurgeTraitUtils.packedTraitsForToken(tokenId);
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
    // Player entrypoints (proxy to game logic)
    // ---------------------------------------------------------------------

    function purchase(uint256 quantity, bool payInCoin, bytes32 affiliateCode) external payable {
        _purchase(msg.sender, quantity, payInCoin, affiliateCode, false);
    }

    function purchaseWithClaimable(address buyer, uint256 quantity) external onlyGame {
        _purchase(buyer, quantity, false, bytes32(0), true);
    }

    function _purchase(
        address buyer,
        uint256 quantity,
        bool payInCoin,
        bytes32 affiliateCode,
        bool useClaimable
    ) private {
        // Primary entry for player token purchases; pricing and bonuses are sourced from the game contract.
        if (quantity == 0 || quantity > type(uint32).max) revert InvalidQuantity();

        (uint24 targetLevel, uint8 state, uint8 phase, bool rngLocked_, uint256 priceWei, uint256 priceCoinUnit) = game
            .purchaseInfo();

        if ((targetLevel % 20) == 16) revert NotTimeYet();
        if (rngLocked_ && phase >= 3 && state == 2) revert RngNotReady();

        uint256 coinCost = quantity * priceCoinUnit;
        uint256 expectedWei = priceWei * quantity;

        uint32 levelHundredCount;
        if (!payInCoin && targetLevel == 100) {
            // Level-100 ETH purchases scale price based on ETH mint history and prior level-100 mints.
            (expectedWei, levelHundredCount) = _levelHundredCost(msg.sender, priceWei, uint32(quantity));
        }

        uint256 bonus;
        uint256 bonusCoinReward;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            _coinReceive(buyer, uint32(quantity), quantity * priceCoinUnit, targetLevel, 0);
        } else {
            bonusCoinReward = (quantity / 10) * priceCoinUnit;
            bonus = _processEthPurchase(
                buyer,
                quantity * 100,
                affiliateCode,
                targetLevel,
                state,
                false,
                useClaimable,
                expectedWei,
                priceCoinUnit
            );
            if (targetLevel == 100) {
                _levelHundredMintCount[buyer] = levelHundredCount;
            }
            if (phase == 3 && (targetLevel % 100) > 90) {
                bonus += (quantity * priceCoinUnit) / 5;
            }
        }

        if (useClaimable) {
            unchecked {
                bonus += (quantity * priceCoinUnit) / CLAIMABLE_BONUS_DIVISOR;
            }
        }

        bonus += bonusCoinReward;
        if (bonus != 0) {
            coin.creditFlip(buyer, bonus);
        }

        uint32 qty32 = uint32(quantity);
        unchecked {
            _purchaseCount += qty32;
        }

        _recordPurchase(buyer, qty32);

        uint256 costAmount = payInCoin ? coinCost : expectedWei;
        emit TokenPurchase(buyer, qty32, payInCoin, useClaimable, costAmount, bonus);
    }

    function mintAndPurge(uint256 quantity, bool payInCoin, bytes32 affiliateCode) external payable {
        _mintAndPurge(msg.sender, quantity, payInCoin, affiliateCode, false);
    }

    function mintAndPurgeWithClaimable(address buyer, uint256 quantity) external onlyGame {
        _mintAndPurge(buyer, quantity, false, bytes32(0), true);
    }

    function _mintAndPurge(
        address buyer,
        uint256 quantity,
        bool payInCoin,
        bytes32 affiliateCode,
        bool useClaimable
    ) private {
        // Map purchase flow: mints 4:1 scaled quantity and immediately queues them for purge draws.
        (uint24 lvl, uint8 state, uint8 phase, bool rngLocked_, uint256 priceWei, uint256 priceUnit) = game
            .purchaseInfo();
        if (state == 3 && payInCoin) revert NotTimeYet();
        if (quantity == 0 || quantity > type(uint32).max) revert InvalidQuantity();
        if (rngLocked_) revert RngNotReady();

        uint256 coinCost = quantity * (priceUnit / 4);
        uint256 scaledQty = quantity * 25;
        uint256 mapRebate = (quantity / 4) * (priceUnit / 10);
        uint256 mapBonus = (quantity / 40) * priceUnit;
        uint256 expectedWei = (priceWei * quantity) / 4;

        uint32 levelHundredCount;
        if (!payInCoin && lvl == 100) {
            // Level-100 ETH map mints share the same scaling rules as token mints.
            (expectedWei, levelHundredCount) = _levelHundredCost(buyer, priceWei / 4, uint32(quantity));
        }

        uint256 bonus;
        uint256 claimableBonus;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            _coinReceive(buyer, uint32(quantity), coinCost, lvl, 0);
            bonus = mapRebate;
        } else {
            bonus = _processEthPurchase(
                buyer,
                scaledQty,
                affiliateCode,
                lvl,
                state,
                true,
                useClaimable,
                expectedWei,
                priceUnit
            );
            if (lvl == 100) {
                _levelHundredMintCount[buyer] = levelHundredCount;
            }
            if (phase == 3 && (lvl % 100) > 90) {
                bonus += coinCost / 5;
            }
            if (useClaimable) {
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
            coin.creditFlip(buyer, rebateMint);
        }

        game.enqueueMap(buyer, uint32(quantity));

        uint256 costAmount = payInCoin ? coinCost : expectedWei;
        emit MapPurchase(buyer, uint32(quantity), payInCoin, useClaimable, costAmount, rebateMint);
    }

    function _processEthPurchase(
        address payer,
        uint256 scaledQty,
        bytes32 affiliateCode,
        uint24 lvl,
        uint8 gameState,
        bool mapPurchase,
        bool useClaimable,
        uint256 expectedWei,
        uint256 priceUnit
    ) private returns (uint256 bonusMint) {
        // ETH purchases optionally bypass payment when claimable credit is used; all flows are forwarded to game logic.
        if (useClaimable) {
            if (msg.value != 0) revert E();
        } else if (msg.value != expectedWei) {
            revert E();
        }

        // Quest progress tracks full-price equivalents (4 map mints = 1 unit).
        uint32 mintedQuantity = uint32(scaledQty / 100);
        uint32 mintUnits = mapPurchase ? mintedQuantity : 4;

        if (mapPurchase) {
            uint8 mapBonusPct = trophyModule.mapStakeDiscount(payer);
            if (mapBonusPct != 0) {
                uint256 coinCost = (scaledQty * priceUnit) / 100; // quantity * (priceUnit/4)
                uint256 mapStakeMint = (coinCost * uint256(mapBonusPct)) / 100;
                if (gameState != 3) {
                    mapStakeMint <<= 1;
                }
                if (mapStakeMint != 0) {
                    unchecked {
                        bonusMint += mapStakeMint;
                    }
                }
            }
        }

        uint256 streakBonus;
        if (useClaimable) {
            streakBonus = game.recordMint(payer, lvl, false, expectedWei, mintUnits);
        } else {
            streakBonus = game.recordMint{value: expectedWei}(payer, lvl, false, expectedWei, mintUnits);
        }

        if (mintedQuantity != 0) {
            coin.notifyQuestMint(payer, mintedQuantity, true);
        }

        // Flat affiliate payout baseline and bonus conditions.
        uint256 affiliateAmount;
        if (lvl > 40) {
            uint256 pct = gameState != 3 ? 30 : 5;
            affiliateAmount = (priceUnit * pct) / 100;
        } else {
            affiliateAmount = priceUnit / 10; // 0.1 priceCoin
            bool affiliateBonus = lvl <= 3 || gameState != 3; // first 3 levels or any purchase phase
            if (affiliateBonus) {
                affiliateAmount = (affiliateAmount * 250) / 100; // +150% => 0.25 priceCoin
            }
        }

        uint256 rakebackMint;
        address affiliateAddr = coin.affiliateProgram();
        if (affiliateAddr != address(0)) {
            rakebackMint = IPurgeAffiliate(affiliateAddr).payAffiliate(affiliateAmount, affiliateCode, payer, lvl);
        }

        if (!mapPurchase) {
            uint8 percentReached = game.getEarlyPurgePercent();
            uint256 epPercent = percentReached;
            if (epPercent < 20) {
                uint256 bonusPct = 20 - epPercent;
                uint256 coinCost = (scaledQty * priceUnit) / 100;
                uint256 earlyBonus = (coinCost * bonusPct) / 100;
                if (earlyBonus != 0) {
                    unchecked {
                        bonusMint += earlyBonus;
                    }
                }
            }
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
        // Coin payments burn PURGE (with level-based modifiers) and notify quest tracking without moving ETH.
        uint8 stepMod = uint8(lvl % 20);
        if (stepMod == 13) amount = (amount * 3) / 2;
        else if (stepMod == 18) amount = (amount * 9) / 10;
        if (discount != 0) amount -= discount;
        coin.burnCoin(payer, amount);
        game.recordMint(payer, lvl, true, 0, 0);
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
    /// @dev Called by the game contract; will rotate through the queue deterministically based on `_mintQueueStartOffset`.
    function processPendingMints(uint32 playersToProcess, uint32 multiplier) external onlyGame returns (bool finished) {
        uint256 total = _pendingMintQueue.length;

        uint256 index = _mintQueueIndex;
        if (index >= total) {
            finished = true;
        } else {
            uint32 players = playersToProcess == 0 ? MINT_AIRDROP_PLAYER_BATCH_SIZE : playersToProcess;
            uint256 end = index + players;
            if (end > total) {
                end = total;
            }

            uint32 minted;
            uint24 currentLevel = game.level();
            if (multiplier == 0) multiplier = 1;
            while (index < end) {
                uint256 rawIdx = (index + _mintQueueStartOffset) % total;
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
                _updateTrophyBalance(player, 0, currentLevel, true);

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
            _mintQueueStartOffset = 0;
        }
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return address(uint160(_packedOwnershipOf(tokenId)));
    }

    /// @dev Resolve packed ownership; reverts for invalid or burned tokens. Backtracks to find the last initialized slot.
    function _packedOwnershipOf(uint256 tokenId) private view returns (uint256 packed) {
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

        // Tokens below the current base token id are considered retired unless flagged as trophies.
        if (tokenId < _currentBaseTokenId() && !trophyModule.isTrophy(tokenId)) {
            revert InvalidToken();
        }

        if (packed & _BITMASK_BURNED != 0 || (packed & _BITMASK_ADDRESS) == 0) {
            revert InvalidToken();
        }
        return packed;
    }

    function _packedOwnershipOfUnchecked(uint256 tokenId) private view returns (uint256 packed) {
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
        assembly {
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
        return _operatorApprovals[owner][operator];
    }

    /// @dev Lightweight existence check used by approval getters; trophies and game-owned placeholders are handled.
    function _exists(uint256 tokenId) internal view returns (bool) {
        if (tokenId < _currentBaseTokenId()) {
            if (trophyModule.isTrophy(tokenId)) return true;
            uint256 packed = _packedOwnerships[tokenId];
            if (packed == 0) {
                unchecked {
                    uint256 curr = tokenId;
                    while (curr != 0) {
                        packed = _packedOwnerships[--curr];
                        if (packed != 0) break;
                    }
                }
            }
            if (packed == 0) return false;
            return (packed & _BITMASK_BURNED) == 0 && address(uint160(packed)) == address(game);
        }

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
        assembly {
            owner := and(owner, _BITMASK_ADDRESS)
            msgSender := and(msgSender, _BITMASK_ADDRESS)
            result := or(eq(msgSender, owner), eq(msgSender, approvedAddress))
        }
    }

    /// @notice Transfer respecting trophy staking locks; clears per-token approvals.
    function transferFrom(address from, address to, uint256 tokenId) public payable {
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        bool isTrophy = (prevOwnershipPacked & _BITMASK_TROPHY_ACTIVE) != 0;

        if (address(uint160(prevOwnershipPacked)) != from) revert TransferFromIncorrectOwner();
        if (_isTrophyStaked(tokenId)) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);
        if (to == address(0)) revert Zero();

        address approvedAddress = _tokenApprovals[tokenId];

        address sender = msg.sender;
        if (!_isSenderApprovedOrOwner(approvedAddress, from, sender))
            if (!isApprovedForAll(from, sender)) revert TransferFromIncorrectOwner();

        if (approvedAddress != address(0)) {
            delete _tokenApprovals[tokenId];
        }

        unchecked {
            --_packedAddressData[from]; // Updates: `balance -= 1`.
            ++_packedAddressData[to]; // Updates: `balance += 1`.

            uint256 preserved = prevOwnershipPacked &
                (_BITMASK_TROPHY_KIND | _BITMASK_TROPHY_STAKED | _BITMASK_TROPHY_ACTIVE);
            _packedOwnerships[tokenId] = _packOwnershipData(to, preserved | _BITMASK_NEXT_INITIALIZED);

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextId = tokenId + 1;
                if (_packedOwnerships[nextId] == 0) {
                    if (nextId != _currentIndex) {
                        _packedOwnerships[nextId] = prevOwnershipPacked;
                    }
                }
            }
        }

        uint24 currentLevel = game.level();
        if (isTrophy && from != to) {
            _updateTrophyBalance(from, -1, currentLevel, true);
            _updateTrophyBalance(to, 1, currentLevel, true);
        } else {
            _updateTrophyBalance(to, 0, currentLevel, true);
        }

        uint256 fromValue = uint256(uint160(from));
        uint256 toValue = uint256(uint160(to));
        assembly {
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
            assembly {
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
                assembly {
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
        if (_isTrophyStaked(tokenId)) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);

        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }
    // ---------------------------------------------------------------------
    // Purge game wiring
    // ---------------------------------------------------------------------

    modifier onlyGame() {
        if (msg.sender != address(game)) revert E();
        _;
    }

    modifier onlyCoinContract() {
        if (msg.sender != address(coin)) revert OnlyCoin();
        _;
    }

    modifier onlyTrophyModule() {
        if (msg.sender != address(trophyModule)) revert E();
        _;
    }

    /// @notice Wire game and trophy modules using an address array ([game, trophies]); set-once per slot.
    function wire(address[] calldata addresses) external onlyCoinContract {
        _setGame(addresses.length > 0 ? addresses[0] : address(0));
        _setTrophyModule(addresses.length > 1 ? addresses[1] : address(0));
    }

    function _setGame(address gameAddr) private {
        if (gameAddr == address(0)) return;
        address current = address(game);
        if (current == address(0)) {
            game = IPurgeGame(gameAddr);
        } else if (gameAddr != current) {
            revert E();
        }
    }

    function _setTrophyModule(address trophiesAddr) private {
        if (trophiesAddr == address(0)) return;
        address current = address(trophyModule);
        if (current == address(0)) {
            trophyModule = IPurgeGameTrophies(trophiesAddr);
        } else if (trophiesAddr != current) {
            revert E();
        }
    }

    // ---------------------------------------------------------------------
    // Trophy module hooks
    // ---------------------------------------------------------------------

    /// @notice Returns the next token id to be minted; callable by the trophy module only.
    function nextTokenId() external view onlyTrophyModule returns (uint256) {
        return _currentIndex;
    }

    /// @notice Mint placeholder trophies to the game contract; level provided by trophy module to avoid extra calls.
    function mintPlaceholders(
        uint256 quantity,
        uint24 level
    ) external onlyTrophyModule returns (uint256 startTokenId) {
        if (quantity == 0) revert E();
        startTokenId = _currentIndex;
        address gameAddr = address(game);
        _mint(gameAddr, quantity);
        unchecked {
            totalTrophySupply += quantity;
        }

        _updateTrophyBalance(gameAddr, 0, level, true);

        return startTokenId;
    }

    /// @notice Declare a dormant burn range; used later to emit Transfer events for historical burns.
    function scheduleDormantRange(uint256 startTokenId, uint256 endTokenId) external onlyTrophyModule {
        if (startTokenId >= endTokenId) return;
        _dormantCursor.push(startTokenId);
        _dormantEnd.push(endTokenId);
    }

    /// @notice Burn placeholder padding after level processing; must not target active trophy ids.
    function clearPlaceholderPadding(uint256 startTokenId, uint256 endTokenId) external onlyTrophyModule {
        if (startTokenId >= endTokenId) return;

        uint256 count = endTokenId - startTokenId;
        uint256 tokenId = startTokenId;
        address currentOwner;
        uint256 burnDelta;

        while (tokenId < endTokenId) {
            uint256 packed = _packedOwnershipOfUnchecked(tokenId);
            address owner = address(uint160(packed));
            bool isTrophy = _burnPacked(tokenId, packed);
            if (isTrophy) revert E();

            if (owner != currentOwner) {
                if (currentOwner != address(0) && burnDelta != 0) {
                    _applyPurgeAccounting(currentOwner, burnDelta, 0);
                }
                currentOwner = owner;
                burnDelta = 0;
            }

            unchecked {
                burnDelta += _BURN_COUNT_INCREMENT_UNIT;
                ++tokenId;
            }
        }

        if (currentOwner != address(0) && burnDelta != 0) {
            _applyPurgeAccounting(currentOwner, burnDelta, 0);
        }

        if (totalTrophySupply < count) revert E();
        unchecked {
            totalTrophySupply -= count;
        }
    }

    /// @notice Expose previous/current base token ids to the trophy module.
    function getBasePointers() external view onlyTrophyModule returns (uint256 previousBase, uint256 currentBase) {
        previousBase = basePointers >> 128;
        currentBase = _currentBaseTokenId();
    }

    function setBasePointers(uint256 previousBase, uint256 currentBase) external onlyTrophyModule {
        _setBasePointers(previousBase, currentBase);
    }

    /// @notice Trophy module helper to read packed ownership (reverts for invalid tokens).
    function packedOwnershipOf(uint256 tokenId) external view onlyTrophyModule returns (uint256 packed) {
        return _packedOwnershipOf(tokenId);
    }

    /// @notice Trophy module transfer that bypasses user approvals but still emits Transfer.
    function transferTrophy(address from, address to, uint256 tokenId) external onlyTrophyModule {
        _moduleTransfer(from, to, tokenId);
    }

    /// @notice Trophy module hook to set packed info bits for staking/activation and trophy kind.
    function setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool staked) external onlyTrophyModule {
        _setTrophyPackedInfo(tokenId, kind, staked);
    }

    /// @notice Trophy module helper to clear per-token approvals (used before burns/transfers).
    function clearApproval(uint256 tokenId) external onlyTrophyModule {
        if (_tokenApprovals[tokenId] != address(0)) {
            delete _tokenApprovals[tokenId];
        }
    }

    function incrementTrophySupply(uint256 amount) external onlyTrophyModule {
        unchecked {
            totalTrophySupply += amount;
        }
    }

    function decrementTrophySupply(uint256 amount) external onlyTrophyModule {
        unchecked {
            totalTrophySupply -= amount;
        }
    }

    function sendEth(address to, uint256 amount) external onlyTrophyModule {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert E();
    }

    // ---------------------------------------------------------------------
    // VRF / RNG
    // ---------------------------------------------------------------------

    function _setSeasonMintedSnapshot(uint256 minted) private {
        seasonMintedSnapshot = minted;
        seasonPurgedCount = 0;
    }

    /// @notice Called by game when a purchase phase ends; snapshots minted count and shuffles pending mint order.
    function finalizePurchasePhase(uint32 minted, uint256 rngWord) external onlyGame {
        _setSeasonMintedSnapshot(minted);
        uint256 baseTokenId = _currentBaseTokenId();

        uint256 startId = baseTokenId + uint256(minted);
        _nextBaseTokenIdHint = ((startId + 99) / 100) * 100 + 1;
        _purchaseCount = 0;
        _mintQueueIndex = 0;
        uint256 queueLength = _pendingMintQueue.length;
        if (queueLength > 1) {
            _mintQueueStartOffset = ((rngWord % (queueLength - 1)) + 1);
        } else {
            _mintQueueStartOffset = 0;
        }
    }

    /// @notice Burn a batch of player tokens (never trophies) owned by `owner`; trophies burned are tallied separately.
    function purge(address owner, uint256[] calldata tokenIds) external onlyGame {
        uint256 purged;
        uint256 burnDelta;
        uint32 trophiesBurned;
        uint256 len = tokenIds.length;
        uint256 baseLimit = _currentBaseTokenId();
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            if (tokenId < baseLimit) revert InvalidToken();
            bool isTrophy = _purgeToken(owner, tokenId);
            unchecked {
                burnDelta += _BURN_COUNT_INCREMENT_UNIT;
                if (isTrophy) {
                    ++trophiesBurned;
                }
                ++purged;
                ++i;
            }
        }

        if (burnDelta != 0) {
            _applyPurgeAccounting(owner, burnDelta, trophiesBurned);
        }

        seasonPurgedCount += purged;
    }

    function _purgeToken(address owner, uint256 tokenId) private returns (bool isTrophy) {
        uint256 packed = _packedOwnershipOf(tokenId);
        if (address(uint160(packed)) != owner) revert TransferFromIncorrectOwner();
        return _burnPacked(tokenId, packed);
    }

    /// @dev Marks a token as burned and backfills ownership to keep scans efficient; approvals are cleared.
    function _burnPacked(uint256 tokenId, uint256 prevOwnershipPacked) private returns (bool isTrophy) {
        address from = address(uint160(prevOwnershipPacked));
        isTrophy = (prevOwnershipPacked & _BITMASK_TROPHY_ACTIVE) != 0;

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

        emit Transfer(from, address(0), tokenId);
    }

    /// @dev Applies burn deltas to address data and trophy balance; also refreshes level watermark.
    function _applyPurgeAccounting(address owner, uint256 burnDelta, uint32 trophiesBurned) private {
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

        uint24 currentLevel = game.level();

        if (trophiesBurned != 0) {
            uint256 current = (currentPackedData & _BITMASK_TROPHY_BALANCE) >> _BITPOS_TROPHY_BALANCE;
            uint256 updated = current > trophiesBurned ? current - trophiesBurned : 0;
            currentPackedData = (currentPackedData & ~_BITMASK_TROPHY_BALANCE) | (updated << _BITPOS_TROPHY_BALANCE);
        }

        currentPackedData =
            (currentPackedData & ~_BITMASK_BALANCE_LEVEL) |
            (uint256(currentLevel) << _BITPOS_BALANCE_LEVEL);
        _packedAddressData[owner] = currentPackedData;
    }

    /// @notice Emits Transfer events for already-burned dormant ranges to help indexers catch up.
    /// @dev This is intentionally out-of-spec (events without state changes) and should only be called by automation.
    function processDormant(uint32 limit) external returns (bool finished, bool worked) {
        uint256 head = _dormantHead;
        uint256 len = _dormantCursor.length;
        if (head >= len) {
            return (true, false);
        }

        uint256 tokensRemaining = limit == 0 ? uint256(DORMANT_EMIT_BATCH) : uint256(limit);
        if (tokensRemaining == 0) tokensRemaining = uint256(DORMANT_EMIT_BATCH);

        while (tokensRemaining != 0 && head < len) {
            uint256 endTokenId = _dormantEnd[head];
            uint256 cursor = _dormantCursor[head];

            if (cursor >= endTokenId) {
                unchecked {
                    ++head;
                }
                continue;
            }

            uint256 currentIndex = _currentIndex;
            if (cursor >= currentIndex) {
                cursor = endTokenId;
            } else {
                uint256 available = endTokenId - cursor;
                uint256 batch = tokensRemaining;
                if (batch > available) {
                    batch = available;
                }

                uint256 limitToken = cursor + batch;
                if (limitToken > endTokenId) {
                    limitToken = endTokenId;
                }
                if (limitToken > currentIndex) {
                    limitToken = currentIndex;
                }

                uint256 startCursor = cursor;

                while (cursor < limitToken) {
                    uint256 packed = _packedOwnerships[cursor];
                    if (packed == 0) {
                        uint256 seek = cursor;
                        unchecked {
                            while (seek != 0) {
                                packed = _packedOwnerships[--seek];
                                if (packed != 0) break;
                            }
                        }
                    }
                    if (packed != 0 && (packed & _BITMASK_BURNED) == 0) {
                        address from = address(uint160(packed));
                        if (from != address(0)) {
                            emit Transfer(from, address(0), cursor);
                        }
                    }
                    unchecked {
                        ++cursor;
                    }
                }

                uint256 advanced = cursor - startCursor;
                if (advanced == 0) {
                    break;
                }
                tokensRemaining -= advanced;
                worked = true;
            }

            if (cursor >= endTokenId) {
                unchecked {
                    ++head;
                }
            } else {
                _dormantCursor[head] = cursor;
            }
        }

        _dormantHead = head;
        if (head >= len) {
            if (len != 0) {
                delete _dormantCursor;
                delete _dormantEnd;
            }
            _dormantHead = 0;
            return (true, worked);
        }

        return (false, worked);
    }

    /// @dev Trophy-module transfer hook; clears stale approvals and preserves trophy metadata bits.
    function _moduleTransfer(address from, address to, uint256 tokenId) private {
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
        if (to == address(0)) revert Zero();
        address approved = _tokenApprovals[tokenId];
        if (approved != address(0)) {
            delete _tokenApprovals[tokenId];
        }
        unchecked {
            --_packedAddressData[from];
            ++_packedAddressData[to];
        }
        uint256 preserved = prevOwnershipPacked &
            (_BITMASK_TROPHY_KIND | _BITMASK_TROPHY_STAKED | _BITMASK_TROPHY_ACTIVE);
        _packedOwnerships[tokenId] = _packOwnershipData(to, preserved | _BITMASK_NEXT_INITIALIZED);

        if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
            uint256 nextId = tokenId + 1;
            if (_packedOwnerships[nextId] == 0 && nextId != _currentIndex) {
                _packedOwnerships[nextId] = prevOwnershipPacked;
            }
        }

        uint24 currentLevel = game.level();
        _updateTrophyBalance(from, -1, currentLevel, true);
        _updateTrophyBalance(to, 1, currentLevel, true);

        uint256 fromValue = uint256(uint160(from));
        uint256 toValue = uint256(uint160(to));
        assembly {
            log4(0, 0, _TRANSFER_EVENT_SIGNATURE, fromValue, toValue, tokenId)
        }
    }

    /// @dev Trophy module hook to set flag bits; updates owner trophy balance when active flag changes.
    function _setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool staked) private {
        uint256 packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            packed = _packedOwnershipOf(tokenId);
        }
        address owner = address(uint160(packed));
        bool wasActive = (packed & _BITMASK_TROPHY_ACTIVE) != 0;
        bool isActive;
        IPurgeGameTrophies module = trophyModule;

        isActive = module.isTrophy(tokenId);

        uint256 cleared = packed & ~(_BITMASK_TROPHY_KIND | _BITMASK_TROPHY_STAKED | _BITMASK_TROPHY_ACTIVE);
        uint256 updated = cleared | (uint256(kind) << _BITPOS_TROPHY_KIND);
        if (staked) {
            updated |= _BITMASK_TROPHY_STAKED;
        }
        if (isActive) {
            updated |= _BITMASK_TROPHY_ACTIVE;
        }
        _packedOwnerships[tokenId] = updated;

        if (owner != address(0)) {
            if (wasActive != isActive) {
                _updateTrophyBalance(owner, isActive ? int32(1) : int32(-1), game.level(), true);
            }
            if (wasActive && !isActive) {
                emit Transfer(owner, address(0), tokenId);
            }
        }
    }

    /// @dev Helper to check the staked flag without exposing full ownership; used to gate transfers/approvals.
    function _isTrophyStaked(uint256 tokenId) private view returns (bool) {
        uint256 packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            packed = _packedOwnershipOf(tokenId);
        }
        return (packed & _BITMASK_TROPHY_STAKED) != 0;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function currentBaseTokenId() external view returns (uint256) {
        return _currentBaseTokenId();
    }

    function tokenTraitsPacked(uint256 tokenId) external pure returns (uint32) {
        return PurgeTraitUtils.packedTraitsForToken(tokenId);
    }

    function purchaseCount() external view returns (uint32) {
        return _purchaseCount;
    }

    /// @notice Pending owed mints for a player (used by processPendingMints).
    function tokensOwed(address player) external view returns (uint32) {
        return _tokensOwed[player];
    }

    /// @notice Expose decoded trophy bookkeeping fields (owed rewards, base/last claim level, trait/kind flags).
    function getTrophyData(
        uint256 tokenId
    )
        external
        view
        returns (uint256 owedWei, uint24 baseLevel, uint24 lastClaimLevel, uint16 traitId, uint8 trophyKind)
    {
        uint256 raw = trophyModule.trophyData(tokenId);
        owedWei = raw & TROPHY_OWED_MASK;
        uint256 shiftedBase = raw >> TROPHY_BASE_LEVEL_SHIFT;
        baseLevel = uint24(shiftedBase);
        lastClaimLevel = uint24((raw >> TROPHY_LAST_CLAIM_SHIFT));
        traitId = uint16(raw >> 152);

        if (raw & TROPHY_FLAG_MAP != 0) trophyKind = uint8(TrophyKind.Map);
        else if (raw & TROPHY_FLAG_AFFILIATE != 0) trophyKind = uint8(TrophyKind.Affiliate);
        else if (raw & TROPHY_FLAG_STAKE != 0) trophyKind = uint8(TrophyKind.Stake);
        else if (raw & TROPHY_FLAG_BAF != 0) trophyKind = uint8(TrophyKind.Baf);
        else if (raw & TROPHY_FLAG_DECIMATOR != 0) trophyKind = uint8(TrophyKind.Decimator);
        else trophyKind = uint8(TrophyKind.Level);
    }
}
