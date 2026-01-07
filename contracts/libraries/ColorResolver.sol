// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployConstants} from "../DeployConstants.sol";
import "../interfaces/IDegenerusAffiliate.sol";
import "../interfaces/IconRendererTypes.sol";

/// @title ColorResolver
/// @notice Shared color resolution logic with referrer cascade
/// @dev Can be inherited by renderer contracts to provide unified color resolution
abstract contract ColorResolver {
    address private constant affiliateProgram = DeployConstants.AFFILIATE;
    IColorRegistry internal constant registry = IColorRegistry(DeployConstants.ICON_COLOR_REGISTRY);

    /// @notice Resolve color with full cascade: token → owner → referrer → upline → default
    /// @param nftContract The NFT contract address
    /// @param tokenId The token ID
    /// @param channel Color channel (0=outline, 1=flame, 2=diamond, 3=square)
    /// @param defColor Fallback color if no overrides found
    /// @return The resolved color hex string
    function _resolveColor(
        address nftContract,
        uint256 tokenId,
        uint8 channel,
        string memory defColor
    ) internal view returns (string memory) {
        // Per-token override
        string memory s = registry.tokenColor(nftContract, tokenId, channel);
        if (bytes(s).length != 0) return s;

        // Owner default (will revert if token doesn't exist, which is fine for gamepieces)
        address owner_ = IERC721Lite(nftContract).ownerOf(tokenId);
        s = registry.addressColor(owner_, channel);
        if (bytes(s).length != 0) return s;

        // Referrer default
        address ref = _getReferrer(owner_);
        if (ref != address(0)) {
            s = registry.addressColor(ref, channel);
            if (bytes(s).length != 0) return s;

            // Upline default
            address up = _getReferrer(ref);
            if (up != address(0)) {
                s = registry.addressColor(up, channel);
                if (bytes(s).length != 0) return s;
            }
        }
        return defColor;
    }

    /// @notice Resolve color with try/catch on ownerOf (for trophies that may be burned)
    /// @param nftContract The NFT contract address
    /// @param tokenId The token ID
    /// @param channel Color channel (0=outline, 1=flame, 2=diamond, 3=square)
    /// @param defColor Fallback color if no overrides found
    /// @return The resolved color hex string
    function _resolveColorSafe(
        address nftContract,
        uint256 tokenId,
        uint8 channel,
        string memory defColor
    ) internal view returns (string memory) {
        // Per-token override
        string memory s = registry.tokenColor(nftContract, tokenId, channel);
        if (bytes(s).length != 0) return s;

        // Owner default (with try/catch for burned tokens)
        address owner_;
        try IERC721Lite(nftContract).ownerOf(tokenId) returns (address o) {
            owner_ = o;
        } catch {
            owner_ = address(0);
        }
        s = registry.addressColor(owner_, channel);
        if (bytes(s).length != 0) return s;

        // Referrer default
        address ref = _getReferrer(owner_);
        if (ref != address(0)) {
            s = registry.addressColor(ref, channel);
            if (bytes(s).length != 0) return s;

            // Upline default
            address up = _getReferrer(ref);
            if (up != address(0)) {
                s = registry.addressColor(up, channel);
                if (bytes(s).length != 0) return s;
            }
        }
        return defColor;
    }

    function _getReferrer(address user) private view returns (address) {
        if (user == address(0)) return address(0);
        return IDegenerusAffiliate(affiliateProgram).getReferrer(user);
    }
}
