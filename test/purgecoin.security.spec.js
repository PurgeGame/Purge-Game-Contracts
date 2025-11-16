const { expect } = require("chai");
const { ethers } = require("hardhat");

const MILLION = 1_000_000n;

async function deployPurgecoin() {
  const [deployer] = await ethers.getSigners();
  const Purgecoin = await ethers.getContractFactory("Purgecoin");
  const purgecoin = await Purgecoin.deploy();
  await purgecoin.waitForDeployment();

  const LinkableStub = await ethers.getContractFactory("LinkableStub");
  const regularRenderer = await LinkableStub.deploy();
  await regularRenderer.waitForDeployment();
  const trophyRenderer = await LinkableStub.deploy();
  await trophyRenderer.waitForDeployment();
  const nft = await LinkableStub.deploy();
  await nft.waitForDeployment();

  const MockGame = await ethers.getContractFactory("MockGame");
  const game = await MockGame.deploy(await purgecoin.getAddress());
  await game.waitForDeployment();

  await purgecoin
    .connect(deployer)
    .wire(
      await game.getAddress(),
      await nft.getAddress(),
      await regularRenderer.getAddress(),
      await trophyRenderer.getAddress()
    );

  return { purgecoin, game };
}

describe("Purgecoin security guards", function () {
  it("skips luckbox credit for contract burn targets", async function () {
    const { purgecoin, game } = await deployPurgecoin();
    const [deployer] = await ethers.getSigners();

    const LinkCaller = await ethers.getContractFactory("LinkCaller");
    const contractTarget = await LinkCaller.deploy();
    await contractTarget.waitForDeployment();

    const burnAmount = 50n * MILLION;
    await purgecoin.connect(deployer).transfer(await contractTarget.getAddress(), burnAmount);

    await contractTarget
      .connect(deployer)
      .burn(await game.getAddress(), await contractTarget.getAddress(), burnAmount);
    const contractLuck = await purgecoin.playerLuckbox(await contractTarget.getAddress());
    expect(contractLuck).to.equal(0n);

    await game.burn(deployer.address, burnAmount);
    expect(await purgecoin.playerLuckbox(deployer.address)).to.equal(burnAmount / 50n);
  });
});
