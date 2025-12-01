// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPurgeGameExternal} from "./IPurgeGameExternal.sol";

interface IPurgeGame is IPurgeGameExternal {
    function getTraitRemainingQuad(
        uint8[4] calldata traitIds
    ) external view returns (uint16 lastExterminated, uint24 currentLevel, uint32[4] memory remaining);

    function level() external view returns (uint24);

    function gameState() external view returns (uint8);

    function currentPhase() external view returns (uint8);

    function mintPrice() external view returns (uint256);

    function coinPriceUnit() external view returns (uint256);

    function prizePoolTargetView() external view returns (uint256);

    function getEarlyPurgePercent() external view returns (uint8);

    function decWindow() external view returns (bool on, uint24 lvl);

    function isBafLevelActive(uint24 lvl) external view returns (bool);

    function principalStEthBalance() external view returns (uint256);

    function purchaseInfo()
        external
        view
        returns (uint24 lvl, uint8 gameState_, uint8 phase_, bool rngLocked_, uint256 priceWei, uint256 priceCoinUnit);

    function ethMintLevelCount(address player) external view returns (uint24);

    function ethMintStreakCount(address player) external view returns (uint24);

    function ethMintLastLevel(address player) external view returns (uint24);

    function enqueueMap(address buyer, uint32 quantity) external;

    function recordMint(
        address player,
        uint24 lvl,
        bool coinMint,
        uint256 costWei,
        uint32 mintUnits
    ) external payable returns (uint256 coinReward);

    function rngLocked() external view returns (bool);

    function purchaseWithClaimable(bool mapPurchase) external;

    /// @notice Sample up to 100 trait purge tickets from a random trait and recent level (last 20).
    function sampleTraitTickets(uint256 entropy) external view returns (uint24 lvl, uint8 trait, address[] memory tickets);
}
