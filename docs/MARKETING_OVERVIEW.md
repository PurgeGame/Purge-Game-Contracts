# Degenerus: Incentive Architecture & Economic Design

## The Core Thesis

Degenerus is built for the crypto participant who keeps chasing high-variance upside, even though a lot of what they are really buying is fraud risk. It keeps the variance and removes the rug: the rules are on-chain and immutable after launch, accounting is public, and randomness is verifiably fair. You are still taking risk, but you are not taking "will the team steal the money" as part of that risk.

Most projects are built to maximize revenue from the widest possible audience, which means promising free money and guaranteed returns. Degenerus takes the opposite approach. It is designed for a narrower audience that enjoys skill expression like poker, while still being simple enough to feel like a fair lottery ticket. That focus defines the mission: honest high-variance play, real skill expression, and transparent payouts.

The concept borrows the high-variance appeal of classic scams and crypto Ponzis but removes the impossible promises. It guarantees only what code can enforce: jackpots fire on schedule, prizes pay out when triggered, and some players lose because this is a gambling game with strategy, not a yield machine. The product is honest volatility.

That volatility is intentional. Coinflips are 50/50, bond outcomes eliminate half of positions, and affiliate rewards arrive as coinflip stakes instead of fixed payouts. Returns are tied to level progression rather than time, and external yield subsidizes prize pools so winners can collectively receive more than losers put in. The protocol earns from growth rather than extracting from player winnings.

---

## Multiple Ways to Win

There is a jackpot draw every single day, regardless of phase. Purchase phase, burn phase, every day has some kind of jackpot firing.

The daily jackpot fires once per day during burn phase until level completes. When you earn a ticket, that ticket enters every remaining daily draw for that level. Burn on day one with eight draws remaining, your ticket is in all eight. Burn on day seven, only days seven and eight. This is why early participation matters.

Tickets come from burning gamepieces and buying MAPs. Each burn generates tickets for both current and next level. MAPs purchased during purchase phase also receive next-level tickets, meaning MAP buyers accumulate entries before the next level begins. Winners are selected via Chainlink VRF.

The extermination prize is the big one. When someone reduces a trait count to zero, they win a substantial portion of the prize pool and the Trophy.

The level jackpot fires at end of each purchase phase, weighted by MAP holdings. Carryover jackpots fire after extermination and pay next-level ticket holders from the reward pool. The BAF jackpot fires every ten levels. The Decimator jackpot opens periodically; players burn BURNIE to enter, bucketed by coinflip streak.

---

## Why the Game Sustains Itself

All ETH entering the system flows directly into prize pools, jackpots, and reserves governed by immutable smart contracts. Every mechanism is designed to make depositing ETH the rational choice at every stage.

The flow is straightforward: deposits are algorithmically split into prize pools, bond backing, and yield reserves; jackpots and maturities pay back out to active participants; and external yield refills reward pools between cycles. Some jackpots pay part of winnings as MAP tickets, and that MAP cost rolls into the next prize pool. Money flows in this direction because every role benefits from progression: early players get more draws, bondholders need levels to advance, affiliates earn on volume, and some rewards recycle back into play through auto-bought MAPs and DGNRS burns.

For players, early entry is always advantaged. Early burns enter more jackpot drawings with fewer competitors. Early MAPs capture next-level tickets before burn phase opens. Waiting is costly.

For bondholders, deposits are a bet on game progression. Their payout depends on reaching maturity, so they're incentivized to promote the game. If it stalls, they lose.

For affiliates, every referral generates coinflip stakes. Unlike one-time bonuses, affiliate earnings scale with ongoing activity. They have reason to keep their network engaged level after level.

These incentives reinforce each other. Players deposit ETH, which grows prize pools. Larger prizes attract more players, which makes bondholders' maturities safer. Bondholders deposit, which funds rewards, which makes jackpots bigger. Bigger jackpots give affiliates something to recruit around. At no point does anyone benefit from the game slowing down.

The timing incentives are stacked to guarantee progression. Players who MAP on the first day of the previous level's burn phase split extra jackpots from the reward pool and always have the highest EV of any MAP buyers—designed to be generally positive. Affiliates receive higher rewards for recruiting latecomers, so there's always someone pushing to fill the remaining spots. As funding approaches the target, players can see that the main game will start soon, creating urgency to participate before burn phase opens and early-entry advantages disappear. If none of that is enough, the year-long inactivity timeout means early players must push the level forward or lose their entire investment. Every equilibrium points in the same direction.

Friction isn't eliminated, it's monetized. Complicated onboarding? That's affiliate revenue for someone who can explain it. The affiliate system lets smoothing friction for others become a full-time job. You earn from their activity continuously, creating a distributed workforce with clear incentive to reduce every barrier to entry.

---

## The Game: Competitive Elimination

Each level follows a fixed cycle: purchase phase, then burn phase. The level must hit a funding target before play begins.

Gamepieces are on-chain tokens with four visual traits. Each trait exists in a pool shared across all gamepieces. Owning a gamepiece lets you compete for extermination, but doesn't give jackpot tickets by itself. Tickets are only earned when you burn. When you burn, you reduce each of its four trait counts by one and receive tickets for both current and next level's daily jackpots. The goal: reduce any single trait's count to zero. That's an extermination.

When a trait hits zero, the player who burned the final piece wins the extermination prize (a significant slice of the prize pool), receives a Trophy NFT, and earns the title of Exterminator. The game advances to the next level and the cycle restarts. All remaining gamepieces are destroyed. If you didn't burn before extermination, you get nothing. If no extermination happens after roughly ten daily jackpots, the level times out and auto-advances.

Gamepieces are negative EV for players with poor strategy. Burning randomly without understanding trait counts, coordination, or timing will lose money. This is intentional. Gamepieces are tools for skilled play. However, coordinated burns can direct the extermination prize to specific players, and strategic burn timing influences jackpot draws. Players who understand the game extract significant value that casual participants cannot.

One exception: if fewer than 5,000 gamepieces are purchased, buyers receive multiples of their purchase price back, becoming positive EV even without strategy. That value comes from MAP buyers who funded pools without competing for extermination.

The strategic depth comes from competing incentives. There is a race between 256 different trait teams, and only one team gets the extermination payout. At the same time, the exterminator payout is heavily weighted in a mathematically complex way, which turns the endgame into a negotiation game. Players are balancing coordination, timing, and the social layer of "who lets who win" rather than just optimizing for raw trait counts.

MAPs (Mini-Airdrop Passes) offer a different value proposition. Unlike gamepieces, MAPs give jackpot tickets immediately upon purchase. No burning required. They cost one quarter of a gamepiece and provide a trait ticket (contributes to pool but can't exterminate), entry into the level jackpot, and next-level daily jackpot tickets if purchased early. MAPs are pure jackpot exposure: lottery tickets, not the elimination game.

That split is intentional. Gamepieces are heavy PvP with high skill expression: you are competing against other skilled players for extermination and timing advantages. MAPs are mostly gambling, with light skill around timing purchases and staying active to accumulate more draws. The systems interact, but the prizes are mostly segregated. PvP specialists win by outplaying other PvPers, not by siphoning MAP gamblers; MAP buyers are competing primarily against other MAP buyers.

---

## Cycles and Compounding Rewards

The game operates on nested cycles. Each ten-level stretch forms a bond cycle, with bonds sold in the first five levels and maturing once the pool is funded. Every hundred levels, prices and the trait pool reset. These cycles repeat indefinitely.

Early entry is heavily rewarded. Bond multipliers favor early depositors. Tickets earned early accumulate across more draws, compounding expected value the longer you stay engaged. Benefits are intentionally skewed toward actions that strengthen the system: funding pools, advancing levels, and keeping activity high.

Players who engage with every aspect (gamepieces, MAPs, coinflips, bonds) capture value that single-strategy players miss. Affiliate earnings feed coinflip stakes. Coinflip wins produce BURNIE, which can purchase gamepieces without adding ETH to pools. Early burns generate next-level tickets. Each mechanism connects to others.

The daily quest system reinforces breadth and consistency. Complete quests to earn points that feed a personal multiplier, amplifying coinflip stakes, affiliate earnings, and jackpot ticket weight. Maintain a streak and you earn an additional bonus, so daily engagement earns extra returns. Quests rotate to push broad engagement. The multiplier boosts secondary rewards, not core jackpot odds, so new players aren't hopelessly outmatched by veterans.

---

## The BURNIE Token

BURNIE isn't purchased; it's won. ETH purchases credit coinflip stakes, and each day a single verifiably random coinflip runs for the entire community. Everyone with stakes is on the same side, roughly 50% win rate. Winners receive minted BURNIE; losers forfeit stakes. Every BURNIE in circulation represents a won bet.

Players can spend BURNIE on "nudges" to shift the upcoming flip toward heads or tails. Nudging doesn't change expected value; the payout ratio adjusts to keep EV constant. It lets players buy control over timing without buying an edge. BURNIE spent on nudges is burned.

BURNIE has value because it can purchase gamepieces and MAPs (burned, not added to prize pools), pay marketplace fees, enter the Decimator jackpot, and influence flip outcomes. When you buy a gamepiece with BURNIE instead of ETH, the BURNIE is destroyed forever, creating constant deflationary pressure.

The coinflip system has built-in incentives for aggressive play. A recycling bonus rewards rolling winnings forward. A bounty rewards setting all-time high stakes. A portion feeds the BAF jackpot. Players who let it ride are rewarded.

---

## Bonds

Bonds are time-locked positions that pay out at milestones. They are a direct bet that the game keeps moving forward.

Bonds are sold during the first five levels of each ten-level cycle. Deposits create a weighted score (boosted by the player multiplier) that enters a series of DGNRS jackpot draws during the early part of the cycle (up to five runs). Those draws mint a liquid bond token, DGNRS. That token is the middle layer: you can hold it, trade it, or burn it to lock into the maturity payout.

Burning DGNRS places you into one of two deterministic lanes for that maturity. When the maturity hits and the pool is funded, one lane wins and the other is eliminated. The winning lane splits the pot: half goes pro-rata by burned amount (Decimator), half is distributed as draw prizes. During live play, some of the small draw buckets are automatically used to buy MAPs for winners, cycling rewards back into the game loop.

Early participation compounds. Buying bonds early means your score is present in more DGNRS draws. Burning DGNRS early gives more chances to win the ongoing coinflip jackpots that pull from the burn lanes, and burns made while the series is still minting also add to your DGNRS jackpot score, effectively recycling back into the current drawings.

Bondholders are incentivized to promote the game. If it stalls before maturity, they lose. Their deposits add ETH flowing into bond backing, reward pools, and yield generation.

---

## Affiliates

Players create an affiliate code with their chosen rakeback percentage and earn rewards when referrals make purchases. Rewards extend up to two levels of upline. Earnings arrive as coinflip stakes with potential to multiply via BURNIE wins.

Affiliate earnings are tied to volume, not jackpot wins. Affiliates benefit from consistent activity rather than lucky one-offs. The affiliate system creates an army of promoters whose economic interests are directly aligned with game growth.

---

## Trust Architecture

The game operates with immutable rules, Chainlink VRF for all randomness, on-chain prize pool accounting, and public smart contracts. What doesn't exist: admin withdrawal functions, hidden RNG manipulation, off-chain fund custody, upgrade keys, or house edge skimming from player prizes.

This makes the system effectively indestructible. There is no admin kill switch, no backdoor to pause payouts, and no reliance on the team to keep it running. Any player can advance the game state, and funds are always held by the contracts themselves. The only intentional shutdown path is the inactivity timeout; if the game stalls long enough, it drains to bondholders in a defined order.

Every random outcome uses Chainlink VRF. The randomness comes from an external oracle, provably unbiased. Anyone can verify any outcome. This isn't "trust us, it's fair"; it's cryptographic proof on every roll.

The protocol adds value instead of extracting it. stETH yield flows back into reward pools, meaning prize payouts can exceed the ETH players put in. Traditional games take 1-15% of every bet. Degenerus inverts this with a negative house edge.

The creator's revenue comes exclusively from stETH yield and bond sales (selling claims on future yield). No rake on winnings, no fee on pools, no hidden extraction. The creator profits when the game grows and ETH stays in the system generating yield, not when players lose. There's no incentive to rig outcomes or drain players faster.

If the game becomes inactive for roughly a year, remaining funds drain to bond maturities oldest first, then a one-year claim window opens for bondholders. Even in the worst case, funds go to participants before operators.

---

## Key Differentiators

Negative house edge: stETH yield subsidizes rewards. Verifiable fairness: Chainlink VRF, auditable on-chain. Immutable rules: can't be changed, can't be rugged. Protocol earns from growth, not extraction. Multiple entry points: gamepieces, MAPs, bonds, coinflips. Built-in affiliate system with real incentives. Self-sustaining economics designed to run indefinitely.

The game succeeds when players succeed. That alignment is the foundation of everything.

---

## Marketing Goals

This project is not trying to do mass-market direct-to-consumer marketing. The goal is to find strong "shills" and explainers with reach in gambling and crypto, then give them the clarity and tools to communicate the system. Ideal targets are creators who already talk about +EV gambling or slot mechanics, because they understand variance, edge, and timing and can frame Degenerus honestly.
