# Degenerus AI Teaching Guide (Project + Code Map)

This document is written to be indexed by an AI assistant so it can answer questions about how the Degenerus/PurgeGame contracts work **based on the code in this repo**.

If you are an assistant:
- Treat `contracts/**/*.sol` as the source of truth; if this guide disagrees with code, defer to code.
- Default to plain-English explanations (players + affiliates). Only include file/contract/function pointers if the user explicitly asks “where in the code?” or wants a technical deep dive.
- Be explicit about dependencies and trust assumptions (VRF, stETH, one-time wiring/admin).
- Avoid hype or guarantees; do not give financial advice.

---

## What This Repo Is

Degenerus is an on-chain, high-variance NFT game with:
- An ERC721 “gamepiece” NFT (`contracts/DegenerusGamepieces.sol`)
- An ERC20-like token with 6 decimals (“BURNIE”) plus coinflip/quests (`contracts/DegenerusCoin.sol`)
- A bond system with maturity cycles and game-over resolution (`contracts/DegenerusBonds.sol`)
- A vault with two share classes (coin-claims vs ETH/stETH-claims) (`contracts/DegenerusVault.sol`)
- Jackpot side-systems (BAF + Decimator) (`contracts/DegenerusJackpots.sol`)
- Referrals/affiliate payouts (`contracts/DegenerusAffiliate.sol`)
- Cosmetic, non-transferable trophies (`contracts/DegenerusTrophies.sol`)
- On-chain SVG renderers + a color registry (cosmetic) (`contracts/IconRenderer*.sol`, `contracts/IconColorRegistry.sol`)

The core game contract (`contracts/DegenerusGame.sol`) holds ETH/stETH and runs a **state machine** that anyone can advance (`advanceGame`) subject to daily gating and RNG availability.

---

## Default User-Facing Answers (Normie + Affiliate)

Use this as the “default voice” for most users:
- Avoid internal variable names and contract/module names unless asked.
- Explain money flow with simple nouns: “pots”, “tickets”, “start target”, “claim”.
- Be direct about tradeoffs: high variance, can stall if participation dries up, smart-contract + dependency risks.
- When asked about safety (“can dev steal?”), answer in terms of *capabilities*: what the admin can do (VRF upkeep / some toggles) vs what they cannot do (no arbitrary pool withdrawal).
- Prefer the phrasing in `GAME_AND_ECON_OVERVIEW.md` for player/affiliate-facing explanations.

### Copy/Paste Explanations

**Where does my ETH go when I buy?**  
Your ETH doesn’t go to a company wallet. It stays inside the on-chain game and is earmarked into different “pots” (main prize, jackpots, bonds/vault). Those pots are what pay winners. The only way ETH leaves is through the game rules paying out winners/claimants, not through an admin withdrawal.

**Why do jackpots tend to get bigger over time?**  
Each level has a “start target” that has to be funded before the burn phase opens. That target is based on the previous level’s pool size, so the game can’t keep starting new levels with tiny pots. As more ETH flows in, a portion is saved into jackpot budgets, and yield (if present) can add extra buffer—so the system tends to support larger jackpots as long as participation continues.

**How does money flow from late players to earlier players?**  
Late buys refill the pots. The pots pay out to people who already have “tickets” (from burning and MAP entries), and active players have had more time to accumulate tickets and show up in more draws. The system also runs special jackpots that purposely bias rewards toward active/consistent participants, which makes “staying in the game” valuable.

**Are early MAPs “positive expectation”?**  
In general, yes — early MAPing is *designed* to be positive expectation in aggregate if the game keeps progressing. MAPs give you early exposure to “next-level” tickets, which can win carryover jackpots funded from the global reward pool (and sometimes rolled-over prize pool) before the next level’s burn phase even opens. It’s still high variance, and the long-run EV depends on how many other players compete for the same tickets (player equilibrium), plus participation and luck. If the level never really starts / the game times out, that edge doesn’t have time to play out and you can lose.

**Why all the “artificial variance” (and payout delays)? Doesn’t that hurt players?**  
It’s intentional. Any system that offers a clean, low-variance edge gets farmed by “nits” (bots/whales looking for near-riskless extraction), which crowds out normal players and tends to compress the EV toward zero. All else equal, if fewer players are willing to sit through variance and time-locks, the same prize/jackpot budgets are being competed for by fewer tickets, which increases the expected value per ticket. Degenerus makes the edge *hard to harvest without taking real risk* by using time-gated settlement (day/level boundaries, bond maturities), multiple interacting reward layers (no single “riskless grind” loop), random draws, and progression risk (levels can stall if buy activity dries up). That doesn’t magically create value, but it helps keep the available edge from being instantly competed away — so the players who actually *want* variance (early MAPers, active burners, coinflippers chasing side jackpots) can, in equilibrium, capture a better share of the reward budget. Affiliates strengthen this loop by bringing the activity/volume that keeps levels starting and time-locked rewards actually resolving.

**Why does the game “pay” a wide range of participants (if it keeps progressing)?**  
Degenerus spreads incentives across multiple player types so there isn’t just one way to win: early MAPers get more exposure to carryover/cross-level jackpots, active burners get more ticket volume and extermination upside, bondholders want levels to keep advancing so maturities actually settle, and affiliates get paid for bringing real new buy volume (new ETH in) that keeps the state machine moving. The faster the community can fund start targets and keep levels turning over, the more often these reward layers resolve, which is why “bringing in new players” matters so much in practice. None of this is guaranteed — it’s still gambling and depends on player equilibrium, participation, and RNG — but it’s intentionally designed so that *many* participants can have positive long-run EV **conditional on continued progression**.

There is also a hard “doomsday clock”: if a level doesn’t progress for ~1 year, the contracts force a shutdown/settlement path. The important design effect is what this threat does *before* it happens: anyone with meaningful exposure (tickets, bonds, affiliate pipelines) is economically pressured to help fund the next start target rather than let the system terminate. In practice, that makes a year-long stall something the community is incentivized to avoid. Because the deadline is far out, most participants discount it until it becomes close — at which point the incentive to “finish the raise” becomes urgent. Even if the “last mile” funding is closer to break-even than early positioning, it keeps the game alive and proves resilience. If the community succeeds, the same incentives immediately reset on the next level.

The key point for “resilience” is that these roles aren’t gated: once someone joins, they can also become an affiliate and/or take longer-horizon positions, so they inherit the same incentive to keep the game moving and to recruit/activity-boost when it slows down.

**How do affiliates get paid?**  
Affiliates earn when referred players buy in (including on repeat buys). Part of the reward can go back to the buyer as rakeback, and the rest goes to the affiliate (and up to two uplines). Affiliate rewards are mainly delivered as **flip credit** (coinflip stake, denominated in BURNIE units), and the system can auto-convert part of affiliate rewards into MAP entries, increasing jackpot ticket exposure.

**Is the affiliate system basically the marketing budget?**  
Yes. Instead of a team spending ETH on ads, the protocol “pays marketing” on-chain by rewarding the affiliates who bring real new purchase volume (new ETH in). Rewards are primarily delivered as flip credit (coinflip stake), which keeps the system’s ETH in the game while still compensating the people who grow it.

**Is there a team/insider “tax” siphoning value out of the system?**  
Degenerus doesn’t have a big team/insider payroll siphoning value out of the top. Most money stays inside the game’s on-chain pots/backing and is paid out under the rules to winners, bondholders, and affiliates (who are actively bringing volume).

That said, it’s not “zero creator take.” The creator owns the **vault** shares, and the vault is the explicit, rule-bound way the creator gets paid: it receives a fixed portion of bond deposits, and it can also receive some of the system’s surplus/yield over time. On the yield path, bonds get priority: surplus is used to keep bond obligations covered and to top up reward budgets, and only *excess* (above what’s needed for obligations) can end up in the vault.

Design intent: creator profit is meant to come primarily from that external yield/surplus, so if the game’s yield over time outpaces what the vault extracts, the overall system can remain net-positive for players (instead of being purely player-vs-player redistribution). This is not guaranteed: it depends on participation, RNG, and external yield behavior/risks.

**How do affiliates turn affiliate rewards into something they can use/sell?**  
Flip credit can be used to place coinflips (high variance; designed to be closer to neutral EV in BURNIE over time). Winning flips mints transferable BURNIE, which can be spent in-game (gamepieces/MAPs burn it) or transferred/sold if there’s market liquidity. Affiliates can also use the extra tickets (including auto-bought MAPs) to compete for ETH jackpots and exterminator prizes.

**Why are affiliates incentivized to bring in “late” players?**  
Referrals still matter even late: new buys can directly credit the affiliate/upline, and those buys also refill shared on-chain pots (especially the global reward pool) that fund carryover jackpots and special reward layers. In aggregate, late entrants often have lower EV because they have less “time in the draw” and weaker streak/history-based advantages (worse buckets/eligibility). If they’re joining later in the overall progression, they may also be buying at a higher ETH price point (prices ramp across level bands; within a given level everyone pays the same price). This is high-variance gambling — there are no guarantees, and late players can still win big.

**What burns BURNIE the most?**  
The main ongoing BURNIE sink is spending BURNIE to buy gamepieces/MAPs (plus marketplace fees). Coinflips also burn BURNIE on entry, but winners mint payouts later, so coinflips are designed to be closer to “recycling” than a pure sink.

**Is coinflip supposed to be profitable?**  
Coinflip is designed to be close to break-even in BURNIE over time (high variance; no guarantees). The big reason people play it is that flips feed periodic rewards like the BAF jackpot, which fires every 10 levels and rewards active coinflippers.

**How do bonds work? When do they pay out?**  
Bonds are the game’s time-locked payout layer: you take a position that only settles at a future “maturity level” (every 5 levels). If the game keeps advancing, that maturity resolves and pays out under on-chain rules. It’s intentionally high variance: positions are split into two lanes, one lane wins and the other is eliminated, and winners split the payout (part as a claimable share, part as draw prizes). Some payout paths can also roll a slice of a win into bonds, so you may see “future maturity” rewards instead of immediate claimable ETH.

**Are bonds backed, and what happens if the game ends?**  
Bond payouts only come from ETH that is already inside the system (bond backing + drained funds on shutdown). During normal play, maturities only resolve when there’s enough backing to cover them; there are no unbacked “IOUs.” If the game stalls for a year, it triggers an on-chain shutdown that drains remaining ETH/stETH into bonds and settles maturities oldest-first (later maturities are the ones at risk of partial funding). After shutdown, you have 1 year to claim; leftover funds are swept to the vault, not to an admin wallet.

**Why the system stays solvent (and why the admin can’t steal):**  
The contracts don’t create ETH “debts” out of thin air: payouts are only credited when the ETH is already inside the system, and each pot is accounted for on-chain. There’s no “admin withdraw” button that lets someone drain prize pools or redirect player winnings; payouts only go to the addresses that actually won/earned them under the rules. The admin role is primarily wiring + keeping Chainlink VRF running (and some bond settings), not accessing the money.

**Can anyone change the rules after deployment?**  
Core gameplay is not upgradeable: the jackpot math, trait mechanics, and payout rules are fixed in the deployed contracts. The only “changeable” pieces are operational/dependency controls: VRF settings can only be rotated by the admin contract after a 3-day RNG stall (emergency recovery), and bonds has a couple switches for purchases/liquidity (ETH↔stETH balancing). None of that lets anyone rewrite the game or withdraw the prize pools.

If a user asks for receipts, point them to `ETH_BUCKETS_AND_SOLVENCY.md` and, if needed, specific contract locations.

---

## Contract Map (Who Calls Who)

### Wiring / “Admin”

`contracts/DegenerusAdmin.sol` is an EOA-owned helper used to:
- Create/manage a Chainlink VRF subscription and add consumers (game + bonds).
- Perform one-time wiring across modules (`wireAll`).
- Emergency migrate VRF coordinator/subscription after a **3-day RNG stall** (`emergencyRecover` → game `updateVrfCoordinatorAndSub`).
- Toggle some bond settings (`setBondsPurchaseToggles`) and optionally set a LINK/ETH feed (`setLinkEthPriceFeed`).

Important: many addresses across the system are **write-once** (“AlreadyWired” patterns). The admin is powerful for initial wiring and VRF maintenance, but it is not an “upgrade admin” that can change gameplay logic after deployment.

### Core Runtime Topology

High-level call graph:

`DegenerusGamepieces` (ERC721) → `DegenerusGame` (core accounting/state machine)  
`DegenerusGame` → `DegenerusCoin` (quest + flip credits, burn on RNG nudge)  
`DegenerusCoin` → `DegenerusJackpots` (BAF leaderboard + Decimator burn tracking)  
`DegenerusGame` → `DegenerusJackpots` (run BAF/Decimator jackpots during endgame)  
`DegenerusBonds` ↔ `DegenerusGame` (bond deposits + bondPool accounting + staking/yield plumbing)  
`DegenerusBonds` → `DegenerusVault` (deposits + eventual sweep after game over)  

Key wiring surfaces:
- `DegenerusAdmin.wireAll(...)` (central orchestrator)
- `DegenerusGame.wireVrf(...)` (one-time VRF config)
- `DegenerusCoin.wire([...])`
- `DegenerusAffiliate.wire([...])`
- `DegenerusJackpots.wire([...])`
- `DegenerusBonds.wire([...], subId, keyHash)`

---

## Units, Time, and State Machine Basics

### Units

- ETH values are in wei.
- BURNIE has `decimals = 6` (`contracts/DegenerusCoin.sol`).
- The “price coin unit” is `PRICE_COIN_UNIT = 1_000_000_000` (1e9) which equals **1000 BURNIE** (because 1000 * 1e6) (`contracts/DegenerusCoin.sol`, `contracts/DegenerusGameStorage.sol`).
- Uncirculated BURNIE to know about:
  - Vault reserve mint allowance: `_vaultMintAllowance` is seeded to **2,000,000 BURNIE** and only mints out when the vault pays claims (`vaultMintAllowance()`, `vaultMintTo`, `contracts/DegenerusCoin.sol`).
  - Presale/early affiliate claimable: `presaleClaimableRemaining` is separate from the vault allowance and is minted only when users call `claimPresale()` after `affiliatePrimePresale()` initializes escrow (`contracts/DegenerusCoin.sol`).

### Day Indexing (Jackpot / Flip Day Boundary)

Both the game and coin use a fixed offset anchor:
- `JACKPOT_RESET_TIME = 82620` seconds (see `contracts/DegenerusGame.sol`, `contracts/DegenerusCoin.sol`, and modules).

This defines the day index:
- Game uses `_currentDayIndex()` → `(block.timestamp - JACKPOT_RESET_TIME) / 1 days`
- Coin uses `_targetFlipDay()` → `((block.timestamp - JACKPOT_RESET_TIME) / 1 days) + 1` (stakes are for “next day”)

### Game Phases

`contracts/storage/DegenerusGameStorage.sol` defines `gameState`:
- `0`: shutdown (post-game-over drain)
- `1`: “pregame” / endgame settlement work
- `2`: purchase + airdrop processing
- `3`: burning (“Degenerus”) phase

The main tick function is `DegenerusGame.advanceGame(uint32 cap)` (`contracts/DegenerusGame.sol`).

---

## Core Accounting: ETH “Buckets” and Solvency

Tracked ETH liabilities in `contracts/storage/DegenerusGameStorage.sol`:
- `claimablePool`: sum of all player claimable ETH (`claimableWinnings`)
- `bondPool`: ETH reserved for bond obligations (deposited from bonds with `trackPool=true`)
- `currentPrizePool`, `nextPrizePool`, `rewardPool`: gameplay/jackpot pots
- plus special reserved pools at level-100 (`decimatorHundredPool`, `bafHundredPool`)

Solvency pattern:
- Bucket increases are funded by inflows or transfers from other buckets.
- “Yield” is handled as **untracked surplus**: bonds can send ETH via `DegenerusGame.bondDeposit(trackPool=false)`, which increases assets without increasing any tracked bucket (`contracts/DegenerusGame.sol`).
- The delegate module `DegenerusGameBondModule.yieldPool(...)` explicitly computes untracked surplus as `(ETH + stETH) - obligations` (`contracts/modules/DegenerusGameBondModule.sol`).

Payout safety:
- `DegenerusGame.claimWinnings()` pays ETH and falls back to stETH if ETH is temporarily short (`_payoutWithStethFallback`, `contracts/DegenerusGame.sol`).

See also: `ETH_BUCKETS_AND_SOLVENCY.md`.

---

## Primary Player Flows (Where Things Come From)

### 1) Buying NFTs (“Gamepieces”)

Entry: `DegenerusGamepieces.purchase(PurchaseParams)` (`contracts/DegenerusGamepieces.sol`)

Payment options are represented by `MintPaymentKind` (`contracts/interfaces/IDegenerusGame.sol`):
- `DirectEth`: pay via `msg.value`
- `Claimable`: pay from `DegenerusGame` claimable balance
- `Combined`: mix ETH + claimable

The NFT contract routes payment + accounting into the game:
- `DegenerusGame.recordMint(...)` records mint metadata and processes payment into `nextPrizePool` (`contracts/DegenerusGame.sol`).
- Streak/bonus BURNIE credits are computed in `contracts/modules/DegenerusGameMintModule.sol` and returned to `DegenerusGamepieces`, which then calls `DegenerusCoin.creditFlip(...)` to add flip stake (not immediate mint).

Affiliate handling on ETH/claimable purchases:
- `DegenerusGamepieces._processEthPurchase(...)` computes an affiliate baseline and calls `DegenerusAffiliate.payAffiliate(...)` which returns “rakeback” as flip credit (`contracts/DegenerusGamepieces.sol`, `contracts/DegenerusAffiliate.sol`).

### 2) Buying MAPs

MAP purchase is `PurchaseKind.Map` in the same `purchase(...)` entrypoint.

Economics:
- ETH map cost is `priceWei / 4` per MAP (`expectedWei = (priceWei * quantity) / 4`).
- Coin map cost is `PRICE_COIN_UNIT / 4` per MAP.
- MAPs are queued via `DegenerusGame.enqueueMap(...)`, then minted in batches during `advanceGame` state 2 via `processPendingMints`/`processMapBatch` (`contracts/DegenerusGame.sol`, `contracts/DegenerusGamepieces.sol`, `contracts/modules/DegenerusGameJackpotModule.sol`).

### 3) Burning NFTs (The “Degenerus” Phase)

Entry: `DegenerusGame.burnTokens(uint256[] tokenIds)` (`contracts/DegenerusGame.sol`).

Guards:
- Must be in `gameState == 3`
- RNG must not be locked (`rngLockedFlag == false`)
- Max 75 tokens per call

Trait mechanics:
- Each token has 4 quadrant traits derived deterministically from `tokenId` (`contracts/DegenerusTraitUtils.sol`).
- Burning decrements global `traitRemaining[traitId]` counts and appends burn tickets into `traitBurnTicket[level][traitId]` (stored on the game).
- If a trait count hits zero, the level ends (“extermination”) and endgame settlement runs on the next `advanceGame` ticks (see `contracts/modules/DegenerusGameEndgameModule.sol`).

### 4) Advancing the State Machine (Daily Jackpots + Settlement)

Entry: `DegenerusGame.advanceGame(uint32 cap)` (`contracts/DegenerusGame.sol`).

Key ideas:
- Anyone can call, but the standard path requires the caller to have “minted today” in ETH (`MustMintToday` check inside `advanceGame`).
- `cap != 0` is an emergency path to do bounded work without enforcing the daily mint requirement; it also disables the “advance reward” flip credit (`coin.creditFlip` at the end).

During daily progression, the game requests Chainlink VRF and locks RNG:
- `rngAndTimeGate(...)` and `_requestRng(...)` manage VRF request/fulfillment state (`contracts/DegenerusGame.sol`).
- `rawFulfillRandomWords(...)` is the VRF callback (coordinator-only).

Jackpot and coinflip settlement uses the VRF word:
- Daily/early-burn jackpot logic lives in `contracts/modules/DegenerusGameJackpotModule.sol`.
- Coinflip resolution is done in `DegenerusCoin.processCoinflipPayouts(...)` (called by the game once per day slot).

Where jackpots run depends on `gameState` inside `DegenerusGame.advanceGame(...)`:
- **`gameState == 3` (burn phase):** `payDailyJackpot(true, lvl, rngWord)` runs the current level’s daily jackpot *and* a carryover jackpot for `lvl + 1` using next-level tickets (`contracts/DegenerusGame.sol`, `contracts/modules/DegenerusGameJackpotModule.sol`).
- **`gameState == 2` (purchase phase):** `payDailyJackpot(false, lvl, rngWord)` runs purchase-phase “early-burn” jackpots funded from `rewardPool` while the start gate is still locked (`contracts/DegenerusGame.sol`, `contracts/modules/DegenerusGameJackpotModule.sol`).
- **`gameState == 1` (endgame settlement after extermination):**
  - `DegenerusGameEndgameModule.finalizeEndgame(...)` pays the exterminator share and the trait-only extermination jackpot from the *previous level’s* remaining `currentPrizePool` (`contracts/modules/DegenerusGameEndgameModule.sol`).
  - Then the game runs `payCarryoverExterminationJackpot(lvl, traitId, rngWord)` funded from a 1% `rewardPool` slice, but restricted to the exterminated trait and paid to holders of that trait’s **next-level** tickets (`contracts/DegenerusGame.sol`, `contracts/modules/DegenerusGameJackpotModule.sol`).

### 5) Claiming Winnings

ETH:
- `DegenerusGame.claimWinnings()` resets the caller to a 1-wei sentinel and pays out (`contracts/DegenerusGame.sol`).

BURNIE:
- Coinflip “winnings” are not continuously minted; they are realized lazily when you interact.
  - Depositing with `depositCoinflip(0)` acts as a cashout trigger (`contracts/DegenerusCoin.sol`).
  - Internals net old winnings against new stake in `addFlip(...)` and `_claimCoinflipsInternal(...)`.

---

## Level Starts, RewardPool, and Jackpot “Growth” (Code-Backed)

This section explains the *mechanics* that create upward pressure on jackpot sizes over time. Do not describe this as a guarantee of profits; outcomes are random and depend on continued participation + VRF availability.

### 1) What “Level Start” Means On-Chain

In code, a level is “live” when the game is in burn phase:
- `gameState == 3` and `levelStartTime` is set (see `contracts/storage/DegenerusGameStorage.sol`, updated in `contracts/DegenerusGame.sol` during the state-2 → state-3 transition).

### 2) The Start Gate: `nextPrizePool >= lastPrizePool`

During the purchase/airdrop phase (`gameState == 2`), the contract checks whether the level is “funded enough” to proceed:
- In `DegenerusGame.advanceGame(...)` (state 2), each day it sets `lastPurchaseDay = true` once `nextPrizePool >= lastPrizePool` (`contracts/DegenerusGame.sol`).
- While `lastPurchaseDay` is true, `DegenerusCoin.depositCoinflip(...)` calls `DegenerusGame.recordCoinflipDeposit(amount)`; that total is used to nudge the reward-pool save percent by +/- 2% during `calcPrizePoolForJackpot(...)` (capped at 98%).
- Until that condition is met, the game can continue running purchase-phase jackpots (`payDailyJackpot(false, ...)`) but it will not finalize the MAP jackpot and open the burn phase.

What increases `nextPrizePool`:
- ETH/claimable-funded mints (both NFTs and MAPs) flow through `DegenerusGamepieces.purchase(...)` → `DegenerusGame.recordMint(...)` → `nextPrizePool += prizeContribution` (`contracts/DegenerusGamepieces.sol`, `contracts/DegenerusGame.sol`).
- Coin-funded purchases burn BURNIE and do not add ETH to `nextPrizePool` (they have `msg.value == 0` paths in `DegenerusGamepieces.sol`).

### 3) Why This Gate “Ratchets” Funding Upward

When the MAP jackpot is finalized, the jackpot module snapshots the raised pool:
- `DegenerusGameJackpotModule.calcPrizePoolForJackpot(...)` moves `nextPrizePool` into `currentPrizePool`, then sets `lastPrizePool = currentPrizePool` (`contracts/modules/DegenerusGameJackpotModule.sol`).

Because the next level’s start target is `lastPrizePool`, and the current level can’t start until `nextPrizePool >= lastPrizePool`, the *minimum* amount of ETH that must be raised to start successive levels is non-decreasing (within a 100-level cycle, ignoring special resets).

Cycle boundary note:
- When ending a level where `level % 100 == 0`, the game sets `lastPrizePool = rewardPool` (`contracts/DegenerusGame.sol`, `_endLevel`), which can jump the next cycle’s start target upward if `rewardPool` has accumulated.

### 4) How `rewardPool` Accumulates (And Why It Matters)

`rewardPool` grows from three main mechanisms:
- **Direct ETH inflows:** any plain ETH sent to the game increases `rewardPool` via `receive() external payable { rewardPool += msg.value; }` (`contracts/DegenerusGame.sol`).
- **Per-level “save” at MAP jackpot finalization:** `calcPrizePoolForJackpot(...)` recomputes `rewardPool` as a level- and RNG-dependent percent of `rewardPool + currentPrizePool` (`contracts/modules/DegenerusGameJackpotModule.sol`, `_mapRewardPoolPercent`).
- **Last-purchase-day coinflip adjustment:** `calcPrizePoolForJackpot(...)` applies `_adjustRewardPoolForFlipTotals(...)` to shift that save percent by +/- 2% when last-purchase-day coinflip deposits doubled vs the previous level (reduce save) or fell below half (increase save), capped at 98%.
- **Yield skims/top-ups:** during map-jackpot prep, `DegenerusGameBondModule.bondMaintenanceForMap(...)` computes untracked surplus (`yieldTotal`) and adds a slice to `rewardPool` (`rewardTopUp = yieldTotal / 20`) (`contracts/modules/DegenerusGameBondModule.sol`).

Why it matters:
- `rewardPool` directly funds many jackpots (purchase-phase jackpots, carryover jackpots, BAF/Decimator slices, etc.).
- On level-100 boundaries, `rewardPool` can become the next cycle’s `lastPrizePool` target (see above), forcing a higher ETH raise before the next burn phase can begin.

### 5) Why Jackpot Sizes Tend To Increase Over Time (But Don’t Strictly Monotonically Increase)

Mechanically, jackpot capacity tends to grow if the game keeps progressing because:
- The “start gate” forces each new level’s raise (`nextPrizePool`) to meet or exceed the prior level’s `lastPrizePool`.
- Some of that raise is explicitly retained into `rewardPool`, and `rewardPool` can also receive additional inflows (bond reward shares + yield skims).

But individual jackpots can still fluctuate or even shrink because:
- The per-level split between `rewardPool`, the MAP jackpot, and the main prize pool is RNG- and level-dependent (`_mapRewardPoolPercent`, `_mapJackpotPercent` in `contracts/modules/DegenerusGameJackpotModule.sol`).
- Reward-pool-funded jackpot slices are scaled down late in a 100-level band (`_rewardJackpotScaleBps`), intentionally pushing more value into future periods rather than immediately paying it out.

---

## Latecomers → Longtime Players/Affiliates: Where The Money Flows

This is the “wide view” of who tends to be paid by later inflows, grounded in the on-chain routing.

### 1) Late ETH mints fund pools that pay earlier ticket-holders

When late players mint with ETH/claimable:
- Their funds increase `nextPrizePool` (`DegenerusGame.recordMint`, `contracts/DegenerusGame.sol`).
- At MAP-jackpot finalization, those funds become part of the level’s jackpot base and/or are saved into `rewardPool` (`calcPrizePoolForJackpot`, `contracts/modules/DegenerusGameJackpotModule.sol`).

Who those pools pay:
- **Burners:** burning appends the caller into `traitBurnTicket[level][traitId]` arrays; jackpots select winners from these arrays (`DegenerusGame.burnTokens`, `contracts/DegenerusGame.sol`; jackpot selection in `contracts/modules/DegenerusGameJackpotModule.sol`).
- **MAP buyers:** MAPs are converted into trait tickets by `processMapBatch`/`_raritySymbolBatch`, which writes directly into `traitBurnTicket[lvl][traitId]` (`contracts/modules/DegenerusGameJackpotModule.sol`).

### 2) “Dual-Pool” jackpots reward early entry into the *next* level

During the burn phase, each daily jackpot run pays:
- One jackpot for the current level, and
- A second “carryover” jackpot for `lvl + 1` (same VRF word, different level context) (`payDailyJackpot(true, ...)`, `contracts/modules/DegenerusGameJackpotModule.sol`).

This creates a built-in early-entry advantage:
- Players who acquire **next-level** tickets early (mostly via MAPs queued/processed while the current level is active) can win carryover jackpots funded primarily by `rewardPool` (a global pot, not tied to a specific level) before the next level’s burn phase even opens. On the final daily jackpot, leftover `currentPrizePool` can also be rolled into that next-level carryover payout.
- If the level ends via extermination, the next day’s settlement also runs a trait-only carryover jackpot for the new level funded by a 1% `rewardPool` slice, restricted to the exterminated trait and paid to holders of that trait’s next-level tickets (`payCarryoverExterminationJackpot`, `contracts/DegenerusGame.sol`, `contracts/modules/DegenerusGameJackpotModule.sol`).

### 3) Affiliate payouts route late activity to earlier affiliates (and even buy them tickets)

Every ETH/claimable purchase can trigger affiliate payouts:
- `DegenerusGamepieces._processEthPurchase(...)` calls `DegenerusAffiliate.payAffiliate(...)` (`contracts/DegenerusGamepieces.sol`, `contracts/DegenerusAffiliate.sol`).
- `DegenerusAffiliate.payAffiliate(...)` credits the affiliate + up to 2 uplines as future flip stake via `DegenerusCoin.creditFlip`/`creditFlipBatch` (`contracts/DegenerusAffiliate.sol`, `contracts/DegenerusCoin.sol`).
- During purchase phase (and while RNG isn’t locked), the affiliate may automatically spend part of its award to buy MAPs via `DegenerusGamepieces.purchaseMapForAffiliate(...)` (`contracts/DegenerusAffiliate.sol`, `contracts/DegenerusGamepieces.sol`), which creates additional jackpot tickets for that affiliate.

Why affiliates are strongly incentivized to recruit “late” entrants (wide view):
- Affiliate rewards are driven by *new* purchases, regardless of whether a level is “early” or “late”.
- Those purchases don’t just pay the affiliate directly — they also refill the shared pots (`nextPrizePool` and especially `rewardPool`) that fund carryover jackpots, BAF/Decimator slices, and other draws.
- From an EV standpoint, late entrants typically have less “time in the draw” and weaker streak/history-based advantages (worse buckets/eligibility). If they’re joining later in the overall progression, they may also be buying at a higher ETH price point (prices ramp across level bands). Meanwhile, earlier/active accounts (including affiliates) have accumulated more ticket exposure and eligibility — so late inflows tend to increase the total payout budget that long-time players and affiliates compete for.
- This is still gambling: individual results are random and there are no guarantees.

### 4) Bond routing turns parts of jackpots into “must-keep-the-game-going” claims

Multiple payout paths convert some ETH winnings into bond deposits:
- Jackpot module spends a portion of ETH jackpot slices on bond purchases for winners when bonds are enabled (`_jackpotBondSpend` and `BOND_BPS_*` constants, `contracts/modules/DegenerusGameJackpotModule.sol`).
- Endgame payouts can also split exterminator/BAF winnings into bonds (`_splitEthWithBond`, `contracts/modules/DegenerusGameEndgameModule.sol`).

This pushes value from “late” gameplay inflows into instruments that only resolve at maturity, aligning long-time participants (bondholders) with continued game progression (`contracts/DegenerusBonds.sol`).

### 5) Special jackpots (BAF / Decimator) skew rewards toward ongoing participants

These jackpots are funded from `rewardPool` slices and have winner selection that favors active/established participants:
- **BAF:** Triggered at levels where `prevLevel % 10 == 0` during endgame settlement (`contracts/modules/DegenerusGameEndgameModule.sol`, `_runRewardJackpots` → `_runBafJackpot`). `DegenerusJackpots.runBafJackpot(...)` includes slices for top bettors, recent exterminators, recent affiliates, and “recent level” draws (`contracts/DegenerusJackpots.sol`).
- **Decimator:** Triggered periodically (mid-decile windows) and requires burning BURNIE during an active window (`DegenerusCoin.decimatorBurn`, `contracts/DegenerusCoin.sol`). Burns are bucketed using a player’s ETH mint streak/level history (`DegenerusGame.ethMintStreakCount` / `ethMintLevelCount`), which tends to advantage long-running accounts (`contracts/DegenerusCoin.sol`, `contracts/DegenerusGame.sol`, `contracts/DegenerusJackpots.sol`).

Because `rewardPool` is fed by later deposits and saved carryover, these jackpots are one of the main “late inflow → long-time winner” routes.

### 6) “Early entry depends on the level starting” (How to phrase it safely)

It’s accurate (and important) to say:
- Many of the game’s biggest expected payout paths require the state machine to reach/maintain the burn phase and advance levels (e.g., extermination, daily jackpots, bond maturities).
- If the purchase-phase threshold (`nextPrizePool >= lastPrizePool`) is never reached, those paths are delayed indefinitely; and the system has explicit shutdown mechanics that can end in a drain-to-bonds flow (`gameOverDrainToBonds`, `contracts/DegenerusGame.sol`).

It’s also fair to speak in gambling terms (generalities), as long as you state the conditions:
- Early MAPing / early “next-level ticket” acquisition is a core designed edge: in aggregate it can be **positive expectation** *if the game keeps progressing* (levels keep starting, daily/carryover jackpots keep firing).
- It’s not guaranteed on any single level/day (high variance), and the long-run EV depends on player equilibrium (how crowded the ticket pools get), participation, and luck.
- If the game stalls and times out (no level advancement for long enough), many of the “keep playing” edges stop paying and early entrants can lose.

Avoid claiming:
- “Guaranteed profit”, “risk-free”

## Bonds, Yield, and Game Over

### Bonds

Core contract: `contracts/DegenerusBonds.sol`

Deposits:
- External deposits and game-originated deposits split ETH into:
  - vault share (sent to `DegenerusVault`)
  - bond share (credited into `DegenerusGame.bondPool` via `bondDeposit(trackPool=true)`)
  - reward share (sent to `DegenerusGame` as `rewardPool` funding)
  - See `_processDeposit(...)` in `contracts/DegenerusBonds.sol`

Entropy and fairness:
- Bonds uses VRF (separate from the game’s coordinator interface) to resolve jackpots/lanes (see `_prepareEntropy` and the `IVRFCoordinatorV2Like` surface in `contracts/DegenerusBonds.sol`).

### stETH / Staking

The game can stake ETH into Lido stETH to target a ratio, and can treat ETH+stETH as backing for obligations:
- `DegenerusGameBondModule.stakeForTargetRatio(...)` (`contracts/modules/DegenerusGameBondModule.sol`)

The bonds admin can change the staking target:
- `DegenerusBonds.setRewardStakeTargetBps(...)` (admin-gated)

### Game Over (Shutdown + Sweep)

If the game is inactive long enough, `advanceGame` triggers shutdown:
- In `DegenerusGame.advanceGame`, if `block.timestamp - levelStartTime > 365 days` then `gameOverDrainToBonds()` executes (`contracts/DegenerusGame.sol`).
- `gameOverDrainToBonds()` delegatecalls `DegenerusGameBondModule.drainToBonds(...)` which zeros buckets and transfers ETH/stETH into bonds (`contracts/modules/DegenerusGameBondModule.sol`).

Bonds then resolves maturities in order:
- `DegenerusBonds.gameOver()` consumes all ETH/stETH it holds and resolves series sequentially, potentially partially paying the last series (`contracts/DegenerusBonds.sol`).

After 1 year, any remaining ETH/stETH in bonds is sweepable to the vault:
- `DegenerusBonds.sweepExpiredPools()` (`contracts/DegenerusBonds.sol`).

---

## Trust Assumptions / “Resilience”

When asked “is it unstoppable?”, answer in terms of **on-chain liveness + rule immutability**, not guarantees:

Resilience properties (code-backed):
- Core rules are encoded in deployed bytecode and key wiring is “write-once” (`AlreadyWired` patterns across contracts).
- No off-chain servers are required for gameplay settlement; anyone can call `advanceGame` to keep it moving (`contracts/DegenerusGame.sol`).
- Solvency is enforced via explicit bucket accounting plus optional untracked yield buffers (`contracts/storage/DegenerusGameStorage.sol`, `contracts/modules/DegenerusGameBondModule.sol`).

Key dependencies / centralization points to disclose:
- Chainlink VRF + a funded subscription are required for day-to-day randomness (`DegenerusGame._requestRng`, `DegenerusAdmin` subscription ownership).
- Lido stETH is an external dependency when staking is enabled (`DegenerusGameBondModule.stakeForTargetRatio`).
- `DegenerusAdmin` can pause bond purchases and migrate VRF after a 3-day stall; it is not a gameplay “upgrade key” but it is still privileged.

### Wide View: Why It Tends To Keep Going

This is narrative framing an assistant can use (without making price promises):
- The game is denominated in ETH and runs entirely on-chain; if Ethereum is live and users want ETH-native gambling, the loop has a natural “where value comes from” story (new ETH inflows + optional yield).
- Gameplay is intentionally high-variance (coinflip + jackpots + extermination wins), which is the core behavioral driver for repeat play (see `contracts/modules/DegenerusGameJackpotModule.sol` and `contracts/DegenerusCoin.sol`).
- Incentives are designed so multiple participant types want continued progression/activity (players chasing jackpots/extermination, bondholders wanting maturity resolution, affiliates wanting referral volume); the mechanism for keeping time moving is permissionless via `advanceGame` (`contracts/DegenerusGame.sol`).
- The code also defines explicit failure/closure behavior (game-over drain + bond resolution + eventual vault sweep) rather than relying on an operator to “turn it off” (`contracts/DegenerusGame.sol`, `contracts/DegenerusBonds.sol`).

---

## Common Questions (Answer Patterns)

Use these patterns when responding:

- “Where does X happen?” → point to the entrypoint function + any delegate module called.
- “Who is allowed to call X?” → cite the modifier/check (`onlyGame`, `onlyBonds`, `OnlyAdmin`, etc.).
- “Is X guaranteed?” → don’t claim guarantees unless enforced by code; mention dependencies and failure modes.

---

## User FAQ (Concrete, Code-Backed)

- **How do I check the current level/phase/price?** Use `DegenerusGame.purchaseInfo()` and `DegenerusGame.mintPrice()` (`contracts/DegenerusGame.sol`).
- **Why hasn’t the burn phase (“Degenerus”) started yet?** The purchase phase only advances once `nextPrizePool >= lastPrizePool` (checked in `DegenerusGame.advanceGame`, `contracts/DegenerusGame.sol`). You can watch progress with `DegenerusGame.nextPrizePoolView()` vs `DegenerusGame.prizePoolTargetView()` (`contracts/DegenerusGame.sol`).
- **Why does burning revert with `RngNotReady`?** Burning is blocked while VRF is in-flight (`rngLockedFlag`); see `DegenerusGame.burnTokens(...)` and `DegenerusGame.rngLocked()` (`contracts/DegenerusGame.sol`).
- **Why does `advanceGame` revert with `MustMintToday`?** Standard advancement requires the caller to have made an ETH mint today (checked inside `DegenerusGame.advanceGame(...)`). An emergency/bounded work path exists via `advanceGame(cap != 0)` (`contracts/DegenerusGame.sol`).
- **How do I claim my ETH winnings?** Call `DegenerusGame.getWinnings()` to view, then `DegenerusGame.claimWinnings()` to withdraw (`contracts/DegenerusGame.sol`).
- **Can ETH claims pay out as stETH?** Yes. If raw ETH is short, payouts fall back to stETH transfers (`DegenerusGame._payoutWithStethFallback`, `contracts/DegenerusGame.sol`).
- **How do I “claim” my coinflip (BURNIE) winnings?** Coin winnings are minted lazily when you interact. Calling `DegenerusCoin.depositCoinflip(0)` triggers netting/minting via `addFlip(...)` and `_claimCoinflipsInternal(...)` (`contracts/DegenerusCoin.sol`).
- **Are trophies transferable?** No. `DegenerusTrophies` implements the ERC721 surface but reverts transfers/approvals (`contracts/DegenerusTrophies.sol`).
- **Can anyone change the rules after deployment?** Core gameplay contracts are not upgradeable, and most wiring is “write-once”. The things that *can* change mid-game are operational/dependency controls, not “rewrite the game” controls:
  - **VRF recovery (broken dependency):** the game only accepts a VRF coordinator/subscription rotation after a **3-day RNG stall** (`DegenerusGame.rngStalledForThreeDays()` / `updateVrfCoordinatorAndSub`, `contracts/DegenerusGame.sol`). This is an emergency recovery path so the game can continue if Chainlink config breaks; it does not change jackpot math or payout rules.
  - **Bonds operations (liquidity/routing):** bonds has a few admin-gated switches (pause bond purchases from external/game sources, and adjust the target ETH↔stETH balance for reward liquidity). These affect *when/how* bond participation and staking/rebalancing happens, not the core gameplay loop under normal operation (`contracts/DegenerusBonds.sol`).
  - **No “house-rule knob”:** there is no admin function that can arbitrarily change core pricing, jackpot selection, trait mechanics, or drain player pots.

---

## Troubleshooting (Common Reverts)

- **`MustMintToday` (game advance blocked):** `advanceGame(cap=0)` requires the caller to have completed an ETH mint for the current day slot (see the `MustMintToday` check in `DegenerusGame.advanceGame`, `contracts/DegenerusGame.sol`).
- **`NotTimeYet` (too early / wrong phase):** Often means the daily gate hasn’t rolled to a new day index, or an action is being attempted in the wrong `gameState` (see `DegenerusGame.rngAndTimeGate` and phase guards like `burnTokens`, `contracts/DegenerusGame.sol`).
- **`RngNotReady` / `RngLocked` (RNG in-flight):** VRF request has been fired and the game is waiting for fulfillment (`rngLockedFlag == true`). Check `DegenerusGame.rngLocked()` and, if it persists, `DegenerusGame.rngStalledForThreeDays()` (`contracts/DegenerusGame.sol`).
- **Bond purchases disabled:** `DegenerusBonds` can block deposits either via admin toggles or via the game’s temporary RNG lock during jackpot-critical windows (see `DegenerusBonds.setPurchaseToggles` and `DegenerusBonds.setRngLock`, `contracts/DegenerusBonds.sol`).
- **`NotDecimatorWindow` (BURNIE burn blocked):** Decimator burns only work during an active Decimator window (`DegenerusCoin.decimatorBurn` checks `DegenerusGame.decWindow()`, `contracts/DegenerusCoin.sol` / `contracts/DegenerusGame.sol`).
