// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;



interface IERC721A {
    error ApprovalCallerNotOwnerNorApproved();

    error ApprovalQueryForNonexistentToken();

    error BalanceQueryForZeroAddress();

    error MintToZeroAddress();

    error MintZeroQuantity();

    error OwnerQueryForNonexistentToken();

    error TransferCallerNotOwnerNorApproved();

    error TransferFromIncorrectOwner();

    error TransferToNonERC721ReceiverImplementer();

    error TransferToZeroAddress();

    error URIQueryForNonexistentToken();

    error OwnershipNotInitializedForExtraData();


    function totalSupply() external view returns (uint256);


    function supportsInterface(bytes4 interfaceId) external view returns (bool);


    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function balanceOf(address owner) external view returns (uint256 balance);

    function ownerOf(uint256 tokenId) external view returns (address owner);

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external payable;

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external payable;

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external payable;

    function approve(address to, uint256 tokenId) external payable;

    function setApprovalForAll(address operator, bool _approved) external;

    function getApproved(uint256 tokenId) external view returns (address operator);

    function isApprovedForAll(address owner, address operator) external view returns (bool);


    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function tokenURI(uint256 tokenId) external view returns (string memory);


    event ConsecutiveTransfer(uint256 indexed fromTokenId, uint256 toTokenId, address indexed from, address indexed to);
}




interface ERC721A__IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

interface IPurgeRenderer {
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory);
}

interface IPurgeGame {
    function describeBaseToken(uint256 tokenId)
        external
        view
        returns (uint256 metaPacked, uint32[4] memory remaining);

    function level() external view returns (uint24);

    function gameState() external view returns (uint8);
}

interface IPurgecoin {
    function bonusCoinflip(address player, uint256 amount) external;

    function isBettingPaused() external view returns (bool);
}

contract PurgeGameNFT is IERC721A {
    struct TokenApprovalRef {
        address value;
    }


    uint256 private constant _BITMASK_ADDRESS_DATA_ENTRY = (1 << 64) - 1;

    uint256 private constant _BITPOS_NUMBER_MINTED = 64;

    uint256 private constant _BITPOS_NUMBER_BURNED = 128;

    uint256 private constant _BITPOS_START_TIMESTAMP = 160;

    uint256 private constant _BITMASK_BURNED = 1 << 224;

    uint256 private constant _BITPOS_NEXT_INITIALIZED = 225;

    uint256 private constant _BITMASK_NEXT_INITIALIZED = 1 << 225;

    uint256 private constant _BITPOS_EXTRA_DATA = 232;

    uint256 private constant _BITMASK_EXTRA_DATA_COMPLEMENT = (1 << 232) - 1;

    uint256 private constant _BITMASK_ADDRESS = (1 << 160) - 1;

    bytes32 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    address private constant _TROPHY_BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;


    uint256 private _currentIndex;

    uint256 private _burnCounter;

    string private _name;

    string private _symbol;

    mapping(uint256 => uint256) private _packedOwnerships;

    mapping(address => uint256) private _packedAddressData;

    mapping(uint256 => TokenApprovalRef) private _tokenApprovals;

    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // ---------------------------------------------------------------------
    // Purge game state
    // ---------------------------------------------------------------------
    error E();
    error NotTokenOwner();
    error NotTrophyOwner();
    error ClaimNotReady();
    error CoinPaused();
    error OnlyCoin();
    error InvalidToken();

    IPurgeGame private game;
    IPurgeRenderer private immutable renderer;
    IPurgecoin private immutable coin;

    uint256 private basePointers; // high 128 bits = previous base token id, low 128 bits = current base token id
    mapping(uint256 => uint256) private trophyData; // Packed metadata + owed + claim bookkeeping per trophy

    struct EndLevelRequest {
        address exterminator;
        uint8 traitId;
        uint24 level;
        uint256 pool;
        uint256 randomWord;
    }

    uint256[] private mapTrophyIds;
    uint256[] private levelTrophyIds;

    uint256 private seasonMintedSnapshot;
    uint256 private seasonPurgedCount;

    uint32 private constant COIN_DRIP_STEPS = 10; // MAP coin drip cadence
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * 1_000_000; // 1000 PURGED (6 decimals)
    uint256 private constant TROPHY_FLAG_MAP = uint256(1) << 200;
    uint256 private constant TROPHY_OWED_MASK = (uint256(1) << 128) - 1;
    uint256 private constant TROPHY_BASE_LEVEL_SHIFT = 128;
    uint256 private constant TROPHY_BASE_LEVEL_MASK = uint256(0xFFFFFF) << TROPHY_BASE_LEVEL_SHIFT;
    uint256 private constant TROPHY_LAST_CLAIM_SHIFT = 168;
    uint256 private constant TROPHY_LAST_CLAIM_MASK = uint256(0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT;

    function _currentBaseTokenId() private view returns (uint256) {
        return uint256(uint128(basePointers));
    }

    function _previousBaseTokenId() private view returns (uint256) {
        return basePointers >> 128;
    }

    function _setBasePointers(uint256 previousBase, uint256 currentBase) private {
        basePointers = (uint256(uint128(previousBase)) << 128) | uint128(currentBase);
    }


    constructor(address renderer_, address coin_) {
        _name = "Purge Game";
        _symbol = "PG";
        renderer = IPurgeRenderer(renderer_);
        coin = IPurgecoin(coin_);
    }


    function totalSupply() public view virtual override returns (uint256) {
        uint256 trophyCount = mapTrophyIds.length + levelTrophyIds.length;

        if (game.gameState() == 4) {
            uint256 minted = seasonMintedSnapshot;
            uint256 purged = seasonPurgedCount;
            uint256 active = minted > purged ? minted - purged : 0;
            return trophyCount + active;
        }

        return trophyCount;
    }

    function balanceOf(address owner) public view virtual override returns (uint256) {
        if (owner == address(0)) _revert(BalanceQueryForZeroAddress.selector);
        return _packedAddressData[owner] & _BITMASK_ADDRESS_DATA_ENTRY;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == 0x01ffc9a7 || // ERC165 interface ID for ERC165.
            interfaceId == 0x80ac58cd || // ERC165 interface ID for ERC721.
            interfaceId == 0x5b5e139f; // ERC165 interface ID for ERC721Metadata.
    }


    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        uint256 info = trophyData[tokenId];
        if (info != 0) {
            uint32[4] memory empty;
            return renderer.tokenURI(tokenId, info, empty);
        } else if (tokenId < _currentBaseTokenId()) {
            revert InvalidToken();
        }

        (uint256 metaPacked, uint32[4] memory remaining) = game.describeBaseToken(tokenId);
        return renderer.tokenURI(tokenId, metaPacked, remaining);
    }

    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        return address(uint160(_packedOwnershipOf(tokenId)));
    }

    function _packedOwnershipOf(uint256 tokenId) private view returns (uint256 packed) {
        if (tokenId >= _currentIndex) {
            if (trophyData[tokenId] != 0) return _packedTrophyBurnOwner();
            _revert(OwnerQueryForNonexistentToken.selector);
        }

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
            if (trophyData[tokenId] != 0) return _packedTrophyBurnOwner();
            _revert(OwnerQueryForNonexistentToken.selector);
        }

        return packed;
    }

    function _packedTrophyBurnOwner() private pure returns (uint256) {
        return uint256(uint160(_TROPHY_BURN_ADDRESS));
    }

    function _packOwnershipData(address owner, uint256 flags) private view returns (uint256 result) {
        assembly {
            owner := and(owner, _BITMASK_ADDRESS)
            result := or(owner, or(shl(_BITPOS_START_TIMESTAMP, timestamp()), flags))
        }
    }

    function _nextInitializedFlag(uint256 quantity) private pure returns (uint256 result) {
        assembly {
            result := shl(_BITPOS_NEXT_INITIALIZED, eq(quantity, 1))
        }
    }


    function approve(address to, uint256 tokenId) public payable virtual override {
        _approve(to, tokenId, true);
    }

    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        if (!_exists(tokenId)) _revert(ApprovalQueryForNonexistentToken.selector);

        return _tokenApprovals[tokenId].value;
    }

    function setApprovalForAll(address operator, bool approved) public virtual override {
        _operatorApprovals[_msgSenderERC721A()][operator] = approved;
        emit ApprovalForAll(_msgSenderERC721A(), operator, approved);
    }

    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        if (tokenId < _currentBaseTokenId()) {
            return trophyData[tokenId] != 0;
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

    function _getApprovedSlotAndAddress(uint256 tokenId)
        private
        view
        returns (uint256 approvedAddressSlot, address approvedAddress)
    {
        TokenApprovalRef storage tokenApproval = _tokenApprovals[tokenId];
        assembly {
            approvedAddressSlot := tokenApproval.slot
            approvedAddress := sload(approvedAddressSlot)
        }
    }


    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public payable virtual override {
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);

        from = address(uint160(uint256(uint160(from)) & _BITMASK_ADDRESS));

        if (address(uint160(prevOwnershipPacked)) != from) _revert(TransferFromIncorrectOwner.selector);

        (uint256 approvedAddressSlot, address approvedAddress) = _getApprovedSlotAndAddress(tokenId);

        if (!_isSenderApprovedOrOwner(approvedAddress, from, _msgSenderERC721A()))
            if (!isApprovedForAll(from, _msgSenderERC721A())) _revert(TransferCallerNotOwnerNorApproved.selector);

        _beforeTokenTransfers(from, to, tokenId, 1);

        assembly {
            if approvedAddress {
                sstore(approvedAddressSlot, 0)
            }
        }

        unchecked {
            --_packedAddressData[from]; // Updates: `balance -= 1`.
            ++_packedAddressData[to]; // Updates: `balance += 1`.

            _packedOwnerships[tokenId] = _packOwnershipData(
                to,
                _BITMASK_NEXT_INITIALIZED | _nextExtraData(from, to, prevOwnershipPacked)
            );

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextTokenId = tokenId + 1;
                if (_packedOwnerships[nextTokenId] == 0) {
                    if (nextTokenId != _currentIndex) {
                        _packedOwnerships[nextTokenId] = prevOwnershipPacked;
                    }
                }
            }
        }

        uint256 toMasked = uint256(uint160(to)) & _BITMASK_ADDRESS;
        assembly {
            log4(
                0, // Start of data (0, since no data).
                0, // End of data (0, since no data).
                _TRANSFER_EVENT_SIGNATURE, // Signature.
                from, // `from`.
                toMasked, // `to`.
                tokenId // `tokenId`.
            )
        }
        if (toMasked == 0) _revert(TransferToZeroAddress.selector);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public payable virtual override {
        safeTransferFrom(from, to, tokenId, '');
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public payable virtual override {
        transferFrom(from, to, tokenId);
        if (to.code.length != 0)
            if (!_checkContractOnERC721Received(from, to, tokenId, _data)) {
                _revert(TransferToNonERC721ReceiverImplementer.selector);
            }
    }

    function _checkContractOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) private returns (bool) {
        try ERC721A__IERC721Receiver(to).onERC721Received(_msgSenderERC721A(), from, tokenId, _data) returns (
            bytes4 retval
        ) {
            return retval == ERC721A__IERC721Receiver(to).onERC721Received.selector;
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                _revert(TransferToNonERC721ReceiverImplementer.selector);
            }
            assembly {
                revert(add(32, reason), mload(reason))
            }
        }
    }


    function _mint(address to, uint256 quantity) internal virtual {
        uint256 startTokenId = _currentIndex;
        if (quantity == 0) _revert(MintZeroQuantity.selector);

        _beforeTokenTransfers(address(0), to, startTokenId, quantity);

        unchecked {
            _packedOwnerships[startTokenId] = _packOwnershipData(
                to,
                _nextInitializedFlag(quantity) | _nextExtraData(address(0), to, 0)
            );

            _packedAddressData[to] += quantity * ((1 << _BITPOS_NUMBER_MINTED) | 1);

            uint256 toMasked = uint256(uint160(to)) & _BITMASK_ADDRESS;

            if (toMasked == 0) _revert(MintToZeroAddress.selector);

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

    function _approve(address to, uint256 tokenId) internal virtual {
        _approve(to, tokenId, false);
    }

    function _approve(
        address to,
        uint256 tokenId,
        bool approvalCheck
    ) internal virtual {
        address owner = ownerOf(tokenId);

        if (approvalCheck && _msgSenderERC721A() != owner)
            if (!isApprovedForAll(owner, _msgSenderERC721A())) {
                _revert(ApprovalCallerNotOwnerNorApproved.selector);
            }

        _tokenApprovals[tokenId].value = to;
        emit Approval(owner, to, tokenId);
    }


    function _burn(uint256 tokenId) internal virtual {
        _burn(tokenId, false);
    }

    function _burn(uint256 tokenId, bool approvalCheck) internal virtual {
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);

        address from = address(uint160(prevOwnershipPacked));

        (uint256 approvedAddressSlot, address approvedAddress) = _getApprovedSlotAndAddress(tokenId);

        if (approvalCheck) {
            if (!_isSenderApprovedOrOwner(approvedAddress, from, _msgSenderERC721A()))
                if (!isApprovedForAll(from, _msgSenderERC721A())) _revert(TransferCallerNotOwnerNorApproved.selector);
        }

        _beforeTokenTransfers(from, address(0), tokenId, 1);

        assembly {
            if approvedAddress {
                sstore(approvedAddressSlot, 0)
            }
        }

        unchecked {
            _packedAddressData[from] += (1 << _BITPOS_NUMBER_BURNED) - 1;

            _packedOwnerships[tokenId] = _packOwnershipData(
                from,
                (_BITMASK_BURNED | _BITMASK_NEXT_INITIALIZED) | _nextExtraData(from, address(0), prevOwnershipPacked)
            );

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextTokenId = tokenId + 1;
                if (_packedOwnerships[nextTokenId] == 0) {
                    if (nextTokenId != _currentIndex) {
                        _packedOwnerships[nextTokenId] = prevOwnershipPacked;
                    }
                }
            }
        }

        emit Transfer(from, address(0), tokenId);

        unchecked {
            _burnCounter++;
        }
    }


    function _setExtraDataAt(uint256 index, uint24 extraData) internal virtual {
        uint256 packed = _packedOwnerships[index];
        if (packed == 0) _revert(OwnershipNotInitializedForExtraData.selector);
        uint256 extraDataCasted;
        assembly {
            extraDataCasted := extraData
        }
        packed = (packed & _BITMASK_EXTRA_DATA_COMPLEMENT) | (extraDataCasted << _BITPOS_EXTRA_DATA);
        _packedOwnerships[index] = packed;
    }

    function _extraData(
        address from,
        address to,
        uint24 previousExtraData
    ) internal view virtual returns (uint24) {}

    function _nextExtraData(
        address from,
        address to,
        uint256 prevOwnershipPacked
    ) private view returns (uint256) {
        uint24 extraData = uint24(prevOwnershipPacked >> _BITPOS_EXTRA_DATA);
        return uint256(_extraData(from, to, extraData)) << _BITPOS_EXTRA_DATA;
    }


    function _msgSenderERC721A() internal view virtual returns (address) {
        return msg.sender;
    }

    function _toString(uint256 value) internal pure virtual returns (string memory str) {
        assembly {
            let m := add(mload(0x40), 0xa0)
            mstore(0x40, m)
            str := sub(m, 0x20)
            mstore(str, 0)

            let end := str

            for { let temp := value } 1 {} {
                str := sub(str, 1)
                mstore8(str, add(48, mod(temp, 10)))
                temp := div(temp, 10)
                if iszero(temp) { break }
            }

            let length := sub(end, str)
            str := sub(str, 0x20)
            mstore(str, length)
        }
    }

    function _revert(bytes4 errorSelector) internal pure {
        assembly {
            mstore(0x00, errorSelector)
            revert(0x00, 0x04)
        }
    }

    // ---------------------------------------------------------------------
    // Purge game wiring
    // ---------------------------------------------------------------------

    modifier onlyGame() {
        if (msg.sender != address(game)) revert E();
        _;
    }

    function wireContracts(address game_) external {
        if (msg.sender != address(coin)) revert E();
        game = IPurgeGame(game_);
        uint256 currentBase = _mintTrophyPlaceholders(1);
        _setBasePointers(0, currentBase);
    }

    // ---------------------------------------------------------------------
    // Game operations
    // ---------------------------------------------------------------------

    function gameMint(address to, uint256 quantity) external onlyGame returns (uint256 startTokenId) {
        startTokenId = _currentIndex;
        _mint(to, quantity);
    }

    function prepareNextLevel(uint24 nextLevel) external onlyGame {
        uint256 previousBase = _currentBaseTokenId();
        uint256 currentBase = _mintTrophyPlaceholders(nextLevel);
        _setBasePointers(previousBase, currentBase);
    }

    function recordSeasonMinted(uint256 minted) external onlyGame {
        seasonMintedSnapshot = minted;
        seasonPurgedCount = 0;
    }

    function _mintTrophyPlaceholders(uint24 level) private returns (uint256 newBaseTokenId) {
        uint256 startId = _currentIndex;
        _mint(address(game), 2);
        uint256 mapTokenId = startId;
        uint256 levelTokenId = startId + 1;
        trophyData[mapTokenId] =
            (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_MAP;
        trophyData[levelTokenId] = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT);
        newBaseTokenId = levelTokenId + 1;
    }

    function purge(address owner, uint256[] calldata tokenIds) external onlyGame {
        uint256 purged;
        uint256 len = tokenIds.length;
        uint256 baseLimit = _currentBaseTokenId();
        for (uint256 i; i < len; ) {
            uint256 tokenId = tokenIds[i];
            if (tokenId < baseLimit) revert InvalidToken();
            _purgeToken(owner, tokenId);
            unchecked {
                ++purged;
                ++i;
            }
        }
        if (purged != 0) {
            uint256 snapshot = seasonMintedSnapshot;
            uint256 current = seasonPurgedCount;
            uint256 cap = snapshot > current ? snapshot - current : 0;
            uint256 add = purged > cap ? cap : purged;
            if (add != 0) {
                seasonPurgedCount = current + add;
            }
        }
    }

    function _purgeToken(address owner, uint256 tokenId) private {
        uint256 packed = _packedOwnershipOf(tokenId);
        if (address(uint160(packed)) != owner) revert NotTokenOwner();
        _burnPacked(tokenId, packed);
    }

    function _burnPacked(uint256 tokenId, uint256 prevOwnershipPacked) private {
        address from = address(uint160(prevOwnershipPacked));
        (uint256 approvedAddressSlot, address approvedAddress) = _getApprovedSlotAndAddress(tokenId);

        _beforeTokenTransfers(from, address(0), tokenId, 1);

        assembly {
            if approvedAddress {
                sstore(approvedAddressSlot, 0)
            }
        }

        unchecked {
            _packedAddressData[from] += (1 << _BITPOS_NUMBER_BURNED) - 1;

            _packedOwnerships[tokenId] = _packOwnershipData(
                from,
                (_BITMASK_BURNED | _BITMASK_NEXT_INITIALIZED) | _nextExtraData(from, address(0), prevOwnershipPacked)
            );

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextTokenId = tokenId + 1;
                if (_packedOwnerships[nextTokenId] == 0 && nextTokenId != _currentIndex) {
                    _packedOwnerships[nextTokenId] = prevOwnershipPacked;
                }
            }
        }

        emit Transfer(from, address(0), tokenId);

        unchecked {
            _burnCounter++;
        }
    }

    function awardTrophy(address to, uint256 data, uint256 deferredWei) external payable onlyGame {
        bool isMap = (data & TROPHY_FLAG_MAP) != 0;
        uint256 baseTokenId = _currentBaseTokenId();
        uint256 tokenId = isMap ? (baseTokenId - 2) : (baseTokenId - 1);
        _awardTrophy(to, data, deferredWei, tokenId);
    }

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        onlyGame
        returns (address mapImmediateRecipient)
    {
        uint24 nextLevel = req.level + 1;
        uint256 previousBase = _previousBaseTokenId();
        uint256 levelTokenId = previousBase - 1;
        uint256 mapTokenId = previousBase - 2;

        bool traitWin = req.exterminator != address(0);
        uint256 randomWord = req.randomWord;

        if (traitWin) {
            uint256 traitData = (uint256(req.traitId) << 152) | (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT);
            uint256 legacyPool = (req.level > 1) ? (req.pool / 20) : 0;
            uint256 deferredAward = msg.value;
            if (legacyPool != 0) {
                deferredAward -= legacyPool;
            }
            _awardTrophy(req.exterminator, traitData, deferredAward, levelTokenId);

            if (legacyPool != 0) {
                uint256[] storage source = levelTrophyIds;
                uint256 trophyCount = source.length;
                if (trophyCount != 0) {
                    uint256 draws = trophyCount < 3 ? trophyCount : 3;
                    uint256 baseShare = legacyPool / draws;
                    uint256 rand = randomWord;
                    uint256 mask = type(uint64).max;
                    for (uint256 i; i < draws; ) {
                        uint256 idx = trophyCount == 1 ? 0 : (rand & mask) % trophyCount;
                        rand >>= 64;
                        _addTrophyReward(source[idx], baseShare, nextLevel);
                        unchecked {
                            ++i;
                        }
                    }
                }
            }
        } else {
            uint256 poolCarry = req.pool;
            uint256 mapUnit = poolCarry / 20;

            mapImmediateRecipient = ownerOf(mapTokenId);

            delete trophyData[levelTokenId];

            uint256 valueIn = msg.value;
            _addTrophyReward(mapTokenId, mapUnit, nextLevel);
            valueIn -= mapUnit;

            uint256 draws = valueIn / mapUnit;
            uint256 mapCount = mapTrophyIds.length;
            for (uint256 j; j < draws; ) {
                uint256 idx = mapCount == 1 ? 0 : (randomWord & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) % mapCount;
                uint256 tokenId = mapTrophyIds[idx];
                _addTrophyReward(tokenId, mapUnit, nextLevel);
                randomWord >>= 64;
                unchecked {
                    ++j;
                }
            }
        }
    }

    function claimTrophyReward(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        uint256 info = trophyData[tokenId];
        if (info == 0) revert InvalidToken();

        uint256 owed = info & TROPHY_OWED_MASK;
        if (owed == 0) revert ClaimNotReady();

        uint24 currentLevel = game.level();
        uint24 lastClaim = uint24((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);
        if (currentLevel <= lastClaim) revert ClaimNotReady();

        uint24 baseStartLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + 1;
        if (currentLevel < baseStartLevel) revert ClaimNotReady();

        uint32 vestEnd = uint32(baseStartLevel) + COIN_DRIP_STEPS;
        uint256 denom = vestEnd > currentLevel ? vestEnd - currentLevel : 1;
        uint256 payout = owed / denom;

        info = (info & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK))
            | ((owed - payout) & TROPHY_OWED_MASK)
            | (uint256(currentLevel & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
        trophyData[tokenId] = info;

        (bool ok, ) = msg.sender.call{value: payout}("");
        if (!ok) revert E();

        emit TrophyRewardClaimed(tokenId, msg.sender, payout);
    }

    event TrophyRewardClaimed(uint256 indexed tokenId, address indexed claimant, uint256 amount);

    function burnieNFT() external {
        if (msg.sender != address(coin)) revert OnlyCoin();
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok, ) = payable(msg.sender).call{value: bal}("");
        if (!ok) revert E();
    }

    // ---------------------------------------------------------------------
    // MAP Purgecoin drip
    // ---------------------------------------------------------------------

    function claimMapTrophyCoin(uint256 tokenId) external {
        if (coin.isBettingPaused()) revert CoinPaused();
        if (ownerOf(tokenId) != msg.sender) revert NotTrophyOwner();

        uint256 info = trophyData[tokenId];
        if (info == 0 || (info & TROPHY_FLAG_MAP) == 0) revert ClaimNotReady();

        uint32 start = uint32((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
        uint32 levelNow = game.level();
        uint32 floor = start - 1;

        if (levelNow <= floor) revert ClaimNotReady();

        uint32 last = uint32((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);
        if (last < floor) last = floor;
        if (levelNow <= last) revert ClaimNotReady();

        uint32 from = last + 1;
        uint32 offsetStart = from - start;
        uint32 offsetEnd = levelNow - start;

        uint256 span = uint256(offsetEnd - offsetStart + 1);

        uint256 blocksEnd = offsetEnd / 10;
        uint256 blocksStart = offsetStart / 10;
        uint256 remEnd = offsetEnd % 10;
        uint256 remStart = offsetStart % 10;

        uint256 prefixEnd = ((blocksEnd * (blocksEnd - 1)) / 2) * 10 + blocksEnd * (remEnd + 1);
        uint256 prefixStart = ((blocksStart * (blocksStart - 1)) / 2) * 10 + blocksStart * (remStart + 1);

        uint256 claimable = COIN_EMISSION_UNIT * (span + (prefixEnd - prefixStart));

        info = (info & ~TROPHY_LAST_CLAIM_MASK) | (uint256(levelNow & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
        trophyData[tokenId] = info;
        coin.bonusCoinflip(msg.sender, claimable);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function currentBaseTokenId() external view returns (uint256) {
        return _currentBaseTokenId();
    }

    function getTrophyData(uint256 tokenId)
        external
        view
        returns (uint256 owedWei, uint24 baseLevel, uint24 lastClaimLevel, uint16 traitId, bool isMap)
    {
        uint256 raw = trophyData[tokenId];
        owedWei = raw & TROPHY_OWED_MASK;
        uint256 shiftedBase = raw >> TROPHY_BASE_LEVEL_SHIFT;
        baseLevel = uint24(shiftedBase);
        lastClaimLevel = uint24((raw >> TROPHY_LAST_CLAIM_SHIFT));
        traitId = uint16(raw >> 152);
        isMap = (raw & TROPHY_FLAG_MAP) != 0;
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _awardTrophy(address to, uint256 data, uint256 deferredWei, uint256 tokenId) private {
        bool isMap = (data & TROPHY_FLAG_MAP) != 0;
        address currentOwner = ownerOf(tokenId);
        if (currentOwner == address(game)) {
            transferFrom(address(game), to, tokenId);
            if (isMap) {
                mapTrophyIds.push(tokenId);
            } else {
                levelTrophyIds.push(tokenId);
            }
        }

        uint256 newData = data & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK);
        uint256 owed = deferredWei & TROPHY_OWED_MASK;
        newData |= owed;
        trophyData[tokenId] = newData;
    }

    function _addTrophyReward(uint256 tokenId, uint256 amountWei, uint24 startLevel) private {
        uint256 info = trophyData[tokenId];
        uint256 owed = (info & TROPHY_OWED_MASK) + amountWei;
        uint256 base = uint256((startLevel - 1) & 0xFFFFFF);
        uint256 updated = (info & ~(TROPHY_OWED_MASK | TROPHY_BASE_LEVEL_MASK))
            | (owed & TROPHY_OWED_MASK)
            | (base << TROPHY_BASE_LEVEL_SHIFT);
        trophyData[tokenId] = updated;
    }
}
