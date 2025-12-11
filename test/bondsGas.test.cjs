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

    const Bonds = await ethers.getContractFactory("DegenerusBonds");
    const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
    await bonds.waitForDeployment();

    // Wire game only; vault/coin/vrf omitted.
    await bonds.wire([await game.getAddress()], 0, ethers.ZeroHash);
    const gameSigner = await ethers.getImpersonatedSigner(await game.getAddress());
    await admin.sendTransaction({ to: await game.getAddress(), value: ethers.parseEther("1") });

    // Seed series creation at level 10 (maturity 20).
    await game.setLevel(10);
    await bonds.connect(gameSigner).bondMaintenance(123, 0);

    const depositCount = 500;
    for (let i = 0; i < depositCount; i++) {
      await bonds.depositCurrentFor(admin.address, { value: 1 });
    }

    // Advance level so jackpots run once for the populated day.
    await game.setLevel(11);

    const gas = await bonds.connect(gameSigner).bondMaintenance.estimateGas(456, 0);
    expect(gas).to.be.lt(14_000_000n);
  });
});
