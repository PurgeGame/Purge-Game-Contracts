// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockBafCoinJackpotView {
    struct PlayerScore {
        address player;
        uint96 score;
    }

    mapping(address => uint256) private lastDayAmount;
    mapping(uint24 => PlayerScore) private topByLevel;
    PlayerScore private topLastDay;

    function setCoinflipAmountLastDay(address player, uint256 amount) external {
        lastDayAmount[player] = amount;
    }

    function setCoinflipAmountLastDayBatch(address[] calldata players, uint256 amount) external {
        for (uint256 i; i < players.length; ) {
            lastDayAmount[players[i]] = amount;
            unchecked {
                ++i;
            }
        }
    }

    function setCoinflipTop(uint24 lvl, address player, uint96 score) external {
        topByLevel[lvl] = PlayerScore(player, score);
    }

    function setCoinflipTopLastDay(address player, uint96 score) external {
        topLastDay = PlayerScore(player, score);
    }

    function coinflipAmountLastDay(address player) external view returns (uint256) {
        return lastDayAmount[player];
    }

    function coinflipTop(uint24 lvl) external view returns (address player, uint96 score) {
        PlayerScore memory entry = topByLevel[lvl];
        return (entry.player, entry.score);
    }

    function coinflipTopLastDay() external view returns (address player, uint96 score) {
        return (topLastDay.player, topLastDay.score);
    }
}

contract MockBafAffiliateJackpotView {
    struct PlayerScore {
        address player;
        uint96 score;
    }

    mapping(uint24 => PlayerScore) private topByLevel;

    function setAffiliateTop(uint24 lvl, address player, uint96 score) external {
        topByLevel[lvl] = PlayerScore(player, score);
    }

    function affiliateTop(uint24 lvl) external view returns (address player, uint96 score) {
        PlayerScore memory entry = topByLevel[lvl];
        return (entry.player, entry.score);
    }
}

contract MockBafGameJackpotView {
    uint24 public level;

    mapping(address => uint256) private bonusMultiplier;
    mapping(address => uint24) private streakCount;
    mapping(uint24 => address) private exterminatorByLevel;
    mapping(uint24 => mapping(uint8 => address[])) private traitBurnTicket;

    function setLevel(uint24 lvl) external {
        level = lvl;
    }

    function setPlayerBonusMultiplier(address player, uint256 mult) external {
        bonusMultiplier[player] = mult;
    }

    function setPlayerBonusMultiplierBatch(address[] calldata players, uint256 mult) external {
        for (uint256 i; i < players.length; ) {
            bonusMultiplier[players[i]] = mult;
            unchecked {
                ++i;
            }
        }
    }

    function setEthMintStreakCount(address player, uint24 count) external {
        streakCount[player] = count;
    }

    function setEthMintStreakCountBatch(address[] calldata players, uint24 count) external {
        for (uint256 i; i < players.length; ) {
            streakCount[players[i]] = count;
            unchecked {
                ++i;
            }
        }
    }

    function setLevelExterminator(uint24 lvl, address ex) external {
        exterminatorByLevel[lvl] = ex;
    }

    function seedTraitTicketsRange(uint24 lvl, uint8 startTrait, uint8 count, address[] calldata tickets) external {
        if (tickets.length == 0 || count == 0) return;
        uint16 end = uint16(startTrait) + uint16(count);
        for (uint16 t = startTrait; t < end; ) {
            address[] storage arr = traitBurnTicket[lvl][uint8(t)];
            while (arr.length != 0) {
                arr.pop();
            }
            for (uint256 i; i < tickets.length; ) {
                arr.push(tickets[i]);
                unchecked {
                    ++i;
                }
            }
            unchecked {
                ++t;
            }
        }
    }

    function playerBonusMultiplier(address player) external view returns (uint256) {
        return bonusMultiplier[player];
    }

    function ethMintStreakCount(address player) external view returns (uint24) {
        return streakCount[player];
    }

    function levelExterminator(uint24 lvl) external view returns (address) {
        return exterminatorByLevel[lvl];
    }

    function sampleTraitTickets(
        uint256 entropy
    ) external view returns (uint24 lvlSel, uint8 traitSel, address[] memory tickets) {
        uint24 currentLvl = level;
        if (currentLvl <= 1) {
            return (0, 0, new address[](0));
        }

        uint24 maxOffset = currentLvl - 1;
        if (maxOffset > 20) maxOffset = 20;

        uint256 word = entropy;
        uint24 offset;
        unchecked {
            offset = uint24(word % maxOffset) + 1;
            lvlSel = currentLvl - offset;
        }

        traitSel = uint8(word >> 24);
        address[] storage arr = traitBurnTicket[lvlSel][traitSel];
        uint256 len = arr.length;
        if (len == 0) {
            return (lvlSel, traitSel, new address[](0));
        }

        uint256 take = len > 4 ? 4 : len;
        tickets = new address[](take);
        uint256 start = (word >> 40) % len;
        for (uint256 i; i < take; ) {
            tickets[i] = arr[(start + i) % len];
            unchecked {
                ++i;
            }
        }
    }
}
