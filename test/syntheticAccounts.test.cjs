const { expect } = require("chai");
const { ethers } = require("hardhat");

function makeLow48ZeroAddress() {
  const raw = BigInt(ethers.hexlify(ethers.randomBytes(20)));
  let addr = (raw >> 48n) << 48n;
  if (addr === 0n) addr = 1n << 48n;
  return ethers.getAddress(ethers.toBeHex(addr, 20));
}

describe("Synthetic MAP players", function () {
  it("routes synth MAP purchase rewards to affiliate owner", async function () {
    const [admin, affiliateOwner] = await ethers.getSigners();

    const StETH = await ethers.getContractFactory("MockStETH");
    const steth = await StETH.deploy();
    await steth.waitForDeployment();

    const dummyBonds = ethers.Wallet.createRandom().address;
    const dummyVault = ethers.Wallet.createRandom().address;
    const dummyRenderer = ethers.Wallet.createRandom().address;
    const dummyTrophies = ethers.Wallet.createRandom().address;

    const Affiliate = await ethers.getContractFactory("DegenerusAffiliate");
    const affiliate = await Affiliate.deploy(dummyBonds, await admin.getAddress());
    await affiliate.waitForDeployment();

    const Coin = await ethers.getContractFactory("DegenerusCoin");
    const coin = await Coin.deploy(dummyBonds, await admin.getAddress(), await affiliate.getAddress(), dummyVault);
    await coin.waitForDeployment();

    const Endgame = await ethers.getContractFactory("DegenerusGameEndgameModule");
    const endgame = await Endgame.deploy();
    await endgame.waitForDeployment();

    const JackpotModule = await ethers.getContractFactory("DegenerusGameJackpotModule");
    const jackpotModule = await JackpotModule.deploy();
    await jackpotModule.waitForDeployment();

    const MintModule = await ethers.getContractFactory("DegenerusGameMintModule");
    const mintModule = await MintModule.deploy();
    await mintModule.waitForDeployment();

    const BondModule = await ethers.getContractFactory("DegenerusGameBondModule");
    const bondModule = await BondModule.deploy();
    await bondModule.waitForDeployment();

    const Gamepieces = await ethers.getContractFactory("DegenerusGamepieces");
    const nft = await Gamepieces.deploy(dummyRenderer, await coin.getAddress(), await affiliate.getAddress(), dummyVault);
    await nft.waitForDeployment();

    const Game = await ethers.getContractFactory("DegenerusGame");
    const game = await Game.deploy(
      await coin.getAddress(),
      dummyRenderer,
      await nft.getAddress(),
      await endgame.getAddress(),
      await jackpotModule.getAddress(),
      await mintModule.getAddress(),
      await bondModule.getAddress(),
      await steth.getAddress(),
      ethers.ZeroAddress, // jackpots (unused)
      dummyBonds,
      dummyTrophies,
      await affiliate.getAddress(),
      dummyVault,
      await admin.getAddress()
    );
    await game.waitForDeployment();

    // Wire core dependencies.
    await coin.wire([await game.getAddress(), await nft.getAddress(), ethers.ZeroAddress, ethers.ZeroAddress]);
    const coinAddr = await coin.getAddress();
    const coinSigner = await ethers.getImpersonatedSigner(coinAddr);
    await ethers.provider.send("hardhat_setBalance", [coinAddr, ethers.toQuantity(ethers.parseEther("1"))]);
    await nft.connect(coinSigner).wire([await game.getAddress()]);
    await affiliate.wire([await coin.getAddress(), await game.getAddress(), await nft.getAddress()]);

    // Create an affiliate code and a synthetic MAP-only player.
    const code = ethers.encodeBytes32String("AFF");
    await affiliate.connect(affiliateOwner).createAffiliateCode(code, 10);

    const synthetic = await game.connect(affiliateOwner).createSyntheticMapPlayer.staticCall(code);
    await game.connect(affiliateOwner).createSyntheticMapPlayer(code);

    expect(await affiliate.syntheticMapOwner(synthetic)).to.equal(await affiliateOwner.getAddress());

    // Buy 1 MAP for the synthetic via direct ETH.
    const [, , , , priceWei] = await game.purchaseInfo();
    const costWei = priceWei / 4n;

    const ownerAddr = await affiliateOwner.getAddress();
    const beforeOwner = await coin.coinflipAmount(ownerAddr);
    const beforeSynth = await coin.coinflipAmount(synthetic);

    await nft.connect(affiliateOwner).purchaseMapForSynthetic(synthetic, 1, false, { value: costWei });

    const afterOwner = await coin.coinflipAmount(ownerAddr);
    const afterSynth = await coin.coinflipAmount(synthetic);

    expect(afterOwner).to.be.gt(beforeOwner);
    expect(afterSynth).to.equal(beforeSynth);
  });

  it("routes synth claimable ETH credits to affiliate owner", async function () {
    const [admin, affiliateOwner] = await ethers.getSigners();

    const StETH = await ethers.getContractFactory("MockStETH");
    const steth = await StETH.deploy();
    await steth.waitForDeployment();

    const dummyBonds = ethers.Wallet.createRandom().address;
    const dummyVault = ethers.Wallet.createRandom().address;
    const dummyRenderer = ethers.Wallet.createRandom().address;
    const dummyTrophies = ethers.Wallet.createRandom().address;

    const Affiliate = await ethers.getContractFactory("DegenerusAffiliate");
    const affiliate = await Affiliate.deploy(dummyBonds, await admin.getAddress());
    await affiliate.waitForDeployment();

    const Coin = await ethers.getContractFactory("DegenerusCoin");
    const coin = await Coin.deploy(dummyBonds, await admin.getAddress(), await affiliate.getAddress(), dummyVault);
    await coin.waitForDeployment();

    const Endgame = await ethers.getContractFactory("DegenerusGameEndgameModule");
    const endgame = await Endgame.deploy();
    await endgame.waitForDeployment();

    const JackpotModule = await ethers.getContractFactory("DegenerusGameJackpotModule");
    const jackpotModule = await JackpotModule.deploy();
    await jackpotModule.waitForDeployment();

    const MintModule = await ethers.getContractFactory("DegenerusGameMintModule");
    const mintModule = await MintModule.deploy();
    await mintModule.waitForDeployment();

    const BondModule = await ethers.getContractFactory("DegenerusGameBondModule");
    const bondModule = await BondModule.deploy();
    await bondModule.waitForDeployment();

    const Gamepieces = await ethers.getContractFactory("DegenerusGamepieces");
    const nft = await Gamepieces.deploy(dummyRenderer, await coin.getAddress(), await affiliate.getAddress(), dummyVault);
    await nft.waitForDeployment();

    const Game = await ethers.getContractFactory("DegenerusGame");
    const game = await Game.deploy(
      await coin.getAddress(),
      dummyRenderer,
      await nft.getAddress(),
      await endgame.getAddress(),
      await jackpotModule.getAddress(),
      await mintModule.getAddress(),
      await bondModule.getAddress(),
      await steth.getAddress(),
      ethers.ZeroAddress, // jackpots (unused)
      dummyBonds,
      dummyTrophies,
      await affiliate.getAddress(),
      dummyVault,
      await admin.getAddress()
    );
    await game.waitForDeployment();

    // Wire core dependencies.
    await coin.wire([await game.getAddress(), await nft.getAddress(), ethers.ZeroAddress, ethers.ZeroAddress]);
    const coinAddr = await coin.getAddress();
    const coinSigner = await ethers.getImpersonatedSigner(coinAddr);
    await ethers.provider.send("hardhat_setBalance", [coinAddr, ethers.toQuantity(ethers.parseEther("1"))]);
    await nft.connect(coinSigner).wire([await game.getAddress()]);
    await affiliate.wire([await coin.getAddress(), await game.getAddress(), await nft.getAddress()]);

    const code = ethers.encodeBytes32String("AFF");
    await affiliate.connect(affiliateOwner).createAffiliateCode(code, 10);

    const synthetic = await game.connect(affiliateOwner).createSyntheticMapPlayer.staticCall(code);
    await game.connect(affiliateOwner).createSyntheticMapPlayer(code);

    // Fund the bond pool and credit winnings to the synthetic "beneficiary" (should reroute).
    const amount = ethers.parseEther("1");
    const bondsAddr = dummyBonds;
    const bondsSigner = await ethers.getImpersonatedSigner(bondsAddr);
    await ethers.provider.send("hardhat_setBalance", [bondsAddr, ethers.toQuantity(ethers.parseEther("10"))]);

    await game.connect(bondsSigner).bondDeposit(true, { value: amount });
    await game.connect(bondsSigner).bondCreditToClaimable(synthetic, amount);

    const ownerWinnings = await game.connect(affiliateOwner).getWinnings();
    expect(ownerWinnings).to.be.gt(0n);

    const synthSigner = await ethers.getImpersonatedSigner(synthetic);
    await ethers.provider.send("hardhat_setBalance", [synthetic, ethers.toQuantity(ethers.parseEther("1"))]);
    const synthWinnings = await game.connect(synthSigner).getWinnings();
    expect(synthWinnings).to.equal(0n);
  });

  it("mints BAF trophies to affiliate owner when the winner is synthetic", async function () {
    const [deployer, affiliateOwner] = await ethers.getSigners();

    const synthetic = makeLow48ZeroAddress();

    const MockAffiliate = await ethers.getContractFactory("MockAffiliate");
    const affiliate = await MockAffiliate.deploy();
    await affiliate.waitForDeployment();

    const EndgameHarness = await ethers.getContractFactory("EndgameHarness");
    const harness = await EndgameHarness.deploy();
    await harness.waitForDeployment();

    const MockBonds = await ethers.getContractFactory("MockBondsJackpot");
    const bonds = await MockBonds.deploy();
    await bonds.waitForDeployment();

    const Trophies = await ethers.getContractFactory("DegenerusTrophies");
    const trophies = await Trophies.deploy(ethers.Wallet.createRandom().address);
    await trophies.waitForDeployment();
    await trophies.connect(deployer).setGame(await harness.getAddress());

    const MockJackpots = await ethers.getContractFactory("MockJackpotsBaf");
    const jackpots = await MockJackpots.deploy(synthetic);
    await jackpots.waitForDeployment();

    const ownerAddr = await affiliateOwner.getAddress();
    await affiliate.setSynthetic(synthetic, ownerAddr, ethers.encodeBytes32String("AFF"));

    await harness.setAffiliateProgramAddr(await affiliate.getAddress());
    await harness.setTrophies(await trophies.getAddress());
    await harness.setBonds(await bonds.getAddress());
    await harness.setRewardPool(ethers.parseEther("10"));

    // lvl=1 -> prevLevel=0 -> BAF path runs.
    await harness.finalizeEndgame(1, 123456789, await jackpots.getAddress());

    expect(await trophies.balanceOf(ownerAddr)).to.equal(1n);
    expect(await trophies.balanceOf(synthetic)).to.equal(0n);
    expect(await harness.claimableWinningsOf(ownerAddr)).to.be.gt(0n);
    expect(await harness.claimableWinningsOf(synthetic)).to.equal(0n);
  });
});
