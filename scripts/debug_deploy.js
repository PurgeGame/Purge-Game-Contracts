const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const bondsAddr = deployer.address;

  console.log("1. Deploying MockLinkToken...");
  const MockLinkToken = await ethers.getContractFactory("MockLinkToken");
  const link = await MockLinkToken.deploy();
  await link.waitForDeployment();
  console.log("   MockLinkToken deployed at:", await link.getAddress());

  console.log("2. Deploying MockRenderer...");
  const MockRenderer = await ethers.getContractFactory("MockRenderer");
  const renderer = await MockRenderer.deploy();
  await renderer.waitForDeployment();
  console.log("   MockRenderer deployed at:", await renderer.getAddress());

  console.log("3. Deploying MockVRFCoordinator...");
  const MockVRF = await ethers.getContractFactory("MockVRFCoordinator");
  const vrf = await MockVRF.deploy(ethers.parseEther("500"));
  await vrf.waitForDeployment();
  console.log("   MockVRFCoordinator deployed at:", await vrf.getAddress());

  console.log("4. Deploying Mock stETH...");
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const steth = await MockERC20.deploy();
  await steth.waitForDeployment();
  console.log("   Mock stETH deployed at:", await steth.getAddress());

  console.log("5. Deploying PurgeAffiliate...");
  const PurgeAffiliate = await ethers.getContractFactory("PurgeAffiliate");
  const affiliate = await PurgeAffiliate.deploy(bondsAddr);
  await affiliate.waitForDeployment();
  console.log("   PurgeAffiliate deployed at:", await affiliate.getAddress());

  console.log("6. Deploying Purgecoin...");
  const Purgecoin = await ethers.getContractFactory("Purgecoin");
  const purgecoin = await Purgecoin.deploy(bondsAddr, await affiliate.getAddress(), await renderer.getAddress());
  await purgecoin.waitForDeployment();
  console.log("   Purgecoin deployed at:", await purgecoin.getAddress());

  console.log("7. Deploying PurgeGameNFT...");
  const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
  const purgeNFT = await PurgeGameNFT.deploy(await renderer.getAddress(), await purgecoin.getAddress());
  await purgeNFT.waitForDeployment();
  console.log("   PurgeGameNFT deployed at:", await purgeNFT.getAddress());

  console.log("8. Deploying PurgeTrophies...");
  const PurgeTrophies = await ethers.getContractFactory("PurgeTrophies");
  const trophies = await PurgeTrophies.deploy(await renderer.getAddress());
  await trophies.waitForDeployment();
  console.log("   PurgeTrophies deployed at:", await trophies.getAddress());

  console.log("9. Deploying Modules...");
  const PurgeGameEndgameModule = await ethers.getContractFactory("PurgeGameEndgameModule");
  const endgameModule = await PurgeGameEndgameModule.deploy();
  await endgameModule.waitForDeployment();
  console.log("   EndgameModule deployed.");

  const PurgeGameJackpotModule = await ethers.getContractFactory("PurgeGameJackpotModule");
  const jackpotModule = await PurgeGameJackpotModule.deploy();
  await jackpotModule.waitForDeployment();
  console.log("   JackpotModule deployed.");

  const PurgeGameMintModule = await ethers.getContractFactory("PurgeGameMintModule");
  const mintModule = await PurgeGameMintModule.deploy();
  await mintModule.waitForDeployment();
  console.log("   MintModule deployed.");

  const PurgeGameBondModule = await ethers.getContractFactory("PurgeGameBondModule");
  const bondModule = await PurgeGameBondModule.deploy();
  await bondModule.waitForDeployment();
  console.log("   BondModule deployed.");

  // Check if PurgeQuestModule exists or use Mock
  try {
      const PurgeQuestModule = await ethers.getContractFactory("contracts/modules/PurgeQuestModule.sol:PurgeQuestModule");
      const questModule = await PurgeQuestModule.deploy();
      await questModule.waitForDeployment();
      console.log("   PurgeQuestModule deployed.");
  } catch (e) {
      console.log("   PurgeQuestModule deployment failed, using Mock?", e.message);
  }

  let jackpotsAddr = bondsAddr;
  try {
      const PurgeJackpots = await ethers.getContractFactory("contracts/PurgeJackpots.sol:PurgeJackpots");
      const jackpots = await PurgeJackpots.deploy(bondsAddr);
      await jackpots.waitForDeployment();
      jackpotsAddr = await jackpots.getAddress();
      console.log("   Jackpots module deployed at:", jackpotsAddr);
  } catch (e) {
      console.log("   Jackpots module deployment failed.", e.message);
  }

  console.log("10. Deploying PurgeGame...");
  const PurgeGame = await ethers.getContractFactory("PurgeGame");
  const purgeGame = await PurgeGame.deploy(
    await purgecoin.getAddress(),
    await renderer.getAddress(),
    await purgeNFT.getAddress(),
    await endgameModule.getAddress(),
    await jackpotModule.getAddress(),
    await mintModule.getAddress(),
    await bondModule.getAddress(),
    await vrf.getAddress(),
    ethers.ZeroHash,
    1n,
    await link.getAddress(),
    await steth.getAddress(),
    jackpotsAddr,
    bondsAddr,
    await trophies.getAddress()
  );
  await purgeGame.waitForDeployment();
  console.log("   PurgeGame deployed at:", await purgeGame.getAddress());

  const setGameTx = await trophies.setGame(await purgeGame.getAddress());
  await setGameTx.wait();
  console.log("   Trophies wired to game.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
