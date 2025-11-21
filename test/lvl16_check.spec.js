const { expect } = require("chai");
const { ethers, network, artifacts } = require("hardhat");

const PURGE_GAME_FQN = "contracts/PurgeGame.sol:PurgeGame";
const LINK_TOKEN_ADDRESS = "0x514910771AF9Ca656af840dff83E8264EcF986CA";
const PURGE_PRICE = ethers.parseEther("0.025");
const JACKPOT_RESET_TIME = 82_620n;

const layoutCache = new Map();

async function deployLinkMock() {
  const linkFactory = await ethers.getContractFactory("MockLinkToken");
  const temp = await linkFactory.deploy();
  await temp.waitForDeployment();

  const runtimeCode = await ethers.provider.getCode(await temp.getAddress());
  await network.provider.send("hardhat_setCode", [
    LINK_TOKEN_ADDRESS,
    runtimeCode,
  ]);

  return ethers.getContractAt("MockLinkToken", LINK_TOKEN_ADDRESS);
}

async function deploySystem() {
  const [deployer] = await ethers.getSigners();

  const link = await deployLinkMock();

  const MockRenderer = await ethers.getContractFactory("MockRenderer");
  const renderer = await MockRenderer.deploy();
  await renderer.waitForDeployment();

  const MockVRF = await ethers.getContractFactory("MockVRFCoordinator");
  const vrf = await MockVRF.deploy(ethers.parseEther("500"));
  await vrf.waitForDeployment();

  const Purgecoin = await ethers.getContractFactory("Purgecoin");
  const purgecoin = await Purgecoin.deploy();
  await purgecoin.waitForDeployment();

  const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
  const purgeNFT = await PurgeGameNFT.deploy(await deployer.getAddress());
  await purgeNFT.waitForDeployment();

  const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
  const purgeTrophies = await PurgeGameTrophies.deploy(await purgeNFT.getAddress());
  await purgeTrophies.waitForDeployment();

  const PurgeGameEndgameModule = await ethers.getContractFactory("PurgeGameEndgameModule");
  const endgameModule = await PurgeGameEndgameModule.deploy();
  await endgameModule.waitForDeployment();

  const PurgeGameJackpotModule = await ethers.getContractFactory("PurgeGameJackpotModule");
  const jackpotModule = await PurgeGameJackpotModule.deploy();
  await jackpotModule.waitForDeployment();

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
    LINK_TOKEN_ADDRESS
  );
  await purgeGame.waitForDeployment();

  await (await purgecoin.addContractAddress(await purgeGame.getAddress())).wait();
  await (
    await purgeNFT.setGame(
      await purgeGame.getAddress(),
      await renderer.getAddress()
    )
  ).wait();

  await (
    await purgecoin.wire(
      await purgeGame.getAddress(),
      await purgeNFT.getAddress(),
      await purgeTrophies.getAddress(),
      await renderer.getAddress(),
      await renderer.getAddress()
    )
  ).wait();

  return {
    link,
    renderer,
    vrf,
    purgecoin,
    purgeGame,
    purgeNFT,
    purgeTrophies,
    deployer,
  };
}

function toBytes32(value) {
  return ethers.toBeHex(BigInt(value), 32);
}

async function readStorage(address, slotHex) {
  return network.provider.send("eth_getStorageAt", [address, slotHex]);
}

async function fetchLayout(fqn) {
  if (layoutCache.has(fqn)) return layoutCache.get(fqn);
  const buildInfo = await artifacts.getBuildInfo(fqn);
  if (!buildInfo) throw new Error(`Build info missing for ${fqn}`);
  const [source, name] = fqn.split(":");
  const layout = buildInfo.output.contracts[source][name].storageLayout;
  layoutCache.set(fqn, layout);
  return layout;
}

async function getStorageEntry(fqn, label) {
  const layout = await fetchLayout(fqn);
  const entry = layout.storage.find((item) => item.label === label);
  if (!entry) throw new Error(`Storage label ${label} not found in ${fqn}`);
  return entry;
}

async function setPackedValue(address, entry, value, byteSize = 1) {
  const slotHex = toBytes32(entry.slot);
  const currentHex = await readStorage(address, slotHex);
  let current = BigInt(currentHex);
  const shift = BigInt(entry.offset) * 8n;
  const mask = ((1n << (BigInt(byteSize) * 8n)) - 1n) << shift;
  current = (current & ~mask) | ((BigInt(value) << shift) & mask);
  const newHex = ethers.toBeHex(current, 32);
  await network.provider.send("hardhat_setStorageAt", [
    address,
    slotHex,
    newHex,
  ]);
}

describe("Level 16 Restrictions", function () {
  it("should prevent normal NFT purchase at level 16", async () => {
    const { purgeGame, deployer } = await deploySystem();
    const gameAddress = await purgeGame.getAddress();
    
    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const rngLockedEntry = await getStorageEntry(PURGE_GAME_FQN, "rngLockedFlag");

    // Set game to Level 16, State 2 (Purchase)
    await setPackedValue(gameAddress, levelEntry, 16, 3);
    await setPackedValue(gameAddress, stateEntry, 2, 1);
    await setPackedValue(gameAddress, rngLockedEntry, 0, 1);

    // Attempt purchase - should fail
    await expect(
      purgeGame.connect(deployer).purchase(1, false, ethers.ZeroHash, { value: PURGE_PRICE })
    ).to.be.revertedWithCustomError(purgeGame, "NotTimeYet");
  });

  it("should allow MAP purchase at level 16", async () => {
    const { purgeGame, deployer } = await deploySystem();
    const gameAddress = await purgeGame.getAddress();
    
    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const rngLockedEntry = await getStorageEntry(PURGE_GAME_FQN, "rngLockedFlag");
    const coinPriceEntry = await getStorageEntry(PURGE_GAME_FQN, "priceCoin"); // need priceCoin for calculation

    // Set game to Level 16, State 2 (Purchase)
    await setPackedValue(gameAddress, levelEntry, 16, 3);
    await setPackedValue(gameAddress, stateEntry, 2, 1);
    await setPackedValue(gameAddress, rngLockedEntry, 0, 1);
    
    // Need to make sure early purge percent is enough if using coin? 
    // Or if paying in ETH, we just need state 2.
    // MAPs require: min quantity based on level.
    // Level 16 % 100 = 16. minQuantity is 4 (from PurgeGameNFT._mapMinimumQuantity).
    
    const quantity = 4;
    // Calculate cost:
    // cost = quantity * 25 * price / 100?
    // mintAndPurge logic:
    // scaledQty = quantity * 25
    // expectedWei = (price * scaledQty) / 100
    // = price * quantity * 25 / 100 = price * quantity / 4
    const expectedWei = (PURGE_PRICE * BigInt(quantity)) / 4n;

    await expect(
      purgeGame.connect(deployer).mintAndPurge(quantity, false, ethers.ZeroHash, { value: expectedWei })
    ).to.not.be.reverted;
  });
});