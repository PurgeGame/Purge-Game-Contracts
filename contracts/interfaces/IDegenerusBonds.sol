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
    /// @param ticketsEnabled True to pay mint ticket jackpots during presale.
    /// @return advanced True if the presale payout advanced.
    function runPresaleDailyFromGame(
        uint256 rngWord,
        uint48 day,
        bool ticketsEnabled
    ) external returns (bool advanced);

    /// @notice Run daily ticket coin jackpot after sales open.
    /// @param rngWord RNG word from advanceGame.
    /// @param day Day index being processed.
    /// @return advanced True if the ticket jackpot advanced.
    function runTicketJackpotFromGame(uint256 rngWord, uint48 day) external returns (bool advanced);

    /// @notice Record a mint ticket entry for daily coin jackpots.
    /// @param player Ticket owner.
    /// @param mintUnits Ticket weight (1 MAP = 1, 1 NFT = 4).
    /// @param day Day index when the mint occurred.
    function recordTicketFromGame(address player, uint32 mintUnits, uint48 day) external;

    /// @notice Resolve bonds game-over with supplied entropy.
    /// @param rngWord RNG word from advanceGame.
    function gameOverWithEntropy(uint256 rngWord) external;

    /// @notice True once bonds has attempted game-over entropy.
    function gameOverEntropyAttempted() external view returns (bool);

    /// @notice Set or clear the RNG lock on bond operations.
    /// @param locked True to block bond operations during VRF pending window.
    function setRngLock(bool locked) external;
}
