// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IDegenerusGame.sol";

library DegenerusGameCredit {
    function availableCredit(
        mapping(address => uint256) storage claimableWinnings,
        mapping(address => uint256) storage bondCredit,
        address buyer,
        MintPaymentKind payKind,
        uint256 msgValue
    ) internal view returns (bool ok, uint256 available, uint256 ethValue) {
        if (payKind == MintPaymentKind.Claimable) {
            if (msgValue != 0) return (false, 0, 0);
            uint256 claimable = claimableWinnings[buyer];
            if (claimable <= 1) return (false, 0, 0);
            unchecked {
                available = claimable - 1;
            }
            return (true, available, 0);
        }
        if (payKind == MintPaymentKind.BondCredit) {
            if (msgValue != 0) return (false, 0, 0);
            available = bondCredit[buyer];
            if (available == 0) return (false, 0, 0);
            return (true, available, 0);
        }
        if (payKind == MintPaymentKind.Combined) {
            uint256 claimableAvail;
            uint256 claimable = claimableWinnings[buyer];
            if (claimable > 1) {
                unchecked {
                    claimableAvail = claimable - 1;
                }
            }
            uint256 credit = bondCredit[buyer];
            ethValue = msgValue;
            available = ethValue + claimableAvail + credit;
            if (available == 0) return (false, 0, 0);
            return (true, available, ethValue);
        }
        return (false, 0, 0);
    }

    function processMintPayment(
        mapping(address => uint256) storage claimableWinnings,
        mapping(address => uint256) storage bondCredit,
        address player,
        uint256 amount,
        MintPaymentKind payKind,
        uint256 msgValue
    ) internal returns (bool ok, uint256 prizeContribution, uint256 creditUsed, uint256 claimableUsed) {
        if (payKind == MintPaymentKind.DirectEth) {
            if (msgValue != amount) return (false, 0, 0, 0);
            return (true, amount, 0, 0);
        }
        if (payKind == MintPaymentKind.Claimable) {
            if (msgValue != 0) return (false, 0, 0, 0);
            uint256 claimable = claimableWinnings[player];
            if (claimable <= amount) return (false, 0, 0, 0);
            unchecked {
                claimableWinnings[player] = claimable - amount;
            }
            return (true, amount, 0, amount);
        }
        if (payKind == MintPaymentKind.BondCredit) {
            if (msgValue != 0) return (false, 0, 0, 0);
            uint256 credit = bondCredit[player];
            if (credit < amount) return (false, 0, 0, 0);
            unchecked {
                bondCredit[player] = credit - amount;
            }
            return (true, 0, amount, 0);
        }
        if (payKind == MintPaymentKind.Combined) {
            if (msgValue > amount) return (false, 0, 0, 0);
            uint256 remaining = amount - msgValue;
            if (remaining != 0) {
                uint256 claimable = claimableWinnings[player];
                if (claimable > 1) {
                    uint256 available = claimable - 1;
                    claimableUsed = remaining < available ? remaining : available;
                    if (claimableUsed != 0) {
                        unchecked {
                            claimableWinnings[player] = claimable - claimableUsed;
                        }
                        remaining -= claimableUsed;
                    }
                }
            }
            if (remaining != 0) {
                uint256 credit = bondCredit[player];
                if (credit < remaining) return (false, 0, 0, 0);
                unchecked {
                    bondCredit[player] = credit - remaining;
                }
                creditUsed = remaining;
                remaining = 0;
            }
            if (remaining != 0) return (false, 0, 0, 0);
            return (true, msgValue + claimableUsed, creditUsed, claimableUsed);
        }
        return (false, 0, 0, 0);
    }
}
