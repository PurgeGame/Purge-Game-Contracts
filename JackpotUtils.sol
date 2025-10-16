// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title JackpotUtils
 * @notice Pure/view helpers for drawing winners from per-trait ticket traitPurgeTicket and
 *         deriving "winning traits" for daily/early jackpots.
 *
 * @dev Notes:
 * - `_randTraitTicket` samples WITH replacement (winners may repeat). Callers that
 *   require distinct winners must deduplicate externally or introduce a different sampler.
 * - When no tickets exist for a trait (length==0) OR `numWinners==0`, we return an EMPTY array.
 *   This prevents upstream payout code from crediting `address(0)`.
 */
library JackpotUtils {
    // -----------------------------------------------------------------------
    // Ticket sampling
    // -----------------------------------------------------------------------

    /**
     * @notice Sample up to `numWinners` entries from a trait's ticket array using a
     *         deterministic PRNG based on (`randomWord`, `salt`, `trait`).
     *
     * @param traitPurgeTicket  Storage mapping traitId => dynamic array of addresses (tickets)
     * @param randomWord        VRF word (or derived word) used as entropy
     * @param trait             0..255 trait id whose ticket bucket to sample
     * @param numWinners        Target number of draws (capped to bucket length)
     * @param salt              Extra salt for domain separation across calls
     *
     * @return winners          Address list of size K, where K = min(numWinners, bucketLen).
     *                          When bucketLen==0 or numWinners==0, returns an EMPTY array.
     *
     * @dev Sampling is WITH replacement (same ticket can be selected multiple times).
     *      This keeps the function O(K) without touching the whole bucket.
     */
    function _randTraitTicket(
        address[][256] storage traitPurgeTicket,
        uint256 randomWord,
        uint8   trait,
        uint8   numWinners,
        uint8   salt
    ) internal view returns (address[] memory winners) {
        address[] storage holders = traitPurgeTicket[trait];
        uint256 n = holders.length;
        if (n == 0 || numWinners == 0) return new address[](0);


        winners = new address[](numWinners);

        bytes32 base = keccak256(abi.encode(randomWord, salt, trait));
        for (uint256 i; i < numWinners; ) {
            uint256 idx = uint256(keccak256(abi.encode(base, i))) % n;
            winners[i] = holders[idx];
            unchecked { ++i; }
        }
    }



    // -----------------------------------------------------------------------
    // Trait selection helpers
    // -----------------------------------------------------------------------

    /**
     * @notice Produce four random trait IDs (uniform) from a single random word.
     * @dev Layout:
     *  - Q0: 0..63   (base)
     *  - Q1: 64..127 (add 64)
     *  - Q2: 128..191 (add 128)
     *  - Q3: 192..255 (add 192)
     */
    function _getRandomTraits(uint256 rw) internal pure returns (uint8[4] memory w) {
        w[0] = uint8(rw & 0x3F);                  // 0..63
        w[1] = 64  + uint8((rw >>  6) & 0x3F);    // 64..127
        w[2] = 128 + uint8((rw >> 12) & 0x3F);    // 128..191
        w[3] = 192 + uint8((rw >> 18) & 0x3F);    // 192..255
    }

    /**
     * @notice Pick four “winning traits” guided by observed purge counts:
     *         - Group 0 (symbols): pick most‑purged symbol (range 0..7), random color.
     *         - Group 1 (colors):  pick most‑purged color (range 0..7), random symbol.
     *         - Group 2 (full traits): pick most‑purged (range 0..63).
     *         - Group 3: random full trait (range 0..63).
     *
     * @param randomWord  Entropy
     * @param c           80‑bucket counter array: [0..7]=Q0 symbols, [8..15]=Q1 colors,
     *                    [16..79]=Q2 traits (64 slots)
     */
    function _getWinningTraits(
        uint256 randomWord,
        uint32[80] storage c
    ) internal view returns (uint8[4] memory w) {
        // Domain-separated seed
        uint256 s = uint256(keccak256(abi.encodePacked(randomWord, uint256(0xBAF))));

        // Q0: symbol from max bucket [0..7], color random [0..7]
        uint8 sym  = _maxIdxInRange(c, 0, 8);
        uint8 col0 = uint8(uint256(keccak256(abi.encodePacked(s, uint256(0)))) & 7);
        w[0] = (col0 << 3) | sym;                 // 0..63

        // Q1: color from max bucket [8..15], symbol random [0..7]
        uint8 mcol = _maxIdxInRange(c, 8, 8);
        uint8 rsym = uint8(uint256(keccak256(abi.encodePacked(s, uint256(1)))) & 7);
        w[1] = 64 + ((mcol << 3) | rsym);         // 64..127

        // Q2: full trait [0..63] from max bucket [16..79]
        uint8 mtrait = _maxIdxInRange(c, 16, 64);
        w[2] = 128 + mtrait;                      // 128..191

        // Q3: full trait random [0..63]
        w[3] = 192 + uint8(uint256(keccak256(abi.encodePacked(s, uint256(2)))) & 63);
    }

    /**
     * @notice Find the relative index (0‑based) of the maximum value in c[base .. base+len).
     *         Ties resolve to the earliest (lowest index).
     *
     * @dev Returns 0 if the window is empty or out of bounds.
     */
    function _maxIdxInRange(
        uint32[80] storage c,
        uint8  base,
        uint8  len
    ) private view returns (uint8) {
        if (len == 0 || base >= 80) return 0;

        uint256 end = uint256(base) + uint256(len);
        if (end > 80) end = 80;

        uint8  maxRel = 0;
        uint32 maxV   = c[base];

        for (uint256 i = uint256(base) + 1; i < end; ++i) {
            uint32 v = c[i];
            if (v > maxV) {
                maxV   = v;
                maxRel = uint8(i) - base;
            }
        }
        return maxRel;
    }
}
