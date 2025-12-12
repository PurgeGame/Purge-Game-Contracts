// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameEndgameModule} from "../modules/DegenerusGameEndgameModule.sol";
import {IDegenerusAffiliate} from "../interfaces/IDegenerusAffiliate.sol";

/// @dev Calls the endgame module directly (no delegatecall) for focused payout/trophy routing tests.
contract EndgameHarness is DegenerusGameEndgameModule {
    function setAffiliateProgramAddr(address affiliateAddr) external {
        affiliateProgramAddr = affiliateAddr;
    }

    function setTrophies(address trophiesAddr) external {
        trophies = trophiesAddr;
    }

    function setBonds(address bondsAddr) external {
        bonds = bondsAddr;
    }

    function setRewardPool(uint256 amount) external {
        rewardPool = amount;
    }

    function claimableWinningsOf(address player) external view returns (uint256) {
        return claimableWinnings[player];
    }

    /// @dev Minimal implementation required by the module when called outside `DegenerusGame` via delegatecall.
    function affiliatePayoutAddress(address player) external view returns (address recipient, address affiliateOwner) {
        (affiliateOwner, ) = IDegenerusAffiliate(affiliateProgramAddr).syntheticMapInfo(player);
        recipient = affiliateOwner == address(0) ? player : affiliateOwner;
    }
}

