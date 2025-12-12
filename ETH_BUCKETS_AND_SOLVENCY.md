# ETH Buckets & Solvency Analysis

## 1. The ETH Buckets (Liabilities)
The `DegenerusGame` contract tracks its ETH liabilities in distinct "buckets" (variables). The sum of these buckets represents the total ETH the contract *owes* to various actors or systems.

### A. Player Liabilities (Immediate Debt)
*   **`claimablePool`**: The aggregate amount of ETH currently owed to players (winnings from jackpots, bonds, affiliates, etc. that haven't been withdrawn yet).
    *   *Solvency:* Backed 1:1 by ETH/stETH. This number only goes up when funds are internally transferred from another valid pool (e.g., `currentPrizePool` -> `claimablePool`) or deposited explicitly for payouts.

### B. Bond Liabilities (System Debt)
*   **`bondPool`**: ETH deposited by the `DegenerusBonds` contract to back bond positions.
    *   *Solvency:* This is purely principal. Yield earned on this ETH is *not* added to this bucket (it falls through as "untracked surplus"), ensuring the contract always has *more* assets than this liability requires.

### C. Gameplay Rewards (Game Debt)
*   **`currentPrizePool`**: The active pot for the current level's Exterminator and Extermination Jackpot.
*   **`nextPrizePool`**: Accumulating pot for the *next* level (funded by current level mints).
*   **`rewardPool`**: A general-purpose "slush fund" for Daily Jackpots, BAFs, and other side-prizes.
    *   *Solvency:* These are funded directly by minting revenue (`msg.value`) or yield injections. They cannot grow without matching ETH inflow.

### D. Reserved/Special Pools
*   **`decimatorHundredPool`** & **`bafHundredPool`**: Temporary holding buckets for level-100 special jackpots, carved out of `rewardPool` when needed.

---

## 2. Why Solvency is Guaranteed

The system is designed to always be **Over-Collateralized**.

### The Equation
$$ \text{Total Assets} \ge \text{Total Liabilities} $$
$$ (\text{ETH Balance} + \text{stETH Balance}) \ge (\text{claimable} + \text{bond} + \text{prize} + \text{reward}) $$

### Mechanism 1: 1:1 Inflow Matching
Every bucket increase is strictly coupled with an ETH inflow:
*   **Mints:** `nextPrizePool` increases by exactly `msg.value`.
*   **Bond Deposits:** `bondPool` increases by exactly `msg.value`.
*   **Jackpot Allocations:** Pools are only created by subtracting from other valid pools (e.g., `rewardPool` -> `decimatorHundredPool`).

### Mechanism 2: The "Untracked Surplus" (Yield)
The "Secret Sauce" of solvency is how **Yield** is handled:
1.  ETH staked in Lido earns yield (stETH balance grows).
2.  When `DegenerusBonds` sends yield to the game, it calls `bondDeposit(trackPool=false)`.
3.  **Result:** The contract's *Assets* (ETH Balance) increase, but **NO Liability Bucket increases**.
4.  This creates a **permanent solvency buffer**. This "untracked ETH" sits in the contract balance, silently backing all other pools. If `claimablePool` needs to pay out, it draws from `address(this).balance`—which includes this surplus.

### Mechanism 3: stETH Interchange
The contract treats `stETH` and `ETH` as fungible for solvency.
*   If the contract runs low on raw ETH for payouts, it can swap/withdraw stETH (via the Bonds contract or Vault) to cover liabilities.
*   The `_payoutWithStethFallback` function ensures that if raw ETH is insufficient, stETH is transferred directly to the player to settle the debt.

### Conclusion
The buckets will **always be solvent** because:
1.  **Liabilities never exceed inflows.**
2.  **Assets grow independently of liabilities** via yield.
3.  **Accounting is closed-loop:** ETH never leaves a bucket without being paid out or moved to another valid bucket.
