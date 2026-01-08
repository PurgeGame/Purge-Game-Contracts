// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal bond interface for jackpot-related deposits.
interface IDegenerusBondsJackpot {
    function purchasesEnabled() external view returns (bool);
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded);
    function depositFromGame(address beneficiary, uint256 amount) external returns (uint256 scoreAwarded);
    function mintJackpotDgnrs(address beneficiary, uint256 amount, uint24 currLevel) external;

    /// @notice Unified entry point for game-awarded bond prizes.
    /// @dev Routes to depositFromGame when purchases are open, mintJackpotDgnrs when closed.
    ///      Bonds contract owns the routing logic based on its internal state.
    /// @param beneficiary Address receiving the bond prize.
    /// @param amount ETH amount to convert into bonds.
    /// @param lvl Current game level for DGNRS mint routing (when purchases closed).
    /// @return bondPoolShare Amount game should add to bondPool (half for deposits, full for mints).
    function awardFromGame(
        address beneficiary,
        uint256 amount,
        uint24 lvl
    ) external returns (uint256 bondPoolShare);
}
