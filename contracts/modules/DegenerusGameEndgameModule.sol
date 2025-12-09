// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusJackpots} from "../interfaces/IDegenerusJackpots.sol";
import {IDegenerusTrophies} from "../interfaces/IDegenerusTrophies.sol";
import {IDegenerusAffiliate} from "../interfaces/IDegenerusAffiliate.sol";
import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";

interface IDegenerusGameAffiliatePayout {
    function affiliatePayoutAddress(address player) external view returns (address recipient, address affiliateOwner);
}

interface IDegenerusGameTraitJackpot {
    function payExterminationJackpot(
        uint24 lvl,
        uint8 traitId,
        uint256 rngWord,
        uint256 ethPool
    ) external returns (uint256 paidEth);
}

interface IDegenerusBondsJackpot {
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded);
    function purchasesEnabled() external view returns (bool);
}

/**
 * @title DegenerusGameEndgameModule
 * @notice Delegate-called module that hosts the slow-path endgame settlement logic for `DegenerusGame`.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract DegenerusGameEndgameModule is DegenerusGameStorage {
    // -----------------------
    // Custom Errors / Events
    // -----------------------
    event PlayerCredited(address indexed player, address indexed recipient, uint256 amount);

    uint16 private constant TRAIT_ID_TIMEOUT = 420;
    uint16 private constant BOND_BPS_HALF = 5000;

    /**
     * @notice Settles a completed level by paying the exterminator, a trait-only jackpot, and reward jackpots.
     * @dev Called by the core game contract via `delegatecall` so state mutations land on the parent.
     * @param lvl Current level index (1-based) that just completed.
     * @param rngWord Randomness used for jackpot and ticket selection.
     * @param jackpotsAddr Address of the jackpots contract to invoke.
     */
    function finalizeEndgame(uint24 lvl, uint256 rngWord, address jackpotsAddr) external {
        uint256 claimableDelta;
        uint24 prevLevel = lvl == 0 ? 0 : lvl - 1;
        uint16 traitRaw = lastExterminatedTrait;
        if (traitRaw != TRAIT_ID_TIMEOUT) {
            uint8 traitId = uint8(traitRaw);
            address ex = levelExterminators[uint256(prevLevel) - 1]; // guaranteed populated when traitRaw is set

            _maybeMintAffiliateTop(prevLevel);

            uint256 poolValue = currentPrizePool;
            uint256 exterminatorShare = (prevLevel % 10 == 4 && prevLevel != 4)
                ? (poolValue * 40) / 100
                : (poolValue * 30) / 100;

            claimableDelta += _payExterminatorShare(ex, exterminatorShare);

            uint256 jackpotPool = poolValue > exterminatorShare ? poolValue - exterminatorShare : 0;
            if (jackpotPool != 0) {
                IDegenerusGameTraitJackpot(address(this)).payExterminationJackpot(
                    prevLevel,
                    traitId,
                    rngWord,
                    jackpotPool
                );
            }

            currentPrizePool = 0;
            airdropIndex = 0;
        }
        claimableDelta += _runRewardJackpots(prevLevel, rngWord, jackpotsAddr);
        if (claimableDelta != 0) {
            claimablePool += claimableDelta;
        }
    }

    function _runRewardJackpots(
        uint24 prevLevel,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 claimableDelta) {
        uint256 rewardPoolLocal = rewardPool;
        uint24 prevMod10 = prevLevel % 10;
        uint24 prevMod100 = prevLevel % 100;

        if (prevMod10 == 0) {
            uint256 bafPoolWei;
            bool reservedBaf;
            if (prevMod100 == 0 && bafHundredPool != 0) {
                // Every 100 levels we may have a carry pool; otherwise take a fresh slice from rewardPool.
                bafPoolWei = bafHundredPool;
                bafHundredPool = 0;
                reservedBaf = true;
            } else {
                bafPoolWei = (rewardPoolLocal * (prevLevel == 50 ? 25 : 10)) / 100;
            }

            (uint256 netSpend, uint256 claimed) = _rewardJackpot(0, bafPoolWei, prevLevel, rngWord, jackpotsAddr);
            claimableDelta += claimed;
            if (reservedBaf) {
                // Reserved BAF pool was already removed from rewardPool when carved out; only return any refund.
                uint256 refund = bafPoolWei - netSpend;
                if (refund != 0) {
                    rewardPoolLocal += refund;
                }
            } else {
                rewardPoolLocal -= netSpend;
            }
        }
        if (prevMod10 == 5 && prevLevel >= 15 && prevMod100 != 95) {
            // Fire decimator jackpots midway through each decile except the 95th to avoid overlap with final bands.
            uint256 decPoolWei = (rewardPoolLocal * 15) / 100;
            if (decPoolWei != 0) {
                (uint256 spend, uint256 claimed) = _rewardJackpot(1, decPoolWei, prevLevel, rngWord, jackpotsAddr);
                rewardPoolLocal -= spend;
                claimableDelta += claimed;
            }
        }

        rewardPool = rewardPoolLocal;
        return claimableDelta;
    }

    function _maybeMintAffiliateTop(uint24 prevLevel) private {
        address affiliateAddr = affiliateProgramAddr;
        (address top, uint96 score) = IDegenerusAffiliate(affiliateAddr).affiliateTop(prevLevel);
        if (top == address(0)) return;
        address trophyAddr = trophies;
        IDegenerusTrophies(trophyAddr).mintAffiliate(top, prevLevel, score);
    }

    function _payExterminatorShare(address ex, uint256 exterminatorShare) private returns (uint256 claimableDelta) {
        bool bondsEnabled = IDegenerusBondsJackpot(bonds).purchasesEnabled();
        (uint256 ethPortion, uint256 splitClaimable) = _splitEthWithBond(
            ex,
            exterminatorShare,
            BOND_BPS_HALF,
            bondsEnabled
        );
        claimableDelta = splitClaimable + _addClaimableEth(ex, ethPortion);
    }

    function _splitEthWithBond(
        address winner,
        uint256 amount,
        uint16 bondBps,
        bool bondsEnabled
    ) private returns (uint256 ethPortion, uint256 claimableDelta) {
        uint256 bondBudget = (amount * bondBps) / 10_000;

        ethPortion = amount;

        if (!bondsEnabled || bondBudget == 0) {
            return (ethPortion, claimableDelta);
        }

        if (bondCashoutHalf[winner]) {
            uint256 payout = bondBudget / 2;
            claimableDelta = _addClaimableEth(winner, payout);
            ethPortion -= bondBudget;
            return (ethPortion, claimableDelta);
        }

        try IDegenerusBondsJackpot(bonds).depositCurrentFor{value: bondBudget}(winner) {
            ethPortion -= bondBudget;
        } catch {
            // leave bondBudget in ethPortion to pay out as ETH on failure
        }
        return (ethPortion, claimableDelta);
    }

    /// @notice Adds ETH winnings to a player, emitting the credit event.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) private returns (uint256) {
        address recipient = _payoutRecipient(beneficiary);
        unchecked {
            claimableWinnings[recipient] += weiAmount;
        }
        emit PlayerCredited(beneficiary, recipient, weiAmount);
        return weiAmount;
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
    ) private returns (uint256 netSpend, uint256 claimableDelta) {
        if (kind == 0) {
            return _runBafJackpot(poolWei, lvl, rngWord, jackpotsAddr);
        }
        if (kind == 1) {
            uint256 returnWei = IDegenerusJackpots(jackpotsAddr).runDecimatorJackpot(poolWei, lvl, rngWord);
            return (poolWei - returnWei, 0);
        }
        return (0, 0);
    }

    function _payoutRecipient(address player) private view returns (address recipient) {
        // Synthetic MAP addresses minted by the game zero out the low 48 bits.
        bool maybeSynthetic = (uint160(player) & ((uint160(1) << 48) - 1)) == 0;
        if (!maybeSynthetic) {
            return player;
        }
        (recipient, ) = IDegenerusGameAffiliatePayout(address(this)).affiliatePayoutAddress(player);
        if (recipient == address(0)) {
            return player;
        }
    }

    function _runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord,
        address jackpotsAddr
    ) private returns (uint256 netSpend, uint256 claimableDelta) {
        address trophyAddr = trophies;
        (
            address[] memory winnersArr,
            uint256[] memory amountsArr,
            uint256 bondMask,
            uint256 refund
        ) = IDegenerusJackpots(jackpotsAddr).runBafJackpot(poolWei, lvl, rngWord);
        bool bondsEnabled = IDegenerusBondsJackpot(bonds).purchasesEnabled();
        for (uint256 i; i < winnersArr.length; ) {
            uint256 amount = amountsArr[i];
            uint256 ethPortion = amount;
            uint256 tmpClaimable;
            bool forceBond = (bondMask & (uint256(1) << i)) != 0;
            if (forceBond) {
                // Force full bond payout for tagged winners (with ETH fallback if bonds cannot be minted).
                (ethPortion, tmpClaimable) = _splitEthWithBond(winnersArr[i], amount, 10_000, bondsEnabled);
            } else if (i < 2) {
                (ethPortion, tmpClaimable) = _splitEthWithBond(winnersArr[i], amount, BOND_BPS_HALF, bondsEnabled);
            }
            claimableDelta += tmpClaimable;
            if (ethPortion != 0) {
                claimableDelta += _addClaimableEth(winnersArr[i], ethPortion);
            }
            unchecked {
                ++i;
            }
        }
        if (winnersArr.length != 0) {
            try IDegenerusTrophies(trophyAddr).mintBaf(winnersArr[0], lvl) {} catch {}
        }
        netSpend = poolWei - refund;
        return (netSpend, claimableDelta);
    }
}
