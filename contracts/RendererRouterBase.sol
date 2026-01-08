// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ContractAddresses} from "./ContractAddresses.sol";

/// @title RendererRouterBase
/// @notice Generic safe upgrade router for tokenURI rendering with fallback
/// @dev Uses staticcall with gas limits to prevent reverts in tokenURI calls
abstract contract RendererRouterBase {
    error NotAdmin();

    uint256 private constant PRIMARY_GAS = 1_000_000;
    uint256 private constant MIN_FALLBACK_GAS = 200_000;

    address public primary;

    event PrimaryRendererUpdated(address indexed previous, address indexed next);

    /// @notice Get the fallback renderer address (immutable per deployment)
    /// @dev Must be implemented by child contract
    function fallbackRenderer() internal view virtual returns (address);

    /// @notice Get the function selector for tokenURI calls
    /// @dev Must be implemented by child contract (e.g., ITokenRenderer.tokenURI.selector)
    function tokenURISelector() internal view virtual returns (bytes4);

    /// @notice Update the primary renderer address
    /// @dev Only callable by admin
    function setPrimary(address newRenderer) public {
        if (msg.sender != ContractAddresses.ADMIN) revert NotAdmin();
        address prev = primary;
        primary = newRenderer;
        emit PrimaryRendererUpdated(prev, newRenderer);
    }

    /// @notice Main routing logic: try primary, then fallback
    /// @dev Internal function to be called by child contract's tokenURI
    function _routeTokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) internal view returns (string memory) {
        (bool ok, string memory uri) = _callPrimary(tokenId, data, extras);
        if (ok) return uri;
        (ok, uri) = _callRenderer(fallbackRenderer(), tokenId, data, extras, gasleft());
        if (ok) return uri;
        return "";
    }

    function _callPrimary(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) private view returns (bool ok, string memory uri) {
        address target = primary;
        if (target == address(0)) return (false, "");
        if (PRIMARY_GAS + MIN_FALLBACK_GAS > gasleft()) return (false, "");
        return _callRenderer(target, tokenId, data, extras, PRIMARY_GAS);
    }

    function _callRenderer(
        address target,
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras,
        uint256 gasLimit
    ) private view returns (bool ok, string memory uri) {
        if (gasLimit == 0) return (false, "");
        bytes memory payload = abi.encodeWithSelector(tokenURISelector(), tokenId, data, extras);
        (bool success, bytes memory ret) = target.staticcall{gas: gasLimit}(payload);
        if (!success || ret.length < 64) return (false, "");
        uint256 offset;
        uint256 len;
        assembly {
            offset := mload(add(ret, 0x20))
            len := mload(add(ret, 0x40))
        }
        if (offset != 0x20) return (false, "");
        if (len > ret.length - 0x40) return (false, "");
        uri = abi.decode(ret, (string));
        if (bytes(uri).length == 0) return (false, "");
        return (true, uri);
    }
}
