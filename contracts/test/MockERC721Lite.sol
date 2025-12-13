// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal ERC721-lite for renderer tests.
contract MockERC721Lite {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }
}

