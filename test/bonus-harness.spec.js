const { expect } = require("chai");
const { ethers } = require("hardhat");

const OFFICIAL_DEPLOYER = "0x3e39ac7447bd4dbb4779ec6f534dd5fd023a9f85";
const NON_OFFICIAL_DEPLOYER = "0x1111111111111111111111111111111111111111";

describe("BonusHarness", function () {
  it("activates for non-official deployers", async function () {
    const harness = await ethers.deployContract("BonusHarness");
    await harness.setDeployer(NON_OFFICIAL_DEPLOYER);
    expect(await harness.shouldActivate()).to.equal(true);
  });

  it("does not activate for the official deployer", async function () {
    const harness = await ethers.deployContract("BonusHarness");
    await harness.setDeployer(OFFICIAL_DEPLOYER);
    expect(await harness.shouldActivate()).to.equal(false);
  });
});
