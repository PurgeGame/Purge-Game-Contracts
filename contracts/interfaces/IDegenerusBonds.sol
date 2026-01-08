// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Interface for DegenerusBonds operations called from game and modules.
interface IDegenerusBonds {
    /// @notice Send ETH/stETH/BURNIE to bonds for jackpot funding or vault sweep.
    /// @param coinAmount BURNIE amount to credit (minted via vaultEscrow beforehand).
    /// @param stEthAmount stETH amount to transfer from game to bonds.
    /// @param rngWord VRF entropy for bond jackpot resolution (0 if not applicable).
    function payBonds(uint256 coinAmount, uint256 stEthAmount, uint256 rngWord) external payable;

    /// @notice Signal game-over to bonds, enabling shutdown resolution flow.
    function notifyGameOver() external;

    /// @notice Query the ETH cover required for upcoming bond maturities.
    /// @param stopAt Maximum bondPool value to consider (optimization hint).
    /// @return required ETH needed to cover next maturity obligations.
    function requiredCoverNext(uint256 stopAt) external view returns (uint256 required);

    /// @notice Get the admin-configured target ratio for stETH staking (basis points).
    /// @return Target percentage of stakeable funds to hold as stETH (0-10000).
    function rewardStakeTargetBps() external view returns (uint16);

    /// @notice Run bond maintenance operations (resolution, payouts, etc.).
    /// @param rngWord VRF random word for any RNG-dependent operations.
    /// @param workCapOverride Gas budget override (0 = use default).
    /// @return done True if all maintenance is complete.
    function bondMaintenance(uint256 rngWord, uint32 workCapOverride) external returns (bool done);

    /// @notice Run daily presale payouts using game-supplied entropy.
    /// @param rngWord RNG word from advanceGame.
    /// @param day Day index being processed.
    /// @param lastPurchaseDay True if prize pool target was met today.
    /// @return advanced True if the presale payout advanced.
    function runPresaleDailyFromGame(
        uint256 rngWord,
        uint48 day,
        bool lastPurchaseDay
    ) external returns (bool advanced);

    /// @notice Resolve bonds game-over with supplied entropy.
    /// @param rngWord RNG word from advanceGame.
    function gameOverWithEntropy(uint256 rngWord) external;

    /// @notice True once bonds has attempted game-over entropy.
    function gameOverEntropyAttempted() external view returns (bool);

    /// @notice Check if gamepiece/MAP purchases are enabled (presale gating).
    /// @dev Purchases enabled when presale raised > 40 ETH OR presale ended.
    /// @return True if gamepiece/MAP purchases are enabled, false otherwise.
    function gamepiecePurchasesEnabled() external view returns (bool);
}
