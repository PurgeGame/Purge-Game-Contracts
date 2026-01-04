// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DegenerusGameJackpotModule} from "../modules/DegenerusGameJackpotModule.sol";
import {IDegenerusCoinModule} from "../interfaces/DegenerusGameModuleInterfaces.sol";

contract JackpotGasHarness is DegenerusGameJackpotModule {
    function setBonds(address bondsAddr) external {
        bonds = bondsAddr;
    }

    function setState(
        uint24 lvl,
        uint128 priceWei,
        uint256 rewardPoolWei,
        uint256 currentPrizePoolWei,
        uint256 dailyJackpotBaseWei,
        uint8 jackpotCounter_
    ) external {
        level = lvl;
        price = priceWei;
        rewardPool = rewardPoolWei;
        currentPrizePool = currentPrizePoolWei;
        dailyJackpotBase = dailyJackpotBaseWei;
        jackpotCounter = jackpotCounter_;
    }

    function setDailyBurnCounts(uint8 symbolIdx, uint8 colorIdx, uint8 traitIdx) external {
        for (uint256 i; i < 80; ) {
            dailyBurnCount[i] = 0;
            unchecked {
                ++i;
            }
        }
        dailyBurnCount[symbolIdx] = 1;
        dailyBurnCount[8 + colorIdx] = 1;
        dailyBurnCount[16 + traitIdx] = 1;
    }

    function seedTraitTickets(uint24 lvl, uint8 traitId, address[] calldata addrs) external {
        address[] storage arr = traitBurnTicket[lvl][traitId];
        uint256 len = addrs.length;
        for (uint256 i; i < len; ) {
            arr.push(addrs[i]);
            unchecked {
                ++i;
            }
        }
    }

    function pendingMapMintsLength() external view returns (uint256) {
        return pendingMapMints.length;
    }

    function payDailyJackpotAndMap(uint24 lvl, uint256 randWord, address coinContract) external {
        this.payDailyJackpot(true, lvl, randWord, IDegenerusCoinModule(coinContract));
        this.payMapJackpot(lvl, randWord);
    }

    function payDailyJackpotAndMapWithRand(
        uint24 lvl,
        uint256 randWordDaily,
        uint256 randWordMap,
        address coinContract
    ) external {
        this.payDailyJackpot(true, lvl, randWordDaily, IDegenerusCoinModule(coinContract));
        this.payMapJackpot(lvl, randWordMap);
    }

    function simulateMapPayout(address[] calldata winners, uint256 perWinner, uint16 mapBps) external {
        _simulateMapPayout(winners, perWinner, mapBps);
    }

    function simulateWorstCaseWrites(
        address[] calldata ethWinners,
        uint256 ethPerWinner,
        address[] calldata mapWinners,
        uint256 mapPerWinner,
        uint16 mapBps
    ) external {
        _simulateMapPayout(ethWinners, ethPerWinner, 0);
        _simulateMapPayout(mapWinners, mapPerWinner, mapBps);
    }

    function _simulateMapPayout(address[] calldata winners, uint256 perWinner, uint16 mapBps) private {
        uint256 mapPrice = uint256(price) / 4;
        uint256 totalCash;
        uint256 len = winners.length;

        for (uint256 i; i < len; ) {
            address winner = winners[i];
            if (winner != address(0) && perWinner != 0) {
                uint256 cashPortion = perWinner;
                if (mapBps != 0 && mapPrice != 0) {
                    uint256 mapBudget = (perWinner * mapBps) / 10_000;
                    if (mapBudget >= mapPrice) {
                        uint256 qty = mapBudget / mapPrice;
                        if (qty > type(uint32).max) qty = type(uint32).max;
                        uint256 mapCost = qty * mapPrice;
                        if (mapCost != 0) {
                            uint32 owed = playerMapMintsOwed[winner];
                            if (owed == 0) {
                                pendingMapMints.push(winner);
                            }
                            unchecked {
                                playerMapMintsOwed[winner] = owed + uint32(qty);
                            }
                            nextPrizePool += mapCost;
                            cashPortion = perWinner - mapCost;
                        }
                    }
                }
                if (cashPortion != 0) {
                    unchecked {
                        claimableWinnings[winner] += cashPortion;
                    }
                    totalCash += cashPortion;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (totalCash != 0) {
            claimablePool += totalCash;
        }
    }

}
