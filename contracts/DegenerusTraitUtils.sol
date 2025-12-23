// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared helpers for generating and packing Degenerus trait identifiers.
library DegenerusTraitUtils {
    /// @dev Map a 32-bit random input to an 0..7 bucket with a fixed piecewise distribution.
    function weightedBucket(uint32 rnd) internal pure returns (uint8) {
        unchecked {
            uint32 scaled = uint32((uint64(rnd) * 75) >> 32);
            if (scaled < 10) return 0;
            if (scaled < 20) return 1;
            if (scaled < 30) return 2;
            if (scaled < 40) return 3;
            if (scaled < 49) return 4;
            if (scaled < 58) return 5;
            if (scaled < 67) return 6;
            return 7;
        }
    }

    /// @dev Produce a 6-bit trait id from a 64-bit random value.
    function traitFromWord(uint64 rnd) internal pure returns (uint8) {
        uint8 category = weightedBucket(uint32(rnd));
        uint8 sub = weightedBucket(uint32(rnd >> 32));
        return (category << 3) | sub;
    }

    /// @dev Pack the 4 quadrant traits derived from a 256-bit random seed.
    function packedTraitsFromSeed(uint256 rand) internal pure returns (uint32) {
        uint8 traitA = traitFromWord(uint64(rand));
        uint8 traitB = traitFromWord(uint64(rand >> 64)) | 64;
        uint8 traitC = traitFromWord(uint64(rand >> 128)) | 128;
        uint8 traitD = traitFromWord(uint64(rand >> 192)) | 192;

        return uint32(traitA) | (uint32(traitB) << 8) | (uint32(traitC) << 16) | (uint32(traitD) << 24);
    }

    /// @dev Deterministically derive packed traits for a token id.
    function packedTraitsForToken(uint256 tokenId) internal pure returns (uint32) {
        return packedTraitsFromSeed(uint256(keccak256(abi.encodePacked(tokenId))));
    }
}
