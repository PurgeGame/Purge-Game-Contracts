const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);

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

  console.log("4. Deploying Purgecoin...");
  const Purgecoin = await ethers.getContractFactory("Purgecoin");
  const purgecoin = await Purgecoin.deploy();
  await purgecoin.waitForDeployment();
  console.log("   Purgecoin deployed at:", await purgecoin.getAddress());

  console.log("5. Deploying PurgeGameNFT...");
  const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
  const purgeNFT = await PurgeGameNFT.deploy(
    await renderer.getAddress(),
    await renderer.getAddress(),
    await purgecoin.getAddress()
  );
  await purgeNFT.waitForDeployment();
  console.log("   PurgeGameNFT deployed at:", await purgeNFT.getAddress());

  console.log("6. Deploying PurgeGameTrophies...");
  const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
  const purgeTrophies = await PurgeGameTrophies.deploy(await purgeNFT.getAddress());
  await purgeTrophies.waitForDeployment();
  console.log("   PurgeGameTrophies deployed at:", await purgeTrophies.getAddress());

  console.log("7. Deploying Modules...");
  const PurgeGameEndgameModule = await ethers.getContractFactory("PurgeGameEndgameModule");
  const endgameModule = await PurgeGameEndgameModule.deploy();
  await endgameModule.waitForDeployment();
  console.log("   EndgameModule deployed.");

  const PurgeGameJackpotModule = await ethers.getContractFactory("PurgeGameJackpotModule");
  const jackpotModule = await PurgeGameJackpotModule.deploy();
  await jackpotModule.waitForDeployment();
  console.log("   JackpotModule deployed.");

  // Check if PurgeQuestModule exists or use Mock
  try {
      const PurgeQuestModule = await ethers.getContractFactory("contracts/modules/PurgeQuestModule.sol:PurgeQuestModule");
      const questModule = await PurgeQuestModule.deploy();
      await questModule.waitForDeployment();
      console.log("   PurgeQuestModule deployed.");
  } catch (e) {
      console.log("   PurgeQuestModule deployment failed, using Mock?", e.message);
  }

  try {
      const PurgeCoinExternalJackpotModule = await ethers.getContractFactory("contracts/modules/PurgeCoinExternalJackpotModule.sol:PurgeCoinExternalJackpotModule");
      const externalJackpotModule = await PurgeCoinExternalJackpotModule.deploy();
      await externalJackpotModule.waitForDeployment();
      console.log("   ExternalJackpotModule deployed.");
  } catch (e) {
      console.log("   ExternalJackpotModule deployment failed.", e.message);
  }

  console.log("8. Deploying PurgeGame...");
  const PurgeGame = await ethers.getContractFactory("PurgeGame");
  const purgeGame = await PurgeGame.deploy(
    await purgecoin.getAddress(),
    await renderer.getAddress(),
    await purgeNFT.getAddress(),
    await purgeTrophies.getAddress(),
    await endgameModule.getAddress(),
    await jackpotModule.getAddress(),
    await vrf.getAddress(),
    ethers.ZeroHash,
    1n,
    await link.getAddress()
  );
  await purgeGame.waitForDeployment();
  console.log("   PurgeGame deployed at:", await purgeGame.getAddress());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
