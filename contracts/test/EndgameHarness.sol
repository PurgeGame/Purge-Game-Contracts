// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameEndgameModule} from "../modules/DegenerusGameEndgameModule.sol";

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
}
