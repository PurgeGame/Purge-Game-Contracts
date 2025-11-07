// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IPurgeRenderer.sol";

contract MockRenderer is IPurgeRenderer {
    address public game;
    address public nft;

    function wireContracts(address game_, address nft_) external {
        game = game_;
        nft = nft_;
    }
}
