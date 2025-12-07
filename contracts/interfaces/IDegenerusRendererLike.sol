// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IDegenerusRendererLike {
    function setStartingTraitRemaining(uint32[256] calldata values) external;
}
