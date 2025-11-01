// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

struct VRFRandomWordsRequest {
    bytes32 keyHash;
    uint256 subId;
    uint16 requestConfirmations;
    uint32 callbackGasLimit;
    uint32 numWords;
    bytes extraArgs;
}

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

interface IPurgeGame {
    function describeBaseToken(uint256 tokenId)
        external
        view
        returns (uint256 metaPacked, uint32[4] memory remaining);

    function level() external view returns (uint24);

    function gameState() external view returns (uint8);
}

interface IPurgecoin {
    function bonusCoinflip(address player, uint256 amount, bool rngReady, uint256 luckboxBonus) external;

    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory);
}

interface IVRFCoordinator {
    function requestRandomWords(
        VRFRandomWordsRequest calldata request
    ) external returns (uint256);

    function getSubscription(
        uint256 subId
    )
        external
        view
        returns (uint96 balance, uint96 premium, uint64 reqCount, address owner, address[] memory consumers);
}

interface ILinkToken {
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);
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
    error CoinPaused();
    error OnlyCoin();
    error InvalidToken();
    error TrophyStakeViolation(uint8 reason);
    error StakeInvalid();
    error OnlyCoordinatorCanFulfill(address have, address want);

    // ---------------------------------------------------------------------
    // Events & types
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
event TrophyRewardClaimed(uint256 indexed tokenId, address indexed claimant, uint256 amount);
event TrophyStakeChanged(
    address indexed owner,
    uint256 indexed tokenId,
    uint8 kind,
    bool staked,
    uint8 count,
    uint16 mapBonusBps
);
event StakeTrophyAwarded(address indexed to, uint256 indexed tokenId, uint24 level, uint256 principal);

    struct EndLevelRequest {
        address exterminator;
        uint16 traitId;
        uint24 level;
        uint256 pool;
    }

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
    IPurgecoin private immutable coin;
    IVRFCoordinator private immutable vrfCoordinator;
    bytes32 private immutable vrfKeyHash;
    uint256 private immutable vrfSubscriptionId;
    address private immutable linkToken;

    uint256 private basePointers; // high 128 bits = previous base token id, low 128 bits = current base token id
    mapping(uint256 => uint256) private trophyData; // Packed metadata + owed + claim bookkeeping per trophy

    uint256[] private stakedTrophyIds;
    mapping(uint256 => uint256) private stakedTrophyIndex; // 1-based index for packed removal
    uint256 private totalTrophySupply;

    uint256 private seasonMintedSnapshot;
    uint256 private seasonPurgedCount;

    mapping(uint256 => bool) private trophyStaked;
    mapping(address => uint8) private levelStakeCount;
    mapping(address => uint8) private affiliateStakeCount;
    mapping(address => uint8) private mapStakeCount;
    mapping(address => uint24) private affiliateStakeBaseLevel;
    mapping(address => uint24) private stakedBafMaxLevel;
    mapping(address => mapping(uint24 => uint16)) private stakedBafLevelCounts;
    mapping(address => uint24) private _ethMintLastLevel;
    mapping(address => uint24) private _ethMintLevelCount;
    mapping(address => uint24) private _ethMintStreakCount;
    bool private rngFulfilled;
    bool private rngLockedFlag;
    uint256 private rngRequestId;
    uint256 private rngWord;

    uint32 private constant COIN_DRIP_STEPS = 10; // Base vesting window before coin drip starts
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint256 private constant COIN_BASE_UNIT = 1_000_000; // 1 PURGED (6 decimals)
    uint256 private constant COIN_EMISSION_UNIT = 1_000 * COIN_BASE_UNIT; // 1000 PURGED (6 decimals)
    uint256 private constant LUCK_PER_LINK = 220 * COIN_BASE_UNIT; // Base credit per 1 LINK (pre-multiplier)
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
    uint8 private constant LEVEL_STAKE_MAX = 20;
    uint8 private constant MAP_STAKE_MAX = 20;
    uint8 private constant AFFILIATE_STAKE_MAX = 20;
    uint16 private constant BAF_TRAIT_SENTINEL = 0xFFFA;
    uint16 private constant DECIMATOR_TRAIT_SENTINEL = 0xFFFB;
    uint16 private constant STAKE_TRAIT_SENTINEL = 0xFFFD;
    uint32 private constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16 private constant VRF_REQUEST_CONFIRMATIONS = 10;
    uint24 private constant STAKE_PREVIEW_START_LEVEL = 12;

    function _currentBaseTokenId() private view returns (uint256) {
        return uint256(uint128(basePointers));
    }

    function _previousBaseTokenId() private view returns (uint256) {
        return basePointers >> 128;
    }

    function _setBasePointers(uint256 previousBase, uint256 currentBase) private {
        basePointers = (uint256(uint128(previousBase)) << 128) | uint128(currentBase);
    }

    constructor(
        address regularRenderer_,
        address trophyRenderer_,
        address coin_,
        address vrfCoordinator_,
        bytes32 keyHash_,
        uint256 subId_,
        address linkToken_
    ) {
        regularRenderer = ITokenRenderer(regularRenderer_);
        trophyRenderer = ITokenRenderer(trophyRenderer_);
        coin = IPurgecoin(coin_);
        vrfCoordinator = IVRFCoordinator(vrfCoordinator_);
        vrfKeyHash = keyHash_;
        vrfSubscriptionId = subId_;
        linkToken = linkToken_;
        rngFulfilled = true;
        rngLockedFlag = false;
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

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        uint256 info = trophyData[tokenId];
        if (info != 0) {
            uint32[4] memory empty;
            return trophyRenderer.tokenURI(tokenId, info, empty);
        } else if (tokenId < _currentBaseTokenId()) {
            revert InvalidToken();
        }

        (uint256 metaPacked, uint32[4] memory remaining) = game.describeBaseToken(tokenId);
        return regularRenderer.tokenURI(tokenId, metaPacked, remaining);
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



        if (tokenId < _currentBaseTokenId() && trophyData[tokenId] == 0) {
            revert InvalidToken();
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
            if (trophyData[tokenId] != 0) return true;
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
            return
                (packed & _BITMASK_BURNED) == 0 &&
                address(uint160(packed)) == address(game);
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

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public payable {
        if (rngLockedFlag) {
            address senderCheck = msg.sender;
            if (senderCheck != address(this) && senderCheck != address(game)) revert CoinPaused();
        }
        uint256 prevOwnershipPacked = _packedOwnershipOf(tokenId);

        if (address(uint160(prevOwnershipPacked)) != from) revert TransferFromIncorrectOwner();
        if (trophyStaked[tokenId]) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);

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

            _packedOwnerships[tokenId] = _packOwnershipData(to, _BITMASK_NEXT_INITIALIZED);

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextTokenId = tokenId + 1;
                if (_packedOwnerships[nextTokenId] == 0) {
                    if (nextTokenId != _currentIndex) {
                        _packedOwnerships[nextTokenId] = prevOwnershipPacked;
                    }
                }
            }
        }

        if (to == address(0)) revert Zero();
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

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public payable {
        safeTransferFrom(from, to, tokenId, '');
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory _data
    ) public payable {
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
        try IERC721Receiver(to).onERC721Received(sender, from, tokenId, _data) returns (
            bytes4 retval
        ) {
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
        if (trophyStaked[tokenId]) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);

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

    function wireContracts(address game_) external {
        if (msg.sender != address(coin)) revert E();
        game = IPurgeGame(game_);
        uint256 currentBase = _mintTrophyPlaceholders(1);
        _setBasePointers(0, currentBase);
    }

    // ---------------------------------------------------------------------
    // VRF / RNG
    // ---------------------------------------------------------------------

    function requestRng() external onlyGame {
        uint256 id = vrfCoordinator.requestRandomWords(
            VRFRandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit: VRF_CALLBACK_GAS_LIMIT,
                numWords: 1,
                extraArgs: bytes("")
            })
        );
        rngRequestId = id;
        rngFulfilled = false;
        rngWord = 0;
        rngLockedFlag = true;
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        address coordinator = address(vrfCoordinator);
        if (msg.sender != coordinator) revert OnlyCoordinatorCanFulfill(msg.sender, coordinator);
        if (requestId != rngRequestId || rngFulfilled) return;
        rngFulfilled = true;
        rngWord = randomWords[0];
    }

    function releaseRngLock() external onlyGame {
        rngLockedFlag = false;
        rngRequestId = 0;
    }

    function rngLocked() external view returns (bool) {
        return rngLockedFlag;
    }

    function currentRngWord() external view returns (uint256) {
        return rngFulfilled ? rngWord : 0;
    }

    function isRngFulfilled() external view returns (bool) {
        return rngFulfilled;
    }

    function _tierMultPermille(uint256 subBal) private pure returns (uint16) {
        if (subBal < 200 ether) return 2000;
        if (subBal < 300 ether) return 1500;
        if (subBal < 600 ether) return 1000;
        if (subBal < 1000 ether) return 500;
        if (subBal < 2000 ether) return 100;
        return 0;
    }

    function onTokenTransfer(address from, uint256 amount, bytes calldata) external {
        if (msg.sender != linkToken) revert E();
        if (amount == 0) revert Zero();
        if (rngLockedFlag) revert CoinPaused();

        try ILinkToken(linkToken).transferAndCall(address(vrfCoordinator), amount, abi.encode(vrfSubscriptionId)) returns (bool ok) {
            if (!ok) revert E();
        } catch {
            revert E();
        }

        (uint96 bal, , , , ) = vrfCoordinator.getSubscription(vrfSubscriptionId);
        uint16 mult = _tierMultPermille(uint256(bal));
        if (mult == 0) return;

        uint256 base = (amount * LUCK_PER_LINK) / 1 ether;
        uint256 credit = (base * mult) / 1000;
        if (credit != 0) {
            coin.bonusCoinflip(from, 0, true, credit);
        }
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

    function recordEthMint(address player, uint24 level)
        external
        onlyGame
        returns (uint256 coinReward, uint256 luckboxReward)
    {
        uint24 prevLevel = _ethMintLastLevel[player];
        if (prevLevel == level) return (0, 0);

        uint24 total = _ethMintLevelCount[player];
        if (total < type(uint24).max) {
            unchecked {
                total = uint24(total + 1);
            }
            _ethMintLevelCount[player] = total;
        }

        uint24 streak = _ethMintStreakCount[player];
        if (prevLevel != 0 && prevLevel + 1 == level) {
            if (streak < type(uint24).max) {
                unchecked {
                    streak = uint24(streak + 1);
                }
            }
        } else {
            streak = 1;
        }
        _ethMintStreakCount[player] = streak;
        _ethMintLastLevel[player] = level;

        uint256 streakReward;
        if (streak >= 2) {
            uint256 capped = streak >= 61 ? 60 : uint256(streak - 1);
            streakReward = capped * 100 * COIN_BASE_UNIT;
        }

        uint256 totalReward;
        if (total >= 2) {
            uint256 cappedTotal = total >= 61 ? 60 : uint256(total - 1);
            totalReward = (cappedTotal * 100 * COIN_BASE_UNIT * 30) / 100;
        }

        if (streakReward != 0 || totalReward != 0) {
            unchecked {
                luckboxReward = streakReward + totalReward;
                coinReward = luckboxReward;
            }
        }

        if (streak == level && level >= 20 && (level % 10 == 0)) {
            uint256 milestoneBonus = (uint256(level) / 2) * 1000 * COIN_BASE_UNIT;
            coinReward += milestoneBonus;
        }

        if (total >= 20 && (total % 10 == 0)) {
            uint256 totalMilestone = (uint256(total) / 2) * 1000 * COIN_BASE_UNIT;
            coinReward += (totalMilestone * 30) / 100;
        }

        return (coinReward, luckboxReward);
    }

    function _hasBafTrophy(uint24 level) private pure returns (bool) {
        if (level == 0) return false;
        return level % 20 == 0;
    }

    function _hasDecimatorTrophy(uint24 level) private pure returns (bool) {
        if (level < 25) return false;
        if (level % 10 != 5) return false;
        return (level % 100) != 95;
    }

    function _stakePreviewData(uint24 level) private pure returns (uint256) {
        uint24 baseLevel = level == 0 ? 0 : uint24(level - 1);
        return
            (uint256(STAKE_TRAIT_SENTINEL) << 152) |
            (uint256(baseLevel) << TROPHY_BASE_LEVEL_SHIFT) |
            TROPHY_FLAG_STAKE;
    }

    function _mintedCountForLevel(uint24 level) private pure returns (uint256 count) {
        count = 4;
        if (_hasBafTrophy(level)) count += 1;
        if (_hasDecimatorTrophy(level)) count += 1;
    }

    function _placeholderStart(uint24 level) private view returns (uint256 startId) {
        uint24 currentLevel = game.level();
        uint256 mintedCount = _mintedCountForLevel(level);
        if (level == currentLevel) {
            uint256 base = _currentBaseTokenId();
            return base - mintedCount;
        }
        if (level + 1 == currentLevel) {
            uint256 base = _previousBaseTokenId();
            return base - mintedCount;
        }
        revert InvalidToken();
    }

    function _placeholderTokenId(uint24 level, TrophyKind kind) private view returns (uint256) {
        bool hasBaf = _hasBafTrophy(level);
        bool hasDec = _hasDecimatorTrophy(level);
        uint256 startId = _placeholderStart(level);
        if (kind == TrophyKind.Baf) {
            if (!hasBaf) revert InvalidToken();
            return startId;
        }
        if (kind == TrophyKind.Decimator) {
            if (!hasDec) revert InvalidToken();
            return startId + (hasBaf ? 1 : 0);
        }

        uint256 baseOffset = (hasBaf ? 1 : 0) + (hasDec ? 1 : 0);
        if (kind == TrophyKind.Map) return startId + baseOffset;
        if (kind == TrophyKind.Level) return startId + baseOffset + 1;
        if (kind == TrophyKind.Affiliate) return startId + baseOffset + 2;
        if (kind == TrophyKind.Stake) return startId + baseOffset + 3;
        revert InvalidToken();
    }

    function _mintTrophyPlaceholders(uint24 level) private returns (uint256 newBaseTokenId) {
        uint256 baseData = (uint256(0xFFFF) << 152) | (uint256(level) << TROPHY_BASE_LEVEL_SHIFT);
        bool mintBaf = _hasBafTrophy(level);
        bool mintDec = _hasDecimatorTrophy(level);

        uint256 mintedCount = _mintedCountForLevel(level);
        uint256 startId = _currentIndex;
        _mint(address(game), mintedCount);

        uint256 nextId = startId;
        if (mintBaf) {
            uint256 bafTokenId = nextId++;
            trophyData[bafTokenId] = baseData | TROPHY_FLAG_BAF;
        }

        if (mintDec) {
            uint256 decTokenId = nextId++;
            trophyData[decTokenId] = baseData | TROPHY_FLAG_DECIMATOR;
        }

        uint256 mapTokenId = nextId++;
        trophyData[mapTokenId] = baseData | TROPHY_FLAG_MAP;

        uint256 levelTokenId = nextId++;
        trophyData[levelTokenId] = baseData;

        uint256 affiliateTokenId = nextId++;
        trophyData[affiliateTokenId] = baseData | TROPHY_FLAG_AFFILIATE;

        uint256 stakeTokenId = nextId++;
        if (level >= STAKE_PREVIEW_START_LEVEL) {
            trophyData[stakeTokenId] = _stakePreviewData(level);
        } else {
            trophyData[stakeTokenId] = 0;
        }

        newBaseTokenId = nextId;
    }

    function clearStakePreview(uint24 level) external onlyCoinContract {
        uint256 tokenId = _placeholderTokenId(level, TrophyKind.Stake);
        if (trophyData[tokenId] == 0) return;
        if (address(uint160(_packedOwnershipOf(tokenId))) != address(game)) return;
        trophyData[tokenId] = 0;
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
        seasonPurgedCount += purged;
    }

    function _purgeToken(address owner, uint256 tokenId) private {
        uint256 packed = _packedOwnershipOf(tokenId);
        if (address(uint160(packed)) != owner) revert TransferFromIncorrectOwner();
        _burnPacked(tokenId, packed);
    }

    function _burnPacked(uint256 tokenId, uint256 prevOwnershipPacked) private {
        address from = address(uint160(prevOwnershipPacked));

        unchecked {
            _packedAddressData[from] += (1 << _BITPOS_NUMBER_BURNED) - 1;

            _packedOwnerships[tokenId] = _packOwnershipData(from, _BITMASK_BURNED | _BITMASK_NEXT_INITIALIZED);

            if (prevOwnershipPacked & _BITMASK_NEXT_INITIALIZED == 0) {
                uint256 nextTokenId = tokenId + 1;
                if (_packedOwnerships[nextTokenId] == 0 && nextTokenId != _currentIndex) {
                    _packedOwnerships[nextTokenId] = prevOwnershipPacked;
                }
            }
        }

        emit Transfer(from, address(0), tokenId);
    }

    function awardTrophy(
        address to,
        uint24 level,
        TrophyKind kind,
        uint256 data,
        uint256 deferredWei
    ) external payable {
        bool fromGame = msg.sender == address(game);
        bool fromCoinContract = msg.sender == address(coin);
        if (!fromGame && !fromCoinContract) revert E();

        if (kind == TrophyKind.Stake) revert E();

        if (fromGame) {
            if (kind == TrophyKind.Baf || kind == TrophyKind.Decimator) revert E();
        } else {
            if (kind != TrophyKind.Baf && kind != TrophyKind.Decimator) revert OnlyCoin();
        }

        uint256 tokenId = _placeholderTokenId(level, kind);
        _awardTrophy(to, data, deferredWei, tokenId);
    }

    function processEndLevel(EndLevelRequest calldata req)
        external
        payable
        onlyGame
        returns (address mapImmediateRecipient, address[6] memory affiliateRecipients)
    {
        uint24 nextLevel = req.level + 1;
        uint256 mapTokenId = _placeholderTokenId(req.level, TrophyKind.Map);
        uint256 levelTokenId = _placeholderTokenId(req.level, TrophyKind.Level);
        uint256 affiliateTokenId = _placeholderTokenId(req.level, TrophyKind.Affiliate);

        bool traitWin = req.traitId != TRAIT_ID_TIMEOUT;
        uint256 randomWord = rngWord;

        if (traitWin) {
            uint256 traitData = (uint256(req.traitId) << 152) | (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT);
            uint256 sharedPool = req.pool / 20;
            uint256 base = sharedPool / 100;
            uint256 remainder = sharedPool - (base * 100);
            uint256 affiliateTrophyShare = base * 20 + remainder;
            uint256 stakerRewardPool = base * 10;
            uint256 deferredAward = msg.value;
            deferredAward -= affiliateTrophyShare + stakerRewardPool;
            _awardTrophy(req.exterminator, traitData, deferredAward, levelTokenId);

            affiliateRecipients = _selectAffiliateRecipients(randomWord);
            address affiliateWinner = affiliateRecipients[0];
            if (affiliateWinner == address(0)) {
                affiliateWinner = req.exterminator;
                affiliateRecipients[0] = affiliateWinner;
            }
            uint256 affiliateData =
                (uint256(0xFFFE) << 152) | (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_AFFILIATE;
            _awardTrophy(affiliateWinner, affiliateData, affiliateTrophyShare, affiliateTokenId);

            if (stakerRewardPool != 0) {
                uint256[] storage source = stakedTrophyIds;
                uint256 trophyCount = source.length;
                if (trophyCount != 0) {
                    uint256 rounds = trophyCount == 1 ? 1 : 2;
                    uint256 baseShare = stakerRewardPool / rounds;
                    uint256 rand = randomWord;
                    uint256 mask = type(uint64).max;
                    for (uint256 i; i < rounds; ) {
                        uint256 idxA = trophyCount == 1 ? 0 : (rand & mask) % trophyCount;
                        rand >>= 64;
                        uint256 idxB = trophyCount == 1 ? idxA : (rand & mask) % trophyCount;
                        rand >>= 64;
                        uint256 tokenA = source[idxA];
                        uint256 chosen = tokenA;
                        if (trophyCount != 1) {
                            uint256 tokenB = source[idxB];
                            chosen = tokenA <= tokenB ? tokenA : tokenB;
                        }
                        _addTrophyReward(chosen, baseShare, nextLevel);
                        unchecked {
                            ++i;
                        }
                    }
                }
            }
        } else {
            uint256 poolCarry = req.pool;
            uint256 mapUnit = poolCarry / 20;

            mapImmediateRecipient = address(uint160(_packedOwnershipOf(mapTokenId)));

            delete trophyData[levelTokenId];

            uint256 valueIn = msg.value;
            address affiliateWinner = req.exterminator;
            uint256 affiliateShare = mapUnit;
            if (affiliateWinner != address(0) && affiliateShare != 0) {
                uint256 affiliateData =
                    (uint256(0xFFFE) << 152) | (uint256(req.level) << TROPHY_BASE_LEVEL_SHIFT) | TROPHY_FLAG_AFFILIATE;
                _awardTrophy(affiliateWinner, affiliateData, affiliateShare, affiliateTokenId);
                valueIn -= affiliateShare;
            }

            for (uint8 k; k < 6; ) {
                affiliateRecipients[k] = affiliateWinner;
                unchecked {
                    ++k;
                }
            }

            _addTrophyReward(mapTokenId, mapUnit, nextLevel);
            valueIn -= mapUnit;

            uint256[] storage staked = stakedTrophyIds;
            uint256 stakedCount = staked.length;
            uint256 distributed;
            if (mapUnit != 0 && stakedCount != 0) {
                uint256 draws = valueIn / mapUnit;
                uint256 rand = randomWord;
                uint256 mask = type(uint64).max;
                for (uint256 j; j < draws; ) {
                    uint256 idx = stakedCount == 1 ? 0 : (rand & mask) % stakedCount;
                    uint256 tokenId = staked[idx];
                    _addTrophyReward(tokenId, mapUnit, nextLevel);
                    distributed += mapUnit;
                    rand >>= 64;
                    unchecked {
                        ++j;
                    }
                }
                randomWord = rand;
            }

            uint256 leftover = valueIn - distributed;
            if (leftover != 0) {
                (bool ok, ) = payable(address(game)).call{value: leftover}("");
                if (!ok) revert E();
            }
        }

        return (mapImmediateRecipient, affiliateRecipients);
    }

    function claimTrophy(uint256 tokenId) external {
        if (address(uint160(_packedOwnershipOf(tokenId))) != msg.sender) revert TransferFromIncorrectOwner();

        uint256 info = trophyData[tokenId];
        if (info == 0) revert InvalidToken();

        uint24 currentLevel = game.level();
        uint24 lastClaim = uint24((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFF);

        uint256 owed = info & TROPHY_OWED_MASK;
        uint256 newOwed = owed;
        uint256 payout;
        bool ethClaimed;
        uint24 updatedLast = lastClaim;

        if (owed != 0 && currentLevel > lastClaim) {
            uint24 baseStartLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + 1;
            if (currentLevel >= baseStartLevel) {
                uint32 vestEnd = uint32(baseStartLevel) + COIN_DRIP_STEPS;
                uint256 denom = vestEnd > currentLevel ? vestEnd - currentLevel : 1;
                payout = owed / denom;
                newOwed = owed - payout;
                ethClaimed = true;
                updatedLast = currentLevel;
            }
        }

        uint256 coinAmount;
        bool coinClaimed;
        bool isMap = (info & TROPHY_FLAG_MAP) != 0;
        if (isMap) {
            uint32 start = uint32((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF) + COIN_DRIP_STEPS + 1;
            uint32 floor = start - 1;
            uint32 last = lastClaim;
            if (last < floor) last = floor;
            if (currentLevel > last) {
                if (rngLockedFlag) revert CoinPaused();
                uint32 from = last + 1;
                uint32 offsetStart = from - start;
                uint32 offsetEnd = currentLevel - start;

                uint256 span = uint256(offsetEnd - offsetStart + 1);
                uint256 periodSize = COIN_DRIP_STEPS;
                uint256 blocksEnd = uint256(offsetEnd) / periodSize;
                uint256 blocksStart = uint256(offsetStart) / periodSize;
                uint256 remEnd = uint256(offsetEnd) % periodSize;
                uint256 remStart = uint256(offsetStart) % periodSize;

                uint256 prefixEnd =
                    ((blocksEnd * (blocksEnd - 1)) / 2) * periodSize + blocksEnd * (remEnd + 1);
                uint256 prefixStart =
                    ((blocksStart * (blocksStart - 1)) / 2) * periodSize + blocksStart * (remStart + 1);

                coinAmount = COIN_EMISSION_UNIT * (span + (prefixEnd - prefixStart));
                coinClaimed = true;
                updatedLast = currentLevel;
            }
        }

        if (!ethClaimed && !coinClaimed) revert ClaimNotReady();

        uint256 newInfo = (info & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK))
            | (newOwed & TROPHY_OWED_MASK)
            | (uint256(updatedLast & 0xFFFFFF) << TROPHY_LAST_CLAIM_SHIFT);
        trophyData[tokenId] = newInfo;

        if (ethClaimed) {
            (bool ok, ) = msg.sender.call{value: payout}("");
            if (!ok) revert E();
            emit TrophyRewardClaimed(tokenId, msg.sender, payout);
        }

        if (coinClaimed) {
            coin.bonusCoinflip(msg.sender, coinAmount, true, 0);
        }
    }

    // ---------------------------------------------------------------------
    // Affiliate staking
    // ---------------------------------------------------------------------

    function setTrophyStake(
        uint256 tokenId,
        bool isMap,
        bool stake
    ) external {
        if (rngLockedFlag) revert CoinPaused();
        address sender = msg.sender;
        uint256 info = trophyData[tokenId];
        bool mapTrophy = (info & TROPHY_FLAG_MAP) != 0;
        bool affiliateTrophy = (info & TROPHY_FLAG_AFFILIATE) != 0;
        bool levelTrophy = info != 0 && !mapTrophy && !affiliateTrophy && (info & TROPHY_FLAG_STAKE) == 0;
        bool bafTrophy = (info & TROPHY_FLAG_BAF) != 0;
        uint24 trophyBaseLevel = uint24((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFF);
        bool targetMap = isMap;
        bool targetAffiliate = !isMap && affiliateTrophy;
        bool targetLevel = !isMap && !affiliateTrophy && levelTrophy;

        uint24 effectiveLevel = _effectiveStakeLevel();

        if (targetMap) {
            if (!mapTrophy) revert TrophyStakeViolation(_STAKE_ERR_NOT_MAP);
        } else if (targetAffiliate) {
            // ok
        } else if (targetLevel) {
            // ok
        } else if (affiliateTrophy) {
            revert TrophyStakeViolation(_STAKE_ERR_NOT_LEVEL);
        } else {
            revert TrophyStakeViolation(_STAKE_ERR_NOT_AFFILIATE);
        }

        if (address(uint160(_packedOwnershipOf(tokenId))) != sender) revert TransferFromIncorrectOwner();

        bool currentlyStaked = trophyStaked[tokenId];
        if (stake) {
            if (currentlyStaked) revert TrophyStakeViolation(_STAKE_ERR_ALREADY_STAKED);
            trophyStaked[tokenId] = true;
            _addStakedTrophy(tokenId);
            if (_tokenApprovals[tokenId] != address(0)) delete _tokenApprovals[tokenId];
            uint8 count;
            uint16 discountBps;
            uint8 kind;
            if (targetMap) {
                uint8 current = mapStakeCount[sender];
                if (current >= MAP_STAKE_MAX) revert StakeInvalid();
                unchecked {
                    current += 1;
                }
                mapStakeCount[sender] = current;
                count = current;
                discountBps = uint16(_stakeDiscountPct(current) * 100);
                kind = 1;
            } else if (targetAffiliate) {
                uint8 before = affiliateStakeCount[sender];
                if (before >= AFFILIATE_STAKE_MAX) revert StakeInvalid();
                affiliateStakeBaseLevel[sender] = effectiveLevel;
                uint8 current = before + 1;
                affiliateStakeCount[sender] = current;
                count = current;
                discountBps = uint16(_currentAffiliateBonus(sender, effectiveLevel) * 100);
                kind = 2;
            } else {
                uint8 current = levelStakeCount[sender];
                if (current >= LEVEL_STAKE_MAX) revert StakeInvalid();
                unchecked {
                    current += 1;
                }
                levelStakeCount[sender] = current;
                count = current;
                discountBps = uint16(_stakeDiscountPct(current) * 100);
                kind = 3;
            }
            if (bafTrophy) {
                _registerBafStake(sender, trophyBaseLevel);
            }
            emit TrophyStakeChanged(sender, tokenId, kind, true, count, discountBps);
        } else {
            if (game.gameState() != 3) revert TrophyStakeViolation(_STAKE_ERR_LOCKED);
            if (!currentlyStaked) revert TrophyStakeViolation(_STAKE_ERR_NOT_STAKED);
            trophyStaked[tokenId] = false;
            _removeStakedTrophy(tokenId);
            uint8 count;
            uint16 discountBps;
            uint8 kind;
            if (targetMap) {
                uint8 current = mapStakeCount[sender];
                if (current == 0) revert StakeInvalid();
                unchecked {
                    current -= 1;
                }
                mapStakeCount[sender] = current;
                count = current;
                discountBps = uint16(_stakeDiscountPct(current) * 100);
                kind = 1;
            } else if (targetAffiliate) {
                uint8 current = affiliateStakeCount[sender];
                if (current == 0) revert StakeInvalid();
                unchecked {
                    current -= 1;
                }
                affiliateStakeCount[sender] = current;
                affiliateStakeBaseLevel[sender] = effectiveLevel;
                count = current;
                discountBps = uint16(_currentAffiliateBonus(sender, effectiveLevel) * 100);
                kind = 2;
            } else {
                uint8 current = levelStakeCount[sender];
                if (current == 0) revert StakeInvalid();
                unchecked {
                    current -= 1;
                }
                levelStakeCount[sender] = current;
                count = current;
                discountBps = uint16(_stakeDiscountPct(current) * 100);
                kind = 3;
            }
            if (bafTrophy) {
                _unregisterBafStake(sender, trophyBaseLevel);
            }
            emit TrophyStakeChanged(sender, tokenId, kind, false, count, discountBps);
        }
    }

    function isTrophyStaked(uint256 tokenId) external view returns (bool) {
        return trophyStaked[tokenId];
    }

    function stakedTrophySample(uint64 salt) external view returns (address owner) {
        uint256 count = stakedTrophyIds.length;
        if (count == 0) return address(0);

        uint256 rand = uint256(keccak256(abi.encodePacked(salt, count)));
        uint256 idxA = count == 1 ? 0 : rand % count;
        uint256 tokenA = stakedTrophyIds[idxA];

        uint256 idxB;
        if (count == 1) {
            idxB = idxA;
        } else {
            rand = uint256(keccak256(abi.encodePacked(rand, salt)));
            idxB = rand % count;
        }
        uint256 tokenB = stakedTrophyIds[idxB];

        uint256 chosen = tokenA <= tokenB ? tokenA : tokenB;
        owner = address(uint160(_packedOwnershipOf(chosen)));
    }

    function _addStakedTrophy(uint256 tokenId) private {
        if (stakedTrophyIndex[tokenId] != 0) return;
        stakedTrophyIds.push(tokenId);
        stakedTrophyIndex[tokenId] = stakedTrophyIds.length;
    }

    function _removeStakedTrophy(uint256 tokenId) private {
        uint256 indexPlus = stakedTrophyIndex[tokenId];
        if (indexPlus == 0) return;
        uint256 idx = indexPlus - 1;
        uint256 lastIdx = stakedTrophyIds.length - 1;
        if (idx != lastIdx) {
            uint256 lastToken = stakedTrophyIds[lastIdx];
            stakedTrophyIds[idx] = lastToken;
            stakedTrophyIndex[lastToken] = idx + 1;
        }
        stakedTrophyIds.pop();
        delete stakedTrophyIndex[tokenId];
    }

    function _registerBafStake(address player, uint24 level) private {
        if (level == 0) return;
        uint16 newCount = stakedBafLevelCounts[player][level] + 1;
        stakedBafLevelCounts[player][level] = newCount;
        uint24 currentMax = stakedBafMaxLevel[player];
        if (level > currentMax) {
            stakedBafMaxLevel[player] = level;
        }
    }

    function _unregisterBafStake(address player, uint24 level) private {
        if (level == 0) return;
        mapping(uint24 => uint16) storage counts = stakedBafLevelCounts[player];
        uint16 current = counts[level];
        if (current <= 1) {
            delete counts[level];
            if (stakedBafMaxLevel[player] == level) {
                stakedBafMaxLevel[player] = _nextHighestBafLevel(player, level);
            }
        } else {
            counts[level] = current - 1;
        }
    }

    function _nextHighestBafLevel(address player, uint24 startLevel) private view returns (uint24) {
        mapping(uint24 => uint16) storage counts = stakedBafLevelCounts[player];
        uint24 level = startLevel;
        while (level != 0) {
            unchecked {
                level -= 1;
            }
            if (counts[level] != 0) {
                return level;
            }
        }
        return 0;
    }

    function levelStakeDiscount(address player) external view returns (uint8) {
        return _stakeDiscountPct(levelStakeCount[player]);
    }

    function mapStakeDiscount(address player) external view returns (uint8) {
        return _stakeDiscountPct(mapStakeCount[player]);
    }

    function affiliateStakeBonus(address player) external view returns (uint8) {
        uint8 count = affiliateStakeCount[player];
        if (count == 0) return 0;
        uint24 effective = _effectiveStakeLevel();
        return _currentAffiliateBonus(player, effective);
    }

    function bafStakeBonusBps(address player) external view returns (uint16) {
        uint24 level = stakedBafMaxLevel[player];
        if (level == 0) return 0;
        uint256 bonus = uint256(level) * 10;
        if (bonus > 220) {
            bonus = 220;
        }
        return uint16(bonus);
    }

    function ethMintLastLevel(address player) external view returns (uint24) {
        return _ethMintLastLevel[player];
    }

    function ethMintLevelsCompleted(address player) external view returns (uint24) {
        return _ethMintLevelCount[player];
    }

    function ethMintStreak(address player) external view returns (uint24) {
        return _ethMintStreakCount[player];
    }

    function awardStakeTrophy(
        address to,
        uint24 level,
        uint256 principal
    ) external onlyCoinContract returns (uint256 tokenId) {

        uint256 data = _stakePreviewData(level);
        uint256 placeholderId = _placeholderTokenId(level, TrophyKind.Stake);

        _awardTrophy(to, data, 0, placeholderId);
        tokenId = placeholderId;
        emit StakeTrophyAwarded(to, tokenId, level, principal);
        return tokenId;
    }

    function purgeTrophy(uint256 tokenId) external {
        if (trophyStaked[tokenId]) revert TrophyStakeViolation(_STAKE_ERR_TRANSFER_BLOCKED);
        if (trophyData[tokenId] == 0) revert InvalidToken();

        address sender = msg.sender;

        uint256 packed = _packedOwnershipOf(tokenId);
        if (address(uint160(packed)) != sender) revert TransferFromIncorrectOwner();

        if (_tokenApprovals[tokenId] != address(0)) {
            delete _tokenApprovals[tokenId];
        }

        delete trophyData[tokenId];

        unchecked {
            totalTrophySupply -= 1;
        }

        coin.bonusCoinflip(sender, 100_000 * COIN_BASE_UNIT, false, 0);
    }

    function burnieNFT() external onlyCoinContract {
        uint256 bal = address(this).balance;
        (bool ok, ) = payable(msg.sender).call{value: bal}("");
        if (!ok) revert E();
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

    function _selectAffiliateRecipients(uint256 randomWord) private view returns (address[6] memory recipients) {
        address[] memory leaders = coin.getLeaderboardAddresses(1);
        uint256 len = leaders.length;

        if (len == 0) {
            return recipients;
        }

        address top = leaders[0];
        recipients[0] = top;

        address second = len > 1 ? leaders[1] : top;
        recipients[1] = second;

        if (len <= 2) {
            for (uint8 idx = 2; idx < 6; ) {
                recipients[idx] = top;
                unchecked {
                    ++idx;
                }
            }
            return recipients;
        }

        unchecked {
            uint256 span = len - 2;
            uint256 rand = randomWord;
            uint256 mask = type(uint64).max;
            uint256 remaining = span;
            uint256 slotSeed;

            if (len <= 256) {
                uint256 usedMask = 3; // bits 0 and 1 consumed
                for (uint8 slot = 2; slot < 6; ) {
                    if (remaining == 0) {
                        recipients[slot] = top;
                        ++slot;
                        continue;
                    }
                    if (rand == 0) {
                        ++slotSeed;
                        rand = randomWord | slotSeed;
                    }
                    uint256 idx = 2 + (rand & mask) % span;
                    rand >>= 64;
                    if (idx >= len) idx = len - 1;
                    uint256 bit = uint256(1) << idx;
                    if (usedMask & bit != 0) {
                        continue;
                    }
                    usedMask |= bit;
                    recipients[slot] = leaders[idx];
                    --remaining;
                    ++slot;
                }
            } else {
                bool[] memory used = new bool[](len);
                used[0] = true;
                used[1] = true;
                for (uint8 slot = 2; slot < 6; ) {
                    if (remaining == 0) {
                        recipients[slot] = top;
                        ++slot;
                        continue;
                    }
                    if (rand == 0) {
                        ++slotSeed;
                        rand = randomWord | slotSeed;
                    }
                    uint256 idx = 2 + (rand & mask) % span;
                    rand >>= 64;
                    if (idx >= len) idx = len - 1;
                    if (used[idx]) {
                        continue;
                    }
                    used[idx] = true;
                    recipients[slot] = leaders[idx];
                    --remaining;
                    ++slot;
                }
            }

            for (uint8 slot = 2; slot < 6; ) {
                if (recipients[slot] == address(0)) {
                    recipients[slot] = top;
                }
                ++slot;
            }
        }
        return recipients;
    }

    function _awardTrophy(address to, uint256 data, uint256 deferredWei, uint256 tokenId) private {
        address currentOwner = address(uint160(_packedOwnershipOf(tokenId)));
        if (currentOwner == address(game)) {
            transferFrom(address(game), to, tokenId);
            unchecked {
                totalTrophySupply += 1;
            }
        }

        uint256 prevData = trophyData[tokenId];
        uint256 newData = data & ~(TROPHY_OWED_MASK | TROPHY_LAST_CLAIM_MASK);
        uint256 owed = deferredWei & TROPHY_OWED_MASK;
        newData |= owed;
        trophyData[tokenId] = newData;
        if (prevData == 0 && newData != 0 && to != address(game)) {
            unchecked {
                totalTrophySupply += 1;
            }
        }
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

    function _stakeDiscountPct(uint8 count) private pure returns (uint8) {
        if (count == 0) return 0;
        if (count >= 20) return 20;
        return count;
    }

    function _effectiveStakeLevel() private view returns (uint24) {
        uint24 lvl = game.level();

        uint8 state = game.gameState();
        if (state != 3) {
            unchecked {
                return lvl - 1;
            }
        }
        return lvl;
    }

    function _currentAffiliateBonus(address player, uint24 effectiveLevel) private view returns (uint8) {
        uint8 count = affiliateStakeCount[player];
        if (count == 0) return 0;
        uint24 baseLevel = affiliateStakeBaseLevel[player];
        uint24 levelsHeld = effectiveLevel > baseLevel ? effectiveLevel - baseLevel : 0;
        uint256 effectiveBonus = uint256(levelsHeld) * uint256(count);
        uint256 cap = 10 + (uint256(count - 1) * 5);
        if (cap > 25) cap = 25;
        if (effectiveBonus > cap) effectiveBonus = cap;
        return uint8(effectiveBonus);
    }

}
