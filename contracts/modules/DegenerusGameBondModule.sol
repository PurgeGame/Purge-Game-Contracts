// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";

interface IBonds {
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable;
    function resolveBonds(uint256 rngWord) external returns (bool worked);
    function notifyGameOver() external;
    function stakeRateBps() external view returns (uint16);
    function requiredCoverNext() external view returns (uint256 required);
}

interface IStETHLite {
    function submit(address referral) external payable returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IVault {
    function deposit(uint256 coinAmount, uint256 stEthAmount) external payable;
}

/**
 * @title DegenerusGameBondModule
 * @notice Delegate-called module for bond upkeep, staking, and shutdown flows.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract DegenerusGameBondModule is DegenerusGameStorage {
    uint256 private constant REWARD_POOL_MIN_STAKE = 0.5 ether;

    /// @notice Handle bond funding/resolve work during map jackpot prep.
    function bondMaintenanceForMap(address bondsAddr, address stethAddr, uint256 totalWei, uint256 rngWord) external {
        IBonds bondContract = IBonds(bondsAddr);

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;

        uint256 obligations = currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool;
        uint256 combined = ethBal + stBal;
        uint256 yieldTotal = combined > obligations ? combined - obligations : 0;

        // Mintable coin from map jackpot: 5% of totalWei (priced in DEGEN); send full amount to bonds.
        uint256 bondCoin = (totalWei * priceCoin) / (20 * price);

        uint256 bondSkim = yieldTotal / 4; // 25% to bonds
        uint256 rewardTopUp = yieldTotal / 20; // 5% to reward pool

        uint256 required = bondContract.requiredCoverNext();
        uint256 shortfall = required > bondPool ? required - bondPool : 0;
        uint256 toBondPool = bondSkim < shortfall ? bondSkim : shortfall;
        if (toBondPool != 0) {
            bondPool += toBondPool;
        }

        uint256 leftover = bondSkim - toBondPool;
        uint256 stSpend;
        uint256 ethSpend;
        if (leftover != 0) {
            stSpend = leftover <= stBal ? leftover : stBal;
            if (stSpend < leftover) {
                uint256 gap = leftover - stSpend;
                ethSpend = gap <= ethBal ? gap : ethBal;
            }
        }
        bondContract.payBonds{value: ethSpend}(bondCoin, stSpend, rngWord);
        rewardPool += rewardTopUp;
    }

    /// @notice View helper to compute untracked funds (stETH + ETH minus obligations).
    /// @return total Untracked balance across ETH and stETH.
    function yieldPool(address stethAddr) public view returns (uint256 total) {
        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        uint256 obligations = currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool;
        uint256 combined = ethBal + stBal;
        total = combined > obligations ? combined - obligations : 0;
    }

    /// @notice Stake excess reward pool into stETH based on bonds-configured ratio.
    function stakeForTargetRatio(address bondsAddr, address stethAddr, uint24 lvl) external {
        // Skip only for levels ending in 99 or 00 to avoid endgame edge cases.
        uint24 cycle = lvl % 100;
        if (cycle == 99 || cycle == 0) return;

        uint256 pool = rewardPool;
        if (pool == 0) return;

        uint256 rateBps = 10_000;
        if (bondsAddr != address(0)) {
            rateBps = IBonds(bondsAddr).stakeRateBps();
        }
        if (rateBps == 0) return;

        uint256 targetSt = (pool * rateBps) / 10_000; // stake against configured share of reward pool
        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        if (stBal >= targetSt) return;

        uint256 stakeAmount = targetSt - stBal;
        if (stakeAmount < REWARD_POOL_MIN_STAKE) return;

        _stakeEth(stethAddr, stakeAmount);
    }

    /// @notice Inform bonds of shutdown and transfer all assets to it.
    function drainToBonds(address bondsAddr, address stethAddr) external {
        IBonds bondContract = IBonds(bondsAddr);
        bondContract.notifyGameOver();

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        bondContract.payBonds{value: ethBal}(0, stBal, 0);
    }

    function _stakeEth(address stethAddr, uint256 amount) private {
        // Best-effort staking; skip if stETH deposits are paused or unavailable.
        try IStETHLite(stethAddr).submit{value: amount}(address(0)) returns (uint256 minted) {
            minted;
        } catch {
            return;
        }
    }
}
