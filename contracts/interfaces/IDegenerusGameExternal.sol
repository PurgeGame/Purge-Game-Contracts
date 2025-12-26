// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice External jackpot credits wired into DegenerusGame.
interface IDegenerusGameExternal {
    /// @notice Credit a decimator jackpot claim into the game's claimable balance.
    /// @param account Player address to credit.
    /// @param amount  Amount in wei to credit.
    function creditDecJackpotClaim(address account, uint256 amount) external;

    /// @notice Batch variant to credit decimator jackpot claims.
    /// @param accounts Player addresses to credit.
    /// @param amounts  Wei amounts to credit per player.
    function creditDecJackpotClaimBatch(address[] calldata accounts, uint256[] calldata amounts) external;
}
