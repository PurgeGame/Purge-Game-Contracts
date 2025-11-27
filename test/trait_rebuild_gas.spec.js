const { ethers, network } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("trait rebuild gas checks", function () {
  this.timeout(0);

  async function deployFixture() {
    const MockRenderer = await ethers.getContractFactory("MockRenderer");
    const renderer = await MockRenderer.deploy();
    const VRF = await ethers.getContractFactory("MockVRFCoordinator");
    const vrf = await VRF.deploy(ethers.parseEther("500"));
    const Link = await ethers.getContractFactory("MockLinkToken");
    const link = await Link.deploy();
    const Purgecoin = await ethers.getContractFactory("Purgecoin");
    const purgecoin = await Purgecoin.deploy();
    const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
    const quest = await QuestModule.deploy(purgecoin.target);
    const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
    const extJackpot = await ExternalJackpot.deploy();
    const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
    const nft = await PurgeGameNFT.deploy(renderer.target, renderer.target, purgecoin.target);
    const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
    const trophies = await PurgeGameTrophies.deploy(nft.target);
    const Endgame = await ethers.getContractFactory("PurgeGameEndgameModule");
    const endgameMod = await Endgame.deploy();
    const Jackpot = await ethers.getContractFactory("PurgeGameJackpotModule");
    const jackpotMod = await Jackpot.deploy();
    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();

    const GameHarness = await ethers.getContractFactory("PurgeGameHarness");
    const game = await GameHarness.deploy(
      purgecoin.target,
      renderer.target,
      nft.target,
      trophies.target,
      endgameMod.target,
      jackpotMod.target,
      vrf.target,
      ethers.ZeroHash,
      1n,
      link.target,
      steth.target
    );

    await purgecoin.wire(
      game.target,
      nft.target,
      trophies.target,
      renderer.target,
      renderer.target,
      quest.target,
      extJackpot.target
    );

    return { game };
  }

  const fmt = (gas) => gas.toString();

  it("reports gas for first-slice rebuilds", async function () {
    const { game } = await loadFixture(deployFixture);

    // Level 1 first slice (forced 1,800 tokens)
    await game.harnessResetTraits(0);
    await game.harnessSetState(1, 0, 1);
    const gasL1Fresh = await game.harnessRebuild.estimateGas(0, 1800);

    await game.harnessResetTraits(1);
    await game.harnessSetState(1, 0, 1);
    const gasL1Warm = await game.harnessRebuild.estimateGas(0, 1800);

    // Level >1 first slice (2,500 tokens)
    await game.harnessResetTraits(0);
    await game.harnessSetState(2, 0, 1);
    const gasL2Fresh = await game.harnessRebuild.estimateGas(0, 2500);

    await game.harnessResetTraits(1);
    await game.harnessSetState(2, 0, 1);
    const gasL2Warm = await game.harnessRebuild.estimateGas(0, 2500);

    // Non-first-slice 3,000-token batches (cursor > 0 to avoid first-slice clamp)
    await game.harnessResetTraits(0);
    await game.harnessSetState(2, 0, 1);
    await game.harnessSetRebuildCursor(1);
    const gas3kFresh = await game.harnessRebuild.estimateGas(3000, 3001);

    await game.harnessResetTraits(1);
    await game.harnessSetState(2, 0, 1);
    await game.harnessSetRebuildCursor(1);
    const gas3kWarm = await game.harnessRebuild.estimateGas(3000, 3001);

    console.log("Rebuild gas (fresh storage => 0 -> value):");
    console.log(`  Level 1 (1,800 tokens): ${fmt(gasL1Fresh)}`);
    console.log(`  Level 2+ (2,500 tokens): ${fmt(gasL2Fresh)}`);
    console.log(`  Non-first slice (3,000 tokens): ${fmt(gas3kFresh)}`);
    console.log("Rebuild gas (warm storage => non-zero -> value):");
    console.log(`  Level 1 (1,800 tokens): ${fmt(gasL1Warm)}`);
    console.log(`  Level 2+ (2,500 tokens): ${fmt(gasL2Warm)}`);
    console.log(`  Non-first slice (3,000 tokens): ${fmt(gas3kWarm)}`);
  });
});
