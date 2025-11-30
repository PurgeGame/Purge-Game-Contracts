const { expect } = require("chai");
const { ethers, network } = require("hardhat");

describe("BAF worst-case gas", function () {
  this.timeout(0);

  it("runs BAF jackpot in a heavy, fully-eligible scenario and reports gas", async function () {
    const [deployer] = await ethers.getSigners();
    const lvl = 50;
    const poolWei = ethers.parseEther("500");
    const rngWord = 0x123456789abcdefn;
    const MILLION = 10n ** 6n;

    // --- Deploy mocks ---
    const Coin = await ethers.getContractFactory("MockCoinJackpot");
    const coin = await Coin.deploy();
    await coin.waitForDeployment();

    const Game = await ethers.getContractFactory("MockPurgeGame");
    const game = await Game.deploy();
    await game.waitForDeployment();

    const Trophies = await ethers.getContractFactory("MockPurgeGameTrophies");
    const trophies = await Trophies.deploy();
    await trophies.waitForDeployment();

    const Bonds = await ethers.getContractFactory("MockBondsJackpot");
    const bonds = await Bonds.deploy();
    await bonds.waitForDeployment();

    const Jackpots = await ethers.getContractFactory("PurgeJackpots");
    const jackpots = await Jackpots.deploy();
    await jackpots.waitForDeployment();

    // --- Wire jackpots ---
    await coin.setBonds(await bonds.getAddress());
    await network.provider.request({ method: "hardhat_impersonateAccount", params: [coin.target] });
    await network.provider.send("hardhat_setBalance", [coin.target, "0x1000000000000000000"]);
    const coinSigner = await ethers.getSigner(coin.target);
    await jackpots.connect(coinSigner).wire(coin.target, game.target, trophies.target);

    // Run as game address (onlyGame).
    await network.provider.request({ method: "hardhat_impersonateAccount", params: [game.target] });
    await network.provider.send("hardhat_setBalance", [game.target, "0x1000000000000000000"]);
    const gameSigner = await ethers.getSigner(game.target);

    // --- Seed BAF leaderboard (top 4) ---
    const topPlayers = Array.from({ length: 4 }, (_, i) => ethers.Wallet.createRandom().address);
    for (let i = 0; i < topPlayers.length; i += 1) {
      const amt = BigInt(10_000 + i * 1_000) * MILLION;
      await coin.setCoinflipAmount(topPlayers[i], amt);
      await game.setStreak(topPlayers[i], 10);
      await jackpots.connect(coinSigner).recordBafFlip(topPlayers[i], lvl, amt);
    }

    // --- Seed retro coinflip tops ---
    for (let i = 0; i <= 20; i += 1) {
      await coin.setCoinflipTop(lvl - i, topPlayers[0], 20_000);
    }

    // --- Seed staked trophy sampling ---
    await trophies.setSampleStake(
      topPlayers.slice(0, 4),
      topPlayers.slice(0, 4).map((_, i) => BigInt(i + 1))
    );

    // --- Seed bonds with many owners (weighted sampling) ---
    const bondOwners = Array.from({ length: 32 }, (_, i) => ethers.Wallet.createRandom().address);
    const bondIds = Array.from({ length: 32 }, (_, i) => i + 1);
    await bonds.setSamples(bondOwners, bondIds);
    // Make all bond owners BAF-eligible.
    for (const addr of bondOwners) {
      await coin.setCoinflipAmount(addr, 20_000n * MILLION);
      await game.setStreak(addr, 10);
    }

    // --- Seed scatter tickets (4 tickets repeated, eligible) ---
    const scatterTickets = bondOwners.slice(0, 4);
    await game.setSampleTickets(scatterTickets, lvl, 1);

    // --- Execute jackpot and capture gas ---
    const tx = await jackpots.connect(gameSigner).runBafJackpot(poolWei, lvl, rngWord, { gasLimit: 30_000_000 });
    const rc = await tx.wait();
    // eslint-disable-next-line no-console
    console.log("BAF worst-case gasUsed:", rc.gasUsed.toString());

    // Ensure we stayed under target.
    expect(rc.gasUsed).to.be.lt(1_500_000n);
  });
});
