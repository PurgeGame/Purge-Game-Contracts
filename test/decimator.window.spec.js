const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const MILLION = 1_000_000n;
const MIN_BURN = 100n * MILLION; // matches Purgecoin.MIN

describe("Decimator window latch", function () {
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
      steth.target
    );

    // Keep quest staking gates from blocking coinflip payouts in unrelated code paths.
    await purgecoin.harnessSetStakeLevelComplete(100);

    return { game, purgecoin };
  }

  it("closes the window for non-100 levels when RNG is requested and blocks further burns", async function () {
    const { game, purgecoin } = await loadFixture(deployFixture);
    const [, player] = await ethers.getSigners();

    const futureTs = (await time.latest()) + 1_000;
    await time.setNextBlockTimestamp(futureTs);
    await game.harnessSetState(25, 0, 1);
    await game.harnessSetRng(0, false, false); // force _requestRng on advanceGame
    await purgecoin.harnessMint(player.address, MIN_BURN * 2n);

    const decBefore = await game.decWindow();
    expect(decBefore[0]).to.equal(true);
    await expect(purgecoin.connect(player).decimatorBurn(MIN_BURN)).to.not.be.reverted;

    await game.connect(player).advanceGame(1);

    const decAfter = await game.decWindow();
    expect(decAfter[0]).to.equal(false);
    await expect(purgecoin.connect(player).decimatorBurn(MIN_BURN)).to.be.revertedWithCustomError(
      purgecoin,
      "NotDecimatorWindow"
    );
  });

  it("keeps the level-100 window latched until the phase-3 RNG request closes it", async function () {
    const { game, purgecoin } = await loadFixture(deployFixture);
    const [, player] = await ethers.getSigners();

    const futureTs = (await time.latest()) + 1_000;
    await time.setNextBlockTimestamp(futureTs);
    await purgecoin.harnessMint(player.address, MIN_BURN * 3n);

    // Initial request at phase 0 should not close the level-100 window.
    await game.harnessSetState(100, 0, 1);
    await game.harnessSetRng(0, false, false);
    await expect(purgecoin.connect(player).decimatorBurn(MIN_BURN)).to.not.be.reverted;
    await game.connect(player).advanceGame(1);
    const stillOpen = await game.decWindow();
    expect(stillOpen[0]).to.equal(true);

    // A later request at phase 3 should close it and block further burns.
    await game.harnessSetRng(0, false, false);
    await game.harnessSetState(100, 3, 1);
    await expect(purgecoin.connect(player).decimatorBurn(MIN_BURN)).to.not.be.reverted;
    await game.connect(player).advanceGame(1);

    const closed = await game.decWindow();
    expect(closed[0]).to.equal(false);
    await expect(purgecoin.connect(player).decimatorBurn(MIN_BURN)).to.be.revertedWithCustomError(
      purgecoin,
      "NotDecimatorWindow"
    );
  });
});
