// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Operation types that trusted external contracts can request on DegenerusGame.
enum DegenerusGameExternalOp {
    DecJackpotClaim
}

interface IDegenerusGameExternal {
    /// @notice Apply a trusted state transition initiated by an external module.
    /// @param op      The operation being requested.
    /// @param account Recipient/player address to credit (when applicable).
    /// @param amount  Amount in wei to apply for the operation.
    function applyExternalOp(DegenerusGameExternalOp op, address account, uint256 amount) external;

    /// @notice Batched variant of applyExternalOp to aggregate accounting updates.
    /// @param op       Operation selector.
    /// @param accounts Recipients to credit.
    /// @param amounts  Wei amounts to apply per recipient.
    function applyExternalOpBatch(
        DegenerusGameExternalOp op,
        address[] calldata accounts,
        uint256[] calldata amounts
    ) external;
}
