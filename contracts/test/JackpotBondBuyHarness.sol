// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameJackpotModule} from "../modules/DegenerusGameJackpotModule.sol";

/// @dev Test harness that can run the jackpot module directly (no delegatecall) while acting as the "game"
///      for DegenerusBonds.depositFromGame().
contract JackpotBondBuyHarness is DegenerusGameJackpotModule {
    // --- Wiring helpers ---
    function setBonds(address bonds_) external {
        bonds = bonds_;
    }

    function getBonds() external view returns (address) {
        return bonds;
    }

    function setLevel(uint24 lvl) external {
        level = lvl;
    }

    function seedTraitTicket(uint24 lvl, uint8 traitId, address holder) external {
        traitBurnTicket[lvl][traitId].push(holder);
    }

    // --- Minimal bond-bank surface (used by DegenerusBonds) ---
    function bondDeposit(bool trackPool) external payable {
        if (trackPool) {
            bondPool += msg.value;
        }
        // Untracked deposits fall through as surplus backing.
    }

    function bondCreditToClaimable(address, uint256) external {}

    function bondCreditToClaimableBatch(address[] calldata, uint256[] calldata) external {}

    function bondAvailable() external view returns (uint256) {
        return bondPool;
    }

    function ethMintStreakCount(address) external pure returns (uint24) {
        return 0;
    }

    // Accept rewardShare sent by DegenerusBonds for direct purchases.
    receive() external payable {
        rewardPool += msg.value;
    }
}
