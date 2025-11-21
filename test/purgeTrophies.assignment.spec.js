const { expect } = require("chai");
const { ethers, artifacts, network } = require("hardhat");

const PURGE_TROPHY_KIND_MAP = 0;
const PURGE_TROPHY_KIND_LEVEL = 1;
const PURGE_TROPHY_KIND_AFFILIATE = 2;
const PURGE_TROPHY_KIND_STAKE = 3;
const PURGE_TROPHY_KIND_BAF = 4;
const PURGE_TROPHY_KIND_DECIMATOR = 5;

const TROPHY_FLAG_MAP = 1n << 200n;
const TROPHY_FLAG_AFFILIATE = 1n << 201n;
const TROPHY_FLAG_STAKE = 1n << 202n;
const TROPHY_FLAG_BAF = 1n << 203n;
const TROPHY_FLAG_DECIMATOR = 1n << 204n;
const TROPHY_BASE_LEVEL_SHIFT = 128n;
const TROPHY_OWED_MASK = (1n << 128n) - 1n;
const TROPHY_LAST_CLAIM_SHIFT = 168n;
const COIN_BASE_UNIT = 1_000_000n;
const COIN_EMISSION_UNIT = 1_000n * COIN_BASE_UNIT;
const BAF_LEVEL_REWARD = 100n * COIN_BASE_UNIT;
const TRAIT_ID_TIMEOUT = 420;
const DECIMATOR_TRAIT_SENTINEL = 0xfffb;
const TROPHIES_FQN = "contracts/PurgeGameTrophies.sol:PurgeGameTrophies";

async function getStorageEntry(label) {
  const buildInfo = await artifacts.getBuildInfo(TROPHIES_FQN);
  const entry = buildInfo.output.contracts["contracts/PurgeGameTrophies.sol"].PurgeGameTrophies.storageLayout.storage.find(
    (item) => item.label === label
  );
  if (!entry) throw new Error(`storage entry ${label} missing`);
  return entry;
}

async function setTrophyStakedFlag(trophiesAddr, tokenId, staked) {
  const entry = await getStorageEntry("trophyStaked");
  const slot = BigInt(entry.slot);
  const mapSlot = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [BigInt(tokenId), slot])
  );
  const val = staked ? ethers.toBeHex(1, 32) : ethers.ZeroHash;
  await network.provider.send("hardhat_setStorageAt", [trophiesAddr, mapSlot, val]);
}

async function deployHarness(firstLevel = 5) {
  const TrophyGameHarness = await ethers.getContractFactory("TrophyGameHarness");
  const TrophyCoinHarness = await ethers.getContractFactory("TrophyCoinHarness");
  const TrophyNFTHarness = await ethers.getContractFactory("TrophyNFTHarness");
  const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");

  const game = await TrophyGameHarness.deploy();
  await game.waitForDeployment();

  const coin = await TrophyCoinHarness.deploy();
  await coin.waitForDeployment();

  const nft = await TrophyNFTHarness.deploy(await game.getAddress(), await coin.getAddress());
  await nft.waitForDeployment();

  const trophies = await PurgeGameTrophies.deploy(await nft.getAddress());
  await trophies.waitForDeployment();

  await coin.wireTrophies(await trophies.getAddress(), await game.getAddress(), firstLevel);
  await game.setLevel(firstLevel);

  return { game, coin, nft, trophies };
}

async function findPlaceholders(trophies, nft, level) {
  const maxId = Number(await nft.nextTokenId());
  const result = {};
  for (let id = 1; id < maxId; id += 1) {
    const raw = await trophies.trophyData(id);
    if (raw === 0n) continue;
    const baseLevel = Number((raw >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFFn);
    if (baseLevel !== level) continue;
    if (raw & TROPHY_FLAG_DECIMATOR) result.decimator = id;
    else if (raw & TROPHY_FLAG_BAF) result.baf = id;
    else if (raw & TROPHY_FLAG_STAKE) result.stake = id;
    else if (raw & TROPHY_FLAG_AFFILIATE) result.affiliate = id;
    else if (raw & TROPHY_FLAG_MAP) result.map = id;
    else result.level = id;
  }
  return result;
}

describe("PurgeGameTrophies assignment and funds", function () {
  it("routes trait wins to exterminator, affiliate leaderboard, and staked trophies", async function () {
    const { game, coin, nft, trophies } = await deployHarness(5);
    const [, exterminator, staker, topAffiliate, otherAffiliate] = await ethers.getSigners();

    await coin.setLeaderboard([topAffiliate.address, otherAffiliate.address]);

    const placeholders = await findPlaceholders(trophies, nft, 5);
    const mapData = await trophies.trophyData(placeholders.map);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      staker.address,
      5,
      PURGE_TROPHY_KIND_MAP,
      mapData,
      0
    );

    await game.setGameState(3);
    await game.setRngLocked(false);
    await trophies.connect(staker).setTrophyStake(placeholders.map, true);

    expect(await coin.burnCount()).to.equal(1n);
    const burnRecord = await coin.burnAt(0);
    expect(burnRecord.amount).to.equal(5_000n * COIN_BASE_UNIT);
    expect(burnRecord.target).to.equal(staker.address);

    const pool = 20_000n;
    const req = {
      exterminator: exterminator.address,
      traitId: 123,
      level: 5,
      pool,
    };

    await game.processEndLevel(await trophies.getAddress(), req, { value: 300n });

    const levelData = await trophies.trophyData(placeholders.level);
    const affiliateData = await trophies.trophyData(placeholders.affiliate);
    const stakedMapData = await trophies.trophyData(placeholders.map);

    expect(await nft.ownerOf(placeholders.level)).to.equal(exterminator.address);
    expect(await nft.ownerOf(placeholders.affiliate)).to.equal(topAffiliate.address);
    expect(levelData & TROPHY_OWED_MASK).to.equal(0n);
    expect(affiliateData & TROPHY_OWED_MASK).to.equal(200n);
    expect(stakedMapData & TROPHY_OWED_MASK).to.equal(100n);
  });

  it("burns level trophy and distributes timeout pool to map holder, stakers, and game", async function () {
    const { game, coin, nft, trophies } = await deployHarness(7);
    const [, staker] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 7);
    const mapData = await trophies.trophyData(placeholders.map);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      staker.address,
      7,
      PURGE_TROPHY_KIND_MAP,
      mapData,
      0
    );
    await trophies.connect(staker).setTrophyStake(placeholders.map, true);

    const pool = 2_000n;
    const req = {
      exterminator: ethers.ZeroAddress,
      traitId: TRAIT_ID_TIMEOUT,
      level: 7,
      pool,
    };

    await game.processEndLevel(await trophies.getAddress(), req, { value: 2_050n });

    expect(await trophies.trophyData(placeholders.level)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(3n);

    const stakedMapData = await trophies.trophyData(placeholders.map);
    expect(stakedMapData & TROPHY_OWED_MASK).to.equal(2_000n);
    const baseLevel = Number((stakedMapData >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFFn);
    expect(baseLevel).to.equal(7);

    expect(await game.totalReceived()).to.equal(50n);
  });

  it("requires full affiliate-only funding and burns the level trophy on timeout", async function () {
    const { game, coin, nft, trophies } = await deployHarness(8);
    const [, affiliate] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 8);
    const pool = 1_000n;
    const req = {
      exterminator: affiliate.address,
      traitId: TRAIT_ID_TIMEOUT,
      level: 8,
      pool,
    };

    await expect(
      game.processEndLevel(await trophies.getAddress(), req, { value: pool - 1n })
    ).to.be.revertedWithCustomError(trophies, "InvalidToken");

    await game.processEndLevel(await trophies.getAddress(), req, { value: pool });

    expect(await trophies.trophyData(placeholders.level)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(3n);

    const affiliateData = await trophies.trophyData(placeholders.affiliate);
    expect(affiliateData & TROPHY_OWED_MASK).to.equal(pool);
    expect(await nft.ownerOf(placeholders.affiliate)).to.equal(affiliate.address);
  });

  it("pays decimator coin drip when staked", async function () {
    const { game, coin, nft, trophies } = await deployHarness(25);
    const [, player] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 25);
    const decData = await trophies.trophyData(placeholders.decimator);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      player.address,
      25,
      PURGE_TROPHY_KIND_DECIMATOR,
      decData,
      0
    );

    await game.setGameState(3);
    await game.setRngLocked(false);
    await expect(
      trophies.connect(player).setTrophyStake(placeholders.decimator, true)
    ).to.be.revertedWithCustomError(trophies, "StakeInvalid");

    await setTrophyStakedFlag(await trophies.getAddress(), placeholders.decimator, true);

    await game.setLevel(46);
    await trophies.connect(player).claimTrophy(placeholders.decimator);

    expect(await coin.lastCoinflipPlayer()).to.equal(player.address);
    expect(await coin.lastCoinflipAmount()).to.equal(12n * COIN_EMISSION_UNIT);
    expect(await coin.lastCoinflipRngReady()).to.equal(true);

    const info = await trophies.trophyData(placeholders.decimator);
    const lastClaim = Number((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFFn);
    expect(lastClaim).to.equal(46);
  });

  it("accrues and pays BAF stake rewards with caps", async function () {
    const { game, coin, nft, trophies } = await deployHarness(20);
    const [, player] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 20);
    const bafData = await trophies.trophyData(placeholders.baf);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      player.address,
      20,
      PURGE_TROPHY_KIND_BAF,
      bafData,
      0
    );

    await game.setGameState(3);
    await game.setRngLocked(false);
    await trophies.connect(player).setTrophyStake(placeholders.baf, true);

    await game.setLevel(24);
    await trophies.connect(player).claimTrophy(placeholders.baf);

    expect(await coin.lastCoinflipPlayer()).to.equal(player.address);
    expect(await coin.lastCoinflipAmount()).to.equal(8n * BAF_LEVEL_REWARD);
    expect(await coin.lastCoinflipRngReady()).to.equal(true);

    const info = await trophies.trophyData(placeholders.baf);
    expect(info & TROPHY_OWED_MASK).to.equal(0n);
    expect(await nft.ownerOf(placeholders.baf)).to.equal(player.address);
  });

  it("burns affiliate trophy and skips payouts when no leaderboard addresses exist", async function () {
    const { game, nft, trophies } = await deployHarness(6);
    const [, exterminator] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 6);
    const req = {
      exterminator: exterminator.address,
      traitId: 777,
      level: 6,
      pool: 5_000n,
    };

    const supplyBefore = await nft.trophySupply();
    await game.processEndLevel(await trophies.getAddress(), req, { value: 0 });

    expect(await nft.ownerOf(placeholders.level)).to.equal(exterminator.address);
    expect(await trophies.trophyData(placeholders.affiliate)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(supplyBefore - 1n);
  });

  it("burns BAF trophy placeholder on flop loss", async function () {
    const { coin, nft, trophies } = await deployHarness(20);
    const placeholders = await findPlaceholders(trophies, nft, 20);
    const supplyBefore = await nft.trophySupply();
    expect(placeholders.baf).to.not.equal(undefined);

    await coin.burnBaf(await trophies.getAddress(), 20);

    expect(await trophies.trophyData(placeholders.baf)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(supplyBefore - 1n);
  });
});
