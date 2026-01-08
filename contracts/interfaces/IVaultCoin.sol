// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface for tokens with vault mint allowance (BURNIE, DGNRS).
/// @dev Used by DegenerusVault, DegenerusBonds, and game modules for minting tokens
///      from vault escrow without requiring token transfers.
interface IVaultCoin {
    /// @notice Increase the vault's mint allowance without transferring tokens.
    /// @param amount Amount to add to vault's mint allowance.
    function vaultEscrow(uint256 amount) external;

    /// @notice Mint tokens to recipient from vault's allowance.
    /// @param to Recipient address.
    /// @param amount Amount to mint.
    function vaultMintTo(address to, uint256 amount) external;

    /// @notice View the vault's remaining mint allowance.
    /// @return Remaining amount available for vault minting.
    function vaultMintAllowance() external view returns (uint256);
}
