// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";

interface IBonds {
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable;
    function notifyGameOver() external;
    function requiredCoverNext() external view returns (uint256 required);
    function rewardStakeTargetBps() external view returns (uint16);
}

interface IVaultEscrowCoin {
    function vaultEscrow(uint256 amount) external;
}

interface IStETHLite {
    function balanceOf(address account) external view returns (uint256);
    function submit(address referral) external payable returns (uint256);
}

/**
 * @title DegenerusGameBondModule
 * @notice Delegate-called module for bond upkeep, staking, and shutdown flows.
 *         The storage layout mirrors the core contract so writes land in the parent via `delegatecall`.
 */
contract DegenerusGameBondModule is DegenerusGameStorage {
    uint256 private constant MIN_STAKE = 0.01 ether;

    /// @notice Handle bond funding/resolve work during map jackpot prep.
    function bondMaintenanceForMap(
        address bondsAddr,
        address stethAddr,
        address coinAddr,
        uint24 lvl,
        uint256 rngWord
    ) external {
        IBonds bondContract = IBonds(bondsAddr);

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;

        uint256 obligations = currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool;
        if (lvl % 100 == 0) {
            unchecked {
                obligations += bafHundredPool; // include reserved reward slices so they cannot be skimmed as “yield” on level 100. Decimator already ran
            }
        }
        uint256 combined = ethBal + stBal;
        uint256 yieldTotal = combined > obligations ? combined - obligations : 0;

        // Mintable coin: each of vault and bonds receives 5% of the nextPrizePool value (priced in coin units).
        uint256 coinSlice = (nextPrizePool * priceCoin) / price; // coin equivalent of nextPrizePool
        coinSlice = coinSlice / 20; // 5%

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
        IVaultEscrowCoin(coinAddr).vaultEscrow(coinSlice);
        bondContract.payBonds{value: ethSpend}(coinSlice, stSpend, rngWord);
        rewardPool += rewardTopUp;
    }

    /// @notice View helper to compute untracked funds (stETH + ETH minus obligations).
    /// @return total Untracked balance across ETH and stETH.
    function yieldPool(address stethAddr) public view returns (uint256 total) {
        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        uint256 obligations = currentPrizePool + nextPrizePool + rewardPool + claimablePool + bondPool;
        uint256 decPool = decimatorHundredPool;
        uint256 bafPool = bafHundredPool;
        if (decPool != 0 || bafPool != 0) {
            unchecked {
                obligations += decPool + bafPool; // only non-zero during level-100 specials
            }
        }
        uint256 combined = ethBal + stBal;
        total = combined > obligations ? combined - obligations : 0;
    }

    /// @notice Stake excess ETH into stETH to approach the bonds-configured target ratio.
    function stakeForTargetRatio(address bondsAddr, address stethAddr, uint24 lvl) external {
        uint24 cycle = lvl % 100;
        if (cycle == 99 || cycle == 0) return;

        uint16 targetBps = IBonds(bondsAddr).rewardStakeTargetBps();
        if (targetBps > 10_000) return;
        if (targetBps == 0) targetBps = 10_000; // default to fully staking non-reserved ETH

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        if (ethBal == 0) return;

        // Keep claimable winnings liquid in ETH; everything else can be staked subject to the ratio target.
        uint256 ethReserve = claimablePool;
        if (ethBal <= ethReserve) return;
        uint256 ethStakeable = ethBal - ethReserve;

        // Work with the stakeable ETH plus existing stETH to hit the target ratio.
        uint256 totalStakeable = stBal + ethStakeable;
        if (totalStakeable == 0) return;

        uint256 targetSt = (totalStakeable * uint256(targetBps)) / 10_000;
        if (targetSt <= stBal) return;

        uint256 needed = targetSt - stBal;
        if (needed == 0) return;

        uint256 stakeAmt = needed < ethStakeable ? needed : ethStakeable;
        if (stakeAmt < MIN_STAKE) return;

        try IStETHLite(stethAddr).submit{value: stakeAmt}(address(0)) returns (uint256) {
            // mint amount ignored; accounting tracks notional via rewardPool/obligations
        } catch {
            // Swallow failures to avoid blocking advanceGame.
        }
    }

    /// @notice Inform bonds of shutdown and transfer all assets to it.
    function drainToBonds(address bondsAddr, address stethAddr) external {
        IBonds bondContract = IBonds(bondsAddr);
        bondContract.notifyGameOver();

        // Lock bond accounting and zero in-game pools before handing assets to bonds to avoid post-drain credits.
        bondGameOver = true;
        bondPool = 0;
        currentPrizePool = 0;
        nextPrizePool = 0;
        rewardPool = 0;
        claimablePool = 0;
        decimatorHundredPool = 0;
        bafHundredPool = 0;
        dailyJackpotBase = 0;

        uint256 stBal = IStETHLite(stethAddr).balanceOf(address(this));
        uint256 ethBal = address(this).balance;
        bondContract.payBonds{value: ethBal}(0, stBal, 0);
    }
}
