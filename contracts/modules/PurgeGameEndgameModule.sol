// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeJackpots} from "../interfaces/IPurgeJackpots.sol";
import {IPurgeTrophies} from "../interfaces/IPurgeTrophies.sol";
import {IPurgeAffiliate} from "../interfaces/IPurgeAffiliate.sol";
import {PurgeGameStorage, ClaimableBongInfo} from "../storage/PurgeGameStorage.sol";

interface IPurgeGameAffiliatePayout {
    function affiliatePayoutAddress(address player) external view returns (address recipient, address affiliateOwner);
}

interface IPurgeGameTraitJackpot {
    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 rngWord,
        uint256 ethPool
    ) external returns (uint256 paidEth);
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

    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint256 private constant JACKPOT_BONG_MIN_BASE = 0.02 ether;
    uint256 private constant JACKPOT_BONG_MAX_BASE = 0.5 ether;
    uint8 private constant JACKPOT_BONG_MAX_MULTIPLIER = 4;
    uint16 private constant BONG_BPS_HALF = 5000;

    /**
     * @notice Settles a completed level by paying the exterminator, a trait-only jackpot, and reward jackpots.
     * @dev Called by the core game contract via `delegatecall` so state mutations land on the parent.
     *      Returns true once all endgame work for the previous level is finished so the core can advance.
     * @param lvl Current level index (1-based) that just completed.
     * @param cap Reserved for legacy batching; retained for ABI compatibility.
     * @param rngWord Randomness used for jackpot and ticket selection.
     * @param jackpotsAddr Address of the jackpots contract to invoke.
     */
    function finalizeEndgame(
        uint24 lvl,
        uint32 cap,
        uint256 rngWord,
        address jackpotsAddr
    ) external returns (bool readyForPurchase) {
        cap; // unused (legacy batching placeholder)

        uint24 prevLevel = lvl == 0 ? 0 : lvl - 1;
        uint16 traitRaw = lastExterminatedTrait;
        if (traitRaw != TRAIT_ID_TIMEOUT) {
            uint8 traitId = uint8(traitRaw);
            if (!levelExterminatorPaid[prevLevel]) {
                _primeTraitPayouts(prevLevel, traitId, rngWord);
            }
        }
        _runRewardJackpots(prevLevel, rngWord, jackpotsAddr);
        return true;
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
     * @notice Splits the current prize pool between the exterminator and a trait-only jackpot for the winning trait.
     * @dev Removes the equal-split/bonus path in favor of a daily-style jackpot scoped to the exterminated trait.
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

        uint256 jackpotPool = poolValue > exterminatorShare ? poolValue - exterminatorShare : 0;
        if (jackpotPool != 0) {
            IPurgeGameTraitJackpot(address(this)).payExterminationJackpot(
                prevLevel,
                traitId,
                rngWord,
                jackpotPool
            );
        }

        currentPrizePool = 0;
        airdropIndex = 0;
    }

    function _maybeMintAffiliateTop(uint24 prevLevel) private {
        address affiliateAddr = affiliateProgramAddr;
        (address top, ) = IPurgeAffiliate(affiliateAddr).affiliateTop(prevLevel);
        if (top == address(0)) return;
        address trophyAddr = trophies;
        try IPurgeTrophies(trophyAddr).mintAffiliate(top, prevLevel) {} catch {}
    }

    function _payExterminatorShare(address ex, uint256 exterminatorShare, uint256 rngWord) private {
        address[] memory exArr = new address[](1);
        exArr[0] = ex;
        uint256 ethPortion = _splitEthWithBongs(exArr, exterminatorShare, BONG_BPS_HALF, rngWord);
        _addClaimableEth(ex, ethPortion);
    }

    function _splitEthWithBongs(
        address[] memory winners,
        uint256 amount,
        uint16 bongBps,
        uint256 entropy
    ) private returns (uint256 ethPortion) {
        uint256 winnersLen = winners.length;
        if (bongBps == 0 || amount == 0 || winnersLen == 0) {
            return amount;
        }

        uint256 bongBudget = (amount * bongBps) / 10_000;
        if (bongBudget < JACKPOT_BONG_MIN_BASE) {
            return amount;
        }

        uint256 basePerBong = bongBudget / winnersLen;
        if (basePerBong < JACKPOT_BONG_MIN_BASE) {
            basePerBong = JACKPOT_BONG_MIN_BASE;
        }

        uint256 quantity = bongBudget / basePerBong;
        if (quantity == 0) return amount;

        uint256 maxQuantity = winnersLen * JACKPOT_BONG_MAX_MULTIPLIER;
        if (quantity > maxQuantity) {
            quantity = maxQuantity;
        }
        if (quantity > type(uint16).max) {
            quantity = type(uint16).max;
        }

        basePerBong = (bongBudget + quantity - 1) / quantity; // ceil to fully use bong budget
        if (basePerBong < JACKPOT_BONG_MIN_BASE) {
            basePerBong = JACKPOT_BONG_MIN_BASE;
        }

        uint256 spend = basePerBong * quantity;
        if (spend > amount) {
            basePerBong = amount / quantity;
            if (basePerBong < JACKPOT_BONG_MIN_BASE) {
                return amount;
            }
            spend = basePerBong * quantity;
        }
        if (spend == 0 || spend > amount) {
            return amount;
        }

        uint16 offset = uint16(entropy % winnersLen);
        uint96 base96 = uint96(basePerBong);
        _creditClaimableBongs(winners, uint16(quantity), base96, offset);
        if (spend != 0) {
            unchecked {
                bongCreditEscrow += spend;
            }
        }

        return amount - spend;
    }

    function _creditClaimableBongs(
        address[] memory winners,
        uint16 quantity,
        uint96 basePerBong,
        uint16 offset
    ) private {
        if (quantity == 0 || winners.length == 0 || basePerBong == 0) return;
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
                _addClaimableBong(recipient, uint256(share) * uint256(basePerBong), basePerBong, true);
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

    function _addClaimableBong(address player, uint256 weiAmount, uint96 basePerBong, bool stake) private {
        if (player == address(0) || weiAmount == 0 || basePerBong == 0) return;
        ClaimableBongInfo storage info = claimableBongInfo[player];
        if (info.basePerBongWei == 0) {
            info.basePerBongWei = basePerBong;
            info.stake = stake;
        }
        unchecked {
            info.weiAmount = uint128(uint256(info.weiAmount) + weiAmount);
        }
        _autoLiquidateBongCredit(player);
    }

    function _autoLiquidateBongCredit(address player) private returns (bool converted) {
        if (!autoBongLiquidate[player]) return false;
        ClaimableBongInfo storage info = claimableBongInfo[player];
        uint256 creditWei = info.weiAmount;
        if (creditWei == 0) return false;

        info.weiAmount = 0;
        info.basePerBongWei = 0;
        info.stake = false;
        bongCreditEscrow = bongCreditEscrow - creditWei;
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
        (address[] memory winnersArr, uint256[] memory amountsArr, uint256 bongMask, uint256 refund) = IPurgeJackpots(
            jackpotsAddr
        ).runBafJackpot(poolWei, lvl, rngWord);
        address[] memory single = new address[](1);
        for (uint256 i; i < winnersArr.length; ) {
            uint256 amount = amountsArr[i];
            if (amount != 0) {
                uint256 ethPortion = amount;
                bool forceBong = (bongMask & (uint256(1) << i)) != 0;
                if (forceBong) {
                    single[0] = winnersArr[i];
                    // Force full bong payout for tagged winners (with ETH fallback if bongs cannot be minted).
                    ethPortion = _splitEthWithBongs(single, amount, 10_000, rngWord ^ (uint256(i) << 1));
                } else if (i < 2) {
                    single[0] = winnersArr[i];
                    ethPortion = _splitEthWithBongs(single, amount, BONG_BPS_HALF, rngWord ^ i);
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
