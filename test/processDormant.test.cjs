const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DegenerusGamepieces processDormant", function () {
  it("emits burn transfers for prior level unburned tokens", async function () {
    const [admin, player] = await ethers.getSigners();

    // Dummy external addresses; not used by this test.
    const dummyBonds = ethers.Wallet.createRandom().address;
    const dummyAffiliate = ethers.Wallet.createRandom().address;
    const dummyVault = ethers.Wallet.createRandom().address;
    const dummyRenderer = ethers.Wallet.createRandom().address;

    const Coin = await ethers.getContractFactory("DegenerusCoin");
    const coin = await Coin.deploy(dummyBonds, await admin.getAddress(), dummyAffiliate, dummyVault);
    await coin.waitForDeployment();

    const Gamepieces = await ethers.getContractFactory("ExposedDegenerusGamepieces");
    const nft = await Gamepieces.deploy(dummyRenderer, await coin.getAddress(), dummyAffiliate, dummyVault);
    await nft.waitForDeployment();

    // Wire a dummy game address so we can call onlyGame entrypoints.
    const gameAddr = ethers.Wallet.createRandom().address;
    const coinAddr = await coin.getAddress();
    const coinSigner = await ethers.getImpersonatedSigner(coinAddr);
    await ethers.provider.send("hardhat_setBalance", [coinAddr, ethers.toQuantity(ethers.parseEther("1"))]);
    await nft.connect(coinSigner).wire([gameAddr]);

    const gameSigner = await ethers.getImpersonatedSigner(gameAddr);
    await ethers.provider.send("hardhat_setBalance", [gameAddr, ethers.toQuantity(ethers.parseEther("1"))]);

    const playerAddr = await player.getAddress();

    // Mint 4 tokens to the player (tokenIds 1..4).
    await nft.exposedMint(playerAddr, 4);

    // Retire the level: schedules the dormant range and advances the base pointer.
    await nft.connect(gameSigner).advanceBase();

    const tx1 = await nft.connect(gameSigner).processDormant(2);
    await expect(tx1).to.emit(nft, "Transfer").withArgs(playerAddr, ethers.ZeroAddress, 1n);
    await expect(tx1).to.emit(nft, "Transfer").withArgs(playerAddr, ethers.ZeroAddress, 2n);

    const tx2 = await nft.connect(gameSigner).processDormant(2);
    await expect(tx2).to.emit(nft, "Transfer").withArgs(playerAddr, ethers.ZeroAddress, 3n);
    await expect(tx2).to.emit(nft, "Transfer").withArgs(playerAddr, ethers.ZeroAddress, 4n);

    const tx3 = await nft.connect(gameSigner).processDormant(2);
    const receipt3 = await tx3.wait();
    const transferLogs = receipt3.logs
      .map((log) => {
        try {
          return nft.interface.parseLog(log);
        } catch (err) {
          return null;
        }
      })
      .filter((parsed) => parsed && parsed.name === "Transfer");
    expect(transferLogs.length).to.equal(0);
  });
});
