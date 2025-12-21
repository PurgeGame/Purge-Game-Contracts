import hre from "hardhat";
import fs from "node:fs";
import path from "node:path";

const { ethers, network } = hre;

const ZERO_ADDRESS = ethers.ZeroAddress;

function pickEnv(...names) {
  for (const name of names) {
    const value = process.env[name];
    if (value && value.trim() !== "") return value.trim();
  }
  return undefined;
}

function requireEnv(...names) {
  const value = pickEnv(...names);
  if (!value) {
    throw new Error(`Missing env: ${names.join(" or ")}`);
  }
  return value;
}

function requireAddress(...names) {
  const value = requireEnv(...names);
  if (!ethers.isAddress(value)) {
    throw new Error(`Invalid address for ${names[0]}: ${value}`);
  }
  return ethers.getAddress(value);
}

function optionalAddress(...names) {
  const value = pickEnv(...names);
  if (!value) return undefined;
  if (!ethers.isAddress(value)) {
    throw new Error(`Invalid address for ${names[0]}: ${value}`);
  }
  return ethers.getAddress(value);
}

function requireBytes32(...names) {
  const value = requireEnv(...names);
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`Invalid bytes32 for ${names[0]}: ${value}`);
  }
  return value;
}

function requireUint(...names) {
  const value = requireEnv(...names);
  try {
    return BigInt(value);
  } catch (err) {
    throw new Error(`Invalid uint for ${names[0]}: ${value}`);
  }
}

function loadIconsData() {
  const filePath = path.resolve(process.cwd(), "scripts/data/icons32Data.json");
  const raw = fs.readFileSync(filePath, "utf8");
  const data = JSON.parse(raw);
  if (!Array.isArray(data.paths) || data.paths.length !== 33) {
    throw new Error("icons32Data.paths must contain 33 items");
  }
  if (!Array.isArray(data.symQ1) || data.symQ1.length !== 8) {
    throw new Error("icons32Data.symQ1 must contain 8 items");
  }
  if (!Array.isArray(data.symQ2) || data.symQ2.length !== 8) {
    throw new Error("icons32Data.symQ2 must contain 8 items");
  }
  if (!Array.isArray(data.symQ3) || data.symQ3.length !== 8) {
    throw new Error("icons32Data.symQ3 must contain 8 items");
  }
  return data;
}

async function deployContract(name, args = []) {
  const Factory = await ethers.getContractFactory(name);
  const contract = await Factory.deploy(...args);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log(`[deploy] ${name}: ${address}`);
  return contract;
}

async function main() {
  const [deployer] = await ethers.getSigners();
  const isLocal = network.name === "hardhat" || network.name === "localhost";
  const defaultMode = isLocal ? "manual" : "admin";
  const mode = (process.env.DEPLOY_MODE || defaultMode).toLowerCase();
  if (mode !== "admin" && mode !== "manual") {
    throw new Error(`Invalid DEPLOY_MODE: ${mode}`);
  }

  const useAdmin = mode === "admin";
  const useMocks = process.env.USE_MOCKS === "1" || (isLocal && process.env.USE_MOCKS !== "0");

  if (useAdmin && useMocks) {
    throw new Error("Admin mode requires a VRF coordinator with createSubscription; disable USE_MOCKS or set DEPLOY_MODE=manual.");
  }

  console.log(`[deploy] network=${network.name} deployer=${deployer.address} mode=${mode} mocks=${useMocks}`);

  let stethAddress;
  let vrfCoordinatorAddress;
  let vrfKeyHash;
  let vrfSubId;

  if (useMocks) {
    const mockVrf = await deployContract("MockVRFCoordinator");
    vrfCoordinatorAddress = await mockVrf.getAddress();
    const mockSteth = await deployContract("MockStETH");
    stethAddress = await mockSteth.getAddress();
    vrfKeyHash = ethers.hexlify(ethers.randomBytes(32));
    vrfSubId = 1n;
  } else {
    stethAddress = requireAddress("STETH_ADDRESS", "STETH");
    vrfCoordinatorAddress = requireAddress("VRF_COORDINATOR", "PURGE_VRF_COORDINATOR");
    vrfKeyHash = requireBytes32("VRF_KEY_HASH", "PURGE_VRF_KEY_HASH");
    if (!useAdmin) {
      vrfSubId = requireUint("VRF_SUB_ID", "PURGE_VRF_SUBSCRIPTION_ID");
    }
  }

  let adminContract;
  let adminAddress = deployer.address;

  if (useAdmin) {
    const linkToken = requireAddress("LINK_TOKEN", "LINK_TOKEN_ADDRESS");
    adminContract = await deployContract("DegenerusAdmin", [linkToken]);
    adminAddress = await adminContract.getAddress();
  }

  const iconsData = loadIconsData();
  const icons = await deployContract("Icons32Data", [
    iconsData.paths,
    iconsData.diamond,
    iconsData.symQ1,
    iconsData.symQ2,
    iconsData.symQ3
  ]);
  const registry = await deployContract("IconColorRegistry", [ZERO_ADDRESS]);
  const assets = await deployContract("TrophySvgAssets");

  const bonds = await deployContract("DegenerusBonds", [adminAddress, stethAddress]);
  const affiliate = await deployContract("DegenerusAffiliate", [await bonds.getAddress(), adminAddress]);

  // Precompute the vault address so the coin can be deployed with it and the vault constructor no-ops its setVault call.
  const predictedVault = ethers.getCreateAddress({
    from: deployer.address,
    nonce: (await deployer.getNonce()) + 1
  });

  const coin = await deployContract("DegenerusCoin", [
    await bonds.getAddress(),
    adminAddress,
    await affiliate.getAddress(),
    predictedVault
  ]);
  const vault = await deployContract("DegenerusVault", [
    await coin.getAddress(),
    stethAddress,
    await bonds.getAddress()
  ]);
  const vaultAddress = await vault.getAddress();
  if (vaultAddress.toLowerCase() !== predictedVault.toLowerCase()) {
    throw new Error(`Vault address mismatch: expected ${predictedVault}, got ${vaultAddress}`);
  }

  const questModule = await deployContract("DegenerusQuestModule", [await coin.getAddress()]);
  const endgameModule = await deployContract("DegenerusGameEndgameModule");
  const jackpotModule = await deployContract("DegenerusGameJackpotModule");
  const mintModule = await deployContract("DegenerusGameMintModule");
  const bondModule = await deployContract("DegenerusGameBondModule");
  const jackpots = await deployContract("DegenerusJackpots", [await bonds.getAddress(), adminAddress]);

  const regularRenderer = await deployContract("IconRendererRegular32", [
    await coin.getAddress(),
    await icons.getAddress(),
    await registry.getAddress(),
    adminAddress
  ]);
  const trophySvg = await deployContract("IconRendererTrophy32Svg", [
    await coin.getAddress(),
    await icons.getAddress(),
    await registry.getAddress(),
    await assets.getAddress(),
    adminAddress
  ]);
  const trophyRenderer = await deployContract("IconRendererTrophy32", [
    await icons.getAddress(),
    await registry.getAddress(),
    await trophySvg.getAddress(),
    adminAddress
  ]);

  await (await registry.setRenderer(await regularRenderer.getAddress())).wait();

  const trophies = await deployContract("DegenerusTrophies", [await trophyRenderer.getAddress()]);
  const gamepieces = await deployContract("DegenerusGamepieces", [
    await regularRenderer.getAddress(),
    await coin.getAddress(),
    await affiliate.getAddress(),
    await vault.getAddress()
  ]);

  await (await registry.addAllowedToken(await gamepieces.getAddress())).wait();

  const game = await deployContract("DegenerusGame", [
    await coin.getAddress(),
    await gamepieces.getAddress(),
    await endgameModule.getAddress(),
    await jackpotModule.getAddress(),
    await mintModule.getAddress(),
    await bondModule.getAddress(),
    stethAddress,
    await jackpots.getAddress(),
    await bonds.getAddress(),
    await trophies.getAddress(),
    await affiliate.getAddress(),
    await vault.getAddress(),
    adminAddress
  ]);

  await (await trophies.setGame(await game.getAddress())).wait();

  if (useAdmin) {
    const modules = [
      await regularRenderer.getAddress(),
      await trophyRenderer.getAddress(),
      await trophySvg.getAddress()
    ];
    const moduleWires = [
      [await game.getAddress(), await gamepieces.getAddress(), await trophies.getAddress()],
      [await trophies.getAddress()],
      [await trophies.getAddress()]
    ];

    const tx = await adminContract.wireAll(
      await bonds.getAddress(),
      vrfCoordinatorAddress,
      vrfKeyHash,
      await game.getAddress(),
      await coin.getAddress(),
      await affiliate.getAddress(),
      await jackpots.getAddress(),
      await questModule.getAddress(),
      await trophies.getAddress(),
      await gamepieces.getAddress(),
      await vault.getAddress(),
      modules,
      moduleWires
    );
    await tx.wait();

    const subId = await adminContract.subscriptionId();
    console.log(`[deploy] VRF subscription id: ${subId.toString()}`);

    const linkEthFeed = optionalAddress("LINK_ETH_FEED");
    if (linkEthFeed) {
      await (await adminContract.setLinkEthPriceFeed(linkEthFeed)).wait();
    }
  } else {
    await (await questModule.wire([await game.getAddress()])).wait();
    await (
      await coin.wire([
        await game.getAddress(),
        await gamepieces.getAddress(),
        await questModule.getAddress(),
        await jackpots.getAddress()
      ])
    ).wait();
    await (await gamepieces.wire([await game.getAddress()])).wait();
    await (
      await affiliate.wire([
        await coin.getAddress(),
        await game.getAddress(),
        await gamepieces.getAddress()
      ])
    ).wait();
    await (await jackpots.wire([await coin.getAddress(), await game.getAddress()])).wait();
    await (
      await bonds.wire(
        [
          await game.getAddress(),
          await vault.getAddress(),
          await coin.getAddress(),
          vrfCoordinatorAddress,
          await questModule.getAddress(),
          await trophies.getAddress()
        ],
        vrfSubId,
        vrfKeyHash
      )
    ).wait();
    await (await game.wireVrf(vrfCoordinatorAddress, vrfSubId, vrfKeyHash)).wait();
    await (
      await regularRenderer.wire([
        await game.getAddress(),
        await gamepieces.getAddress(),
        await trophies.getAddress()
      ])
    ).wait();
    await (await trophyRenderer.wire([await trophies.getAddress()])).wait();
    await (await trophySvg.wire([await trophies.getAddress()])).wait();

    if (!useMocks) {
      console.log("[deploy] Reminder: add bonds + game as consumers on your VRF subscription.");
    }
  }

  const addresses = {
    network: network.name,
    deployer: deployer.address,
    admin: adminAddress,
    steth: stethAddress,
    vrfCoordinator: vrfCoordinatorAddress,
    vrfKeyHash,
    bonds: await bonds.getAddress(),
    affiliate: await affiliate.getAddress(),
    coin: await coin.getAddress(),
    vault: await vault.getAddress(),
    questModule: await questModule.getAddress(),
    endgameModule: await endgameModule.getAddress(),
    jackpotModule: await jackpotModule.getAddress(),
    mintModule: await mintModule.getAddress(),
    bondModule: await bondModule.getAddress(),
    jackpots: await jackpots.getAddress(),
    icons: await icons.getAddress(),
    registry: await registry.getAddress(),
    trophyAssets: await assets.getAddress(),
    regularRenderer: await regularRenderer.getAddress(),
    trophyRenderer: await trophyRenderer.getAddress(),
    trophySvg: await trophySvg.getAddress(),
    trophies: await trophies.getAddress(),
    gamepieces: await gamepieces.getAddress(),
    game: await game.getAddress()
  };

  if (adminContract) {
    addresses.degenerusAdmin = await adminContract.getAddress();
    addresses.vrfSubId = (await adminContract.subscriptionId()).toString();
  } else {
    addresses.vrfSubId = vrfSubId.toString();
  }

  const outputPath = pickEnv("DEPLOY_OUTPUT");
  if (outputPath) {
    fs.writeFileSync(outputPath, JSON.stringify(addresses, null, 2));
    console.log(`[deploy] Wrote addresses to ${outputPath}`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
