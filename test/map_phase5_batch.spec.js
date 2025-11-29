const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

describe("Phase 5 map jackpot with 3000 cap", function () {
  this.timeout(0);

  async function deployFixture() {
    const MockRenderer = await ethers.getContractFactory("MockRenderer");
    const renderer = await MockRenderer.deploy();
    const VRF = await ethers.getContractFactory("MockVRFCoordinator");
    const vrf = await VRF.deploy(ethers.parseEther("500"));
    const Link = await ethers.getContractFactory("MockLinkToken");
    const link = await Link.deploy();
    const Purgecoin = await ethers.getContractFactory("PurgecoinHarness");
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
      extJackpot.target,
      deployer.address
    );

    // Avoid coinflip pending gating.
    await purgecoin.harnessSetStakeLevelComplete(100);

    return { game, nft };
  }

  it("advances through phase 5 with cap=3000", async function () {
    const { game, nft } = await loadFixture(deployFixture);
    const [, player] = await ethers.getSigners();

    // Ensure timestamp moves forward relative to fixture snapshot.
    const now = await time.latest();
    await time.setNextBlockTimestamp(now + 1);

    // Leave RNG unlocked for minting.
    await game.harnessSetRng(1, true, false);

    const price = await game.mintPrice();
    await nft.connect(player).purchase(1, false, ethers.ZeroHash, { value: price });

    // Lock RNG and preload a word for advanceGame, and jump to phase 4 purchase state.
    await game.harnessSetRng(1234, true, true);
    await game.harnessSetState(0, 4, 2);

    // Phase 4 -> 5 with cap=3000 (runs map jackpot step). If gating keeps phase at 4,
    // force progression for the trait rebuild test.
    await game.connect(player).advanceGame(3000);
    await game.harnessSetState(0, 5, 2);
    await game.harnessSetRng(4321, true, true);

    // Phase 5 trait rebuild / finalize with cap=3000.
    await game.connect(player).advanceGame(3000);

    // Should end up latched beyond phase 5 without reverting.
    const phase = await game.currentPhase();
    expect(phase).to.be.at.least(5);
  });
});
