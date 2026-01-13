// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

enum MintPaymentKind {
    DirectEth,
    Claimable,
    Combined
}

interface IDegenerusGame {
    function getTraitRemainingQuad(
        uint8[4] calldata traitIds
    ) external view returns (uint16 lastExterminated, uint24 currentLevel, uint32[4] memory remaining);

    function level() external view returns (uint24);

    function gameState() external view returns (uint8);

    function mintPrice() external view returns (uint256);

    function decWindow() external view returns (bool on, uint24 lvl);

    function decWindowOpenFlag() external view returns (bool);

    function purchaseInfo()
        external
        view
        returns (uint24 lvl, uint8 gameState_, bool lastPurchaseDay_, bool rngLocked_, uint256 priceWei);

    function ethMintLevelCount(address player) external view returns (uint24);

    function ethMintStreakCount(address player) external view returns (uint24);

    function playerBonusMultiplier(address player) external view returns (uint256);

    function enqueueMap(address buyer, uint32 quantity) external;

    function recordMint(
        address player,
        uint24 lvl,
        uint256 costWei,
        uint32 mintUnits,
        MintPaymentKind payKind
    ) external payable returns (uint256 coinReward, uint256 newClaimableBalance);

    function recordCoinflipDeposit(uint256 amount) external;

    /// @notice Credit a decimator jackpot claim into the game's claimable balance.
    /// @param account Player address to credit.
    /// @param amount  Amount in wei to credit.
    function creditDecJackpotClaim(address account, uint256 amount) external;

    /// @notice Batch variant to credit decimator jackpot claims.
    /// @param accounts Player addresses to credit.
    /// @param amounts  Wei amounts to credit per player.
    function creditDecJackpotClaimBatch(address[] calldata accounts, uint256[] calldata amounts) external;

    function rngLocked() external view returns (bool);

    /// @notice Sample up to 4 trait burn tickets from a random trait and recent level (last 20).
    function sampleTraitTickets(uint256 entropy) external view returns (uint24 lvl, uint8 trait, address[] memory tickets);

    /// @notice Return the exterminator address for a given level (level index is 1-based).
    function levelExterminator(uint24 lvl) external view returns (address);
}
