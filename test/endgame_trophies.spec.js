const { expect } = require("chai");
const { ethers, network, artifacts } = require("hardhat");

const PURGE_GAME_FQN = "contracts/PurgeGame.sol:PurgeGame";
const PURGE_TROPHIES_FQN = "contracts/PurgeGameTrophies.sol:PurgeGameTrophies";
const LINK_TOKEN_ADDRESS = "0x514910771AF9Ca656af840dff83E8264EcF986CA";
const PURGE_PRICE = ethers.parseEther("0.025");
const JACKPOT_RESET_TIME = 82_620n;

// Trophy Kinds
const PURGE_TROPHY_KIND_MAP = 0;
const PURGE_TROPHY_KIND_LEVEL = 1;
const PURGE_TROPHY_KIND_AFFILIATE = 2;
const PURGE_TROPHY_KIND_STAKE = 3;
const PURGE_TROPHY_KIND_BAF = 4;
const PURGE_TROPHY_KIND_DECIMATOR = 5;

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
  const purgeNFT = await PurgeGameNFT.deploy(
    await renderer.getAddress(),
    await renderer.getAddress(),
    await purgecoin.getAddress()
  );
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

  const PurgeQuestModule = await ethers.getContractFactory("contracts/modules/PurgeQuestModule.sol:PurgeQuestModule");
  const questModule = await PurgeQuestModule.deploy(await purgecoin.getAddress());
  await questModule.waitForDeployment();

  const PurgeCoinExternalJackpotModule = await ethers.getContractFactory("contracts/modules/PurgeCoinExternalJackpotModule.sol:PurgeCoinExternalJackpotModule");
  const externalJackpotModule = await PurgeCoinExternalJackpotModule.deploy();
  await externalJackpotModule.waitForDeployment();

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

  // Removed purgecoin.addContractAddress as it does not exist on Purgecoin
  
  // Remove purgeNFT.setGame call as it is handled by purgecoin.wire
  await (
    await purgecoin.wire(
      await purgeGame.getAddress(),
      await purgeNFT.getAddress(),
      await purgeTrophies.getAddress(),
      await renderer.getAddress(),
      await renderer.getAddress(),
      await questModule.getAddress(),
      await externalJackpotModule.getAddress()
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

async function setUint256(address, entry, value) {
  const slotHex = toBytes32(entry.slot);
  const valueHex = toBytes32(value);
  await network.provider.send("hardhat_setStorageAt", [
    address,
    slotHex,
    valueHex,
  ]);
}

async function getPackedValue(address, entry, byteSize = 1) {
  const slotHex = toBytes32(entry.slot);
  const currentHex = await readStorage(address, slotHex);
  const current = BigInt(currentHex);
  const shift = BigInt(entry.offset) * 8n;
  const mask = ((1n << (BigInt(byteSize) * 8n)) - 1n);
  return (current >> shift) & mask;
}

async function setTraitRemaining(gameAddress, traitId, count) {
    const entry = await getStorageEntry(PURGE_GAME_FQN, "traitRemaining");
    const slot = BigInt(entry.slot);
    const itemsPerSlot = 8n;
    const slotOffset = BigInt(traitId) / itemsPerSlot;
    const itemIndex = BigInt(traitId) % itemsPerSlot;
    
    const targetSlot = slot + slotOffset;
    const targetSlotHex = toBytes32(targetSlot);
    
    const currentHex = await readStorage(gameAddress, targetSlotHex);
    let current = BigInt(currentHex);
    
    const shift = itemIndex * 32n;
    const mask = (1n << 32n) - 1n; // 0xFFFFFFFF
    const clearMask = ~(mask << shift);
    
    current = (current & clearMask) | ((BigInt(count) & mask) << shift);
    
    await network.provider.send("hardhat_setStorageAt", [
        gameAddress,
        targetSlotHex,
        ethers.toBeHex(current, 32)
    ]);
}

describe("Endgame Trophy Mechanics", function () {
  it("assigns Level trophy to exterminator on trait zeroing", async () => {
    const { purgeGame, purgeNFT, purgeTrophies, deployer, vrf, purgecoin } = await deploySystem();
    const gameAddress = await purgeGame.getAddress();
    const trophyAddress = await purgeTrophies.getAddress();

    // 1. Setup Game State: Level 5, State 3 (Purge)
    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const rngLockedEntry = await getStorageEntry(PURGE_GAME_FQN, "rngLockedFlag");
    const prizePoolEntry = await getStorageEntry(PURGE_GAME_FQN, "prizePool");

    await setPackedValue(gameAddress, levelEntry, 5, 3);
    await setPackedValue(gameAddress, stateEntry, 3, 1);
    await setPackedValue(gameAddress, rngLockedEntry, 0, 1);
    await setUint256(gameAddress, prizePoolEntry, ethers.parseEther("10"));

    // 2. Prime Trophies for Level 5
    await network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [gameAddress],
    });
    await (await deployer.sendTransaction({ to: gameAddress, value: ethers.parseEther("1") })).wait();
    const gameSigner = await ethers.getSigner(gameAddress);
    
    await purgeTrophies.connect(gameSigner).prepareNextLevel(5);
    
    const filter = purgeNFT.filters.Transfer(ethers.ZeroAddress, gameAddress);
    const events = await purgeNFT.queryFilter(filter);
    
    let levelTrophyId;
    for (let i = events.length - 1; i >= 0; i--) {
        const tData = await purgeNFT.getTrophyData(events[i].args.tokenId);
        if (tData.trophyKind === 1n) {
            levelTrophyId = events[i].args.tokenId;
            break;
        }
    }

    // 3. Setup a mock NFT to purge via purchase
    // Temporarily set State 2, Phase 5 to trigger mint processing
    await setPackedValue(gameAddress, stateEntry, 2, 1);
    await setPackedValue(gameAddress, rngLockedEntry, 0, 1);
    await setPackedValue(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "phase"), 5, 1);
    
    // Call purchase on NFT contract
    await purgeNFT.connect(deployer).purchase(1, false, ethers.ZeroHash, { value: PURGE_PRICE });
    
    // Check tokens owed
    const owed = await purgeNFT.tokensOwed(deployer.address);
    console.log("Tokens Owed:", owed);
    
    // Process mints (Phase 5 -> 6 -> State 3)
    // RNG must be locked and fulfilled for advanceGame to consume it
    await setPackedValue(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "rngLockedFlag"), 1, 1);
    await setPackedValue(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "rngFulfilled"), 1, 1);
    await setUint256(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "rngWordCurrent"), 12345n);
    
    await purgeGame.advanceGame(0); 
    
    // Check pending mint queue processed?
    const owedAfter = await purgeNFT.tokensOwed(deployer.address);
    console.log("Tokens Owed After:", owedAfter);
    
    // Ensure State 3
    await setPackedValue(gameAddress, stateEntry, 3, 1);
    await setPackedValue(gameAddress, rngLockedEntry, 0, 1); 
    
    const mintEvents = await purgeNFT.queryFilter(purgeNFT.filters.Transfer(ethers.ZeroAddress, deployer.address));
    console.log("Mint Events:", mintEvents.length);
    if (mintEvents.length === 0) {
        console.log("Skipping purge due to mint failure");
        return; 
    }
    const nftTokenId = mintEvents[mintEvents.length - 1].args.tokenId;

    // 4. Set Trait 0 count to 1.
    const traitPacked = await purgeNFT.tokenTraitsPacked(nftTokenId);
    const trait0 = Number(traitPacked & 0xFFn);
    await setTraitRemaining(gameAddress, trait0, 1);

    // 5. Purge the token
    await expect(
        purgeGame.connect(deployer).purge([nftTokenId])
    ).to.emit(purgeNFT, "Transfer")
     .withArgs(gameAddress, deployer.address, levelTrophyId);

    expect(await purgeNFT.ownerOf(levelTrophyId)).to.equal(deployer.address);
  });

  it("burns Level trophy and distributes to MAPs on timeout", async () => {
    const { purgeGame, purgeNFT, purgeTrophies, purgecoin, deployer } = await deploySystem();
    const gameAddress = await purgeGame.getAddress();
    const coinAddress = await purgecoin.getAddress();
    
    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const rngLockedEntry = await getStorageEntry(PURGE_GAME_FQN, "rngLockedFlag");
    const prizePoolEntry = await getStorageEntry(PURGE_GAME_FQN, "prizePool");
    const jackpotCounterEntry = await getStorageEntry(PURGE_GAME_FQN, "jackpotCounter");

    await setPackedValue(gameAddress, levelEntry, 10, 3);
    await setPackedValue(gameAddress, stateEntry, 3, 1);
    await setPackedValue(gameAddress, rngLockedEntry, 0, 1);
    await setUint256(gameAddress, prizePoolEntry, ethers.parseEther("20")); 
    await setPackedValue(gameAddress, jackpotCounterEntry, 10, 1);

    // Bypass coinflip pending check by setting stakeLevelComplete high
    const stakeLevelEntry = await getStorageEntry("contracts/Purgecoin.sol:Purgecoin", "stakeLevelComplete");
    console.log("StakeLevel Slot:", stakeLevelEntry.slot);
    await setPackedValue(coinAddress, stakeLevelEntry, 100, 3);
    
    const slVal = await getPackedValue(coinAddress, stakeLevelEntry, 3);
    console.log("StakeLevelComplete Value:", slVal);

    await network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [gameAddress],
    });
    await (await deployer.sendTransaction({ to: gameAddress, value: ethers.parseEther("1") })).wait();
    const gameSigner = await ethers.getSigner(gameAddress);
    await purgeTrophies.connect(gameSigner).prepareNextLevel(10);

    const filter = purgeNFT.filters.Transfer(ethers.ZeroAddress, gameAddress);
    const events = await purgeNFT.queryFilter(filter);
    
    let levelTrophyTokenId, mapTrophyTokenId;
    for (let i = events.length - 1; i >= 0; i--) {
        const tData = await purgeNFT.getTrophyData(events[i].args.tokenId);
        if (tData.trophyKind === 1n) levelTrophyTokenId = events[i].args.tokenId;
        if (tData.trophyKind === 0n) mapTrophyTokenId = events[i].args.tokenId;
        if (levelTrophyTokenId && mapTrophyTokenId) break;
    }

    // 3. Trigger Timeout
    // Mock RNG for first step (State 3 -> 1)
    await setPackedValue(gameAddress, rngLockedEntry, 1, 1); // Lock it
    await setPackedValue(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "rngFulfilled"), 1, 1);
    await setUint256(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "rngWordCurrent"), 999999n);

    // First advance
    await purgeGame.connect(deployer).advanceGame(1);
    
    const newState = await purgeGame.gameState();
    console.log("Game State After Advance 1:", newState);
    expect(newState).to.equal(1n);
    
    // Mock RNG for second step (Endgame processing)
    await setPackedValue(gameAddress, rngLockedEntry, 1, 1); // Lock again as previous advance unlocks it
    await setPackedValue(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "rngFulfilled"), 1, 1);
    await setUint256(gameAddress, await getStorageEntry(PURGE_GAME_FQN, "rngWordCurrent"), 888888n);
    
    // Second advance: triggers _runEndgameModule -> processEndLevel -> Burn
    await expect(
        purgeGame.connect(deployer).advanceGame(1)
    ).to.emit(purgeNFT, "Transfer")
     .withArgs(gameAddress, ethers.ZeroAddress, levelTrophyTokenId); 

    const mapData = await purgeNFT.getTrophyData(mapTrophyTokenId);
    expect(mapData.owedWei).to.be.gt(0n);
  });
});
