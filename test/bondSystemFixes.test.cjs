const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Bond system fixes", function () {
  it("tracks bondShare into the game's bondPool on bond purchases", async function () {
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

    await bonds.wire([await game.getAddress(), await vault.getAddress()], 0, ethers.ZeroHash);

    const gameAddr = await game.getAddress();
    const gameSigner = await ethers.getImpersonatedSigner(gameAddr);
    await admin.sendTransaction({ to: gameAddr, value: ethers.parseEther("5") });
    await game.setLevel(1);

    const amount = ethers.parseEther("1");
    await bonds.connect(gameSigner).depositFromGame(admin.address, amount, { value: amount });

    expect(await game.lastTrackPool()).to.equal(true);
    expect(await game.trackedBondPool()).to.equal(amount / 2n); // 50% bond backing share
  });

  it("routes stETH to DegenerusVault via payBonds (bonds approves vault)", async function () {
    const [admin] = await ethers.getSigners();

    const MockGame = await ethers.getContractFactory("MockGameBondBank");
    const game = await MockGame.deploy();
    await game.waitForDeployment();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();
    await steth.waitForDeployment();

    const MockCoin = await ethers.getContractFactory("MockVaultCoin");
    const coin = await MockCoin.deploy();
    await coin.waitForDeployment();

    const Bonds = await ethers.getContractFactory("DegenerusBonds");
    const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
    await bonds.waitForDeployment();

    const Vault = await ethers.getContractFactory("DegenerusVault");
    const vault = await Vault.deploy(await coin.getAddress(), await steth.getAddress(), await bonds.getAddress());
    await vault.waitForDeployment();

    await bonds.wire([await game.getAddress(), await vault.getAddress()], 0, ethers.ZeroHash);

    const gameAddr = await game.getAddress();
    const gameSigner = await ethers.getImpersonatedSigner(gameAddr);
    await admin.sendTransaction({ to: gameAddr, value: ethers.parseEther("1") });

    const stAmt = ethers.parseEther("2");
    await steth.mint(gameAddr, stAmt);
    await steth.connect(gameSigner).approve(await bonds.getAddress(), ethers.MaxUint256);

    await bonds.connect(gameSigner).payBonds(0, stAmt, 0);
    expect(await steth.balanceOf(await vault.getAddress())).to.equal(stAmt);
  });

  it("keeps shutdown drain assets in bonds (not vault) and allows public gameOver calls", async function () {
    const [admin] = await ethers.getSigners();

    const MockGame = await ethers.getContractFactory("MockGameBondBank");
    const game = await MockGame.deploy();
    await game.waitForDeployment();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();
    await steth.waitForDeployment();

    const MockCoin = await ethers.getContractFactory("MockVaultCoin");
    const coin = await MockCoin.deploy();
    await coin.waitForDeployment();

    const Bonds = await ethers.getContractFactory("DegenerusBonds");
    const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
    await bonds.waitForDeployment();

    const Vault = await ethers.getContractFactory("DegenerusVault");
    const vault = await Vault.deploy(await coin.getAddress(), await steth.getAddress(), await bonds.getAddress());
    await vault.waitForDeployment();

    await bonds.wire([await game.getAddress(), await vault.getAddress()], 0, ethers.ZeroHash);

    const gameAddr = await game.getAddress();
    const gameSigner = await ethers.getImpersonatedSigner(gameAddr);
    await admin.sendTransaction({ to: gameAddr, value: ethers.parseEther("1") });

    const stAmt = ethers.parseEther("2");
    await steth.mint(gameAddr, stAmt);
    await steth.connect(gameSigner).approve(await bonds.getAddress(), ethers.MaxUint256);

    await bonds.connect(gameSigner).notifyGameOver();

    const ethAmt = ethers.parseEther("0.25");
    await bonds.connect(gameSigner).payBonds(0, stAmt, 0, { value: ethAmt });

    expect(await ethers.provider.getBalance(await bonds.getAddress())).to.equal(ethAmt);
    expect(await steth.balanceOf(await bonds.getAddress())).to.equal(stAmt);
    expect(await ethers.provider.getBalance(await vault.getAddress())).to.equal(0);
    expect(await steth.balanceOf(await vault.getAddress())).to.equal(0);

    await expect(bonds.gameOver()).to.not.be.reverted;
  });

  it("spends MAP jackpot bond bps on bond purchases (not a fixed 10% skim)", async function () {
    const [admin] = await ethers.getSigners();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();
    await steth.waitForDeployment();

    const MockVault = await ethers.getContractFactory("MockVault");
    const vault = await MockVault.deploy(await steth.getAddress());
    await vault.waitForDeployment();

    const Harness = await ethers.getContractFactory("JackpotBondBuyHarness");
    const harness = await Harness.deploy();
    await harness.waitForDeployment();

    const Bonds = await ethers.getContractFactory("DegenerusBonds");
    const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
    await bonds.waitForDeployment();

    const MockCoinModule = await ethers.getContractFactory("MockCoinModule");
    const coin = await MockCoinModule.deploy();
    await coin.waitForDeployment();

    await bonds.wire([await harness.getAddress(), await vault.getAddress()], 0, ethers.ZeroHash);
    await harness.setBonds(await bonds.getAddress());
    // Enable bond purchases (open window: 10-14, 20-24, ...).
    await harness.setLevel(10);

    // Winning traits for rngWord=0 are [0, 64, 128, 192].
    const lvl = 10;
    const holder = await admin.getAddress();
    for (const trait of [0, 64, 128, 192]) {
      await harness.seedTraitTicket(lvl, trait, holder);
    }

    // Fund the harness so it can pay bond purchases (payMapJackpot uses contract ETH).
    await admin.sendTransaction({ to: await harness.getAddress(), value: ethers.parseEther("1") });

    const pool = ethers.parseEther("1");
    await harness.payMapJackpot(lvl, 0, pool, await coin.getAddress());

    // With lvl=10 and rngWord=0, the deterministic bond spend yields this exact vault inflow.
    const expectedVaultEth = 57867199999999993n;
    expect(await ethers.provider.getBalance(await vault.getAddress())).to.equal(expectedVaultEth);
  });
});
