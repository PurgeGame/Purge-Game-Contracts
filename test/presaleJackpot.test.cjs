const { expect } = require("chai");
const { ethers } = require("hardhat");

function growthMultiplierBpsWithPrev(raised, prev) {
  if (prev === 0n || raised === 0n) return 20_000n;

  const ONE = 10n ** 18n;
  const ratio = (raised * ONE) / prev;
  if (ratio <= 5n * 10n ** 17n) return 30_000n; // <=0.5x -> 3.0x
  if (ratio <= ONE) {
    return 40_000n - (20_000n * ratio) / ONE; // 4 - 2r
  }
  if (ratio <= 2n * ONE) {
    return 20_000n - (10_000n * (ratio - ONE)) / ONE; // 2 - (r-1)
  }
  return 10_000n; // >=2x -> 1.0x
}

function presaleTargetBudget(raised) {
  const prev = ethers.parseEther("50");
  const bps = growthMultiplierBpsWithPrev(raised, prev);
  let target = (raised * bps) / 10_000n;
  if (target < raised) target = raised;
  return target;
}

describe("DegenerusBonds presale jackpot", function () {
  it("mints DGNRS across 5 manual rounds", async function () {
    const [admin, alice, bob] = await ethers.getSigners();

    const MockVrf = await ethers.getContractFactory("MockVRFCoordinator");
    const vrf = await MockVrf.deploy();
    await vrf.waitForDeployment();

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

    // Wire vault + coin; keep game unset (presale mode).
    await bonds.wire(
      [ethers.ZeroAddress, await vault.getAddress(), await coin.getAddress(), await vrf.getAddress()],
      1,
      ethers.keccak256(ethers.toUtf8Bytes("PRESALE_VRF_KEY_HASH"))
    );

    const amountA = ethers.parseEther("10");
    const amountB = ethers.parseEther("15");
    const raised = amountA + amountB;

    await bonds.connect(alice).presaleDeposit(alice.address, { value: amountA });
    await bonds.connect(bob).presaleDeposit(bob.address, { value: amountB });

    const dgnrsAddr = await bonds.dgnrsToken();
    const dgnrs = await ethers.getContractAt("BondToken", dgnrsAddr);

    expect(await dgnrs.totalSupply()).to.equal(0n);

    const perRun = (raised * 10n) / 100n;
    const finalBudget = presaleTargetBudget(raised);

    let expectedMintedBudget = 0n;
    let expectedSupply = 0n;

    for (let run = 0; run < 5; run++) {
      const isFinal = run === 4;
      const toMint = isFinal ? finalBudget - expectedMintedBudget : perRun;
      const minted = toMint;
      expectedSupply += minted;
      expectedMintedBudget = isFinal ? finalBudget : expectedMintedBudget + toMint;

      const requestId = await vrf.nextRequestId();
      await expect(bonds.runPresaleJackpot())
        .to.emit(bonds, "PresaleJackpotVrfRequested")
        .withArgs(requestId);

      const vrfAddr = await vrf.getAddress();
      await ethers.provider.send("hardhat_setBalance", [vrfAddr, "0x56BC75E2D63100000"]); // 100 ETH
      const vrfSigner = await ethers.getImpersonatedSigner(vrfAddr);
      await (await bonds.connect(vrfSigner).fulfillRandomWords(requestId, [BigInt(100 + run)])).wait();

      await expect(bonds.runPresaleJackpot())
        .to.emit(bonds, "PresaleJackpot")
        .withArgs(run, toMint, BigInt(100 + run));

      expect(await dgnrs.totalSupply()).to.equal(expectedSupply);
    }

    // Final invariant: mintedBudget == total DGNRS minted.
    expect(await dgnrs.totalSupply()).to.equal(expectedMintedBudget);
  });
});
