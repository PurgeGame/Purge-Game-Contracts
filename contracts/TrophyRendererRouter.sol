// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeployConstants} from "./DeployConstants.sol";

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
contract TrophyRendererRouter is ITrophyRenderer {
    error NotAdmin();

    uint256 private constant PRIMARY_GAS = 1_000_000;
    uint256 private constant MIN_FALLBACK_GAS = 200_000;

    address private constant admin = DeployConstants.ADMIN;
    address public constant fallbackRenderer = DeployConstants.RENDERER_TROPHY;
    address public primary;
    event PrimaryRendererUpdated(address indexed previous, address indexed next);

    function setPrimary(address newRenderer) public {
        if (msg.sender != admin) revert NotAdmin();
        address prev = primary;
        primary = newRenderer;
        emit PrimaryRendererUpdated(prev, newRenderer);
    }

    function tokenURI(
        uint256 tokenId,
        uint256 data,
        uint32[4] calldata extras
    ) external view returns (string memory) {
        (bool ok, string memory uri) = _callPrimary(tokenId, data, extras);
        if (ok) return uri;
        (ok, uri) = _callRenderer(fallbackRenderer, tokenId, data, extras, gasleft());
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
        bytes memory payload = abi.encodeWithSelector(
            ITrophyRenderer.tokenURI.selector,
            tokenId,
            data,
            extras
        );
        (bool success, bytes memory ret) = target.staticcall{gas: gasLimit}(payload);
        if (!success || ret.length < 64) return (false, "");
        uint256 offset;
        uint256 len;
        assembly {
            offset := mload(add(ret, 0x20))
            len := mload(add(ret, 0x40))
        }
        if (offset != 0x20) return (false, "");
        if (ret.length < 0x40 + len) return (false, "");
        uri = abi.decode(ret, (string));
        if (bytes(uri).length == 0) return (false, "");
        return (true, uri);
    }
}
