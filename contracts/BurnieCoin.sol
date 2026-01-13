// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title BurnieCoin
 * @author Burnie Degenerus
 * @notice ERC20 in-game token (BURNIE, 18 decimals) with integrated coinflip wagering and quest rewards.
 *
 * @dev ARCHITECTURE:
 *      - ERC20 standard with game contract transfer bypass
 *      - Coinflip: Daily stake windows with VRF-based 50/50 outcomes, 50-150% bonus on wins
 *      - Quest integration: Bonus flip credits for gameplay actions (mint/burn)
 *      - Decimator burns: Burn-to-participate for decimator jackpot eligibility
 *      - Bounty: 1000 BURNIE/window accumulator; half removed each window (paid on win)
 *      - Vault escrow: 2M BURNIE virtual reserve, minted only on ContractAddresses.VAULT withdrawal
 *
 * @dev CRITICAL INVARIANTS:
 *      - totalSupply + _vaultMintAllowance = supplyIncUncirculated
 *      - coinflipBalance[day][player] immutable after settlement (day <= flipsClaimableDay)
 *      - Only one bountyOwedTo address at a time
 *
 * @dev SECURITY:
 *      - Access control: onlyDegenerusGameContract, onlyFlipCreditors, onlyVault
 *      - CEI pattern: burns before external calls
 *      - RNG lock prevents stake manipulation during VRF callback
 *      - MIN threshold (100 BURNIE) prevents dust spam
 *      - 30-day auto-expiry on unclaimed coinflips
 */

import {IDegenerusGame} from "./interfaces/IDegenerusGame.sol";
import {IDegenerusQuests} from "./interfaces/IDegenerusQuests.sol";
import {IDegenerusJackpots} from "./interfaces/IDegenerusJackpots.sol";
import {ContractAddresses} from "./ContractAddresses.sol";

contract BurnieCoin {
    /*+======================================================================+
      |                              EVENTS                                  |
      +======================================================================+
      |  Lightweight ERC20 events plus gameplay signals for off-chain        |
      |  indexers/clients. Events are the primary mechanism for UIs to       |
      |  track coinflip results, quest completions, and bounty state.        |
      +======================================================================+*/

    /// @notice Standard ERC20 transfer event.
    /// @dev Emitted on transfer, mint (from=0), and burn (to=0).
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice Standard ERC20 approval event.
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /// @notice Emitted when a player deposits BURNIE into the coinflip pool.
    /// @param player The depositor's address.
    /// @param creditedFlip The raw amount deposited (excludes quest bonuses credited separately).
    event CoinflipDeposit(address indexed player, uint256 creditedFlip);

    /// @notice Emitted when a player burns BURNIE during a decimator window.
    /// @param player The burner's address.
    /// @param amountBurned The amount burned (18 decimals).
    /// @param bucket The effective bucket weight assigned (lower = more valuable).
    event DecimatorBurn(address indexed player, uint256 amountBurned, uint8 bucket);

    /// @notice Emitted when a coinflip day window is resolved.
    /// @param result True if the coinflip was a win, false if loss.
    event CoinflipFinished(bool result);

    /// @notice Emitted when a player arms the bounty by setting a new biggest-flip-ever record.
    /// @param to The player who now owns the bounty payout right.
    /// @param bountyAmount The current bounty pool size at time of arming.
    /// @param newRecordFlip The new all-time high flip amount.
    event BountyOwed(address indexed to, uint256 bountyAmount, uint256 newRecordFlip);

    /// @notice Emitted when the bounty is paid out on a winning coinflip.
    /// @param to The recipient of the bounty.
    /// @param amount The amount paid (half of pool).
    event BountyPaid(address indexed to, uint256 amount);

    /// @notice Emitted when the daily quest is rolled for a new day.
    /// @param day The day index (0-indexed from deployTime anchor).
    /// @param questType The type of quest rolled (see IDegenerusQuests).
    /// @param highDifficulty Whether hard mode is active for this quest.
    event DailyQuestRolled(uint48 indexed day, uint8 questType, bool highDifficulty);

    /// @notice Emitted when a player completes a quest.
    /// @param player The player who completed the quest.
    /// @param questType The type of quest completed.
    /// @param streak The player's current completion streak.
    /// @param reward The reward amount credited (as flip stake).
    /// @param hardMode Whether the quest was completed in hard mode.
    event QuestCompleted(
        address indexed player,
        uint8 questType,
        uint32 streak,
        uint256 reward,
        bool hardMode,
        bool completedBoth
    );

    /// @notice Emitted when ContractAddresses.ADMIN credits LINK-funded bonus directly.
    /// @param player The recipient of the credit.
    /// @param amount The amount minted (18 decimals).
    event LinkCredit(address indexed player, uint256 amount);

    /// @notice Emitted when virtual coin is escrowed to the vault reserve.
    /// @param sender The contract that escrowed the funds (VAULT or GAME).
    /// @param amount The amount added to vault mint allowance (18 decimals).
    event VaultEscrowRecorded(address indexed sender, uint256 amount);

    /*+======================================================================+
      |                              ERRORS                                  |
      +======================================================================+
      |  Custom errors for gas-efficient reverts. Each error corresponds     |
      |  to a specific access control or validation failure.                 |
      +======================================================================+*/

    /// @notice Caller is not the authorized DegenerusGame contract.
    error OnlyGame();

    /// @notice Caller is not the authorized ContractAddresses.VAULT contract.
    error OnlyVault();

    /// @notice Requested amount exceeds available balance or allowance.
    error Insufficient();

    /// @notice Deposit/burn amount is below the minimum threshold (100 BURNIE).
    error AmountLTMin();

    /// @notice Zero address not allowed for transfers, mints, or wiring.
    error ZeroAddress();

    /// @notice Decimator burn attempted outside an active decimator window.
    error NotDecimatorWindow();


    /// @notice Caller is not the ContractAddresses.ADMIN address.
    error OnlyAdmin();

    /// @notice Caller is not the authorized affiliate contract.
    error OnlyAffiliate();

    /// @notice Caller is not the authorized gamepiece (gamepieces) contract.
    error OnlyNft();

    /// @notice Coinflip deposits are locked during level jackpot resolution.
    error CoinflipLocked();

    /// @notice Caller is not authorized (trusted contracts: GAME, GAMEPIECES, AFFILIATE, ICON_COLOR_REGISTRY).
    error OnlyTrustedContracts();

    /// @notice Caller is not authorized (flip creditors: GAME, GAMEPIECES, AFFILIATE).
    error OnlyFlipCreditors();

    /// @notice Caller is not authorized (vault operations: VAULT or GAME).
    error OnlyVaultOrGame();

    /*+======================================================================+
      |                         ERC20 STATE                                  |
      +======================================================================+
      |  Minimal ERC20 metadata/state. Transfers are protected by Solidity   |
      |  0.8+ overflow checks. No SafeMath needed.                           |
      |                                                                      |
      |  STORAGE LAYOUT:                                                     |
      |  +-----------------------------------------------------------------+ |
      |  | Slot | Variable                    | Type                       | |
      |  +------+-----------------------------+----------------------------+ |
      |  |  0   | totalSupply                 | uint256                    | |
      |  |  1   | balanceOf                   | mapping(address => uint256)| |
      |  |  2   | allowance                   | mapping(addr => mapping)   | |
      |  +-----------------------------------------------------------------+ |
      +======================================================================+*/

    /// @notice Token name displayed in wallets and explorers.
    string public constant name = "Burnies";

    /// @notice Token symbol (ticker).
    string public constant symbol = "BURNIE";

    /// @notice Total circulating supply (excludes ContractAddresses.VAULT's virtual allowance).
    /// @dev Increases on mint, decreases on burn. Always equals sum of all balanceOf entries.
    uint256 public totalSupply;

    /// @notice Token balance for each address.
    /// @dev Standard ERC20 balance mapping.
    mapping(address => uint256) public balanceOf;

    /// @notice Spending allowances: owner => spender => amount.
    /// @dev type(uint256).max indicates infinite approval.
    mapping(address => mapping(address => uint256)) public allowance;

    /*+======================================================================+
      |                         DATA TYPES                                   |
      +======================================================================+
      |  Packed structs for gas-efficient storage. Each struct fits within   |
      |  a single 32-byte slot where possible.                               |
      +======================================================================+*/

    /// @notice Leaderboard entry for tracking top flip bettors.
    /// @dev Packed into single slot: address (20 bytes) + uint96 (12 bytes) = 32 bytes.
    ///      Score is stored in whole BURNIE tokens (divided by 1 ether) to fit uint96.
    struct PlayerScore {
        address player; // 20 bytes - the leading player's address
        uint96 score; // 12 bytes - score in whole tokens (max ~7.9e28)
    }

    /// @notice Outcome record for a single coinflip day window.
    /// @dev Packed into single slot: uint16 (2 bytes) + bool (1 byte) = 3 bytes.
    ///      rewardPercent is already in percent units (not basis points), e.g., 150 = 150% = 1.5x.
    struct CoinflipDayResult {
        uint16 rewardPercent; // 2 bytes - payout multiplier percentage [50-150]
        bool win; // 1 byte  - true = players won, false = house won
    }

    /*+======================================================================+
      |                    WIRED CONTRACTS & MODULE STATE                    |
      +======================================================================+
      |  All external dependencies are compile-time constants sourced from  |
      |  ContractAddresses. No storage slots are consumed for wiring, and    |
      |  the references cannot be updated post-deploy.                       |
      |                                                                      |
      |  CONSTANT REFERENCES:                                                |
      |  • GAME, QUESTS, JACKPOTS, AFFILIATE                                  |
|  • VAULT, ADMIN, ICON_COLOR_REGISTRY                                  |
      +======================================================================+*/

    /// @notice The main game contract; provides level, RNG state, and purchase info.
    IDegenerusGame internal constant degenerusGame = IDegenerusGame(ContractAddresses.GAME);

    /// @notice The quest module handling daily quests and streak tracking.
    IDegenerusQuests internal constant questModule = IDegenerusQuests(ContractAddresses.QUESTS);

    /// @notice The jackpots module for decimator burns and BAF flip tracking.
    IDegenerusJackpots internal constant jackpots = IDegenerusJackpots(ContractAddresses.JACKPOTS);

    /*+======================================================================+
      |                       COINFLIP ACCOUNTING                            |
      +======================================================================+
      |  Per-day coinflip stakes and results. Stakes are placed for the      |
      |  "next" day and resolved when the day window closes.                 |
      |                                                                      |
      |  CLAIM LIFECYCLE:                                                    |
      |  1. Player deposits → coinflipBalance[targetDay][player] increases   |
      |  2. Day ends → processCoinflipPayouts() records result               |
      |  3. flipsClaimableDay advances → old days become claimable           |
      |  4. On next deposit → _claimCoinflipsInternal() auto-claims wins     |
      |                                                                      |
      |  STORAGE SLOTS:                                                      |
      |  +-----------------------------------------------------------------+ |
      |  | Slot | Variable              | Type                             | |
      |  +------+-----------------------+----------------------------------+ |
      |  |  9   | coinflipBalance       | mapping(day => mapping(addr=>u)) | |
      |  |  10  | coinflipDayResult     | mapping(day => CoinflipDayResult)| |
      |  |  11  | lastCoinflipClaim     | mapping(addr => uint48)          | |
      |  |  12  | flipsClaimableDay     | uint48 (packed with other?)      | |
      |  +-----------------------------------------------------------------+ |
      +======================================================================+*/

    /// @notice Per-day, per-player coinflip stake amounts.
    /// @dev Key: day index (day 1 = deploy day, resets at JACKPOT_RESET_TIME) => player => stake.
    ///      Cleared on claim. Cannot be modified once day <= flipsClaimableDay.
    mapping(uint48 => mapping(address => uint256)) internal coinflipBalance;

    /// @notice Resolved outcome for each coinflip day window.
    /// @dev Key: day index. Value: (rewardPercent, win). Set once by processCoinflipPayouts().
    mapping(uint48 => CoinflipDayResult) internal coinflipDayResult;

    /// @notice Last day index from which a player claimed coinflip winnings.
    /// @dev Used to determine claim range in _claimCoinflipsInternal().
    mapping(address => uint48) internal lastCoinflipClaim;

    /// @notice The most recent day index that has been resolved and is claimable.
    /// @dev Advances each time processCoinflipPayouts() is called.
    ///      Active betting day = flipsClaimableDay + 1 (via _targetFlipDay).
    uint48 internal flipsClaimableDay;

    /// @notice Timestamp when the game contract was deployed.
    /// @dev Used to calculate day index relative to deploy (day 1 = deploy day).
    ///      Set by the game contract via setDeployTime().
    uint48 internal deployTime;

    /*+======================================================================+
      |                         VAULT ESCROW                                 |
      +======================================================================+
      |  Virtual mint allowance for the ContractAddresses.VAULT. This represents BURNIE that   |
      |  exists "on paper" but hasn't entered circulation. The ContractAddresses.VAULT can     |
      |  mint from this allowance when distributing to players.              |
      +======================================================================+*/

    /// @notice Virtual supply the ContractAddresses.VAULT is authorized to mint (not yet circulating).
    /// @dev Seeded to 2,000,000 BURNIE. Increases via vaultEscrow(), decreases via vaultMintTo().
    ///      supplyIncUncirculated = totalSupply + _vaultMintAllowance.
    /// @custom:security Only ContractAddresses.VAULT/game can increase; only ContractAddresses.VAULT can mint from it.
    uint256 private _vaultMintAllowance = 2_000_000 ether;

    /*+======================================================================+
      |                       LEADERBOARD STATE                              |
      +======================================================================+
      |  Per-level and per-day tracking of the top coinflip bettor. Used     |
      |  for bonus payouts and UI display. Scores stored in whole tokens.    |
      +======================================================================+*/

    /// @notice Tracks whether the top-flip bonus has been paid for a given game level.
    /// @dev Key: game level. Value: true if bonus already paid. One-time per level.
    mapping(uint24 => bool) internal topFlipRewardPaid;

    /// @notice Live per-level leaderboard for biggest pending flip stake.
    /// @dev Key: game level. Value: (player, score in whole tokens).
    ///      Updated on each addFlip() call.
    mapping(uint24 => PlayerScore) internal coinflipTopByLevel;

    /// @notice Live per-day leaderboard for biggest pending flip stake.
    /// @dev Key: day index. Value: (player, score in whole tokens).
    ///      Reset implicitly each new day.
    mapping(uint48 => PlayerScore) internal coinflipTopByDay;

    /*+======================================================================+
      |                         VIEW HELPERS                                 |
      +======================================================================+
      |  Read-only functions for UIs and external contracts to query state.  |
      +======================================================================+*/

    /// @notice View-only helper to estimate claimable coin (flips only) for the caller.
    /// @dev Does not include pending stakes, only resolved winning days.
    /// @return The total BURNIE claimable from past winning coinflips.
    function claimableCoin() external view returns (uint256) {
        address player = msg.sender;
        return _viewClaimableCoin(player);
    }

    /// @notice Total supply including uncirculated ContractAddresses.VAULT allowance.
    /// @dev Used by ContractAddresses.VAULT share calculations and dashboards.
    /// @return The sum of circulating supply + virtual ContractAddresses.VAULT reserve.
    function supplyIncUncirculated() external view returns (uint256) {
        return totalSupply + _vaultMintAllowance;
    }

    /// @notice Virtual coin reserved for the ContractAddresses.VAULT (not yet circulating).
    /// @dev Exposed for the ContractAddresses.VAULT share math and external dashboards.
    /// @return The current ContractAddresses.VAULT mint allowance in BURNIE (18 decimals).
    function vaultMintAllowance() external view returns (uint256) {
        return _vaultMintAllowance;
    }

    /*+======================================================================+
      |                         BOUNTY STATE                                 |
      +======================================================================+
      |  Global bounty pool for record-breaking flips. The bounty pool       |
      |  accumulates 1000 BURNIE per coinflip window. When a player sets     |
      |  a new all-time high flip, they arm the bounty. On their next        |
      |  coinflip resolution, half the pool is removed; if they win, that    |
      |  half is credited to their stake.                                    |
      |                                                                      |
      |  STORAGE LAYOUT (packed in slots):                                   |
      |  +-----------------------------------------------------------------+ |
      |  | Slot | Variable         | Type     | Size     | Notes           | |
      |  +------+------------------+----------+----------+-----------------+ |
      |  |  17  | currentBounty    | uint128  | 16 bytes | Pool size       | |
      |  |      | biggestFlipEver  | uint128  | 16 bytes | All-time record | |
      |  |  18  | bountyOwedTo     | address  | 20 bytes | Armed recipient | |
      |  +-----------------------------------------------------------------+ |
      +======================================================================+*/

    /// @notice Current bounty pool size in BURNIE (18 decimals).
    /// @dev Increases by 1000 BURNIE each coinflip window. Half removed per resolution (paid on win).
    ///      Wraps on overflow (effectively resets to small value).
    uint128 public currentBounty = 1_000_000_000;

    /// @notice All-time record for biggest coinflip stake.
    /// @dev Updated when a new record is set. Used as threshold for arming bounty.
    ///      Frozen during RNG lock to prevent manipulation.
    uint128 public biggestFlipEver = 1_000_000_000;

    /// @notice Address that has armed the bounty (set new record).
    /// @dev Cleared after payout. Only one player can hold bounty right at a time.
    address internal bountyOwedTo;

    /*+======================================================================+
      |                       ERC20 DECIMALS                                 |
      +======================================================================+*/

    /// @notice Number of decimal places for BURNIE token.
    /// @dev 18 decimals (standard ERC20). 1 BURNIE = 1e18 base units.
    uint8 public constant decimals = 18;

    /*+======================================================================+
      |                       ERC20 FUNCTIONS                                |
      +======================================================================+
      |  Standard ERC20 interface with game-contract bypass for transferFrom.|
      |  The game contract can transfer on behalf of players without prior   |
      |  approval (trusted contract pattern).                                |
      +======================================================================+*/

    /// @notice Approve `spender` to transfer up to `amount` tokens on behalf of caller.
    /// @dev Standard ERC20 approve. Setting to type(uint256).max indicates infinite approval.
    /// @param spender The address authorized to spend.
    /// @param amount The maximum amount that can be spent.
    /// @return True on success.
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfer `amount` tokens from caller to `to`.
    /// @dev Standard ERC20 transfer. Reverts on insufficient balance.
    /// @param to The recipient address.
    /// @param amount The amount to transfer (18 decimals).
    /// @return True on success.
    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /// @notice Transfer `amount` tokens from `from` to `to` on behalf of caller.
    /// @dev Standard ERC20 transferFrom with game-contract bypass.
    ///      SECURITY: DegenerusGame can transfer without approval (trusted contract pattern).
    ///      This enables seamless gameplay transactions without pre-approval steps.
    /// @param from The source address.
    /// @param to The destination address.
    /// @param amount The amount to transfer (18 decimals).
    /// @return True on success.
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        // Game contract bypass: no allowance check needed for trusted game operations
        if (msg.sender != ContractAddresses.GAME) {
            uint256 allowed = allowance[from][msg.sender];
            // Infinite approval optimization: skip allowance update for max value
            if (allowed != type(uint256).max) {
                // Solidity 0.8+ will revert on underflow if allowed < amount
                uint256 newAllowance = allowed - amount;
                allowance[from][msg.sender] = newAllowance;
                emit Approval(from, msg.sender, newAllowance);
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Internal transfer helper.
    /// @dev Reverts on zero address or insufficient balance (via Solidity 0.8+ underflow check).
    /// @param from The source address.
    /// @param to The destination address.
    /// @param amount The amount to transfer.
    function _transfer(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        // Solidity 0.8+ reverts on underflow if balanceOf[from] < amount
        balanceOf[from] -= amount;
        // Overflow is theoretically possible but would require ~2^256 total supply
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    /// @notice Internal mint helper - creates new tokens.
    /// @dev Increases totalSupply and recipient balance. Emits Transfer from address(0).
    /// @param to The recipient address (cannot be zero).
    /// @param amount The amount to mint (18 decimals).
    function _mint(address to, uint256 amount) internal {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Internal burn helper - destroys tokens.
    /// @dev Decreases totalSupply and sender balance. Emits Transfer to address(0).
    ///      SECURITY: Burns BEFORE any external calls (CEI pattern) in depositCoinflip/decimatorBurn.
    /// @param from The address to burn from (cannot be zero).
    /// @param amount The amount to burn (18 decimals).
    function _burn(address from, uint256 amount) internal {
        if (from == address(0)) revert ZeroAddress();
        // Solidity 0.8+ reverts on underflow if balanceOf[from] < amount
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    /*+======================================================================+
      |                         CONSTANTS                                    |
      +======================================================================+
      |  Protocol parameters and unit conversions. These define the          |
      |  economic boundaries of the coinflip and decimator systems.          |
      |                                                                      |
      |  VALUE SUMMARY:                                                      |
      |  • ether (1e18)            - Standard 18-decimal token unit          |
      |  • PRICE_COIN_UNIT (1000)  - Bounty increment per window             |
      |  • MIN (100 BURNIE)        - Minimum deposit/burn threshold          |
      |  • COINFLIP_EXTRA [78-115] - Payout multiplier range for normal      |
      |  • BPS_DENOMINATOR (10000) - Basis points conversion                 |
      |  • DECIMATOR_BUCKET (10)   - Base bucket for decimator weighting     |
      |  • JACKPOT_RESET_TIME      - Daily reset boundary (22:57 UTC)        |
      |  • COIN_CLAIM_DAYS (30)    - Max days to claim past winnings         |
      +======================================================================+*/

    /// @dev 1000 BURNIE - used for bounty accumulation and top-flip rewards.
    uint256 private constant PRICE_COIN_UNIT = 1000 ether;

    /// @dev Minimum amount for coinflip deposits and decimator burns (100 BURNIE).
    ///      Prevents dust attacks and meaningless micro-stakes.
    uint256 private constant MIN = 100 ether;

    /// @dev Base percentage for normal coinflip payouts (non-extreme outcomes).
    ///      Range: [78, 78+37] = [78%, 115%] when added to principal.
    uint16 private constant COINFLIP_EXTRA_MIN_PERCENT = 78;

    /// @dev Range width for coinflip payout randomization: min + (rng % 38) => [78..115].
    uint16 private constant COINFLIP_EXTRA_RANGE = 38;

    /// @dev Basis points denominator for percentage calculations (100.00%).
    uint16 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Base bucket denominator for decimator weighting.
    ///      Lower bucket = more valuable. Adjusted based on level and streak.
    uint8 private constant DECIMATOR_BUCKET = 10;

    /// @dev Seconds offset from midnight UTC for daily coinflip reset boundary (22:57 UTC).
    uint48 private constant JACKPOT_RESET_TIME = 82620;

    /// @dev Maximum number of past days a player can claim coinflip winnings.
    ///      After 30 days, unclaimed winnings expire (stakes are forfeit).
    uint8 private constant COIN_CLAIM_DAYS = 30;

    /// @dev Maximum BAF (Biggest Active Flip) bracket level.
    ///      Levels are grouped into brackets of 10 for leaderboard tracking.
    uint24 private constant MAX_BAF_BRACKET = (type(uint24).max / 10) * 10;

    /*+======================================================================+
      |                         MODIFIERS                                    |
      +======================================================================+
      |  Access control modifiers for privileged operations. Each modifier   |
      |  gates access to a specific set of trusted contracts.                |
      |                                                                      |
      |  MODIFIER HIERARCHY:                                                 |
      |  +-----------------------------------------------------------------+ |
      |  |  Modifier              | Allowed Callers                        | |
      |  +------------------------+----------------------------------------+ |
      |  |  onlyDegenerusGame     | degenerusGame only                     | |
      |  |  onlyTrustedContracts  | game, gamepiece, affiliate, color registry   | |
|  |  onlyFlipCreditors     | game, gamepiece, affiliate                  | |
      |  |  onlyVault             | VAULT only                             | |
      |  +-----------------------------------------------------------------+ |
      +======================================================================+*/

    /// @dev Restricts access to the DegenerusGame contract only.
    ///      Used for: processCoinflipPayouts, rollDailyQuest, notifyQuestBurn.
    modifier onlyDegenerusGameContract() {
        if (msg.sender != ContractAddresses.GAME) revert OnlyGame();
        _;
    }

    /// @dev Restricts access to game, gamepiece, affiliate, or color registry contracts.
    ///      Used for: burnCoin (gameplay burns).
    modifier onlyTrustedContracts() {
        address sender = msg.sender;
        if (
            sender != ContractAddresses.GAME &&
            sender != ContractAddresses.GAMEPIECES &&
            sender != ContractAddresses.AFFILIATE &&
            sender != ContractAddresses.ICON_COLOR_REGISTRY
        ) revert OnlyTrustedContracts();
        _;
    }

    /// @dev Restricts access to contracts that can credit flip stakes.
    ///      Used for: creditFlip, creditFlipBatch.
    modifier onlyFlipCreditors() {
        address sender = msg.sender;
        if (
            sender != ContractAddresses.GAME &&
            sender != ContractAddresses.GAMEPIECES &&
            sender != ContractAddresses.AFFILIATE
        ) revert OnlyFlipCreditors();
        _;
    }

    /// @dev Restricts access to the ContractAddresses.VAULT contract only.
    ///      Used for: vaultMintTo.
    modifier onlyVault() {
        if (msg.sender != ContractAddresses.VAULT) revert OnlyVault();
        _;
    }

    /*+======================================================================+
      |                      PLAYER COINFLIP FUNCTIONS                       |
      +======================================================================+
      |  External entry points for players to deposit BURNIE into the        |
      |  daily coinflip pool. Stakes are placed for the next day window.     |
      |                                                                      |
      |  FLOW:                                                               |
      |  1. Player calls depositCoinflip(amount)                             |
      |  2. BURNIE is burned from player (CEI pattern)                       |
      |  3. Quest module checks for bonus rewards                            |
      |  4. Stake + bonuses added via addFlip() to next day's pool           |
      |  5. On next window close, win/loss is resolved via VRF               |
      |  6. Winnings auto-claimed on next deposit                            |
      +======================================================================+*/

    /// @notice Burn BURNIE to increase the caller's coinflip stake, applying quest rewards when eligible.
    /// @dev Zero-amount calls act as cash-out of pending winnings without adding new stake.
    ///      SECURITY: Burns BEFORE downstream calls (CEI pattern) to prevent reentrancy.
    ///      Locked during level jackpot resolution to prevent stake manipulation.
    /// @param amount Amount (18 decimals) to burn; must satisfy MIN (100 BURNIE), or zero for cash-out.
    function depositCoinflip(uint256 amount) external {
        // Allow zero-amount calls to act as a cash-out of pending winnings without adding a new stake.
        if (amount == 0) {
            addFlip(msg.sender, 0, false, false, true);
            emit CoinflipDeposit(msg.sender, 0);
            return;
        }
        // Prevent deposits during critical RNG resolution phase
        if (_coinflipLockedDuringLevelJackpot()) revert CoinflipLocked();
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;

        // CEI PATTERN: Burn first so reentrancy into downstream module calls cannot spend the same balance twice.
        _burn(caller, amount);

        // Quests can layer on bonus flip credit when the quest is active/completed.
        IDegenerusQuests module = questModule;
        uint256 questReward;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth) = module
            .handleFlip(caller, amount);
        questReward = _questApplyReward(caller, reward, hardMode, questType, streak, completed, completedBoth);

        // Principal + quest bonus become the pending flip stake.
        uint256 creditedFlip = amount + questReward;
        // canArmBounty=true, bountyEligible=true: this deposit can set new records
        addFlip(caller, creditedFlip, true, true, true);
        degenerusGame.recordCoinflipDeposit(amount);

        emit CoinflipDeposit(caller, amount);
    }

    /// @dev Check if coinflip deposits are locked during level jackpot resolution.
    ///      Locked when: gameState=2 (purchase) AND lastPurchaseDay AND rngLocked.
    /// @return locked True if deposits should be rejected.
    function _coinflipLockedDuringLevelJackpot() private view returns (bool locked) {
        (, uint8 gameState_, bool lastPurchaseDay_, bool rngLocked_, ) = degenerusGame.purchaseInfo();
        locked = (gameState_ == 2) && lastPurchaseDay_ && rngLocked_;
    }

    /*+======================================================================+
      |                      DECIMATOR BURN FUNCTION                         |
      +======================================================================+
      |  Burns BURNIE during decimator windows to participate in ContractAddresses.JACKPOTS.   |
      |  Weighted participation based on player's mint streak and level.     |
      |                                                                      |
      |  BUCKET CALCULATION:                                                 |
      |  • Base bucket = 10 (lower = more valuable)                          |
      |  • Non-100 levels: bucket = 10 - (streak / 10), min 5                |
      |  • 100-levels: bucket = 10 - (streak/20 + mintLvls/25), min 2        |
      |                                                                      |
      |  The effective burn amount is scaled by player's bonus multiplier,   |
      |  but the multiplier is disabled once effective score reaches cap.    |
      +======================================================================+*/

    /// @notice Burn BURNIE during an active Decimator window to accrue weighted participation.
    /// @dev SECURITY: Burns BEFORE downstream calls (CEI pattern).
    ///      Quest rewards are added to the base amount before bucket calculation.
    ///      Bucket determines jackpot weight (lower = better odds).
    /// @param amount Amount (18 decimals) to burn; must satisfy MIN (100 BURNIE).
    function decimatorBurn(uint256 amount) external {
        IDegenerusGame game = degenerusGame;
        (bool decOn, uint24 lvl) = game.decWindow();
        if (!decOn) revert NotDecimatorWindow();
        if (amount < MIN) revert AmountLTMin();

        address caller = msg.sender;
        // CEI PATTERN: Burn first to anchor the amount used for bonuses.
        _burn(caller, amount);

        // Check for quest completion/bonus
        IDegenerusQuests module = questModule;
        (
            uint256 reward,
            bool hardMode,
            uint8 questType,
            uint32 questStreak,
            bool completed,
            bool completedBoth
        ) = module.handleDecimator(caller, amount);
        uint256 questReward = _questApplyReward(
            caller,
            reward,
            hardMode,
            questType,
            questStreak,
            completed,
            completedBoth
        );

        // Scale decimator weight using the shared player bonus multiplier.
        uint256 multBps = game.playerBonusMultiplier(caller);
        uint256 baseAmount = amount + questReward;

        // Calculate bucket based on level type and player's mint streak
        uint8 bucket = DECIMATOR_BUCKET;
        if (lvl == 5) {
            // Level 5: bucket by mint-level count (0->10 ... 5+->5).
            uint24 mintLvls = game.ethMintLevelCount(caller);
            if (mintLvls >= 5) {
                bucket = 5;
            } else {
                bucket = uint8(DECIMATOR_BUCKET - uint8(mintLvls));
            }
        } else if (lvl % 100 != 0) {
            // Non-100 levels: simpler bucket reduction based on streak
            uint24 dec = game.ethMintStreakCount(caller) / 10;
            bucket = dec >= 5 ? uint8(5) : uint8(DECIMATOR_BUCKET - uint8(dec));
        } else {
            // 100-levels: more complex calculation factoring in both streak and mint levels
            uint24 streak = game.ethMintStreakCount(caller);
            uint24 mintLvls = game.ethMintLevelCount(caller);
            uint256 mintContribution;
            if (lvl > 100) {
                uint256 maxCount = (uint256(lvl) * 75) / 100;
                if (maxCount != 0) {
                    mintContribution = (uint256(mintLvls) * 4) / maxCount;
                    if (mintContribution > 4) mintContribution = 4;
                }
            } else {
                mintContribution = uint256(mintLvls / 25);
            }
            uint256 dec = uint256(streak / 20) + mintContribution;
            uint256 reduced = dec >= DECIMATOR_BUCKET ? 0 : uint256(DECIMATOR_BUCKET) - dec;
            // Floor at 2 for 100-levels (more valuable base)
            bucket = reduced < 2 ? uint8(2) : uint8(reduced);
        }

        // Record the burn with the ContractAddresses.JACKPOTS module
        uint8 bucketUsed = jackpots.recordDecBurn(caller, lvl, bucket, baseAmount, multBps);

        emit DecimatorBurn(caller, amount, bucketUsed);
    }

    /// @dev View helper to calculate claimable coinflip winnings for a player.
    ///      Iterates through up to COIN_CLAIM_DAYS resolved days; older stakes expire.
    /// @param player The player address to check.
    /// @return total The sum of all claimable winnings (principal + reward%).
    function _viewClaimableCoin(address player) internal view returns (uint256 total) {
        // Pending flip winnings within the claim window (up to 30 days); staking removed.
        uint48 latestDay = flipsClaimableDay;
        uint48 startDay = lastCoinflipClaim[player];
        if (startDay >= latestDay) return 0;

        uint48 minClaimableDay;
        unchecked {
            minClaimableDay = latestDay > COIN_CLAIM_DAYS ? latestDay - COIN_CLAIM_DAYS : 0;
        }
        if (startDay < minClaimableDay) {
            startDay = minClaimableDay;
        }

        uint8 remaining = COIN_CLAIM_DAYS;
        uint48 cursor = startDay + 1;
        while (remaining != 0 && cursor <= latestDay) {
            CoinflipDayResult storage result = coinflipDayResult[cursor];
            // Unresolved day detection: both fields zero means day not yet settled
            if (result.rewardPercent == 0 && !result.win) break;

            uint256 flipStake = coinflipBalance[cursor][player];
            if (flipStake != 0 && result.win) {
                // Payout = principal + (principal * rewardPercent%)
                // rewardPercent is already in percent (not bps), so multiply by 100 to get bps equivalent
                uint256 payout = flipStake + (flipStake * uint256(result.rewardPercent) * 100) / BPS_DENOMINATOR;
                total += payout;
            }
            unchecked {
                ++cursor;
                --remaining;
            }
        }
    }

    /*+======================================================================+
      |                       VAULT FUNCTIONS                                |
      +======================================================================+
      |  Manage the virtual ContractAddresses.VAULT reserve and mint from it when needed.      |
      +======================================================================+*/

    /// @notice Escrow virtual coin to the ContractAddresses.VAULT (no token movement); increases mint allowance.
    /// @dev Access: ContractAddresses.VAULT or game when routing coin share without touching the ContractAddresses.VAULT.
    ///      This increases the "paper" reserve that ContractAddresses.VAULT can later mint from.
    /// @param amount The amount of virtual BURNIE to add to the allowance.
    function vaultEscrow(uint256 amount) external {
        if (amount == 0) return;
        address sender = msg.sender;
        if (sender != ContractAddresses.VAULT && sender != ContractAddresses.GAME) revert OnlyVaultOrGame();
        _vaultMintAllowance += amount;
        emit VaultEscrowRecorded(sender, amount);
    }

    /// @notice Mint coin out of the ContractAddresses.VAULT allowance to a recipient.
    /// @dev Access: ContractAddresses.VAULT only. Converts virtual reserve into circulating supply.
    ///      Reverts if amount exceeds available allowance.
    /// @param to The recipient address.
    /// @param amount The amount to mint (18 decimals).
    function vaultMintTo(address to, uint256 amount) external onlyVault {
        if (amount == 0) return;
        uint256 allowanceVault = _vaultMintAllowance;
        if (amount > allowanceVault) revert Insufficient();
        _vaultMintAllowance = allowanceVault - amount;
        _mint(to, amount);
    }

    /*+======================================================================+
      |                       FLIP CREDIT FUNCTIONS                          |
      +======================================================================+
      |  Allow authorized contracts to credit coinflip stakes to players     |
      |  without requiring them to burn BURNIE directly.                     |
      +======================================================================+*/

    /// @notice Credit a coinflip stake from authorized contracts (game, gamepiece, affiliate).
    /// @dev Zero address or zero amount is a no-op.
    ///      Does NOT arm bounty (canArmBounty=false) - only direct deposits can set records.
    /// @param player The player to credit.
    /// @param amount The stake amount to add (18 decimals).
    function creditFlip(address player, uint256 amount) external onlyFlipCreditors {
        if (player == address(0) || amount == 0) return;
        addFlip(player, amount, false, false, false);
    }

    /// @notice Credit LINK-funded bonus directly (ContractAddresses.ADMIN-triggered).
    /// @dev Admin-only. Credits flip stake for LINK donation rewards.
    ///      Used for promotional rewards funded by LINK token proceeds.
    /// @param player The recipient address.
    /// @param amount The amount to credit as flip stake (18 decimals).
    function creditLinkReward(address player, uint256 amount) external {
        if (msg.sender != ContractAddresses.ADMIN) revert OnlyAdmin();
        if (player == address(0) || amount == 0) return;
        addFlip(player, amount, false, false, false);
        emit LinkCredit(player, amount);
    }

    /// @notice Set the deploy timestamp for day index calculations.
    /// @dev Admin-only. Can only be set once (when deployTime is 0).
    ///      Called by game contract during initialization.
    /// @param timestamp The deploy timestamp from the game contract.
    function setDeployTime(uint48 timestamp) external {
        if (msg.sender != ContractAddresses.ADMIN) revert OnlyAdmin();
        if (deployTime != 0) revert(); // Can only set once
        if (timestamp == 0) revert();
        deployTime = timestamp;
    }

    /// @notice Batch credit up to three flip stakes in a single call.
    /// @dev Gas optimization for crediting multiple players in one transaction.
    ///      Zero addresses or amounts are skipped.
    /// @param players Array of 3 player addresses.
    /// @param amounts Array of 3 stake amounts (18 decimals each).
    function creditFlipBatch(address[3] calldata players, uint256[3] calldata amounts) external onlyFlipCreditors {
        for (uint256 i; i < 3; ) {
            address player = players[i];
            uint256 amount = amounts[i];
            if (player != address(0) && amount != 0) {
                addFlip(player, amount, false, false, false);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Compute affiliate quest rewards while preserving quest module access control.
    /// @dev Access: affiliate contract only. Routes through coin contract to enforce access.
    /// @param player The player who triggered the affiliate action.
    /// @param amount The base amount for quest calculation.
    /// @return questReward The bonus reward earned (if any quest completed).
    function affiliateQuestReward(address player, uint256 amount) external returns (uint256 questReward) {
        if (msg.sender != ContractAddresses.AFFILIATE) revert OnlyAffiliate();
        IDegenerusQuests module = questModule;
        if (player == address(0) || amount == 0) return 0;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth) = module
            .handleAffiliate(player, amount);
        return _questApplyReward(player, reward, hardMode, questType, streak, completed, completedBoth);
    }

    /*+======================================================================+
      |                       QUEST INTEGRATION                              |
      +======================================================================+
      |  Daily quest lifecycle functions. The coin contract acts as a hub    |
      |  to route quest-related calls to the quest module while maintaining  |
      |  access control and emitting events for indexers.                    |
      +======================================================================+*/

    /// @notice Roll the daily quest for a given day using VRF entropy.
    /// @dev Access: game contract only. Emits DailyQuestRolled for each quest type.
    /// @param day The day index to roll for.
    /// @param entropy VRF-sourced randomness for quest selection.
    function rollDailyQuest(uint48 day, uint256 entropy) external onlyDegenerusGameContract {
        IDegenerusQuests module = questModule;
        (bool rolled, uint8[2] memory questTypes, bool highDifficulty) = module.rollDailyQuest(day, entropy);
        if (rolled) {
            for (uint256 i; i < 2; ) {
                emit DailyQuestRolled(day, questTypes[i], highDifficulty);
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Roll the daily quest with explicit overrides for quest types.
    /// @dev Access: game contract only. Used when game state requires specific quest types.
    /// @param day The day index to roll for.
    /// @param entropy VRF-sourced randomness.
    /// @param forceMintEth Force a mint-with-ETH quest type.
    /// @param forceBurn Force a burn quest type.
    function rollDailyQuestWithOverrides(
        uint48 day,
        uint256 entropy,
        bool forceMintEth,
        bool forceBurn
    ) external onlyDegenerusGameContract {
        IDegenerusQuests module = questModule;
        (bool rolled, uint8[2] memory questTypes, bool highDifficulty) = module.rollDailyQuestWithOverrides(
            day,
            entropy,
            forceMintEth,
            forceBurn
        );
        if (rolled) {
            for (uint256 i; i < 2; ) {
                emit DailyQuestRolled(day, questTypes[i], highDifficulty);
                unchecked {
                    ++i;
                }
            }
        }
    }

    /// @notice Normalize burn quests mid-day when extermination ends the burn window.
    /// @dev Access: game contract only. Called when game state transition invalidates burn quests.
    function normalizeActiveBurnQuests() external onlyDegenerusGameContract {
        IDegenerusQuests module = questModule;
        module.normalizeActiveBurnQuests();
    }

    /// @notice Notify quest module of a mint action.
    /// @dev Access: gamepiece contract only. Credits quest rewards as flip stakes.
    /// @param player The player who minted.
    /// @param quantity Number of gamepieces minted.
    /// @param paidWithEth Whether the mint was paid with ETH (vs BURNIE).
    function notifyQuestMint(address player, uint32 quantity, bool paidWithEth) external {
        if (msg.sender != ContractAddresses.GAMEPIECES) revert OnlyNft();
        IDegenerusQuests module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth) = module
            .handleMint(player, quantity, paidWithEth);
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed, completedBoth);
        if (questReward != 0) {
            addFlip(player, questReward, false, false, false);
        }
    }

    /// @notice Notify quest module of an gamepiece burn.
    /// @dev Access: game contract only. Credits quest rewards as flip stakes.
    /// @param player The player who burned gamepieces.
    /// @param quantity Number of gamepieces burned.
    function notifyQuestBurn(address player, uint32 quantity) external {
        if (msg.sender != ContractAddresses.GAME) revert OnlyGame();
        IDegenerusQuests module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth) = module
            .handleBurn(player, quantity);
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed, completedBoth);
        if (questReward != 0) {
            addFlip(player, questReward, false, false, false);
        }
    }

    /// @notice Notify quest module of a loot box purchase.
    /// @dev Access: game contract only. Credits quest rewards as flip stakes.
    /// @param player The player who purchased the loot box.
    /// @param amountWei ETH amount spent on the loot box (in wei).
    function notifyQuestLootBox(address player, uint256 amountWei) external {
        if (msg.sender != ContractAddresses.GAME) revert OnlyGame();
        IDegenerusQuests module = questModule;
        (uint256 reward, bool hardMode, uint8 questType, uint32 streak, bool completed, bool completedBoth) = module
            .handleLootBox(player, amountWei);
        uint256 questReward = _questApplyReward(player, reward, hardMode, questType, streak, completed, completedBoth);
        if (questReward != 0) {
            addFlip(player, questReward, false, false, false);
        }
    }

    /// @notice Burn BURNIE from `target` during gameplay/affiliate flows.
    /// @dev Access: DegenerusGame, gamepiece, or affiliate.
    ///      Used for purchases, fees, and affiliate utilities.
    ///      Reverts on zero address or insufficient balance.
    /// @param target The address to burn from.
    /// @param amount The amount to burn (18 decimals).
    function burnCoin(address target, uint256 amount) external onlyTrustedContracts {
        _burn(target, amount);
    }

    /*+======================================================================+
      |                       COINFLIP VIEW FUNCTIONS                        |
      +======================================================================+
      |  Read-only functions for querying coinflip stake amounts.            |
      +======================================================================+*/

    /// @notice Get a player's coinflip stake for the current betting window.
    /// @param player The player address to query.
    /// @return The stake amount for the current target day (18 decimals).
    function coinflipAmount(address player) external view returns (uint256) {
        uint48 day = _targetFlipDay();
        return coinflipBalance[day][player];
    }

    /// @notice Return the player's coinflip stake for the most recently opened day window.
    /// @dev This is the prior day relative to `_targetFlipDay()` (since stakes always target the next day).
    ///      Useful for UIs showing "last day's bet" that is now being resolved.
    /// @param player The player address to query.
    /// @return The stake amount from the previous day (18 decimals).
    function coinflipAmountLastDay(address player) external view returns (uint256) {
        uint48 day = _targetFlipDay();
        unchecked {
            return coinflipBalance[day - 1][player];
        }
    }

    /// @notice Get comprehensive flip credit info for a player.
    /// @dev Shows current stake, yesterday's stake, and claimable amount without processing claims.
    /// @param player The player's address.
    /// @return currentDayStake Stake in the current active betting day.
    /// @return lastDayStake Stake in yesterday's day window.
    /// @return flipsClaimable Total BURNIE claimable from won flips (preview, doesn't modify state).
    /// @return currentDay The current active betting day index.
    function getFlipCreditInfo(address player)
        external
        view
        returns (
            uint256 currentDayStake,
            uint256 lastDayStake,
            uint256 flipsClaimable,
            uint48 currentDay
        )
    {
        currentDay = _targetFlipDay();
        currentDayStake = coinflipBalance[currentDay][player];
        unchecked {
            lastDayStake = currentDay > 0 ? coinflipBalance[currentDay - 1][player] : 0;
        }

        // Calculate claimable without modifying state (similar to _claimCoinflipsInternal but view-only)
        uint48 latestDay = flipsClaimableDay;
        uint48 startDay = lastCoinflipClaim[player];

        if (startDay < latestDay) {
            uint48 claimableCount = latestDay - startDay;
            if (claimableCount > 30) {
                claimableCount = 30; // Cap at 30 days
            }

            uint48 cursor = startDay;
            for (uint256 i; i < claimableCount; ) {
                CoinflipDayResult storage result = coinflipDayResult[cursor];
                uint256 flipStake = coinflipBalance[cursor][player];

                if (flipStake != 0 && result.win) {
                    uint256 bonus = (flipStake * result.rewardPercent) / 100;
                    flipsClaimable += flipStake + bonus;
                }

                unchecked {
                    ++cursor;
                    ++i;
                }
            }
        }
    }

    /*+======================================================================+
      |                    INTERNAL CLAIM FUNCTIONS                          |
      +======================================================================+
      |  Process past coinflip winnings for a player. Called lazily during   |
      |  addFlip() (claimNow) to auto-claim wins before adding new stakes.   |
      +======================================================================+*/

    /// @dev Process coinflip claims for up to COIN_CLAIM_DAYS resolved days.
    ///      Called by addFlip() only when claimNow=true (manual deposits).
    ///      IMPORTANT: This modifies state (coinflipBalance, lastCoinflipClaim).
    /// @param player The player to process claims for.
    /// @return claimed Total BURNIE won across all processed days.
    function _claimCoinflipsInternal(address player) internal returns (uint256 claimed) {
        uint48 latest = flipsClaimableDay;
        uint48 start = lastCoinflipClaim[player];
        if (start >= latest) return 0;

        // Enforce 30-day expiration: anything older than (latest - 30) is forfeit.
        // This also initializes new players to start from the recent window.
        uint48 minClaimableDay;
        unchecked {
            minClaimableDay = latest > COIN_CLAIM_DAYS ? latest - COIN_CLAIM_DAYS : 0;
        }
        if (start < minClaimableDay) {
            start = minClaimableDay;
        }

        uint48 cursor;
        unchecked {
            cursor = start + 1;
        }
        uint48 processed;

        uint8 remaining = COIN_CLAIM_DAYS;

        while (remaining != 0 && cursor <= latest) {
            CoinflipDayResult storage result = coinflipDayResult[cursor];

            // Unresolved day detection: stop processing
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
                // Clear stake whether win or loss (loss = forfeit principal)
                coinflipBalance[cursor][player] = 0;
            }

            processed = cursor;
            unchecked {
                ++cursor;
                --remaining;
            }
        }

        // Update last claim pointer if we processed any days
        if (processed != 0 && processed != start) {
            lastCoinflipClaim[player] = processed;
        }
    }

    /// @dev Calculate the target day for new coinflip deposits.
    ///      Day 1 = deploy day. Days reset at JACKPOT_RESET_TIME (22:57 UTC).
    ///      Stakes always target the NEXT day (current + 1).
    /// @return The day index for new deposits.
    function _targetFlipDay() internal view returns (uint48) {
        // Calculate current day with jackpot reset time offset, then target next day
        uint48 deployDayBoundary = uint48((deployTime - JACKPOT_RESET_TIME) / 1 days);
        uint48 currentDayBoundary = uint48((block.timestamp - JACKPOT_RESET_TIME) / 1 days);
        uint48 currentDay = currentDayBoundary - deployDayBoundary + 1;
        return currentDay + 1;
    }

    /// @dev Round a level up to the nearest bracket of 10 for BAF tracking.
    ///      Used to group levels into brackets for leaderboard efficiency.
    /// @param lvl The raw game level.
    /// @return The bracket level (rounded up to nearest 10).
    function _bafBracketLevel(uint24 lvl) private pure returns (uint24) {
        uint256 bracket = ((uint256(lvl) + 9) / 10) * 10;
        if (bracket > type(uint24).max) return MAX_BAF_BRACKET;
        return uint24(bracket);
    }

    /*+======================================================================+
      |                    COINFLIP RESOLUTION (GAME-ONLY)                   |
      +======================================================================+
      |  Called by DegenerusGame to resolve the daily coinflip using VRF.    |
      |  Determines win/loss and payout multiplier, then advances the        |
      |  claimable day window.                                               |
      +======================================================================+*/

    /// @notice Progress coinflip payouts for the current level in bounded slices.
    /// @dev Called by DegenerusGame; runs in three phases per settlement:
    ///      1. Record the flip resolution day for the level being processed.
    ///      2. Arm bounties on the first payout window.
    ///      3. Perform cleanup and reopen betting (flip claims happen lazily per player).
    ///
    ///      PAYOUT DISTRIBUTION (bonus on top of principal):
    ///      • 5% chance of 50% bonus (150% total) (roll == 0)
    ///      • 5% chance of 150% bonus (250% total) (roll == 1)
    ///      • 90% chance of [78%, 115%] bonus (178%-215% total)
    ///      • +6% if bonusFlip is true (last day bonus)
    ///
    /// @param level Current DegenerusGame level (used to gate 1/run and propagate flip stakes).
    /// @param bonusFlip Adds 6 percentage points to the payout roll for the last flip of the purchase phase.
    /// @param rngWord VRF-sourced random word for determining outcome.
    /// @param epoch The day index being resolved.
    /// @return finished True when all payouts and cleanup are complete (always true).
    function processCoinflipPayouts(
        uint24 level,
        bool bonusFlip,
        uint256 rngWord,
        uint48 epoch
    ) external onlyDegenerusGameContract returns (bool finished) {
        // Mix entropy with epoch for unique per-day randomness
        uint256 seedWord = uint256(keccak256(abi.encodePacked(rngWord, epoch)));

        // Determine payout bonus percent:
        // ~5% each for extreme bonus outcomes (50% or 150%), rest is [78%, 115%]
        uint256 roll = seedWord % 20;
        uint16 rewardPercent;
        if (roll == 0) {
            rewardPercent = 50; // Unlucky: 50% bonus (1.5x total)
        } else if (roll == 1) {
            rewardPercent = 150; // Lucky: 150% bonus (2.5x total)
        } else {
            // Normal bonus range: [78%, 115%]
            rewardPercent = uint16((seedWord % COINFLIP_EXTRA_RANGE) + COINFLIP_EXTRA_MIN_PERCENT);
        }
        // Last day bonus: add 6% to the bonus percent
        if (bonusFlip) {
            unchecked {
                rewardPercent += 6;
            }
        }

        // Least-significant bit decides win/loss for the window (50/50 odds).
        bool win = (rngWord & 1) == 1;

        // Record the day's result for future claims
        CoinflipDayResult storage dayResult = coinflipDayResult[epoch];
        dayResult.rewardPercent = rewardPercent;
        dayResult.win = win;

        // Bounty resolution: if someone armed the bounty, remove half; if win, credit that half to them.
        if (bountyOwedTo != address(0) && currentBounty > 0) {
            address to = bountyOwedTo;
            uint256 slice = currentBounty >> 1; // pay/delete half of the bounty pool
            unchecked {
                currentBounty -= uint128(slice);
            }
            if (win) {
                // Credit as flip stake, not direct mint
                addFlip(to, slice, false, false, false);
                emit BountyPaid(to, slice);
            }
            // Clear bounty owner regardless of win/loss
            bountyOwedTo = address(0);
        }

        // Move the active window forward; the resolved day becomes claimable immediately.
        flipsClaimableDay = epoch;

        // Accumulate bounty pool for next window
        unchecked {
            // Gas-optimized: wraps on overflow, which would effectively reset the bounty.
            currentBounty += uint128(PRICE_COIN_UNIT);
        }

        // Pay out top-flip bonus for this level (once per level)
        if (!topFlipRewardPaid[level]) {
            PlayerScore memory entry = coinflipTopByLevel[level];
            if (entry.player != address(0)) {
                // Credit lands as future flip stake; no direct mint.
                addFlip(entry.player, PRICE_COIN_UNIT, false, false, false);
                topFlipRewardPaid[level] = true;
            }
        }

        emit CoinflipFinished(win);
        return true;
    }

    /*+======================================================================+
      |                    LEADERBOARD VIEW FUNCTIONS                        |
      +======================================================================+
      |  Read-only functions for querying top bettors by level or day.       |
      +======================================================================+*/

    /// @notice Return the top coinflip bettor recorded for a given level.
    /// @dev Reads the level-keyed leaderboard entry.
    /// @param lvl The game level to query.
    /// @return player The address of the top bettor for this level.
    /// @return score The top stake in whole BURNIE tokens.
    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score) {
        PlayerScore memory stored = coinflipTopByLevel[lvl];
        return (stored.player, stored.score);
    }

    /// @notice Return the top coinflip bettor for the most recently opened day window.
    /// @dev Mirrors `coinflipAmountLastDay()` but returns the top address + score for that day.
    /// @return player The address of the top bettor for yesterday.
    /// @return score The top stake in whole BURNIE tokens.
    function coinflipTopLastDay() external view returns (address player, uint96 score) {
        uint48 day = _targetFlipDay();
        unchecked {
            PlayerScore memory stored = coinflipTopByDay[day - 1];
            return (stored.player, stored.score);
        }
    }

    /*+======================================================================+
      |                    INTERNAL STAKE MANAGEMENT                         |
      +======================================================================+
      |  Core internal function for adding coinflip stakes. Handles:         |
      |  • Auto-claiming past winnings (manual deposits only)                |
      |  • Recycling bonus (1% for rolling forward)                          |
      |  • Leaderboard updates                                               |
      |  • Bounty arming logic                                               |
      |  • BAF (Biggest Active Flip) jackpot tracking                        |
      +======================================================================+*/

    /// @notice Increase a player's pending coinflip stake and possibly arm a bounty.
    /// @dev Central function for all stake additions. Called by depositCoinflip, creditFlip, etc.
    ///
    ///      RECYCLING BONUS: Players get 1% bonus (capped at 500 BURNIE) for rolling
    ///      winnings forward instead of withdrawing (manual deposits only).
    ///
    ///      BOUNTY ARMING: Only direct deposits (canArmBounty=true, bountyEligible=true)
    ///      can set new records and arm the bounty. Requires:
    ///      - RNG not locked (prevent manipulation)
    ///      - newStake > biggestFlipEver
    ///      - If bounty already armed: must exceed by 1%
    ///
    /// @param player               Target player.
    /// @param coinflipDeposit      Amount to add to their current pending flip stake.
    /// @param canArmBounty         If true, a sufficiently large deposit may arm a bounty.
    /// @param bountyEligible       If true, this deposit can arm the bounty (entire amount is considered).
    /// @param claimNow             If true, auto-claim past flips and apply recycling bonus.
    function addFlip(
        address player,
        uint256 coinflipDeposit,
        bool canArmBounty,
        bool bountyEligible,
        bool claimNow
    ) internal {
        // Auto-claim only on manual deposits to avoid gas spikes on game-driven credits.
        if (claimNow) {
            uint256 totalClaimed = _claimCoinflipsInternal(player);
            uint256 mintRemainder;

            if (coinflipDeposit > totalClaimed) {
                // Recycling: small bonus (1%) for rolling winnings forward, capped at 500 BURNIE.
                uint256 recycled = coinflipDeposit - totalClaimed;
                uint256 bonus = recycled / 100;
                uint256 bonusCap = 500 ether;
                if (bonus > bonusCap) bonus = bonusCap;
                coinflipDeposit += bonus;
            } else if (totalClaimed > coinflipDeposit) {
                // If claims exceed the new deposit, mint the difference to the player immediately.
                mintRemainder = totalClaimed - coinflipDeposit;
            }
            if (mintRemainder != 0) {
                _mint(player, mintRemainder);
            }
        }

        // Determine which future day this stake applies to (always the next window).
        IDegenerusGame game = degenerusGame;
        bool rngLocked = game.rngLocked();
        uint48 targetDay = _targetFlipDay();
        uint24 currLevel = game.level();

        uint256 prevStake = coinflipBalance[targetDay][player];
        uint256 newStake = prevStake + coinflipDeposit;

        // Update player's stake for target day
        coinflipBalance[targetDay][player] = newStake;
        _updateTopDayBettor(player, newStake, targetDay);

        // Record flip for BAF (Biggest Active Flip) jackpot tracking
        if (coinflipDeposit != 0) {
            uint24 bafLvl = _bafBracketLevel(currLevel);
            jackpots.recordBafFlip(player, bafLvl, coinflipDeposit);
        }

        // Update level leaderboard (allowed even during RNG lock)
        _updateTopBettor(player, newStake, currLevel);

        // Bounty logic: only when RNG not locked (prevents manipulation after VRF request)
        if (!rngLocked) {
            uint256 record = biggestFlipEver;
            if (newStake > record) {
                // Guard against overflow: cap at uint128.max for record tracking
                if (newStake > type(uint128).max) revert Insufficient();
                biggestFlipEver = uint128(newStake);

                if (canArmBounty && bountyEligible) {
                    // Bounty arms when setting a new record with an eligible stake.
                    // If bounty already armed, must exceed by 1% (min +1) to steal it.
                    uint256 threshold = record;
                    if (bountyOwedTo != address(0)) {
                        uint256 onePercent = record / 100;
                        // Ensure minimum 1 wei increase if 1% rounds to 0
                        threshold = record + (onePercent == 0 ? 1 : onePercent);
                    }
                    if (newStake >= threshold) {
                        bountyOwedTo = player;
                        emit BountyOwed(player, currentBounty, newStake);
                    }
                }
            }
        }
    }

    /*+======================================================================+
      |                    INTERNAL HELPER FUNCTIONS                         |
      +======================================================================+*/

    /// @dev Apply quest reward if quest was completed. Emits QuestCompleted event.
    /// @param player The player who completed the quest.
    /// @param reward The raw reward amount.
    /// @param hardMode Whether completed in hard mode.
    /// @param questType The type of quest completed.
    /// @param streak The player's current streak.
    /// @param completed Whether the quest was actually completed.
    /// @param completedBoth Whether this completion finished both quest slots for the day.
    /// @return The reward amount (0 if not completed).
    function _questApplyReward(
        address player,
        uint256 reward,
        bool hardMode,
        uint8 questType,
        uint32 streak,
        bool completed,
        bool completedBoth
    ) private returns (uint256) {
        if (!completed) return 0;
        // Event captures quest progress for indexers/UI; raw reward is returned to the caller.
        emit QuestCompleted(player, questType, streak, reward, hardMode, completedBoth);
        return reward;
    }

    /// @dev Convert a raw stake amount to a uint96 score (whole tokens only).
    ///      Caps at type(uint96).max to prevent truncation issues.
    /// @param s The raw stake amount (18 decimals).
    /// @return The score in whole tokens (divided by 1 ether).
    function _score96(uint256 s) private pure returns (uint96) {
        uint256 wholeTokens = s / 1 ether;
        if (wholeTokens > type(uint96).max) {
            wholeTokens = type(uint96).max;
        }
        return uint96(wholeTokens);
    }

    /// @dev Update level leaderboard if player's score is higher than current leader.
    /// @param player The player address.
    /// @param stakeScore The player's total stake (raw, 18 decimals).
    /// @param lvl The game level.
    function _updateTopBettor(address player, uint256 stakeScore, uint24 lvl) private {
        uint96 score = _score96(stakeScore);
        PlayerScore memory levelLeader = coinflipTopByLevel[lvl];
        if (score > levelLeader.score || levelLeader.player == address(0)) {
            coinflipTopByLevel[lvl] = PlayerScore({player: player, score: score});
        }
    }

    /// @dev Update day leaderboard if player's score is higher than current leader.
    /// @param player The player address.
    /// @param stakeScore The player's total stake (raw, 18 decimals).
    /// @param day The day index.
    function _updateTopDayBettor(address player, uint256 stakeScore, uint48 day) private {
        uint96 score = _score96(stakeScore);
        PlayerScore memory dayLeader = coinflipTopByDay[day];
        if (score > dayLeader.score || dayLeader.player == address(0)) {
            coinflipTopByDay[day] = PlayerScore({player: player, score: score});
        }
    }
}
