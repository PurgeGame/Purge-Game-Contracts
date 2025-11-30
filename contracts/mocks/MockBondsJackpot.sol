// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal bonds mock to satisfy jackpot sampling.
contract MockBondsJackpot {
    address[] internal owners;
    uint256[] internal ids;

    function setSamples(address[] calldata owners_, uint256[] calldata ids_) external {
        owners = owners_;
        ids = ids_;
    }

    function sampleBondOwners(uint256 entropy) external view returns (address[8] memory out) {
        uint256 len = owners.length;
        if (len == 0) return out;
        for (uint8 i; i < 8; ) {
            uint256 idx = uint256(keccak256(abi.encode(entropy, i))) % len;
            out[i] = owners[idx];
            unchecked {
                ++i;
            }
        }
    }

    function sampleBondOwner(uint256 entropy) external view returns (uint256 tokenId, address owner) {
        uint256 len = owners.length;
        if (len == 0) return (0, address(0));
        uint256 idx = entropy % len;
        return (ids[idx], owners[idx]);
    }
}
