// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract Purgecoin {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event StakeCreated(address indexed player, uint24 targetLevel, uint8 risk, uint256 principal);
    event LuckyCoinBurned(address indexed player, uint256 amount, uint256 coinflipDeposit);
    event Affiliate(uint256 amount, bytes32 indexed code, address sender);
    event CoinflipFinished(bool result);
    event CoinJackpotPaid(uint16 trait, address winner, uint256 amount);
    event BountyOwed(address indexed to, uint256 bountyAmount, uint256 newRecordFlip);
    event BountyPaid(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error OnlyDeployer();
    error OnlyGame();
    error BettingPaused();
    error Zero();
    error Insufficient();
    error AmountLTMin();
    error FlipLTMin();
    error BurnLT2pct();
    error E();
    error InvalidLeaderboard();
    error PresaleExceedsRemaining();
    error InvalidKind();
    error StakeInvalid();
    error OnlyCoordinatorCanFulfill(address have, address want);
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // ERC20 state
    // ---------------------------------------------------------------------
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) revert ZeroAddress();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    struct VRFExtraArgsV1 {
        bool nativePayment;
    }

    struct VRFRandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16 requestConfirmations;
        uint32 callbackGasLimit;
        uint32 numWords;
        bytes extraArgs;
    }

    bytes4 private constant EXTRA_ARGS_V1_TAG = bytes4(keccak256("VRF ExtraArgsV1"));
    bytes4 private constant VRF_REQUEST_SELECTOR =
        bytes4(keccak256("requestRandomWords((bytes32,uint256,uint16,uint32,uint32,bytes))"));
    bytes4 private constant VRF_GET_SUB_SELECTOR = bytes4(keccak256("getSubscription(uint256)"));
    bytes4 private constant LINK_TRANSFER_AND_CALL_SELECTOR =
        bytes4(keccak256("transferAndCall(address,uint256,bytes)"));
    bytes4 private constant GAME_STATE_SELECTOR = bytes4(keccak256("gameState()"));
    bytes4 private constant GAME_LEVEL_SELECTOR = bytes4(keccak256("level()"));
    bytes4 private constant GAME_JACKPOT_SELECTOR = bytes4(keccak256("getJackpotWinners(uint256,uint8,uint8,uint8)"));

    function _vrfRequestRandomWords(VRFRandomWordsRequest memory req) private returns (uint256 requestId) {
        (bool ok, bytes memory data) = s_vrfCoordinator.call(abi.encodeWithSelector(VRF_REQUEST_SELECTOR, req));
        if (!ok || data.length == 0) revert E();
        requestId = abi.decode(data, (uint256));
    }

    function _vrfGetSubscription(
        uint256 subId
    ) private view returns (uint96 bal, uint96, uint64, address, address[] memory) {
        (bool ok, bytes memory data) = s_vrfCoordinator.staticcall(abi.encodeWithSelector(VRF_GET_SUB_SELECTOR, subId));
        if (!ok || data.length == 0) revert E();
        return abi.decode(data, (uint96, uint96, uint64, address, address[]));
    }

    function _linkTransferAndCall(address to, uint256 amount, bytes memory data) private returns (bool) {
        (bool ok, bytes memory ret) = LINK.call(
            abi.encodeWithSelector(LINK_TRANSFER_AND_CALL_SELECTOR, to, amount, data)
        );
        if (!ok) return false;
        return ret.length == 0 || abi.decode(ret, (bool));
    }

    function _gameState() private view returns (uint8) {
        (bool ok, bytes memory data) = purgeGameContract.staticcall(abi.encodeWithSelector(GAME_STATE_SELECTOR));
        if (!ok || data.length == 0) revert E();
        return abi.decode(data, (uint8));
    }

    function _gameLevel() private view returns (uint24) {
        (bool ok, bytes memory data) = purgeGameContract.staticcall(abi.encodeWithSelector(GAME_LEVEL_SELECTOR));
        if (!ok || data.length == 0) revert E();
        return abi.decode(data, (uint24));
    }

    function _gameJackpotWinners(
        uint256 randomWord,
        uint8 trait,
        uint8 numWinners,
        uint8 salt
    ) private view returns (address[] memory) {
        (bool ok, bytes memory data) = purgeGameContract.staticcall(
            abi.encodeWithSelector(GAME_JACKPOT_SELECTOR, randomWord, trait, numWinners, salt)
        );
        if (!ok) revert E();
        return abi.decode(data, (address[]));
    }

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    struct PlayerScore {
        address player;
        uint256 score;
    }

    /// @dev BAF jackpot accounting
    struct BAFState {
        uint128 totalPrizePoolWei;
        uint120 returnAmountWei;
        bool inProgress;
    }

    /// @dev BAF scatter scan cursor
    struct BAFScan {
        uint120 per;
        uint32 limit;
        uint8 offset;
    }

    /// @dev Decimator per-player burn snapshot for a given level
    struct DecEntry {
        uint232 burn;
        uint24 level;
    }

    // ---------------------------------------------------------------------
    // Constants (units & limits)
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6; // token has 6 decimals
    uint16 private constant RANK_NOT_FOUND = 11;
    uint256 private constant PRESALEAMOUNT = 4_000_000 * MILLION;
    uint256 private constant MIN = 100 * MILLION; // min burn / min flip (100 PURGED)
    uint8 private constant MAX_RISK = 11; // staking risk 1..11
    uint256 private constant ONEK = 1_000 * MILLION; // 1,000 PURGED (6d)
    uint32 private constant BAF_BATCH = 5000;
    uint256 private constant BUCKET_SIZE = 1500;
    uint256 private constant LUCK_PER_LINK = 220 * MILLION; // 220 PURGE per 1 LINK
    uint8 private constant STAKE_MAX_LANES = 3;
    uint256 private constant STAKE_LANE_BITS = 86;
    uint256 private constant STAKE_LANE_MASK = (uint256(1) << STAKE_LANE_BITS) - 1;
    uint256 private constant STAKE_LANE_RISK_BITS = 8;
    uint256 private constant STAKE_LANE_PRINCIPAL_BITS = STAKE_LANE_BITS - STAKE_LANE_RISK_BITS;
    uint256 private constant STAKE_LANE_PRINCIPAL_MASK = (uint256(1) << STAKE_LANE_PRINCIPAL_BITS) - 1;
    uint256 private constant STAKE_LANE_RISK_SHIFT = STAKE_LANE_PRINCIPAL_BITS;
    uint256 private constant STAKE_LANE_RISK_MASK = ((uint256(1) << STAKE_LANE_RISK_BITS) - 1) << STAKE_LANE_RISK_SHIFT;
    uint256 private constant STAKE_PRINCIPAL_FACTOR = MILLION;
    uint256 private constant STAKE_MAX_PRINCIPAL = STAKE_LANE_PRINCIPAL_MASK * STAKE_PRINCIPAL_FACTOR;

    // ---------------------------------------------------------------------
    // VRF configuration
    // ---------------------------------------------------------------------
    uint32 private constant vrfCallbackGasLimit = 200_000;
    uint16 private constant vrfRequestConfirmations = 5;

    // ---------------------------------------------------------------------
    // Scan sentinels
    // ---------------------------------------------------------------------
    uint32 private constant SS_IDLE = type(uint32).max; // not started
    uint32 private constant SS_DONE = type(uint32).max - 1; // finished

    // ---------------------------------------------------------------------
    // Immutables / external wiring
    // ---------------------------------------------------------------------
    address private immutable creator; // deployer / ETH sink
    bytes32 private immutable vrfKeyHash; // VRF key hash
    uint256 private immutable vrfSubscriptionId; // VRF sub id

    address private immutable s_vrfCoordinator; // VRF coordinator handle

    // LINK token (Chainlink ERC677) — network-specific address
    address private constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA; // MAINNET LINK

    // ---------------------------------------------------------------------
    // Game wiring & state
    // ---------------------------------------------------------------------
    address private purgeGameContract; // PurgeGame contract address (set once)

    // Session flags
    bool public isBettingPaused; // set while VRF is pending unless explicitly allowed
    bool private tbActive; // “tenth player” bonus active
    bool private rngFulfilled;
    uint8 private extMode; // external jackpot mode (state machine)

    // Leaderboard lengths
    uint8 private luckboxLen;
    uint8 private affiliateLen;
    uint8 private topLen;

    // “tenth player” bonus fields
    uint8 private tbMod; // wheel mod (0..9)
    uint32 private tbRemain; // remaining awards
    uint256 private tbPrize; // prize per tenth player

    // Scan cursors / progress
    uint24 private stakeLevelComplete;
    uint32 private scanCursor = SS_IDLE;
    uint32 private coinflipPlayersCount;
    uint32 private payoutIndex;

    // Daily jackpot accounting
    uint256 private dailyCoinBurn;
    uint256 private currentTenthPlayerBonusPool;

    // queue over storage we reuse every round
    address[] private cfPlayers;
    uint256 private cfHead; // next index to pay
    uint256 private cfTail; // next slot to write

    mapping(address => uint256) public coinflipAmount;

    // O(1) “largest bettor” tracking
    PlayerScore[4] public topBettors;

    // Affiliates / luckbox
    mapping(bytes32 => address) private affiliateCode;
    mapping(uint24 => mapping(address => uint256)) public affiliateCoinEarned; // level => player => earned
    mapping(address => address) public referredBy;
    mapping(address => uint256) public playerLuckbox;
    PlayerScore[10] public luckboxLeaderboard;
    PlayerScore[8] public affiliateLeaderboard;

    // Staking
    mapping(uint24 => address[]) private stakeAddr; // level => stakers
    mapping(uint24 => mapping(address => uint256)) private stakeAmt; // level => packed stake lanes (principal/risk)

    // Leaderboard index maps (1-based positions)
    mapping(address => uint8) private luckboxPos;
    mapping(address => uint8) private affiliatePos;
    mapping(address => uint8) private topPos;

    // RNG
    uint256 private rngWord;
    uint256 private rngRequestId;

    // Bounty / BAF heads
    uint256 public currentBounty = ONEK;
    uint256 public biggestFlipEver = ONEK;
    address private bountyOwedTo;

    // BAF / Decimator execution state
    BAFState private bafState;
    BAFScan private bs;
    uint256 private extVar; // decimator accumulator/denominator

    // Decimator tracking
    mapping(address => DecEntry) private decBurn;
    mapping(uint24 => mapping(uint256 => address[])) private decBuckets; // level => bucketIdx => players
    mapping(uint24 => uint256) private decPlayersCount;

    // Presale tiers
    uint256 public totalPresaleSold;
    uint256 private constant TIER1_BOUNDARY = 800_000 * MILLION;
    uint256 private constant TIER2_BOUNDARY = 1_600_000 * MILLION;
    uint256 private constant TIER3_BOUNDARY = 2_400_000 * MILLION;
    uint256 private constant TIER1_PRICE = 0.000012 ether;
    uint256 private constant TIER2_PRICE = 0.000014 ether;
    uint256 private constant TIER3_PRICE = 0.000016 ether;
    uint256 private constant TIER4_PRICE = 0.000018 ether;
    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyPurgeGameContract() {
        if (msg.sender != purgeGameContract) revert OnlyGame();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    /**
     * @param _vrfCoordinator    Chainlink VRF v2.5 coordinator
     * @param _keyHash           Key hash for the coordinator
     * @param _subId             Subscription id (funded with LINK / native per config)
     */
    constructor(address _vrfCoordinator, bytes32 _keyHash, uint256 _subId) {
        name = "Purgecoin";
        symbol = "PURGE";
        decimals = 6;
        s_vrfCoordinator = _vrfCoordinator;
        creator = msg.sender;
        vrfKeyHash = _keyHash;
        vrfSubscriptionId = _subId;

        // Initial supply: reserve for presale and deployer allocation.
        _mint(address(this), PRESALEAMOUNT);
        _mint(creator, PRESALEAMOUNT);
    }

    // Lucky burn + optional coinflip deposit
    /// @notice Burn PURGED to grow luckbox and (optionally) place a coinflip deposit in the same tx.
    /// @dev
    /// - Reverts if betting is paused.
    /// - `amount` must be ≥ MIN; if `coinflipDeposit` > 0 it must be ≥ MIN and burn must be at least 2% of it.
    /// - Burns the sum (`amount + coinflipDeposit`), then (if provided) schedules the flip via `addFlip`.
    /// - Credits luckbox with `amount + coinflipDeposit/50` and updates the luckbox leaderboard.
    /// - If the Decimator window is active, accumulates the caller’s burn for the current level.
    function luckyCoinBurn(uint256 amount, uint256 coinflipDeposit) external {
        if (isBettingPaused) revert BettingPaused();
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;
        uint256 burnTotal = amount + coinflipDeposit;
        uint256 bal = balanceOf[msg.sender];
        if (burnTotal == bal) burnTotal -= 1; // leave 1 unit to avoid zero balance

        if (coinflipDeposit != 0) {
            if (coinflipDeposit < MIN) revert FlipLTMin();
            // Require burn to be at least 2% of the coinflip deposit.
            if (amount * 50 < coinflipDeposit) revert BurnLT2pct();
        }

        _burn(caller, burnTotal);

        if (coinflipDeposit != 0) {
            // Internal flip accounting; assumed non-reentrant / no external calls.
            addFlip(caller, coinflipDeposit, true);
        }

        unchecked {
            // Track aggregate burn and grow caller luckbox (adds +2% of deposit).
            dailyCoinBurn += amount;
            uint256 newLuck = playerLuckbox[caller] + amount + coinflipDeposit / 50;
            playerLuckbox[caller] = newLuck;

            // Update luckbox leaderboard (board 0 = luckbox).
            _updatePlayerScore(0, caller, newLuck);
        }

        // If Decimator window is active, accumulate burn this level.
        (bool decOn, uint24 lvl) = _decWindow();
        if (decOn) {
            DecEntry storage e = decBurn[caller];
            if (e.level != lvl) {
                e.level = lvl;
                e.burn = uint232(amount);
                _decPush(lvl, caller);
            } else {
                e.burn += uint232(amount);
            }
        }

        emit LuckyCoinBurned(caller, amount, coinflipDeposit);
    }

    // Affiliate code management
    /// @notice Create a new affiliate code mapping to the caller.
    /// @dev Reverts if `code_` is zero or already taken.
    function createAffiliateCode(bytes32 code_) external {
        if (code_ == bytes32(0)) revert Zero();
        if (affiliateCode[code_] != address(0)) revert Insufficient();
        affiliateCode[code_] = msg.sender;
        emit Affiliate(1, code_, msg.sender); // 1 = code created
    }

    /// @notice Set the caller’s referrer once using a valid affiliate code.
    /// @dev Reverts if code is unknown, self-referral, or caller already has a referrer.
    function referPlayer(bytes32 code_) external {
        address referrer = affiliateCode[code_];
        if (referrer == address(0) || referrer == msg.sender || referredBy[msg.sender] != address(0)) {
            revert Insufficient();
        }
        referredBy[msg.sender] = referrer;
        emit Affiliate(0, code_, msg.sender); // 0 = player referred
    }
    // Stake with encoded risk window
    function _encodeStakeLane(uint256 principalRounded, uint8 risk) private pure returns (uint256) {
        if (risk == 0 || risk > MAX_RISK) revert StakeInvalid();
        if (principalRounded == 0) revert StakeInvalid();

        uint256 normalized = principalRounded / STAKE_PRINCIPAL_FACTOR;
        if (normalized == 0) normalized = 1;
        if (normalized > STAKE_LANE_PRINCIPAL_MASK) {
            normalized = STAKE_LANE_PRINCIPAL_MASK;
        }
        return normalized | (uint256(risk) << STAKE_LANE_RISK_SHIFT);
    }

    function _decodeStakeLane(uint256 lane) private pure returns (uint256 principalRounded, uint8 risk) {
        if (lane == 0) return (0, 0);
        uint256 units = lane & STAKE_LANE_PRINCIPAL_MASK;
        principalRounded = units * STAKE_PRINCIPAL_FACTOR;
        risk = uint8((lane & STAKE_LANE_RISK_MASK) >> STAKE_LANE_RISK_SHIFT);
    }

    function _laneAt(uint256 encoded, uint8 index) private pure returns (uint256) {
        if (index >= STAKE_MAX_LANES) return 0;
        uint256 shift = uint256(index) * STAKE_LANE_BITS;
        return (encoded >> shift) & STAKE_LANE_MASK;
    }

    function _setLane(uint256 encoded, uint8 index, uint256 laneValue) private pure returns (uint256) {
        uint256 shift = uint256(index) * STAKE_LANE_BITS;
        uint256 mask = STAKE_LANE_MASK << shift;
        return (encoded & ~mask) | (laneValue << shift);
    }

    function _laneCount(uint256 encoded) private pure returns (uint8 count) {
        if ((encoded & STAKE_LANE_MASK) != 0) count++;
        if (((encoded >> STAKE_LANE_BITS) & STAKE_LANE_MASK) != 0) count++;
        if (((encoded >> (2 * STAKE_LANE_BITS)) & STAKE_LANE_MASK) != 0) count++;
    }

    function _ensureCompatible(uint256 encoded, uint8 expectRisk) private pure {
        uint8 lanes = _laneCount(encoded);
        for (uint8 i; i < lanes; ) {
            (, uint8 haveRisk) = _decodeStakeLane(_laneAt(encoded, i));
            if (haveRisk != expectRisk) revert StakeInvalid();
            unchecked {
                ++i;
            }
        }
    }

    function _insertLane(uint256 encoded, uint256 laneValue, bool strictCapacity) private pure returns (uint256) {
        (, uint8 riskNew) = _decodeStakeLane(laneValue);

        uint8 lanes = _laneCount(encoded);

        // Try to merge with an existing lane carrying the same risk
        for (uint8 idx; idx < lanes; ) {
            uint256 target = _laneAt(encoded, idx);
            (, uint8 riskExisting) = _decodeStakeLane(target);
            if (riskExisting == riskNew) {
                uint256 unitsExisting = target & STAKE_LANE_PRINCIPAL_MASK;
                uint256 unitsNew = laneValue & STAKE_LANE_PRINCIPAL_MASK;
                uint256 totalUnits = unitsExisting + unitsNew;
                if (totalUnits >> STAKE_LANE_PRINCIPAL_BITS != 0) revert StakeInvalid();
                uint256 mergedLane = (target & ~STAKE_LANE_PRINCIPAL_MASK) | totalUnits;
                return _setLane(encoded, idx, mergedLane);
            }
            unchecked {
                ++idx;
            }
        }

        if (lanes < STAKE_MAX_LANES) {
            return _setLane(encoded, lanes, laneValue);
        }
        if (strictCapacity) revert StakeInvalid();
        // all slots occupied with different maturities
        revert StakeInvalid();
    }

    /// @notice Burn PURGED to open a future “stake window” targeting `targetLevel` with a risk radius.
    /// @dev
    /// - `burnAmt` must be ≥ 250e6 (6d).
    /// - `targetLevel` must be at least 11 levels ahead of the current game level.
    /// - `risk` ∈ [1..MAX_RISK] and cannot exceed the distance to `targetLevel`.
    /// - Encodes stake as: whole-token principal (6‑decimal trimmed) + 8-bit risk code.
    /// - Enforces no overlap/collision with caller’s existing stakes.
    function stake(uint256 burnAmt, uint24 targetLevel, uint8 risk) external {
        if (burnAmt < 250 * MILLION) revert AmountLTMin();
        if (isBettingPaused) revert BettingPaused();
        uint24 currLevel = _gameLevel();
        uint24 distance = targetLevel - currLevel;
        if (risk == 0 || risk > MAX_RISK || distance > 500 || distance < MAX_RISK) revert Insufficient();

        // Starting level where this stake is placed (inclusive)
        uint24 placeLevel = uint24(targetLevel - (risk - 1));

        // 1) Guard against direct collisions in the risk window [placeLevel .. placeLevel+risk-1]
        uint256 existingEncoded;
        for (uint24 offset = 0; offset < risk; ) {
            uint24 checkLevel = uint24(placeLevel + offset);
            existingEncoded = stakeAmt[checkLevel][msg.sender];
            if (existingEncoded != 0) {
                uint8 wantRisk = uint8(risk - offset);
                _ensureCompatible(existingEncoded, wantRisk);
                if (_laneCount(existingEncoded) >= STAKE_MAX_LANES) revert StakeInvalid();
            }
            unchecked {
                ++offset;
            }
        }

        // 2) Guard against overlap from earlier stakes that extend into placeLevel
        uint24 scanStart = currLevel;
        uint24 scanFloor = placeLevel > (MAX_RISK - 1) ? uint24(placeLevel - (MAX_RISK - 1)) : uint24(1);
        if (scanStart < scanFloor) scanStart = scanFloor;

        for (uint24 scanLevel = scanStart; scanLevel < placeLevel; ) {
            uint256 existingAtScan = stakeAmt[scanLevel][msg.sender];
            if (existingAtScan != 0) {
                uint8 lanes = _laneCount(existingAtScan);
                for (uint8 li; li < lanes; ) {
                    (, uint8 existingRisk) = _decodeStakeLane(_laneAt(existingAtScan, li));
                    uint24 reachLevel = scanLevel + uint24(existingRisk) - 1;
                    if (reachLevel >= placeLevel) {
                        uint24 impliedRiskAtPlace = uint24(existingRisk) - (placeLevel - scanLevel);
                        if (uint8(impliedRiskAtPlace) != risk) revert StakeInvalid();
                    }
                    unchecked {
                        ++li;
                    }
                }
            }
            unchecked {
                ++scanLevel;
            }
        }

        // Burn principal
        _burn(msg.sender, burnAmt);

        // Base credit and compounded boost factors
        uint256 levelBps = 5 * uint256(distance);
        if (levelBps > 300) levelBps = 300;
        uint256 riskBps = 30 * uint256(risk - 1);
        if (riskBps > 300) riskBps = 300;
        uint256 stepBps = levelBps + riskBps; // per-level growth in bps

        // Luckbox: +5% of burn
        uint256 fivePercent = burnAmt / 20;
        playerLuckbox[msg.sender] += fivePercent;
        uint256 newLuck = playerLuckbox[msg.sender];
        _updatePlayerScore(0, msg.sender, newLuck);

        // Compounded boost starting from 95% of burn (fivePercent * 19)
        uint256 boostedPrincipal = fivePercent * 19;
        for (uint24 i = distance; i != 0; ) {
            boostedPrincipal = (boostedPrincipal * (10_000 + stepBps)) / 10_000;
            unchecked {
                --i;
            }
        }

        // Encode and place the stake lane
        uint256 principalRounded = boostedPrincipal - (boostedPrincipal % STAKE_PRINCIPAL_FACTOR);
        if (principalRounded > STAKE_MAX_PRINCIPAL) {
            principalRounded = STAKE_MAX_PRINCIPAL;
        }
        if (principalRounded == 0) principalRounded = STAKE_PRINCIPAL_FACTOR;
        uint256 newLane = _encodeStakeLane(principalRounded, risk);

        uint256 existingAtPlace = stakeAmt[placeLevel][msg.sender];
        if (existingAtPlace == 0) {
            stakeAmt[placeLevel][msg.sender] = newLane;
            stakeAddr[placeLevel].push(msg.sender);
        } else {
            _ensureCompatible(existingAtPlace, risk);
            stakeAmt[placeLevel][msg.sender] = _insertLane(existingAtPlace, newLane, true);
        }

        emit StakeCreated(msg.sender, targetLevel, risk, principalRounded);
    }

    /// @notice Return the recorded referrer for `player` (zero address if none).
    function getReferrer(address player) external view returns (address) {
        return referredBy[player];
    }
    /// @notice Credit affiliate rewards for a purchase (invoked by the game contract).
    /// @dev
    /// Referral rules:
    /// - If `referredBy[sender] == address(1)`: sender is “locked” and we no-op.
    /// - Else if a referrer already exists: pay that address (`affiliateAddr = referrer`).
    /// - Else if `code` resolves to a valid address different from `sender`: bind it and use it.
    /// - Else: lock the sender to `address(1)` (no future attempts) and return.
    /// Payout rules:
    /// - `amount` is optionally doubled on levels `level % 25 == 1`.
    /// - Direct ref gets a coinflip credit equal to `amount`; their upline (if any and already active
    ///   this level) receives a 20% bonus coinflip credit of the same (post‑doubling) amount.
    function payAffiliate(uint256 amount, bytes32 code, address sender, uint24 lvl) external onlyPurgeGameContract {
        address affiliateAddr = affiliateCode[code];
        address referrer = referredBy[sender];

        // Locked sender: ignore
        if (referrer == address(1)) return;

        // Resolve the effective affiliate
        if (referrer != address(0)) {
            affiliateAddr = referrer;
        } else if (affiliateAddr != address(0) && affiliateAddr != sender) {
            referredBy[sender] = affiliateAddr;
        } else {
            // Permanently lock sender from further referral attempts
            referredBy[sender] = address(1);
            return;
        }

        if (amount != 0) {
            if (lvl % 25 == 1) amount <<= 1;

            // Pay direct affiliate (skip sentinels)
            if (affiliateAddr != address(0) && affiliateAddr != address(1)) {
                uint256 newTotal = affiliateCoinEarned[lvl][affiliateAddr] + amount;
                affiliateCoinEarned[lvl][affiliateAddr] = newTotal;
                addFlip(affiliateAddr, amount, false);
                _updatePlayerScore(1, affiliateAddr, newTotal);
            }

            // Upline bonus (20%) only if upline is active this level
            address upline = referredBy[affiliateAddr];
            if (
                upline != address(0) && upline != address(1) && upline != sender && affiliateCoinEarned[lvl][upline] > 0
            ) {
                uint256 bonus = amount / 5;
                if (bonus != 0) {
                    uint256 newTotalU = affiliateCoinEarned[lvl][upline] + bonus;
                    affiliateCoinEarned[lvl][upline] = newTotalU;
                    addFlip(upline, bonus, false);
                    _updatePlayerScore(1, upline, newTotalU);
                }
            }
        }

        emit Affiliate(amount, code, sender);
    }

    /// @notice Clear the affiliate leaderboard and index for the next cycle (invoked by the game).
    function resetAffiliateLeaderboard() external onlyPurgeGameContract {
        uint8 len = affiliateLen;
        for (uint8 i; i < len; ) {
            address addr = affiliateLeaderboard[i].player;
            delete affiliatePos[addr];
            unchecked {
                ++i;
            }
        }
        delete affiliateLeaderboard; // zero out fixed-size array entries
        affiliateLen = 0;
    }
    /// @notice Buy PURGE during the tiered presale by sending exact ETH.
    /// @dev
    /// Requirements:
    /// - `amount` uses token base units (decimals = 6 assumed by constants).
    /// - `amount >= 5e6` and is a multiple of `1e6`.
    /// - Not more than the remaining presale allocation.
    /// Effects:
    /// - Increments `totalPresaleSold`.
    /// - Forwards ETH to `creator`.
    /// - Transfers `amount` tokens from this contract to the buyer.
    function presale(uint256 amount) external payable {
        if (amount < 5 * MILLION) revert AmountLTMin();
        if (amount % MILLION != 0) revert InvalidKind();

        uint256 sold = totalPresaleSold;
        if (amount > PRESALEAMOUNT - sold) revert PresaleExceedsRemaining();

        uint256 costWei = _computePresaleCostAtSold(amount, sold);
        if (msg.value != costWei) revert Insufficient();

        // Effects
        totalPresaleSold = sold + amount;

        // Interactions (ETH to creator)
        (bool ok, ) = payable(creator).call{value: costWei}("");
        if (!ok) revert Insufficient();

        // Token transfer to buyer
        _transfer(address(this), msg.sender, amount);
    }

    /// @notice Quote the ETH required to purchase `amount` at the current presale tier state.
    /// @dev Reverts if `amount` is zero, not a multiple of `1e6`, or exceeds remaining allocation.
    function quotePresaleCost(uint256 amount) external view returns (uint256 costWei) {
        if (amount == 0) revert Insufficient();
        if (amount % MILLION != 0) revert InvalidKind();

        uint256 sold = totalPresaleSold;
        if (amount > PRESALEAMOUNT - sold) revert PresaleExceedsRemaining();

        return _computePresaleCostAtSold(amount, sold);
    }

    /// @notice Compute the tiered presale cost for `amount`, given `sold` units already sold.
    /// @dev Splits `amount` across tier buckets [T1..T4] using remaining capacity in order,
    ///      then multiplies by per‑tier prices. All arithmetic uses base‑unit amounts (1e6).
    function _computePresaleCostAtSold(uint256 amount, uint256 sold) internal pure returns (uint256 costWei) {
        unchecked {
            uint256 tier1Qty;
            uint256 tier2Qty;
            uint256 tier3Qty;
            uint256 remainingQty = amount;

            if (sold < TIER1_BOUNDARY) {
                uint256 space1 = TIER1_BOUNDARY - sold;
                tier1Qty = remainingQty < space1 ? remainingQty : space1;
                sold += tier1Qty;
                remainingQty -= tier1Qty;
            }
            if (remainingQty != 0 && sold < TIER2_BOUNDARY) {
                uint256 space2 = TIER2_BOUNDARY - sold;
                tier2Qty = remainingQty < space2 ? remainingQty : space2;
                sold += tier2Qty;
                remainingQty -= tier2Qty;
            }
            if (remainingQty != 0 && sold < TIER3_BOUNDARY) {
                uint256 space3 = TIER3_BOUNDARY - sold;
                tier3Qty = remainingQty < space3 ? remainingQty : space3;
                sold += tier3Qty;
                remainingQty -= tier3Qty;
            }

            // Divide by 1e6 at the end since amounts are in base units (decimals = 6).
            costWei =
                (tier1Qty * TIER1_PRICE +
                    tier2Qty * TIER2_PRICE +
                    tier3Qty * TIER3_PRICE +
                    remainingQty * TIER4_PRICE) / MILLION;
        }
    }

    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != s_vrfCoordinator) {
            revert OnlyCoordinatorCanFulfill(msg.sender, s_vrfCoordinator);
        }
        fulfillRandomWords(requestId, randomWords);
    }

    function requestRngPurgeGame(bool pauseBetting) external onlyPurgeGameContract {
        uint256 id = _vrfRequestRandomWords(
            VRFRandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: 1,
                extraArgs: abi.encodeWithSelector(EXTRA_ARGS_V1_TAG, VRFExtraArgsV1({nativePayment: false}))
            })
        );
        rngFulfilled = false;
        rngWord = 0;
        rngRequestId = id;
        isBettingPaused = pauseBetting;
    }

    /// @notice VRF callback: store the random word once for the expected request.
    /// @dev Reverts if `requestId` does not match the most recent request or if already fulfilled.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal {
        if (requestId != rngRequestId || rngFulfilled) return;
        rngFulfilled = true;
        rngWord = randomWords[0];
    }

    /// @notice Read the current VRF word (0 if not yet fulfilled).
    function pullRng() external view returns (uint256) {
        return rngFulfilled ? rngWord : 0;
    }
    /// @notice One‑time wiring of the PurgeGame contract address.
    /// @dev Access: deployer/creator only; irreversible (no admin update).
    function addContractAddress(address a) external {
        if (purgeGameContract != address(0) || msg.sender != creator) revert OnlyDeployer();
        purgeGameContract = a;
    }

    /// @notice Credit the creator’s share of gameplay proceeds.
    /// @dev Access: PurgeGame only. Zero amounts are ignored.
    function Burnie(uint256 amount) external onlyPurgeGameContract {
        if (amount == 0) return;
        _mint(creator, amount);
    }

    /// @notice Grant a pending coinflip stake during gameplay flows instead of minting PURGE.
    /// @dev Access: PurgeGame only. Zero address or zero amount are ignored.
    function grantCoinflipInGame(address player, uint256 amount) external onlyPurgeGameContract {
        if (player == address(0) || amount == 0) return;
        addFlip(player, amount, false);
    }

    /// @notice Burn PURGE from `target` during gameplay flows (purchases, fees),
    ///         and credit 2% of the burned amount to their luckbox.
    /// @dev Access: PurgeGame only. OZ ERC20 `_burn` reverts on zero address or insufficient balance.
    ///      Leaderboard is refreshed only when a non‑zero credit is applied.
    function burnInGame(address target, uint256 amount) external onlyPurgeGameContract {
        _burn(target, amount);
        // 2% luckbox credit; skip if too small to matter after integer division.
        uint256 credit = amount / 50; // 2%
        uint256 newLuck = playerLuckbox[target] + credit;
        playerLuckbox[target] = newLuck;
        _updatePlayerScore(0, target, newLuck); // luckbox leaderboard
    }

    /// @notice Progress coinflip payouts for the current level in bounded slices.
    /// @dev Called by PurgeGame. Operates in four phases per “day”:
    ///      (1) Optional stake propagation (once per level/day; only if coinflip win).
    ///      (2) Arm bounty & “tenth‑player” bonus on the first payout window.
    ///      (3) Pay player flips (and tenth‑player bonuses) in batches.
    ///      (4) Cleanup in batches; on completion, reset per‑round state and unpause betting.
    /// @param level Current PurgeGame level (used to gate 1/run and propagate stakes).
    /// @param cap   Work cap hint. cap==0 uses defaults; otherwise applies directly.
    /// @param bonusFlip Applies 10% bonus to last flip of purchase phase
    /// @return finished True once the entire cycle—including cleanup—has completed.
    function processCoinflipPayouts(
        uint24 level,
        uint32 cap,
        bool bonusFlip
    ) external onlyPurgeGameContract returns (bool finished) {
        if (!isBettingPaused) return true;
        // --- Step sizing (bounded work) ----------------------------------------------------

        uint32 stepPayout = (cap == 0) ? 500 : cap;
        uint32 stepStake = (cap == 0) ? 200 : cap;

        uint256 word = rngWord;
        bool win = (word & 1) == 1;
        if (!win) stepPayout <<= 2; // 4x work on losses to clear backlog faster
        // --- (1) Stake propagation (once per level; only if coinflip result is win) --------
        if (payoutIndex == 0 && stakeLevelComplete < level) {
            uint32 st = scanCursor;
            if (st == SS_IDLE) {
                st = 0;
                scanCursor = 0;
            }

            if (st != SS_DONE) {
                // If loss: mark complete; no propagation.
                if (!win) {
                    scanCursor = SS_DONE;
                    stakeLevelComplete = level;
                } else {
                    // Win: process stakers at this level in slices.
                    address[] storage a = stakeAddr[level];
                    uint32 len = uint32(a.length);
                    if (st < len) {
                        uint32 en = st + stepStake;
                        if (en > len) en = len;

                        for (uint32 i = st; i < en; ) {
                            address s = a[i];
                            uint256 enc = stakeAmt[level][s];
                            if (enc != 0) {
                                for (uint8 li; li < STAKE_MAX_LANES; ) {
                                    uint256 lane = _laneAt(enc, li);
                                    if (lane != 0) {
                                        (uint256 pr, uint8 rf) = _decodeStakeLane(lane);
                                        if (rf <= 1) {
                                            uint256 fivePct = pr / 20;
                                            uint256 newLuck = playerLuckbox[s] + fivePct;
                                            playerLuckbox[s] = newLuck;
                                            _updatePlayerScore(0, s, newLuck);
                                            addFlip(s, fivePct * 19, false);
                                        } else {
                                            uint24 nextL = level + 1;
                                            uint8 newRf = rf - 1;
                                            uint256 laneValue = _encodeStakeLane(pr * 2, newRf);
                                            uint256 nextEnc = stakeAmt[nextL][s];
                                            if (nextEnc == 0) {
                                                stakeAmt[nextL][s] = laneValue;
                                                stakeAddr[nextL].push(s);
                                            } else {
                                                stakeAmt[nextL][s] = _insertLane(nextEnc, laneValue, false);
                                            }
                                        }
                                    }
                                    unchecked {
                                        ++li;
                                    }
                                }
                            }
                            unchecked {
                                ++i;
                            }
                        }

                        scanCursor = (en == len) ? SS_DONE : en;
                        return false; // more stake processing remains
                    }

                    // Finished this phase.
                    scanCursor = SS_DONE;
                    stakeLevelComplete = level;
                    return false; // allow caller to continue in a subsequent call
                }
            }
        }

        // --- (2) Bounty payout & tenth‑player bonus arming (first payout window only) -------
        uint256 totalPlayers = coinflipPlayersCount;

        // Bounty: convert any owed bounty into a flip credit on the first window.
        if (totalPlayers != 0 && payoutIndex == 0 && bountyOwedTo != address(0) && currentBounty > 0) {
            address to = bountyOwedTo;
            uint256 amt = currentBounty;
            bountyOwedTo = address(0);
            currentBounty = 0;
            addFlip(to, amt, false);
            emit BountyPaid(to, amt);
        }

        // “Every 10th player” bonus pool: arm once per round when win and enough players.
        if (win && payoutIndex == 0 && currentTenthPlayerBonusPool > 0 && totalPlayers >= 10) {
            uint256 bonusPool = currentTenthPlayerBonusPool;
            currentTenthPlayerBonusPool = 0;
            uint32 rem = uint32(totalPlayers / 10); // how many 10th slots exist
            if (rem != 0) {
                uint256 prize = bonusPool / rem;
                uint256 dust = bonusPool - prize * rem;
                if (dust > 0) _addToBounty(dust);
                tbPrize = prize;
                tbRemain = rem;
                tbActive = (prize != 0);
            } else {
                _addToBounty(bonusPool);
                tbActive = false;
            }
            tbMod = uint8(uint256(keccak256(abi.encodePacked(word, "tenthMod"))) % 10); // wheel offset 0..9
        }

        // --- (3) Player payouts (windowed by stepPayout) -----------------------------------
        uint256 start = payoutIndex;
        uint256 end = start + stepPayout;
        if (end > totalPlayers) end = totalPlayers;

        uint8 wheel = uint8(start % 10); // rolling 0..9 index for tenth‑player bonus

        for (uint256 i = start; i < end; ) {
            address p = _playerAt(i);

            uint256 credit; // accumulate bonus + flip payout

            // Tenth‑player bonus
            if (tbActive && tbRemain != 0 && wheel == tbMod) {
                credit = tbPrize;
                unchecked {
                    --tbRemain;
                }
                if (tbRemain == 0) tbActive = false;
            }

            // Flip payout: double on win, zero out stake in all cases.
            uint256 amt = coinflipAmount[p];
            if (amt != 0) {
                coinflipAmount[p] = 0;
                if (win) {
                    if (bonusFlip) amt = (amt * 11) / 10; // keep current rounding semantics
                    unchecked {
                        credit += amt * 2;
                    }
                }
            }

            if (credit != 0) _mint(p, credit);

            unchecked {
                ++i;
                wheel = (wheel == 9) ? 0 : (wheel + 1);
            }
        }
        payoutIndex = uint32(end);
        // --- (4) Cleanup (single-shot) -------------------------------------------
        if (end >= totalPlayers) {
            for (uint8 k; k < topLen; ) {
                address q = topBettors[k].player;
                if (q != address(0)) topPos[q] = 0;
                unchecked {
                    ++k;
                }
            }
            delete topBettors;
            topLen = 0;

            tbActive = false;
            tbRemain = 0;
            tbPrize = 0;
            tbMod = 0;
            cfHead = cfTail;
            payoutIndex = 0;
            coinflipPlayersCount = 0;

            scanCursor = SS_IDLE;

            isBettingPaused = false;
            emit CoinflipFinished(win);

            rngRequestId = 0;
            return true;
        }

        return false;
    }
    /// @notice Distribute “coin jackpots” after the daily coinflip result is known.
    /// @dev
    /// Flow (only callable by PurgeGame):
    ///  - If loss: reset `dailyCoinBurn` and exit.
    ///  - If win:
    ///     * Add 15% of (max(dailyCoinBurn, 8k PURGED)) to the bounty.
    ///     * Pay 4 trait jackpots (15% total → 3.75% each) to the top‑luckbox among 5 candidates per trait,
    ///       else roll that slice into the bounty if no candidate qualifies.
    ///     * From 30% pool: credit the largest bettor, a random pick among #3/#4, arm the “every 10th player”
    ///       bonus (paid during payouts), and split the remainder to luckbox leaderboard players with ≥ 1000 PURGED
    ///       currently staked in flips. Any remainder dust is rolled into the bounty.
    ///  - Finally, zero `dailyCoinBurn` for the next cycle.
    function triggerCoinJackpot() external onlyPurgeGameContract {
        uint256 randWord = rngWord;
        bool flipWin = (rngWord & 1) == 1;
        if (!flipWin) {
            dailyCoinBurn = 0;
            return;
        }

        uint256 burnBase = dailyCoinBurn;
        if (burnBase < 8000 * MILLION) burnBase = 8000 * MILLION;

        // ----- (A) Always add 15% to the bounty -----
        _addToBounty((burnBase * 15) / 100);

        // ----- (B) 4× trait jackpots from another 15% (3.75% each) -----
        {
            uint256 traitPool = (burnBase * 15) / 100;
            if (traitPool != 0) {
                uint256 traitRnd = uint256(keccak256(abi.encodePacked(randWord, "CoinJackpot")));
                uint256 perTraitPrize = traitPool / 4; // remainder intentionally not used

                for (uint8 i; i < 4; ) {
                    if (i > 0) traitRnd = uint256(keccak256(abi.encodePacked(traitRnd, i)));
                    uint8 winningTrait = uint8(traitRnd & 0x3F) + (i << 6);

                    // Up to 5 candidates sampled by the game; pick highest luckbox.
                    address[] memory candidates = _gameJackpotWinners(randWord, winningTrait, 5, uint8(42 + i));
                    address winnerAddr = getTopLuckbox(candidates);

                    emit CoinJackpotPaid(winningTrait, winnerAddr, perTraitPrize);
                    if (winnerAddr != address(0)) {
                        _mint(winnerAddr, perTraitPrize);
                    } else {
                        _addToBounty(perTraitPrize);
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
        }

        // ----- (C) Player / leaderboard jackpots from 30% -----
        {
            uint256 totalPlayers = coinflipPlayersCount;
            uint256 playerPool = (burnBase * 30) / 100;

            if (totalPlayers != 0 && playerPool != 0) {
                uint256 lbPrize = (playerPool * 35) / 100; // largest bettor
                uint256 midPrize = (playerPool * 15) / 100; // random among #3 / #4 bettors
                currentTenthPlayerBonusPool = (playerPool * 20) / 100; // paid during payouts
                uint256 lbPool = playerPool - lbPrize - midPrize - currentTenthPlayerBonusPool;

                // Largest bettor gets credited now (paid when payouts run).
                address largestBettor = topBettors[0].player;
                if (largestBettor != address(0)) {
                    coinflipAmount[largestBettor] += lbPrize;
                }

                // Randomly pick #3 or #4.
                address midWinner = topBettors[2 + (uint256(keccak256(abi.encodePacked(randWord, "p34"))) & 1)].player;
                if (midWinner != address(0)) {
                    coinflipAmount[midWinner] += midPrize;
                }

                // Luckbox leaderboard split (only those with ≥ 1000 PURGED in active flips).
                if (lbPool != 0) {
                    address[10] memory eligible;
                    uint256 eligibleCount;
                    address topLuck = luckboxLeaderboard[0].player;
                    bool topIncluded;

                    for (uint8 i; i < 10; ) {
                        address p = luckboxLeaderboard[i].player;
                        if (p != address(0) && coinflipAmount[p] >= ONEK) {
                            eligible[eligibleCount] = p;
                            if (p == topLuck) topIncluded = true;
                            unchecked {
                                ++eligibleCount;
                            }
                        }
                        unchecked {
                            ++i;
                        }
                    }

                    if (eligibleCount == 0) {
                        _addToBounty(lbPool);
                    } else if (topIncluded) {
                        if (eligibleCount == 1) {
                            _mint(topLuck, lbPool);
                            emit CoinJackpotPaid(420, topLuck, lbPool);
                        } else {
                            uint256 topCut = (lbPool * 25) / 100;
                            _mint(topLuck, topCut);
                            emit CoinJackpotPaid(420, topLuck, topCut);

                            uint256 rem = lbPool - topCut;
                            uint256 each = rem / (eligibleCount - 1);
                            uint256 paid;

                            for (uint256 i; i < eligibleCount; ) {
                                address w = eligible[i];
                                if (w != topLuck) {
                                    _mint(w, each);
                                    emit CoinJackpotPaid(420, w, each);
                                    paid += each;
                                }
                                unchecked {
                                    ++i;
                                }
                            }
                            uint256 dust = lbPool - (paid + topCut);
                            if (dust != 0) _addToBounty(dust);
                        }
                    } else {
                        uint256 each = lbPool / eligibleCount;
                        uint256 paid;
                        for (uint256 i; i < eligibleCount; ) {
                            address w = eligible[i];
                            _mint(w, each);
                            emit CoinJackpotPaid(420, w, each);
                            paid += each;
                            unchecked {
                                ++i;
                            }
                        }
                        uint256 dust = lbPool - paid;
                        if (dust != 0) _addToBounty(dust);
                    }
                }
            }
        }

        // Reset for next day.
        dailyCoinBurn = 0;
    }
    /// @notice Progress an external jackpot: BAF (kind=0) or Decimator (kind=1).
    /// @dev
    /// Lifecycle:
    /// - First call (not in progress): arms the run based on `kind`, snapshots limits, computes offsets,
    ///   and optionally performs BAF “headline” allocations (largest bettor, etc.). When more work is
    ///   required, returns (finished=false, partial winners/amounts, 0).
    /// - Subsequent calls stream through the remaining work in windowed batches until finished=true.
    /// Storage/Modes:
    /// - `bafState.inProgress` gates the run. `extMode` encodes the sub‑phase:
    ///     0 = idle, 1 = BAF scatter pass, 2 = Decimator denom accumulation, 3 = Decimator payouts.
    /// - `scanCursor` walks the population starting at `bs.offset` then advancing in steps of 10.
    /// Returns:
    /// - `finished` signals completion of the whole external run.
    /// - `winners/amounts` are the credits to be applied by the caller on this step only.
    /// - `returnAmountWei` is any ETH to send back to the game (unused mid‑run).
    function runExternalJackpot(
        uint8 kind,
        uint256 poolWei,
        uint32 cap,
        uint24 lvl
    )
        external
        onlyPurgeGameContract
        returns (bool finished, address[] memory winners, uint256[] memory amounts, uint256 returnAmountWei)
    {
        uint32 batch = (cap == 0) ? BAF_BATCH : cap;

        uint256 executeWord = rngWord;

        // ----------------------------------------------------------------------
        // Arm a new external run
        // ----------------------------------------------------------------------
        if (!bafState.inProgress) {
            if (kind > 1) revert InvalidKind();

            bafState.inProgress = true;

            uint32 limit = (kind == 0) ? uint32(coinflipPlayersCount) : uint32(decPlayersCount[lvl]);

            // Randomize the stride modulo for the 10‑way sharded buckets
            bs.offset = uint8(executeWord % 10);
            bs.limit = limit;
            scanCursor = bs.offset;

            // Pool/accounting snapshots
            bafState.totalPrizePoolWei = uint128(poolWei);
            bafState.returnAmountWei = 0;

            extVar = 0;
            extMode = (kind == 0) ? uint8(1) : uint8(2);

            // ---------------------------
            // kind == 0 : BAF headline + setup scatter
            // ---------------------------
            if (kind == 0) {
                uint256 P = poolWei;
                uint256 lbMin = (ONEK / 4) * uint256(lvl); // minimum “active” threshold
                address[6] memory tmpW;
                uint256[6] memory tmpA;
                uint256 n;
                uint256 credited;
                uint256 toReturn;

                // (1) Largest bettor — 20%
                {
                    uint256 prize = (P * 20) / 100;
                    address w = topBettors[0].player;
                    if (_eligible(w, lbMin)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }
                // (2) Random among #3/#4 — 10%
                {
                    uint256 prize = (P * 10) / 100;
                    address w = topBettors[2 + (uint256(keccak256(abi.encodePacked(executeWord, "p34"))) & 1)].player;
                    if (_eligible(w, lbMin)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }
                // (3) Random eligible — 10%
                {
                    uint256 prize = (P * 10) / 100;
                    address w = _randomEligible(uint256(keccak256(abi.encodePacked(executeWord, "re"))), lbMin);
                    if (w != address(0)) {
                        tmpW[n] = w;
                        tmpA[n] = prize;
                        unchecked {
                            ++n;
                        }
                        credited += prize;
                    } else {
                        toReturn += prize;
                    }
                }
                // (4) Luckbox LB #1/#2/#3 — 7%/5%/3%
                {
                    uint256 p1 = (P * 7) / 100;
                    uint256 p2 = (P * 5) / 100;
                    uint256 p3 = (P * 3) / 100;
                    address w1 = luckboxLeaderboard[0].player;
                    address w2 = luckboxLeaderboard[1].player;
                    address w3 = luckboxLeaderboard[2].player;
                    if (_eligible(w1, lbMin)) {
                        tmpW[n] = w1;
                        tmpA[n] = p1;
                        unchecked {
                            ++n;
                        }
                        credited += p1;
                    } else {
                        toReturn += p1;
                    }
                    if (_eligible(w2, lbMin)) {
                        tmpW[n] = w2;
                        tmpA[n] = p2;
                        unchecked {
                            ++n;
                        }
                        credited += p2;
                    } else {
                        toReturn += p2;
                    }
                    if (_eligible(w3, lbMin)) {
                        tmpW[n] = w3;
                        tmpA[n] = p3;
                        unchecked {
                            ++n;
                        }
                        credited += p3;
                    } else {
                        toReturn += p3;
                    }
                }

                // Scatter the remainder equally across shard‑stride participants
                uint256 scatter = P - credited - toReturn;
                if (limit >= 10 && bs.offset < limit) {
                    uint256 occurrences = 1 + (uint256(limit) - 1 - bs.offset) / 10; // count of indices visited
                    uint256 perWei = scatter / occurrences;
                    bs.per = uint120(perWei);

                    // Accumulate “toReturn” plus any scatter dust
                    uint256 rem = toReturn + (scatter - perWei * occurrences);
                    bafState.returnAmountWei = uint120(rem);
                } else {
                    bs.per = 0;
                    bafState.returnAmountWei = uint120(toReturn + scatter);
                }

                // Emit headline winners for this step
                winners = new address[](n);
                amounts = new uint256[](n);
                for (uint256 i; i < n; ) {
                    winners[i] = tmpW[i];
                    amounts[i] = tmpA[i];
                    unchecked {
                        ++i;
                    }
                }

                // If nothing to scatter (or empty population), finish immediately
                if (bs.per == 0 || limit < 10 || bs.offset >= limit) {
                    uint256 ret = uint256(bafState.returnAmountWei);
                    delete bafState;
                    delete bs;
                    extMode = 0;
                    extVar = 0;
                    scanCursor = SS_IDLE;
                    return (true, winners, amounts, ret);
                }
                return (false, winners, amounts, 0);
            }

            // ---------------------------
            // kind == 1 : Decimator armed; denom pass first
            // ---------------------------
            return (false, new address[](0), new uint256[](0), 0);
        }

        // ----------------------------------------------------------------------
        // BAF scatter pass (extMode == 1)
        // ----------------------------------------------------------------------
        if (extMode == 1) {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            uint256 tmpCap = uint256(batch) / 10 + 2; // rough upper bound on step winners
            address[] memory tmpWinners = new address[](tmpCap);
            uint256[] memory tmpAmounts = new uint256[](tmpCap);
            uint256 n2;
            uint256 per = uint256(bs.per);
            uint256 lbMin = (ONEK / 4) * uint256(lvl);
            uint256 retWei = uint256(bafState.returnAmountWei);

            for (uint32 i = scanCursor; i < end; ) {
                address p = _playerAt(i);
                if (_eligible(p, lbMin)) {
                    tmpWinners[n2] = p;
                    tmpAmounts[n2] = per;
                    unchecked {
                        ++n2;
                    }
                } else {
                    retWei += per;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;
            bafState.returnAmountWei = uint120(retWei);

            winners = new address[](n2);
            amounts = new uint256[](n2);
            for (uint256 k; k < n2; ) {
                winners[k] = tmpWinners[k];
                amounts[k] = tmpAmounts[k];
                unchecked {
                    ++k;
                }
            }

            if (end == bs.limit) {
                uint256 ret = uint256(bafState.returnAmountWei);
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                return (true, winners, amounts, ret);
            }
            return (false, winners, amounts, 0);
        }

        // ----------------------------------------------------------------------
        // Decimator denom accumulation (extMode == 2)
        // ----------------------------------------------------------------------
        if (extMode == 2) {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;
            uint256 lbMin = (ONEK / 4) * uint256(lvl);

            for (uint32 i = scanCursor; i < end; ) {
                address p = _srcPlayer(1, lvl, i);
                DecEntry storage e = decBurn[p];
                if (e.level == lvl && _eligibleLuckbox(p, lbMin)) {
                    extVar += e.burn;
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;

            if (end < bs.limit) return (false, new address[](0), new uint256[](0), 0);

            // Nothing eligible → refund entire pool
            if (extVar == 0) {
                uint256 refund = uint256(bafState.totalPrizePoolWei);
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                return (true, new address[](0), new uint256[](0), refund);
            }

            // Proceed to payouts
            extMode = 3;
            scanCursor = bs.offset;
            return (false, new address[](0), new uint256[](0), 0);
        }

        // ----------------------------------------------------------------------
        // Decimator payouts (extMode == 3)
        // ----------------------------------------------------------------------
        {
            uint32 end = scanCursor + batch;
            if (end > bs.limit) end = bs.limit;

            uint256 tmpCap = uint256(batch) / 10 + 2;
            address[] memory tmpWinners = new address[](tmpCap);
            uint256[] memory tmpAmounts = new uint256[](tmpCap);
            uint256 n2;

            uint256 lbMin = (ONEK / 4) * uint256(lvl);
            uint256 pool = uint256(bafState.totalPrizePoolWei);
            uint256 denom = extVar;
            uint256 paid = uint256(bafState.returnAmountWei);

            for (uint32 i = scanCursor; i < end; ) {
                address p = _srcPlayer(1, lvl, i);
                DecEntry storage e = decBurn[p];
                if (e.level == lvl && _eligibleLuckbox(p, lbMin)) {
                    uint256 amt = (pool * e.burn) / denom;
                    if (amt != 0) {
                        tmpWinners[n2] = p;
                        tmpAmounts[n2] = amt;
                        unchecked {
                            ++n2;
                            paid += amt;
                        }
                    }
                }
                unchecked {
                    i += 10;
                }
            }
            scanCursor = end;
            bafState.returnAmountWei = uint120(paid);

            winners = new address[](n2);
            amounts = new uint256[](n2);
            for (uint256 k; k < n2; ) {
                winners[k] = tmpWinners[k];
                amounts[k] = tmpAmounts[k];
                unchecked {
                    ++k;
                }
            }

            if (end == bs.limit) {
                uint256 ret = pool > paid ? (pool - paid) : 0;
                delete bafState;
                delete bs;
                extMode = 0;
                extVar = 0;
                scanCursor = SS_IDLE;
                return (true, winners, amounts, ret);
            }
            return (false, winners, amounts, 0);
        }
    }

    /// @notice Return 1-based rank of `player` on the luckbox leaderboard, or `RANK_NOT_FOUND` (11) if absent.
    /// @dev Defensive check ensures mapping hint matches current leaderboard slot.
    function getPlayerRank(address player) external view returns (uint16) {
        uint8 pos = luckboxPos[player]; // 1..luckboxLen or 0 (not present)
        return (pos != 0 && pos <= luckboxLen && luckboxLeaderboard[pos - 1].player == player) ? pos : RANK_NOT_FOUND;
    }

    /// @notice Return addresses from a leaderboard.
    /// @param which 0 = luckbox (≤10), 1 = affiliate (≤8), 2 = top bettors (≤4).
    function getLeaderboardAddresses(uint8 which) external view returns (address[] memory out) {
        if (which == 0) {
            uint8 len = luckboxLen;
            out = new address[](len);
            for (uint8 i; i < len; ) {
                out[i] = luckboxLeaderboard[i].player;
                unchecked {
                    ++i;
                }
            }
        } else if (which == 1) {
            uint8 len = affiliateLen;
            out = new address[](len);
            for (uint8 i; i < len; ) {
                out[i] = affiliateLeaderboard[i].player;
                unchecked {
                    ++i;
                }
            }
        } else if (which == 2) {
            uint8 len = topLen;
            out = new address[](len);
            for (uint8 i; i < len; ) {
                out[i] = topBettors[i].player;
                unchecked {
                    ++i;
                }
            }
        } else {
            revert InvalidLeaderboard();
        }
    }

    /// @notice Eligibility gate requiring both luckbox balance and active coinflip stake ≥ `min`.
    function _eligible(address player, uint256 min) internal view returns (bool) {
        return playerLuckbox[player] >= min && coinflipAmount[player] >= min;
    }

    /// @notice Eligibility gate requiring only luckbox balance ≥ `min` (no coinflip amount check).
    function _eligibleLuckbox(address player, uint256 min) internal view returns (bool) {
        return playerLuckbox[player] >= min;
    }

    /// @notice Pick the first eligible player when scanning up to 300 candidates from a pseudo-random start.
    /// @dev Uses stride 2 for odd N to cover the ring without repeats; stride 1 for even N (contiguous window).
    function _randomEligible(uint256 seed, uint256 min) internal view returns (address) {
        uint256 total = coinflipPlayersCount;
        if (total == 0) return address(0);

        uint256 idx = seed % total;
        uint256 stride = (total & 1) == 1 ? 2 : 1; // ensures full coverage when total is odd
        uint256 maxChecks = total < 300 ? total : 300; // cap work

        for (uint256 tries; tries < maxChecks; ) {
            address p = _playerAt(idx);
            if (_eligible(p, min)) return p;
            unchecked {
                idx += stride;
                if (idx >= total) idx -= total;
                ++tries;
            }
        }
        return address(0);
    }
    /// @notice Return player address at global coinflip index `idx`.
    /// @dev Indexing is flattened into fixed-size buckets to avoid resizing a single array.
    ///      Callers must ensure 0 <= idx < coinflipPlayersCount for the current session.
    function _playerAt(uint256 idx) internal view returns (address) {
        return cfPlayers[cfHead + idx];
    }

    /// @notice Source player address for a given index in either coinflip or decimator lists.
    /// @param kind 0 = coinflip roster, 1 = decimator roster for `lvl`.
    /// @param lvl  Level to read when `kind == 1`.
    /// @param idx  Global flattened index (0..N-1).
    function _srcPlayer(uint8 kind, uint24 lvl, uint256 idx) internal view returns (address) {
        if (kind == 0) {
            return cfPlayers[cfHead + idx];
        }
        uint256 bucketIdx = idx / BUCKET_SIZE;
        uint256 offsetInBucket = idx - bucketIdx * BUCKET_SIZE;
        return decBuckets[lvl][bucketIdx][offsetInBucket];
    }

    // 2) Append to queue, reusing slots. Updates coinflipPlayersCount.
    function _pushPlayer(address p) internal {
        uint256 pos = cfTail;
        if (pos == cfPlayers.length) {
            cfPlayers.push(p);
        } else {
            cfPlayers[pos] = p;
        }
        unchecked {
            cfTail = pos + 1;
            coinflipPlayersCount = uint32(cfTail - cfHead);
        }
    }

    /// @notice Increase a player’s pending coinflip stake and possibly arm a bounty.
    /// @param player           Target player.
    /// @param coinflipDeposit  Amount to add to their current pending flip stake.
    /// @param canArmBounty     If true, a sufficiently large deposit may arm a bounty.
    function addFlip(address player, uint256 coinflipDeposit, bool canArmBounty) internal {
        uint256 prevStake = coinflipAmount[player];
        if (prevStake == 0) _pushPlayer(player);

        uint256 newStake = prevStake + coinflipDeposit;
        coinflipAmount[player] = newStake;
        _updatePlayerScore(2, player, newStake);

        uint256 record = biggestFlipEver;
        if (newStake > record && topBettors[0].player == player) {
            biggestFlipEver = newStake;

            if (canArmBounty) {
                uint256 threshold = (bountyOwedTo != address(0)) ? (record + record / 100) : record;
                if (newStake >= threshold) {
                    bountyOwedTo = player;
                    emit BountyOwed(player, currentBounty, newStake);
                }
            }
        }
    }

    /// @notice Increase the global bounty pool.
    /// @dev Uses unchecked addition; will wrap on overflow.
    /// @param amount Amount of PURGED to add to the bounty pool.
    function _addToBounty(uint256 amount) internal {
        unchecked {
            currentBounty += amount;
        }
    }

    /// @notice Pick the address with the highest luckbox from a candidate list.
    /// @param players Candidate addresses (may include address(0)).
    /// @return best Address with the maximum `playerLuckbox` value among `players` (zero if none).
    function getTopLuckbox(address[] memory players) internal view returns (address best) {
        uint256 top;
        uint256 len = players.length;
        for (uint256 i; i < len; ) {
            address p = players[i];
            if (p != address(0)) {
                uint256 v = playerLuckbox[p];
                if (v > top) {
                    top = v;
                    best = p;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Check whether the Decimator window is active for the current game phase.
    /// @dev Returns `(false, 0)` while purge phase (gameState==4) is active.
    /// @return on  True if level >= 25 and `level % 10 == 5` (Decimator checkpoint).
    /// @return lvl Current game level (0 if purge phase).
    function _decWindow() internal view returns (bool on, uint24 lvl) {
        uint8 s = _gameState();
        if (s == 4) return (false, 0);
        lvl = _gameLevel();
        on = (lvl >= 25 && (lvl % 10) == 5 && (lvl % 100) != 95);
    }

    /// @notice Append a player to the Decimator roster for a given level.
    /// @param lvl Level bucket to push into.
    /// @param p   Player address.
    function _decPush(uint24 lvl, address p) internal {
        uint256 idx = decPlayersCount[lvl];
        decBuckets[lvl][idx / BUCKET_SIZE].push(p);
        unchecked {
            decPlayersCount[lvl] = idx + 1;
        }
    }

    function _tierMultPermille(uint256 subBal) internal pure returns (uint16) {
        if (subBal < 200 ether) return 2000; // +100%
        if (subBal < 300 ether) return 1500; // +50%
        if (subBal < 600 ether) return 1000; //  0%
        if (subBal < 1000 ether) return 500; // -50%
        if (subBal < 2000 ether) return 100; // -90%
        return 0; // ≥2000: no credit
    }

    // Users call: LINK.transferAndCall(address(this), amount, "")
    function onTokenTransfer(address from, uint256 amount, bytes calldata) external {
        if (isBettingPaused) revert BettingPaused();
        if (msg.sender != LINK) revert E();
        if (amount == 0) revert Zero();

        // fund VRF sub
        if (!_linkTransferAndCall(s_vrfCoordinator, amount, abi.encode(vrfSubscriptionId))) {
            revert E();
        }

        // post‑fund subscription LINK balance
        (uint96 bal, , , , ) = _vrfGetSubscription(vrfSubscriptionId);

        uint16 mult = _tierMultPermille(uint256(bal));
        uint256 credit;
        if (mult != 0) {
            uint256 base = (amount * LUCK_PER_LINK) / 1 ether; // amount is 18d LINK
            credit = (base * mult) / 1000;
            uint256 newLuck = playerLuckbox[from] + credit;
            playerLuckbox[from] = newLuck;
            _updatePlayerScore(0, from, newLuck);
        }
    }

    /// @notice Route a player score update to the appropriate leaderboard.
    /// @param lid 0 = luckbox top10, 1 = affiliate top8, else = top bettor top4.
    /// @param p   Player address.
    /// @param s   New score for that board.
    function _updatePlayerScore(uint8 lid, address p, uint256 s) internal {
        if (lid == 0) {
            _updateBoard10(p, s);
        } else if (lid == 1) {
            _updateBoard8(p, s);
        } else {
            _updateBoard4(p, s);
        }
    }
    /// @notice Insert/update `p` with score `s` on the luckbox top‑10 board.
    /// @dev Keeps a 1‑based position map in `luckboxPos`. Returns true if the board changed.
    function _updateBoard10(address p, uint256 s) internal returns (bool) {
        PlayerScore[10] storage board = luckboxLeaderboard;
        uint8 curLen = luckboxLen;
        uint8 prevPos = luckboxPos[p]; // 1..curLen, or 0 if not present
        uint8 idx;

        // Case 1: already on board — bubble up if improved
        if (prevPos != 0) {
            idx = prevPos - 1;
            if (s <= board[idx].score) return false; // no improvement
            for (; idx > 0 && s > board[idx - 1].score; ) {
                board[idx] = board[idx - 1];
                luckboxPos[board[idx].player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore(p, s);
            luckboxPos[p] = idx + 1;
            return true;
        }

        // Case 2: space available — insert and grow
        if (curLen < 10) {
            idx = curLen;
            for (; idx > 0 && s > board[idx - 1].score; ) {
                board[idx] = board[idx - 1];
                luckboxPos[board[idx].player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore(p, s);
            luckboxPos[p] = idx + 1;
            unchecked {
                luckboxLen = curLen + 1;
            }
            return true;
        }

        // Case 3: full — must beat the tail to enter
        if (s <= board[9].score) return false;
        address dropped = board[9].player;
        idx = 9;
        for (; idx > 0 && s > board[idx - 1].score; ) {
            board[idx] = board[idx - 1];
            luckboxPos[board[idx].player] = idx + 1;
            unchecked {
                --idx;
            }
        }
        board[idx] = PlayerScore(p, s);
        luckboxPos[p] = idx + 1;
        if (dropped != address(0)) luckboxPos[dropped] = 0;
        return true;
    }

    /// @notice Insert/update `p` with score `s` on the affiliate top‑8 board.
    /// @dev Keeps a 1‑based position map in `affiliatePos`. Returns true if the board changed.
    function _updateBoard8(address p, uint256 s) internal returns (bool) {
        PlayerScore[8] storage board = affiliateLeaderboard;
        uint8 curLen = affiliateLen;
        uint8 prevPos = affiliatePos[p];
        uint8 idx;

        if (prevPos != 0) {
            idx = prevPos - 1;
            if (s <= board[idx].score) return false;
            for (; idx > 0 && s > board[idx - 1].score; ) {
                board[idx] = board[idx - 1];
                affiliatePos[board[idx].player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore(p, s);
            affiliatePos[p] = idx + 1;
            return true;
        }

        if (curLen < 8) {
            idx = curLen;
            for (; idx > 0 && s > board[idx - 1].score; ) {
                board[idx] = board[idx - 1];
                affiliatePos[board[idx].player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore(p, s);
            affiliatePos[p] = idx + 1;
            unchecked {
                affiliateLen = curLen + 1;
            }
            return true;
        }

        if (s <= board[7].score) return false;
        address dropped = board[7].player;
        idx = 7;
        for (; idx > 0 && s > board[idx - 1].score; ) {
            board[idx] = board[idx - 1];
            affiliatePos[board[idx].player] = idx + 1;
            unchecked {
                --idx;
            }
        }
        board[idx] = PlayerScore(p, s);
        affiliatePos[p] = idx + 1;
        if (dropped != address(0)) affiliatePos[dropped] = 0;
        return true;
    }

    /// @notice Insert/update `p` with score `s` on the top‑bettors top‑4 board.
    /// @dev Keeps a 1‑based position map in `topPos`. Returns true if the board changed.
    function _updateBoard4(address p, uint256 s) internal returns (bool) {
        PlayerScore[4] storage board = topBettors;
        uint8 curLen = topLen;
        uint8 prevPos = topPos[p];
        uint8 idx;

        if (prevPos != 0) {
            idx = prevPos - 1;
            if (s <= board[idx].score) return false;
            for (; idx > 0 && s > board[idx - 1].score; ) {
                board[idx] = board[idx - 1];
                topPos[board[idx].player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore(p, s);
            topPos[p] = idx + 1;
            return true;
        }

        if (curLen < 4) {
            idx = curLen;
            for (; idx > 0 && s > board[idx - 1].score; ) {
                board[idx] = board[idx - 1];
                topPos[board[idx].player] = idx + 1;
                unchecked {
                    --idx;
                }
            }
            board[idx] = PlayerScore(p, s);
            topPos[p] = idx + 1;
            unchecked {
                topLen = curLen + 1;
            }
            return true;
        }

        if (s <= board[3].score) return false;
        address dropped = board[3].player;
        idx = 3;
        for (; idx > 0 && s > board[idx - 1].score; ) {
            board[idx] = board[idx - 1];
            topPos[board[idx].player] = idx + 1;
            unchecked {
                --idx;
            }
        }
        board[idx] = PlayerScore(p, s);
        topPos[p] = idx + 1;
        if (dropped != address(0)) topPos[dropped] = 0;
        return true;
    }
}
