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

  console.log("5. Deploying DegenerusAffiliate...");
  const DegenerusAffiliate = await ethers.getContractFactory("DegenerusAffiliate");
  const affiliate = await DegenerusAffiliate.deploy(bondsAddr);
  await affiliate.waitForDeployment();
  console.log("   DegenerusAffiliate deployed at:", await affiliate.getAddress());

  console.log("6. Deploying DegenerusCoin...");
  const DegenerusCoin = await ethers.getContractFactory("DegenerusCoin");
  const degeneruscoin = await DegenerusCoin.deploy(bondsAddr, await affiliate.getAddress(), await renderer.getAddress());
  await degeneruscoin.waitForDeployment();
  console.log("   DegenerusCoin deployed at:", await degeneruscoin.getAddress());

  console.log("7. Deploying DegenerusGameNFT...");
  const DegenerusGameNFT = await ethers.getContractFactory("DegenerusGameNFT");
  const degenerusNFT = await DegenerusGameNFT.deploy(await renderer.getAddress(), await degeneruscoin.getAddress());
  await degenerusNFT.waitForDeployment();
  console.log("   DegenerusGameNFT deployed at:", await degenerusNFT.getAddress());

  console.log("8. Deploying DegenerusTrophies...");
  const DegenerusTrophies = await ethers.getContractFactory("DegenerusTrophies");
  const trophies = await DegenerusTrophies.deploy(await renderer.getAddress());
  await trophies.waitForDeployment();
  console.log("   DegenerusTrophies deployed at:", await trophies.getAddress());

  console.log("9. Deploying Modules...");
  const DegenerusGameEndgameModule = await ethers.getContractFactory("DegenerusGameEndgameModule");
  const endgameModule = await DegenerusGameEndgameModule.deploy();
  await endgameModule.waitForDeployment();
  console.log("   EndgameModule deployed.");

  const DegenerusGameJackpotModule = await ethers.getContractFactory("DegenerusGameJackpotModule");
  const jackpotModule = await DegenerusGameJackpotModule.deploy();
  await jackpotModule.waitForDeployment();
  console.log("   JackpotModule deployed.");

  const DegenerusGameMintModule = await ethers.getContractFactory("DegenerusGameMintModule");
  const mintModule = await DegenerusGameMintModule.deploy();
  await mintModule.waitForDeployment();
  console.log("   MintModule deployed.");

  const DegenerusGameBondModule = await ethers.getContractFactory("DegenerusGameBondModule");
  const bondModule = await DegenerusGameBondModule.deploy();
  await bondModule.waitForDeployment();
  console.log("   BondModule deployed.");

  // Check if DegenerusQuestModule exists or use Mock
  try {
      const DegenerusQuestModule = await ethers.getContractFactory("contracts/modules/DegenerusQuestModule.sol:DegenerusQuestModule");
      const questModule = await DegenerusQuestModule.deploy();
      await questModule.waitForDeployment();
      console.log("   DegenerusQuestModule deployed.");
  } catch (e) {
      console.log("   DegenerusQuestModule deployment failed, using Mock?", e.message);
  }

  let jackpotsAddr = bondsAddr;
  try {
      const DegenerusJackpots = await ethers.getContractFactory("contracts/DegenerusJackpots.sol:DegenerusJackpots");
      const jackpots = await DegenerusJackpots.deploy(bondsAddr);
      await jackpots.waitForDeployment();
      jackpotsAddr = await jackpots.getAddress();
      console.log("   Jackpots module deployed at:", jackpotsAddr);
  } catch (e) {
      console.log("   Jackpots module deployment failed.", e.message);
  }

  console.log("10. Deploying DegenerusGame...");
  const DegenerusGame = await ethers.getContractFactory("DegenerusGame");
  const degenerusGame = await DegenerusGame.deploy(
    await degeneruscoin.getAddress(),
    await renderer.getAddress(),
    await degenerusNFT.getAddress(),
    await endgameModule.getAddress(),
    await jackpotModule.getAddress(),
    await mintModule.getAddress(),
    await bondModule.getAddress(),
    await vrf.getAddress(),
    ethers.ZeroHash,
    await steth.getAddress(),
    jackpotsAddr,
    bondsAddr,
    await trophies.getAddress(),
    await affiliate.getAddress(),
    deployer.address
  );
  await degenerusGame.waitForDeployment();
  console.log("   DegenerusGame deployed at:", await degenerusGame.getAddress());

  const setGameTx = await trophies.setGame(await degenerusGame.getAddress());
  await setGameTx.wait();
  console.log("   Trophies wired to game.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
