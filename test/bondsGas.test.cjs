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
    const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress(), ethers.parseEther("1"));
    await bonds.waitForDeployment();

    // Wire game only; vault/coin/vrf omitted.
    await bonds.wire([await game.getAddress()], 0, ethers.ZeroHash);

    // Seed series creation at level 10 (maturity 20).
    await game.setLevel(10);
    await bonds.bondMaintenance(123);

    const depositCount = 500;
    for (let i = 0; i < depositCount; i++) {
      await bonds.depositCurrentFor(admin.address, { value: 1 });
    }

    // Advance level so jackpots run once for the populated day.
    await game.setLevel(11);

    const gas = await bonds.bondMaintenance.estimateGas(456);
    expect(gas).to.be.lt(14_000_000n);
  });
});
