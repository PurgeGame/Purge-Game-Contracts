// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDegenerusGameExternal} from "./IDegenerusGameExternal.sol";

enum MintPaymentKind {
    DirectEth,
    Claimable,
    Combined
}

interface IDegenerusGame is IDegenerusGameExternal {
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
    function creditBondWinnings(address player) external payable;

    function burnTokens(uint256[] calldata tokenIds) external;

    /// @notice Sample up to 100 trait burn tickets from a random trait and recent level (last 20).
    function sampleTraitTickets(uint256 entropy) external view returns (uint24 lvl, uint8 trait, address[] memory tickets);

    /// @notice Return the exterminator address for a given level (level index is 1-based).
    function levelExterminator(uint24 lvl) external view returns (address);
}
