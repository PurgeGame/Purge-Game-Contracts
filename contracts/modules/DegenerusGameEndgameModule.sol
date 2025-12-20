// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusCoinModule} from "../interfaces/DegenerusGameModuleInterfaces.sol";
import {IDegenerusGameJackpotModule} from "../interfaces/IDegenerusGameModules.sol";
import {IDegenerusJackpots} from "../interfaces/IDegenerusJackpots.sol";
import {IDegenerusTrophies} from "../interfaces/IDegenerusTrophies.sol";
import {IDegenerusAffiliate} from "../interfaces/IDegenerusAffiliate.sol";
import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";

interface IDegenerusBondsJackpot {
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded);
    function depositFromGame(address beneficiary, uint256 amount) external payable returns (uint256 scoreAwarded);
    function purchasesEnabled() external view returns (bool);
}

interface IDegenerusGamepiecesRewards {
    function queueRewardMints(address player, uint32 quantity) external;
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
    uint16 private constant BAF_TOP_BOND_BPS = 2000; // 20% bond buy for top/flip/3-4 BAF winners
    uint16 private constant BAF_SCATTER_BOND_BPS = 10_000; // full bond payout for selected scatter winners
    uint8 private constant BAF_BOND_MASK_OFFSET = 128;
    uint16 private constant EXTERMINATION_PURCHASE_BPS = 2000; // 20% of non-exterminator pool
    uint8 private constant EXTERMINATION_PURCHASE_WINNERS = 20;

    /**
     * @notice Settles a completed level by paying the exterminator, a trait-only jackpot, and reward jackpots.
     * @dev Called by the core game contract via `delegatecall` so state mutations land on the parent.
     * @param lvl Current level index (1-based) that just completed.
     * @param rngWord Randomness used for jackpot and ticket selection.
     * @param jackpotsAddr Address of the jackpots contract to invoke.
     * @param nftAddr NFT contract used to queue reward mints.
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
        uint24 prevLevel = lvl == 0 ? 0 : lvl - 1;
        uint16 traitRaw = lastExterminatedTrait;
        if (traitRaw != TRAIT_ID_TIMEOUT) {
            uint8 traitId = uint8(traitRaw);
            address ex = levelExterminators[uint256(prevLevel) - 1]; // guaranteed populated when traitRaw is set

            _maybeMintAffiliateTop(prevLevel);

            uint256 poolValue = currentPrizePool;
            uint16 exShareBps = _exterminatorShareBps(prevLevel, rngWord);
            uint256 exterminatorShare = (poolValue * exShareBps) / 10_000;

            claimableDelta += _payExterminatorShare(ex, exterminatorShare);

            uint256 jackpotPool = poolValue > exterminatorShare ? poolValue - exterminatorShare : 0;
            if (jackpotPool != 0) {
                uint256 purchasePool = (jackpotPool * EXTERMINATION_PURCHASE_BPS) / 10_000;
                uint256 exterminationPool = jackpotPool - purchasePool;
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
                if (purchasePool != 0) {
                    _runExterminationPurchaseRewards(prevLevel, traitId, rngWord, purchasePool, nftAddr);
                }
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
        bool bondsEnabled = true; // attempt bond buys; failures fall back to ETH payouts
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

        (address resolved, , bool halfCashout) = _resolveBondRecipient(winner);
        if (halfCashout) {
            uint256 payout = bondBudget / 2;
            claimableDelta = _addClaimableEth(resolved, payout);
            ethPortion -= bondBudget;
            return (ethPortion, claimableDelta);
        }

        try IDegenerusBondsJackpot(bonds).depositFromGame{value: bondBudget}(resolved, bondBudget) {
            ethPortion -= bondBudget;
        } catch {
            // leave bondBudget in ethPortion to pay out as ETH on failure
        }
        return (ethPortion, claimableDelta);
    }

    /// @notice Adds ETH winnings to a player, emitting the credit event.
    function _addClaimableEth(address beneficiary, uint256 weiAmount) private returns (uint256) {
        address recipient = beneficiary;
        unchecked {
            claimableWinnings[recipient] += weiAmount;
        }
        emit PlayerCredited(beneficiary, recipient, weiAmount);
        return weiAmount;
    }

    function _resolveBondRecipient(address winner) private view returns (address resolved, bool rerouted, bool halfCashout) {
        resolved = winner;
        halfCashout = bondCashoutHalf[winner];
        rerouted = false;
    }

    function _runExterminationPurchaseRewards(
        uint24 prevLevel,
        uint8 traitId,
        uint256 rngWord,
        uint256 poolWei,
        address nftAddr
    ) private {
        if (poolWei == 0) return;
        nextPrizePool += poolWei;
        address[] storage holders = traitBurnTicket[prevLevel][traitId];
        uint256 len = holders.length;
        if (len == 0) return;

        uint256 tokenPrice = uint256(price);
        if (tokenPrice == 0) return;
        uint256 mapPrice = tokenPrice / 4;
        if (mapPrice == 0) return;

        uint256 burnCount = uint256(traitStartRemaining[traitId]);
        if (burnCount > len) burnCount = len;
        uint256 burnStart = len - burnCount;

        uint256 minUnitPrice = mapPrice;
        uint256 maxWinners = poolWei / minUnitPrice;
        if (maxWinners > EXTERMINATION_PURCHASE_WINNERS) maxWinners = EXTERMINATION_PURCHASE_WINNERS;
        if (maxWinners > len) maxWinners = len;
        if (maxWinners == 0) return;

        uint256 remainingPool = poolWei;
        IDegenerusGamepiecesRewards nftRewards = IDegenerusGamepiecesRewards(nftAddr);

        for (uint256 i; i < maxWinners; ) {
            if (remainingPool < minUnitPrice) break;
            uint256 remainingWinners = maxWinners - i;
            uint256 budget = remainingPool / remainingWinners;
            uint256 entropy = uint256(keccak256(abi.encode(rngWord, prevLevel, traitId, i, "ex_reward")));
            uint256 idx = entropy % len;
            address winner = holders[idx];
            if (winner == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            bool isBurnTicket = idx >= burnStart;
            uint256 unitPrice = isBurnTicket ? tokenPrice : mapPrice;
            uint256 qty = budget / unitPrice;
            if (qty == 0) {
                if (remainingPool < unitPrice) break;
                qty = 1;
            }
            if (qty > type(uint32).max) {
                qty = type(uint32).max;
            }
            uint256 cost = qty * unitPrice;
            if (cost > remainingPool) {
                qty = remainingPool / unitPrice;
                if (qty == 0) break;
                cost = qty * unitPrice;
            }
            remainingPool -= cost;

            if (isBurnTicket) {
                nftRewards.queueRewardMints(winner, uint32(qty));
            } else {
                _queueRewardMaps(winner, uint32(qty));
            }

            unchecked {
                ++i;
            }
        }
    }

    function _queueRewardMaps(address buyer, uint32 quantity) private {
        if (quantity == 0) return;
        uint32 owed = playerMapMintsOwed[buyer];
        if (owed == 0) {
            pendingMapMints.push(buyer);
        }
        unchecked {
            playerMapMintsOwed[buyer] = owed + quantity;
        }
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
            // Decimator pool is reserved in `claimablePool` up front; per-player credits happen on claim.
            uint256 spend = poolWei - returnWei;
            return (spend, spend);
        }
        return (0, 0);
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
        // bondMask: low bits mark top/flip/3-4 winners; high bits mark scatter winners.
        uint256 topMask = bondMask & ((uint256(1) << BAF_BOND_MASK_OFFSET) - 1);
        uint256 scatterMask = bondMask >> BAF_BOND_MASK_OFFSET;
        bool bondsEnabled = IDegenerusBondsJackpot(bonds).purchasesEnabled();
        for (uint256 i; i < winnersArr.length; ) {
            uint256 amount = amountsArr[i];
            uint256 ethPortion = amount;
            uint256 tmpClaimable;
            bool scatterBond = (scatterMask & (uint256(1) << i)) != 0;
            bool topBond = (topMask & (uint256(1) << i)) != 0;
            if (scatterBond) {
                (ethPortion, tmpClaimable) = _splitEthWithBond(winnersArr[i], amount, BAF_SCATTER_BOND_BPS, bondsEnabled);
            } else if (topBond) {
                (ethPortion, tmpClaimable) = _splitEthWithBond(winnersArr[i], amount, BAF_TOP_BOND_BPS, bondsEnabled);
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

    function _revertDelegate(bytes memory reason) private pure {
        if (reason.length == 0) revert();
        assembly ("memory-safe") {
            revert(add(32, reason), mload(reason))
        }
    }

    /// @dev Returns exterminator share in basis points; rolls 20-40% except on big-ex levels (fixed 40%).
    function _exterminatorShareBps(uint24 prevLevel, uint256 rngWord) private pure returns (uint16) {
        if (prevLevel % 10 == 4 && prevLevel != 4) {
            return 4000; // 40% on big-ex levels
        }
        uint256 seed = uint256(keccak256(abi.encode(rngWord, prevLevel, "ex_share")));
        uint256 roll = seed % 21; // 0-20 inclusive
        return uint16(2000 + roll * 100); // 20-40% in 1% steps
    }
}
