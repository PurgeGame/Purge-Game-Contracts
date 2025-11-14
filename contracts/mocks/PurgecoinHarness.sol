// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Purgecoin} from "../Purgecoin.sol";

contract PurgecoinHarness is Purgecoin {
    function harnessSetStakeLevelComplete(uint24 level) external {
        stakeLevelComplete = level;
    }
}
