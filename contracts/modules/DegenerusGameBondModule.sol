// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";

/// @notice Minimal interface for the Bonds contract used by this module.
interface IBonds {
    /// @notice Send ETH/stETH/BURNIE to bonds for jackpot funding or vault sweep.
    /// @param coinAmount BURNIE amount to credit (minted via vaultEscrow beforehand).
    /// @param stEthAmount stETH amount to transfer from game to bonds.
    /// @param rngWord VRF entropy for bond jackpot resolution (0 if not applicable).
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable;

    /// @notice Signal game-over to bonds, enabling shutdown resolution flow.
    function notifyGameOver() external;

    /// @notice Query the ETH cover required for upcoming bond maturities.
    /// @param stopAt Maximum bondPool value to consider (optimization hint).
    /// @return required ETH needed to cover next maturity obligations.
    function requiredCoverNext(uint256 stopAt) external view returns (uint256 required);

    /// @notice Get the admin-configured target ratio for stETH staking (basis points).
    /// @return Target percentage of stakeable funds to hold as stETH (0-10000).
    function rewardStakeTargetBps() external view returns (uint16);
}

/// @notice Minimal interface for BURNIE coin vault escrow.
interface IVaultEscrowCoin {
    /// @notice Mint BURNIE to vault escrow for bond jackpot rewards.
    /// @param amount BURNIE amount to mint and escrow.
    function vaultEscrow(uint256 amount) external;
}

/// @notice Minimal interface for Lido stETH interactions.
interface IStETHLite {
    /// @notice Get stETH balance of an account.
    /// @param account Address to query.
    /// @return Current stETH balance (rebases over time).
    function balanceOf(address account) external view returns (uint256);

    /// @notice Stake ETH to receive stETH.
    /// @param referral Referral address for Lido rewards (unused, pass address(0)).
    /// @return Amount of stETH shares minted.
    function submit(address referral) external payable returns (uint256);
}

/**
 * @title DegenerusGameBondModule
 * @author Burnie Degenerus
 * @notice Delegate-called module handling bond-related operations for the game.
 *
 * @dev This module is called via `delegatecall` from DegenerusGame, meaning:
 *      - All storage reads/writes operate on the game contract's storage
 *      - `address(this)` refers to the game contract, not this module
 *      - `msg.sender` is preserved from the original call to the game
 *
 * The module inherits DegenerusGameStorage to ensure identical slot layout.
 * Any storage layout changes must be synchronized across all modules.
 *
 * ## Functions
 *
 * - `bondUpkeep`: Called during pregame (state 1) to distribute yield and fund bonds
 * - `yieldPool`: View helper to calculate untracked surplus (solvency buffer)
 * - `stakeForTargetRatio`: Stake excess ETH into Lido stETH for yield generation
 * - `drainToBonds`: Shutdown flow - transfer all assets to bonds for final resolution
 *
 * ## Yield Distribution (bondUpkeep)
 *
 * Untracked yield (assets - obligations) is distributed as:
 * - 25% → Bonds (first to cover shortfall in bondPool, remainder to vault)
 * - 5%  → Reward pool (future jackpot funding)
 * - 70% → Remains as untracked solvency buffer
 *
 * Additionally, 5% of lastPrizePool (in BURNIE) is minted for bond jackpots.
 *
 * ## Solvency Model
 *
 * The game maintains solvency via:
 * - Tracked obligations: currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool + specials
 * - Assets: ETH balance + stETH balance
 * - Invariant: assets >= obligations (enforced by never crediting more than received)
 * - Buffer: untracked surplus grows from yield and provides safety margin
 */
contract DegenerusGameBondModule is DegenerusGameStorage {
    /// @notice Minimum ETH amount for Lido staking (Lido has deposit minimums).
    uint256 private constant MIN_STAKE = 0.01 ether;

    /**
     * @notice Handle bond funding and yield distribution during pregame maintenance.
     * @dev Called via delegatecall from DegenerusGame during state 1 (pregame).
     *      Executes once per level transition to:
     *      1. Calculate yield (untracked surplus)
     *      2. Distribute yield to bonds and reward pool
     *      3. Mint BURNIE for bond jackpots
     *      4. Sweep excess bondPool to vault
     *
     * @param bondsAddr Address of the DegenerusBonds contract.
     * @param stethAddr Address of the Lido stETH contract.
     * @param coinAddr Address of the DegenerusCoin contract.
     * @param rngWord VRF entropy word for bond jackpot resolution.
     *
     * ## Yield Distribution Flow
     *
     * ```
     * Total Yield = (ETH + stETH) - obligations
     *
     * bondSkim (25%)  ──┬── Fill bondPool shortfall (if any)
     *                   └── Send remainder to bonds for jackpots
     *
     * rewardTopUp (5%) ──── Add to rewardPool for future jackpots
     *
     * Unallocated (70%) ─── Remains as solvency buffer
     * ```
     *
     * ## Bond Coverage Logic
     *
     * The bonds contract reports how much ETH is needed for upcoming maturities.
     * If bondPool is under-funded, yield is used to fill the gap first.
     * If bondPool is over-funded, excess is swept to the vault.
     */
    function bondUpkeep(address bondsAddr, address stethAddr, address coinAddr, uint256 rngWord) external {
        IBonds bondContract = IBonds(bondsAddr);

        // ─────────────────────────────────────────────────────────────────────
        // Step 1: Snapshot current balances and calculate yield
        // ─────────────────────────────────────────────────────────────────────

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;

        // Cache storage vars to minimize SLOADs
        uint256 bondPoolLocal = bondPool;
        uint256 rewardPoolLocal = rewardPool;

        // Sum all tracked obligations (liabilities the game owes)
        uint256 obligations = currentPrizePool + nextPrizePool + rewardPoolLocal + claimablePool + bondPoolLocal;

        // Include level-100 special pools if active (only non-zero during those windows)
        uint256 bafPool = bafHundredPool;
        if (bafPool != 0) {
            unchecked {
                obligations += bafPool;
            }
        }
        uint256 decPool = decimatorHundredPool;
        if (decPool != 0) {
            unchecked {
                obligations += decPool;
            }
        }

        // Yield = assets - obligations (the untracked solvency buffer)
        uint256 combined = ethBal + stBal;
        uint256 yieldTotal = combined > obligations ? combined - obligations : 0;

        // ─────────────────────────────────────────────────────────────────────
        // Step 2: Calculate distribution amounts
        // ─────────────────────────────────────────────────────────────────────

        // Mint 5% of lastPrizePool worth of BURNIE for bond jackpots.
        // Formula: (lastPrizePool in wei) * (BURNIE per wei at current price) / 20
        uint256 coinSlice = (lastPrizePool * PRICE_COIN_UNIT) / price;
        coinSlice = coinSlice / 20; // 5%

        // Yield distribution: 25% to bonds, 5% to reward pool
        uint256 bondSkim = yieldTotal / 4; // 25% of yield
        uint256 rewardTopUp = yieldTotal / 20; // 5% of yield

        // ─────────────────────────────────────────────────────────────────────
        // Step 3: Check bond coverage requirements and fill shortfall
        // ─────────────────────────────────────────────────────────────────────

        // Query bonds for how much ETH is needed for upcoming maturities.
        // Pass (bondPool + bondSkim) as stopAt hint for gas optimization.
        uint256 required;
        if (bondSkim == 0 && bondPoolLocal == 0) {
            // No yield and no bondPool - skip the external call
            required = 0;
        } else {
            uint256 requiredStopAt = bondPoolLocal + bondSkim;
            required = bondContract.requiredCoverNext(requiredStopAt);
        }

        // Calculate shortfall: how much bondPool is under required cover
        uint256 shortfall = required > bondPoolLocal ? required - bondPoolLocal : 0;

        // Fill shortfall from bondSkim (up to the full bondSkim amount)
        uint256 toBondPool = bondSkim < shortfall ? bondSkim : shortfall;
        if (toBondPool != 0) {
            bondPoolLocal += toBondPool;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Step 4: Send leftover yield to bonds for jackpots
        // ─────────────────────────────────────────────────────────────────────

        // Leftover = bondSkim minus what went to bondPool
        // Safe unchecked: toBondPool <= bondSkim by construction
        uint256 leftover;
        unchecked {
            leftover = bondSkim - toBondPool;
        }

        // Allocate leftover to stETH first (preferred), then ETH
        uint256 stSpend;
        uint256 ethSpend;
        if (leftover != 0) {
            uint256 remaining = leftover;
            // Prefer sending stETH to keep ETH liquid for claims
            stSpend = stBal < remaining ? stBal : remaining;
            remaining -= stSpend;
            ethSpend = ethBal < remaining ? ethBal : remaining;
        }

        // Mint BURNIE to vault escrow (bonds will pull from escrow)
        if (coinSlice != 0) {
            IVaultEscrowCoin(coinAddr).vaultEscrow(coinSlice);
        }

        // Send to bonds: ETH (as value), BURNIE amount, stETH amount, RNG word
        bondContract.payBonds{value: ethSpend}(coinSlice, stSpend, rngWord);

        // Add yield slice to reward pool for future jackpots
        if (rewardTopUp != 0) {
            rewardPoolLocal += rewardTopUp;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Step 5: Sweep excess bondPool to vault
        // ─────────────────────────────────────────────────────────────────────

        // If bondPool exceeds required cover, send excess to vault via bonds.
        // This prevents over-accumulation and routes surplus to creator.
        if (bondPoolLocal > required) {
            uint256 excess = bondPoolLocal - required;

            // Re-read balances (may have changed from payBonds call above)
            uint256 stBalLocal = IStETHLite(stethAddr).balanceOf(address(this));
            uint256 ethBalLocal = address(this).balance;

            // Allocate excess: prefer stETH, then ETH
            uint256 stSend;
            uint256 ethSend;
            uint256 remaining = excess;
            stSend = stBalLocal < remaining ? stBalLocal : remaining;
            remaining -= stSend;
            ethSend = ethBalLocal < remaining ? ethBalLocal : remaining;

            if (stSend != 0 || ethSend != 0) {
                // payBonds with coinAmount=0 and rngWord=0 routes to vault sweep
                bondContract.payBonds{value: ethSend}(0, stSend, 0);
                bondPoolLocal -= (stSend + ethSend);
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Step 6: Commit storage updates (single SSTORE per changed var)
        // ─────────────────────────────────────────────────────────────────────

        if (bondPoolLocal != bondPool) {
            bondPool = bondPoolLocal;
        }
        if (rewardPoolLocal != rewardPool) {
            rewardPool = rewardPoolLocal;
        }
    }

    /**
     * @notice Calculate untracked funds (the solvency buffer).
     * @dev View function to compute: (ETH + stETH) - all tracked obligations.
     *      This surplus exists because:
     *      - stETH rebases upward from Lido yield
     *      - Bond deposits with trackPool=false add assets without liabilities
     *      - Rounding dust accumulates over time
     *
     *      The yield pool provides a safety margin ensuring the game can always
     *      pay its obligations, even if individual pools are temporarily depleted.
     *
     * @param stethAddr Address of the Lido stETH contract.
     * @return total Untracked balance (0 if obligations exceed assets).
     */
    function yieldPool(address stethAddr) public view returns (uint256 total) {
        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;

        // Sum all tracked obligations
        uint256 obligations = currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool;

        // Include level-100 special pools (only non-zero during those windows)
        uint256 bafPool = bafHundredPool;
        if (bafPool != 0) {
            unchecked {
                obligations += bafPool;
            }
        }
        uint256 decPool = decimatorHundredPool;
        if (decPool != 0) {
            unchecked {
                obligations += decPool;
            }
        }

        // Yield = assets - obligations (never negative)
        uint256 combined = ethBal + stBal;
        total = combined > obligations ? combined - obligations : 0;
    }

    /**
     * @notice Stake excess ETH into Lido stETH to earn yield.
     * @dev Called via delegatecall during state transitions. Stakes ETH into Lido
     *      to approach the admin-configured target ratio of stETH holdings.
     *
     *      The staking is conservative:
     *      - Reserves claimablePool in ETH for immediate player withdrawals
     *      - Only stakes if we're below target ratio
     *      - Minimum stake of 0.01 ETH (Lido requirement)
     *      - Skips levels 99/0 to avoid 100-level boundary complications
     *      - Silently fails if Lido submission reverts (doesn't block game)
     *
     * @param bondsAddr Address of bonds contract (to query target ratio).
     * @param stethAddr Address of the Lido stETH contract.
     * @param lvl Current game level.
     *
     * ## Target Ratio
     *
     * Admin configures targetBps (0-10000) on bonds contract.
     * - 0 = staking disabled
     * - 5000 = target 50% stETH / 50% ETH
     * - 10000 = target 100% stETH (except claimable reserve)
     *
     * ## Why Stake?
     *
     * stETH earns Lido staking rewards (~3-5% APY), which:
     * - Grows the yield pool (untracked surplus)
     * - Increases solvency buffer over time
     * - Provides additional funding for jackpots via bondUpkeep distribution
     */
    function stakeForTargetRatio(address bondsAddr, address stethAddr, uint24 lvl) external {
        // Skip at 100-level cycle boundaries to avoid complications during special events
        uint24 cycle = lvl % 100;
        if (cycle == 99 || cycle == 0) return;

        // Query admin-configured target ratio from bonds
        uint16 targetBps = IBonds(bondsAddr).rewardStakeTargetBps();
        if (targetBps == 0) return; // Staking disabled
        if (targetBps > 10_000) return; // Invalid config guard

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        if (ethBal == 0) return; // Nothing to stake

        // ─────────────────────────────────────────────────────────────────────
        // Reserve ETH for claimable withdrawals (must stay liquid)
        // ─────────────────────────────────────────────────────────────────────

        uint256 ethReserve = claimablePool;
        if (ethBal <= ethReserve) return; // All ETH needed for claims
        uint256 ethStakeable = ethBal - ethReserve;

        // ─────────────────────────────────────────────────────────────────────
        // Calculate target stETH amount based on stakeable funds
        // ─────────────────────────────────────────────────────────────────────

        uint256 totalStakeable = stBal + ethStakeable;
        uint256 targetSt = (totalStakeable * uint256(targetBps)) / 10_000;

        // Already at or above target - no staking needed
        if (targetSt <= stBal) return;

        uint256 needed = targetSt - stBal;

        // Stake the minimum of (needed, available)
        uint256 stakeAmt = needed < ethStakeable ? needed : ethStakeable;
        if (stakeAmt < MIN_STAKE) return; // Below Lido minimum

        // ─────────────────────────────────────────────────────────────────────
        // Submit to Lido (wrapped in try/catch to avoid blocking game)
        // ─────────────────────────────────────────────────────────────────────

        try IStETHLite(stethAddr).submit{value: stakeAmt}(address(0)) returns (uint256) {
            // Success - stETH balance increases, ETH balance decreases.
            // No explicit accounting needed: the game tracks obligations,
            // and stETH is treated as equivalent to ETH for solvency.
        } catch {
            // Lido submission failed (e.g., paused, rate limited).
            // Swallow the error to avoid blocking advanceGame.
            // Staking will retry on next level transition.
        }
    }

    /**
     * @notice Execute game-over shutdown: drain all assets to bonds.
     * @dev Called via delegatecall when game-over conditions are met:
     *      - 365 days inactive after a level started, OR
     *      - ~2.5 years from deploy if game never started
     *
     *      This is a one-way operation that:
     *      1. Notifies bonds of shutdown (enables their resolution flow)
     *      2. Zeros all game pools (prevents further credits)
     *      3. Transfers ALL ETH + stETH to bonds for final distribution
     *
     *      After this call:
     *      - Game enters state 0 (shutdown)
     *      - Bonds resolves maturities oldest-first with available funds
     *      - Players have 1 year to claim from bonds
     *      - Remainder swept to vault after grace period
     *
     * @param bondsAddr Address of the DegenerusBonds contract.
     * @param stethAddr Address of the Lido stETH contract.
     *
     * ## Important: Unclaimed Winnings
     *
     * Setting claimablePool = 0 means any unclaimed player winnings are
     * transferred to bonds. Players should claim before shutdown.
     * The ~1 year warning period (from first inactivity signs) gives
     * ample time to claim.
     *
     * ## Post-Shutdown Flow (in Bonds)
     *
     * ```
     * notifyGameOver() → gameOverStarted = true
     *                  → disables new deposits/burns
     *                  → enables gameOver() resolution
     *
     * gameOver()       → resolves maturities in order
     *                  → partial payouts if funds insufficient
     *                  → marks remaining series as resolved
     *
     * sweepExpiredPools() → (1 year later) sends remainder to vault
     * ```
     */
    function drainToBonds(address bondsAddr, address stethAddr) external {
        IBonds bondContract = IBonds(bondsAddr);

        // Signal shutdown to bonds (enables their resolution flow)
        bondContract.notifyGameOver();

        // ─────────────────────────────────────────────────────────────────────
        // Zero all game pools to prevent any further credits
        // ─────────────────────────────────────────────────────────────────────

        // Set flag first to block any bond-related game operations
        bondGameOver = true;

        // Zero all tracked liability pools
        bondPool = 0;
        currentPrizePool = 0;
        nextPrizePool = 0;
        rewardPool = 0;
        claimablePool = 0; // Note: unclaimed player winnings go to bonds
        decimatorHundredPool = 0;
        bafHundredPool = 0;
        dailyJackpotBase = 0;

        // ─────────────────────────────────────────────────────────────────────
        // Transfer ALL remaining assets to bonds
        // ─────────────────────────────────────────────────────────────────────

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;

        // payBonds receives all ETH (via value) and stETH (via parameter)
        // coinAmount=0, rngWord=0 since this is a shutdown transfer
        bondContract.payBonds{value: ethBal}(0, stBal, 0);
    }
}
