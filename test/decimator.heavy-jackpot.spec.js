const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const abi = ethers.AbiCoder.defaultAbiCoder();

// ----------------------------------------------------------------------------- 
// Helpers
// ----------------------------------------------------------------------------- 
const LEVEL = 25;
const BUCKETS = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];
const ENTRIES_PER_BUCKET = 5000;
const RNG_WORD = 0x123456789abcdefn;
const POOL_WEI = ethers.parseEther("1000");
const SELECTION_CAP = 1900; // winners processed per call during selection
const DEC_PLAYERS_COUNT_SLOT = 49;
const DEC_BURN_SLOT = 47;
const DEC_BUCKET_ROSTER_SLOT = 54;

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

const streamingPayout = (poolWei, winners) => {
  let remainingPool = poolWei;
  let remainingBurn = winners.reduce((acc, w) => acc + w.burn, 0n);
  const payouts = [];

  for (const w of winners) {
    const amount =
      remainingBurn === 0n ? 0n : w.burn === remainingBurn ? remainingPool : (remainingPool * w.burn) / remainingBurn;
    payouts.push(amount);
    remainingPool -= amount;
    remainingBurn -= w.burn;
  }

  return payouts;
};

describe("Decimator jackpot heavy bucket sweep", function () {
  this.timeout(0);

  it("selects the correct winners and proportional payouts with 5k entrants per bucket", async function () {
    const [deployer] = await ethers.getSigners();

    // --- Deploy minimal system with mocks ---
    const MockGame = await ethers.getContractFactory("MockPurgeGame");
    const mockGame = await MockGame.deploy();
    await mockGame.waitForDeployment();
    await mockGame.setLevel(LEVEL);
    await mockGame.setGameState(3); // gameState not used in dec flow but set to active-ish

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

    const ExternalJackpot = await ethers.getContractFactory("PurgeCoinExternalJackpotModule");
    const extJackpot = await ExternalJackpot.deploy();
    await extJackpot.waitForDeployment();

    const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
    const nft = await PurgeGameNFT.deploy(
      await renderer.getAddress(),
      await renderer.getAddress(),
      await purgecoin.getAddress()
    );
    await nft.waitForDeployment();

    await purgecoin.wire(
      await mockGame.getAddress(),
      await nft.getAddress(),
      await trophies.getAddress(),
      await renderer.getAddress(),
      await renderer.getAddress(),
      await questModule.getAddress(),
      await extJackpot.getAddress()
    );

    // --- Seed decBucketRoster + decBurn directly in storage for scale ---
    const burnByAddr = {};
    const bucketByAddr = {};
    const rosters = {};
    let totalEntries = 0;

    for (const bucket of BUCKETS) {
      const { bucketSlot, dataBase } = rosterSlots(LEVEL, bucket);
      const writes = [{ slot: bucketSlot, value: pad32(BigInt(ENTRIES_PER_BUCKET)) }];

      const roster = [];
      for (let i = 0; i < ENTRIES_PER_BUCKET; i += 1) {
        const raw = ethers.keccak256(abi.encode(["uint8", "uint32"], [bucket, i]));
        const addr = ethers.getAddress("0x" + raw.slice(26));
        const burn =
          (BigInt(ethers.keccak256(abi.encode(["bytes32", "uint8"], [raw, bucket]))) %
            10n ** 15n) +
          10n ** 12n; // non-zero, varied

        const packed = burn + (BigInt(LEVEL) << 192n) + (BigInt(bucket) << 216n);
        const decBurnSlot = mappingSlotAddr(addr, DEC_BURN_SLOT);

        writes.push({ slot: dataBase + BigInt(i), value: padAddr(addr) });
        writes.push({ slot: decBurnSlot, value: pad32(packed) });

        burnByAddr[addr] = burn;
        bucketByAddr[addr] = bucket;
        roster.push({ addr, burn, bucket });
      }

      await chunkedSet(await purgecoin.getAddress(), writes, 128);
      rosters[bucket] = roster;
      totalEntries += ENTRIES_PER_BUCKET;
    }

    const decPlayersCountSlot = mappingSlot(LEVEL, DEC_PLAYERS_COUNT_SLOT);
    await setStorage(await purgecoin.getAddress(), decPlayersCountSlot, pad32(BigInt(totalEntries)));

    // --- Expected winners + payouts (mirror contract logic) ---
    const { winners: expectedWinners, extVar } = simulateSelection(rosters, RNG_WORD, 1_000_000_000);
    expect(extVar).to.be.gt(0n);
    const totalWinnerBurn = expectedWinners.reduce((acc, w) => acc + w.burn, 0n);
    expect(totalWinnerBurn).to.equal(extVar);

    const payPool = (POOL_WEI * 95n) / 100n;
    const expectedAmounts = streamingPayout(payPool, expectedWinners);
    const expectedTopWinner = expectedWinners.reduce((best, w) => (best === null || w.burn > best.burn ? w : best), null)
      ?.addr;
    const expectedTrophyAmount = POOL_WEI - payPool;

    // --- Execute jackpot selection + payout on-chain ---
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [await mockGame.getAddress()],
    });
    await network.provider.send("hardhat_setBalance", [await mockGame.getAddress(), "0x1000000000000000000"]);
    const gameSigner = await ethers.getSigner(await mockGame.getAddress());

    await purgecoin
      .connect(gameSigner)
      .runExternalJackpot.staticCall(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD);

    const gasLimit = 25_000_000;
    try {
      await purgecoin.connect(gameSigner).runExternalJackpot(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD, { gasLimit }); // init
    } catch (e) {
      // eslint-disable-next-line no-console
      console.log("init tx revert data", e.data || e);
      throw e;
    }
    let iterations = 0;
    let finished = false;
    let finalReturn = 0n;
    const actualWinners = [];
    const actualAmounts = [];

    while (!finished) {
      const [stepFinished, winnersStep, amountsStep, , returnWeiStep] = await purgecoin
        .connect(gameSigner)
        .runExternalJackpot.staticCall(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD);

      try {
        await purgecoin
          .connect(gameSigner)
          .runExternalJackpot(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD, { gasLimit });
      } catch (e) {
        // eslint-disable-next-line no-console
        console.log("jackpot tx revert data", e.data || e);
        throw e;
      }

      for (let i = 0; i < winnersStep.length; i += 1) {
        actualWinners.push(winnersStep[i]);
        actualAmounts.push(amountsStep[i]);
      }

      if (stepFinished) {
        finished = true;
        finalReturn = returnWeiStep;
      }

      iterations += 1;
      if (iterations > 250) throw new Error("jackpot batching did not finish");
    }

    const burnWinners = actualWinners.slice(0, expectedWinners.length);
    const burnAmounts = actualAmounts.slice(0, expectedWinners.length);

    expect(actualWinners.length).to.equal(expectedWinners.length + 1);
    expect(ethers.keccak256(abi.encode(["address[]"], [burnWinners]))).to.equal(
      ethers.keccak256(abi.encode(["address[]"], [expectedWinners.map((w) => w.addr)]))
    );
    expect(ethers.keccak256(abi.encode(["uint256[]"], [burnAmounts]))).to.equal(
      ethers.keccak256(abi.encode(["uint256[]"], [expectedAmounts]))
    );
    expect(actualWinners[expectedWinners.length]).to.equal(expectedTopWinner);
    expect(actualAmounts[expectedWinners.length]).to.equal(expectedTrophyAmount);

    // Bucket-level sanity: winner counts per bucket match expectation.
    const expectedCounts = {};
    for (const w of expectedWinners) {
      expectedCounts[w.bucket] = (expectedCounts[w.bucket] || 0) + 1;
    }
    const actualCounts = {};
    for (const addr of burnWinners) {
      const b = bucketByAddr[addr];
      actualCounts[b] = (actualCounts[b] || 0) + 1;
    }
    expect(actualCounts).to.deep.equal(expectedCounts);

    // Sum of payouts should consume the full pool with streaming division.
    const paidBurn = burnAmounts.reduce((acc, v) => acc + v, 0n);
    expect(paidBurn).to.equal(payPool);
    const paidTotal = actualAmounts.reduce((acc, v) => acc + v, 0n);
    expect(paidTotal + finalReturn).to.equal(POOL_WEI);
    expect(finalReturn).to.equal(0n);
  });
});
