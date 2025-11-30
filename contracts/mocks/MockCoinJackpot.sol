// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal coin interface mock used for BAF jackpot gas measurement.
contract MockCoinJackpot {
    mapping(address => uint256) internal flipAmount;
    mapping(uint24 => address) internal topPlayer;
    mapping(uint24 => uint96) internal topScore;
    address internal bondsAddr;

    function setCoinflipAmount(address player, uint256 amount) external {
        flipAmount[player] = amount;
    }

    function setCoinflipTop(uint24 lvl, address player, uint96 score) external {
        topPlayer[lvl] = player;
        topScore[lvl] = score;
    }

    function setBonds(address addr) external {
        bondsAddr = addr;
    }

    function coinflipAmount(address player) external view returns (uint256) {
        return flipAmount[player];
    }

    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score) {
        return (topPlayer[lvl], topScore[lvl]);
    }

    function biggestLuckbox() external pure returns (address player, uint96 score) {
        return (address(0), 0);
    }

    function playerLuckbox(address) external pure returns (uint256) {
        return 0;
    }

    function bonds() external view returns (address) {
        return bondsAddr;
    }
}
