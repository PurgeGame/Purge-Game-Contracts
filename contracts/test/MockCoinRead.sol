// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal coin-like read interface for renderers.
contract MockCoinRead {
    address public affiliateProgram;
    address public admin;

    constructor(address affiliateProgram_, address admin_) {
        affiliateProgram = affiliateProgram_;
        admin = admin_;
    }

    function setAffiliateProgram(address affiliateProgram_) external {
        affiliateProgram = affiliateProgram_;
    }

    function setAdmin(address admin_) external {
        admin = admin_;
    }
}
