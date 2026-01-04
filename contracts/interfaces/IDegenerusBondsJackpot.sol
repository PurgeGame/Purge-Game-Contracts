// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal bond interface for jackpot-related deposits.
interface IDegenerusBondsJackpot {
    function purchasesEnabled() external view returns (bool);
    function depositCurrentFor(address beneficiary) external payable returns (uint256 scoreAwarded);
    function depositFromGame(address beneficiary, uint256 amount) external returns (uint256 scoreAwarded);
}
