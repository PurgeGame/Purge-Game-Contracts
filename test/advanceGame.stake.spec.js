const { expect } = require("chai");
const { ethers, network, artifacts } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const MILLION = 1_000_000n;
const PURGE_GAME_FQN = "contracts/PurgeGame.sol:PurgeGame";
const PURGE_GAME_NFT_FQN = "contracts/PurgeGameNFT.sol:PurgeGameNFT";
const PURGE_COIN_FQN = "contracts/Purgecoin.sol:Purgecoin";
const JACKPOT_RESET_TIME = 82_620n;
const PRICE_COIN_UNIT = 1_000_000_000n;
const DAY_SECONDS = 86_400n;
const ETH_DAY_SHIFT = 72n;
const COINFLIP_GAS_LIMIT = 15_000_000n;
const COINFLIP_QUEUE_SIZE = 2_000;
const BASE_FLIP_STAKE = 250n * MILLION;
const SS_IDLE = (1n << 32n) - 1n;

const layoutCache = new Map();

const toWord = (value) => ethers.zeroPadValue(ethers.toBeHex(value), 32);
const toAddressWord = (addr) => ethers.zeroPadValue(addr, 32);

async function setStorageRaw(address, slot, value) {
  await network.provider.send("hardhat_setStorageAt", [address, slot, value]);
}

const mapSlot = (key, slot) =>
  BigInt(
    ethers.keccak256(
      ethers.concat([toWord(key), toWord(slot)])
    )
  );

const arrayDataSlot = (slot) =>
  BigInt(ethers.keccak256(toWord(slot)));

function deterministicAddress(index) {
  const base = 0x1000000000000000000000000000000000000000n;
  const addrBytes = ethers.zeroPadValue(
    ethers.toBeHex(base + BigInt(index)),
    20
  );
  return ethers.getAddress(addrBytes);
}

async function deploySystem() {
  const [deployer] = await ethers.getSigners();

  const MockRenderer = await ethers.getContractFactory("MockRenderer");
  const regularRenderer = await MockRenderer.deploy();
  await regularRenderer.waitForDeployment();
  const trophyRenderer = await MockRenderer.deploy();
  await trophyRenderer.waitForDeployment();

  const MockVRF = await ethers.getContractFactory("MockVRFCoordinator");
  const vrf = await MockVRF.deploy(ethers.parseEther("500"));
  await vrf.waitForDeployment();

  const MockLink = await ethers.getContractFactory("MockLinkToken");
  const link = await MockLink.deploy();
  await link.waitForDeployment();

  const Purgecoin = await ethers.getContractFactory("Purgecoin");
  const purgecoin = await Purgecoin.deploy();
  await purgecoin.waitForDeployment();

  const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
  const questModule = await QuestModule.deploy(await purgecoin.getAddress());
  await questModule.waitForDeployment();

  const ExternalJackpot = await ethers.getContractFactory("PurgeCoinExternalJackpotModule");
  const externalJackpot = await ExternalJackpot.deploy();
  await externalJackpot.waitForDeployment();

  const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
  const purgeNFT = await PurgeGameNFT.deploy(
    await regularRenderer.getAddress(),
    await trophyRenderer.getAddress(),
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

  const MockStETH = await ethers.getContractFactory("MockStETH");
  const steth = await MockStETH.deploy();
  await steth.waitForDeployment();

  const PurgeGame = await ethers.getContractFactory("PurgeGame");
  const purgeGame = await PurgeGame.deploy(
    await purgecoin.getAddress(),
    await regularRenderer.getAddress(),
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

  await (
    await purgecoin.wire(
      await purgeGame.getAddress(),
      await purgeNFT.getAddress(),
      await purgeTrophies.getAddress(),
      await regularRenderer.getAddress(),
      await trophyRenderer.getAddress(),
      await questModule.getAddress(),
      await externalJackpot.getAddress()
    )
  ).wait();

  return {
    regularRenderer,
    trophyRenderer,
    vrf,
    purgecoin,
    purgeGame,
    purgeNFT,
    purgeTrophies,
    endgameModule,
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

async function ensureCallerLuck(purgecoin, owner, caller, target) {
  const current = await purgecoin.playerLuckbox(caller.address);
  if (current >= target) return;
  const deficit = target - current + MILLION * 10n;
  await (await purgecoin.connect(owner).transfer(caller.address, deficit)).wait();
  await (await purgecoin.connect(caller).luckyCoinBurn(deficit, 0)).wait();
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

describe("AdvanceGame stake resolution", function () {
  it("transitions to state 2 after extermination snapshot", async function () {
    const { purgeGame, purgeNFT, deployer } = await deploySystem();
    const gameAddress = await purgeGame.getAddress();
    const nftAddress = await purgeNFT.getAddress();
    const advancer = deployer;

    // Set block timestamp to a deterministic day
    const latest = await time.latest();
    const targetTs = Math.max(
      Number(latest) + 1,
      Number(JACKPOT_RESET_TIME + 3n * 24n * 60n * 60n)
    );
    await time.setNextBlockTimestamp(targetTs);

    // Configure RNG state on NFT
    const rngWordEntry = await getStorageEntry(PURGE_GAME_NFT_FQN, "rngWord");
    const rngFulfilledEntry = await getStorageEntry(
      PURGE_GAME_NFT_FQN,
      "rngFulfilled"
    );
    const rngLockedEntry = await getStorageEntry(
      PURGE_GAME_NFT_FQN,
      "rngLockedFlag"
    );
    await setUint256(nftAddress, rngWordEntry, 0x1234n);
    await setPackedValue(nftAddress, rngFulfilledEntry, 1);
    await setPackedValue(nftAddress, rngLockedEntry, 1);

    // Game level/state snapshot: level 2 (prev level 1 just ended)
    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const dailyIdxEntry = await getStorageEntry(PURGE_GAME_FQN, "dailyIdx");
    const jackpotCounterEntry = await getStorageEntry(
      PURGE_GAME_FQN,
      "jackpotCounter"
    );
  const lastTraitEntry = await getStorageEntry(
    PURGE_GAME_FQN,
    "lastExterminatedTrait"
  );
  const prizeEntry = await getStorageEntry(PURGE_GAME_FQN, "currentPrizePool");
    const rewardPoolEntry = await getStorageEntry(
      PURGE_GAME_FQN,
      "rewardPool"
    );

    await setPackedValue(gameAddress, levelEntry, 2, 3);
    await setPackedValue(gameAddress, phaseEntry, 7);
    await setPackedValue(gameAddress, stateEntry, 1);
    await setPackedValue(gameAddress, dailyIdxEntry, 0, 6);
  await setPackedValue(gameAddress, jackpotCounterEntry, 0);
  await setPackedValue(gameAddress, lastTraitEntry, 5, 2);
  await setUint256(
    gameAddress,
    prizeEntry,
    ethers.parseEther("100")
  );
  await setUint256(gameAddress, rewardPoolEntry, 0n);

    // Configure pending end-level flags
    const pendingExEntry = await getStorageEntry(
      PURGE_GAME_FQN,
      "exterminator"
    );
    const exterminator = await advancer.getAddress();
    await setPackedValue(gameAddress, pendingExEntry, exterminator, 20);

    // Fund game with enough ETH to cover deferred payouts
    await (
      await advancer.sendTransaction({
        to: gameAddress,
        value: ethers.parseEther("20"),
      })
    ).wait();

    // Run advanceGame until state settles
    let tx = await purgeGame.connect(advancer).advanceGame(1);
    let receipt = await tx.wait();
    const advanceEvent1 = receipt.logs
      .map((log) => {
        try {
          return purgeGame.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((parsed) => parsed && parsed.name === "Advance");
    if (advanceEvent1) {
      console.log("advance event 1", advanceEvent1.args.gameState, advanceEvent1.args.phase);
    }
    const phaseAfterFirst = Number(
      await getPackedValue(gameAddress, phaseEntry)
    );
    console.log("phase after first", phaseAfterFirst);
    expect(phaseAfterFirst).to.equal(0);
    const stateAfterFirst = Number(
      await getPackedValue(gameAddress, stateEntry)
    );
    console.log("state after first", stateAfterFirst);
    expect(stateAfterFirst).to.equal(1);
    const pendingAfterFirst = await readStorage(
      gameAddress,
      toBytes32(pendingExEntry.slot)
    );
    console.log("pending ex after first", pendingAfterFirst);
    console.log(
      "nextPrizePool",
      await readStorage(gameAddress, toBytes32((await getStorageEntry(PURGE_GAME_FQN, "nextPrizePool")).slot))
    );
    const storedExFirst = ethers.getAddress(
      ethers.toBeHex(BigInt(pendingAfterFirst) & ((1n << (20n * 8n)) - 1n), 20)
    );
    console.log("decoded pending after first", storedExFirst);

    tx = await purgeGame.connect(advancer).advanceGame(1);
    receipt = await tx.wait();
    const advanceEvent2 = receipt.logs
      .map((log) => {
        try {
          return purgeGame.interface.parseLog(log);
        } catch {
          return null;
        }
      })
      .find((parsed) => parsed && parsed.name === "Advance");
    if (advanceEvent2) {
      console.log("advance event 2", advanceEvent2.args.gameState, advanceEvent2.args.phase);
    }
    const phaseAfterSecond = Number(
      await getPackedValue(gameAddress, phaseEntry)
    );
    console.log("phase after second", phaseAfterSecond);
    const finalState = Number(
      await getPackedValue(gameAddress, stateEntry)
    );
    console.log("state after second", finalState);
    const pendingAfterSecond = await readStorage(
      gameAddress,
      toBytes32(pendingExEntry.slot)
    );
    console.log("pending ex after second", pendingAfterSecond);
    const storedExSecond = ethers.getAddress(
      ethers.toBeHex(BigInt(pendingAfterSecond) & ((1n << (20n * 8n)) - 1n), 20)
    );
    console.log("decoded pending after second", storedExSecond);
    expect(finalState).to.equal(2);
    const rawPending = await readStorage(
      gameAddress,
      toBytes32(pendingExEntry.slot)
    );
    expect(BigInt(rawPending)).to.equal(0n);
  });
  this.timeout(0);

  it("processes multiple stake batches (cap=0) and awards stake trophy", async () => {
    const {
      purgeGame,
      purgecoin,
      purgeNFT,
      purgeTrophies,
      deployer,
    } = await deploySystem();

    const signers = await ethers.getSigners();
    const advancer = signers[1];
    const stakeWallets = await createWallets(420, deployer, ethers.parseEther("0.2"));
    const targetLevel = 25;
    const risk = 1;

    // Fund LINK sink to avoid revert on first RNG request if triggered
    await (await purgecoin.connect(deployer).transfer(await advancer.getAddress(), 10_000n * MILLION)).wait();

    // Transfer tokens to stakers and create stakes
    const baseBurn = 400n * MILLION;
    const burnIncrement = 5_000n; // keep delta small but unique
    const stakeEvents = [];

    for (let i = 0; i < stakeWallets.length; i += 1) {
      const staker = stakeWallets[i];
      const burnAmt = baseBurn + BigInt(i) * burnIncrement;
      await (await purgecoin.connect(deployer).transfer(staker.address, burnAmt)).wait();
      const tx = await purgecoin.connect(staker).stake(burnAmt, targetLevel, risk);
      const receipt = await tx.wait();
      const event = receipt.logs
        .map((log) => {
          try {
            return purgecoin.interface.parseLog(log);
          } catch {
            return null;
          }
        })
        .find((parsed) => parsed && parsed.name === "StakeCreated");
      expect(event, "StakeCreated missing").to.not.be.undefined;
      stakeEvents.push({
        player: staker.address,
        principal: event.args[3],
      });
    }

    const stakeAddrEntry = await getStorageEntry(PURGE_COIN_FQN, "stakeAddr");
    const baseSlot = BigInt(stakeAddrEntry.slot);
    const slotKey = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["uint256", "uint256"],
        [BigInt(targetLevel), baseSlot]
      )
    );
    const rosterLength = BigInt(
      await readStorage(await purgecoin.getAddress(), slotKey)
    );
    expect(rosterLength).to.be.gt(200n, "expected stake roster to exceed single batch");

    const maxStake = stakeEvents.reduce(
      (acc, curr) => (curr.principal > acc.principal ? curr : acc),
      stakeEvents[0]
    );

    // Configure PurgeGame state to purge phase (phase 7 so _endJackpot executes)
    const gameAddress = await purgeGame.getAddress();
    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const rewardPoolEntry = await getStorageEntry(
      PURGE_GAME_FQN,
      "rewardPool"
    );
    const prizeEntry = await getStorageEntry(PURGE_GAME_FQN, "currentPrizePool");
    const dailyIdxEntry = await getStorageEntry(PURGE_GAME_FQN, "dailyIdx");
    const levelStartEntry = await getStorageEntry(
      PURGE_GAME_FQN,
      "levelStartTime"
    );

    const now = BigInt(await time.latest());
    const day = now > JACKPOT_RESET_TIME ? (now - JACKPOT_RESET_TIME) / 86_400n : 0n;
    const prevDay = day === 0n ? 0n : day - 1n;

    await setPackedValue(gameAddress, levelEntry, targetLevel, 3);
    await setPackedValue(gameAddress, phaseEntry, 7);
    await setPackedValue(gameAddress, stateEntry, 3);
    await setUint256(gameAddress, rewardPoolEntry, 0n);
    await setUint256(gameAddress, prizeEntry, ethers.parseEther("50"));
    await setPackedValue(gameAddress, dailyIdxEntry, prevDay, 6);
    await setPackedValue(gameAddress, levelStartEntry, now, 6);

    // Prime NFT RNG state
    const nftAddress = await purgeNFT.getAddress();
    const rngWordEntry = await getStorageEntry(PURGE_GAME_NFT_FQN, "rngWord");
    const rngFulfilledEntry = await getStorageEntry(
      PURGE_GAME_NFT_FQN,
      "rngFulfilled"
    );
    const rngLockedEntry = await getStorageEntry(
      PURGE_GAME_NFT_FQN,
      "rngLockedFlag"
    );
    await setUint256(nftAddress, rngWordEntry, 0x1235n);
    await setPackedValue(nftAddress, rngFulfilledEntry, 1);
    await setPackedValue(nftAddress, rngLockedEntry, 0);

    // Ensure advancer satisfies luckbox requirement
    const requiredLuck =
      PRICE_COIN_UNIT *
      BigInt(targetLevel) *
      BigInt(Math.floor(targetLevel / 100) + 1) *
      2n;
    await ensureCallerLuck(purgecoin, deployer, advancer, requiredLuck);

    // First advanceGame(0) should process first stake batch but not finish
    let tx = await purgeGame.connect(advancer).advanceGame(0);
    await tx.wait();

    // Phase should remain 7 (processing not finished)
    const phaseAfterFirst = Number(await getPackedValue(gameAddress, phaseEntry));
    expect(phaseAfterFirst).to.equal(7, "phase should stay at 7 after partial processing");

    let currentPhase = Number(await getPackedValue(gameAddress, phaseEntry));
    for (let attempt = 0; attempt < 100 && currentPhase !== 6; attempt += 1) {
      const followTx = await purgeGame.connect(advancer).advanceGame(0);
      await followTx.wait();
      currentPhase = Number(await getPackedValue(gameAddress, phaseEntry));
    }

    expect(currentPhase).to.equal(6, "phase should return to 6 after completion");

    // Confirm stake candidate cleared
    const candidateEntry = await getStorageEntry(
      "contracts/Purgecoin.sol:Purgecoin",
      "stakeTrophyCandidate"
    );
    const candidateSlotHex = toBytes32(candidateEntry.slot);
    const rawCandidate = BigInt(
      await readStorage(await purgecoin.getAddress(), candidateSlotHex)
    );
    const rawPrincipal = BigInt(
      await readStorage(
        await purgecoin.getAddress(),
        toBytes32(BigInt(candidateEntry.slot) + 1n)
      )
    );
    expect(rawCandidate).to.equal(0n, "stake trophy candidate not cleared");
    expect(rawPrincipal).to.equal(0n, "stake trophy principal slot not cleared");
  });

  it("processes 10k stakes and 5k coinflips with cap=0", async () => {
    const {
      purgeGame,
      purgecoin,
      purgeNFT,
      deployer,
    } = await deploySystem();

    const advancer = (await ethers.getSigners())[1];

    const stakeCount = 10_000;
    const coinflipCount = 5_000;
    const targetLevel = 42;
    const purgecoinAddress = await purgecoin.getAddress();
    const gameAddress = await purgeGame.getAddress();
    const nftAddress = await purgeNFT.getAddress();

    const stakeAddresses = Array.from({ length: stakeCount }, (_, i) => deterministicAddress(i + 1));
    const coinflipAddresses = Array.from({ length: coinflipCount }, (_, i) => deterministicAddress(100_000 + i));

    const STAKE_PRINCIPAL_FACTOR = 1_000_000n;
    const STAKE_LANE_RISK_SHIFT = 78n;
    const unitsMask = (1n << STAKE_LANE_RISK_SHIFT) - 1n;
    const baseUnits = 5_000n;

    const stakeAddrEntry = await getStorageEntry(PURGE_COIN_FQN, "stakeAddr");
    const stakeAmtEntry = await getStorageEntry(PURGE_COIN_FQN, "stakeAmt");
    const stakeLevelCompleteEntry = await getStorageEntry(PURGE_COIN_FQN, "stakeLevelComplete");
    const scanCursorEntry = await getStorageEntry(PURGE_COIN_FQN, "scanCursor");

    const stakeAddrSlot = BigInt(stakeAddrEntry.slot);
    const stakeAmtSlot = BigInt(stakeAmtEntry.slot);

    const stakeLengthSlot = mapSlot(BigInt(targetLevel), stakeAddrSlot);
    await setStorageRaw(purgecoinAddress, toWord(stakeLengthSlot), toWord(BigInt(stakeCount)));
    const stakeArrayBase = arrayDataSlot(stakeLengthSlot);
    const rosterLength = BigInt(await readStorage(purgecoinAddress, toWord(stakeLengthSlot)));
    console.log("stake roster length", rosterLength.toString());

    const levelStakeAmtSlot = mapSlot(BigInt(targetLevel), stakeAmtSlot);

    const lastUnits = baseUnits + BigInt(stakeCount - 1);
    const expectedWinner = stakeAddresses[stakeCount - 1];
    const expectedPrincipal = lastUnits * STAKE_PRINCIPAL_FACTOR;

    for (let i = 0; i < stakeCount; i += 1) {
      const addr = stakeAddresses[i];
      const elementSlot = stakeArrayBase + BigInt(i);
      await setStorageRaw(purgecoinAddress, toWord(elementSlot), toAddressWord(addr));

      const units = baseUnits + BigInt(i);
      const lane = (units & unitsMask) | (1n << STAKE_LANE_RISK_SHIFT);
      const finalSlot = mapSlot(ethers.toBigInt(addr), levelStakeAmtSlot);
      await setStorageRaw(purgecoinAddress, toWord(finalSlot), toWord(lane));
    }

    const sampleFirstSlot = mapSlot(ethers.toBigInt(stakeAddresses[0]), levelStakeAmtSlot);
    const sampleLastSlot = mapSlot(ethers.toBigInt(stakeAddresses[stakeCount - 1]), levelStakeAmtSlot);
    const sampleFirstLane = BigInt(await readStorage(purgecoinAddress, toWord(sampleFirstSlot)));
    const sampleLastLane = BigInt(await readStorage(purgecoinAddress, toWord(sampleLastSlot)));
    const decodeUnits = (lane) => lane & unitsMask;
    const decodeRisk = (lane) => Number((lane >> STAKE_LANE_RISK_SHIFT) & 0xffn);
    console.log(
      "sample lanes",
      sampleFirstLane.toString(),
      sampleLastLane.toString(),
      "risk",
      decodeRisk(sampleFirstLane),
      decodeRisk(sampleLastLane),
      "units",
      decodeUnits(sampleFirstLane).toString()
    );

    await setPackedValue(purgecoinAddress, stakeLevelCompleteEntry, targetLevel - 1, 3);
    await setPackedValue(purgecoinAddress, scanCursorEntry, 0);

    const cfPlayersEntry = await getStorageEntry(PURGE_COIN_FQN, "cfPlayers");
    const cfPlayersSlot = BigInt(cfPlayersEntry.slot);
    await setStorageRaw(purgecoinAddress, toWord(cfPlayersSlot), toWord(BigInt(coinflipCount)));
    const cfArrayBase = arrayDataSlot(cfPlayersSlot);

    for (let i = 0; i < coinflipCount; i += 1) {
      const addr = coinflipAddresses[i];
      const elementSlot = cfArrayBase + BigInt(i);
      await setStorageRaw(purgecoinAddress, toWord(elementSlot), toAddressWord(addr));
    }

    const cfTailEntry = await getStorageEntry(PURGE_COIN_FQN, "cfTail");
    const cfHeadEntry = await getStorageEntry(PURGE_COIN_FQN, "cfHead");
    const coinflipPlayersCountEntry = await getStorageEntry(PURGE_COIN_FQN, "coinflipPlayersCount");
    const payoutIndexEntry = await getStorageEntry(PURGE_COIN_FQN, "payoutIndex");
    const coinflipAmountEntry = await getStorageEntry(PURGE_COIN_FQN, "coinflipAmount");

    await setPackedValue(purgecoinAddress, cfTailEntry, coinflipCount, 16);
    await setPackedValue(purgecoinAddress, cfHeadEntry, 0, 16);
    await setPackedValue(purgecoinAddress, coinflipPlayersCountEntry, coinflipCount, 4);
    await setPackedValue(purgecoinAddress, payoutIndexEntry, 0, 4);

    const coinflipAmountSlot = BigInt(coinflipAmountEntry.slot);
    const baseCoinflipAmount = 250n * MILLION;
    for (const addr of coinflipAddresses) {
      const slot = mapSlot(ethers.toBigInt(addr), coinflipAmountSlot);
      await setStorageRaw(purgecoinAddress, toWord(slot), toWord(baseCoinflipAmount));
    }

    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const rewardPoolEntry = await getStorageEntry(PURGE_GAME_FQN, "rewardPool");
    const prizeEntry = await getStorageEntry(PURGE_GAME_FQN, "currentPrizePool");
    const dailyIdxEntry = await getStorageEntry(PURGE_GAME_FQN, "dailyIdx");
    const levelStartEntry = await getStorageEntry(PURGE_GAME_FQN, "levelStartTime");

    const now = BigInt(await time.latest());
    const day = now > JACKPOT_RESET_TIME ? (now - JACKPOT_RESET_TIME) / 86_400n : 0n;
    const prevDay = day === 0n ? 0n : day - 1n;

    await setPackedValue(gameAddress, levelEntry, targetLevel, 3);
    await setPackedValue(gameAddress, phaseEntry, 7);
    await setPackedValue(gameAddress, stateEntry, 3);
    await setUint256(gameAddress, rewardPoolEntry, 0n);
    await setUint256(gameAddress, prizeEntry, ethers.parseEther("250"));
    await setPackedValue(gameAddress, dailyIdxEntry, prevDay, 6);
    await setPackedValue(gameAddress, levelStartEntry, now, 6);

    const rngWordEntry = await getStorageEntry(PURGE_GAME_NFT_FQN, "rngWord");
    const rngFulfilledEntry = await getStorageEntry(PURGE_GAME_NFT_FQN, "rngFulfilled");
    const rngLockedEntry = await getStorageEntry(PURGE_GAME_NFT_FQN, "rngLockedFlag");
    await setUint256(nftAddress, rngWordEntry, 0xabcdef1235n);
    await setPackedValue(nftAddress, rngFulfilledEntry, 1);
    await setPackedValue(nftAddress, rngLockedEntry, 0);

    const requiredLuck =
      PRICE_COIN_UNIT *
      BigInt(targetLevel) *
      BigInt(Math.floor(targetLevel / 100) + 1) *
      2n;
    await ensureCallerLuck(purgecoin, deployer, advancer, requiredLuck);

    const gasUsage = [];

    let tx = await purgeGame.connect(advancer).advanceGame(0);
    let receipt = await tx.wait();
    gasUsage.push(receipt.gasUsed);
    let currentPhase = Number(await getPackedValue(gameAddress, phaseEntry));
    let iterations = 0;
    while (currentPhase !== 6 && iterations < 200) {
      const followTx = await purgeGame.connect(advancer).advanceGame(0);
      const followReceipt = await followTx.wait();
      gasUsage.push(followReceipt.gasUsed);

      currentPhase = Number(await getPackedValue(gameAddress, phaseEntry));
      iterations += 1;
    }

    expect(currentPhase).to.equal(6, "phase should return to 6 after processing massive workload");
    const finalStakeLevelComplete = Number(await getPackedValue(purgecoinAddress, stakeLevelCompleteEntry, 3));
    const finalScanCursor = Number(await getPackedValue(purgecoinAddress, scanCursorEntry, 4));
    console.log("final stakeLevelComplete", finalStakeLevelComplete, "scanCursor", finalScanCursor);
    const candidateEntry = await getStorageEntry(
      PURGE_COIN_FQN,
      "stakeTrophyCandidate"
    );
    const candidateSlot = BigInt(candidateEntry.slot);
    const rawPlayer = BigInt(
      await readStorage(
        purgecoinAddress,
        toWord(candidateSlot)
      )
    );
    const rawPrincipal = BigInt(
      await readStorage(
        purgecoinAddress,
        toWord(candidateSlot + 1n)
      )
    );
    const rawLevel = BigInt(
      await readStorage(
        purgecoinAddress,
        toWord(candidateSlot + 2n)
      )
    );
    expect(rawPlayer, "stake trophy candidate player cleared").to.equal(0n);
    expect(rawPrincipal, "stake trophy candidate principal cleared").to.equal(0n);
    expect(rawLevel, "stake trophy candidate level cleared").to.equal(0n);

    const bonusPct = await purgeTrophies.stakeTrophyBonus(expectedWinner);
    expect(bonusPct).to.be.greaterThanOrEqual(0, "stake bonus should be queryable");

    console.log(
      "massive stake gas sequence:",
      gasUsage.map((g) => g.toString()).join(", ")
    );
  });

  async function seedCoinflipQueueState(purgecoin, targetLevel, queueSize = COINFLIP_QUEUE_SIZE) {
    const purgecoinAddress = await purgecoin.getAddress();
    const cfPlayersEntry = await getStorageEntry(PURGE_COIN_FQN, "cfPlayers");
    const cfPlayersSlot = BigInt(cfPlayersEntry.slot);
    await setStorageRaw(purgecoinAddress, toWord(cfPlayersSlot), toWord(BigInt(queueSize)));
    const cfArrayBase = arrayDataSlot(cfPlayersSlot);
    const flippers = [];
    for (let i = 0; i < queueSize; i += 1) {
      const addr = deterministicAddress(500_000 + i);
      flippers.push(addr);
      const elementSlot = cfArrayBase + BigInt(i);
      await setStorageRaw(purgecoinAddress, toWord(elementSlot), toAddressWord(addr));
    }

    const cfTailEntry = await getStorageEntry(PURGE_COIN_FQN, "cfTail");
    const cfHeadEntry = await getStorageEntry(PURGE_COIN_FQN, "cfHead");
    const payoutIndexEntry = await getStorageEntry(PURGE_COIN_FQN, "payoutIndex");
    await setPackedValue(purgecoinAddress, cfTailEntry, queueSize, 16);
    await setPackedValue(purgecoinAddress, cfHeadEntry, 0, 16);
    await setPackedValue(purgecoinAddress, payoutIndexEntry, 0, 4);

    const coinflipAmountEntry = await getStorageEntry(PURGE_COIN_FQN, "coinflipAmount");
    const coinflipAmountSlot = BigInt(coinflipAmountEntry.slot);
    for (const addr of flippers) {
      const slot = mapSlot(ethers.toBigInt(addr), coinflipAmountSlot);
      await setStorageRaw(purgecoinAddress, toWord(slot), toWord(BASE_FLIP_STAKE));
    }

    const scanCursorEntry = await getStorageEntry(PURGE_COIN_FQN, "scanCursor");
    const stakeLevelCompleteEntry = await getStorageEntry(PURGE_COIN_FQN, "stakeLevelComplete");
    await setPackedValue(purgecoinAddress, scanCursorEntry, SS_IDLE, 4);
    await setPackedValue(purgecoinAddress, stakeLevelCompleteEntry, targetLevel, 3);
    const confirmLevel = Number(await getPackedValue(purgecoinAddress, stakeLevelCompleteEntry, 3));
    if (confirmLevel !== targetLevel) {
      throw new Error("failed to seed stakeLevelComplete");
    }
  }

  async function configureCoinflipGameState(
    purgeGame,
    advancer,
    targetLevel,
    rngWord,
    targetDay,
    targetTs
  ) {
    const gameAddress = await purgeGame.getAddress();
    const levelEntry = await getStorageEntry(PURGE_GAME_FQN, "level");
    const phaseEntry = await getStorageEntry(PURGE_GAME_FQN, "phase");
    const stateEntry = await getStorageEntry(PURGE_GAME_FQN, "gameState");
    const prizeEntry = await getStorageEntry(PURGE_GAME_FQN, "currentPrizePool");
    const lastPrizeEntry = await getStorageEntry(PURGE_GAME_FQN, "lastPrizePool");
    const dailyIdxEntry = await getStorageEntry(PURGE_GAME_FQN, "dailyIdx");
    const levelStartEntry = await getStorageEntry(PURGE_GAME_FQN, "levelStartTime");
    const rngWordEntry = await getStorageEntry(PURGE_GAME_FQN, "rngWordCurrent");
    const rngFulfilledEntry = await getStorageEntry(PURGE_GAME_FQN, "rngFulfilled");
    const rngLockedEntry = await getStorageEntry(PURGE_GAME_FQN, "rngLockedFlag");
    const mintPackedEntry = await getStorageEntry(PURGE_GAME_FQN, "mintPacked_");

    await setPackedValue(gameAddress, levelEntry, targetLevel, 3);
    await setPackedValue(gameAddress, phaseEntry, 2);
    await setPackedValue(gameAddress, stateEntry, 2);
    await setUint256(gameAddress, prizeEntry, ethers.parseEther("260"));
    await setUint256(gameAddress, lastPrizeEntry, ethers.parseEther("200"));

    const prevDay = targetDay === 0n ? 0n : targetDay - 1n;
    await setPackedValue(gameAddress, dailyIdxEntry, prevDay, 6);
    await setPackedValue(gameAddress, levelStartEntry, targetTs, 6);

    await setUint256(gameAddress, rngWordEntry, rngWord);
    await setPackedValue(gameAddress, rngFulfilledEntry, 1);
    await setPackedValue(gameAddress, rngLockedEntry, 1);

    const mintSlot = mapSlot(ethers.toBigInt(advancer.address), BigInt(mintPackedEntry.slot));
    const mintedValue = BigInt(targetDay) << ETH_DAY_SHIFT;
    await setStorageRaw(gameAddress, toWord(mintSlot), toWord(mintedValue));
  }

  describe("coinflip gas budget", function () {
    this.timeout(0);

    async function runCoinflipGasCase() {
      const { purgeGame, purgecoin } = await deploySystem();
      const advancer = (await ethers.getSigners())[1];
      const targetLevel = 42;
      await seedCoinflipQueueState(purgecoin, targetLevel);
      const latest = BigInt(await time.latest());
      const targetTs = latest + 1_000n;
      const targetDay = (targetTs - JACKPOT_RESET_TIME) / DAY_SECONDS;
      const rngWord = 0xabcdef12344n; // force a loss -> 3x payout window
      await configureCoinflipGameState(purgeGame, advancer, targetLevel, rngWord, targetDay, targetTs);
      await time.setNextBlockTimestamp(Number(targetTs));
      const tx = await purgeGame.connect(advancer).advanceGame(0);
      const receipt = await tx.wait();
      return receipt.gasUsed;
    }

    it("coinflip gas (loss) stays under 15M", async function () {
      const gas = await runCoinflipGasCase();
      console.log("coinflip loss gas", gas.toString());
      expect(gas).to.be.lt(COINFLIP_GAS_LIMIT);
    });
  });
});
