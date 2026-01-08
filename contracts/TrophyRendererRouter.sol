// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContractAddresses} from "./ContractAddresses.sol";
import {RendererRouterBase} from "./RendererRouterBase.sol";

/// @notice Trophy metadata renderer interface.
interface ITrophyRenderer {
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) external view returns (string memory);
}

/// @notice Safe upgrade router for trophy tokenURI rendering.
/// @dev Uses staticcall and a fallback renderer to prevent tokenURI reverts.
contract TrophyRendererRouter is RendererRouterBase {
    function fallbackRenderer() internal view override returns (address) {
        return ContractAddresses.RENDERER_TROPHY;
    }

    function tokenURISelector() internal view override returns (bytes4) {
        return ITrophyRenderer.tokenURI.selector;
    }

    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) external view returns (string memory) {
        return _routeTokenURI(tokenId, data, extras);
    }
}
