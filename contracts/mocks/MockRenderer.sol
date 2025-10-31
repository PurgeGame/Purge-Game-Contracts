// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockRenderer {
    address public game;
    address public nft;

    function wireContracts(address game_, address nft_) external {
        game = game_;
        nft = nft_;
    }
}
