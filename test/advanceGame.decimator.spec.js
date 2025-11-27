const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { getJackpotSlots } = require("./helpers/jackpotSlots");

const abi = ethers.AbiCoder.defaultAbiCoder();

// ----------------------------------------------------------------------------- 
// Helpers
// ----------------------------------------------------------------------------- 
const LEVEL = 26; // Target level 26 so prevLevel is 25 (Decimator trigger)
const BUCKETS = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];
const ENTRIES_PER_BUCKET = 5000;
const RNG_WORD = 0x123456789abcdefn;
const SELECTION_CAP = 500; // winners processed per call during selection
let DEC_PLAYERS_COUNT_SLOT;
let DEC_BURN_SLOT;
let DEC_BUCKET_ROSTER_SLOT;

const pad32 = (value) => ethers.toBeHex(value, 32);
const padAddr = (addr) => ethers.zeroPadValue(addr, 32);

const mappingSlot = (key, slot) => BigInt(ethers.keccak256(abi.encode(["uint256", "uint256"], [key, slot])));
const mappingSlotAddr = (addr, slot) =>
  BigInt(ethers.keccak256(abi.encode(["address", "uint256"], [addr, slot])));

// Nested mapping (level => denom => address[]).
const rosterSlots = (level, denom) => {
  const levelSlot = mappingSlot(level, DEC_BUCKET_ROSTER_SLOT);
  const bucketSlot = BigInt(ethers.keccak256(abi.encode(["uint256", "uint256"], [denom, levelSlot])));
  const dataBase = BigInt(ethers.keccak256(abi.encode(["uint256"], [bucketSlot])));
  return { bucketSlot, dataBase };
};

const setStorage = async (target, slot, value) => {
  await network.provider.send("hardhat_setStorageAt", [target, pad32(slot), value]);
};

const chunkedSet = async (target, writes, chunkSize = 64) => {
  for (let i = 0; i < writes.length; i += chunkSize) {
    const slice = writes.slice(i, i + chunkSize);
    await Promise.all(slice.map(({ slot, value }) => setStorage(target, slot, value)));
  }
};

// Simulate the selection phase (extMode == 2) using the exact contract math.
const simulateSelection = (rosters, rngWord, cap) => {
  let entropy = BigInt(rngWord);
  const accumulators = {};
  for (let denom = 2; denom <= 20; denom += 1) {
    entropy = BigInt(ethers.keccak256(abi.encode(["uint256", "uint8"], [entropy, denom])));
    accumulators[denom] = Number(entropy % BigInt(denom));
  }

  const winners = [];
  let extVar = 0n;
  let winnersBudget = cap;
  let denom = 2;
  let idx = 0;

  while (denom <= 20 && winnersBudget !== 0) {
    const roster = rosters[denom] || [];
    const len = roster.length;
    let acc = accumulators[denom];

    if (idx >= len) {
      const advanced = len - idx;
      accumulators[denom] = Number((BigInt(acc) + BigInt(advanced)) % BigInt(denom));
      denom += 1;
      idx = 0;
      continue;
    }

    const step = (denom - ((acc + 1) % denom)) % denom;
    const winnerIdx = idx + step;
    if (winnerIdx >= len) {
      accumulators[denom] = Number((BigInt(acc) + BigInt(len - idx)) % BigInt(denom));
      denom += 1;
      idx = 0;
      continue;
    }

    const entry = roster[winnerIdx];
    winners.push(entry);
    extVar += entry.burn;
    winnersBudget -= 1;
    accumulators[denom] = 0;
    idx = winnerIdx + 1;
    if (idx >= len) {
      denom += 1;
      idx = 0;
    }
  }

  return { winners, extVar };
};

describe("AdvanceGame Decimator Integration", function () {
  this.timeout(0);

  it("triggers and completes decimator via advanceGame", async function () {
    const [deployer] = await ethers.getSigners();
    if (!DEC_BURN_SLOT) {
      const slots = await getJackpotSlots();
      DEC_BURN_SLOT = slots.decBurnSlot;
      DEC_PLAYERS_COUNT_SLOT = slots.decPlayersCountSlot;
      DEC_BUCKET_ROSTER_SLOT = slots.decBucketRosterSlot;
    }

    // --- Deploy Dependencies ---
    const MockRenderer = await ethers.getContractFactory("MockRenderer");
    const renderer = await MockRenderer.deploy();
    await renderer.waitForDeployment();

    const Purgecoin = await ethers.getContractFactory("PurgecoinHarness");
    const purgecoin = await Purgecoin.deploy();
    await purgecoin.waitForDeployment();

    const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
    const questModule = await QuestModule.deploy(await purgecoin.getAddress());
    await questModule.waitForDeployment();

    const MockTrophies = await ethers.getContractFactory("MockPurgeGameTrophies");
    const trophies = await MockTrophies.deploy();
    await trophies.waitForDeployment();

    const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
    const extJackpotModule = await ExternalJackpot.deploy();
    await extJackpotModule.waitForDeployment();

    const EndgameModule = await ethers.getContractFactory("PurgeGameEndgameModule");
    const endgameModule = await EndgameModule.deploy();
    await endgameModule.waitForDeployment();

    const JackpotModule = await ethers.getContractFactory("PurgeGameJackpotModule");
    const jackpotModule = await JackpotModule.deploy();
    await jackpotModule.waitForDeployment();

    const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
    const nft = await PurgeGameNFT.deploy(
      await renderer.getAddress(),
      await renderer.getAddress(),
      await purgecoin.getAddress()
    );
    await nft.waitForDeployment();

    // --- Deploy Game Harness ---
    const GameHarness = await ethers.getContractFactory("PurgeGameHarness");
    const game = await GameHarness.deploy(
        await purgecoin.getAddress(),
        await renderer.getAddress(),
        await nft.getAddress(),
        await trophies.getAddress(),
        await endgameModule.getAddress(),
        await jackpotModule.getAddress(),
        deployer.address, // vrfCoordinator mock
        ethers.ZeroHash, // vrfKeyHash
        0, // vrfSubscriptionId
        deployer.address // linkToken
    );
    await game.waitForDeployment();

    // --- Wire up ---
    await purgecoin.wire(
      await game.getAddress(),
      await nft.getAddress(),
      await trophies.getAddress(),
      await renderer.getAddress(),
      await renderer.getAddress(),
      await questModule.getAddress(),
      await extJackpotModule.getAddress()
    );
    
    await trophies.wireAndPrime(await game.getAddress(), await purgecoin.getAddress(), 1);

    // --- Setup Game State ---
    // Level 26, State 1 (Pregame), Phase 0
    await game.harnessSetState(LEVEL, 0, 1);
    
    // Set reward pool to enough to fund the decimator
    const rewardPool = ethers.parseEther("10000");
    await game.harnessSetRewardPool(rewardPool);

    // Ensure RNG is ready so advanceGame doesn't revert/request
    await game.harnessSetRng(RNG_WORD, true, true);

    // --- Seed decBucketRoster + decBurn in Purgecoin for PREVIOUS level (25) ---
    const decLevel = LEVEL - 1;
    const burnByAddr = {};
    const bucketByAddr = {};
    const rosters = {};
    let totalEntries = 0;

    for (const bucket of BUCKETS) {
      const { bucketSlot, dataBase } = rosterSlots(decLevel, bucket);
      const writes = [{ slot: bucketSlot, value: pad32(BigInt(ENTRIES_PER_BUCKET)) }];

      const roster = [];
      for (let i = 0; i < ENTRIES_PER_BUCKET; i += 1) {
        const raw = ethers.keccak256(abi.encode(["uint8", "uint32"], [bucket, i]));
        const addr = ethers.getAddress("0x" + raw.slice(26));
        const burn =
          (BigInt(ethers.keccak256(abi.encode(["bytes32", "uint8"], [raw, bucket]))) %
            10n ** 15n) +
          10n ** 12n; // non-zero, varied

        const packed = burn + (BigInt(decLevel) << 192n) + (BigInt(bucket) << 216n);
        const decBurnSlot = mappingSlotAddr(addr, DEC_BURN_SLOT);

        writes.push({ slot: dataBase + BigInt(i), value: padAddr(addr) });
        writes.push({ slot: decBurnSlot, value: pad32(packed) });

        burnByAddr[addr] = burn;
        bucketByAddr[addr] = bucket;
        roster.push({ addr, burn, bucket });
      }

      await chunkedSet(await extJackpotModule.getAddress(), writes, 128);
      rosters[bucket] = roster;
      totalEntries += ENTRIES_PER_BUCKET;
    }

    const decPlayersCountSlot = mappingSlot(decLevel, DEC_PLAYERS_COUNT_SLOT);
    await setStorage(await extJackpotModule.getAddress(), decPlayersCountSlot, pad32(BigInt(totalEntries)));

    // --- Expected winners + payouts (mirror contract logic) ---
    const expectedPool = (rewardPool * 15n) / 100n;
    const { winners: expectedWinners, extVar } = simulateSelection(rosters, RNG_WORD, 1_000_000_000);
    expect(extVar).to.be.gt(0n);
    const totalWinnerBurn = expectedWinners.reduce((acc, w) => acc + w.burn, 0n);
    expect(totalWinnerBurn).to.equal(extVar);

    // --- Execute via advanceGame ---
    const gasLimit = 30_000_000;
    let iterations = 0;
    while (iterations < 200) {
        const currentState = await game.gameState();
        if (currentState === 2n) {
            break;
        }

        try {
            await game.advanceGame(SELECTION_CAP, { gasLimit });
        } catch (e) {
            // eslint-disable-next-line no-console
            console.log("advanceGame revert:", e.message);
            throw e;
        }
        iterations++;
    }
    
    expect(await game.gameState()).to.equal(2n);

    // --- Verify Payouts ---
    for (let i = 0; i < 5; i++) {
        const idx = Math.floor(Math.random() * expectedWinners.length);
        const winner = expectedWinners[idx];
        const expectedAmount = (expectedPool * winner.burn) / totalWinnerBurn;
        
        const claimable = await game.harnessGetClaimable(winner.addr);
        expect(claimable).to.equal(expectedAmount);
    }
  });
});
