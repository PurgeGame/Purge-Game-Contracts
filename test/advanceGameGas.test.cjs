const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DegenerusGame advanceGame gas", function () {
  it("processes map batches under 15M (advanceGame(0))", async function () {
    const [admin, caller] = await ethers.getSigners();

    const VRF = await ethers.getContractFactory("MockVRFCoordinator");
    const vrf = await VRF.deploy();
    await vrf.waitForDeployment();

    const StETH = await ethers.getContractFactory("MockStETH");
    const steth = await StETH.deploy();
    await steth.waitForDeployment();

    // Dummy external addresses; not used by this test.
    const dummyBonds = ethers.Wallet.createRandom().address;
    const dummyAffiliate = ethers.Wallet.createRandom().address;
    const dummyVault = ethers.Wallet.createRandom().address;
    const dummyRenderer = ethers.Wallet.createRandom().address;
    const dummyTrophies = ethers.Wallet.createRandom().address;

    const Coin = await ethers.getContractFactory("DegenerusCoin");
    const coin = await Coin.deploy(dummyBonds, await admin.getAddress(), dummyAffiliate, dummyVault);
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
    const nft = await Gamepieces.deploy(dummyRenderer, await coin.getAddress(), dummyAffiliate, dummyVault);
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
      dummyAffiliate,
      dummyVault,
      await admin.getAddress()
    );
    await game.waitForDeployment();

    // Wire the game address into dependent contracts.
    await coin.wire([await game.getAddress(), await nft.getAddress(), ethers.ZeroAddress, ethers.ZeroAddress]);
    const coinAddr = await coin.getAddress();
    const coinSigner = await ethers.getImpersonatedSigner(coinAddr);
    await ethers.provider.send("hardhat_setBalance", [coinAddr, ethers.toQuantity(ethers.parseEther("1"))]);
    await nft.connect(coinSigner).wire([await game.getAddress()]);

    // Wire VRF so advanceGame can request randomness.
    await game.wireVrf(await vrf.getAddress(), 1, ethers.hexlify(ethers.randomBytes(32)));

    // Request RNG once (cap!=0 bypasses MustMintToday).
    await game.connect(caller).advanceGame(1);
    const reqId = (await vrf.nextRequestId()) - 1n;

    // Fulfill VRF.
    const vrfAddr = await vrf.getAddress();
    const vrfSigner = await ethers.getImpersonatedSigner(vrfAddr);
    await ethers.provider.send("hardhat_setBalance", [vrfAddr, ethers.toQuantity(ethers.parseEther("1"))]);
    await game.connect(vrfSigner).rawFulfillRandomWords(reqId, [123456789n]);

    // Enqueue a large MAP backlog and mark the caller as having minted today, both as the NFT contract.
    const nftAddr = await nft.getAddress();
    const nftSigner = await ethers.getImpersonatedSigner(nftAddr);
    await ethers.provider.send("hardhat_setBalance", [nftAddr, ethers.toQuantity(ethers.parseEther("1"))]);

    const mapBuyer = ethers.Wallet.createRandom().address;
    await game.connect(nftSigner).enqueueMap(mapBuyer, 500_000);

    // Satisfy MustMintToday() for `advanceGame(0)` by preloading the caller's mintPacked_ day slot.
    // `mintPacked_` lives at storage slot 64 in `DegenerusGameStorage`.
    const mintPackedMappingSlot = 64n;
    const mintPackedKey = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256"],
        [await caller.getAddress(), mintPackedMappingSlot]
      )
    );
    await ethers.provider.send("hardhat_setStorageAt", [
      await game.getAddress(),
      mintPackedKey,
      ethers.zeroPadValue("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", 32),
    ]);

    // Execute one batch to move past the "first batch" reduced budget, then estimate the next batch.
    await game.connect(caller).advanceGame(0);
    const gas = await game.connect(caller).advanceGame.estimateGas(0);
    expect(gas).to.be.lt(15_000_000n);
  });
});
