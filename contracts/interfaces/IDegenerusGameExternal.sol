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
    /// @param lvl     Level context for the request (used by callers for bookkeeping).
    function applyExternalOp(DegenerusGameExternalOp op, address account, uint256 amount, uint24 lvl) external;
}
