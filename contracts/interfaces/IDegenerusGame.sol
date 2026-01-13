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

    /// @notice Queue reward mints and prize funding for a future level.
    function queueFutureRewardMints(
        address player,
        uint24 targetLevel,
        uint32 quantity,
        uint256 poolWei
    ) external;

    function futurePrizePoolView(uint24 lvl) external view returns (uint256);

    function futurePrizePoolTotalView() external view returns (uint256);

    function futureMintsOwedView(uint24 lvl, address player) external view returns (uint32);

    /// @notice Credit a decimator jackpot claim into the game's claimable balance.
    /// @param account Player address to credit.
    /// @param amount  Amount in wei to credit.
    function creditDecJackpotClaim(address account, uint256 amount) external;

    /// @notice Batch variant to credit decimator jackpot claims.
    /// @param accounts Player addresses to credit.
    /// @param amounts  Wei amounts to credit per player.
    function creditDecJackpotClaimBatch(address[] calldata accounts, uint256[] calldata amounts) external;

    function rngLocked() external view returns (bool);

    function startPurchasing() external;

    function lootboxStatus(address player, uint48 day) external view returns (uint256 amount, bool presale);

    function openLootBox(uint48 day) external;

    function startLootboxPresale() external;

    function endLootboxPresale() external;

    /// @notice Sample up to 4 trait burn tickets from a random trait and recent level (last 20).
    function sampleTraitTickets(uint256 entropy) external view returns (uint24 lvl, uint8 trait, address[] memory tickets);

    /// @notice Return the exterminator address for a given level (level index is 1-based).
    function levelExterminator(uint24 lvl) external view returns (address);

    /// @notice Purchase any combination of gamepieces, MAPs, and loot boxes with ETH or claimable.
    /// @dev Main entry point for all ETH/claimable purchases. For BURNIE purchases, use DegenerusGamepieces.purchase().
    ///      Spending all claimable winnings earns a 10% bonus across the combined purchase.
    /// @param gamepieceQuantity Number of gamepieces to purchase (0 to skip).
    /// @param mapQuantity Number of MAP tickets to purchase (0 to skip).
    /// @param lootBoxAmount ETH amount for loot boxes, minimum 0.01 ETH (0 to skip).
    /// @param affiliateCode Affiliate/referral code for all purchases.
    /// @param payKind Payment method (DirectEth, Claimable, or Combined).
    function purchase(
        uint256 gamepieceQuantity,
        uint256 mapQuantity,
        uint256 lootBoxAmount,
        bytes32 affiliateCode,
        MintPaymentKind payKind
    ) external payable;
}
