const { expect } = require("chai");
const { ethers, network, artifacts } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const LINK_TOKEN_ADDRESS = "0x514910771AF9Ca656af840dff83E8264EcF986CA";
const MILLION = 1_000_000n;
const PURGE_PRICE = ethers.parseEther("0.025");
const PURGE_GAME_FQN = "contracts/PurgeGame.sol:PurgeGame";
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

  const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
  const questModule = await QuestModule.deploy(await purgecoin.getAddress());
  await questModule.waitForDeployment();

  const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
  const externalJackpot = await ExternalJackpot.deploy();
  await externalJackpot.waitForDeployment();

  const MockStETH = await ethers.getContractFactory("MockStETH");
  const steth = await MockStETH.deploy();
  await steth.waitForDeployment();

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
    await link.getAddress(),
    await steth.getAddress()
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
    await renderer.getAddress(),
    await questModule.getAddress(),
    await externalJackpot.getAddress(),
    deployer.address
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
    endgameModule,
    jackpotModule,
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

async function createWallets(count, funder, fundAmount) {
  const provider = ethers.provider;
  const wallets = [];
  for (let i = 0; i < count; i += 1) {
    const wallet = ethers.Wallet.createRandom().connect(provider);
    wallets.push(wallet);
    await (await funder.sendTransaction({ to: wallet.address, value: fundAmount })).wait();
  }
  return wallets;
}

async function seedCoinflipPlayers(
  purgecoin,
  purgeGame,
  owner,
  wallets,
  { level, burnAmount, depositAmount }
) {
  const gameAddress = await purgeGame.getAddress();
  const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
  const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");

  await setPackedValue(gameAddress, levelEntry, level, 3);
  await setPackedValue(gameAddress, stateEntry, 2);

  const mintedAmount = burnAmount + depositAmount + 1n * MILLION;

  for (const wallet of wallets) {
    await (await purgecoin.connect(owner).transfer(wallet.address, mintedAmount)).wait();
    await (
      await purgecoin
        .connect(wallet)
        .luckyCoinBurn(burnAmount, depositAmount)
    ).wait();
  }
}

async function configureAdvanceScenario(
  purgeGame,
  {
    level,
    phase,
    state,
    rewardPoolWei,
    prizeWei,
    rngWord = 12345n,
  }
) {
  const gameAddress = await purgeGame.getAddress();
  const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
  const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
  const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
  const rewardPoolEntry = await getStorageEntry(
    PURGE_GAME_FQN,
    "rewardPool"
  );
  const prizeEntry = await getStorageEntry(PURGE_GAME_FQN, "currentPrizePool");
  const rngWordEntry = await getStorageEntry(PURGE_GAME_FQN, "rngWord");
  const rngTsEntry = await getStorageEntry(PURGE_GAME_FQN, "rngTs");
  const rngFulfilledEntry = await getStorageEntry(
    PURGE_GAME_FQN,
    "rngFulfilled"
  );
  const rngConsumedEntry = await getStorageEntry(
    PURGE_GAME_FQN,
    "rngConsumed"
  );
  const dailyIdxEntry = await getStorageEntry(PURGE_GAME_FQN, "dailyIdx");

  const now = BigInt(await time.latest());
  const day = now > JACKPOT_RESET_TIME ? (now - JACKPOT_RESET_TIME) / 86_400n : 0n;
  const prevDay = day === 0n ? 0n : day - 1n;

  await setPackedValue(gameAddress, levelEntry, level, 3);
  await setPackedValue(gameAddress, phaseEntry, phase);
  await setPackedValue(gameAddress, stateEntry, state);
  await setUint256(gameAddress, rewardPoolEntry, rewardPoolWei);
  await setUint256(gameAddress, prizeEntry, prizeWei);
  await setUint256(gameAddress, rngWordEntry, rngWord);
  await setPackedValue(gameAddress, rngTsEntry, now, 6);
  await setPackedValue(gameAddress, rngFulfilledEntry, 1);
  await setPackedValue(gameAddress, rngConsumedEntry, 0);
  await setPackedValue(gameAddress, dailyIdxEntry, prevDay, 6);
}

async function readPhase(purgeGame) {
  const entry = await getStorageEntry(PURGE_GAME_FQN, "phase");
  const value = await getPackedValue(await purgeGame.getAddress(), entry);
  return Number(value);
}

async function ensureCallerLuck(purgecoin, owner, caller, target) {
  const current = await purgecoin.playerLuckbox(caller.address);
  if (current >= target) return;
  const deficit = target - current + MILLION * 10n;
  await (await purgecoin.connect(owner).transfer(caller.address, deficit)).wait();
  await (await purgecoin.connect(caller).luckyCoinBurn(deficit, 0)).wait();
}

describe.skip("PurgeGame integration scaffold", function () {
  this.timeout(0);

  it("bootstraps the system into purchase phase with bounded gas", async () => {
    const { vrf, purgecoin, purgeGame, renderer, link, deployer } =
      await deploySystem();

    await advanceGameAndAssertGas(purgeGame, 1000);
    await fulfillLatestRandom(vrf, purgecoin, 777n);

    await advanceGameAndAssertGas(purgeGame, 1000);

    const gameAddress = await purgeGame.getAddress();
    const rngConsumedEntry = await getStorageEntry(
      PURGE_GAME_FQN,
      "rngConsumed"
    );
    while ((await getPackedValue(gameAddress, rngConsumedEntry, 1)) === 0n) {
      await advanceGameAndAssertGas(purgeGame, 1000);
    }

    expect(await purgeGame.gameState()).to.equal(2);
    expect(await purgeGame.level()).to.equal(1);

    await (await link.drip(await deployer.getAddress(), ethers.parseEther("10"))).wait();

    await expect(
      purgeGame.purchase(1, false, ethers.ZeroHash, {
        value: PURGE_PRICE,
      })
    ).to.emit(purgeGame, "TokenCreated");
  });

  it("allows map purchases during purge state", async () => {
    const { purgeGame, purgecoin, deployer } = await deploySystem();
    const gameAddress = await purgeGame.getAddress();
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
    const rngConsumedEntry = await getStorageEntry(
      PURGE_GAME_FQN,
      "rngConsumed"
    );

    await setPackedValue(gameAddress, stateEntry, 4);
    await setPackedValue(gameAddress, phaseEntry, 6);
    await setPackedValue(gameAddress, rngConsumedEntry, 1);

    const quantity = 4;
    const expectedWei = (PURGE_PRICE * BigInt(quantity * 25)) / 100n;

    const balanceBefore = await purgecoin.balanceOf(await deployer.getAddress());
    await expect(
      purgeGame.mintAndPurge(quantity, false, ethers.ZeroHash, {
        value: expectedWei,
      })
    ).to.not.be.reverted;
    const balanceAfter = await purgecoin.balanceOf(await deployer.getAddress());
    expect(balanceAfter).to.be.greaterThan(balanceBefore);
  });

  it.skip("simulates gameplay through level 200 with capped advanceGame gas", async () => {});
});

describe.skip("advanceGame stress scenarios", function () {
  this.timeout(0);

  it("keeps advanceGame below 16M gas during BAF jackpot scatter", async () => {
    const system = await deploySystem();
    const { purgecoin, purgeGame, deployer } = system;

    const wallets = await createWallets(
      5000,
      deployer,
      ethers.parseEther("0.1")
    );
    await seedCoinflipPlayers(purgecoin, purgeGame, deployer, wallets, {
      level: 20,
      burnAmount: 400n * MILLION,
      depositAmount: 300n * MILLION,
    });

    const runner = wallets[0];
    await ensureCallerLuck(purgecoin, deployer, runner, 50_000_000_000n);

    await configureAdvanceScenario(purgeGame, {
      level: 20,
      phase: 4,
      state: 3,
      rewardPoolWei: ethers.parseEther("500"),
      prizeWei: ethers.parseEther("200"),
      rngWord: 987654321n,
    });

    const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
    const gameAddress = await purgeGame.getAddress();

    const gasSamples = [];
    let iterations = 0;

    while ((await getPackedValue(gameAddress, phaseEntry)) === 4n) {
      const tx = await purgeGame.connect(runner).advanceGame(0);
      const receipt = await tx.wait();
      gasSamples.push(receipt.gasUsed);
      expect(receipt.gasUsed).to.be.lessThan(16_000_000n);
      iterations += 1;
      expect(iterations).to.be.lessThan(50);
    }

    const maxGas = gasSamples.reduce(
      (max, g) => (g > max ? g : max),
      0n
    );
    console.log("BAF advanceGame max gas:", maxGas.toString());
    expect(maxGas).to.be.lessThan(16_000_000n);
  });

  it("keeps advanceGame below 16M gas during Decimator payouts", async () => {
    const system = await deploySystem();
    const { purgecoin, purgeGame, deployer } = system;

    const wallets = await createWallets(
      5000,
      deployer,
      ethers.parseEther("0.1")
    );
    await seedCoinflipPlayers(purgecoin, purgeGame, deployer, wallets, {
      level: 35,
      burnAmount: 420n * MILLION,
      depositAmount: 320n * MILLION,
    });

    const runner = wallets[0];
    await ensureCallerLuck(purgecoin, deployer, runner, 80_000_000_000n);

    await configureAdvanceScenario(purgeGame, {
      level: 35,
      phase: 4,
      state: 3,
      rewardPoolWei: ethers.parseEther("350"),
      prizeWei: ethers.parseEther("120"),
      rngWord: 123123123n,
    });

    const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
    const gameAddress = await purgeGame.getAddress();

    const gasSamples = [];
    let iterations = 0;

    while ((await getPackedValue(gameAddress, phaseEntry)) === 4n) {
      const tx = await purgeGame.connect(runner).advanceGame(0);
      const receipt = await tx.wait();
      gasSamples.push(receipt.gasUsed);
      expect(receipt.gasUsed).to.be.lessThan(16_000_000n);
      iterations += 1;
      expect(iterations).to.be.lessThan(60);
    }

    const maxGas = gasSamples.reduce(
      (max, g) => (g > max ? g : max),
      0n
    );
    console.log("Decimator advanceGame max gas:", maxGas.toString());
    expect(maxGas).to.be.lessThan(16_000_000n);
  });

});

async function advanceGameAndAssertGas(purgeGame, cap) {
  const tx = await purgeGame.advanceGame(cap);
  const receipt = await tx.wait();
  expect(receipt.gasUsed).to.be.lessThan(16_000_000n);
  return receipt;
}

async function fulfillLatestRandom(
  vrf,
  purgecoin,
  randomWord = 123456789n
) {
  const requestId = await vrf.lastRequestId();
  expect(requestId).to.not.equal(0n, "VRF request not issued");
  await vrf.fulfill(await purgecoin.getAddress(), requestId, randomWord);
}
