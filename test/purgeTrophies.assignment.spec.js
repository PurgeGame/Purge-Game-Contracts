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
const TROPHY_CLAIMS_SHIFT = 192n;
const COIN_BASE_UNIT = 1_000_000n;
const COIN_EMISSION_UNIT = 1_000n * COIN_BASE_UNIT;
const BAF_LEVEL_REWARD = 100n * COIN_BASE_UNIT;
const TRAIT_ID_TIMEOUT = 420;
const DECIMATOR_TRAIT_SENTINEL = 0xfffb;
const TROPHIES_FQN = "contracts/PurgeGameTrophies.sol:PurgeGameTrophies";
const TROPHY_GAME_FQN = "contracts/mocks/TrophyModuleHarness.sol:TrophyGameHarness";

const layoutCache = new Map();

async function getStorageEntry(fqn, label) {
  if (!layoutCache.has(fqn)) {
    const buildInfo = await artifacts.getBuildInfo(fqn);
    const [source, name] = fqn.split(":");
    layoutCache.set(fqn, buildInfo.output.contracts[source][name].storageLayout.storage);
  }
  const layout = layoutCache.get(fqn);
  const entry = layout.find((item) => item.label === label);
  if (!entry) throw new Error(`storage entry ${label} missing`);
  return entry;
}

async function setTrophyStakedFlag(trophiesAddr, tokenId, staked) {
  const entry = await getStorageEntry(TROPHIES_FQN, "trophyStaked");
  const slot = BigInt(entry.slot);
  const mapSlot = ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(["uint256", "uint256"], [BigInt(tokenId), slot])
  );
  const val = staked ? ethers.toBeHex(1, 32) : ethers.ZeroHash;
  await network.provider.send("hardhat_setStorageAt", [trophiesAddr, mapSlot, val]);
}

async function setUint256Slot(address, entry, value) {
  if (entry.offset !== 0) throw new Error("unexpected packed slot");
  await network.provider.send("hardhat_setStorageAt", [
    address,
    ethers.toBeHex(BigInt(entry.slot), 32),
    ethers.toBeHex(BigInt(value), 32),
  ]);
}

async function readBafStakeInfo(trophies, player) {
  const entry = await getStorageEntry(TROPHIES_FQN, "bafStakeInfo");
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

function owed(info) {
  return info & TROPHY_OWED_MASK;
}

function claims(info) {
  return Number((info >> TROPHY_CLAIMS_SHIFT) & 0xFFn);
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
      rngWord: 0n,
      deferredWei: 300n,
    };

    await game.processEndLevel(await trophies.getAddress(), req, { value: 300n });

    const levelData = await trophies.trophyData(placeholders.level);
    const affiliateData = await trophies.trophyData(placeholders.affiliate);
    const stakeData = await trophies.trophyData(placeholders.stake);
    const stakedMapData = await trophies.trophyData(placeholders.map);

    expect(await nft.ownerOf(placeholders.level)).to.equal(exterminator.address);
    expect(await nft.ownerOf(placeholders.affiliate)).to.equal(topAffiliate.address);
    expect(levelData & TROPHY_OWED_MASK).to.equal(req.deferredWei);
    expect(affiliateData & TROPHY_OWED_MASK).to.equal(0n);
    expect(stakedMapData & TROPHY_OWED_MASK).to.equal(0n);
    expect(stakeData).to.equal(0n); // stake placeholder burned because it was never assigned
    expect(await nft.trophySupply()).to.equal(3n);
    expect(await game.totalReceived()).to.equal(300n);
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
      rngWord: 0n,
      deferredWei: 0n,
    };

    await game.processEndLevel(await trophies.getAddress(), req, { value: 2_050n });

    expect(await trophies.trophyData(placeholders.level)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(1n);

    const stakedMapData = await trophies.trophyData(placeholders.map);
    expect(stakedMapData & TROPHY_OWED_MASK).to.equal(0n);
    const baseLevel = Number((stakedMapData >> TROPHY_BASE_LEVEL_SHIFT) & 0xFFFFFFn);
    expect(baseLevel).to.equal(7);

    expect(await game.totalReceived()).to.equal(2_050n);
  });

  it("requires full affiliate-only funding and burns the level trophy on timeout", async function () {
    const { game, coin, nft, trophies } = await deployHarness(8);
    const [, affiliate] = await ethers.getSigners();

    await coin.setLeaderboard([affiliate.address]);

    const placeholders = await findPlaceholders(trophies, nft, 8);
    const req = {
      exterminator: affiliate.address,
      traitId: TRAIT_ID_TIMEOUT,
      level: 8,
      rngWord: 0n,
      deferredWei: 0n,
    };

    await game.processEndLevel(await trophies.getAddress(), req, { value: 0 });

    expect(await trophies.trophyData(placeholders.level)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(2n);

    const affiliateData = await trophies.trophyData(placeholders.affiliate);
    expect(affiliateData & TROPHY_OWED_MASK).to.equal(0n);
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
    await trophies.connect(player).setTrophyStake(placeholders.decimator, true);

    await game.setLevel(46);
    await trophies.connect(player).claimTrophy(placeholders.decimator);

    expect(await coin.lastCoinflipPlayer()).to.equal(player.address);
    expect(await coin.lastCoinflipAmount()).to.equal(12n * (await game.coinPriceUnit()));
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
    const stakeState = await readBafStakeInfo(trophies, player.address);
    const priceUnit = await game.coinPriceUnit();
    const rewardPerLevel = priceUnit / 10n;
    const currentLevel = await game.level();
    const deltaLevels = currentLevel - BigInt(stakeState.lastLevel);
    const expectedPending = stakeState.pending + deltaLevels * BigInt(stakeState.count) * rewardPerLevel;
    await trophies.connect(player).claimTrophy(placeholders.baf);

    expect(await coin.lastCoinflipPlayer()).to.equal(player.address);
    expect(await coin.lastCoinflipAmount()).to.equal(expectedPending);
    expect(await coin.lastCoinflipRngReady()).to.equal(true);

    const info = await trophies.trophyData(placeholders.baf);
    expect(info & TROPHY_OWED_MASK).to.equal(0n);
    expect(await nft.ownerOf(placeholders.baf)).to.equal(player.address);
  });

  it("assigns trophies, stakes them, funds endgame rewards, and lets stakers claim", async function () {
    const { game, coin, nft, trophies } = await deployHarness(12);
    const [, mapHolder, stakeHolder, exterminator, affiliate] = await ethers.getSigners();

    await coin.setLeaderboard([affiliate.address]);

    const placeholders = await findPlaceholders(trophies, nft, 12);
    const mapData = await trophies.trophyData(placeholders.map);
    const stakeData = await trophies.trophyData(placeholders.stake);

    await coin.awardViaCoin(
      await trophies.getAddress(),
      mapHolder.address,
      12,
      PURGE_TROPHY_KIND_MAP,
      mapData,
      0
    );
    await coin.awardViaCoin(
      await trophies.getAddress(),
      stakeHolder.address,
      12,
      PURGE_TROPHY_KIND_STAKE,
      stakeData,
      0
    );

    await trophies.connect(mapHolder).setTrophyStake(placeholders.map, true);
    await trophies.connect(stakeHolder).setTrophyStake(placeholders.stake, true);
    expect(await coin.burnCount()).to.equal(2n);

    const gameAddr = await game.getAddress();
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [gameAddr],
    });
    const gameSigner = await ethers.getSigner(gameAddr);
    await (await mapHolder.sendTransaction({ to: gameAddr, value: ethers.parseEther("1") })).wait();

    const scaledPool = 50_000n;
    const rngSeed = 888n;
    const halfPercent = scaledPool / 200n;
    const expectedAffiliateReward = halfPercent * 2n;
    const expectedStakeReward = halfPercent;
    const expectedRandomReward = halfPercent;

    const req = { exterminator: exterminator.address, traitId: 777, level: 12, rngWord: rngSeed, deferredWei: 0n };
    await trophies.connect(gameSigner).processEndLevel(req, scaledPool);

    expect(await nft.ownerOf(placeholders.level)).to.equal(exterminator.address);
    expect(await nft.ownerOf(placeholders.affiliate)).to.equal(affiliate.address);

    const affiliateInfo = await trophies.trophyData(placeholders.affiliate);
    const stakeInfo = await trophies.trophyData(placeholders.stake);
    const mapInfo = await trophies.trophyData(placeholders.map);

    expect(owed(affiliateInfo)).to.equal(expectedAffiliateReward);
    expect(owed(affiliateInfo) + owed(stakeInfo) + owed(mapInfo)).to.equal(
      expectedAffiliateReward + expectedStakeReward + expectedRandomReward
    );
    expect(owed(stakeInfo) + owed(mapInfo)).to.equal(expectedStakeReward + expectedRandomReward);
    expect(owed(stakeInfo)).to.be.gt(0n);

    // Stake affiliate after rewards are assigned so claims are permitted.
    await trophies.connect(affiliate).setTrophyStake(placeholders.affiliate, true);
    expect(await coin.burnCount()).to.equal(3n);

    const poolEntry = await getStorageEntry(TROPHY_GAME_FQN, "trophyPool");
    const poolTopUp = ethers.parseEther("1");
    await setUint256Slot(gameAddr, poolEntry, poolTopUp);

    await game.setLevel(13);

    const stakeClaims = claims(await trophies.trophyData(placeholders.stake));
    const affiliateClaims = claims(await trophies.trophyData(placeholders.affiliate));
    const mapClaims = claims(await trophies.trophyData(placeholders.map));

    const stakePayout = owed(stakeInfo) / BigInt(stakeClaims);
    const affiliatePayout = owed(affiliateInfo) / BigInt(affiliateClaims);
    const mapPayout = mapClaims === 0 ? 0n : owed(mapInfo) / BigInt(mapClaims);

    const poolBefore = await game.trophyPool();

    await trophies.connect(stakeHolder).claimTrophy(placeholders.stake);
    await trophies.connect(affiliate).claimTrophy(placeholders.affiliate);
    if (mapPayout !== 0n) {
      await trophies.connect(mapHolder).claimTrophy(placeholders.map);
    }

    const poolAfter = await game.trophyPool();
    expect(poolBefore - poolAfter).to.equal(stakePayout + affiliatePayout + mapPayout);

    const stakeInfoAfterClaim = await trophies.trophyData(placeholders.stake);
    expect(owed(stakeInfoAfterClaim)).to.equal(owed(stakeInfo) - stakePayout);

    const affiliateInfoAfterClaim = await trophies.trophyData(placeholders.affiliate);
    expect(owed(affiliateInfoAfterClaim)).to.equal(owed(affiliateInfo) - affiliatePayout);

    if (mapPayout !== 0n) {
      const mapInfoAfterClaim = await trophies.trophyData(placeholders.map);
      expect(owed(mapInfoAfterClaim)).to.equal(owed(mapInfo) - mapPayout);
    }
  });

  it("burns affiliate trophy and skips payouts when no leaderboard addresses exist", async function () {
    const { game, nft, trophies } = await deployHarness(6);
    const [, exterminator] = await ethers.getSigners();

    const placeholders = await findPlaceholders(trophies, nft, 6);
    const req = {
      exterminator: exterminator.address,
      traitId: 777,
      level: 6,
      rngWord: 0n,
      deferredWei: 0n,
    };

    const supplyBefore = await nft.trophySupply();
    await game.processEndLevel(await trophies.getAddress(), req, { value: 0 });

    expect(await nft.ownerOf(placeholders.level)).to.equal(exterminator.address);
    expect(await trophies.trophyData(placeholders.affiliate)).to.equal(0n);
    expect(await nft.trophySupply()).to.equal(supplyBefore - 2n);
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
