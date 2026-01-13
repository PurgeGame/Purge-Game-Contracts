// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameStorage} from "../storage/DegenerusGameStorage.sol";
import {ContractAddresses} from "../ContractAddresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DegenerusGameGameOverModule
 * @notice Handles game over logic including jackpot distribution and final sweeps.
 * @dev Executed via delegatecall from DegenerusGame. Inherits storage layout.
 */
contract DegenerusGameGameOverModule is DegenerusGameStorage {
    /// @dev stETH token interface
    IERC20 private constant steth = IERC20(ContractAddresses.STETH_TOKEN);

    /// @dev Generic revert for error conditions
    error E();

    /// @notice Sweep game funds on gameover - distributes remaining funds via jackpot or vault sweep.
    /// @dev Called when liveness guards trigger (2.5yr deploy or 365-day inactivity).
    ///      Transitions game to GAMEOVER (86).
    ///
    ///      LEVEL 1 TIMEOUT (2.5 years): Award all remaining funds via daily jackpot.
    ///      OTHER TIMEOUTS (365 days): Split 50/50 - half to vault, half to cross-level jackpot.
    ///      Final sweep of all remaining funds occurs 1 month after gameover.
    ///
    ///      VRF FALLBACK: Uses rngWordByDay which is set by _gameOverEntropy. If Chainlink VRF
    ///      is broken, waits 3 days then uses earliest historical VRF word as secure fallback.
    ///      This prevents manipulation since historical VRF was already verified on-chain.
    /// @param day Day index for RNG word lookup.
    function handleGameOverDrain(uint48 day) external {
        if (gameOverFinalJackpotPaid) return; // Already processed

        uint256 ethBal = address(this).balance;
        uint256 stBal = steth.balanceOf(address(this));
        uint256 totalFunds = ethBal + stBal;

        // Calculate available funds (excluding claimable winnings reserve)
        uint256 available = totalFunds > claimablePool ? totalFunds - claimablePool : 0;

        gameState = GAME_STATE_GAMEOVER; // Terminal state
        gameOverTime = uint48(block.timestamp);
        gameOverFinalJackpotPaid = true;

        if (available == 0) return; // Nothing to distribute

        // Get RNG word for jackpot selection (includes VRF fallback after 3 days)
        uint256 rngWord = rngWordByDay[day];
        if (rngWord == 0) return; // RNG not ready yet (wait for fallback)

        // LEVEL 1 TIMEOUT: Award all remaining funds via daily jackpot
        if (level == 1) {
            // Convert stETH to ETH if needed for jackpot pool
            if (stBal > 0) {
                rewardPool += stBal;
            }
            // Award all available funds via daily jackpot mechanism
            // Note: This will be handled by the main contract calling payDailyJackpot
            return;
        }

        // OTHER TIMEOUTS: Split 50/50 between vault and cross-level jackpot
        uint256 halfToVault = available / 2;
        uint256 halfToJackpot = available - halfToVault;

        // Send half to vault (prioritize ETH, then stETH)
        if (halfToVault > 0) {
            if (ethBal >= halfToVault) {
                (bool ok, ) = payable(ContractAddresses.VAULT).call{value: halfToVault}("");
                if (!ok) revert E();
            } else {
                // Send all ETH to vault
                if (ethBal > 0) {
                    (bool ok, ) = payable(ContractAddresses.VAULT).call{value: ethBal}("");
                    if (!ok) revert E();
                }
                // Send remaining from stETH
                uint256 stethToVault = halfToVault - ethBal;
                if (!steth.transfer(ContractAddresses.VAULT, stethToVault)) revert E();
            }
        }

        // Award other half via cross-level jackpot
        if (halfToJackpot > 0) {
            _payGameOverCrossLevelJackpot(halfToJackpot, rngWord);
        }
    }

    /// @dev Distributes gameover jackpot to one random ticket from each level.
    ///      Selects one ticket from each level before the current level, splits pot evenly.
    /// @param amount Total ETH amount to distribute.
    /// @param rngWord VRF random word for winner selection.
    function _payGameOverCrossLevelJackpot(uint256 amount, uint256 rngWord) private {
        if (amount == 0) return;

        uint24 currentLevel = level;
        if (currentLevel <= 1) return; // No previous levels to award

        // First pass: count eligible levels (levels with at least one ticket)
        uint24 eligibleLevels = 0;
        for (uint24 lvl = 1; lvl < currentLevel; ) {
            bool hasTickets = false;
            for (uint16 traitId = 0; traitId < 256; ) {
                if (traitBurnTicket[lvl][uint8(traitId)].length > 0) {
                    hasTickets = true;
                    break;
                }
                unchecked { ++traitId; }
            }
            if (hasTickets) {
                unchecked { ++eligibleLevels; }
            }
            unchecked { ++lvl; }
        }

        if (eligibleLevels == 0) {
            // No tickets found - send all to vault instead
            if (amount <= address(this).balance) {
                (bool ok, ) = payable(ContractAddresses.VAULT).call{value: amount}("");
                if (!ok) revert E();
            } else {
                uint256 ethAvailable = address(this).balance;
                if (ethAvailable > 0) {
                    (bool ok, ) = payable(ContractAddresses.VAULT).call{value: ethAvailable}("");
                    if (!ok) revert E();
                }
                uint256 stethAmount = amount - ethAvailable;
                if (!steth.transfer(ContractAddresses.VAULT, stethAmount)) revert E();
            }
            return;
        }

        // Calculate payout per winner
        uint256 payoutPerWinner = amount / eligibleLevels;
        if (payoutPerWinner == 0) return;

        // Second pass: select winners and distribute
        uint256 entropyState = rngWord;
        for (uint24 lvl = 1; lvl < currentLevel; ) {
            // Count total tickets for this level
            uint256 totalTickets = 0;
            for (uint16 traitId = 0; traitId < 256; ) {
                totalTickets += traitBurnTicket[lvl][uint8(traitId)].length;
                unchecked { ++traitId; }
            }

            if (totalTickets == 0) {
                unchecked { ++lvl; }
                continue;
            }

            // Select a random ticket index
            entropyState = _entropyStep(entropyState);
            uint256 targetTicketIdx = entropyState % totalTickets;

            // Find the winner
            address winner;
            uint256 ticketCount = 0;
            for (uint16 traitId = 0; traitId < 256; ) {
                address[] storage holders = traitBurnTicket[lvl][uint8(traitId)];
                uint256 len = holders.length;
                if (ticketCount + len > targetTicketIdx) {
                    // Winner is in this trait's ticket array
                    winner = holders[targetTicketIdx - ticketCount];
                    break;
                }
                ticketCount += len;
                unchecked { ++traitId; }
            }

            // Credit the winner
            if (winner != address(0)) {
                claimableWinnings[winner] += payoutPerWinner;
                claimablePool += payoutPerWinner;
            }

            unchecked { ++lvl; }
        }
    }

    /// @notice Final sweep of all remaining funds to vault after 1 month post-gameover.
    /// @dev Called automatically by advanceGame when appropriate time has passed.
    ///      Only sweeps funds beyond claimablePool (preserves player winnings).
    function handleFinalSweep() external {
        if (gameOverTime == 0) return; // Game not over yet
        if (block.timestamp < uint256(gameOverTime) + 30 days) return; // Too early

        uint256 ethBal = address(this).balance;
        uint256 stBal = steth.balanceOf(address(this));
        uint256 totalFunds = ethBal + stBal;

        // Calculate available funds (excluding claimable winnings reserve)
        uint256 available = totalFunds > claimablePool ? totalFunds - claimablePool : 0;

        if (available == 0) return; // Nothing to sweep

        // Send all available funds to vault
        if (ethBal > claimablePool) {
            uint256 ethToVault = ethBal - claimablePool;
            (bool ok, ) = payable(ContractAddresses.VAULT).call{value: ethToVault}("");
            if (!ok) revert E();
        }

        // Sweep any remaining stETH
        if (stBal > 0) {
            if (!steth.transfer(ContractAddresses.VAULT, stBal)) revert E();
        }
    }

    /// @dev Xorshift PRNG step for deterministic entropy progression.
    function _entropyStep(uint256 state) private pure returns (uint256) {
        unchecked {
            state ^= state << 7;
            state ^= state >> 9;
            state ^= state << 8;
        }
        return state;
    }
}
