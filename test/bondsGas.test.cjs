const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DegenerusBonds gas", function () {
  it("runs bondMaintenance jackpot day well under 14M with hundreds of entrants", async function () {
    const [admin] = await ethers.getSigners();

    const MockGame = await ethers.getContractFactory("MockGameBondBank");
    const game = await MockGame.deploy();
    await game.waitForDeployment();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();
    await steth.waitForDeployment();

    const MockVault = await ethers.getContractFactory("MockVault");
    const vault = await MockVault.deploy(await steth.getAddress());
    await vault.waitForDeployment();

    const Bonds = await ethers.getContractFactory("DegenerusBonds");
    const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
    await bonds.waitForDeployment();

    // Wire game + vault; coin/vrf omitted.
    await bonds.wire([await game.getAddress(), await vault.getAddress()], 0, ethers.ZeroHash);
    const gameSigner = await ethers.getImpersonatedSigner(await game.getAddress());
    await admin.sendTransaction({ to: await game.getAddress(), value: ethers.parseEther("1") });

    // Seed the first series (maturity 10) and populate it with many entrants.
    await game.setLevel(0);
    await bonds.connect(gameSigner).bondMaintenance(123, 0);
    await game.setLevel(1);

    const depositCount = 500;
    for (let i = 0; i < depositCount; i++) {
      await bonds.connect(gameSigner).depositFromGame(admin.address, 1, { value: 1 });
    }

    const gas = await bonds.connect(gameSigner).bondMaintenance.estimateGas(456, 0);
    expect(gas).to.be.lt(14_000_000n);
  });
});
