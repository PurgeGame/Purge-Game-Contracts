// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "../interfaces/DegenerusGameModuleInterfaces.sol";
import {IDegenerusGameJackpotModule} from "../interfaces/IDegenerusGameModules.sol";
import {IDegenerusBondsJackpot} from "../interfaces/IDegenerusBondsJackpot.sol";
import {IDegenerusJackpots} from "../interfaces/IDegenerusJackpots.sol";
import {IDegenerusTrophies} from "../interfaces/IDegenerusTrophies.sol";
import {IDegenerusAffiliate} from "../interfaces/IDegenerusAffiliate.sol";
import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";

/// @notice Minimal interface for queuing NFT reward mints.
interface IDegenerusGamepiecesRewards {
    /// @notice Queue reward NFT mints for a player (processed during advanceGame).
    /// @param player Address to receive the NFTs.
    /// @param quantity Number of NFTs to mint.
    function queueRewardMints(address player, uint32 quantity) external;
}

/**
 * @title DegenerusGameEndgameModule
 * @author Burnie Degenerus
 * @notice Delegate-called module handling level settlement after extermination or timeout.
 *
 * @dev This module is called via `delegatecall` from DegenerusGame during state 1 (pregame),
 *      meaning all storage reads/writes operate on the game contract's storage.
 *
 * ## When Called
 *
 * After a level ends (via extermination or timeout), the game transitions to state 1
 * and calls `finalizeEndgame()` to settle payouts before starting the next level.
 *
 * ## Settlement Flow
 *
 * ```
 * finalizeEndgame()
 *     │
 *     ├─ IF extermination occurred (not timeout):
 *     │   ├─ Mint exterminator trophy (winnings packed)
 *     │   ├─ Pay exterminator (20-40% of prize pool)
 *     │   │   └─ 25% of their share → bonds (if enabled)
 *     │   ├─ Pay extermination jackpot (trait ticket holders)
 *     │   └─ Pay purchase rewards (20% → NFT/MAP rewards for winners)
 *     │
 *     └─ IF previous level > 0:
 *         ├─ Mint affiliate trophy for top affiliate
 *         └─ Run reward jackpots:
 *             ├─ BAF (every 10 levels): 10-25% of rewardPool
 *             └─ Decimator (levels 15,25,35...85): 15% of rewardPool
 * ```
 *
 * ## Exterminator Share Calculation
 *
 * - "Big-ex" levels (14, 24, 34...): Fixed 40%
 * - All other levels: Random 20-40% (VRF-derived, 1% steps)
 *
 * ## Bond Integration
 *
 * Several payout paths route a portion to bonds:
 * - Exterminator: 25% of their share → bonds
 * - BAF top winners: 20% → bonds
 * - BAF scatter winners: remainder after MAPs → bonds (100%)
 *
 * This creates time-locked value that incentivizes continued game progression.
 */
contract DegenerusGameEndgameModule is DegenerusGameStorage {
    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted when ETH is credited to a player's claimable balance.
    /// @param player Original winner address.
    /// @param recipient Address credited (same as player).
    /// @param amount ETH amount credited.
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sentinel value indicating level ended via timeout, not extermination.
    uint16 private constant TRAIT_ID_TIMEOUT = 420;

    /// @notice Basis points of exterminator share routed to bonds (25%).
    uint16 private constant BOND_BPS_EX = 2500;

    /// @notice Basis points for bond buy on BAF top/flip/3-4 winners (20%).
    uint16 private constant BAF_TOP_BOND_BPS = 2000;

    /// @notice Basis points for bond buy on BAF scatter remainder (100%).
    uint16 private constant BAF_SCATTER_BOND_BPS = 10_000;

    /// @notice Bit offset separating top winners from scatter winners in bondMask.
    uint8 private constant BAF_BOND_MASK_OFFSET = 128;

    /// @notice Basis points of non-exterminator pool for purchase rewards (20%).
    uint16 private constant EXTERMINATION_PURCHASE_BPS = 2000;

    /// @notice Maximum winners for extermination purchase rewards.
    uint8 private constant EXTERMINATION_PURCHASE_WINNERS = 20;

    // ─────────────────────────────────────────────────────────────────────────
    // Main Entry Point
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Settle a completed level by paying exterminator, jackpots, and rewards.
     * @dev Called via delegatecall from DegenerusGame during state 1.
     *
     * @param lvl Current level index (1-based) - this is the NEW level after advancement.
     * @param rngWord VRF entropy for jackpot selection and randomization.
     * @param jackpotsAddr Address of DegenerusJackpots contract.
     * @param jackpotModuleAddr Address of jackpot module for delegatecall.
     * @param coinContract BURNIE coin contract for reward credits.
     * @param nftAddr NFT contract for queuing reward mints.
     *
     * ## State Changes
     *
     * - `currentPrizePool` → 0 (after extermination settlement)
     * - `claimablePool` += all ETH payouts
     * - `nextPrizePool` += purchase reward pool (funds next level)
     * - `rewardPool` -= BAF/Decimator jackpot spends
     * - `bondPool` += bond deposits from split payouts
     * - `airdropIndex` → 0 (reset for next level)
     *
     * ## Extermination vs Timeout
     *
     * - Extermination: `lastExterminatedTrait != 420` - full settlement with payouts
     * - Timeout: `lastExterminatedTrait == 420` - skip exterminator/jackpot payouts
     */
    function finalizeEndgame(
        uint24 lvl,
        uint256 rngWord,
        address jackpotsAddr,
        address jackpotModuleAddr,
        IDegenerusCoinModule coinContract,
        address nftAddr
    ) external {
        uint256 claimableDelta;
        uint24 prevLevel = lvl - 1; // The level that just ended
        bool hasPrevLevel = prevLevel != 0;

        // ─────────────────────────────────────────────────────────────────────
        // Extermination Settlement (if not timeout)
        // ─────────────────────────────────────────────────────────────────────

        uint16 traitRaw = lastExterminatedTrait;
        if (traitRaw != TRAIT_ID_TIMEOUT) {
            uint8 traitId = uint8(traitRaw);

            // Get exterminator address (guaranteed set when traitRaw != TRAIT_ID_TIMEOUT)
            address ex = levelExterminators[uint256(prevLevel) - 1];

            // Calculate exterminator's share (20-40% of prize pool)
            uint256 poolValue = currentPrizePool;
            uint16 exShareBps = _exterminatorShareBps(prevLevel, rngWord);
            uint256 exterminatorShare = (poolValue * exShareBps) / 10_000;

            uint96 exterminatorWinnings =
                exterminatorShare > type(uint96).max ? type(uint96).max : uint96(exterminatorShare);
            IDegenerusTrophies(trophies).mintExterminator(
                ex,
                prevLevel,
                traitId,
                exterminationInvertFlag,
                exterminatorWinnings
            );

            // Pay exterminator (with bond split)
            claimableDelta += _payExterminatorShare(ex, exterminatorShare);

            // Remaining pool goes to jackpots and purchase rewards
            uint256 jackpotPool = poolValue > exterminatorShare ? poolValue - exterminatorShare : 0;
            if (jackpotPool != 0) {
                // Split: 20% to purchase rewards, 80% to extermination jackpot
                uint256 purchasePool = (jackpotPool * EXTERMINATION_PURCHASE_BPS) / 10_000;
                uint256 exterminationPool = jackpotPool - purchasePool;

                // Round purchase pool to MAP-price multiple; remainder to trait jackpot
                uint256 mapPrice = uint256(price) / 4;
                if (mapPrice != 0 && purchasePool != 0) {
                    uint256 rounded = (purchasePool / mapPrice) * mapPrice;
                    uint256 refund = purchasePool - rounded;
                    purchasePool = rounded;
                    exterminationPool += refund;
                }

                // Pay extermination jackpot (trait-only ticket holders)
                (bool ok, bytes memory data) = jackpotModuleAddr.delegatecall(
                    abi.encodeWithSelector(
                        IDegenerusGameJackpotModule.payExterminationJackpot.selector,
                        prevLevel,
                        traitId,
                        rngWord,
                        exterminationPool,
                        coinContract
                    )
                );
                if (!ok) _revertDelegate(data);

                // Run purchase rewards (NFT/MAP distribution to winners)
                if (purchasePool != 0) {
                    _runExterminationPurchaseRewards(prevLevel, traitId, rngWord, purchasePool, nftAddr);
                }
            }

            // Clear prize pool and reset airdrop cursor
            currentPrizePool = 0;
            airdropIndex = 0;
        }

        // ─────────────────────────────────────────────────────────────────────
        // Reward Jackpots (BAF, Decimator) and Affiliate Trophy
        // ─────────────────────────────────────────────────────────────────────

        if (hasPrevLevel) {
            // Mint trophy for top affiliate of the completed level
            _maybeMintAffiliateTop(prevLevel);

            // Run BAF (every 10 levels) and Decimator (mid-decile) jackpots
            claimableDelta += _runRewardJackpots(prevLevel, rngWord, jackpotsAddr);
        }

        // ─────────────────────────────────────────────────────────────────────
        // Commit claimable pool update
        // ─────────────────────────────────────────────────────────────────────

        if (claimableDelta != 0) {
            claimablePool += claimableDelta;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reward Jackpots (BAF & Decimator)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Run BAF and Decimator jackpots based on level triggers.
     * @dev BAF fires every 10 levels, Decimator fires mid-decile.
     *
     * @param prevLevel The level that just completed.
     * @param rngWord VRF entropy for jackpot resolution.
     * @param jackpotsAddr DegenerusJackpots contract address.
     * @return claimableDelta Total ETH credited to claimable balances.
     *
     * ## BAF (Big-Ass Flip) Trigger Schedule
     *
     * | Level | Pool Source | Pool Size |
     * |-------|-------------|-----------|
     * | 10, 20, 30... | rewardPool | 10% |
     * | 50 | rewardPool | 25% |
     * | 100 | bafHundredPool | reserved amount |
     *
     * ## Decimator Trigger Schedule
     *
     * Fires at: 15, 25, 35, 45, 55, 65, 75, 85 (NOT 95)
     * Pool: 15% of rewardPool
     */
    function _runRewardJackpots(
        uint24 prevLevel,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 claimableDelta) {
        uint256 rewardPoolLocal = rewardPool;
        uint24 prevMod10 = prevLevel % 10;
        uint24 prevMod100 = prevLevel % 100;

        // ─────────────────────────────────────────────────────────────────────
        // BAF Jackpot (every 10 levels)
        // ─────────────────────────────────────────────────────────────────────

        if (prevMod10 == 0) {
            uint256 bafPoolWei;
            bool reservedBaf;

            if (prevMod100 == 0 && bafHundredPool != 0) {
                // Level 100: use reserved pool (carved out earlier)
                bafPoolWei = bafHundredPool;
                bafHundredPool = 0;
                reservedBaf = true;
            } else {
                // Regular BAF: 10% of rewardPool (25% at level 50)
                bafPoolWei = (rewardPoolLocal * (prevLevel == 50 ? 25 : 10)) / 100;
            }

            (uint256 netSpend, uint256 claimed) = _rewardJackpot(0, bafPoolWei, prevLevel, rngWord, jackpotsAddr);
            claimableDelta += claimed;

            if (reservedBaf) {
                // Reserved pool was already removed; only return refund
                uint256 refund = bafPoolWei - netSpend;
                if (refund != 0) {
                    rewardPoolLocal += refund;
                }
            } else {
                rewardPoolLocal -= netSpend;
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Decimator Jackpot (mid-decile, except 95)
        // ─────────────────────────────────────────────────────────────────────

        if (prevMod10 == 5 && prevLevel >= 15 && prevMod100 != 95) {
            // Fire decimator midway through each decile (15, 25, 35... not 95)
            uint256 decPoolWei = (rewardPoolLocal * 15) / 100;
            if (decPoolWei != 0) {
                (uint256 spend, uint256 claimed) = _rewardJackpot(1, decPoolWei, prevLevel, rngWord, jackpotsAddr);
                rewardPoolLocal -= spend;
                claimableDelta += claimed;
            }
        }

        // Commit rewardPool update
        rewardPool = rewardPoolLocal;
        return claimableDelta;
    }

    /**
     * @notice Mint trophy for the top affiliate of a completed level.
     * @param prevLevel The level that just completed.
     */
    function _maybeMintAffiliateTop(uint24 prevLevel) private {
        address affiliateAddr = affiliateProgramAddr;
        (address top, uint96 score) = IDegenerusAffiliate(affiliateAddr).affiliateTop(prevLevel);
        if (top == address(0)) return;

        address trophyAddr = trophies;
        IDegenerusTrophies(trophyAddr).mintAffiliate(top, prevLevel, score);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Exterminator Payout
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Pay the exterminator their share with bond split.
     * @dev 25% of exterminator share is routed to bonds (if enabled).
     *
     * @param ex Exterminator address.
     * @param exterminatorShare Total ETH share before bond split.
     * @return claimableDelta ETH credited to claimable balance.
     *
     * ## Payout Split
     *
     * ```
     * Exterminator Share
     *     ├─ 75% → claimable ETH
     *     └─ 25% → bonds (creates time-locked position)
     * ```
     */
    function _payExterminatorShare(address ex, uint256 exterminatorShare) private returns (uint256 claimableDelta) {
        if (exterminatorShare == 0) return 0;

        bool bondsEnabled = IDegenerusBondsJackpot(bonds).purchasesEnabled();

        // Split between ETH and bonds
        (uint256 ethPortion, uint256 splitClaimable) = _splitEthWithBond(
            ex,
            exterminatorShare,
            BOND_BPS_EX,
            bondsEnabled
        );

        // Credit ETH portion to claimable
        claimableDelta = splitClaimable + _addClaimableEth(ex, ethPortion);
    }

    /**
     * @notice Split an ETH payout between claimable and bonds.
     * @dev Used for exterminator and BAF winner payouts.
     *
     * @param winner Address receiving the payout.
     * @param amount Total ETH amount before split.
     * @param bondBps Basis points to route to bonds (e.g., 2500 = 25%).
     * @param bondsEnabled Whether bond deposits are currently accepted.
     * @return ethPortion Amount to credit as claimable ETH.
     * @return claimableDelta Additional claimable from bond operations (currently 0).
     */
    function _splitEthWithBond(
        address winner,
        uint256 amount,
        uint16 bondBps,
        bool bondsEnabled
    ) private returns (uint256 ethPortion, uint256 claimableDelta) {
        uint256 bondBudget = (amount * bondBps) / 10_000;

        ethPortion = amount;

        // If bonds disabled or zero budget, return full amount as ETH
        if (!bondsEnabled || bondBudget == 0) {
            return (ethPortion, claimableDelta);
        }

        // Deposit to bonds; reduce ETH portion on success
        if (_depositBondFromGame(bonds, winner, bondBudget)) {
            ethPortion -= bondBudget;
        }

        return (ethPortion, claimableDelta);
    }

    /**
     * @notice Deposit ETH to bonds for a beneficiary from game funds.
     * @dev Uses try/catch to avoid blocking settlement on bond failures.
     *      Adds amount/2 to bondPool on success (game-originated deposits
     *      track half as backing, unlike external deposits which track 20%).
     *
     * @param bondsAddr Bonds contract address.
     * @param beneficiary Address to credit the bond position.
     * @param amount ETH amount to deposit.
     * @return spent True if deposit succeeded.
     */
    function _depositBondFromGame(address bondsAddr, address beneficiary, uint256 amount) private returns (bool spent) {
        if (amount == 0) return false;

        try IDegenerusBondsJackpot(bondsAddr).depositFromGame(beneficiary, amount) {
            // Add half to bondPool (game-originated deposit accounting)
            uint256 bondShare = amount / 2;
            if (bondShare != 0) {
                bondPool += bondShare;
            }
            spent = true;
        } catch {
            // Bond deposit failed - continue without blocking settlement
        }
    }

    /**
     * @notice Credit ETH to a player's claimable balance.
     * @param beneficiary Address to credit.
     * @param weiAmount ETH amount to credit.
     * @return The amount credited (same as input).
     */
    function _addClaimableEth(address beneficiary, uint256 weiAmount) private returns (uint256) {
        address recipient = beneficiary;
        unchecked {
            // Safe: would require ~10^77 wei to overflow
            claimableWinnings[recipient] += weiAmount;
        }
        emit PlayerCredited(beneficiary, recipient, weiAmount);
        return weiAmount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Extermination Purchase Rewards
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Distribute NFT/MAP purchase rewards to extermination jackpot winners.
     * @dev 20% of non-exterminator prize pool is converted to NFT/MAP rewards
     *      and distributed to up to 20 random trait ticket holders.
     *
     * @param prevLevel The level that just completed.
     * @param traitId The exterminated trait ID.
     * @param rngWord VRF entropy for winner selection.
     * @param poolWei ETH amount to convert to rewards.
     * @param nftAddr NFT contract for queuing mints.
     *
     * ## Winner Selection
     *
     * - Up to 20 winners selected from trait burn ticket holders
     * - Selection uses xorshift PRNG seeded from VRF
     *
     * ## Reward Distribution
     *
     * Winners are categorized by ticket type:
     * - Burn-phase tickets (idx >= burnStart): receive full NFTs (4 MAPs = 1 NFT)
     * - MAP tickets (idx < burnStart): receive MAPs
     *
     * Leftover units (< 4 MAPs worth) go to MAP winners.
     *
     * ## Pool Handling
     *
     * The `poolWei` is added to `nextPrizePool`, effectively funding the next
     * level's prize pool while distributing NFT/MAP ownership to winners.
     */
    function _runExterminationPurchaseRewards(
        uint24 prevLevel,
        uint8 traitId,
        uint256 rngWord,
        uint256 poolWei,
        address nftAddr
    ) private {
        if (poolWei == 0) return;

        // Add to next level's prize pool (rewards are NFT/MAPs, not ETH)
        nextPrizePool += poolWei;

        // Get trait ticket holders
        address[] storage holders = traitBurnTicket[prevLevel][traitId];
        uint256 len = holders.length;
        if (len == 0) return;

        // Calculate pricing
        uint256 tokenPrice = uint256(price);
        if (tokenPrice == 0) return;
        uint256 mapPrice = tokenPrice / 4;
        if (mapPrice == 0) return;

        // Determine burn-phase ticket boundary
        // burnStart = where burn-phase tickets begin in the holders array
        uint256 burnCount = uint256(traitStartRemaining[traitId]);
        if (burnCount > len) burnCount = len;
        uint256 burnStart = len - burnCount;

        // Calculate available units and winner count
        uint256 totalUnits = poolWei / mapPrice;
        uint256 maxWinners = totalUnits;
        if (maxWinners > EXTERMINATION_PURCHASE_WINNERS) maxWinners = EXTERMINATION_PURCHASE_WINNERS;
        if (maxWinners > len) maxWinners = len;
        if (maxWinners == 0) return;

        IDegenerusGamepiecesRewards nftRewards = IDegenerusGamepiecesRewards(nftAddr);

        // ─────────────────────────────────────────────────────────────────────
        // Select winners and categorize by ticket type
        // ─────────────────────────────────────────────────────────────────────

        address[] memory winners = new address[](maxWinners);
        uint256[] memory burnIdx = new uint256[](maxWinners);  // Indices of burn-ticket winners
        uint256[] memory mapIdx = new uint256[](maxWinners);   // Indices of MAP-ticket winners
        uint256 burnWinners;
        uint256 mapWinners;
        uint256 totalBurnUnits;
        uint256 totalMapUnits;
        uint256 unitsLeft = totalUnits;

        // Seed PRNG from VRF with level/trait context
        uint256 entropy = uint256(keccak256(abi.encode(rngWord, prevLevel, traitId, totalUnits)));

        for (uint256 i; i < maxWinners; ) {
            entropy = _entropyStep(entropy);

            // Select random ticket holder
            uint256 remainingWinners = maxWinners - i;
            uint256 idx = entropy % len;
            address winner = holders[idx];
            if (winner == address(0)) {
                winner = holders[0]; // Fallback for zero-address edge case
            }

            // Calculate unit allocation for this winner
            uint256 baseUnits = unitsLeft / remainingWinners;
            uint256 extraUnits = unitsLeft % remainingWinners;
            uint256 unitBudget = baseUnits;
            if (extraUnits != 0 && (entropy % remainingWinners) < extraUnits) {
                unchecked {
                    ++unitBudget;
                }
            }
            unitsLeft -= unitBudget;

            // Store winner and categorize by ticket type
            winners[i] = winner;
            if (idx >= burnStart) {
                // Burn-phase ticket holder -> gets NFTs
                burnIdx[burnWinners++] = i;
                totalBurnUnits += unitBudget;
            } else {
                // MAP ticket holder -> gets MAPs
                mapIdx[mapWinners++] = i;
                totalMapUnits += unitBudget;
            }

            unchecked {
                ++i;
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Convert burn units to NFTs (4 MAP units = 1 NFT)
        // ─────────────────────────────────────────────────────────────────────

        uint256 leftoverUnits = totalBurnUnits % 4;
        uint256 totalTokenQty = totalBurnUnits / 4;
        totalMapUnits += leftoverUnits; // Remainder goes to MAP pool

        if (burnWinners != 0 && totalTokenQty != 0) {
            // Distribute NFTs among burn-ticket winners
            uint256 baseTokens = totalTokenQty / burnWinners;
            uint256 extraTokens = totalTokenQty % burnWinners;
            entropy = _entropyStep(entropy);
            uint256 offset = entropy % burnWinners; // Random starting point

            for (uint256 i; i < burnWinners; ) {
                uint256 idx = burnIdx[(i + offset) % burnWinners];
                uint256 qty = baseTokens + (i < extraTokens ? 1 : 0);

                // Cap at uint32 max (queue function parameter limit)
                if (qty > type(uint32).max) {
                    qty = type(uint32).max;
                }
                if (qty != 0) {
                    nftRewards.queueRewardMints(winners[idx], uint32(qty));
                }

                unchecked {
                    ++i;
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Distribute MAPs to MAP-ticket winners (or all if no MAP winners)
        // ─────────────────────────────────────────────────────────────────────

        if (totalMapUnits != 0) {
            if (mapWinners == 0) {
                // No MAP-ticket winners - distribute to all winners
                uint256 baseMaps = totalMapUnits / maxWinners;
                uint256 extraMaps = totalMapUnits % maxWinners;
                entropy = _entropyStep(entropy);
                uint256 offset = entropy % maxWinners;

                for (uint256 i; i < maxWinners; ) {
                    uint256 idx = (i + offset) % maxWinners;
                    uint256 qty = baseMaps + (i < extraMaps ? 1 : 0);
                    if (qty != 0) {
                        _queueRewardMaps(winners[idx], uint32(qty));
                    }
                    unchecked {
                        ++i;
                    }
                }
            } else {
                // Distribute to MAP-ticket winners only
                uint256 baseMaps = totalMapUnits / mapWinners;
                uint256 extraMaps = totalMapUnits % mapWinners;
                entropy = _entropyStep(entropy);
                uint256 offset = entropy % mapWinners;

                for (uint256 i; i < mapWinners; ) {
                    uint256 idx = mapIdx[(i + offset) % mapWinners];
                    uint256 qty = baseMaps + (i < extraMaps ? 1 : 0);
                    if (qty != 0) {
                        _queueRewardMaps(winners[idx], uint32(qty));
                    }
                    unchecked {
                        ++i;
                    }
                }
            }
        }
    }

    /**
     * @notice Xorshift PRNG step for deterministic pseudo-randomness.
     * @dev Standard xorshift64 algorithm. Seeded from VRF, so ultimately secure.
     * @param state Current PRNG state.
     * @return Next PRNG state.
     */
    function _entropyStep(uint256 state) private pure returns (uint256) {
        unchecked {
            state ^= state << 7;
            state ^= state >> 9;
            state ^= state << 8;
        }
        return state;
    }

    /**
     * @notice Queue MAP rewards for a player.
     * @dev Adds to pending MAP mints queue, processed during advanceGame.
     * @param buyer Address to receive MAPs.
     * @param quantity Number of MAPs to queue.
     */
    function _queueRewardMaps(address buyer, uint32 quantity) private {
        if (quantity == 0) return;

        uint32 owed = playerMapMintsOwed[buyer];
        if (owed == 0) {
            // First MAP owed - add to pending queue
            pendingMapMints.push(buyer);
        }

        unchecked {
            // Note: could overflow if same player wins massive quantities repeatedly
            playerMapMintsOwed[buyer] = owed + quantity;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reward Jackpot Dispatch
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Route a jackpot slice to the appropriate jackpot handler.
     * @param kind Jackpot type: 0 = BAF, 1 = Decimator.
     * @param poolWei ETH amount for the jackpot.
     * @param lvl Level tied to the jackpot.
     * @param rngWord VRF entropy for jackpot resolution.
     * @param jackpotsAddr DegenerusJackpots contract.
     * @return netSpend Amount of rewardPool consumed (poolWei minus refund).
     * @return claimableDelta ETH credited to claimable balances.
     */
    function _rewardJackpot(
        uint8 kind,
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 netSpend, uint256 claimableDelta) {
        if (kind == 0) {
            return _runBafJackpot(poolWei, lvl, rngWord, jackpotsAddr);
        }
        if (kind == 1) {
            // Decimator: jackpots contract handles distribution
            uint256 returnWei = IDegenerusJackpots(jackpotsAddr).runDecimatorJackpot(poolWei, lvl, rngWord);
            // Decimator pool is reserved in claimablePool; per-player credits happen on claim
            uint256 spend = poolWei - returnWei;
            return (spend, spend);
        }
        return (0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BAF Jackpot
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute BAF (Big-Ass Flip) jackpot distribution.
     * @dev Complex payout logic with bond splits and MAP purchases.
     *
     * @param poolWei Total ETH for BAF distribution.
     * @param lvl Level triggering the BAF.
     * @param rngWord VRF entropy for winner selection.
     * @param jackpotsAddr DegenerusJackpots contract.
     * @return netSpend Amount consumed from rewardPool.
     * @return claimableDelta ETH credited to claimable balances.
     *
     * ## Winner Categories (via bondMask)
     *
     * | Category | Bond Split | Special Handling |
     * |----------|------------|------------------|
     * | Top winners (low bits) | 20% → bonds | Direct ETH + bond |
     * | Scatter winners (high bits) | 100% → bonds | 50% → MAPs first |
     * | Regular winners | 0% | Direct ETH |
     *
     * ## Scatter Winner Flow
     *
     * ```
     * Scatter Amount
     *     │
     *     ├─ Up to 50% of total scatter → MAPs
     *     │   └─ Added to nextPrizePool
     *     │
     *     └─ Remainder → bonds (100%)
     *         └─ If bonds disabled → claimable ETH
     * ```
     *
     * ## Trophy
     *
     * First winner (winners[0]) receives BAF trophy.
     */
    function _runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 netSpend, uint256 claimableDelta) {
        address trophyAddr = trophies;

        // Get winners and payout info from jackpots contract
        (
            address[] memory winnersArr,
            uint256[] memory amountsArr,
            uint256 bondMask,
            uint256 refund
        ) = IDegenerusJackpots(jackpotsAddr).runBafJackpot(poolWei, lvl, rngWord);

        // Parse bondMask: low bits = top winners, high bits = scatter winners
        uint256 topMask = bondMask & ((uint256(1) << BAF_BOND_MASK_OFFSET) - 1);
        uint256 scatterMask = bondMask >> BAF_BOND_MASK_OFFSET;

        bool bondsEnabled = IDegenerusBondsJackpot(bonds).purchasesEnabled();
        uint256 mapPrice = uint256(price) / 4;

        // Calculate total scatter amount for MAP budget (50% of scatter → MAPs)
        uint256 scatterTotal;
        for (uint256 i; i < winnersArr.length; ) {
            if ((scatterMask & (uint256(1) << i)) != 0) {
                scatterTotal += amountsArr[i];
            }
            unchecked {
                ++i;
            }
        }
        uint256 mapTarget = scatterTotal / 2; // 50% of scatter can go to MAPs
        uint256 mapSpent;

        // ─────────────────────────────────────────────────────────────────────
        // Process each winner
        // ─────────────────────────────────────────────────────────────────────

        for (uint256 i; i < winnersArr.length; ) {
            uint256 amount = amountsArr[i];
            uint256 ethPortion = amount;
            uint256 tmpClaimable;

            bool scatterSpecial = (scatterMask & (uint256(1) << i)) != 0;
            bool topBond = (topMask & (uint256(1) << i)) != 0;

            if (scatterSpecial) {
                // ─────────────────────────────────────────────────────────────
                // Scatter winner: MAPs first, remainder to bonds
                // ─────────────────────────────────────────────────────────────

                if (mapPrice != 0 && mapSpent < mapTarget) {
                    uint256 qty = amount / mapPrice;
                    if (qty != 0) {
                        if (qty > type(uint32).max) qty = type(uint32).max;
                        uint256 mapCost = qty * mapPrice;

                        // Queue MAPs and add to next level's prize pool
                        _queueRewardMaps(winnersArr[i], uint32(qty));
                        nextPrizePool += mapCost;

                        // Remainder goes to bonds
                        uint256 remainder = amount - mapCost;
                        if (remainder != 0) {
                            (ethPortion, tmpClaimable) = _splitEthWithBond(
                                winnersArr[i],
                                remainder,
                                BAF_SCATTER_BOND_BPS, // 100% to bonds
                                bondsEnabled
                            );
                        } else {
                            ethPortion = 0;
                        }
                        mapSpent += mapCost;
                    } else {
                        // Amount too small for MAPs - all to bonds
                        (ethPortion, tmpClaimable) = _splitEthWithBond(
                            winnersArr[i],
                            amount,
                            BAF_SCATTER_BOND_BPS,
                            bondsEnabled
                        );
                    }
                } else {
                    // MAP budget exhausted - all to bonds
                    (ethPortion, tmpClaimable) = _splitEthWithBond(
                        winnersArr[i],
                        amount,
                        BAF_SCATTER_BOND_BPS,
                        bondsEnabled
                    );
                }
            } else if (topBond) {
                // ─────────────────────────────────────────────────────────────
                // Top winner: 20% to bonds, 80% to claimable
                // ─────────────────────────────────────────────────────────────

                (ethPortion, tmpClaimable) = _splitEthWithBond(winnersArr[i], amount, BAF_TOP_BOND_BPS, bondsEnabled);
            }
            // Else: regular winner - full amount as claimable ETH (no split)

            claimableDelta += tmpClaimable;
            if (ethPortion != 0) {
                claimableDelta += _addClaimableEth(winnersArr[i], ethPortion);
            }

            unchecked {
                ++i;
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // Mint BAF trophy for first winner
        // ─────────────────────────────────────────────────────────────────────

        if (winnersArr.length != 0) {
            try IDegenerusTrophies(trophyAddr).mintBaf(winnersArr[0], lvl) {} catch {}
        }

        netSpend = poolWei - refund;
        return (netSpend, claimableDelta);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Utility Functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Propagate revert data from a failed delegatecall.
     * @param reason Revert data from the failed call.
     */
    function _revertDelegate(bytes memory reason) private pure {
        if (reason.length == 0) revert();
        assembly ("memory-safe") {
            revert(add(32, reason), mload(reason))
        }
    }

    /**
     * @notice Calculate exterminator share in basis points.
     * @dev "Big-ex" levels (14, 24, 34...) get fixed 40%. Others get random 20-40%.
     *
     * @param prevLevel The level that was exterminated.
     * @param rngWord VRF entropy for randomization.
     * @return Exterminator share in basis points (2000-4000).
     */
    function _exterminatorShareBps(uint24 prevLevel, uint256 rngWord) private pure returns (uint16) {
        // Big-ex levels: fixed 40% (levels 14, 24, 34... but not 4)
        if (prevLevel % 10 == 4 && prevLevel != 4) {
            return 4000;
        }

        // Random 20-40% in 1% steps
        uint256 seed = uint256(keccak256(abi.encode(rngWord, prevLevel, "ex_share")));
        uint256 roll = seed % 21; // 0-20 inclusive
        return uint16(2000 + roll * 100); // 20-40%
    }
}
