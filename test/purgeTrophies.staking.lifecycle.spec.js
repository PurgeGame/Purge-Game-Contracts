const { expect } = require("chai");
const { ethers, artifacts } = require("hardhat");

const PURGE_TROPHY_KIND_MAP = 0;
const PURGE_TROPHY_KIND_LEVEL = 1;
const PURGE_TROPHY_KIND_AFFILIATE = 2;
const PURGE_TROPHY_KIND_STAKE = 3;
const PURGE_TROPHY_KIND_BAF = 4;

const TROPHY_FLAG_MAP = 1n << 200n;
const TROPHY_FLAG_AFFILIATE = 1n << 201n;
const TROPHY_FLAG_STAKE = 1n << 202n;
const TROPHY_FLAG_BAF = 1n << 203n;
const TROPHY_BASE_LEVEL_SHIFT = 128n;
const TROPHY_LAST_CLAIM_SHIFT = 168n;
const TROPHY_OWED_MASK = (1n << 128n) - 1n;
const COIN_BASE_UNIT = 1_000_000n;
const TRAIT_ID_TIMEOUT = 420;
const TROPHIES_FQN = "contracts/PurgeGameTrophies.sol:PurgeGameTrophies";

const layoutCache = new Map();

async function deployHarness(firstLevel = 20) {
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
    if (raw & TROPHY_FLAG_BAF) result.baf = id;
    else if (raw & TROPHY_FLAG_STAKE) result.stake = id;
    else if (raw & TROPHY_FLAG_AFFILIATE) result.affiliate = id;
    else if (raw & TROPHY_FLAG_MAP) result.map = id;
    else result.level = id;
  }
  return result;
}

function owed(info) {
  return info & TROPHY_OWED_MASK;
}

function baseLevel(info) {
  return Number((info >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFFn);
}

function lastClaim(info) {
  return Number((info >> TROPHY_LAST_CLAIM_SHIFT) & 0xFFFFFFn);
}

async function getStorageEntry(label) {
  if (!layoutCache.has(TROPHIES_FQN)) {
    const buildInfo = await artifacts.getBuildInfo(TROPHIES_FQN);
    layoutCache.set(TROPHIES_FQN, buildInfo.output.contracts["contracts/PurgeGameTrophies.sol"].PurgeGameTrophies.storageLayout.storage);
  }
  const layout = layoutCache.get(TROPHIES_FQN);
  const entry = layout.find((item) => item.label === label);
  if (!entry) throw new Error(`storage entry ${label} missing`);
  return entry;
}

async function readBafStakeInfo(trophies, player) {
  const entry = await getStorageEntry("bafStakeInfo");
  const slot = BigInt(entry.slot);
  const mapSlot = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["address", "uint256"], [player, slot])
  );
  const packed = BigInt(
    await ethers.provider.send("eth_getStorageAt", [await trophies.getAddress(), mapSlot])
  );
  const pending = BigInt(
    await ethers.provider.send("eth_getStorageAt", [
      await trophies.getAddress(),
      ethers.toBeHex(BigInt(mapSlot) + 1n, 32),
    ])
  );
  return {
    lastLevel: Number(packed & 0xFFFFFFn),
    lastDay: Number((packed >> 24n) & 0xFFFFFFFFn),
    claimedToday: Number((packed >> 56n) & 0xFFFFFFFFn),
    count: Number((packed >> 88n) & 0xFFn),
    pending,
  };
}

describe("PurgeGameTrophies staking lifecycle", function () {
  it.skip("assigns trophies, stakes multiple tokens, and vests rewards over time", async function () {
    const { game, coin, nft, trophies } = await deployHarness(20);
    const [, mapHolder, stakeHolder, bafHolder, exterminator, affiliate] = await ethers.getSigners();

    await coin.setLeaderboard([affiliate.address]);

    const placeholders = await findPlaceholders(trophies, nft, 20);
    const mapData = await trophies.trophyData(placeholders.map);
    const stakeData = await trophies.trophyData(placeholders.stake);
    const bafData = await trophies.trophyData(placeholders.baf);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      mapHolder.address,
      20,
      PURGE_TROPHY_KIND_MAP,
      mapData,
      0
    );
    await coin.awardViaCoin(
      await trophies.getAddress(),
      stakeHolder.address,
      20,
      PURGE_TROPHY_KIND_STAKE,
      stakeData,
      0
    );
    await coin.awardViaCoin(
      await trophies.getAddress(),
      bafHolder.address,
      20,
      PURGE_TROPHY_KIND_BAF,
      bafData,
      0
    );

    await trophies.connect(mapHolder).setTrophyStake(placeholders.map, true);
    await trophies.connect(stakeHolder).setTrophyStake(placeholders.stake, true);
    await trophies.connect(mapHolder).refreshStakeBonuses([placeholders.map], [], [], []);
    await trophies.connect(stakeHolder).refreshStakeBonuses([], [], [placeholders.stake], []);

    expect(await coin.burnCount()).to.equal(2n);
    const firstBurn = await coin.burnAt(0);
    expect(firstBurn.target).to.equal(mapHolder.address);
    expect(firstBurn.amount).to.equal(5_000n * COIN_BASE_UNIT);

    // Force predictable staker selections: first reward goes to map, second to stake.
    await game.setRngWord(1n << 128n);

    const req = {
      exterminator: exterminator.address,
      traitId: 123,
      level: 20,
      rngWord: 0n,
      deferredWei: 500n,
    };

    await game.processEndLevel(await trophies.getAddress(), req, { value: 500n });

    expect(await nft.ownerOf(placeholders.level)).to.equal(exterminator.address);
    expect(await nft.ownerOf(placeholders.affiliate)).to.equal(affiliate.address);

    const mapInfoAfterWin = await trophies.trophyData(placeholders.map);
    const stakeInfoAfterWin = await trophies.trophyData(placeholders.stake);
    const levelInfo = await trophies.trophyData(placeholders.level);
    const affiliateInfo = await trophies.trophyData(placeholders.affiliate);

    expect(owed(mapInfoAfterWin)).to.equal(25n);
    expect(baseLevel(mapInfoAfterWin)).to.equal(20);
    expect(owed(stakeInfoAfterWin)).to.equal(25n);
    expect(owed(levelInfo)).to.equal(350n);
    expect(owed(affiliateInfo)).to.equal(100n);

    await game.prepareNextLevel(await trophies.getAddress(), 21);
    await game.setLevel(21);

    await trophies.connect(bafHolder).setTrophyStake(placeholders.baf, true);
    expect(await coin.burnCount()).to.equal(3n);

    await trophies.connect(mapHolder).claimTrophy(placeholders.map);
    const mapAfterFirstClaim = await trophies.trophyData(placeholders.map);
    expect(owed(mapAfterFirstClaim)).to.equal(23n);
    expect(lastClaim(mapAfterFirstClaim)).to.equal(21);

    await game.setLevel(25);

    await trophies.connect(stakeHolder).claimTrophy(placeholders.stake);
    const stakeAfterClaim = await trophies.trophyData(placeholders.stake);
    expect(owed(stakeAfterClaim)).to.equal(21n);
    expect(lastClaim(stakeAfterClaim)).to.equal(25);

    await trophies.connect(mapHolder).claimTrophy(placeholders.map);
    const mapAfterSecondClaim = await trophies.trophyData(placeholders.map);
    expect(owed(mapAfterSecondClaim)).to.equal(20n);
    expect(lastClaim(mapAfterSecondClaim)).to.equal(25);

    const bafStake = await readBafStakeInfo(trophies, bafHolder.address);
    expect(bafStake.lastLevel).to.equal(21);
    expect(bafStake.count).to.equal(2);
    const rewardPerLevel = (await game.coinPriceUnit()) / 10n;
    const expectedBafPayout =
      rewardPerLevel * BigInt(bafStake.count) * ((await game.level()) - BigInt(bafStake.lastLevel));

    await trophies.connect(bafHolder).claimTrophy(placeholders.baf);
    expect(await coin.lastCoinflipPlayer()).to.equal(bafHolder.address);
    expect(await coin.lastCoinflipAmount()).to.equal(expectedBafPayout);
    expect(await coin.lastCoinflipRngReady()).to.equal(true);

    await expect(
      trophies.connect(bafHolder).claimTrophy(placeholders.baf)
    ).to.be.revertedWithCustomError(trophies, "ClaimNotReady");
  });

  it.skip("clears discounts and blocks claims after unstaking staked trophies", async function () {
    const { game, coin, nft, trophies } = await deployHarness(21);
    const [, player] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 21);
    const mapData = await trophies.trophyData(placeholders.map);
    const stakeData = await trophies.trophyData(placeholders.stake);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      player.address,
      21,
      PURGE_TROPHY_KIND_MAP,
      mapData,
      0
    );
    await coin.awardViaCoin(
      await trophies.getAddress(),
      player.address,
      21,
      PURGE_TROPHY_KIND_STAKE,
      stakeData,
      0
    );

    await trophies.connect(player).setTrophyStake(placeholders.map, true);
    await trophies.connect(player).setTrophyStake(placeholders.stake, true);
    await game.setLevel(26);
    await trophies
      .connect(player)
      .refreshStakeBonuses([placeholders.map], [], [placeholders.stake], []);

    expect(await coin.burnCount()).to.equal(2n);
    expect(await trophies.mapStakeDiscount(player.address)).to.equal(5n);
    expect(await trophies.stakeTrophyBonus(player.address)).to.equal(5n);
    expect(await trophies.isTrophyStaked(placeholders.map)).to.equal(true);
    expect(await trophies.isTrophyStaked(placeholders.stake)).to.equal(true);

    await game.setRngWord((1n << 64n) + 1n);
    const req = { exterminator: player.address, traitId: 111, level: 21, rngWord: 0n, deferredWei: 500n };
    await game.processEndLevel(await trophies.getAddress(), req, { value: 500n });

    const mapInfo = await trophies.trophyData(placeholders.map);
    const stakeInfo = await trophies.trophyData(placeholders.stake);
    expect(owed(mapInfo)).to.equal(25n);
    expect(owed(stakeInfo)).to.equal(25n);

    await trophies.connect(player).setTrophyStake(placeholders.map, false);
    expect(await coin.burnCount()).to.equal(3n);
    const mapUnstakeBurn = await coin.burnAt(2);
    expect(mapUnstakeBurn.amount).to.equal(25_000n * COIN_BASE_UNIT);
    expect(await trophies.isTrophyStaked(placeholders.map)).to.equal(false);
    expect(await trophies.mapStakeDiscount(player.address)).to.equal(0n);
    await expect(
      trophies.connect(player).claimTrophy(placeholders.map)
    ).to.be.revertedWithCustomError(trophies, "ClaimNotReady");

    await trophies.connect(player).setTrophyStake(placeholders.stake, false);
    expect(await coin.burnCount()).to.equal(4n);
    const stakeUnstakeBurn = await coin.burnAt(3);
    expect(stakeUnstakeBurn.amount).to.equal(25_000n * COIN_BASE_UNIT);
    expect(await trophies.isTrophyStaked(placeholders.stake)).to.equal(false);
    expect(await trophies.stakeTrophyBonus(player.address)).to.equal(0n);
    await expect(
      trophies.connect(player).claimTrophy(placeholders.stake)
    ).to.be.revertedWithCustomError(trophies, "ClaimNotReady");
  });

  it("allows burning trophies with pending rewards and blocks burning while staked", async function () {
    const { game, coin, nft, trophies } = await deployHarness(24);
    const [, player] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 24);
    const mapData = await trophies.trophyData(placeholders.map);
    const stakeData = await trophies.trophyData(placeholders.stake);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      player.address,
      24,
      PURGE_TROPHY_KIND_MAP,
      mapData,
      0
    );
    await coin.awardViaCoin(
      await trophies.getAddress(),
      player.address,
      24,
      PURGE_TROPHY_KIND_STAKE,
      stakeData,
      0
    );

    const pool = 2_000n;
    const req = { exterminator: ethers.ZeroAddress, traitId: TRAIT_ID_TIMEOUT, level: 24, rngWord: 0n, deferredWei: 0n };
    await game.processEndLevel(await trophies.getAddress(), req, { value: pool });

    const mapInfo = await trophies.trophyData(placeholders.map);
    expect(owed(mapInfo)).to.equal(0n);
    expect(await game.totalReceived()).to.equal(pool);
    const supplyBeforeBurn = await nft.trophySupply();

    await trophies.connect(player).setTrophyStake(placeholders.stake, true);
    await expect(trophies.connect(player).purgeTrophy(placeholders.stake)).to.be.revertedWithCustomError(
      trophies,
      "TrophyStakeViolation"
    );

    await trophies.connect(player).purgeTrophy(placeholders.map);
    const purgeReward = (await game.coinPriceUnit()) * 100n;
    expect(await coin.lastCoinflipPlayer()).to.equal(player.address);
    expect(await coin.lastCoinflipAmount()).to.equal(purgeReward);
    expect(await trophies.trophyData(placeholders.map)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(supplyBeforeBurn - 1n);
    expect(await game.totalReceived()).to.equal(pool);
  });

  it("tracks exterminator staking bonuses across multiple traits and resets on unstake", async function () {
    const { game, trophies, nft } = await deployHarness(30);
    const [, player] = await ethers.getSigners();

    const placeholders30 = await findPlaceholders(trophies, nft, 30);
    const level30Id = placeholders30.level;
    const req30 = { exterminator: player.address, traitId: 5, level: 30, rngWord: 0n, deferredWei: 0n };
    await game.processEndLevel(await trophies.getAddress(), req30);

    await game.prepareNextLevel(await trophies.getAddress(), 31);
    await game.setLevel(31);
    const placeholders31 = await findPlaceholders(trophies, nft, 31);
    const level31Id = placeholders31.level;
    const req31 = { exterminator: player.address, traitId: 6, level: 31, rngWord: 0n, deferredWei: 0n };
    await game.processEndLevel(await trophies.getAddress(), req31);

    await trophies.connect(player).setTrophyStake(level30Id, true);
    await trophies.connect(player).setTrophyStake(level31Id, true);

    await game.setLevel(40);
    await trophies.connect(player).refreshStakeBonuses([], [level30Id, level31Id], [], []);

    expect(await trophies.exterminatorStakeDiscount(player.address)).to.equal(8n);
    expect(await trophies.hasExterminatorStake(player.address)).to.equal(true);
    expect(await game.probeTraitPurge(await trophies.getAddress(), player.address, 5)).to.equal(9n);
    expect(await game.probeTraitPurge(await trophies.getAddress(), player.address, 6)).to.equal(9n);

    await trophies.connect(player).setTrophyStake(level30Id, false);
    expect(await trophies.exterminatorStakeDiscount(player.address)).to.equal(0n);
    expect(await trophies.hasExterminatorStake(player.address)).to.equal(true);

    await trophies.connect(player).refreshStakeBonuses([], [level31Id], [], []);
    expect(await trophies.exterminatorStakeDiscount(player.address)).to.equal(5n);
    expect(await game.probeTraitPurge(await trophies.getAddress(), player.address, 6)).to.equal(8n);

    await trophies.connect(player).setTrophyStake(level31Id, false);
    expect(await trophies.hasExterminatorStake(player.address)).to.equal(false);
    expect(await trophies.exterminatorStakeDiscount(player.address)).to.equal(0n);
  });
});
