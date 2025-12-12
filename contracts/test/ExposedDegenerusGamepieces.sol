// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGamepieces} from "../DegenerusGamepieces.sol";

contract ExposedDegenerusGamepieces is DegenerusGamepieces {
    constructor(address regularRenderer_, address coin_, address affiliateProgram_, address vault_)
        DegenerusGamepieces(regularRenderer_, coin_, affiliateProgram_, vault_)
    {}

    function exposedMint(address to, uint256 quantity) external {
        _mint(to, quantity);
    }
}

