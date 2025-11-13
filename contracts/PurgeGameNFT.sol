// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeTraitUtils} from "./PurgeTraitUtils.sol";
import {IPurgeGameTrophies} from "./PurgeGameTrophies.sol";
import {IPurgeGame} from "./interfaces/IPurgeGame.sol";
import {IPurgeCoin} from "./interfaces/IPurgeCoin.sol";

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
    function wireContracts(address game_) external;
    function wireTrophies(address trophies_) external;
    function gameMint(address to, uint256 quantity, uint24 lvl) external returns (uint256 startTokenId);
    function tokenTraitsPacked(uint256 tokenId) external view returns (uint32);
    function purchaseCount() external view returns (uint32);
    function resetPurchaseCount() external;
    function finalizePurchasePhase(uint32 minted) external;
    function purge(address owner, uint256[] calldata tokenIds) external;
    function currentBaseTokenId() external view returns (uint256);
    function processPendingMints(uint32 playersToProcess) external returns (bool finished);
    function tokensOwed(address player) external view returns (uint32);
    function processDormant(uint32 maxCount) external returns (bool finished, bool worked);
    function clearPlaceholderPadding(uint256 startTokenId, uint256 endTokenId) external;
}

contract PurgeGameNFT {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error ApprovalCallerNotOwnerNorApproved();

    error TransferFromIncorrectOwner();
    error TransferToNonERC721ReceiverImplementer();
    error Zero();
    error E();
    error ClaimNotReady();

    error OnlyCoin();
    error InvalidToken();
    error TrophyStakeViolation(uint8 reason);
    error StakeInvalid();
    error LuckboxTooSmall();
    error NotTimeYet();
    error RngNotReady();
    error InvalidQuantity();

    // ---------------------------------------------------------------------
    // Events & types
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ---------------------------------------------------------------------
    // ERC721 storage
    // ---------------------------------------------------------------------
    uint256 private constant _BITMASK_ADDRESS_DATA_ENTRY = (1 << 64) - 1;
    uint256 private constant _BITPOS_NUMBER_MINTED = 64;
    uint256 private constant _BITPOS_NUMBER_BURNED = 128;
    uint256 private constant _BITPOS_START_TIMESTAMP = 160;
    uint256 private constant _BITMASK_BURNED = 1 << 224;
    uint256 private constant _BITPOS_NEXT_INITIALIZED = 225;
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
    uint256 private constant _ADDRESS_DATA_BURN_DELTA = (uint256(1) << _BITPOS_NUMBER_BURNED) - 1;

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

    uint256 private basePointers; // high 128 bits = previous base token id, low 128 bits = current base token id

    uint256 private totalTrophySupply;

    uint256 private seasonMintedSnapshot;
    uint256 private seasonPurgedCount;
    uint32 private _purchaseCount;
    uint256 private _nextBaseTokenIdHint;
    address[] private _pendingMintQueue;
    mapping(address => uint32) private _tokensOwed;
    uint256 private _mintQueueIndex; // Tracks # of queue entries fully processed during airdrop rotation
    uint256 private _mintQueueStartOffset;

    uint256[] private _dormantCursor; // processing cursor for each dormant range
    uint256[] private _dormantEnd; // exclusive end token id per dormant range
    uint256 private _dormantHead;

    uint32 private constant MINT_AIRDROP_PLAYER_BATCH_SIZE = 210; // Max unique recipients per airdrop batch
    uint32 private constant MINT_AIRDROP_TOKEN_CAP = 3_000; // Max tokens distributed per airdrop batch

    uint32 private constant COIN_DRIP_STEPS = 10; // Base vesting window before coin drip starts
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint256 private constant COIN_BASE_UNIT = 1_000_000; // 1 PURGED (6 decimals)
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * COIN_BASE_UNIT; // 1000 PURGED (6 decimals)
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_FLAG_AFFILIATE = uint256(1) << 201;
    uint256 private constant TROPHY_FLAG_STAKE = uint256(1) << 202;
    uint256 private constant TROPHY_FLAG_BAF = uint256(1) << 203;
    uint256 private constant TROPHY_FLAG_DECIMATOR = uint256(1) << 204;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_BASE_LEVEL_MASK = uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;
    uint256 private constant TROPHY_LAST_CLAIM_MASK = uint256(0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT;

    uint8 private constant _STAKE_ERR_TRANSFER_BLOCKED = 1;
    uint8 private constant _STAKE_ERR_NOT_LEVEL = 2;
    uint8 private constant _STAKE_ERR_ALREADY_STAKED = 3;
    uint8 private constant _STAKE_ERR_NOT_STAKED = 4;
    uint8 private constant _STAKE_ERR_LOCKED = 5;
    uint8 private constant _STAKE_ERR_NOT_MAP = 6;
    uint8 private constant _STAKE_ERR_NOT_AFFILIATE = 7;
    uint8 private constant _STAKE_ERR_NOT_STAKE = 8;
    uint8 private constant EXTERMINATOR_STAKE_MAX = 20;
    uint8 private constant MAP_STAKE_MAX = 20;
    uint8 private constant AFFILIATE_STAKE_MAX = 20;
    uint8 private constant STAKE_TROPHY_MAX = 20;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    uint16 private constant STAKE_TRAIT_SENTINEL = 0xFFFD;
    uint24 private constant STAKE_PREVIEW_START_LEVEL = 12;
    uint256 private constant LUCKBOX_BYPASS_THRESHOLD = 100_000 * 1_000_000;
    uint32 private constant DORMANT_EMIT_BATCH = 3500;

    function _currentBaseTokenId() private view returns (uint256) {
        return uint256(uint128(basePointers));
    }

    function _previousBaseTokenId() private view returns (uint256) {
        return basePointers >> 128;
    }

    function _setBasePointers(uint256 previousBase, uint256 currentBase) private {
        basePointers = (uint256(uint128(previousBase)) << 128) | uint128(currentBase);
    }

    function _packedTrophyBalance(uint256 packed) private pure returns (uint32) {
        return uint32((packed & _BITMASK_TROPHY_BALANCE) >> _BITPOS_TROPHY_BALANCE);
    }

    function _packedBalanceLevel(uint256 packed) private pure returns (uint24) {
        return uint24((packed & _BITMASK_BALANCE_LEVEL) >> _BITPOS_BALANCE_LEVEL);
    }

    function _updateTrophyBalance(address owner, int32 delta, uint24 lvl, bool setLevel) private {
        if (owner == address(0)) return;
        if (delta == 0 && !setLevel) return;

        uint256 packed = _packedAddressData[owner];
        uint256 current = (packed & _BITMASK_TROPHY_BALANCE) >> _BITPOS_TROPHY_BALANCE;
        uint256 updated = current;

        if (delta > 0) {
            unchecked {
                updated = current + uint32(delta);
            }
        } else if (delta < 0) {
            uint32 absDelta = uint32(-delta);
            unchecked {
                updated = current > absDelta ? current - absDelta : 0;
            }
        }

        uint256 cleared = packed & ~(_BITMASK_TROPHY_BALANCE | _BITMASK_BALANCE_LEVEL);
        uint24 levelValue = setLevel ? lvl : _packedBalanceLevel(packed);
        _packedAddressData[owner] =
            cleared |
            (updated << _BITPOS_TROPHY_BALANCE) |
            (uint256(levelValue) << _BITPOS_BALANCE_LEVEL);
    }

    function _mapMinimumQuantity(uint24 lvl) private pure returns (uint32) {
        uint24 mod = lvl % 100;
        if (mod >= 60) return 1;
        if (mod >= 40) return 2;
        return 4;
    }

    constructor(address regularRenderer_, address trophyRenderer_, address coin_) {
        regularRenderer = ITokenRenderer(regularRenderer_);
        trophyRenderer = ITokenRenderer(trophyRenderer_);
        coin = IPurgeCoin(coin_);
        _currentIndex = 97;
    }

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

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        uint256 info = address(trophyModule) == address(0) ? 0 : trophyModule.trophyData(tokenId);
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
        if (quantity == 0 || quantity > 5000) revert InvalidQuantity();

        address buyer = msg.sender;
        uint24 currentLevel = game.level();
        uint8 state = game.gameState();
        bool queueNext = state == 3;
        uint24 targetLevel = queueNext ? currentLevel + 1 : currentLevel;

        if ((targetLevel % 20) == 16) revert NotTimeYet();
        if (game.rngLocked()) revert RngNotReady();

        uint256 priceCoinUnit = game.coinPriceUnit();
        _enforceCenturyLuckbox(buyer, targetLevel, priceCoinUnit);

        uint256 bonusCoinReward = (quantity / 10) * priceCoinUnit;
        uint256 bonus;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            if (!game.coinMintUnlock(currentLevel)) revert NotTimeYet();
            _coinReceive(buyer, uint32(quantity), quantity * priceCoinUnit, targetLevel, bonusCoinReward);
        } else {
            uint8 phase = game.currentPhase();
            bool creditNext = (state == 3 || state == 1);
            bonus = _processEthPurchase(buyer, quantity * 100, affiliateCode, quantity, targetLevel, false, creditNext);
            if (phase == 3 && (targetLevel % 100) > 90) {
                bonus += (quantity * priceCoinUnit) / 5;
            }
        }

        bonus += bonusCoinReward;
        if (bonus != 0) {
            coin.bonusCoinflip(buyer, bonus, true);
        }

        uint32 qty32 = uint32(quantity);
        unchecked {
            _purchaseCount += qty32;
        }

        _recordPurchase(buyer, qty32);
    }

    function mintAndPurge(uint256 quantity, bool payInCoin, bytes32 affiliateCode) external payable {
        address buyer = msg.sender;
        uint256 priceUnit = game.coinPriceUnit();
        uint8 phase = game.currentPhase();
        uint8 state = game.gameState();
        uint24 lvl = game.level();
        if (state == 3) {
            unchecked {
                ++lvl;
            }
        }
        uint32 minQuantity = _mapMinimumQuantity(lvl);
        if (quantity < minQuantity || quantity > 10000) revert InvalidQuantity();
        if (game.rngLocked()) revert RngNotReady();

        _enforceCenturyLuckbox(buyer, lvl, priceUnit);

        uint256 coinCost = quantity * (priceUnit / 4);
        uint256 scaledQty = quantity * 25;
        uint256 mapRebate = (quantity / 4) * (priceUnit / 10);
        uint256 mapBonus = (quantity / 40) * priceUnit;

        uint256 bonus;

        if (payInCoin) {
            if (msg.value != 0) revert E();
            if (!game.coinMintUnlock(lvl)) revert NotTimeYet();
            _coinReceive(buyer, uint32(quantity), coinCost - mapRebate, lvl, mapBonus);
        } else {
            bool creditNext = (state == 3 || state == 1);
            bonus = _processEthPurchase(
                buyer,
                scaledQty,
                affiliateCode,
                (lvl < 10) ? quantity : 0,
                lvl,
                true,
                creditNext
            );
            if (phase == 3 && (lvl % 100) > 90) {
                bonus += coinCost / 5;
            }
        }

        uint256 rebateMint = bonus + mapRebate + mapBonus;
        if (rebateMint != 0) {
            coin.bonusCoinflip(buyer, rebateMint, true);
        }

        game.enqueueMap(buyer, uint32(quantity));
    }

    function _processEthPurchase(
        address payer,
        uint256 scaledQty,
        bytes32 affiliateCode,
        uint256 bonusUnits,
        uint24 lvl,
        bool mapPurchase,
        bool creditNextPool
    ) private returns (uint256 bonusMint) {
        uint256 expectedWei = (game.mintPrice() * scaledQty) / 100;

        if (mapPurchase) {
            uint8 mapDiscount = address(trophyModule) == address(0) ? 0 : trophyModule.mapStakeDiscount(payer);
            if (mapDiscount != 0) {
                uint256 discountWei = (expectedWei * mapDiscount) / 100;
                expectedWei -= discountWei;
            }
        } else {
            uint8 levelDiscount = address(trophyModule) == address(0)
                ? 0
                : trophyModule.exterminatorStakeDiscount(payer);
            if (levelDiscount != 0) {
                uint256 discountWei = (expectedWei * levelDiscount) / 100;
                expectedWei -= discountWei;
            }
        }

        if (msg.value != expectedWei) revert E();

        uint32 mintedQuantity = mapPurchase ? uint32(scaledQty / 25) : uint32(scaledQty / 100);

        uint256 streakBonus = game.recordMint{value: expectedWei}(payer, lvl, creditNextPool, false);

        if (mintedQuantity != 0) {
            coin.notifyQuestMint(payer, mintedQuantity, true);
        }

        uint256 priceUnit = game.coinPriceUnit();
        uint256 affiliateAmount = (scaledQty * priceUnit * 15) / 100;

        uint8 percentReached = game.getEarlyPurgePercent();
        uint256 pct = percentReached >= 50 ? 25 : 0;
        unchecked {
            affiliateAmount += (affiliateAmount * pct) / 100;
        }

        uint256 rakebackMint = coin.payAffiliate(affiliateAmount, affiliateCode, payer, lvl);

        bonusMint = (bonusUnits * priceUnit * pct) / 100;
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

    function _coinReceive(address payer, uint32 quantity, uint256 amount, uint24 lvl, uint256 discount) private {
        uint8 stepMod = uint8(lvl % 20);
        if (stepMod == 13) amount = (amount * 3) / 2;
        else if (stepMod == 18) amount = (amount * 9) / 10;
        if (discount != 0) amount -= discount;
        coin.burnCoin(payer, amount);
        game.recordMint(payer, lvl, false, true);
        if (quantity != 0) {
            coin.notifyQuestMint(payer, quantity, false);
        }
    }

    function _recordPurchase(address buyer, uint32 quantity) private {
        uint32 owed = _tokensOwed[buyer];
        if (owed == 0) {
            _pendingMintQueue.push(buyer);
        }

        unchecked {
            _tokensOwed[buyer] = owed + quantity;
        }
    }

    function processPendingMints(uint32 playersToProcess) external onlyGame returns (bool finished) {
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
            uint32 multiplier = game.purchaseMultiplier();
            if (multiplier == 0) {
                multiplier = 1;
            }
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

    function _enforceCenturyLuckbox(address player, uint24 lvl, uint256 unit) private view {
        if (lvl != 0 && (lvl % 100 == 0)) {
            uint256 luck = coin.playerLuckbox(player);
            uint256 required = 20 * unit * ((lvl / 100) + 1);
            if (luck < required) revert LuckboxTooSmall();
            if (luck < required + LUCKBOX_BYPASS_THRESHOLD) {
                uint24 lastLevel = game.ethMintLastLevel(player);
                if (uint256(lastLevel) + 1 != uint256(lvl)) revert LuckboxTooSmall();
            }
        }
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return address(uint160(_packedOwnershipOf(tokenId)));
    }

    function _packedOwnershipOf(uint256 tokenId) private view returns (uint256 packed) {
        if (tokenId >= _currentIndex) revert InvalidToken();

        packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            unchecked {
                uint256 curr = tokenId;
                while (true) {
                    packed = _packedOwnerships[--curr];
                    if (packed != 0) break;
                }
            }
        }

        if (
            tokenId < _currentBaseTokenId() && (address(trophyModule) == address(0) || !trophyModule.hasTrophy(tokenId))
        ) {
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
                while (true) {
                    packed = _packedOwnerships[--curr];
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

    function _exists(uint256 tokenId) internal view returns (bool) {
        if (tokenId < _currentBaseTokenId()) {
            if (address(trophyModule) != address(0) && trophyModule.hasTrophy(tokenId)) return true;
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
            while ((packed = _packedOwnerships[tokenId]) == 0) {
                unchecked {
                    --tokenId;
                }
            }
            return packed & _BITMASK_BURNED == 0;
        }

        return false;
    }

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

    function _mint(address to, uint256 quantity) internal {
        uint256 startTokenId = _currentIndex;

        unchecked {
            _packedOwnerships[startTokenId] = _packOwnershipData(to, quantity == 1 ? _BITMASK_NEXT_INITIALIZED : 0);

            _packedAddressData[to] += quantity * ((1 << _BITPOS_NUMBER_MINTED) | 1);

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

    function wireContracts(address game_) external {
        if (msg.sender != address(coin)) revert E();
        _wireGame(game_);
    }

    function wireTrophies(address trophies_) external onlyCoinContract {
        _wireTrophies(trophies_);
    }

    function wireAll(address game_, address trophies_) external onlyCoinContract {
        _wireGame(game_);
        _wireTrophies(trophies_);
    }

    function _wireGame(address game_) private {
        game = IPurgeGame(game_);
    }

    function _wireTrophies(address trophies_) private {
        if (trophies_ == address(0)) revert E();
        if (address(trophyModule) != address(0)) revert E();
        trophyModule = IPurgeGameTrophies(trophies_);
    }

    // ---------------------------------------------------------------------
    // Trophy module hooks
    // ---------------------------------------------------------------------

    function nextTokenId() external view onlyTrophyModule returns (uint256) {
        return _currentIndex;
    }

    function mintPlaceholders(uint256 quantity) external onlyTrophyModule returns (uint256 startTokenId) {
        if (quantity == 0) revert E();
        startTokenId = _currentIndex;
        address gameAddr = address(game);
        _mint(gameAddr, quantity);
        unchecked {
            totalTrophySupply += quantity;
        }
        if (gameAddr != address(0)) {
            _updateTrophyBalance(gameAddr, 0, game.level(), true);
        }
        return startTokenId;
    }

    function scheduleDormantRange(uint256 startTokenId, uint256 endTokenId) external onlyTrophyModule {
        if (startTokenId >= endTokenId) return;
        _dormantCursor.push(startTokenId);
        _dormantEnd.push(endTokenId);
    }

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
                burnDelta += _ADDRESS_DATA_BURN_DELTA;
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

    function getBasePointers() external view onlyTrophyModule returns (uint256 previousBase, uint256 currentBase) {
        previousBase = basePointers >> 128;
        currentBase = _currentBaseTokenId();
    }

    function setBasePointers(uint256 previousBase, uint256 currentBase) external onlyTrophyModule {
        _setBasePointers(previousBase, currentBase);
    }

    function packedOwnershipOf(uint256 tokenId) external view onlyTrophyModule returns (uint256 packed) {
        return _packedOwnershipOf(tokenId);
    }

    function transferTrophy(address from, address to, uint256 tokenId) external onlyTrophyModule {
        _moduleTransfer(from, to, tokenId);
    }

    function setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool staked) external onlyTrophyModule {
        _setTrophyPackedInfo(tokenId, kind, staked);
    }

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

    function gameAddress() external view returns (address) {
        return address(game);
    }

    function coinAddress() external view returns (address) {
        return address(coin);
    }

    // ---------------------------------------------------------------------
    // VRF / RNG
    // ---------------------------------------------------------------------

    function _setSeasonMintedSnapshot(uint256 minted) private {
        seasonMintedSnapshot = minted;
        seasonPurgedCount = 0;
    }

    function finalizePurchasePhase(uint32 minted) external onlyGame {
        _setSeasonMintedSnapshot(minted);
        uint256 baseTokenId = _currentBaseTokenId();

        uint256 startId = baseTokenId + uint256(minted);
        _nextBaseTokenIdHint = ((startId + 99) / 100) * 100 + 1;
        _purchaseCount = 0;
        _mintQueueIndex = 0;
        uint256 queueLength = _pendingMintQueue.length;
        if (queueLength > 1) {
            uint256 entropy = game.currentRngWord();
            _mintQueueStartOffset = ((entropy % (queueLength - 1)) + 1);
        } else {
            _mintQueueStartOffset = 0;
        }
    }

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
                burnDelta += _ADDRESS_DATA_BURN_DELTA;
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

    function _burnPacked(uint256 tokenId, uint256 prevOwnershipPacked) private returns (bool isTrophy) {
        address from = address(uint160(prevOwnershipPacked));
        isTrophy = (prevOwnershipPacked & _BITMASK_TROPHY_ACTIVE) != 0;

        _packedOwnerships[tokenId] = _packOwnershipData(from, _BITMASK_BURNED | _BITMASK_NEXT_INITIALIZED);

        if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
            uint256 nextId = tokenId + 1;
            if (_packedOwnerships[nextId] == 0 && nextId != _currentIndex) {
                _packedOwnerships[nextId] = prevOwnershipPacked;
            }
        }

        emit Transfer(from, address(0), tokenId);
    }

    function _applyPurgeAccounting(address owner, uint256 burnDelta, uint32 trophiesBurned) private {
        uint256 packedData = _packedAddressData[owner];
        unchecked {
            packedData += burnDelta;
        }

        uint24 currentLevel = game.level();

        if (trophiesBurned != 0) {
            uint256 current = (packedData & _BITMASK_TROPHY_BALANCE) >> _BITPOS_TROPHY_BALANCE;
            uint256 updated = current > trophiesBurned ? current - trophiesBurned : 0;
            packedData = (packedData & ~_BITMASK_TROPHY_BALANCE) | (updated << _BITPOS_TROPHY_BALANCE);
        }

        packedData = (packedData & ~_BITMASK_BALANCE_LEVEL) | (uint256(currentLevel) << _BITPOS_BALANCE_LEVEL);
        _packedAddressData[owner] = packedData;
    }

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

    function _moduleTransfer(address from, address to, uint256 tokenId) private {
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);
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

    function _setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool staked) private {
        uint256 packed = _packedOwnerships[tokenId];
        if (packed == 0) {
            packed = _packedOwnershipOf(tokenId);
        }
        address owner = address(uint160(packed));
        bool wasActive = (packed & _BITMASK_TROPHY_ACTIVE) != 0;
        bool isActive;
        IPurgeGameTrophies module = trophyModule;

        isActive = module.hasTrophy(tokenId);

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

    function tokensOwed(address player) external view returns (uint32) {
        return _tokensOwed[player];
    }

    function resetPurchaseCount() external onlyGame {
        _purchaseCount = 0;
    }

    function getTrophyData(
        uint256 tokenId
    )
        external
        view
        returns (uint256 owedWei, uint24 baseLevel, uint24 lastClaimLevel, uint16 traitId, uint8 trophyKind)
    {
        uint256 raw = address(trophyModule) == address(0) ? 0 : trophyModule.trophyData(tokenId);
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
