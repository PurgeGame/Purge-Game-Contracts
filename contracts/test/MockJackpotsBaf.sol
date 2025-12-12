// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev Minimal mock jackpots that always returns a single configured BAF winner.
contract MockJackpotsBaf {
    address public immutable winner;

    constructor(address winner_) {
        winner = winner_;
    }

    function runBafJackpot(
        uint256 poolWei,
        uint24 lvl,
        uint256 rngWord
    )
        external
        returns (address[] memory winners, uint256[] memory amounts, uint256 bondMask, uint256 returnAmountWei)
    {
        lvl;
        rngWord;
        winners = new address[](1);
        amounts = new uint256[](1);
        winners[0] = winner;
        amounts[0] = poolWei;
        bondMask = 0;
        returnAmountWei = 0;
    }
}
