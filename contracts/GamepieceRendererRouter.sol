// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContractAddresses} from "./ContractAddresses.sol";
import {RendererRouterBase} from "./RendererRouterBase.sol";

/// @notice Token metadata renderer interface (gamepieces).
interface ITokenRenderer {
    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory);
}

/// @notice Safe upgrade router for gamepiece tokenURI rendering.
/// @dev Uses staticcall and a fallback renderer to prevent tokenURI reverts.
contract GamepieceRendererRouter is RendererRouterBase {
    function fallbackRenderer() internal pure override returns (address) {
        return ContractAddresses.RENDERER_REGULAR;
    }

    function tokenURISelector() internal pure override returns (bytes4) {
        return ITokenRenderer.tokenURI.selector;
    }

    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata remaining
    ) external view returns (string memory) {
        return _routeTokenURI(tokenId, data, remaining);
    }
}
