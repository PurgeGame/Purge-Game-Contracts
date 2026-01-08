// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContractAddresses} from "./ContractAddresses.sol";
import {RendererRouterBase} from "./RendererRouterBase.sol";

/// @title GenericRendererRouter
/// @notice Configurable safe upgrade router for tokenURI rendering with fallback
/// @dev Uses staticcall and a fallback renderer to prevent tokenURI reverts.
///      Can be deployed multiple times with different fallback renderers and selectors.
contract GenericRendererRouter is RendererRouterBase {
    /// @notice Fallback renderer address (immutable per deployment)
    address private immutable _fallback;

    /// @notice Function selector for tokenURI calls (immutable per deployment)
    bytes4 private immutable _selector;

    /// @notice Deploy a new renderer router
    /// @param fallback_ Address of the fallback renderer
    /// @param selector_ Function selector for tokenURI (e.g., ITokenRenderer.tokenURI.selector)
    constructor(address fallback_, bytes4 selector_) {
        _fallback = fallback_;
        _selector = selector_;
    }

    /// @inheritdoc RendererRouterBase
    function fallbackRenderer() internal view override returns (address) {
        return _fallback;
    }

    /// @inheritdoc RendererRouterBase
    function tokenURISelector() internal view override returns (bytes4) {
        return _selector;
    }

    /// @notice Main tokenURI routing function
    /// @param tokenId Token ID to render
    /// @param data Packed token data
    /// @param extras Additional parameters (e.g., remaining traits, score)
    /// @return Metadata URI string
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) external view returns (string memory) {
        return _routeTokenURI(tokenId, data, extras);
    }
}
