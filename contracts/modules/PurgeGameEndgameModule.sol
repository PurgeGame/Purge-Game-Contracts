// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeJackpots} from "../interfaces/IPurgeJackpots.sol";
import {IPurgeTrophies} from "../interfaces/IPurgeTrophies.sol";
import {IPurgeAffiliate} from "../interfaces/IPurgeAffiliate.sol";
import {PurgeGameStorage, PendingJackpotBondMint, ClaimableBondInfo} from "../storage/PurgeGameStorage.sol";

interface IPurgeGameAffiliatePayout {
    function affiliatePayoutAddress(address player) external view returns (address recipient, address affiliateOwner);
}

/**
 * @title PurgeGameEndgameModule
 * @notice Delegate-called module that hosts the slow-path endgame settlement logic for `PurgeGame`.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract PurgeGameEndgameModule is PurgeGameStorage {
    // -----------------------
    // Custom Errors / Events
    // -----------------------
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);

    uint32 private constant DEFAULT_PAYOUTS_PER_TX = 420;
    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint256 private constant MINT_MASK_24 = (uint256(1) << 24) - 1;
    uint256 private constant ETH_LEVEL_STREAK_SHIFT = 48;
    uint256 private constant JACKPOT_BOND_MIN_BASE = 0.02 ether;
    uint256 private constant JACKPOT_BOND_MAX_BASE = 0.5 ether;
    uint8 private constant JACKPOT_BOND_MAX_MULTIPLIER = 4;
    uint16 private constant BOND_BPS_HALF = 5000;

    /**
     * @notice Settles a completed level by paying trait-related slices, jackpots, and participant airdrops.
     * @dev Called by the core game contract via `delegatecall` so state mutations land on the parent.
     *      Returns true once all endgame work for the previous level is finished so the core can advance.
     * @param lvl Current level index (1-based) that just completed.
     * @param cap Optional cap for batched payouts; zero falls back to DEFAULT_PAYOUTS_PER_TX.
     * @param rngWord Randomness used for jackpot and ticket selection.
     * @param jackpotsAddr Address of the jackpots contract to invoke.
     */
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint256 rngWord,
        address jackpotsAddr
    ) external returns (bool readyForPurchase) {
        uint24 prevLevel = lvl == 0 ? 0 : lvl - 1;
        uint16 traitRaw = lastExterminatedTrait;
        if (traitRaw == TRAIT_ID_TIMEOUT) {
            _runRewardJackpots(prevLevel, rngWord, jackpotsAddr);
            return true;
        }

        uint8 traitId = uint8(traitRaw);
        if (!levelExterminatorPaid[prevLevel]) {
            _primeTraitPayouts(prevLevel, traitId, rngWord);
            return false;
        }

        uint256 participantPool = currentPrizePool;
        if (participantPool != 0) {
            // Finalize the participant slice from `_primeTraitPayouts` in a gas-bounded manner.
            _payoutParticipants(cap, prevLevel, participantPool, traitId);
            if (currentPrizePool != 0) {
                return false;
            }
        }

        _runRewardJackpots(prevLevel, rngWord, jackpotsAddr);
        return true;
    }

    /**
     * @notice Pays the participant slice of the prize pool evenly across trait purge tickets for the level.
     * @dev Uses `airdropIndex` to batch work across transactions and coalesces consecutive identical winners.
     * @param capHint Optional per-call cap to keep gas bounded; zero uses DEFAULT_PAYOUTS_PER_TX.
     * @param prevLevel Level that just ended (level indexes are 1-based).
     * @param participantPool Value of `currentPrizePool` cached by the caller to avoid extra SLOADs.
     */
    function _payoutParticipants(uint32 capHint, uint24 prevLevel, uint256 participantPool, uint8 traitId) private {
        address[] storage arr = traitPurgeTicket[prevLevel][traitId];
        uint256 len = arr.length;
        uint256 unitPayout = participantPool / len;

        uint256 cap = (capHint == 0) ? DEFAULT_PAYOUTS_PER_TX : capHint;
        uint256 i = airdropIndex;
        uint256 end = i + cap;
        if (end > len) end = len;

        while (i < end) {
            address w = arr[i];
            uint256 run = 1;
            unchecked {
                while (i + run < end && arr[i + run] == w) ++run;
            }
            _addClaimableEth(w, unitPayout * run);
            unchecked {
                i += run;
            }
        }

        if (end == len) {
            currentPrizePool = 0;
        }

        uint32 nextIdx = i == len ? 0 : uint32(i);
        airdropIndex = nextIdx;
    }

    function _exterminatorForLevel(uint24 lvl) private view returns (address ex) {
        if (lvl == 0) return address(0);
        address[] storage arr = levelExterminators;
        if (arr.length < lvl) return address(0);
        return arr[uint256(lvl) - 1];
    }

    function _runRewardJackpots(uint24 prevLevel, uint256 rngWord, address jackpotsAddr) private {
        uint256 rewardPoolLocal = rewardPool;
        uint24 prevMod10 = prevLevel % 10;
        uint24 prevMod100 = prevLevel % 100;

        if (prevLevel != 0 && prevMod10 == 0) {
            uint256 bafPoolWei;
            if (prevMod100 == 0 && bafHundredPool != 0) {
                // Every 100 levels we may have a carry pool; otherwise take a fresh slice from rewardPool.
                bafPoolWei = bafHundredPool;
                bafHundredPool = 0;
            } else {
                bafPoolWei = (rewardPoolLocal * (prevLevel == 50 ? 25 : 10)) / 100;
            }
            if (bafPoolWei != 0) {
                rewardPoolLocal -= _rewardJackpot(0, bafPoolWei, prevLevel, rngWord, jackpotsAddr);
            }
        }
        if (prevMod10 == 5 && prevLevel >= 15 && prevMod100 != 95) {
            // Fire decimator jackpots midway through each decile except the 95th to avoid overlap with final bands.
            uint256 decPoolWei = (rewardPoolLocal * 15) / 100;
            if (decPoolWei != 0) {
                rewardPoolLocal -= _rewardJackpot(1, decPoolWei, prevLevel, rngWord, jackpotsAddr);
            }
        }

        rewardPool = rewardPoolLocal;
    }

    /**
     * @notice Splits the current prize pool into exterminator, ticket, and participant slices for a trait win.
     * @dev Handles exterminator and participant splits without any trophy accounting.
     */
    function _primeTraitPayouts(uint24 prevLevel, uint8 traitId, uint256 rngWord) private {
        address ex = _exterminatorForLevel(prevLevel);

        levelExterminatorPaid[prevLevel] = true;
        _maybeMintAffiliateTop(prevLevel);

        uint256 poolValue = currentPrizePool;
        uint256 exterminatorShare = (prevLevel % 10 == 4 && prevLevel != 4)
            ? (poolValue * 40) / 100
            : (poolValue * 30) / 100;

        _payExterminatorShare(ex, exterminatorShare, rngWord);

        // Bonus slice: 10% split across three tickets using their ETH mint streaks as weights
        // (even split if all streaks are zero).
        uint256 ticketBonus = (poolValue * 10) / 100;
        _distributeTicketBonus(prevLevel, traitId, ticketBonus, rngWord);

        uint256 participantShare = ((poolValue * 90) / 100) - exterminatorShare;
        currentPrizePool = participantShare;
        airdropIndex = 0;
    }

    function _maybeMintAffiliateTop(uint24 prevLevel) private {
        address affiliateAddr = affiliateProgramAddr;
        if (affiliateAddr == address(0)) return;
        (address top, ) = IPurgeAffiliate(affiliateAddr).affiliateTop(prevLevel);
        if (top == address(0)) return;
        address trophyAddr = trophies;
        try IPurgeTrophies(trophyAddr).mintAffiliate(top, prevLevel) {} catch {}
    }

    function _payExterminatorShare(address ex, uint256 exterminatorShare, uint256 rngWord) private {
        address[] memory exArr = new address[](1);
        exArr[0] = ex;
        uint256 ethPortion = _splitEthWithBonds(exArr, exterminatorShare, BOND_BPS_HALF, rngWord);
        _addClaimableEth(ex, ethPortion);
    }

    function _distributeTicketBonus(uint24 prevLevel, uint8 traitId, uint256 ticketBonus, uint256 rngWord) private {
        address[] storage arr = traitPurgeTicket[prevLevel][traitId];
        uint256 arrLen = arr.length;
        address[3] memory winners;
        uint256[3] memory streaks;
        for (uint8 i; i < 3; ) {
            // Pick three winners with replacement using disjoint slices of the VRF word; weighting is applied later via streaks.
            address w = arr[(rngWord >> (uint256(i) * 64)) % arrLen];
            winners[i] = w;
            streaks[i] = (mintPacked_[w] >> ETH_LEVEL_STREAK_SHIFT) & MINT_MASK_24;
            unchecked {
                ++i;
            }
        }

        uint256 totalWeight = streaks[0] + streaks[1] + streaks[2];
        uint256 share0 = totalWeight == 0 ? ticketBonus / 3 : (ticketBonus * streaks[0]) / totalWeight;
        uint256 share1 = totalWeight == 0 ? ticketBonus / 3 : (ticketBonus * streaks[1]) / totalWeight;
        uint256 share2 = totalWeight == 0 ? ticketBonus / 3 : (ticketBonus * streaks[2]) / totalWeight;
        uint256 paid = share0 + share1 + share2;
        if (paid < ticketBonus) {
            share0 += (ticketBonus - paid);
        }

        uint256 amt0 = share0;
        uint256 amt1 = share1;
        uint256 amt2 = share2;
        if (winners[1] == winners[0]) {
            amt0 += amt1;
            amt1 = 0;
        }
        if (winners[2] == winners[0]) {
            amt0 += amt2;
            amt2 = 0;
        } else if (winners[2] == winners[1]) {
            amt1 += amt2;
            amt2 = 0;
        }

        if (amt0 != 0) _addClaimableEth(winners[0], amt0);
        if (amt1 != 0) _addClaimableEth(winners[1], amt1);
        if (amt2 != 0) _addClaimableEth(winners[2], amt2);
    }

    function _splitEthWithBonds(
        address[] memory winners,
        uint256 amount,
        uint16 bondBps,
        uint256 entropy
    ) private returns (uint256 ethPortion) {
        uint256 winnersLen = winners.length;
        if (bondBps == 0 || amount == 0 || winnersLen == 0) {
            return amount;
        }

        uint256 bondBudget = (amount * bondBps) / 10_000;
        if (bondBudget < JACKPOT_BOND_MIN_BASE) {
            return amount;
        }

        uint256 basePerBond = bondBudget / winnersLen;
        if (basePerBond < JACKPOT_BOND_MIN_BASE) {
            basePerBond = JACKPOT_BOND_MIN_BASE;
        }

        uint256 quantity = bondBudget / basePerBond;
        if (quantity == 0) return amount;

        uint256 maxQuantity = winnersLen * JACKPOT_BOND_MAX_MULTIPLIER;
        if (quantity > maxQuantity) {
            quantity = maxQuantity;
        }
        if (quantity > type(uint16).max) {
            quantity = type(uint16).max;
        }

        basePerBond = (bondBudget + quantity - 1) / quantity; // ceil to fully use bond budget
        if (basePerBond < JACKPOT_BOND_MIN_BASE) {
            basePerBond = JACKPOT_BOND_MIN_BASE;
        }

        uint256 spend = basePerBond * quantity;
        if (spend > amount) {
            basePerBond = amount / quantity;
            if (basePerBond < JACKPOT_BOND_MIN_BASE) {
                return amount;
            }
            spend = basePerBond * quantity;
        }
        if (spend == 0 || spend > amount) {
            return amount;
        }

        uint16 offset = uint16(entropy % winnersLen);
        uint96 base96 = uint96(basePerBond);
        _creditClaimableBonds(winners, uint16(quantity), base96, offset);
        _fundBonds(spend);

        return amount - spend;
    }

    function _creditClaimableBonds(
        address[] memory winners,
        uint16 quantity,
        uint96 basePerBond,
        uint16 offset
    ) private {
        if (quantity == 0 || winners.length == 0 || basePerBond == 0) return;
        uint256 len = winners.length;
        uint256 per = quantity / len;
        uint256 rem = quantity % len;
        for (uint256 i; i < len; ) {
            uint256 share = per;
            if (i < rem) {
                unchecked {
                    ++share;
                }
            }
            if (share != 0) {
                address recipient = winners[(uint256(offset) + i) % len];
                _addClaimableBond(recipient, uint256(share) * uint256(basePerBond), basePerBond, true);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Adds ETH winnings to a player, emitting the credit event.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) private {
        if (weiAmount == 0) return;
        address recipient = _payoutRecipient(beneficiary);
        unchecked {
            claimableWinnings[recipient] += weiAmount;
        }
        emit PlayerCredited(beneficiary, recipient, weiAmount);
    }

    /**
     * @notice Routes a jackpot slice to the jackpots contract and returns the net ETH consumed.
     * @param kind 0 = BAF jackpot, 1 = Decimator jackpot.
     * @param poolWei Amount forwarded to the jackpots contract.
     * @param lvl Level tied to the jackpot.
     * @param rngWord Randomness used by the jackpot contract.
     * @param jackpotsAddr Jackpots contract to call.
     * @return netSpend Amount of rewardPool consumed (poolWei minus any refund).
     */
    function _rewardJackpot(
        uint8 kind,
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 netSpend) {
        if (kind == 0) {
            return _runBafJackpot(poolWei, lvl, rngWord, jackpotsAddr);
        }
        if (kind == 1) {
            return _runDecJackpot(poolWei, lvl, rngWord, jackpotsAddr);
        }
        return 0;
    }

    function _payoutRecipient(address player) private view returns (address recipient) {
        (recipient, ) = IPurgeGameAffiliatePayout(address(this)).affiliatePayoutAddress(player);
    }

    function _fundBonds(uint256 amount) private {
        if (amount == 0) return;
        unchecked {
            bondCreditEscrow += amount;
        }
    }

    function _addClaimableBond(address player, uint256 weiAmount, uint96 basePerBond, bool stake) private {
        if (player == address(0) || weiAmount == 0 || basePerBond == 0) return;
        ClaimableBondInfo storage info = claimableBondInfo[player];
        if (info.basePerBondWei == 0) {
            info.basePerBondWei = basePerBond;
            info.stake = stake;
        }
        unchecked {
            info.weiAmount = uint128(uint256(info.weiAmount) + weiAmount);
        }
        _autoLiquidateBondCredit(player);
    }

    function _autoLiquidateBondCredit(address player) private returns (bool converted) {
        if (!autoBondLiquidate[player]) return false;
        ClaimableBondInfo storage info = claimableBondInfo[player];
        uint256 creditWei = info.weiAmount;
        if (creditWei == 0) return false;

        info.weiAmount = 0;
        info.basePerBondWei = 0;
        info.stake = false;
        bondCreditEscrow = bondCreditEscrow - creditWei;
        _addClaimableEth(player, creditWei);
        return true;
    }

    function _runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 netSpend) {
        address trophyAddr = trophies;
        (address[] memory winnersArr, uint256[] memory amountsArr, uint256 bondMask, uint256 refund) = IPurgeJackpots(
            jackpotsAddr
        ).runBafJackpot(poolWei, lvl, rngWord);
        address[] memory single = new address[](1);
        for (uint256 i; i < winnersArr.length; ) {
            uint256 amount = amountsArr[i];
            if (amount != 0) {
                uint256 ethPortion = amount;
                bool forceBond = (bondMask & (uint256(1) << i)) != 0;
                if (forceBond) {
                    single[0] = winnersArr[i];
                    // Force full bond payout for tagged winners (with ETH fallback if bonds cannot be minted).
                    ethPortion = _splitEthWithBonds(single, amount, 10_000, rngWord ^ (uint256(i) << 1));
                } else if (i < 2) {
                    single[0] = winnersArr[i];
                    ethPortion = _splitEthWithBonds(single, amount, BOND_BPS_HALF, rngWord ^ i);
                }
                if (ethPortion != 0) {
                    _addClaimableEth(winnersArr[i], ethPortion);
                }
            }
            unchecked {
                ++i;
            }
        }
        if (trophyAddr != address(0) && winnersArr.length != 0) {
            // Top BAF winner gets the cosmetic trophy to keep gas bounded.
            try IPurgeTrophies(trophyAddr).mintBaf(winnersArr[0], lvl) {} catch {}
        }
        netSpend = poolWei - refund;
    }

    function _runDecJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 netSpend) {
        uint256 returnWei = IPurgeJackpots(jackpotsAddr).runDecimatorJackpot(poolWei, lvl, rngWord);
        netSpend = poolWei - returnWei;
    }
}
