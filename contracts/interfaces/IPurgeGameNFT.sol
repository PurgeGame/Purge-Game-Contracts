// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPurgeGameNFT {
    function gameMint(address to, uint256 quantity) external returns (uint256 startTokenId);

    function tokenTraitsPacked(uint256 tokenId) external view returns (uint32);

    function purchaseCount() external view returns (uint32);

    function resetPurchaseCount() external;

    function finalizePurchasePhase(uint32 minted) external;

    function purge(address owner, uint256[] calldata tokenIds) external;

    function currentBaseTokenId() external view returns (uint256);

    function recordSeasonMinted(uint256 minted) external;

    function requestRng() external;

    function currentRngWord() external view returns (uint256);

    function rngLocked() external view returns (bool);

    function releaseRngLock() external;

    function isRngFulfilled() external view returns (bool);

    function processPendingMints(uint32 playersToProcess) external returns (bool finished);

    function tokensOwed(address player) external view returns (uint32);
}
