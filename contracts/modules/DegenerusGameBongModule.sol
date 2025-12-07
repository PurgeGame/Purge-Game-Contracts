// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";
import {IDegenerusCoin} from "../interfaces/IDegenerusCoin.sol";

interface IDegenerusBongsLite {
    function payBongs(uint256 coinAmount, uint256 stEthAmount, uint48 rngDay, uint256 rngWord, uint256 maxBongs) external payable;
    function resolvePendingBongs(uint256 maxBongs) external;
    function resolvePending() external view returns (bool);
    function notifyGameOver() external;
    function stakeRateBps() external view returns (uint16);
}

interface IStETHLite {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IDegenerusGameVaultLike {
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable;
}

/**
 * @title DegenerusGameBongModule
 * @notice Delegate-called module for bong upkeep, staking, and shutdown flows.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract DegenerusGameBongModule is DegenerusGameStorage {
    error E();
    error BongsNotResolved();

    uint256 private constant REWARD_POOL_MIN_STAKE = 0.5 ether;

    /// @notice Handle bong funding/resolve work during map jackpot prep.
    function bongMaintenanceForMap(
        address bongsAddr,
        address coinAddr,
        address stethAddr,
        uint48 day,
        uint256 totalWei,
        uint256 rngWord,
        uint32 cap
    ) external returns (bool worked) {
        IDegenerusBongsLite bongContract = IDegenerusBongsLite(bongsAddr);

        uint256 maxBongs = cap == 0 ? 100 : uint256(cap);
        // If a batch is already pending, just resolve more and skip new funding.
        if (bongContract.resolvePending()) {
            bongContract.payBongs{value: 0}(0, 0, day, rngWord, maxBongs);
            lastBongResolutionDay = day;
            return true;
        }

        // Only fund once per level; subsequent calls act as resolve-only.
        if (lastBongFundingLevel == level) {
            return false;
        }

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 stYield = stBal > principalStEth ? (stBal - principalStEth) : 0;
        uint256 ethBal = address(this).balance;
        uint256 tracked = currentPrizePool + nextPrizePool + rewardPool + bongCreditEscrow;
        uint256 ethYield = ethBal > tracked ? ethBal - tracked : 0;
        uint256 yieldPool = stYield + ethYield;

        // Mintable coin from map jackpot: 5% of totalWei (priced in DEGEN).
        uint256 mintableCoin = (totalWei * priceCoin) / (20 * price);
        uint256 bondCoin = (mintableCoin * 40) / 100;
        uint256 vaultCoin = mintableCoin - bondCoin;

        uint256 bongSkim = yieldPool / 4; // 25% to bongs
        uint256 rewardTopUp = yieldPool / 20; // 5% to reward pool

        uint256 ethForBongs = bongSkim <= ethYield ? bongSkim : ethYield;
        uint256 stForBongs = bongSkim > ethForBongs ? bongSkim - ethForBongs : 0;
        if (stForBongs > stYield) {
            stForBongs = stYield;
            bongSkim = ethForBongs + stForBongs;
        }

        uint256 ethAfterBong = ethYield > ethForBongs ? ethYield - ethForBongs : 0;
        uint256 rewardFromEth = rewardTopUp <= ethAfterBong ? rewardTopUp : ethAfterBong;
        if (rewardFromEth != 0) {
            rewardPool += rewardFromEth;
        }

        // Route vault share (if any) as mint allowance; ignore failures to avoid blocking jackpots.
        if (vaultCoin != 0) {
            address vaultAddr = IDegenerusCoin(coinAddr).vault();
            if (vaultAddr != address(0)) {
                try IDegenerusGameVaultLike(vaultAddr).deposit{value: 0}(vaultCoin, 0) {} catch {}
            }
        }

        bongContract.payBongs{value: ethForBongs}(bondCoin, stForBongs, day, rngWord, maxBongs);
        lastBongFundingLevel = level;
        return (bongSkim != 0 || mintableCoin != 0 || rewardFromEth != 0);
    }

    /// @notice Stake excess reward pool into stETH based on bongs-configured ratio.
    function stakeForTargetRatio(address bongsAddr, address stethAddr, uint24 lvl) external {
        // Skip only for levels ending in 99 or 00 to avoid endgame edge cases.
        uint24 cycle = lvl % 100;
        if (cycle == 99 || cycle == 0) return;

        uint256 pool = rewardPool;
        if (pool == 0) return;

        uint256 rateBps = 10_000;
        if (bongsAddr != address(0)) {
            rateBps = IDegenerusBongsLite(bongsAddr).stakeRateBps();
        }
        if (rateBps == 0) return;

        uint256 targetSt = (pool * rateBps) / 10_000; // stake against configured share of reward pool
        uint256 stBal = principalStEth;
        if (stBal >= targetSt) return;

        uint256 stakeAmount = targetSt - stBal;
        if (stakeAmount < REWARD_POOL_MIN_STAKE) return;

        _stakeEth(stethAddr, stakeAmount);
    }

    /// @notice Inform bongs of shutdown and transfer all assets to it.
    function drainToBongs(address bongsAddr, address stethAddr, uint48 day) external {
        if (bongsAddr == address(0)) return;

        IDegenerusBongsLite bongContract = IDegenerusBongsLite(bongsAddr);
        bongContract.notifyGameOver();

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        if (stBal != 0) {
            principalStEth = 0;
        }

        uint256 ethBal = address(this).balance;
        bongContract.payBongs{value: ethBal}(0, stBal, day, 0, 0);
    }

    function _stakeEth(address stethAddr, uint256 amount) private {
        // Best-effort staking; skip if stETH deposits are paused or unavailable.
        try IStETHLite(stethAddr).submit{value: amount}(address(0)) returns (uint256 minted) {
            principalStEth += minted;
        } catch {
            return;
        }
    }
}
