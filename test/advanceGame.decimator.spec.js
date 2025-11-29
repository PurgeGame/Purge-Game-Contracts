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
let DEC_BUCKET_BURN_TOTAL_SLOT;
let DEC_BUCKET_TOP_SLOT;
let DEC_BUCKET_INDEX_SLOT;

const pad32 = (value) => ethers.toBeHex(value, 32);
const padAddr = (addr) => ethers.zeroPadValue(addr, 32);

const mappingSlot = (key, slot) => BigInt(ethers.keccak256(abi.encode(["uint256", "uint256"], [key, slot])));
const mappingSlotAddr = (addr, slot) =>
  BigInt(ethers.keccak256(abi.encode(["address", "uint256"], [addr, slot])));

const subbucketSlot = (level, denom, sub, baseSlot) => {
  const levelSlot = mappingSlot(level, baseSlot);
  const bucketSlot = BigInt(ethers.keccak256(abi.encode(["uint256", "uint256"], [denom, levelSlot])));
  return BigInt(ethers.keccak256(abi.encode(["uint256", "uint256"], [sub, bucketSlot])));
};

// Nested mapping (level => denom => sub => address[]).
const rosterSlots = (level, denom, sub) => {
  const bucketSlot = subbucketSlot(level, denom, sub, DEC_BUCKET_ROSTER_SLOT);
  const dataBase = BigInt(ethers.keccak256(abi.encode(["uint256"], [bucketSlot])));
  return { bucketSlot, dataBase };
};

const burnTotalSlot = (level, denom, sub) => subbucketSlot(level, denom, sub, DEC_BUCKET_BURN_TOTAL_SLOT);
const topSlot = (level, denom, sub) => subbucketSlot(level, denom, sub, DEC_BUCKET_TOP_SLOT);

const setStorage = async (target, slot, value) => {
  await network.provider.send("hardhat_setStorageAt", [target, pad32(slot), value]);
};

const chunkedSet = async (target, writes, chunkSize = 64) => {
  for (let i = 0; i < writes.length; i += chunkSize) {
    const slice = writes.slice(i, i + chunkSize);
    await Promise.all(slice.map(({ slot, value }) => setStorage(target, slot, value)));
  }
};

// Simulate the selection phase (extMode == 2) using the subbucket selection math.
const simulateSelection = (rosters, rngWord) => {
  const winners = [];
  let totalBurn = 0n;

  for (let denom = 2; denom <= 20; denom += 1) {
    const bucketRosters = rosters[denom];
    if (!bucketRosters) continue;

    const winningSub = Number(
      BigInt(ethers.keccak256(abi.encode(["uint256", "uint8"], [rngWord, denom]))) % BigInt(denom)
    );
    const subRoster = bucketRosters[winningSub] || [];
    winners.push(...subRoster);
    for (const entry of subRoster) {
      totalBurn += entry.burn;
    }
  }

  return { winners, totalBurn };
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
      DEC_BUCKET_BURN_TOTAL_SLOT = slots.decBucketBurnTotalSlot;
      DEC_BUCKET_TOP_SLOT = slots.decBucketTopSlot;
      DEC_BUCKET_INDEX_SLOT = slots.decBucketIndexSlot;
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
      await extJackpotModule.getAddress(),
      deployer.address
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
    const rosters = {};
    let totalEntries = 0;
    const decBucketIndexBase = mappingSlot(decLevel, DEC_BUCKET_INDEX_SLOT);

    for (const bucket of BUCKETS) {
      const subRosters = Array.from({ length: bucket }, () => []);
      const burnTotals = Array(bucket).fill(0n);
      const topBurns = Array(bucket).fill(0n);
      const topAddrs = Array(bucket).fill(ethers.ZeroAddress);
      const rosterSlotsBySub = subRosters.map((_, sub) => rosterSlots(decLevel, bucket, sub));
      const burnSlotsBySub = subRosters.map((_, sub) => burnTotalSlot(decLevel, bucket, sub));
      const topSlotsBySub = subRosters.map((_, sub) => topSlot(decLevel, bucket, sub));
      const writes = [];

      for (let i = 0; i < ENTRIES_PER_BUCKET; i += 1) {
        const raw = ethers.keccak256(abi.encode(["uint8", "uint32"], [bucket, i]));
        const addr = ethers.getAddress("0x" + raw.slice(26));
        const burn =
          (BigInt(ethers.keccak256(abi.encode(["bytes32", "uint8"], [raw, bucket]))) %
            10n ** 15n) +
          10n ** 12n; // non-zero, varied

        const sub = i % bucket;
        const idxInSub = Math.floor(i / bucket);
        const packed =
          burn + (BigInt(decLevel) << 192n) + (BigInt(bucket) << 216n) + (BigInt(sub) << 224n);
        const decBurnSlot = mappingSlotAddr(addr, DEC_BURN_SLOT);
        const decIndexSlot = mappingSlotAddr(addr, decBucketIndexBase);

        const { dataBase } = rosterSlotsBySub[sub];
        writes.push({ slot: dataBase + BigInt(idxInSub), value: padAddr(addr) });
        writes.push({ slot: decBurnSlot, value: pad32(packed) });
        writes.push({ slot: decIndexSlot, value: pad32(BigInt(idxInSub)) });

        subRosters[sub].push({ addr, burn, bucket, sub, idx: idxInSub });
        burnTotals[sub] += burn;
        if (burn > topBurns[sub]) {
          topBurns[sub] = burn;
          topAddrs[sub] = addr;
        }
      }

      for (let sub = 0; sub < bucket; sub += 1) {
        writes.push({ slot: rosterSlotsBySub[sub].bucketSlot, value: pad32(BigInt(subRosters[sub].length)) });
        writes.push({ slot: burnSlotsBySub[sub], value: pad32(burnTotals[sub]) });
        writes.push({ slot: topSlotsBySub[sub], value: padAddr(topAddrs[sub]) });
        writes.push({ slot: topSlotsBySub[sub] + 1n, value: pad32(topBurns[sub]) });
      }

      await chunkedSet(await extJackpotModule.getAddress(), writes, 128);
      rosters[bucket] = subRosters;
      totalEntries += ENTRIES_PER_BUCKET;
    }

    const decPlayersCountSlot = mappingSlot(decLevel, DEC_PLAYERS_COUNT_SLOT);
    await setStorage(await extJackpotModule.getAddress(), decPlayersCountSlot, pad32(BigInt(totalEntries)));

    // --- Expected winners + payouts (mirror contract logic) ---
    const expectedPool = (rewardPool * 15n) / 100n;
    const { winners: expectedWinners, totalBurn: expectedTotalBurn } = simulateSelection(rosters, RNG_WORD);
    expect(expectedTotalBurn).to.be.gt(0n);

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
        const expectedAmount = (expectedPool * winner.burn) / expectedTotalBurn;
        
        const claimable = await game.harnessGetClaimable(winner.addr);
        expect(claimable).to.equal(expectedAmount);
    }
  });
});
