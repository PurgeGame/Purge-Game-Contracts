// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameExternal} from "./IPurgeGameExternal.sol";

enum MintPaymentKind {
    DirectEth,
    Claimable,
    BongCredit,
    Combined
}

interface IPurgeGame is IPurgeGameExternal {
    function getTraitRemainingQuad(
        uint8[4] calldata traitIds
    ) external view returns (uint16 lastExterminated, uint24 currentLevel, uint32[4] memory remaining);

    function level() external view returns (uint24);

    function gameState() external view returns (uint8);

    function mintPrice() external view returns (uint256);

    function coinPriceUnit() external view returns (uint256);

    function prizePoolTargetView() external view returns (uint256);

    function decWindow() external view returns (bool on, uint24 lvl);

    function isBafLevelActive(uint24 lvl) external view returns (bool);

    function purchaseInfo()
        external
        view
        returns (uint24 lvl, uint8 gameState_, bool lastPurchaseDay_, bool rngLocked_, uint256 priceWei, uint256 priceCoinUnit);

    function ethMintLevelCount(address player) external view returns (uint24);

    function ethMintStreakCount(address player) external view returns (uint24);

    function ethMintLastLevel(address player) external view returns (uint24);

    function enqueueMap(address buyer, uint32 quantity) external;

    function recordMint(
        address player,
        uint24 lvl,
        bool coinMint,
        uint256 costWei,
        uint32 mintUnits,
        MintPaymentKind payKind
    ) external payable returns (uint256 coinReward);

    function rngLocked() external view returns (bool);
    function bongCreditOf(address player) external view returns (uint256);
    function addBongCredit(address player, uint256 amount) external payable;
    function creditBongWinnings(address player) external payable;

    /// @notice Sample up to 100 trait purge tickets from a random trait and recent level (last 20).
    function sampleTraitTickets(uint256 entropy) external view returns (uint24 lvl, uint8 trait, address[] memory tickets);

    /// @notice Return the exterminator address for a given level (level index is 1-based).
    function levelExterminator(uint24 lvl) external view returns (address);
}
