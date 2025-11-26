const { expect } = require("chai");
const { ethers, network } = require("hardhat");

const abi = ethers.AbiCoder.defaultAbiCoder();

const LEVEL = 25;
const ENTRIES_PER_BUCKET = 5000;
const RNG_WORD = 0x123456789abcdefn;
const POOL_WEI = ethers.parseEther("1000");
const DEC_PLAYERS_COUNT_SLOT = 49;
const DEC_BURN_SLOT = 47;
const DEC_BUCKET_ROSTER_SLOT = 54;

const pad32 = (value) => ethers.toBeHex(value, 32);
const padAddr = (addr) => ethers.zeroPadValue(addr, 32);

const mappingSlot = (key, slot) => BigInt(ethers.keccak256(abi.encode(["uint256", "uint256"], [key, slot])));
const mappingSlotAddr = (addr, slot) =>
  BigInt(ethers.keccak256(abi.encode(["address", "uint256"], [addr, slot])));

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

describe("Gas Benchmark", function () {
  this.timeout(0);

  let purgecoin, mockGame, gameSigner;

  beforeEach(async function () {
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

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [await mockGame.getAddress()],
    });
    await network.provider.send("hardhat_setBalance", [await mockGame.getAddress(), "0x1000000000000000000"]);
    gameSigner = await ethers.getSigner(await mockGame.getAddress());
  });

  it("Benchmark: Dense Winners (High Write)", async function () {
    const CAP = 1000; 
    const OPS_LIMIT = Math.max(5000, CAP * 4);
    // Fill bucket 4 with valid entries
    const bucket = 4;
    const { bucketSlot, dataBase } = rosterSlots(LEVEL, bucket);
    const writes = [{ slot: bucketSlot, value: pad32(BigInt(ENTRIES_PER_BUCKET)) }];

    for (let i = 0; i < ENTRIES_PER_BUCKET; i += 1) {
      // Predictable addresses to avoid collision checks in setup
      const addr = ethers.getAddress(ethers.zeroPadValue(ethers.toBeHex(i + 1), 20));
      const burn = 10n ** 18n; // valid burn
      const packed = burn + (BigInt(LEVEL) << 192n) + (BigInt(bucket) << 216n);
      const decBurnSlot = mappingSlotAddr(addr, DEC_BURN_SLOT);

      writes.push({ slot: dataBase + BigInt(i), value: padAddr(addr) });
      writes.push({ slot: decBurnSlot, value: pad32(packed) });
    }
    await chunkedSet(await purgecoin.getAddress(), writes, 500);

    // Start jackpot
    // Init call
    await purgecoin.connect(gameSigner).runExternalJackpot(1, POOL_WEI, CAP, LEVEL, RNG_WORD);
    
    // Measure next step (Selection)
    const tx = await purgecoin.connect(gameSigner).runExternalJackpot(1, POOL_WEI, CAP, LEVEL, RNG_WORD);
    const receipt = await tx.wait();
    console.log(`Gas used for Dense Selection (Cap ${CAP}): ${receipt.gasUsed.toString()}`);
  });

  it("Benchmark: Sparse Scanning (High Ops, Low Write)", async function () {
    // We want to hit the OPS limit (5000) before finding many winners.
    // Set CAP=1000, OPS_LIMIT=5000.
    // We fill bucket 4 with "invalid" entries (zero burn or wrong level).
    // This forces the loop to scan and increment OPS.
    
    const CAP = 1000; 
    const OPS_LIMIT = 5000; // default minimum
    const bucket = 4;
    const { bucketSlot, dataBase } = rosterSlots(LEVEL, bucket);
    const writes = [{ slot: bucketSlot, value: pad32(BigInt(ENTRIES_PER_BUCKET)) }];

    for (let i = 0; i < ENTRIES_PER_BUCKET; i += 1) {
      const addr = ethers.getAddress(ethers.zeroPadValue(ethers.toBeHex(i + 1), 20));
      const burn = 0n; // INVALID: 0 burn
      // Even if bucket matches, 0 burn makes it invalid for winner selection in current logic?
      // Let's check code: if (e.level == lvl && e.bucket == denom && e.burn != 0)
      // So 0 burn is skipped.
      
      const packed = burn + (BigInt(LEVEL) << 192n) + (BigInt(bucket) << 216n);
      const decBurnSlot = mappingSlotAddr(addr, DEC_BURN_SLOT);

      writes.push({ slot: dataBase + BigInt(i), value: padAddr(addr) });
      writes.push({ slot: decBurnSlot, value: pad32(packed) });
    }
    await chunkedSet(await purgecoin.getAddress(), writes, 500);

    // Start jackpot
    await purgecoin.connect(gameSigner).runExternalJackpot(1, POOL_WEI, CAP, LEVEL, RNG_WORD);

    // Measure next step (Selection)
    // It should scan ~5000 entries, find 0 winners, and return because of OPS limit.
    const tx = await purgecoin.connect(gameSigner).runExternalJackpot(1, POOL_WEI, CAP, LEVEL, RNG_WORD);
    const receipt = await tx.wait();
    console.log(`Gas used for Sparse Scanning (Ops ~5000): ${receipt.gasUsed.toString()}`);
  });
});
