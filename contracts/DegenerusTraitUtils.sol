// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*+==============================================================================+
  |                                                                              |
  |                      DEGENERUS TRAIT UTILS LIBRARY                           |
  |                                                                              |
  |  Pure utility library for deterministic trait generation from random seeds.  |
  |  Used by DegenerusGamepieces to assign visual traits to gamepieces.                |
  |                                                                              |
  +==============================================================================+
  |                           TRAIT SYSTEM OVERVIEW                              |
  +==============================================================================+
  |                                                                              |
  |  TRAIT ID STRUCTURE (8 bits per trait):                                      |
  |  +------------------------------------------------------------------------+  |
  |  |  Bits 7-6: Quadrant identifier (0-3)                                   |  |
  |  |  Bits 5-3: Category bucket (0-7)                                       |  |
  |  |  Bits 2-0: Sub-bucket (0-7)                                            |  |
  |  |                                                                        |  |
  |  |  Format: [QQ][CCC][SSS] = 8 bits                                       |  |
  |  |                                                                        |  |
  |  |  • Quadrant: Which of 4 trait slots (A=0, B=1, C=2, D=3)               |  |
  |  |  • Category: Main trait category (8 options, weighted distribution)    |  |
  |  |  • Sub-bucket: Variant within category (8 options, weighted)           |  |
  |  +------------------------------------------------------------------------+  |
  |                                                                              |
  |  PACKED TRAITS (32 bits total):                                              |
  |  +------------------------------------------------------------------------+  |
  |  |  Bits 31-24: Trait D (quadrant 3)                                      |  |
  |  |  Bits 23-16: Trait C (quadrant 2)                                      |  |
  |  |  Bits 15-8:  Trait B (quadrant 1)                                      |  |
  |  |  Bits 7-0:   Trait A (quadrant 0)                                      |  |
  |  |                                                                        |  |
  |  |  [DDDDDDDD][CCCCCCCC][BBBBBBBB][AAAAAAAA] = 32 bits                    |  |
  |  +------------------------------------------------------------------------+  |
  |                                                                              |
  |  WEIGHTED DISTRIBUTION:                                                      |
  |  +------------------------------------------------------------------------+  |
  |  |  Bucket | Range    | Width | Probability                               |  |
  |  |  -------+----------+-------+------------                               |  |
  |  |    0    |  0-9     |  10   |  13.3%                                    |  |
  |  |    1    | 10-19    |  10   |  13.3%                                    |  |
  |  |    2    | 20-29    |  10   |  13.3%                                    |  |
  |  |    3    | 30-39    |  10   |  13.3%                                    |  |
  |  |    4    | 40-48    |   9   |  12.0%                                    |  |
  |  |    5    | 49-57    |   9   |  12.0%                                    |  |
  |  |    6    | 58-66    |   9   |  12.0%                                    |  |
  |  |    7    | 67-74    |   8   |  10.7%                                    |  |
  |  |  -------+----------+-------+------------                               |  |
  |  |  Total: 75 (scaled from uint32 range)                                  |  |
  |  +------------------------------------------------------------------------+  |
  |                                                                              |
  |  RANDOM SEED USAGE:                                                          |
  |  +------------------------------------------------------------------------+  |
  |  |  256-bit seed divided into 4 × 64-bit words:                           |  |
  |  |                                                                        |  |
  |  |  [bits 255-192] → Trait D (category from low 32, sub from high 32)     |  |
  |  |  [bits 191-128] → Trait C (category from low 32, sub from high 32)     |  |
  |  |  [bits 127-64]  → Trait B (category from low 32, sub from high 32)     |  |
  |  |  [bits 63-0]    → Trait A (category from low 32, sub from high 32)     |  |
  |  +------------------------------------------------------------------------+  |
  |                                                                              |
  +==============================================================================+
  |                         SECURITY CONSIDERATIONS                              |
  +==============================================================================+
  |                                                                              |
  |  1. PURE FUNCTIONS:                                                          |
  |     • No state reads/writes - purely computational                           |
  |     • No external calls - no reentrancy risk                                 |
  |     • Deterministic outputs from inputs                                      |
  |                                                                              |
  |  2. ARITHMETIC SAFETY:                                                       |
  |     • Uses unchecked blocks for gas efficiency                               |
  |     • All operations within safe bounds (no overflow possible)               |
  |     • Scaling uses uint64 intermediate to prevent truncation                 |
  |                                                                              |
  |  3. DETERMINISM:                                                             |
  |     • Same tokenId always produces same traits (via keccak256)               |
  |     • Critical for on-chain trait verification                               |
  |                                                                              |
  +==============================================================================+*/

/// @title DegenerusTraitUtils
/// @author Burnie Degenerus
/// @notice Pure library for deterministic trait generation from random seeds.
/// @dev Used by DegenerusGamepieces to derive gamepiece visual traits.
///      All functions are internal pure - no state, no external calls.
/// @custom:security-contact burnie@degener.us
library DegenerusTraitUtils {
    /*+======================================================================+
      |                      BUCKET DISTRIBUTION                             |
      +======================================================================+
      |  Maps random values to 0-7 with weighted probability distribution.   |
      |  Lower buckets (0-3) have ~13.3% each, higher buckets less common.   |
      +======================================================================+*/

    /// @dev Map a 32-bit random input to a 0-7 bucket with fixed piecewise distribution.
    ///
    ///      ALGORITHM:
    ///      1. Scale uint32 (0 to 2^32-1) down to 0-74 range
    ///      2. Map scaled value to bucket via thresholds
    ///
    ///      SCALING MATH:
    ///      scaled = (rnd * 75) >> 32
    ///      This maps [0, 2^32-1] → [0, 74] uniformly
    ///
    ///      BUCKET THRESHOLDS:
    ///      Bucket 0: scaled < 10  (range 0-9,   width 10, ~13.3%)
    ///      Bucket 1: scaled < 20  (range 10-19, width 10, ~13.3%)
    ///      Bucket 2: scaled < 30  (range 20-29, width 10, ~13.3%)
    ///      Bucket 3: scaled < 40  (range 30-39, width 10, ~13.3%)
    ///      Bucket 4: scaled < 49  (range 40-48, width 9,  ~12.0%)
    ///      Bucket 5: scaled < 58  (range 49-57, width 9,  ~12.0%)
    ///      Bucket 6: scaled < 67  (range 58-66, width 9,  ~12.0%)
    ///      Bucket 7: scaled >= 67 (range 67-74, width 8,  ~10.7%)
    ///
    /// @param rnd 32-bit random input value.
    /// @return Bucket index 0-7 with weighted distribution.
    function weightedBucket(uint32 rnd) internal pure returns (uint8) {
        unchecked {
            // Scale uint32 to 0-74 range using 64-bit intermediate to prevent overflow
            // (rnd * 75) could overflow uint32, so we use uint64
            uint32 scaled = uint32((uint64(rnd) * 75) >> 32);

            // Piecewise bucket assignment with descending probability for higher buckets
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

    /*+======================================================================+
      |                      TRAIT GENERATION                                |
      +======================================================================+
      |  Derives 6-bit trait from 64-bit random word.                        |
      |  Combines category (3 bits) and sub-bucket (3 bits).                 |
      +======================================================================+*/

    /// @dev Produce a 6-bit trait ID from a 64-bit random value.
    ///
    ///      ALGORITHM:
    ///      1. Use low 32 bits for category bucket (0-7)
    ///      2. Use high 32 bits for sub-bucket (0-7)
    ///      3. Combine: (category << 3) | sub = 6 bits
    ///
    ///      OUTPUT FORMAT (6 bits):
    ///      [CCC][SSS] where C = category, S = sub-bucket
    ///      Range: 0 to 63 (0b000000 to 0b111111)
    ///
    ///      NOTE: Quadrant bits (bits 7-6) are added by caller
    ///
    /// @param rnd 64-bit random input value.
    /// @return 6-bit trait ID (0-63, quadrant bits not included).
    function traitFromWord(uint64 rnd) internal pure returns (uint8) {
        // Category from low 32 bits
        uint8 category = weightedBucket(uint32(rnd));
        // Sub-bucket from high 32 bits
        uint8 sub = weightedBucket(uint32(rnd >> 32));
        // Combine: category in bits 5-3, sub in bits 2-0
        return (category << 3) | sub;
    }

    /*+======================================================================+
      |                      TRAIT PACKING                                   |
      +======================================================================+
      |  Packs 4 traits into 32-bit value for efficient storage.             |
      +======================================================================+*/

    /// @dev Pack the 4 quadrant traits derived from a 256-bit random seed.
    ///
    ///      ALGORITHM:
    ///      1. Split 256-bit seed into 4 × 64-bit words
    ///      2. Generate 6-bit trait from each word
    ///      3. Add quadrant identifier (0, 64, 128, 192) to each trait
    ///      4. Pack into 32-bit value
    ///
    ///      SEED USAGE:
    ///      bits [63:0]    → Trait A (quadrant 0, | 0)
    ///      bits [127:64]  → Trait B (quadrant 1, | 64)
    ///      bits [191:128] → Trait C (quadrant 2, | 128)
    ///      bits [255:192] → Trait D (quadrant 3, | 192)
    ///
    ///      OUTPUT FORMAT (32 bits):
    ///      [traitD:8][traitC:8][traitB:8][traitA:8]
    ///
    ///      Each trait byte: [QQ][CCC][SSS]
    ///      - QQ: Quadrant (0-3)
    ///      - CCC: Category (0-7)
    ///      - SSS: Sub-bucket (0-7)
    ///
    /// @param rand 256-bit random seed (typically from keccak256).
    /// @return 32-bit packed traits value.
    function packedTraitsFromSeed(uint256 rand) internal pure returns (uint32) {
        // Extract 6-bit trait from each 64-bit word, add quadrant identifier
        uint8 traitA = traitFromWord(uint64(rand)); // Quadrant 0: bits 7-6 = 00
        uint8 traitB = traitFromWord(uint64(rand >> 64)) | 64; // Quadrant 1: bits 7-6 = 01
        uint8 traitC = traitFromWord(uint64(rand >> 128)) | 128; // Quadrant 2: bits 7-6 = 10
        uint8 traitD = traitFromWord(uint64(rand >> 192)) | 192; // Quadrant 3: bits 7-6 = 11

        // Pack into 32 bits: [D:24-31][C:16-23][B:8-15][A:0-7]
        return uint32(traitA) | (uint32(traitB) << 8) | (uint32(traitC) << 16) | (uint32(traitD) << 24);
    }

    /*+======================================================================+
      |                      TOKEN TRAIT DERIVATION                          |
      +======================================================================+
      |  Deterministically derives traits from token ID.                     |
      |  Same tokenId always produces same traits (critical for on-chain).   |
      +======================================================================+*/

    /// @dev Deterministically derive packed traits for a token ID.
    ///
    ///      ALGORITHM:
    ///      1. Hash tokenId with keccak256 to get 256-bit seed
    ///      2. Pass seed to packedTraitsFromSeed
    ///
    ///      DETERMINISM:
    ///      keccak256(abi.encodePacked(tokenId)) is deterministic,
    ///      so same tokenId always produces same traits.
    ///      This is critical for on-chain trait verification.
    ///
    /// @param tokenId Token ID to derive traits for.
    /// @return 32-bit packed traits value.
    function packedTraitsForToken(uint256 tokenId) internal pure returns (uint32) {
        return packedTraitsFromSeed(uint256(keccak256(abi.encodePacked(tokenId))));
    }
}
