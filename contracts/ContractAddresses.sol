// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

library ContractAddresses {
    // Network Constants
    address internal constant CREATOR = 0xceE410a785AA2D4a78130FB9bF519408c115C21b;
    address internal constant STETH_TOKEN = 0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af; // Sepolia stETH
    address internal constant LINK_TOKEN = 0x779877A7B0D9E8603169DdbD7836e478b4624789; // Sepolia LINK
    address internal constant VRF_COORDINATOR = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B; // Sepolia VRF V2.5
    bytes32 internal constant VRF_KEY_HASH = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae; // 100 gwei

    // Cost divisor for testnet (divide all ETH amounts by 1,000,000)
    uint256 internal constant COST_DIVISOR = 1_000_000;

    // Contract Addresses (Precomputed)
    address internal constant ICONS_32 = 0x8B2f93c5dbF41739a19C9a75BAd0D35420A8f370;
    address internal constant TROPHY_SVG_ASSETS = 0x6dc9D20D47226Af9b76bA1Bc20Cf8443C5Ddc3b6;
    address internal constant GAME_MINT_MODULE = 0x09E70bfA9c3a56d2CD6437F1fBe057f7Aa0B5078;
    address internal constant GAME_JACKPOT_MODULE = 0x2608d96c2F63c7a27D4d3094573Ef6cf13Cd748B;
    address internal constant GAME_ENDGAME_MODULE = 0x33A77dd763462873279fC073e73D95d577d69c85;
    address internal constant GAME_GAMEOVER_MODULE = 0x0000000000000000000000000000000000000000; // TODO: Update after deploy
    address internal constant COIN = 0xcAB0eA7c2C0F0926584CD473B7B5fCb457f18826;
    address internal constant VAULT = 0xbA924bf8BFa8e10C87dCf9285569e1F0d29D14eF;
    address internal constant AFFILIATE = 0x4cF98E2b067D05f22b569d8a37f38E8Ec9D9e52A;
    address internal constant JACKPOTS = 0x7f91a7cBAd43eEeDdC4F16e3f8F0a39dC4A63Bd4;
    address internal constant QUESTS = 0x9291688D4DC5ad984d8d0232529795d91f5f6E94;
    address internal constant ICON_COLOR_REGISTRY = 0x06DeB8B69a6931Bbb6875857F84B3b57081dAfe1;
    address internal constant RENDERER_REGULAR = 0xdD09Fb5B508f13218aAf22f41C9C8eAF86b9a4De;
    address internal constant RENDERER_TROPHY_SVG = 0x9A3C4439528C216cb16A49851430A8602D352B59;
    address internal constant RENDERER_TROPHY = 0xDA9ADf339C9C85763B18A40c73daf107DD9b7D70;
    address internal constant GAMEPIECE_RENDERER_ROUTER = 0x24798fa853c4b4C64944a33Ff7896cE09b2f1616;
    address internal constant TROPHY_RENDERER_ROUTER = 0xF8cA8AD503FFf9cf717487bb9aCa62b185Bce5f5;
    address internal constant TROPHIES = 0x97c71595906fFb8ea59F97198EcD7bE889Fe2ae9;
    address internal constant GAMEPIECES = 0xa61045A3f2718406618b9654aBf9C6762c7DdEbf;
    address internal constant GAME = 0x0FAED5292EaAD742498694bEf91950b4e7888F0f;
    address internal constant ADMIN = 0xDf4b6dC6099AdE9c1AaAB23c02D545E524f021Ff;
}
