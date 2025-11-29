const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { getJackpotSlots } = require("./helpers/jackpotSlots");

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
let DEC_PLAYERS_COUNT_SLOT;
let DEC_BURN_SLOT;
let DEC_BUCKET_ROSTER_SLOT;
let DEC_BUCKET_BURN_TOTAL_SLOT;
let DEC_BUCKET_TOP_SLOT;
let DEC_BUCKET_INDEX_SLOT;
let DEC_BUCKET_OFFSET_SLOT;
let DEC_CLAIM_ROUND_SLOT;

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

describe("Decimator jackpot heavy bucket sweep", function () {
  this.timeout(0);

  it("selects the correct winners and proportional payouts with 5k entrants per bucket", async function () {
    const [deployer] = await ethers.getSigners();
    if (!DEC_BURN_SLOT) {
      const slots = await getJackpotSlots();
      DEC_BURN_SLOT = slots.decBurnSlot;
      DEC_PLAYERS_COUNT_SLOT = slots.decPlayersCountSlot;
      DEC_BUCKET_ROSTER_SLOT = slots.decBucketRosterSlot;
      DEC_BUCKET_BURN_TOTAL_SLOT = slots.decBucketBurnTotalSlot;
      DEC_BUCKET_TOP_SLOT = slots.decBucketTopSlot;
      DEC_BUCKET_INDEX_SLOT = slots.decBucketIndexSlot;
      DEC_BUCKET_OFFSET_SLOT = slots.decBucketOffsetSlot;
      DEC_CLAIM_ROUND_SLOT = slots.decClaimRoundSlot;
    }

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

    const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
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
      await extJackpot.getAddress(),
      deployer.address
    );

    // --- Seed decBucketRoster + decBurn directly in storage for scale ---
    const rosters = {};
    let totalEntries = 0;
    const decBucketIndexBase = mappingSlot(LEVEL, DEC_BUCKET_INDEX_SLOT);

    for (const bucket of BUCKETS) {
      const subRosters = Array.from({ length: bucket }, () => []);
      const burnTotals = Array(bucket).fill(0n);
      const topBurns = Array(bucket).fill(0n);
      const topAddrs = Array(bucket).fill(ethers.ZeroAddress);
      const rosterSlotsBySub = subRosters.map((_, sub) => rosterSlots(LEVEL, bucket, sub));
      const burnSlotsBySub = subRosters.map((_, sub) => burnTotalSlot(LEVEL, bucket, sub));
      const topSlotsBySub = subRosters.map((_, sub) => topSlot(LEVEL, bucket, sub));
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
          burn + (BigInt(LEVEL) << 192n) + (BigInt(bucket) << 216n) + (BigInt(sub) << 224n);
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

      await chunkedSet(await extJackpot.getAddress(), writes, 128);
      rosters[bucket] = subRosters;
      totalEntries += ENTRIES_PER_BUCKET;
    }

    const decPlayersCountSlot = mappingSlot(LEVEL, DEC_PLAYERS_COUNT_SLOT);
    await setStorage(await extJackpot.getAddress(), decPlayersCountSlot, pad32(BigInt(totalEntries)));
    const countRaw = await network.provider.send("eth_getStorageAt", [
      await extJackpot.getAddress(),
      pad32(decPlayersCountSlot),
    ]);
    // eslint-disable-next-line no-console
    console.log("decPlayersCount", BigInt(countRaw));

    // --- Execute jackpot selection + payout on-chain ---
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [await mockGame.getAddress()],
    });
    await network.provider.send("hardhat_setBalance", [await mockGame.getAddress(), "0x1000000000000000000"]);
    const gameSigner = await ethers.getSigner(await mockGame.getAddress());

    await extJackpot.connect(gameSigner).runExternalJackpot.staticCall(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD);

    const gasLimit = 25_000_000;
    try {
      await extJackpot
        .connect(gameSigner)
        .runExternalJackpot(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD, { gasLimit }); // init
    } catch (e) {
      // eslint-disable-next-line no-console
      console.log("init tx revert data", e.data || e);
      throw e;
    }
    const slot54 = await network.provider.send("eth_getStorageAt", [await purgecoin.getAddress(), pad32(54n)]);
    const slot55 = await network.provider.send("eth_getStorageAt", [await purgecoin.getAddress(), pad32(55n)]);
    // eslint-disable-next-line no-console
    console.log("slot54", slot54);
    // eslint-disable-next-line no-console
    console.log("slot55", slot55);
    let iterations = 0;
    let finalReturn = 0n;

    while (true) {
      const [stepFinished, , , , returnWeiStep] = await extJackpot
        .connect(gameSigner)
        .runExternalJackpot.staticCall(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD);

      try {
        await extJackpot
          .connect(gameSigner)
          .runExternalJackpot(1, POOL_WEI, SELECTION_CAP, LEVEL, RNG_WORD, { gasLimit });
      } catch (e) {
        // eslint-disable-next-line no-console
        console.log("jackpot tx revert data", e.data || e);
        throw e;
      }

      iterations += 1;
      if (stepFinished) {
        finalReturn = returnWeiStep;
        break;
      }
      if (iterations > 250) throw new Error("jackpot batching did not finish");
    }

    expect(finalReturn).to.equal(0n);

    const roundSlot = mappingSlot(LEVEL, 61);
    const roundSeed = await network.provider.send("eth_getStorageAt", [await purgecoin.getAddress(), pad32(roundSlot)]);
    // eslint-disable-next-line no-console
    console.log("dec round seed", roundSeed);

    const roundBase = mappingSlot(LEVEL, DEC_CLAIM_ROUND_SLOT);
    const poolWeiRaw = await network.provider.send("eth_getStorageAt", [await extJackpot.getAddress(), pad32(roundBase)]);
    const totalBurnRaw = await network.provider.send("eth_getStorageAt", [
      await extJackpot.getAddress(),
      pad32(roundBase + 1n),
    ]);
    const poolWei = BigInt(poolWeiRaw);
    const totalBurn = BigInt(totalBurnRaw);
    expect(poolWei).to.equal(POOL_WEI);
    expect(totalBurn).to.be.gt(0n);

    const offsets = {};
    const offsetLevelBase = mappingSlot(LEVEL, DEC_BUCKET_OFFSET_SLOT);
    for (const bucket of BUCKETS) {
      const offsetSlot = mappingSlot(bucket, offsetLevelBase);
      const raw = await network.provider.send("eth_getStorageAt", [await extJackpot.getAddress(), pad32(offsetSlot)]);
      offsets[bucket] = Number(BigInt(raw));
    }

    const expectedWinners = [];
    for (const bucket of BUCKETS) {
      const winningSub = offsets[bucket] % bucket;
      expectedWinners.push(...rosters[bucket][winningSub]);
    }

    const expectedTotalBurn = expectedWinners.reduce((acc, w) => acc + w.burn, 0n);
    expect(totalBurn).to.equal(expectedTotalBurn);

    const expectedAmounts = expectedWinners.map((w) => (poolWei * w.burn) / totalBurn);

    const winnerSet = new Set(expectedWinners.map((w) => w.addr.toLowerCase()));
    let nonWinner = null;
    for (const bucket of BUCKETS) {
      if (nonWinner) break;
      for (const subRoster of rosters[bucket]) {
        if (nonWinner) break;
        for (const entry of subRoster) {
          if (!winnerSet.has(entry.addr.toLowerCase())) {
            nonWinner = entry.addr;
            break;
          }
        }
      }
    }

    if (nonWinner) {
      await expect(extJackpot.connect(gameSigner).consumeDecClaim(nonWinner, LEVEL)).to.be.revertedWithCustomError(
        extJackpot,
        "DecNotWinner"
      );
    }

    const actualAmounts = [];
    for (let i = 0; i < expectedWinners.length; i += 1) {
      const w = expectedWinners[i];
      try {
        const amt = await extJackpot.connect(gameSigner).consumeDecClaim.staticCall(w.addr, LEVEL);
        await extJackpot.connect(gameSigner).consumeDecClaim(w.addr, LEVEL);
        actualAmounts.push(amt);
      } catch (err) {
        // eslint-disable-next-line no-console
        console.log("consume failed at", i, w.addr);
        throw err;
      }
    }

    expect(ethers.keccak256(abi.encode(["uint256[]"], [actualAmounts]))).to.equal(
      ethers.keccak256(abi.encode(["uint256[]"], [expectedAmounts]))
    );
    const paidTotal = actualAmounts.reduce((acc, v) => acc + v, 0n);
    const expectedPaid = expectedAmounts.reduce((acc, v) => acc + v, 0n);
    expect(paidTotal).to.equal(expectedPaid);
  });
});
