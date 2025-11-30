// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PurgeGame} from "../PurgeGame.sol";
import {IPurgeCoin} from "../interfaces/IPurgeCoin.sol";
import {IPurgeCoinModule, IPurgeGameTrophiesModule} from "../modules/PurgeGameModuleInterfaces.sol";
import {QuestInfo, PlayerQuestView} from "../interfaces/IPurgeQuestModule.sol";
import {IPurgeGameTrophies} from "../PurgeGameTrophies.sol";
import {IPurgeGameNFT} from "../PurgeGameNFT.sol";

// -------------------------------------------------------------------------
// Mocks
// -------------------------------------------------------------------------

contract MJRenderer {
    uint32[256] public lastSnapshot;

    function setStartingTraitRemaining(uint32[256] calldata values) external {
        lastSnapshot = values;
    }
}

contract MJStETH {
    mapping(address => uint256) public balanceOf;

    function submit(address) external payable returns (uint256) {
        balanceOf[msg.sender] += msg.value;
        return msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 bal = balanceOf[msg.sender];
        require(bal >= amount, "no bal");
        unchecked {
            balanceOf[msg.sender] = bal - amount;
            balanceOf[to] += amount;
        }
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MJCoin is IPurgeCoin, IPurgeCoinModule {
    address public jackpotsAddr;
    address public affiliateAddr;
    address public gameAddr;
    address public bondMintTarget;

    mapping(address => uint256) public flipCredits;
    mapping(address => uint256) public burned;
    mapping(address => uint256) public luckbox;
    QuestInfo[2] internal quests;
    address internal topPlayer;
    uint96 internal topScore;

    function setGame(address game_) external {
        gameAddr = game_;
    }

    function setJackpots(address jackpots_) external {
        jackpotsAddr = jackpots_;
    }

    function setAffiliate(address affiliate_) external {
        affiliateAddr = affiliate_;
    }

    function setTop(address player_, uint96 score_) external {
        topPlayer = player_;
        topScore = score_;
    }

    function jackpots() external view override(IPurgeCoin, IPurgeCoinModule) returns (address) {
        return jackpotsAddr;
    }

    function affiliateProgram() external view override(IPurgeCoin, IPurgeCoinModule) returns (address) {
        return affiliateAddr;
    }

    function processCoinflipPayouts(
        uint24,
        uint32,
        bool,
        uint256,
        uint48,
        uint256
    ) external pure override(IPurgeCoin, IPurgeCoinModule) returns (bool) {
        return true;
    }

    function bonusCoinflip(address player, uint256 amount) external override(IPurgeCoin, IPurgeCoinModule) {
        flipCredits[player] += amount;
    }

    function addToBounty(uint256 amount) external override(IPurgeCoin, IPurgeCoinModule) {
        burned[address(this)] += amount;
    }

    function rewardTopFlipBonus(uint48, uint256 amount) external override(IPurgeCoin, IPurgeCoinModule) {
        burned[address(this)] += amount;
    }

    function burnCoin(address target, uint256 amount) external override {
        burned[target] += amount;
    }

    function claimPresaleAffiliateBonus() external pure override {}

    function recordStakeResolution(uint24, uint48) external pure override {}

    function coinflipTop(uint24) external view override returns (address player, uint96 score) {
        player = topPlayer;
        score = topScore;
    }

    function playerLuckbox(address player) external view override returns (uint256) {
        return luckbox[player];
    }

    function rollDailyQuest(uint48, uint256) external override(IPurgeCoin, IPurgeCoinModule) {}

    function rollDailyQuestWithOverrides(
        uint48,
        uint256,
        bool,
        bool
    ) external override(IPurgeCoin, IPurgeCoinModule) {}

    function notifyQuestMint(address, uint32, bool) external pure override {}

    function notifyQuestPurge(address, uint32) external pure override {}

    function getActiveQuests() external view override returns (QuestInfo[2] memory) {
        return quests;
    }

    function playerQuestStates(address)
        external
        pure
        override
        returns (uint32 streak, uint32 lastCompletedDay, uint128[2] memory progress, bool[2] memory completed)
    {
        streak = 0;
        lastCompletedDay = 0;
        progress = [uint128(0), uint128(0)];
        completed = [false, false];
    }

    function getPlayerQuestView(address) external pure override returns (PlayerQuestView memory viewData) {
        return viewData;
    }

    function bondPayment(address to, uint256 amount) external override {
        luckbox[to] += amount;
        bondMintTarget = to;
    }

    // Helper so tests can call game.setBonds via the mocked coin.
    function wireBonds(address game, address bonds) external {
        PurgeGame(payable(game)).setBonds(bonds);
    }
}

contract MJNFT is IPurgeGameNFT {
    address public game;
    uint32 public purchaseCountValue;
    uint256 public baseTokenId = 1;
    uint32 public lastFinalizeMinted;
    uint256 public lastFinalizeRng;

    function wireAll(address game_, address) external override {
        game = game_;
    }

    function setGame(address game_) external {
        game = game_;
    }

    function setPurchaseCount(uint32 count) external {
        purchaseCountValue = count;
    }

    function setBaseTokenId(uint256 baseId) external {
        baseTokenId = baseId;
    }

    function tokenTraitsPacked(uint256 tokenId) external pure override returns (uint32) {
        tokenId;
        return 0;
    }

    function purchaseCount() external view override returns (uint32) {
        return purchaseCountValue;
    }

    function finalizePurchasePhase(uint32 minted, uint256 rngWord) external override {
        lastFinalizeMinted = minted;
        lastFinalizeRng = rngWord;
    }

    function purge(address, uint256[] calldata) external pure override {}

    function currentBaseTokenId() external view override returns (uint256) {
        return baseTokenId;
    }

    function processPendingMints(uint32, uint32) external pure override returns (bool finished) {
        return true;
    }

    function tokensOwed(address) external pure override returns (uint32) {
        return 0;
    }

    function processDormant(uint32) external pure override returns (bool finished, bool worked) {
        return (true, false);
    }

    function clearPlaceholderPadding(uint256, uint256) external pure override {}

    function purchaseWithClaimable(address, uint256) external pure override {}

    function mintAndPurgeWithClaimable(address, uint256) external pure override {}
}

contract MJTrophies is IPurgeGameTrophies, IPurgeGameTrophiesModule {
    address public game;
    address public coin;

    mapping(uint256 => address) internal ownerByToken;
    mapping(uint256 => uint256) internal rewardsByToken;

    function wire(address game_, address coin_) external override {
        game = game_;
        coin = coin_;
    }

    function wireAndPrime(address game_, address coin_, uint24) external override {
        game = game_;
        coin = coin_;
    }

    function clearStakePreview(uint24) external pure override {}

    function prepareNextLevel(uint24) external pure override {}

    function awardTrophy(address to, uint24 level, uint8 kind, uint256, uint256 deferredWei)
        external
        override(IPurgeGameTrophies, IPurgeGameTrophiesModule)
    {
        uint256 tokenId = _tokenId(level, kind);
        ownerByToken[tokenId] = to;
        rewardsByToken[tokenId] += deferredWei;
    }

    function burnBafPlaceholder(uint24) external pure override(IPurgeGameTrophies, IPurgeGameTrophiesModule) {}

    function burnDecPlaceholder(uint24) external pure override(IPurgeGameTrophies, IPurgeGameTrophiesModule) {}

    function claimTrophy(uint256) external pure override {}

    function setTrophyStake(uint256, bool) external pure override {}

    function refreshStakeBonuses(
        uint256[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        uint256[] calldata
    ) external pure override {}

    function affiliateStakeBonus(address) external pure override returns (uint8) {
        return 0;
    }

    function stakeTrophyBonus(address) external pure override returns (uint8) {
        return 0;
    }

    function decStakeBonus(address) external pure override returns (uint8) {
        return 0;
    }

    function mapStakeDiscount(address) external pure override returns (uint8) {
        return 0;
    }

    function exterminatorStakeDiscount(address) external pure override returns (uint8) {
        return 0;
    }

    function hasExterminatorStake(address) external pure override returns (bool) {
        return false;
    }

    function purgeTrophy(uint256) external pure override {}

    function stakedTrophySampleWithId(uint256) external pure override returns (uint256 tokenId, address owner) {
        return (0, address(0));
    }

    function trophyToken(uint24 level, uint8 kind)
        external
        pure
        override(IPurgeGameTrophies, IPurgeGameTrophiesModule)
        returns (uint256)
    {
        return _tokenId(level, kind);
    }

    function trophyOwner(uint256 tokenId)
        external
        view
        override(IPurgeGameTrophies, IPurgeGameTrophiesModule)
        returns (address owner)
    {
        owner = ownerByToken[tokenId];
    }

    function rewardTrophyByToken(uint256 tokenId, uint256 amountWei, uint24)
        external
        override(IPurgeGameTrophies, IPurgeGameTrophiesModule)
    {
        rewardsByToken[tokenId] += amountWei;
    }

    function rewardTrophy(uint24 level, uint8 kind, uint256 amountWei)
        external
        override(IPurgeGameTrophies, IPurgeGameTrophiesModule)
        returns (bool paid)
    {
        rewardsByToken[_tokenId(level, kind)] += amountWei;
        return true;
    }

    function rewardRandomStaked(uint256, uint256, uint24)
        external
        pure
        override(IPurgeGameTrophies, IPurgeGameTrophiesModule)
        returns (bool paid)
    {
        return false;
    }

    function processEndLevel(
        EndLevelRequest calldata,
        uint256
    )
        external
        pure
        override(IPurgeGameTrophies, IPurgeGameTrophiesModule)
        returns (uint256 paidTotal)
    {
        return 0;
    }

    function isTrophy(uint256 tokenId) external view override returns (bool) {
        return ownerByToken[tokenId] != address(0);
    }

    function trophyData(uint256) external pure override returns (uint256 rawData) {
        return 0;
    }

    function isTrophyStaked(uint256) external pure override returns (bool) {
        return false;
    }

    function handleExterminatorTraitPurge(address, uint16) external pure override returns (uint8 newPercent) {
        return 0;
    }

    function _tokenId(uint24 level, uint8 kind) internal pure returns (uint256) {
        return (uint256(level) << 8) | uint256(kind);
    }
}

struct VRFRandomWordsRequest {
    bytes32 keyHash;
    uint256 subId;
    uint16 requestConfirmations;
    uint32 callbackGasLimit;
    uint32 numWords;
    bytes extraArgs;
}

interface IVRFCoordinatorMock {
    function requestRandomWords(VRFRandomWordsRequest calldata request) external returns (uint256);
}

contract MJVRFCoordinator is IVRFCoordinatorMock {
    uint256 public lastRequestId;

    event Requested(address indexed caller, uint256 indexed requestId);

    function requestRandomWords(VRFRandomWordsRequest calldata) external override returns (uint256) {
        lastRequestId += 1;
        emit Requested(msg.sender, lastRequestId);
        return lastRequestId;
    }

    function getSubscription(
        uint256
    )
        external
        view
        returns (uint96 balance, uint96 premium, uint64 reqCount, address owner, address[] memory consumers)
    {
        balance = type(uint96).max;
        premium = 0;
        reqCount = 0;
        owner = address(0);
        consumers = new address[](0);
    }

    function fulfillLatest(address game, uint256 rngWord) external {
        uint256[] memory words = new uint256[](1);
        words[0] = rngWord;
        PurgeGame(payable(game)).rawFulfillRandomWords(lastRequestId, words);
    }
}

contract MJBonds {
    bool public locked;
    uint16 public rateBps = 10_000;
    uint256 public pendingCount;
    uint256 public paidYield;

    function setTransfersLocked(bool locked_, uint48) external {
        locked = locked_;
    }

    function payBonds(
        uint256,
        address,
        uint48,
        uint256,
        uint256,
        uint256
    ) external payable {
        paidYield += msg.value;
    }

    function resolvePendingBonds(uint256 maxBonds) external {
        if (pendingCount == 0) return;
        uint256 work = pendingCount;
        if (maxBonds < work) {
            work = maxBonds;
        }
        unchecked {
            pendingCount -= work;
        }
    }

    function resolvePending() external view returns (bool) {
        return pendingCount != 0;
    }

    function stakeRateBps() external view returns (uint16) {
        return rateBps;
    }

    function setStakeRate(uint16 rate) external {
        rateBps = rate;
    }

    function setPendingCount(uint256 count) external {
        pendingCount = count;
    }
}

// -------------------------------------------------------------------------
// Harness
// -------------------------------------------------------------------------

contract MapJackpotHarness is PurgeGame {
    uint256 private constant MASK_32 = (uint256(1) << 32) - 1;
    uint256 private constant ETH_DAY_SHIFT_LOCAL = 72;
    uint256 private constant AGG_DAY_SHIFT_LOCAL = 176;

    constructor(
        address purgeCoinContract,
        address renderer_,
        address nftContract,
        address trophiesContract,
        address endgameModule_,
        address jackpotModule_,
        address vrfCoordinator_,
        bytes32 vrfKeyHash_,
        uint256 vrfSubscriptionId_,
        address linkToken_,
        address stEthToken_
    )
        PurgeGame(
            purgeCoinContract,
            renderer_,
            nftContract,
            trophiesContract,
            endgameModule_,
            jackpotModule_,
            vrfCoordinator_,
            vrfKeyHash_,
            vrfSubscriptionId_,
            linkToken_,
            stEthToken_
        )
    {}

    function harnessSetMintDay(address player, uint32 day) external {
        uint256 data = mintPacked_[player];
        uint256 cleared = data & ~(MASK_32 << ETH_DAY_SHIFT_LOCAL);
        uint256 withEthDay = cleared | (uint256(day) << ETH_DAY_SHIFT_LOCAL);
        // keep aggregate day in sync so helper callers don't regress streak math in tests
        withEthDay = (withEthDay & ~(MASK_32 << AGG_DAY_SHIFT_LOCAL)) | (uint256(day) << AGG_DAY_SHIFT_LOCAL);
        mintPacked_[player] = withEthDay;
    }

    function harnessSetPools(uint256 rewardPool_, uint256 currentPrizePool_, uint256 nextPrizePool_) external {
        rewardPool = rewardPool_;
        currentPrizePool = currentPrizePool_;
        nextPrizePool = nextPrizePool_;
    }

    function harnessForceRngState(uint256 word, bool fulfilled, bool locked) external {
        rngWordCurrent = word;
        rngFulfilled = fulfilled;
        rngLockedFlag = locked;
    }

    function harnessSetPhaseAndState(uint8 phase_, uint8 gameState_) external {
        phase = phase_;
        gameState = gameState_;
    }

    function harnessSetLevel(uint24 lvl) external {
        level = lvl;
    }

    function harnessSetDailyIdx(uint48 idx) external {
        dailyIdx = idx;
    }

    function harnessSetAirdropMultiplier(uint32 multiplier_) external {
        airdropMultiplier = multiplier_;
    }

    function harnessSetPrincipal(uint256 principal) external {
        principalStEth = principal;
    }

    function harnessSetPendingMaps(address[] calldata buyers, uint32[] calldata qty) external {
        require(buyers.length == qty.length, "len");
        delete pendingMapMints;
        airdropIndex = 0;
        airdropMapsProcessedCount = 0;

        for (uint256 i; i < buyers.length; ) {
            pendingMapMints.push(buyers[i]);
            playerMapMintsOwed[buyers[i]] = qty[i];
            unchecked {
                ++i;
            }
        }
    }

    function harnessMapBatchState(address player)
        external
        view
        returns (uint32 idx, uint32 processed, uint32 owed, uint256 pendingLen)
    {
        idx = airdropIndex;
        processed = airdropMapsProcessedCount;
        owed = playerMapMintsOwed[player];
        pendingLen = pendingMapMints.length;
    }

    function harnessSeedTickets(uint24 lvl, uint8 traitId, address[] calldata holders) external {
        address[] storage arr = traitPurgeTicket[lvl][traitId];
        delete traitPurgeTicket[lvl][traitId];
        for (uint256 i; i < holders.length; ) {
            arr.push(holders[i]);
            unchecked {
                ++i;
            }
        }
    }
}
