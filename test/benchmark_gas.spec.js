const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { getJackpotSlots } = require("./helpers/jackpotSlots");

const abi = ethers.AbiCoder.defaultAbiCoder();

const LEVEL = 25;
const ENTRIES_PER_BUCKET = 5000;
const RNG_WORD = 0x123456789abcdefn;
const POOL_WEI = ethers.parseEther("1000");
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

describe("Gas Benchmark", function () {
  this.timeout(0);

  let purgecoin, mockGame, gameSigner, extJackpot;

  beforeEach(async function () {
    if (!DEC_BURN_SLOT) {
      const slots = await getJackpotSlots();
      DEC_BURN_SLOT = slots.decBurnSlot;
      DEC_PLAYERS_COUNT_SLOT = slots.decPlayersCountSlot;
      DEC_BUCKET_ROSTER_SLOT = slots.decBucketRosterSlot;
      DEC_BUCKET_BURN_TOTAL_SLOT = slots.decBucketBurnTotalSlot;
      DEC_BUCKET_TOP_SLOT = slots.decBucketTopSlot;
      DEC_BUCKET_INDEX_SLOT = slots.decBucketIndexSlot;
    }

    const [deployer] = await ethers.getSigners();

    const MockGame = await ethers.getContractFactory("MockPurgeGame");
    mockGame = await MockGame.deploy();
    await mockGame.waitForDeployment();
    await mockGame.setLevel(LEVEL);
    await mockGame.setGameState(3);

    const MockRenderer = await ethers.getContractFactory("MockRenderer");
    const renderer = await MockRenderer.deploy();
    await renderer.waitForDeployment();

    const Purgecoin = await ethers.getContractFactory("PurgecoinHarness");
    purgecoin = await Purgecoin.deploy();
    await purgecoin.waitForDeployment();

    const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
    const questModule = await QuestModule.deploy(await purgecoin.getAddress());
    await questModule.waitForDeployment();

    const MockTrophies = await ethers.getContractFactory("MockPurgeGameTrophies");
    const trophies = await MockTrophies.deploy();
    await trophies.waitForDeployment();

    const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
    extJackpot = await ExternalJackpot.deploy();
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

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [await mockGame.getAddress()],
    });
    await network.provider.send("hardhat_setBalance", [await mockGame.getAddress(), "0x1000000000000000000"]);
    gameSigner = await ethers.getSigner(await mockGame.getAddress());
  });

  it("Benchmark: Dense Winners (High Write)", async function () {
    const CAP = 1000; 
    const bucket = 4;
    const decBucketIndexBase = mappingSlot(LEVEL, DEC_BUCKET_INDEX_SLOT);
    const subRosters = Array.from({ length: bucket }, () => []);
    const burnTotals = Array(bucket).fill(0n);
    const topBurns = Array(bucket).fill(0n);
    const topAddrs = Array(bucket).fill(ethers.ZeroAddress);
    const rosterSlotsBySub = subRosters.map((_, sub) => rosterSlots(LEVEL, bucket, sub));
    const burnSlotsBySub = subRosters.map((_, sub) => burnTotalSlot(LEVEL, bucket, sub));
    const topSlotsBySub = subRosters.map((_, sub) => topSlot(LEVEL, bucket, sub));
    const writes = [];

    for (let i = 0; i < ENTRIES_PER_BUCKET; i += 1) {
      // Predictable addresses to avoid collision checks in setup
      const addr = ethers.getAddress(ethers.zeroPadValue(ethers.toBeHex(i + 1), 20));
      const burn = 10n ** 18n; // valid burn

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

      subRosters[sub].push(addr);
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

    await chunkedSet(await extJackpot.getAddress(), writes, 500);
    const decPlayersCountSlot = mappingSlot(LEVEL, DEC_PLAYERS_COUNT_SLOT);
    await setStorage(await extJackpot.getAddress(), decPlayersCountSlot, pad32(BigInt(ENTRIES_PER_BUCKET)));

    // Start jackpot
    // Init call
    await extJackpot.connect(gameSigner).runDecimatorJackpot(POOL_WEI, LEVEL, RNG_WORD);

    const [, , , returnPreview] = await extJackpot
      .connect(gameSigner)
      .runDecimatorJackpot.staticCall(POOL_WEI, LEVEL, RNG_WORD);
    expect(returnPreview).to.equal(0n);

    // Measure next step (Selection)
    const tx = await extJackpot.connect(gameSigner).runDecimatorJackpot(POOL_WEI, LEVEL, RNG_WORD);
    const receipt = await tx.wait();
    console.log(`Gas used for Dense Selection (Cap ${CAP}): ${receipt.gasUsed.toString()}`);
  });

  it("Benchmark: Sparse Scanning (High Ops, Low Write)", async function () {
    const CAP = 1000; 
    const bucket = 4;
    const decBucketIndexBase = mappingSlot(LEVEL, DEC_BUCKET_INDEX_SLOT);
    const subRosters = Array.from({ length: bucket }, () => []);
    const burnTotals = Array(bucket).fill(0n);
    const topBurns = Array(bucket).fill(0n);
    const topAddrs = Array(bucket).fill(ethers.ZeroAddress);
    const rosterSlotsBySub = subRosters.map((_, sub) => rosterSlots(LEVEL, bucket, sub));
    const burnSlotsBySub = subRosters.map((_, sub) => burnTotalSlot(LEVEL, bucket, sub));
    const topSlotsBySub = subRosters.map((_, sub) => topSlot(LEVEL, bucket, sub));
    const writes = [];

    for (let i = 0; i < ENTRIES_PER_BUCKET; i += 1) {
      const addr = ethers.getAddress(ethers.zeroPadValue(ethers.toBeHex(i + 1), 20));
      const burn = 0n;

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

      subRosters[sub].push(addr);
    }

    for (let sub = 0; sub < bucket; sub += 1) {
      writes.push({ slot: rosterSlotsBySub[sub].bucketSlot, value: pad32(BigInt(subRosters[sub].length)) });
      writes.push({ slot: burnSlotsBySub[sub], value: pad32(burnTotals[sub]) });
      writes.push({ slot: topSlotsBySub[sub], value: padAddr(topAddrs[sub]) });
      writes.push({ slot: topSlotsBySub[sub] + 1n, value: pad32(topBurns[sub]) });
    }

    await chunkedSet(await extJackpot.getAddress(), writes, 500);
    const decPlayersCountSlot = mappingSlot(LEVEL, DEC_PLAYERS_COUNT_SLOT);
    await setStorage(await extJackpot.getAddress(), decPlayersCountSlot, pad32(BigInt(ENTRIES_PER_BUCKET)));

    // Start jackpot
    await extJackpot.connect(gameSigner).runDecimatorJackpot(POOL_WEI, LEVEL, RNG_WORD);

    const [, , , returnPreview] = await extJackpot
      .connect(gameSigner)
      .runDecimatorJackpot.staticCall(POOL_WEI, LEVEL, RNG_WORD);
    expect(returnPreview).to.equal(POOL_WEI);

    // Measure next step (Selection)
    const tx = await extJackpot.connect(gameSigner).runDecimatorJackpot(POOL_WEI, LEVEL, RNG_WORD);
    const receipt = await tx.wait();
    console.log(`Gas used for Sparse Selection (Cap ${CAP}): ${receipt.gasUsed.toString()}`);
  });
});
