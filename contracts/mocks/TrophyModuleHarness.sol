// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../PurgeGameTrophies.sol";
import {PurgeGameExternalOp} from "../interfaces/IPurgeGameExternal.sol";

contract TrophyGameHarness is IPurgeGameMinimal {
    uint24 private _level = 1;
    uint8 private _gameState = 3;
    bool private rngLockedFlag;
    uint256 private rngWord;
    uint256 private _coinPriceUnit = 1_000_000;
    uint256 public totalReceived;
    uint256 public trophyPool;
    uint256 public rewardPool;

    function setLevel(uint24 newLevel) external {
        _level = newLevel;
    }

    function setGameState(uint8 newState) external {
        _gameState = newState;
    }

    function setRngLocked(bool locked) external {
        rngLockedFlag = locked;
    }

    function setRngWord(uint256 word) external {
        rngWord = word;
    }

    function setCoinPriceUnit(uint256 priceUnit) external {
        _coinPriceUnit = priceUnit;
    }

    function level() external view override returns (uint24) {
        return _level;
    }

    function gameState() external view override returns (uint8) {
        return _gameState;
    }

    function rngLocked() external view override returns (bool) {
        return rngLockedFlag;
    }

    function coinPriceUnit() external view override returns (uint256) {
        return _coinPriceUnit;
    }

    function applyExternalOp(
        PurgeGameExternalOp op,
        address account,
        uint256 amount,
        uint24 /*lvl*/
    ) external override {
        if (op == PurgeGameExternalOp.TrophyPayout) {
            if (amount > trophyPool) revert();
            trophyPool -= amount;
            (bool ok, ) = payable(account).call{value: amount}("");
            require(ok, "payout");
        } else if (op == PurgeGameExternalOp.TrophyRecycle) {
            if (amount > trophyPool) revert();
            trophyPool -= amount;
            rewardPool += amount;
        } else {
            // For jackpot claims, just attempt to pay out directly during tests.
            (bool ok, ) = payable(account).call{value: amount}("");
            require(ok, "jackpot");
        }
    }

    function processEndLevel(address trophies, IPurgeGameTrophies.EndLevelRequest calldata req) external payable {
        if (msg.value != 0) {
            totalReceived += msg.value;
        }
        IPurgeGameTrophies(trophies).processEndLevel(req, 0);
    }

    function prepareNextLevel(address trophies, uint24 nextLevel) external {
        IPurgeGameTrophies(trophies).prepareNextLevel(nextLevel);
    }

    function probeTraitPurge(address trophies, address player, uint16 traitId) external view returns (uint8) {
        return IPurgeGameTrophies(trophies).handleExterminatorTraitPurge(player, traitId);
    }

    receive() external payable {
        totalReceived += msg.value;
    }
}

contract TrophyCoinHarness is IPurgecoinMinimal {
    struct Burn {
        address target;
        uint256 amount;
    }

    address public mockTopAffiliate;
    Burn[] public burns;
    address public lastCoinflipPlayer;
    uint256 public lastCoinflipAmount;
    bool public lastCoinflipRngReady;

    function setTopAffiliate(address who) external {
        mockTopAffiliate = who;
    }

    function getTopAffiliate() external view override returns (address) {
        return mockTopAffiliate;
    }

    function bonusCoinflip(address player, uint256 amount) external override {
        lastCoinflipPlayer = player;
        lastCoinflipAmount = amount;
        lastCoinflipRngReady = true;
    }

    function burnCoin(address target, uint256 amount) external override {
        burns.push(Burn({target: target, amount: amount}));
    }

    function burnBaf(address trophies, uint24 level) external {
        IPurgeGameTrophies(trophies).burnBafPlaceholder(level);
    }

    function burnCount() external view returns (uint256) {
        return burns.length;
    }

    function burnAt(uint256 idx) external view returns (Burn memory) {
        return burns[idx];
    }

    function wireTrophies(address trophies, address game, uint24 firstLevel) external {
        IPurgeGameTrophies(trophies).wireAndPrime(game, address(this), firstLevel);
    }

    function awardViaCoin(
        address trophies,
        address to,
        uint24 level_,
        uint8 kind,
        uint256 data,
        uint256 deferredWei
    ) external {
        IPurgeGameTrophies(trophies).awardTrophy(to, level_, kind, data, deferredWei);
    }
}

contract TrophyNFTHarness is IPurgeGameNftModule {
    uint256 private _nextId = 1;
    uint256 private _previousBase;
    uint256 private _currentBase;
    address private immutable _game;
    address private immutable _coin;

    mapping(uint256 => address) private _owners;
    mapping(uint256 => uint8) public kinds;
    mapping(uint256 => bool) public staked;
    uint256 public trophySupply;

    constructor(address game_, address coin_) {
        _game = game_;
        _coin = coin_;
    }

    function nextTokenId() external view override returns (uint256) {
        return _nextId;
    }

    function mintPlaceholders(uint256 quantity) external override returns (uint256 startTokenId) {
        startTokenId = _nextId;
        address gameAddr = _game;
        uint256 end = startTokenId + quantity;
        for (uint256 id = startTokenId; id < end; ) {
            _owners[id] = gameAddr;
            unchecked {
                ++id;
            }
        }
        _nextId = end;
        trophySupply += quantity;
        return startTokenId;
    }

    function scheduleDormantRange(uint256, uint256) external pure override {}

    function processDormant(uint32) external pure override returns (bool, bool) {
        return (true, false);
    }

    function clearPlaceholderPadding(uint256 startTokenId, uint256 endTokenId) external override {
        for (uint256 id = startTokenId; id < endTokenId; ) {
            _owners[id] = address(0);
            unchecked {
                ++id;
            }
        }
        if (trophySupply >= endTokenId - startTokenId) {
            trophySupply -= (endTokenId - startTokenId);
        }
    }

    function getBasePointers() external view override returns (uint256 previousBase, uint256 currentBase) {
        return (_previousBase, _currentBase);
    }

    function setBasePointers(uint256 previousBase, uint256 currentBase) external override {
        _previousBase = previousBase;
        _currentBase = currentBase;
    }

    function packedOwnershipOf(uint256 tokenId) external view override returns (uint256 packed) {
        address owner = _owners[tokenId];
        require(owner != address(0), "owner missing");
        packed = uint256(uint160(owner));
    }

    function transferTrophy(address from, address to, uint256 tokenId) external override {
        require(_owners[tokenId] == from, "bad from");
        _owners[tokenId] = to;
    }

    function setTrophyPackedInfo(uint256 tokenId, uint8 kind, bool stake) external override {
        kinds[tokenId] = kind;
        staked[tokenId] = stake;
    }

    function clearApproval(uint256) external pure override {}

    function incrementTrophySupply(uint256 amount) external override {
        trophySupply += amount;
    }

    function decrementTrophySupply(uint256 amount) external override {
        trophySupply -= amount;
    }

    function gameAddress() external view returns (address) {
        return _game;
    }

    function coinAddress() external view returns (address) {
        return _coin;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _owners[tokenId];
    }
}
