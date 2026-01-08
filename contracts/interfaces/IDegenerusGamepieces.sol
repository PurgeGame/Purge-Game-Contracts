// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal interface for DegenerusGamepieces used by the game contract.
interface IDegenerusGamepieces {
    function purchaseCount() external view returns (uint32);
    function purchaseCounts() external view returns (uint32 prePurchase, uint32 purchasePhase);

    function processPendingMints(
        uint32 playersToProcess,
        uint32 multiplier,
        uint256 rngWord
    ) external returns (bool finished);

    function advanceBase() external;

    function burnFromGame(address owner, uint256[] calldata tokenIds) external;

    function currentBaseTokenId() external view returns (uint256);

    function tokensOwed(address player) external view returns (uint32);

    function processDormant(uint32 maxCount) external returns (bool worked);

    /// @notice Queue reward gamepiece mints for a player (processed during advanceGame).
    /// @param player Address to receive the gamepieces.
    /// @param quantity Number of gamepieces to mint.
    function queueRewardMints(address player, uint32 quantity) external;
}
