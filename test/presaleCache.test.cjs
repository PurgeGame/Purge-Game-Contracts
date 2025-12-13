const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DegenerusBonds presale caching", function () {
  it("caches presale proceeds until the game is wired", async function () {
    const [admin] = await ethers.getSigners();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();
    await steth.waitForDeployment();

    const MockVault = await ethers.getContractFactory("MockVault");
    const vault = await MockVault.deploy(await steth.getAddress());
    await vault.waitForDeployment();

    const Bonds = await ethers.getContractFactory("DegenerusBonds");
    const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
    await bonds.waitForDeployment();

    const Affiliate = await ethers.getContractFactory("DegenerusAffiliate");
    const affiliate = await Affiliate.deploy(await bonds.getAddress(), await admin.getAddress());
    await affiliate.waitForDeployment();

    const MockCoin = await ethers.getContractFactory("MockCoinRead");
    const coin = await MockCoin.deploy(await affiliate.getAddress(), await admin.getAddress());
    await coin.waitForDeployment();

    // Wire vault + coin; keep game unset to simulate presale before game wiring.
    await bonds.wire(
      [ethers.ZeroAddress, await vault.getAddress(), await coin.getAddress()],
      0,
      ethers.ZeroHash
    );

    const amount = ethers.parseEther("1");
    const vaultShare = (amount * 30n) / 100n;
    const rewardShare = (amount * 50n) / 100n;
    const yieldShare = amount - vaultShare - rewardShare;

    const vaultBalBefore = await ethers.provider.getBalance(await vault.getAddress());
    const gameBalBefore = 0n;

    await expect(bonds.presaleDeposit(admin.address, { value: amount }))
      .to.emit(bonds, "PresaleProceedsCached")
      .withArgs(rewardShare, yieldShare);

    expect(await ethers.provider.getBalance(await vault.getAddress())).to.equal(vaultBalBefore + vaultShare);
    expect(await ethers.provider.getBalance(await bonds.getAddress())).to.equal(rewardShare + yieldShare);
    expect(await bonds.presalePendingRewardEth()).to.equal(rewardShare);
    expect(await bonds.presalePendingYieldEth()).to.equal(yieldShare);

    // Wire the game; presale proceeds should remain cached until shutdownPresale().
    const MockGame = await ethers.getContractFactory("MockGameBondBank");
    const game = await MockGame.deploy();
    await game.waitForDeployment();

    await bonds.wire([await game.getAddress()], 0, ethers.ZeroHash);
    expect(await bonds.presalePendingRewardEth()).to.equal(rewardShare);
    expect(await bonds.presalePendingYieldEth()).to.equal(yieldShare);
    expect(await ethers.provider.getBalance(await bonds.getAddress())).to.equal(rewardShare + yieldShare);

    await expect(bonds.shutdownPresale())
      .to.emit(bonds, "PresaleProceedsFlushed")
      .withArgs(rewardShare, yieldShare);

    expect(await ethers.provider.getBalance(await game.getAddress())).to.equal(gameBalBefore + rewardShare + yieldShare);
    expect(await bonds.presalePendingRewardEth()).to.equal(0n);
    expect(await bonds.presalePendingYieldEth()).to.equal(0n);
    expect(await ethers.provider.getBalance(await bonds.getAddress())).to.equal(0n);
  });
});
