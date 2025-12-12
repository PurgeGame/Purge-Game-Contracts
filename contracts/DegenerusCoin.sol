// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title DegenerusCoin
/// @notice ERC20-style game token (BURNIE) that doubles as accounting for coinflip wagers, quests, and jackpots.
/// @dev Acts as the hub for gameplay modules (game, NFTs, quests, jackpots). Mint/burn only occurs through explicit
///      gameplay flows; there is intentionally no public mint.
import {DegenerusGamepieces} from "./DegenerusGamepieces.sol";
import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";
import {IDegenerusQuestModule, QuestInfo, PlayerQuestView} from "./interfaces/IDegenerusQuestModule.sol";
import {IDegenerusJackpots} from "./interfaces/IDegenerusJackpots.sol";

interface IDegenerusAffiliateCoin {
    function consumePresaleCoin(address player) external returns (uint256 amount);
    function presaleClaimableTotal() external view returns (uint256);
    function addPresaleLinkCredit(address player, uint256 amount) external;
}

contract DegenerusCoin {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    // Lightweight ERC20 events plus gameplay signals used by off-chain indexers/clients.
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event CoinflipDeposit(address indexed player, uint256 creditedFlip);
    event DecimatorBurn(address indexed player, uint256 amountBurned, uint8 bucket);
    event CoinflipFinished(bool result);
    event BountyOwed(address indexed to, uint256 bountyAmount, uint256 newRecordFlip);
    event BountyPaid(address indexed to, uint256 amount);
    event DailyQuestRolled(uint48 indexed day, uint8 questType, bool highDifficulty);
    event QuestCompleted(address indexed player, uint8 questType, uint32 streak, uint256 reward, bool hardMode);
    event LinkCredit(address indexed player, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    // Short, custom errors to save gas and keep branch intent explicit.
    error OnlyGame();
    error OnlyVault();
    error Insufficient();
    error AmountLTMin();
    error ZeroAddress();
    error NotDecimatorWindow();
    error OnlyBonds();
    error OnlyAdmin();
    error OnlyAffiliate();
    error AlreadyWired();
    error OnlyNft();

    // ---------------------------------------------------------------------
    // ERC20 state
    // ---------------------------------------------------------------------
    // Minimal ERC20 metadata/state; transfers are unchecked beyond underflow protection in Solidity 0.8.
    string public constant name = "Burnies";
    string public constant symbol = "BURNIE";
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ---------------------------------------------------------------------
    // Types used in storage
    // ---------------------------------------------------------------------
    // Leaderboard entry; score is stored in whole coins to fit in uint96.
    struct PlayerScore {
        address player;
        uint96 score;
    }

    // Outcome for a single coinflip day. rewardPercent is basis points / 100 (e.g., 150 => 1.5x principal).
    struct CoinflipDayResult {
        uint16 rewardPercent;
        bool win;
    }

    // ---------------------------------------------------------------------
    // Game wiring & session state
    // ---------------------------------------------------------------------
    // Core modules; set once via `wire`.
    IDegenerusGame internal degenerusGame;
    DegenerusGamepieces internal degenerusGamepieces;
    IDegenerusQuestModule internal questModule;
    IDegenerusAffiliateCoin private immutable affiliateProgram;
    address private jackpots;
    address private vault;
    address private immutable admin;

    // Coinflip accounting keyed by day window (auto daily flips).
    mapping(uint48 => mapping(address => uint256)) internal coinflipBalance;
    mapping(uint48 => CoinflipDayResult) internal coinflipDayResult;
    mapping(address => uint48) internal lastCoinflipClaim;
    uint48 internal flipsClaimableDay; // Last day that has been opened for claims (active day = flipsClaimableDay)
    bool private presaleEscrowInitialized; // packed with flipsClaimableDay to save a slot

    // Vault escrow: tracks coin reserved for the vault; minted only when vault pays out.
    // Virtual supply the vault is authorized to mint (not yet circulated). Seeded to 2m BURNIE.
    uint256 private vaultMintAllowance = 2_000_000 * 1e6;

    // Track whether the top-flip bonus has been paid for a given level (once per level).
    mapping(uint24 => bool) internal topFlipRewardPaid;

    // Live per-level leaderboard for biggest pending flip.
    mapping(uint24 => PlayerScore) internal coinflipTopByLevel;

    /// @notice View-only helper to estimate claimable coin (flips only; staking removed) for the caller.
    function claimableCoin() external view returns (uint256) {
        address player = msg.sender;
        return _viewClaimableCoin(player);
    }

    /// @notice Total supply including uncirculated vault allowance.
    function supplyIncUncirculated() external view returns (uint256) {
        return totalSupply + vaultMintAllowance;
    }
    // Tracks total unclaimed presale allocation across all sources; minted on claim.
    uint256 public presaleClaimableRemaining;

    // Bounty state; bounty is credited as future coinflip stake for the owed player.
    uint128 public currentBounty = 1_000_000_000;
    uint128 public biggestFlipEver = 1_000_000_000;
    address internal bountyOwedTo;
    address private immutable bonds;

    // ---------------------------------------------------------------------
    // ERC20 state
    // ---------------------------------------------------------------------
    uint8 public constant decimals = 6;

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
        if (msg.sender != address(degenerusGame)) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed != type(uint256).max) {
                uint256 newAllowance = allowed - amount;
                allowance[from][msg.sender] = newAllowance;
                emit Approval(from, msg.sender, newAllowance);
            }
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

    // ---------------------------------------------------------------------
    // Constants (units & limits)
    // ---------------------------------------------------------------------
    uint256 private constant MILLION = 1e6; // token has 6 decimals
    uint256 private constant MIN = 100 * MILLION; // min burn / min flip (100 BURNIE)
    uint16 private constant COINFLIP_EXTRA_MIN_PERCENT = 78; // base % on non-extreme flips
    uint16 private constant COINFLIP_EXTRA_RANGE = 38; // roll range (add to min) => [78..115]
    uint16 private constant BPS_DENOMINATOR = 10_000; // basis point math helper
    uint24 private constant DECIMATOR_SPECIAL_LEVEL = 100; // special bucket rules every 100 levels
    uint48 private constant JACKPOT_RESET_TIME = 82620; // anchor timestamp for day indexing
    uint8 private constant COIN_CLAIM_DAYS = 30; // claim window for flips

    // ---------------------------------------------------------------------
    // Immutables / external wiring
    // ---------------------------------------------------------------------
    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------
    modifier onlyDegenerusGameContract() {
        if (msg.sender != address(degenerusGame)) revert OnlyGame();
        _;
    }

    modifier onlyTrustedContracts() {
        address sender = msg.sender;
        if (
            sender != address(degenerusGame) &&
            sender != address(degenerusGamepieces) &&
            sender != address(affiliateProgram)
        ) revert OnlyGame();
        _;
    }

    modifier onlyFlipCreditors() {
        address sender = msg.sender;
        if (
            sender != address(degenerusGame) &&
            sender != address(degenerusGamepieces) &&
            sender != address(affiliateProgram) &&
            sender != bonds
        ) revert OnlyGame();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------
    constructor(address bonds_, address admin_, address affiliate_, address vault_) {
        if (bonds_ == address(0) || admin_ == address(0) || affiliate_ == address(0)) revert ZeroAddress();
        bonds = bonds_;
        admin = admin_;
        affiliateProgram = IDegenerusAffiliateCoin(affiliate_);
        vault = vault_;
    }

    /// @notice Burn BURNIE to increase the caller’s coinflip stake, applying streak bonuses when eligible.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum, or zero to just cash out.
    function depositCoinflip(uint256 amount) external {
        // Allow zero-amount calls to act as a cash-out of pending winnings without adding a new stake.
        if (amount == 0) {
            addFlip(msg.sender, 0, false, false);
            emit CoinflipDeposit(msg.sender, 0);
            return;
        }
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;

        // Burn first so reentrancy into downstream module calls cannot spend the same balance twice.
        _burn(caller, amount);

        // Quests can layer on bonus flip credit when the quest is active/completed.
        IDegenerusQuestModule module = questModule;
        uint256 questReward;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleFlip(
            caller,
            amount
        );
        questReward = _questApplyReward(caller, reward, hardMode, questType, streak, completed);

        // Principal + quest bonus become the pending flip stake.
        uint256 creditedFlip = amount + questReward;
        addFlip(caller, creditedFlip, true, true);

        emit CoinflipDeposit(caller, amount);
    }

    /// @notice Claim presale/early affiliate bonuses that were deferred to the affiliate contract.
    function claimPresale() external {
        uint256 amount = affiliateProgram.consumePresaleCoin(msg.sender);
        if (amount == 0) return;
        if (amount > presaleClaimableRemaining) revert Insufficient();
        presaleClaimableRemaining -= amount;
        _mint(msg.sender, amount);
    }

    /// @notice Burn BURNIE during an active Decimator window to accrue weighted participation.
    /// @param amount Amount (6 decimals) to burn; must satisfy the global minimum.
    function decimatorBurn(uint256 amount) external {
        (bool decOn, uint24 lvl) = degenerusGame.decWindow();
        if (!decOn) revert NotDecimatorWindow();
        if (amount < MIN) revert AmountLTMin();

        address moduleAddr = jackpots;
        if (moduleAddr == address(0)) revert ZeroAddress();

        address caller = msg.sender;
        // Burn first to anchor the amount used for bonuses.
        _burn(caller, amount);

        IDegenerusQuestModule module = questModule;
        uint256 effectiveAmount = amount;

        // Quest module can also grant extra dec burn weight; fold into the base record to save gas.
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak2, bool completed) = module.handleDecimator(
            caller,
            amount
        );
        uint256 questReward = _questApplyReward(caller, reward, hardMode, questType, streak2, completed);
        if (questReward != 0) {
            effectiveAmount += questReward;
        }

        // Trophies can boost the effective contribution.
        // Bucket logic selects how many people share a jackpot slice; special every DECIMATOR_SPECIAL_LEVEL.
        bool specialDec = (lvl % DECIMATOR_SPECIAL_LEVEL) == 0;
        uint8 bucket = specialDec
            ? _decBucketDenominatorFromLevels(degenerusGame.ethMintLevelCount(caller))
            : _decBucketDenominator(degenerusGame.ethMintStreakCount(caller));
        uint8 bucketUsed = IDegenerusJackpots(moduleAddr).recordDecBurn(caller, lvl, bucket, effectiveAmount);

        (uint32 streak, , , ) = module.playerQuestStates(caller);
        if (streak != 0) {
            // Quest streak: bonus contribution capped at 25%.
            uint256 bonusBps = uint256(streak) * 25; // (streak/4)%
            if (bonusBps > 2500) bonusBps = 2500; // cap at 25%
            uint256 streakBonus = (effectiveAmount * bonusBps) / BPS_DENOMINATOR;
            IDegenerusJackpots(moduleAddr).recordDecBurn(caller, lvl, bucketUsed, streakBonus);
        }

        emit DecimatorBurn(caller, amount, bucketUsed);
    }

    function _viewClaimableCoin(address player) internal view returns (uint256 total) {
        // Pending flip winnings since last claim (up to 30 days); staking removed.
        uint48 latestDay = flipsClaimableDay;
        uint48 startDay = lastCoinflipClaim[player];
        if (startDay >= latestDay) return 0;

        uint8 remaining = COIN_CLAIM_DAYS;
        uint48 cursor = startDay + 1;
        while (remaining != 0 && cursor <= latestDay) {
            CoinflipDayResult storage result = coinflipDayResult[cursor];
            if (result.rewardPercent == 0 && !result.win) break;

            uint256 flipStake = coinflipBalance[cursor][player];
            if (flipStake != 0 && result.win) {
                uint256 payout = flipStake + (flipStake * uint256(result.rewardPercent) * 100) / BPS_DENOMINATOR;
                total += payout;
            }
            unchecked {
                ++cursor;
                --remaining;
            }
        }
    }

    /// @notice Wire game, NFT, quest module, jackpots using an address array.
    /// @dev Order: [game, nft, quest module, jackpots]; set-once per slot. Downstream modules are
    ///      wired directly by the admin rather than being cascaded here.
    function wire(address[] calldata addresses) external {
        address adminAddr = admin;
        if (msg.sender != adminAddr) revert OnlyAdmin();

        uint256 len = addresses.length;
        if (len > 0) _setGame(addresses[0]);
        if (len > 1) _setNft(addresses[1]);
        if (len > 2) _setQuestModule(addresses[2]);
        if (len > 3) _setJackpots(addresses[3]);
    }

    function _setGame(address game_) private {
        if (game_ == address(0)) return;
        address current = address(degenerusGame);
        if (current == address(0)) {
            degenerusGame = IDegenerusGame(game_);
        } else if (game_ != current) {
            revert AlreadyWired();
        }
    }

    function _setNft(address nft_) private {
        if (nft_ == address(0)) return;
        address current = address(degenerusGamepieces);
        if (current == address(0)) {
            degenerusGamepieces = DegenerusGamepieces(nft_);
        } else if (nft_ != current) {
            revert AlreadyWired();
        }
    }

    function _setQuestModule(address questModule_) private {
        if (questModule_ == address(0)) return;
        address current = address(questModule);
        if (current == address(0)) {
            questModule = IDegenerusQuestModule(questModule_);
        } else if (questModule_ != current) {
            revert AlreadyWired();
        }
    }

    function _setJackpots(address jackpots_) private {
        if (jackpots_ == address(0)) return;
        address current = jackpots;
        if (current == address(0)) {
            jackpots = jackpots_;
        } else if (jackpots_ != current) {
            revert AlreadyWired();
        }
    }

    /// @notice One-time presale mint from the affiliate contract; callable only by affiliate.
    function affiliatePrimePresale() external {
        if (msg.sender != address(affiliateProgram)) revert OnlyAffiliate();
        if (presaleEscrowInitialized) revert AlreadyWired();
        presaleEscrowInitialized = true;
        uint256 presaleTotal = affiliateProgram.presaleClaimableTotal();
        if (presaleTotal == 0) return;
        // Record escrow only; tokens are minted lazily on claim.
        presaleClaimableRemaining += presaleTotal;
    }

    /// @notice Escrow virtual coin to the vault (no token movement); increases mint allowance.
    /// @dev Access: vault, bonds, or game when routing coin share without touching the vault.
    function vaultEscrow(uint256 amount) external {
        if (amount == 0) return;
        address sender = msg.sender;
        if (sender != vault && sender != bonds && sender != address(degenerusGame)) revert OnlyVault();
        vaultMintAllowance += amount;
    }

    /// @notice Mint coin out of the vault allowance to a recipient (only the vault can call).
    function vaultMintTo(address to, uint256 amount) external onlyVault {
        if (amount == 0) return;
        uint256 allowanceVault = vaultMintAllowance;
        if (amount > allowanceVault) revert Insufficient();
        vaultMintAllowance = allowanceVault - amount;
        _mint(to, amount);
    }

    /// @notice Credit a coinflip stake from authorized contracts (game, NFT, affiliate, bonds).
    /// @dev Zero address is ignored.
    function creditFlip(address player, uint256 amount) external onlyFlipCreditors {
        if (player == address(0) || amount == 0) return;
        addFlip(player, amount, false, false);
    }

    /// @notice Credit LINK-funded bonus directly (admin-triggered, not presale).
    function creditLinkReward(address player, uint256 amount) external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (player == address(0) || amount == 0) return;
        _mint(player, amount);
        emit LinkCredit(player, amount);
    }

    /// @notice Batch credit up to three flip stakes in a single call.
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external onlyFlipCreditors {
        for (uint256 i; i < 3; ) {
            address player = players[i];
            uint256 amount = amounts[i];
            if (player != address(0) && amount != 0) {
                addFlip(player, amount, false, false);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Compute affiliate quest rewards while preserving quest module access control.
    /// @dev Access: affiliate contract only.
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256 questReward) {
        if (msg.sender != address(affiliateProgram)) revert OnlyAffiliate();
        IDegenerusQuestModule module = questModule;
        if (address(module) == address(0) || player == address(0) || amount == 0) return 0;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleAffiliate(
            player,
            amount
        );
        return _questApplyReward(player, reward, hardMode, questType, streak, completed);
    }

    // ---------------------------------------------------------------------
    // Daily quest wiring (delegated to quest module)
    // ---------------------------------------------------------------------

    function rollDailyQuest(uint48 day, uint256 entropy) external onlyDegenerusGameContract {
        IDegenerusQuestModule module = questModule;
        (bool rolled, , ) = module.rollDailyQuest(day, entropy);
        if (rolled) {
            QuestInfo[2] memory quests = module.getActiveQuests();
            for (uint256 i; i < 2; ) {
                QuestInfo memory info = quests[i];
                if (info.day == day) {
                    emit DailyQuestRolled(day, info.questType, info.highDifficulty);
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    function rollDailyQuestWithOverrides(
        uint48 day,
        uint256 entropy,
        bool forceMintEth,
        bool forceBurn
    ) external onlyDegenerusGameContract {
        IDegenerusQuestModule module = questModule;
        (bool rolled, , ) = module.rollDailyQuestWithOverrides(day, entropy, forceMintEth, forceBurn);
        if (rolled) {
            QuestInfo[2] memory quests = module.getActiveQuests();
            for (uint256 i; i < 2; ) {
                QuestInfo memory info = quests[i];
                if (info.day == day) {
                    emit DailyQuestRolled(day, info.questType, info.highDifficulty);
                    break;
                }
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Normalize burn quests mid-day when extermination ends the burn window.
    function normalizeActiveBurnQuests() external onlyDegenerusGameContract {
        IDegenerusQuestModule module = questModule;
        if (address(module) == address(0)) return;
        module.normalizeActiveBurnQuests();
    }

    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external {
        if (msg.sender != address(degenerusGamepieces)) revert OnlyNft();
        IDegenerusQuestModule module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleMint(
            player,
            quantity,
            paidWithEth
        );
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed);
        if (questReward != 0) {
            addFlip(player, questReward, false, false);
        }
    }

    function notifyQuestBond(address player, uint256 basePerBondWei) external {
        if (msg.sender != bonds) revert OnlyBonds();
        IDegenerusQuestModule module = questModule;
        if (address(module) == address(0) || player == address(0) || basePerBondWei == 0) return;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleBondPurchase(
            player,
            basePerBondWei
        );
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed);
        if (questReward != 0) {
            addFlip(player, questReward, false, false);
        }
    }

    function notifyQuestBurn(address player, uint32 quantity) external {
        if (msg.sender != address(degenerusGame)) revert OnlyGame();
        IDegenerusQuestModule module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed) = module.handleBurn(
            player,
            quantity
        );
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed);
        if (questReward != 0) {
            addFlip(player, questReward, false, false);
        }
    }

    function getActiveQuests() external view returns (QuestInfo[2] memory quests) {
        IDegenerusQuestModule module = questModule;
        return module.getActiveQuests();
    }

    function playerQuestStates(
        address player
    )
        external
        view
        returns (uint32 streak, uint32 lastCompletedDay, uint128[2] memory progress, bool[2] memory completed)
    {
        IDegenerusQuestModule module = questModule;
        return module.playerQuestStates(player);
    }

    function getPlayerQuestView(address player) external view returns (PlayerQuestView memory viewData) {
        IDegenerusQuestModule module = questModule;
        return module.getPlayerQuestView(player);
    }

    /// @notice Burn BURNIE from `target` during gameplay/affiliate flows (purchases, fees, synthetic caps).
    /// @dev Access: DegenerusGame, NFT, or affiliate. OZ ERC20 `_burn` reverts on zero address or insufficient balance.
    function burnCoin(address target, uint256 amount) external onlyTrustedContracts {
        _burn(target, amount);
    }

    function coinflipAmount(address player) external view returns (uint256) {
        uint48 day = _targetFlipDay();
        return coinflipBalance[day][player];
    }

    function _claimCoinflipsInternal(address player) internal returns (uint256 claimed) {
        uint48 latest = flipsClaimableDay;
        uint48 start = lastCoinflipClaim[player];
        if (start >= latest) return 0;

        uint48 cursor;
        unchecked {
            cursor = start + 1;
        }
        uint48 processed;

        uint8 remaining = COIN_CLAIM_DAYS;

        while (remaining != 0 && cursor <= latest) {
            CoinflipDayResult storage result = coinflipDayResult[cursor];

            if (result.rewardPercent == 0 && !result.win) {
                break; // day not settled yet; keep stake intact
            }

            uint256 flipStake = coinflipBalance[cursor][player];
            if (flipStake != 0) {
                if (result.win) {
                    // Winnings = principal + (principal * rewardPercent%) where rewardPercent already in percent (not bps).
                    uint256 payout = flipStake + (flipStake * uint256(result.rewardPercent) * 100) / BPS_DENOMINATOR;
                    claimed += payout;
                }
                coinflipBalance[cursor][player] = 0;
            }

            processed = cursor;
            unchecked {
                ++cursor;
                --remaining;
            }
        }

        if (processed != 0 && processed != lastCoinflipClaim[player]) {
            lastCoinflipClaim[player] = processed;
        }
    }

    function _targetFlipDay() internal view returns (uint48) {
        // Day 0 starts after JACKPOT_RESET_TIME, then increments every 24h; target is always the next day.
        return uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days) + 1;
    }

    /// @notice Progress coinflip payouts for the current level in bounded slices.
    /// @dev Called by DegenerusGame; runs in three phases per settlement:
    ///      1. Record the flip resolution day for the level being processed.
    ///      2. Arm bounties on the first payout window.
    ///      3. Perform cleanup and reopen betting (flip claims happen lazily per player).
    /// @param level Current DegenerusGame level (used to gate 1/run and propagate flip stakes).
    /// @param bonusFlip Adds 6 percentage points to the payout roll for the last flip of the purchase phase.
    /// @return finished True when all payouts and cleanup are complete.
    function processCoinflipPayouts(
        uint24 level,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch,
        uint256 priceCoinUnit
    ) external onlyDegenerusGameContract returns (bool finished) {
        uint256 seedWord = rngWord;
        seedWord = uint256(keccak256(abi.encodePacked(rngWord, epoch)));

        uint256 roll = seedWord % 20; // ~5% each for the low/high outliers
        uint16 rewardPercent;
        if (roll == 0) {
            rewardPercent = 50;
        } else if (roll == 1) {
            rewardPercent = 150;
        } else {
            rewardPercent = uint16((seedWord % COINFLIP_EXTRA_RANGE) + COINFLIP_EXTRA_MIN_PERCENT);
        }
        if (bonusFlip) {
            unchecked {
                rewardPercent += 7;
            }
        }

        // Least-significant bit decides win/loss for the window.
        bool win = (rngWord & 1) == 1;

        CoinflipDayResult storage dayResult = coinflipDayResult[epoch];
        dayResult.rewardPercent = rewardPercent;
        dayResult.win = win;

        // Bounty: convert any owed bounty into a flip credit once per window.
        if (bountyOwedTo != address(0) && currentBounty > 0) {
            address to = bountyOwedTo;
            uint256 slice = currentBounty >> 1; // pay/delete half of the bounty pool
            unchecked {
                currentBounty -= uint128(slice);
            }
            if (win) {
                addFlip(to, slice, false, false);
                emit BountyPaid(to, slice);
            }

            bountyOwedTo = address(0);
        }

        // Move the active window forward; the resolved day becomes claimable.
        flipsClaimableDay = epoch == 0 ? 0 : epoch - 1;

        unchecked {
            // Gas-optimized: wraps on overflow, which would effectively reset the bounty.
            currentBounty += uint128(priceCoinUnit);
        }
        if (!topFlipRewardPaid[level]) {
            PlayerScore memory entry = coinflipTopByLevel[level];
            if (entry.player != address(0)) {
                // Credit lands as future flip stake; no direct mint.
                addFlip(entry.player, priceCoinUnit, false, false);
                topFlipRewardPaid[level] = true;
            }
        }

        emit CoinflipFinished(win);
        return true;
    }

    /// @notice Return the top coinflip bettor recorded for a given level.
    /// @dev Reads the level-keyed leaderboard entry.
    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score) {
        PlayerScore memory stored = coinflipTopByLevel[lvl];
        return (stored.player, stored.score);
    }

    /// @notice Increase a player's pending coinflip stake and possibly arm a bounty.
    /// @param player               Target player.
    /// @param coinflipDeposit      Amount to add to their current pending flip stake.
    /// @param canArmBounty         If true, a sufficiently large deposit may arm a bounty.
    /// @param bountyEligible       If true, this deposit can arm the bounty (entire amount is considered).
    function addFlip(address player, uint256 coinflipDeposit, bool canArmBounty, bool bountyEligible) internal {
        // Auto-claim older flip winnings (without mint) so deposits net against pending payouts.
        uint256 totalClaimed = _claimCoinflipsInternal(player);
        uint256 mintRemainder;

        if (coinflipDeposit > totalClaimed) {
            // Recycling: small bonus for rolling winnings forward.
            uint256 recycled = coinflipDeposit - totalClaimed;
            uint256 bonus = recycled / 100;
            uint256 bonusCap = 500 * MILLION;
            if (bonus > bonusCap) bonus = bonusCap;
            coinflipDeposit += bonus;
        } else if (totalClaimed > coinflipDeposit) {
            // If claims exceed the new deposit, mint the difference to the player immediately.
            mintRemainder = totalClaimed - coinflipDeposit;
        }
        if (mintRemainder != 0) {
            _mint(player, mintRemainder);
        }

        // Determine which future day this stake applies to (always the next window).
        bool rngLocked = degenerusGame.rngLocked();
        uint48 targetDay = _targetFlipDay();
        uint24 currLevel = degenerusGame.level();

        uint256 prevStake = coinflipBalance[targetDay][player];

        uint256 newStake = prevStake + coinflipDeposit;
        uint256 eligibleStake = bountyEligible ? newStake : prevStake;

        coinflipBalance[targetDay][player] = newStake;

        // When BAF is active, capture a persistent roster entry + index for scatter.
        if (degenerusGame.isBafLevelActive(currLevel)) {
            uint24 bafLvl = currLevel;
            address module = jackpots;
            if (module == address(0)) revert ZeroAddress();
            IDegenerusJackpots(module).recordBafFlip(player, bafLvl, coinflipDeposit);
        }

        // Allow leaderboard churn even while RNG is locked; only freeze global records to avoid post-RNG manipulation.
        _updateTopBettor(player, newStake, currLevel);

        if (!rngLocked) {
            uint256 record = biggestFlipEver;
            if (newStake > record) {
                biggestFlipEver = uint128(newStake);

                if (canArmBounty && bountyEligible) {
                    // Bounty arms when the same player sets a new record with an eligible stake.
                    uint256 threshold = (bountyOwedTo != address(0)) ? (record + record / 100) : record;
                    if (eligibleStake >= threshold) {
                        bountyOwedTo = player;
                        emit BountyOwed(player, currentBounty, newStake);
                    }
                }
            }
        }
    }

    function _questApplyReward(
        address player,
        uint256 reward,
        bool hardMode,
        uint8 questType,
        uint32 streak,
        bool completed
    ) private returns (uint256) {
        if (!completed) return 0;
        // Event captures quest progress for indexers/UI; raw reward is returned to the caller.
        emit QuestCompleted(player, questType, streak, reward, hardMode);
        return reward;
    }

    function _decBucketDenominator(uint256 streak) internal pure returns (uint8) {
        if (streak <= 5) {
            return uint8(15 - streak);
        }

        if (streak <= 15) {
            uint256 denom = 9 - ((streak - 6) / 2);
            if (denom < 4) denom = 4;
            return uint8(denom);
        }

        if (streak < 25) {
            return 5;
        }

        return 4;
    }

    function _decBucketDenominatorFromLevels(uint256 levels) internal pure returns (uint8) {
        if (levels >= 100) return 2;
        if (levels >= 90) return 3;
        if (levels >= 80) return 4;

        uint256 reductions = levels / 5;
        uint256 denom = 20;
        if (reductions >= 20) {
            denom = 2;
        } else {
            denom -= reductions;
            if (denom < 4) denom = 4; // should only hit for >=80 but guard anyway
        }
        return uint8(denom);
    }

    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / MILLION;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    function _updateTopBettor(address player, uint256 stakeScore, uint24 lvl) private {
        uint96 score = _score96(stakeScore);
        PlayerScore memory levelLeader = coinflipTopByLevel[lvl];
        if (score > levelLeader.score || levelLeader.player == address(0)) {
            coinflipTopByLevel[lvl] = PlayerScore({player: player, score: score});
        }
    }
}
