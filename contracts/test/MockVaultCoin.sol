// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal coin stub implementing the vault hooks used by DegenerusVault in tests.
contract MockVaultCoin {
    address public vault;
    uint256 public vaultMintAllowance;

    function setVault(address vault_) external {
        vault = vault_;
    }

    function vaultEscrow(uint256 amount) external {
        vaultMintAllowance += amount;
    }

    function vaultMintTo(address, uint256) external {}
}

