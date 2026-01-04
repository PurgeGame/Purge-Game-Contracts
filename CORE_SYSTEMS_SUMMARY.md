# Degenerus: Simple Summary

Plain-English basics of how the game works.

---

## The Big Idea

- Players put ETH into the game by buying gamepieces or MAPs (BURNIE buys burn tokens and don't add ETH)
- That ETH becomes prize pots
- There is no hidden "house" wallet that can take it
- Winners get paid only by the game rules

---

## The Game Loop

### 1. Purchase Phase
Players buy gamepieces with ETH or BURNIE. The game must raise enough ETH to hit a target before the next phase opens.

### 2. Burn Phase
Players burn gamepieces to get tickets for jackpots. When one trait runs out (or hits 1 on L%10=7), the level ends and a winner is picked.

### 3. Next Level
The loop continues.

---

## Gamepieces & Traits

- Each gamepiece has 4 traits
- Burning a gamepiece lowers the count for its traits and gives you jackpot tickets
- If any trait count hits zero (or 1 on L%10=7), that trait is "exterminated" and the level ends

---

## Jackpots

- **Daily jackpots** run during the burn phase
- **Carryover jackpots** reward next-level tickets early
- **MAPs** cost 1/4 of a gamepiece and give one trait ticket + level jackpot entry
- Some jackpot rewards are paid as MAP tickets; the MAP cost is routed into `nextPrizePool`

---

## BURNIE Token

- You do **NOT** get guaranteed BURNIE when you buy gamepieces
- Buying with ETH gives you coinflip credits
- Coinflip is about 50/50: win to claim BURNIE, lose and credits are gone
- Spending BURNIE on gamepieces or MAPs burns it permanently

---

## Bonds

- Some money goes into bonds that pay out at future levels
- Bonds use a two-lane system: one lane wins, one loses (high variance)
- This rewards people who keep the game progressing

---

## Fairness & Safety

- Randomness comes from Chainlink VRF (auditable on-chain)
- If the game is inactive for a long time, it shuts down and funds flow to bonds
- No admin can withdraw the prize pools

---

## In Short

1. Buy gamepieces or MAPs
2. Burn gamepieces to get tickets and try to end the level
3. Jackpots and bond payouts are high variance: big wins possible, nothing guaranteed
