// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal hook surface that the trophy module needs from the NFT contract.
interface IPurgeGameNftModule {
    function nextTokenId() external view returns (uint256);

    function mintPlaceholders(uint256 quantity) external returns (uint256 startTokenId);

    function getBasePointers() external view returns (uint256 previousBase, uint256 currentBase);

    function setBasePointers(uint256 previousBase, uint256 currentBase) external;

    function packedOwnershipOf(uint256 tokenId) external view returns (uint256 packed);

    function transferTrophy(address from, address to, uint256 tokenId) external;

    function setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool staked) external;

    function clearApproval(uint256 tokenId) external;

    function incrementTrophySupply(uint256 amount) external;

    function decrementTrophySupply(uint256 amount) external;

    function sendEth(address to, uint256 amount) external;

    function gameAddress() external view returns (address);

    function coinAddress() external view returns (address);

    function rngLocked() external view returns (bool);

    function currentRngWord() external view returns (uint256);
}
