const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

async function deploySystem() {
  const [deployer] = await ethers.getSigners();

  const Renderer = await ethers.getContractFactory("MockRenderer");
  const renderer = await Renderer.deploy();
  await renderer.waitForDeployment();
  const trophyRenderer = await Renderer.deploy();
  await trophyRenderer.waitForDeployment();

  const VRF = await ethers.getContractFactory("MockVRFCoordinator");
  const vrf = await VRF.deploy(ethers.parseEther("500"));
  await vrf.waitForDeployment();

  const Link = await ethers.getContractFactory("MockLinkToken");
  const link = await Link.deploy();
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
    await renderer.getAddress(),
    await trophyRenderer.getAddress(),
    await purgecoin.getAddress()
  );
  await purgeNFT.waitForDeployment();

  const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
  const purgeTrophies = await PurgeGameTrophies.deploy(await purgeNFT.getAddress());
  await purgeTrophies.waitForDeployment();

  const Endgame = await ethers.getContractFactory("PurgeGameEndgameModule");
  const endgameModule = await Endgame.deploy();
  await endgameModule.waitForDeployment();

  const Jackpot = await ethers.getContractFactory("PurgeGameJackpotModule");
  const jackpotModule = await Jackpot.deploy();
  await jackpotModule.waitForDeployment();

  const PurgeGame = await ethers.getContractFactory("PurgeGame");
  const purgeGame = await PurgeGame.deploy(
    await purgecoin.getAddress(),
    await renderer.getAddress(),
    await purgeNFT.getAddress(),
    await purgeTrophies.getAddress(),
    await endgameModule.getAddress(),
    await jackpotModule.getAddress(),
    await vrf.getAddress(),
    ethers.ZeroHash,
    1n,
    await link.getAddress()
  );
  await purgeGame.waitForDeployment();

  await (
    await purgecoin.wire(
      await purgeGame.getAddress(),
      await purgeNFT.getAddress(),
      await purgeTrophies.getAddress(),
      await renderer.getAddress(),
      await trophyRenderer.getAddress(),
      await questModule.getAddress(),
      await externalJackpot.getAddress()
    )
  ).wait();

  return {
    purgeGame,
    purgecoin,
    purgeNFT,
    purgeTrophies,
    renderer,
    trophyRenderer,
    vrf,
    link,
    deployer,
  };
}

async function createWallets(count, funder, amount) {
  const provider = ethers.provider;
  const wallets = [];
  for (let i = 0; i < count; i += 1) {
    const wallet = ethers.Wallet.createRandom().connect(provider);
    wallets.push(wallet);
    await (await funder.sendTransaction({ to: wallet.address, value: amount })).wait();
  }
  return wallets;
}

const JACKPOT_RESET_TIME = 82620;
const DAY_SECONDS = 24 * 60 * 60;
const MINIMUM_PRIZE_POOL_WEI = ethers.parseEther("125");
const INITIAL_CARRYOVER_WEI = ethers.parseEther("40");
const MAP_PURCHASE_TARGET_WEI = ethers.parseEther("150");
const JACKPOT_LEVEL_CAP = 10;
const LEVEL_COUNT = 10;
const FUTURE_MAP_OPTIONS = { baseQuantity: 100, quantityVariance: 20, minBuyers: 8, maxBuyers: 12 };
const EARLY_PURGE_UNLOCK_THRESHOLD = 30;
const EARLY_PURGE_BONUS_THRESHOLD = 50;
const MILLION = 1_000_000n;
const STRATEGY_MAP_QUANTITY = 4;
const QUEST_TYPES = {
  MINT_ANY: 0,
  MINT_ETH: 1,
  FLIP: 2,
  STAKE: 3,
  AFFILIATE: 4,
  PURGE: 5,
  DECIMATOR: 6,
};
const QUEST_STAKE_REQUIRE_PRINCIPAL = 1;
const QUEST_STAKE_REQUIRE_DISTANCE = 1 << 1;
const QUEST_STAKE_REQUIRE_RISK = 1 << 2;
const QUEST_COMPLETION_PARAMS = {
  mintQuantity: 12,
  purgeQuantity: 12,
  flipAmount: 5000n * MILLION,
  stakePrincipal: 2500n * MILLION,
  stakeDistance: 120,
  stakeRisk: 14,
  affiliateAmount: 6000n * MILLION,
  decimatorAmount: 10000n * MILLION,
};
const QUEST_MINT_ATTEMPT_LIMIT = 8;
const QUEST_PREFUND_COINS = 5_000n * MILLION;
const STAKE_STRATEGY = {
  playerCount: 10,
  burnAmount: 5_000n * MILLION,
  targetLead: 30,
  risk: 5,
  maxPerLevel: 1,
};
const NO_BONUS_STRATEGY = {
  playerCount: 25,
  quantity: STRATEGY_MAP_QUANTITY,
  thresholdPercent: 50,
  quantityRange: { min: STRATEGY_MAP_QUANTITY, max: STRATEGY_MAP_QUANTITY * 5 },
  rngSeed: 0x5ab1en,
};
const NEXT_LEVEL_DAY1_PREFUND_BPS = 1000n; // 10% of next-level requirement front-loaded on purge day 1
const NEXT_LEVEL_DAILY_PREFUND_BPS = 500n; // 5% drip during daily jackpots

function createDeterministicRng(seed = 0x5150n) {
  const mask = (1n << 64n) - 1n;
  let state = seed & mask;
  return (bound) => {
    if (!bound || bound <= 0) return 0;
    state = (state * 6364136223846793005n + 1442695040888963407n) & mask;
    return Number(state % BigInt(bound));
  };
}

function randomJackpotWord(label = "vrf") {
  const timeSalt = BigInt(Date.now());
  const randomSalt = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER));
  return BigInt(
    ethers.solidityPackedKeccak256(
      ["string", "uint256", "uint256"],
      [label, timeSalt, randomSalt]
    )
  );
}

async function currentDay() {
  const block = await ethers.provider.getBlock("latest");
  return BigInt(Math.max(0, Math.floor((block.timestamp - JACKPOT_RESET_TIME) / DAY_SECONDS)));
}

async function configureReferralChain(purgecoin, players, options = {}) {
  if (players.length === 0) {
    return { referralAssignments: new Map(), referralChain: [] };
  }
  const rng = createDeterministicRng(options.seed ?? 0xfacecafe1234n);
  const minBatch = Math.max(1, options.minBatch ?? 1);
  const maxBatch = Math.max(minBatch, options.maxBatch ?? 10);
  const minRakeback = options.minRakeback ?? 2;
  const maxRakeback = Math.min(25, Math.max(minRakeback, options.maxRakeback ?? 12));

  const referralAssignments = new Map();
  const referralChain = [];
  const referralCodes = new Map();
  const playerIndex = new Map(players.map((player, idx) => [player.address, idx]));

  const ensureCode = async (wallet, idx) => {
    if (referralCodes.has(wallet.address)) {
      return referralCodes.get(wallet.address);
    }
    const rakebackSpread = maxRakeback - minRakeback + 1;
    const rakeback = minRakeback + (rakebackSpread > 0 ? rng(rakebackSpread) : 0);
    const code = ethers.solidityPackedKeccak256(["string", "uint256"], ["pg-aff", idx]);
    await (await purgecoin.connect(wallet).createAffiliateCode(code, rakeback)).wait();
    referralCodes.set(wallet.address, code);
    referralChain.push(wallet.address);
    return code;
  };

  const assignReferral = async (wallet, code) => {
    if (!wallet || !code) {
      return;
    }
    if (referralAssignments.has(wallet.address)) {
      return;
    }
    await (await purgecoin.connect(wallet).referPlayer(code)).wait();
    referralAssignments.set(wallet.address, code);
  };

  const roundRobinGroups = Array.isArray(options.roundRobinGroups) ? options.roundRobinGroups : [];
  for (const group of roundRobinGroups) {
    const participants = Array.isArray(group) ? group.filter(Boolean) : [];
    if (participants.length < 2) continue;
    for (const participant of participants) {
      const idx = playerIndex.get(participant.address) ?? referralChain.length;
      await ensureCode(participant, idx);
    }
    for (let i = 0; i < participants.length; i += 1) {
      const referrer = participants[(i + 1) % participants.length];
      const code = referralCodes.get(referrer.address);
      if (!code) continue;
      await assignReferral(participants[i], code);
    }
  }

  const unassigned = players.filter((player) => !referralAssignments.has(player.address));
  if (unassigned.length === 0) {
    return { referralAssignments, referralChain, referralCodes };
  }

  let referrerIdx = 0;
  const initialIdx = playerIndex.get(unassigned[referrerIdx].address) ?? referrerIdx;
  await ensureCode(unassigned[referrerIdx], initialIdx);
  let cursor = 1;

  while (cursor < unassigned.length) {
    const referrer = unassigned[referrerIdx];
    const refIdx = playerIndex.get(referrer.address) ?? referrerIdx;
    const code = await ensureCode(referrer, refIdx);
    const remaining = unassigned.length - cursor;
    const spanRange = maxBatch - minBatch + 1;
    const batchSize = Math.min(
      Math.max(1, minBatch + (spanRange > 0 ? rng(spanRange) : 0)),
      remaining
    );
    for (let i = 0; i < batchSize && cursor < unassigned.length; i += 1) {
      const invitee = unassigned[cursor];
      await assignReferral(invitee, code);
      cursor += 1;
    }
    referrerIdx = cursor - 1;
    if (cursor < unassigned.length) {
      const idx = playerIndex.get(unassigned[referrerIdx].address) ?? referrerIdx;
      await ensureCode(unassigned[referrerIdx], idx);
    }
  }

  return { referralAssignments, referralChain, referralCodes };
}

function coinMintValueWei(coinAmount, mintPriceWei, priceCoinUnit) {
  if (!coinAmount || coinAmount === 0n || mintPriceWei === 0n || priceCoinUnit === 0n) {
    return 0n;
  }
  return (coinAmount * mintPriceWei * 80n) / (priceCoinUnit * 100n);
}

function mapMinimumQuantity(level) {
  const mod = level % 100;
  if (mod >= 60) return 1;
  if (mod >= 40) return 2;
  return 4;
}

async function primeNextLevelMaps({
  levelValue,
  purgeGame,
  purgeNFT,
  players,
  contributions,
  referralCodes,
  stageFundingPlan,
  vrf,
  vrfConsumer,
  percentBps = 0n,
  absoluteWei = 0n,
}) {
  const nextLevelValue = levelValue + 1;
  if (!stageFundingPlan.has(nextLevelValue)) {
    return { buyers: 0, quantity: 0n, totalCost: 0n };
  }
  const nextPlan = stageFundingPlan.get(nextLevelValue);
  const stageInfo = nextPlan.priorPurge;
  const remaining = stageInfo.target > stageInfo.contributed ? stageInfo.target - stageInfo.contributed : 0n;
  if (remaining === 0n) {
    return { buyers: 0, quantity: 0n, totalCost: 0n };
  }
  let desiredContribution = remaining;
  let descriptor = stageInfo.contributed === 0n ? "initial 30%" : "top-up";
  if (absoluteWei !== 0n) {
    desiredContribution = absoluteWei > remaining ? remaining : absoluteWei;
    descriptor = "fixed front-load";
  } else if (percentBps !== 0n) {
    const percentTarget = (stageInfo.target * percentBps) / 10000n;
    if (percentTarget > 0n) {
      desiredContribution = percentTarget > remaining ? remaining : percentTarget;
    }
    descriptor = `daily drip (${Number(percentBps) / 100}%)`;
  }
  if (desiredContribution === 0n) {
    return { buyers: 0, quantity: 0n, totalCost: 0n };
  }
  console.log(
    `Priming level ${nextLevelValue} with ${ethers.formatEther(desiredContribution)} ETH in map mints (${descriptor})`
  );
  const { contributions: primeContributions, stats } = await seedContractWithMaps(
    purgeGame,
    purgeNFT,
    players,
    desiredContribution,
    undefined,
    referralCodes,
    nextLevelValue,
    { exactAmount: true, vrf, vrfConsumer }
  );
  mergeContributionMaps(contributions, primeContributions);
  stageInfo.contributed += stats.totalCost;
  return stats;
}

function accumulateDailyMapActivity(target, addition) {
  if (!addition) {
    return target;
  }
  return {
    buyers: target.buyers + (addition.buyers ?? 0),
    quantity: target.quantity + (addition.quantity ?? 0n),
    totalCost: target.totalCost + (addition.totalCost ?? 0n),
  };
}

async function runStrategyMapPurchases({
  players,
  purgeGame,
  purgeNFT,
  contributions,
  referralCodes,
  targetLevel,
  quantity = STRATEGY_MAP_QUANTITY,
  mintCountLedger,
  quantityRange,
  quantityRng,
}) {
  if (!players || players.length === 0) {
    return { buyers: 0, quantity: 0n, totalCost: 0n };
  }
  const stats = { buyers: 0, quantity: 0n, totalCost: 0n };
  const useRandomQuantity = Boolean(quantityRange);
  const minQuantity = useRandomQuantity ? Math.max(1, Number(quantityRange.min ?? 1)) : quantity;
  const maxQuantity = useRandomQuantity ? Math.max(minQuantity, Number(quantityRange.max ?? minQuantity)) : minQuantity;
  const quantitySpan = maxQuantity - minQuantity + 1;
  const rngFn =
    useRandomQuantity && quantitySpan > 0
      ? quantityRng ?? ((bound) => (bound <= 0 ? 0 : Math.floor(Math.random() * bound)))
      : null;
  for (const player of players) {
    const randomOffset = useRandomQuantity ? rngFn(quantitySpan) : 0;
    const playerQuantity = useRandomQuantity ? minQuantity + randomOffset : quantity;
    if (playerQuantity <= 0) {
      continue;
    }
    const spent = await executeStrategyMint({
      player,
      quantity: playerQuantity,
      targetLevel,
      purgeNFT,
      purgeGame,
      contributions,
      referralCodes,
    });
    stats.buyers += 1;
    stats.quantity += BigInt(playerQuantity);
    stats.totalCost += spent;
    if (mintCountLedger) {
      const prevCount = mintCountLedger.get(player.address) ?? 0n;
      mintCountLedger.set(player.address, prevCount + BigInt(playerQuantity));
    }
  }
  return stats;
}

async function executeStrategyMint({
  player,
  quantity,
  targetLevel,
  purgeNFT,
  purgeGame,
  contributions,
  referralCodes,
  affiliateOverride,
}) {
  const info = await purgeGame.gameInfo();
  const price = info.price_;
  const mapCost = (price * BigInt(quantity) * 25n) / 100n;
  const affiliateCode = affiliateOverride ?? referralCodes.get(player.address) ?? ethers.ZeroHash;
  await recordEarlyPurgeMint(purgeGame, targetLevel, quantity);
  await (
    await purgeNFT.connect(player).mintAndPurge(quantity, false, affiliateCode, {
      value: mapCost,
    })
  ).wait();
  const prev = contributions.get(player.address) ?? 0n;
  contributions.set(player.address, prev + mapCost);
  addLevelContribution(targetLevel, player.address, mapCost);
  return mapCost;
}

async function runNoBonusMapStrategy({
  players,
  purgeGame,
  purgeNFT,
  contributions,
  referralCodes,
  targetLevel,
  mintCountLedger,
  executedLevels,
  strategy = NO_BONUS_STRATEGY,
}) {
  if (!players || players.length === 0) {
    return null;
  }
  if (executedLevels.has(targetLevel)) {
    return null;
  }
  const info = await purgeGame.gameInfo();
  const phaseValue = typeof info.phase_ === "bigint" ? Number(info.phase_) : Number(info.phase_ ?? 0);
  const earlyPercent =
    typeof info.earlyPurgePercent_ === "bigint" ? Number(info.earlyPurgePercent_) : Number(info.earlyPurgePercent_);
  const threshold = strategy.thresholdPercent ?? 50;
  if (phaseValue !== 3) {
    return null;
  }
  if (earlyPercent >= threshold) {
    return null;
  }
  let normalizedRange;
  let rangeRng;
  if (strategy.quantityRange) {
    const minQuantity = Math.max(1, Number(strategy.quantityRange.min ?? 1));
    const maxQuantity = Math.max(minQuantity, Number(strategy.quantityRange.max ?? minQuantity));
    normalizedRange = { min: minQuantity, max: maxQuantity };
    let baseSeed = 0x5150n;
    if (strategy.rngSeed !== undefined) {
      baseSeed = typeof strategy.rngSeed === "bigint" ? strategy.rngSeed : BigInt(strategy.rngSeed);
    }
    const seed = baseSeed ^ BigInt(targetLevel);
    rangeRng = createDeterministicRng(seed);
  }
  const results = await runStrategyMapPurchases({
    players,
    purgeGame,
    purgeNFT,
    contributions,
    referralCodes,
    targetLevel,
    quantity: strategy.quantity ?? STRATEGY_MAP_QUANTITY,
    mintCountLedger,
    quantityRange: normalizedRange,
    quantityRng: rangeRng,
  });
  executedLevels.add(targetLevel);
  return results;
}

async function runStakeStrategies({
  purgecoin,
  purgeGame,
  players,
  strategy,
}) {
  if (!players || players.length === 0) {
    return [];
  }
  const stakes = [];
  const maxPerLevel = strategy.maxPerLevel ?? players.length;
  const targetLead = strategy.targetLead ?? 25;
  const burnAmount = strategy.burnAmount ?? 0n;
  const risk = strategy.risk ?? 3;
  if (!burnAmount || burnAmount === 0n) {
    return stakes;
  }
  const currentLevel = Number(await purgeGame.level());
  const targetLevel = currentLevel + targetLead;
  for (const player of players) {
    if (stakes.length >= maxPerLevel) break;
    const balance = await purgecoin.balanceOf(player.address);
    if (balance < burnAmount) continue;
    try {
      await (await purgecoin.connect(player).stake(burnAmount, targetLevel, risk)).wait();
      stakes.push({
        player: player.address,
        burnAmount,
        targetLevel,
        risk,
        level: currentLevel,
      });
    } catch (err) {
      console.warn(`Stake attempt failed for ${player.address}: ${err.message}`);
    }
  }
  return stakes;
}

function collectCredits(purgeGame, receipts) {
  const iface = purgeGame.interface;
  const ordered = [];
  const totals = new Map();
  for (const receipt of receipts) {
    for (const log of receipt.logs) {
      let parsed;
      try {
        parsed = iface.parseLog(log);
      } catch {
        continue;
      }
      if (!parsed || parsed.name !== "PlayerCredited") continue;
      const addr = parsed.args.player;
      const amount = parsed.args.amount;
      ordered.push({ address: addr, amount });
      const prev = totals.get(addr) ?? 0n;
      totals.set(addr, prev + amount);
    }
  }
  return { ordered, totals };
}

let seedPlayerCursor = 0;

function extractMintedTokenIds(receipt, playerAddress, nft) {
  const tokenIds = [];
  const normalized = playerAddress.toLowerCase();
  const nftAddress = (nft.target ?? nft.address ?? "").toLowerCase();
  if (!nftAddress) {
    return tokenIds;
  }
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== nftAddress) {
      continue;
    }
    let parsed;
    try {
      parsed = nft.interface.parseLog(log);
    } catch {
      continue;
    }
    if (!parsed || parsed.name !== "Transfer") continue;
    const from = parsed.args.from?.toLowerCase?.() ?? "";
    const to = parsed.args.to?.toLowerCase?.() ?? "";
    if (from === ethers.ZeroAddress.toLowerCase() && to === normalized) {
      tokenIds.push(Number(parsed.args.tokenId));
    }
  }
  return tokenIds;
}

async function seedContractWithMaps(
  purgeGame,
  purgeNFT,
  players,
  targetWei,
  mapQty = 200,
  referralCodes = new Map(),
  mintLevel,
  options = {}
) {
  if (players.length === 0) throw new Error("No players available for seeding");
  const provider = ethers.provider;
  const gameAddress = await purgeGame.getAddress();
  const contributions = new Map();
  const stats = { buyers: 0, quantity: 0n, totalCost: 0n };
  const exactAmount = options.exactAmount ?? false;
  const vrf = options.vrf;
  const vrfConsumer = options.vrfConsumer ?? gameAddress;

  let levelTarget = mintLevel;
  if (levelTarget === undefined) {
    levelTarget = Number(await purgeGame.level());
  }

  let iterations = 0;
  const iterationCap = players.length * 50;
  const startCursor = seedPlayerCursor % players.length;
  let buyersUsed = 0;
  let lastBalance = await provider.getBalance(gameAddress);
  while (true) {
    const currentBalance = await provider.getBalance(gameAddress);
    lastBalance = currentBalance;
    if (!exactAmount && currentBalance >= targetWei) {
      break;
    }
    if (exactAmount && stats.totalCost >= targetWei) {
      break;
    }
    if (iterations >= iterationCap) {
      throw new Error(
        `Failed to seed ${ethers.formatEther(targetWei)} ETH into the game contract (current ${ethers.formatEther(currentBalance)} ETH)`
      );
    }

    const playerIndex = (startCursor + buyersUsed) % players.length;
    const player = players[playerIndex];
    iterations += 1;
    buyersUsed += 1;
    const info = await purgeGame.gameInfo();
    const currentPrice = info.price_;
    const mapCost = (currentPrice * BigInt(mapQty) * 25n) / 100n;
    const affiliateCode = referralCodes.get(player.address) ?? ethers.ZeroHash;
    let minted = false;
    while (!minted) {
      try {
        await (
          await purgeNFT.connect(player).mintAndPurge(mapQty, false, affiliateCode, {
            value: mapCost,
          })
        ).wait();
        minted = true;
      } catch (err) {
        if (isCustomError(err, "RngNotReady")) {
          await fulfillPendingVrfRequest(vrf, vrfConsumer);
          await time.increase(5);
          continue;
        }
        throw err;
      }
    }
    const prev = contributions.get(player.address) ?? 0n;
    contributions.set(player.address, prev + mapCost);
    addLevelContribution(levelTarget, player.address, mapCost);
    stats.buyers += 1;
    stats.quantity += BigInt(mapQty);
    stats.totalCost += mapCost;
    await recordEarlyPurgeMint(purgeGame, levelTarget, mapQty);
  }
  seedPlayerCursor = (startCursor + buyersUsed) % players.length;
  return { balance: lastBalance, contributions, stats };
}

function mergeContributionMaps(target, additions) {
  for (const [address, value] of additions.entries()) {
    const prev = target.get(address) ?? 0n;
    target.set(address, prev + value);
  }
}

const levelContributions = new Map();
const questStakeOffsets = new Map();

function addLevelContribution(level, player, amount) {
  if (!levelContributions.has(level)) {
    levelContributions.set(level, new Map());
  }
  const ledger = levelContributions.get(level);
  const prev = ledger.get(player) ?? 0n;
  ledger.set(player, prev + amount);
}

const MAP_BUCKET_SHARE_BPS = [6000n, 1333n, 1333n, 1334n];
const BUCKET_TOLERANCE_WEI = 1000n;

function mapBucketCounts(level, rngWord) {
  const band = Math.floor((level % 100) / 20) + 1;
  const base = [25 * band, 15 * band, 10 * band, 1];
  const offset = Number(rngWord & 0x3n) & 3;
  const counts = [];
  for (let i = 0; i < 4; i += 1) {
    counts.push(base[(i + offset) & 3]);
  }
  return counts;
}

function bucketShareSlices(totalWei, bucketOffset = 0) {
  const slices = [];
  let distributed = 0n;
  for (let i = 0; i < MAP_BUCKET_SHARE_BPS.length; i += 1) {
    if (i === MAP_BUCKET_SHARE_BPS.length - 1) {
      slices.push(totalWei - distributed);
    } else {
      const shareIndex = (i + bucketOffset + 1) & 3;
      const slice = (totalWei * MAP_BUCKET_SHARE_BPS[shareIndex]) / 10000n;
      slices.push(slice);
      distributed += slice;
    }
  }
  return slices;
}

function isCustomError(err, name) {
  if (!err) return false;
  const fields = [err.shortMessage, err.message, err.reason];
  return fields.filter(Boolean).some((msg) => msg.includes(name));
}

const ADVANCE_GAME_CAP = 1500;
let lastAdvanceTimestamp = null;
let lastFulfilledVrfRequest = 0n;

async function fulfillPendingVrfRequest(vrf, consumer) {
  if (!vrf || !consumer) return;
  const requestId = await vrf.lastRequestId();
  if (!requestId || requestId === 0n || requestId === lastFulfilledVrfRequest) {
    return;
  }
  const word = randomJackpotWord(`vrf-${requestId.toString()}`);
  await (await vrf.fulfill(consumer, requestId, word)).wait();
  lastFulfilledVrfRequest = requestId;
}

async function ensureAdvanceWindow() {
  const block = await ethers.provider.getBlock("latest");
  let currentTs = Number(block.timestamp);
  if (lastAdvanceTimestamp === null || currentTs > lastAdvanceTimestamp) {
    lastAdvanceTimestamp = currentTs;
    return;
  }
  const deltaSeconds = lastAdvanceTimestamp - currentTs + DAY_SECONDS;
  await time.increase(deltaSeconds);
  const updated = await ethers.provider.getBlock("latest");
  lastAdvanceTimestamp = Number(updated.timestamp);
}

async function runAdvanceGameTick({
  purgeGame,
  vrf,
  vrfConsumer,
  operator,
  label,
  cap = ADVANCE_GAME_CAP,
  maxAttempts = 32,
}) {
  if (!purgeGame) {
    throw new Error("runAdvanceGameTick requires a purgeGame instance");
  }
  if (!operator) {
    throw new Error("runAdvanceGameTick requires an operator signer");
  }
  await ensureAdvanceWindow();
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    try {
      const tx = await purgeGame.connect(operator).advanceGame(cap);
      const receipt = await tx.wait();
      await fulfillPendingVrfRequest(vrf, vrfConsumer);
      return { receipt, attempt, label };
    } catch (err) {
      if (isCustomError(err, "NotTimeYet") || isCustomError(err, "RngNotReady")) {
        await time.increase(DAY_SECONDS);
        const updated = await ethers.provider.getBlock("latest");
        lastAdvanceTimestamp = Number(updated.timestamp);
        continue;
      }
      throw err;
    }
  }
  throw new Error(`advanceGame did not progress after ${maxAttempts} attempts${label ? ` (${label})` : ""}`);
}

async function ensurePurchasePhase(purgeGame, operator, targetLevel, maxIterations = 96, vrf, vrfConsumer) {
  for (let iteration = 0; iteration < maxIterations; iteration += 1) {
    const currentLevel = Number(await purgeGame.level());
    const info = await purgeGame.gameInfo();
    const stateValue = Number(info.gameState_);
    if (currentLevel >= targetLevel && stateValue === 2) {
      return;
    }
    await runAdvanceGameTick({
      purgeGame,
      vrf,
      vrfConsumer,
      operator,
      label: `prep-${targetLevel}-${iteration}`,
    });
  }
  throw new Error(`Failed to reach purchase state for level ${targetLevel}`);
}

async function advanceThroughPurchasePhase(purgeGame, operator, levelValue, maxIterations = 192, vrf, vrfConsumer) {
  const receipts = [];
  for (let iteration = 0; iteration < maxIterations; iteration += 1) {
    const info = await purgeGame.gameInfo();
    if (Number(info.gameState_) === 3) {
      break;
    }
    const { receipt } = await runAdvanceGameTick({
      purgeGame,
      vrf,
      vrfConsumer,
      operator,
      label: `purchase-${levelValue}-${iteration}`,
    });
    receipts.push(receipt);
  }
  const finalInfo = await purgeGame.gameInfo();
  if (Number(finalInfo.gameState_) !== 3) {
    throw new Error(`Level ${levelValue} did not transition to purge state`);
  }
  return { receipts, finalInfo };
}

async function snapshotClaimableEth(purgeGame, players) {
  const snapshot = new Map();
  for (const player of players) {
    const amount = await purgeGame.connect(player).getWinnings();
    snapshot.set(player.address, amount);
  }
  return snapshot;
}

function formatEth(value) {
  if (value === undefined) return "-";
  const numeric = Number(ethers.formatEther(value));
  const formatted = Number.isFinite(numeric) ? numeric.toFixed(2) : ethers.formatEther(value);
  return `${formatted} ETH`;
}

function formatCoin(value) {
  if (value === undefined) return "-";
  return `${ethers.formatUnits(value, 6)} PURGE`;
}

function shortenAddress(addr) {
  if (!addr || addr === ethers.ZeroAddress) return "unknown";
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}

async function snapshotCoinBalances(purgecoin, watchers) {
  const snapshot = new Map();
  for (const entry of watchers) {
    const [balance, flipStake, luckbox] = await Promise.all([
      purgecoin.balanceOf(entry.address),
      purgecoin.coinflipAmount(entry.address),
      purgecoin.playerLuckbox(entry.address),
    ]);
    snapshot.set(entry.label, { balance, flipStake, luckbox });
  }
  return snapshot;
}

async function snapshotPlayerCoinState(purgecoin, players) {
  const snapshot = new Map();
  for (const player of players) {
    const [balance, flipStake] = await Promise.all([
      purgecoin.balanceOf(player.address),
      purgecoin.coinflipAmount(player.address),
    ]);
    snapshot.set(player.address, { balance, flipStake });
  }
  return snapshot;
}

function coinStateTotal(entry) {
  if (!entry) return 0n;
  return entry.balance + entry.flipStake;
}

function createEarlyPurgeStageTotals() {
  return {
    preUnlock: { mints: 0, tokens: 0n },
    unlockWindow: { mints: 0, tokens: 0n },
    bonusWindow: { mints: 0, tokens: 0n },
  };
}

let earlyPurgeTracker = null;

function resetEarlyPurgeTracker() {
  earlyPurgeTracker = {
    totals: createEarlyPurgeStageTotals(),
    perLevel: new Map(),
  };
}

function classifyEarlyPurgeStage(percent) {
  if (percent < EARLY_PURGE_UNLOCK_THRESHOLD) return "preUnlock";
  if (percent < EARLY_PURGE_BONUS_THRESHOLD) return "unlockWindow";
  return "bonusWindow";
}

function ensureLevelStageTotals(level) {
  if (!earlyPurgeTracker) return null;
  if (!earlyPurgeTracker.perLevel.has(level)) {
    earlyPurgeTracker.perLevel.set(level, createEarlyPurgeStageTotals());
  }
  return earlyPurgeTracker.perLevel.get(level);
}

async function recordEarlyPurgeMint(purgeGame, level, quantity) {
  if (!earlyPurgeTracker) return;
  const percent = Number(await purgeGame.getEarlyPurgePercent());
  const stage = classifyEarlyPurgeStage(percent);
  const qty = BigInt(quantity);
  const totals = earlyPurgeTracker.totals[stage];
  totals.mints += 1;
  totals.tokens += qty;
  const levelTotals = ensureLevelStageTotals(level);
  if (levelTotals) {
    levelTotals[stage].mints += 1;
    levelTotals[stage].tokens += qty;
  }
}

function formatStageRows(stageTotals) {
  return [
    {
      stage: "Pre-unlock (<30%)",
      mints: stageTotals.preUnlock.mints,
      tokens: stageTotals.preUnlock.tokens.toString(),
    },
    {
      stage: "Unlock window (30-49%)",
      mints: stageTotals.unlockWindow.mints,
      tokens: stageTotals.unlockWindow.tokens.toString(),
    },
    {
      stage: "Bonus window (≥50%)",
      mints: stageTotals.bonusWindow.mints,
      tokens: stageTotals.bonusWindow.tokens.toString(),
    },
  ];
}

function reportEarlyPurgeMintStats() {
  if (!earlyPurgeTracker) return;
  console.log("Early purge mint distribution (overall)");
  console.table(formatStageRows(earlyPurgeTracker.totals));
  const levelRows = [];
  for (const [level, totals] of earlyPurgeTracker.perLevel.entries()) {
    levelRows.push({
      level,
      preUnlockMints: totals.preUnlock.mints,
      preUnlockTokens: totals.preUnlock.tokens.toString(),
      unlockMints: totals.unlockWindow.mints,
      unlockTokens: totals.unlockWindow.tokens.toString(),
      bonusMints: totals.bonusWindow.mints,
      bonusTokens: totals.bonusWindow.tokens.toString(),
    });
  }
  if (levelRows.length !== 0) {
    levelRows.sort((a, b) => a.level - b.level);
    console.log("Early purge mint distribution by level");
    console.table(levelRows);
  }
}

function totalEarlyPurgeMintCount() {
  if (!earlyPurgeTracker) return 0n;
  const totals = earlyPurgeTracker.totals;
  const totalTokens =
    totals.preUnlock.tokens + totals.unlockWindow.tokens + totals.bonusWindow.tokens;
  return totalTokens / 4n;
}

async function fulfillStageFunding({
  stageName,
  levelValue,
  fundingPlan,
  purgeGame,
  purgeNFT,
  players,
  contributions,
  referralCodes = new Map(),
  vrf,
  vrfConsumer,
}) {
  if (!fundingPlan.has(levelValue)) {
    return null;
  }
  const stageInfo = fundingPlan.get(levelValue)[stageName];
  if (!stageInfo) {
    return null;
  }
  const remaining = stageInfo.target - stageInfo.contributed;
  if (remaining <= 0n) {
    return null;
  }
  const { contributions: stageContribs, stats } = await seedContractWithMaps(
    purgeGame,
    purgeNFT,
    players,
    remaining,
    undefined,
    referralCodes,
    levelValue,
    { exactAmount: true, vrf, vrfConsumer }
  );
  mergeContributionMaps(contributions, stageContribs);
  if (stats.totalCost === 0n) {
    return stats;
  }
  stageInfo.contributed += stats.totalCost;
  console.log(
    `Level ${levelValue} ${stageName} funding contributed ${formatEth(stats.totalCost)} / ${formatEth(stageInfo.target)}`
  );
  return stats;
}
function reportEthFlow(entries) {
  const comparable = [];
  const expectedOnly = [];
  for (const entry of entries) {
    if (entry.actual === undefined) {
      expectedOnly.push({
        bucket: entry.bucket,
        expected: formatEth(entry.expected),
      });
    } else {
      comparable.push({
        bucket: entry.bucket,
        expected: formatEth(entry.expected),
        actual: formatEth(entry.actual),
      });
    }
  }
  if (comparable.length !== 0) {
    console.table(comparable);
  }
  if (expectedOnly.length !== 0) {
    console.log("Expected-only buckets");
    console.table(expectedOnly);
  }
}

function reportCoinFlows(before, after, totalSupplyBefore, totalSupplyAfter, heading) {
  if (heading) {
    console.log(heading);
  }
  const rows = [];
  for (const [bucket, beforeValue] of before.entries()) {
    const afterValue = after.get(bucket) ?? { balance: 0n, flipStake: 0n, luckbox: 0n };
    rows.push({
      bucket,
      erc20Before: formatCoin(beforeValue.balance),
      erc20After: formatCoin(afterValue.balance),
      erc20Delta: formatCoin(afterValue.balance - beforeValue.balance),
      flipBefore: formatCoin(beforeValue.flipStake),
      flipAfter: formatCoin(afterValue.flipStake),
      flipDelta: formatCoin(afterValue.flipStake - beforeValue.flipStake),
      luckboxBefore: formatCoin(beforeValue.luckbox),
      luckboxAfter: formatCoin(afterValue.luckbox),
      luckboxDelta: formatCoin(afterValue.luckbox - beforeValue.luckbox),
    });
  }
  rows.push({
    bucket: "Total Supply",
    erc20Before: formatCoin(totalSupplyBefore),
    erc20After: formatCoin(totalSupplyAfter),
    erc20Delta: formatCoin(totalSupplyAfter - totalSupplyBefore),
    flipBefore: "-",
    flipAfter: "-",
    flipDelta: "-",
    luckboxBefore: "-",
    luckboxAfter: "-",
    luckboxDelta: "-",
  });
  console.table(rows);
}

function reportTopNetResults(label, rows, limit = 5) {
  const winners = rows
    .filter((row) => row.netWei > 0n)
    .sort((a, b) => (a.netWei < b.netWei ? 1 : -1))
    .slice(0, limit);
  const losers = rows
    .filter((row) => row.netWei < 0n)
    .sort((a, b) => (a.netWei > b.netWei ? 1 : -1))
    .slice(0, limit);

  const project = (list) =>
    list.map((row) => ({
      address: row.address,
      spent: row.spent,
      winnings: row.winnings,
      coinAwarded: row.coinAwarded ?? "-",
      net: row.net,
    }));

  if (winners.length !== 0) {
    console.log(`${label} top ${winners.length} winners`);
    console.table(project(winners));
  } else {
    console.log(`${label} top winners: none`);
  }

  if (losers.length !== 0) {
    console.log(`${label} top ${losers.length} losers`);
    console.table(project(losers));
  } else {
    console.log(`${label} top losers: none`);
  }
}

function withdrawableAmount(amount) {
  if (!amount || amount <= 1n) {
    return 0n;
  }
  return amount - 1n;
}

function totalContributions(contributions) {
  let total = 0n;
  for (const value of contributions.values()) {
    total += value;
  }
  return total;
}

function totalRealized(realized) {
  let total = 0n;
  for (const value of realized.values()) {
    total += value;
  }
  return total;
}

async function sumClaimable(purgeGame, players) {
  if (!players || players.length === 0) {
    return 0n;
  }
  const amounts = await Promise.all(players.map((player) => purgeGame.connect(player).getWinnings()));
  return amounts.reduce((sum, amount) => sum + withdrawableAmount(amount), 0n);
}

async function snapshotMoneyBuckets(label, context) {
  const {
    purgeGame,
    purgeTrophies,
    purgeGameAddress,
    purgeTrophiesAddress,
    players,
    contributions,
    realizedWinnings,
  } = context;

  const info = await purgeGame.gameInfo();
  const [gameBalance, trophyBalance, claimableTotal] = await Promise.all([
    ethers.provider.getBalance(purgeGameAddress),
    ethers.provider.getBalance(purgeTrophiesAddress),
    sumClaimable(purgeGame, players),
  ]);

  const trackedGame = info.carry_ + info.prizePoolCurrent + claimableTotal;
  const inferredNext = gameBalance >= trackedGame ? gameBalance - trackedGame : 0n;
  const bucketShortfall = trackedGame > gameBalance ? trackedGame - gameBalance : 0n;
  const trackedTotal = gameBalance + trophyBalance;
  const contributionsTotal = totalContributions(contributions);
  const payoutsTotal = totalRealized(realizedWinnings);
  const expectedTotal = INITIAL_CARRYOVER_WEI + contributionsTotal - payoutsTotal;

  const bucketRows = [
    { bucket: "Carryover", amount: info.carry_ },
    { bucket: "Prize pool", amount: info.prizePoolCurrent },
    { bucket: "Claimable winnings", amount: claimableTotal },
  ];
  if (inferredNext !== 0n) {
    bucketRows.push({ bucket: "Next / pending pools", amount: inferredNext });
  }
  bucketRows.push({ bucket: "Held by trophies", amount: trophyBalance });

  console.log(`${label} bucket snapshot`);
  console.table(
    bucketRows.map((row) => ({
      bucket: row.bucket,
      amount: formatEth(row.amount),
    }))
  );
  if (payoutsTotal !== 0n) {
    console.log(`Total claimed so far: ${formatEth(payoutsTotal)}`);
  }

  const totalDelta = expectedTotal - trackedTotal;
  console.log(
    `Tracked game balance: ${formatEth(gameBalance)} (${formatEth(trackedGame)} tracked + ${formatEth(
      inferredNext
    )} pending, shortfall ${formatEth(bucketShortfall)})`
  );
  console.log(
    `Total inflow vs tracked: ${formatEth(expectedTotal)} vs ${formatEth(trackedTotal)} (Δ ${formatEth(totalDelta)})`
  );

  const inflowDeltaAbs = totalDelta >= 0n ? totalDelta : -totalDelta;
  if (inflowDeltaAbs > BUCKET_TOLERANCE_WEI) {
    console.warn(
      `${label} inflow reconciliation mismatch ${formatEth(totalDelta)} (expected inflow ${formatEth(
        expectedTotal
      )} vs tracked ${formatEth(trackedTotal)})`
    );
  }
}

async function claimPlayerWinnings(purgeGame, players, realized) {
  let claimedTotal = 0n;
  let claimantCount = 0;
  const perPlayer = new Map();
  for (const player of players) {
    const amount = await purgeGame.connect(player).getWinnings();
    if (amount > 1n) {
      const withdrawable = amount - 1n;
      await (await purgeGame.connect(player).claimWinnings()).wait();
      const prev = realized.get(player.address) ?? 0n;
      realized.set(player.address, prev + withdrawable);
      perPlayer.set(player.address, withdrawable);
      claimedTotal += withdrawable;
      claimantCount += 1;
    }
  }
  return { claimedTotal, claimantCount, perPlayer };
}

async function completeDailyQuests({
  purgecoin,
  purgeNFT,
  purgeGame,
  questPlayers,
  referralCodes,
  playerAffiliateCodes,
  contributions,
  mintCountLedger,
  questTargetLevel,
  coinBank,
  vrf,
  vrfConsumer,
  questMintOverrides,
  questAffiliateSupporters,
}) {
  if (!questPlayers || questPlayers.length === 0) {
    return;
  }
  const quests = await purgecoin.getActiveQuests();
  for (let slot = 0; slot < quests.length; slot += 1) {
    const quest = quests[slot];
    if (!quest || quest.day === 0n) continue;
    for (const player of questPlayers) {
      await ensureQuestSlotComplete(
        {
          purgecoin,
          purgeNFT,
          purgeGame,
          referralCodes,
          playerAffiliateCodes,
          contributions,
          mintCountLedger,
          questTargetLevel,
          coinBank,
          vrf,
          vrfConsumer,
          questMintOverrides,
          questAffiliateSupporters,
        },
        player,
        quest,
        slot
      );
    }
  }
}

async function ensureQuestSlotComplete(context, player, quest, slot) {
  const { purgecoin } = context;
  const [, , , completed] = await purgecoin.playerQuestStates(player.address);
  if (completed[slot]) {
    return;
  }
  await performQuestAction(context, player, quest, slot);
}

async function performQuestAction(context, player, quest, slot) {
  const {
    purgecoin,
    purgeNFT,
    purgeGame,
    referralCodes,
    playerAffiliateCodes,
    contributions,
    mintCountLedger,
    questTargetLevel,
    coinBank,
    vrf,
    vrfConsumer,
    questMintOverrides,
    questAffiliateSupporters,
  } = context;
  const questType = Number(quest.questType);
  switch (questType) {
    case QUEST_TYPES.MINT_ANY: {
      await performQuestCoinMint({
        purgeNFT,
        purgeGame,
        purgecoin,
        player,
        referralCodes,
        playerAffiliateCodes,
        coinBank,
        quantity: QUEST_COMPLETION_PARAMS.mintQuantity,
        contributions,
        targetLevel: questTargetLevel,
        mintCountLedger,
        slot,
        vrf,
        vrfConsumer,
        questMintOverrides,
        questAffiliateSupporters,
      });
      break;
    }
    case QUEST_TYPES.MINT_ETH:
      await performQuestEthMint({
        purgecoin,
        player,
        purgeNFT,
        purgeGame,
        contributions,
        referralCodes,
        playerAffiliateCodes,
        targetLevel: questTargetLevel,
        mintCountLedger,
        quantity: QUEST_COMPLETION_PARAMS.mintQuantity,
        slot,
        vrf,
        vrfConsumer,
        questMintOverrides,
        questAffiliateSupporters,
      });
      break;
    case QUEST_TYPES.FLIP:
      await performQuestFlip(context, player, slot);
      break;
    case QUEST_TYPES.STAKE:
      await performQuestStake(context, player, quest, slot);
      break;
    case QUEST_TYPES.AFFILIATE:
      await performQuestAffiliate(context, player, slot);
      break;
    case QUEST_TYPES.PURGE:
      await performQuestPurge(context, player, slot);
      break;
    case QUEST_TYPES.DECIMATOR:
      await performQuestDecimator(context, player, slot);
      break;
    default:
      break;
  }
}

async function ensureCoinBalance(purgecoin, funder, player, requiredAmount) {
  if (!requiredAmount || requiredAmount === 0n) {
    return;
  }
  const current = await purgecoin.balanceOf(player.address);
  if (current >= requiredAmount) {
    return;
  }
  const delta = requiredAmount - current;
  await (await purgecoin.connect(funder).transfer(player.address, delta)).wait();
}

async function prefundPlayersWithCoin(purgecoin, funder, players, amount) {
  if (!players || players.length === 0) {
    return;
  }
  if (!amount || amount === 0n) {
    return;
  }
  for (const player of players) {
    await (await purgecoin.connect(funder).transfer(player.address, amount)).wait();
  }
}

function buildQuestReferralPlan(questPlayers, referralCodes) {
  const plan = {
    mintOverrides: new Map(),
    affiliateSupporters: new Map(),
  };
  if (!questPlayers || questPlayers.length === 0) {
    return plan;
  }
  const filtered = questPlayers.filter(Boolean);
  if (filtered.length < 2) {
    return plan;
  }
  for (let i = 0; i < filtered.length; i += 1) {
    const supporter = filtered[i];
    const beneficiary = filtered[(i + 1) % filtered.length];
    if (beneficiary?.address) {
      plan.affiliateSupporters.set(beneficiary.address, supporter);
      const code = referralCodes?.get(beneficiary.address);
      if (code) {
        plan.mintOverrides.set(supporter.address, code);
      }
    }
  }
  return plan;
}

async function performQuestCoinMint({
  purgeNFT,
  purgeGame,
  purgecoin,
  player,
  referralCodes,
  playerAffiliateCodes,
  coinBank,
  quantity,
  contributions,
  targetLevel,
  mintCountLedger,
  slot,
  vrf,
  vrfConsumer,
  questMintOverrides,
  questAffiliateSupporters,
}) {
  const info = await purgeGame.gameInfo();
  const stateValue = typeof info.gameState_ === "bigint" ? Number(info.gameState_) : Number(info.gameState_);
  let mintLevelValue = Number(await purgeGame.level());
  if (stateValue === 3) {
    mintLevelValue += 1;
  }
  const coinUnlocked = await purgeGame.coinMintUnlock(mintLevelValue);
  if (!coinUnlocked) {
    await performQuestEthMint({
      purgecoin,
      player,
      purgeNFT,
      purgeGame,
      contributions,
      referralCodes,
      playerAffiliateCodes,
      targetLevel,
      mintCountLedger,
      quantity,
      slot,
      vrf,
      vrfConsumer,
      questMintOverrides,
      questAffiliateSupporters,
    });
    return;
  }
  const priceUnit = await purgeGame.coinPriceUnit();
  const baseCost = BigInt(quantity) * (priceUnit / 4n);
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    await ensureCoinBalance(purgecoin, coinBank, player, baseCost);
    const affiliateCode = referralCodes.get(player.address) ?? ethers.ZeroHash;
    try {
      await (await purgeNFT.connect(player).mintAndPurge(quantity, true, affiliateCode)).wait();
    } catch (err) {
      if (isCustomError(err, "RngNotReady")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(5);
        continue;
      }
      throw err;
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`Coin quest mint did not complete for ${player.address}`);
}

async function performQuestEthMint({
  purgecoin,
  player,
  purgeNFT,
  purgeGame,
  contributions,
  referralCodes,
  targetLevel,
  mintCountLedger,
  quantity,
  slot,
  vrf,
  vrfConsumer,
  questMintOverrides,
}) {
  const affiliateOverride = questMintOverrides?.get(player.address);
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    try {
      await executeStrategyMint({
        player,
        quantity,
        targetLevel,
        purgeNFT,
        purgeGame,
        contributions,
        referralCodes,
        affiliateOverride,
      });
    } catch (err) {
      if (isCustomError(err, "RngNotReady")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(5);
        continue;
      }
      throw err;
    }
    if (mintCountLedger) {
      const prev = mintCountLedger.get(player.address) ?? 0n;
      mintCountLedger.set(player.address, prev + BigInt(quantity));
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`ETH quest mint did not complete for ${player.address}`);
}

async function performQuestFlip(context, player, slot) {
  const { purgecoin, coinBank, vrf, vrfConsumer, purgeGame } = context;
  const amount = QUEST_COMPLETION_PARAMS.flipAmount;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    await ensureCoinBalance(purgecoin, coinBank, player, amount);
    if (await purgeGame.rngLocked()) {
      await fulfillPendingVrfRequest(vrf, vrfConsumer);
      await time.increase(5);
      continue;
    }
    try {
      await (await purgecoin.connect(player).depositCoinflip(amount)).wait();
    } catch (err) {
      if (err?.shortMessage?.includes("BettingPaused")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(60);
        continue;
      }
      throw err;
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`Flip quest did not complete for ${player.address}`);
}

async function performQuestStake(context, player, quest, slot) {
  const { purgecoin, coinBank, questTargetLevel, vrf, vrfConsumer, purgeGame } = context;
  const principal = QUEST_COMPLETION_PARAMS.stakePrincipal;
  const mask = Number(quest.stakeMask ?? 0);
  const distanceTarget = QUEST_COMPLETION_PARAMS.stakeDistance;
  const baseRisk =
    (mask & QUEST_STAKE_REQUIRE_RISK) !== 0
      ? Math.max(Number(quest.stakeRisk), QUEST_COMPLETION_PARAMS.stakeRisk)
      : QUEST_COMPLETION_PARAMS.stakeRisk;
  const contractMaxRisk = 11;
  let stakeOffset = questStakeOffsets.get(player.address) ?? 0;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    const info = await purgeGame.gameInfo();
    const currentLevel = Number(await purgeGame.level());
    const gameStateValue = Number(info.gameState_ ?? info.gameState ?? 0);
    let effectiveLevel = currentLevel;
    if (gameStateValue !== 3) {
      effectiveLevel = currentLevel === 0 ? 0 : currentLevel - 1;
    }
    let targetLevel = questTargetLevel + distanceTarget + stakeOffset;
    if (targetLevel <= effectiveLevel) {
      targetLevel = effectiveLevel + distanceTarget;
    }
    if (targetLevel > effectiveLevel + 500) {
      targetLevel = effectiveLevel + 500;
    }
    let riskValue = baseRisk > contractMaxRisk ? contractMaxRisk : baseRisk;
    const maxRiskForTarget = targetLevel + 1 - effectiveLevel;
    if (maxRiskForTarget <= 0) {
      await time.increase(DAY_SECONDS);
      continue;
    }
    if (riskValue > maxRiskForTarget) {
      riskValue = maxRiskForTarget;
    }
    if (riskValue <= 0) {
      riskValue = 1;
    }
    const attemptTarget = targetLevel;
    const attemptRisk = riskValue;
    const attemptEffective = effectiveLevel;
    const attemptMaxRisk = maxRiskForTarget;
    await ensureCoinBalance(purgecoin, coinBank, player, principal);
    try {
      await (await purgecoin.connect(player).stake(principal, targetLevel, riskValue)).wait();
    } catch (err) {
      if (isCustomError(err, "StakeInvalid")) {
        stakeOffset += distanceTarget;
        await time.increase(DAY_SECONDS);
        continue;
      }
      if (isCustomError(err, "BettingPaused")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(5);
        continue;
      }
      if (isCustomError(err, "Insufficient")) {
        console.warn(
          `Stake quest insufficient for ${player.address}: target ${attemptTarget}, effective ${attemptEffective}, maxRisk ${attemptMaxRisk}, risk ${attemptRisk}`
        );
      }
      throw err;
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`Stake quest did not complete for ${player.address}`);
}

async function performQuestAffiliate(context, player, slot) {
  const {
    purgecoin,
    purgeNFT,
    purgeGame,
    contributions,
    referralCodes,
    playerAffiliateCodes,
    questTargetLevel,
    coinBank,
    vrf,
    vrfConsumer,
    mintCountLedger,
    questAffiliateSupporters,
  } = context;
  const code = playerAffiliateCodes?.get(player.address) ?? referralCodes.get(player.address);
  if (!code) {
    return;
  }
  const helper = questAffiliateSupporters?.get(player.address) ?? coinBank;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    try {
      await executeStrategyMint({
        player: helper,
        quantity: QUEST_COMPLETION_PARAMS.mintQuantity,
        targetLevel: questTargetLevel,
        purgeNFT,
        purgeGame,
        contributions,
        referralCodes,
        affiliateOverride: code,
      });
    } catch (err) {
      if (isCustomError(err, "RngNotReady")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(5);
        continue;
      }
      throw err;
    }
    if (mintCountLedger && helper?.address) {
      const prev = mintCountLedger.get(helper.address) ?? 0n;
      mintCountLedger.set(helper.address, prev + BigInt(QUEST_COMPLETION_PARAMS.mintQuantity));
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`Affiliate quest did not complete for ${player.address}`);
}

async function performQuestPurge(context, player, slot) {
  const { purgecoin, purgeNFT, purgeGame, referralCodes, contributions, vrf, vrfConsumer } = context;
  const quantity = QUEST_COMPLETION_PARAMS.purgeQuantity;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    const info = await purgeGame.gameInfo();
    const stateValue = Number(info.gameState_ ?? info.gameState ?? 0);
    if (stateValue !== 3) {
      await time.increase(DAY_SECONDS);
      continue;
    }
    const levelValue = Number(await purgeGame.level());
    const targetLevel = levelValue + 1;
    const price = info.price_;
    const cost = price * BigInt(quantity);
    const affiliateCode = referralCodes.get(player.address) ?? ethers.ZeroHash;
    let receipt;
    try {
      const purchaseTx = await purgeNFT.connect(player).purchase(quantity, false, affiliateCode, {
        value: cost,
      });
      receipt = await purchaseTx.wait();
    } catch (err) {
      if (isCustomError(err, "RngNotReady")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(5);
        continue;
      }
      await time.increase(DAY_SECONDS);
      continue;
    }
    const tokenIds = extractMintedTokenIds(receipt, player.address, purgeNFT);
    if (tokenIds.length === 0) {
      continue;
    }
    const prevSpent = contributions.get(player.address) ?? 0n;
    contributions.set(player.address, prevSpent + cost);
    addLevelContribution(targetLevel, player.address, cost);
    try {
      await (await purgeGame.connect(player).purge(tokenIds)).wait();
    } catch (err) {
      if (isCustomError(err, "NotTimeYet") || isCustomError(err, "RngNotReady")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(DAY_SECONDS);
        continue;
      }
      throw err;
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`Purge quest did not complete for ${player.address}`);
}

async function performQuestDecimator(context, player, slot) {
  const { purgecoin, coinBank } = context;
  const amount = QUEST_COMPLETION_PARAMS.decimatorAmount;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    await ensureCoinBalance(purgecoin, coinBank, player, amount);
    try {
      await (await purgecoin.connect(player).decimatorBurn(amount)).wait();
    } catch (err) {
      if (err?.shortMessage?.includes("NotDecimatorWindow")) {
        await time.increase(DAY_SECONDS);
        continue;
      }
      throw err;
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`Decimator quest for ${player.address} could not complete (window unavailable)`);
}

describe("PurgeGame money flow simulation", function () {
  this.timeout(0);

  it("runs levels 1-5 money flow end to end", async function () {
    const [primaryFunder, secondaryFunder] = await ethers.getSigners();
    const firstBatch = await createWallets(50, primaryFunder, ethers.parseEther("50"));
    const secondBatch = await createWallets(50, secondaryFunder, ethers.parseEther("50"));
    const state3MapOnlyPlayers = await createWallets(25, primaryFunder, ethers.parseEther("50"));
    const questStrategyPlayers = await createWallets(25, secondaryFunder, ethers.parseEther("50"));
    const noBonusPlayers = await createWallets(
      NO_BONUS_STRATEGY.playerCount,
      primaryFunder,
      ethers.parseEther("50")
    );
    const basePlayers = [...firstBatch, ...secondBatch];
    const strategyPlayers = [...state3MapOnlyPlayers, ...questStrategyPlayers];
    const players = [...basePlayers, ...strategyPlayers, ...noBonusPlayers];
    const stageFundingPlayers = basePlayers;
    const questCompleterPlayers = questStrategyPlayers;
    const state3MapPlayers = [...state3MapOnlyPlayers, ...questStrategyPlayers];
    const noBonusStrategyPlayers = noBonusPlayers;
    const stakingPlayers = basePlayers.slice(0, Math.min(STAKE_STRATEGY.playerCount, basePlayers.length));
    const groupDefinitions = [
      { label: "Map-only strategy", players: state3MapOnlyPlayers },
      { label: "Quest strategy", players: questStrategyPlayers },
      { label: "No-bonus strategy", players: noBonusStrategyPlayers },
    ];

    const system = await deploySystem();
    const { purgeGame, purgeNFT, purgeTrophies, purgecoin, deployer, vrf } = system;
    await purgecoin.connect(deployer).setQuestPurgeEnabled(false);
    const advanceOperator = primaryFunder;
    const purgeGameAddress = await purgeGame.getAddress();
    const purgeTrophiesAddress = await purgeTrophies.getAddress();

    const { referralAssignments, referralCodes } = await configureReferralChain(purgecoin, players, {
      minBatch: 1,
      maxBatch: 10,
      roundRobinGroups: [questCompleterPlayers],
    });

    const { mintOverrides: questMintOverrides, affiliateSupporters: questAffiliateSupporters } =
      buildQuestReferralPlan(questCompleterPlayers, referralCodes);

    const priceCoinUnit = await purgeGame.coinPriceUnit();

    await prefundPlayersWithCoin(purgecoin, deployer, questCompleterPlayers, QUEST_PREFUND_COINS);

    const targetPerLevel = [];
    let currentTarget = MAP_PURCHASE_TARGET_WEI;
    for (let i = 0; i < LEVEL_COUNT; i += 1) {
      targetPerLevel.push(currentTarget);
      currentTarget = (currentTarget * 110n) / 100n;
    }

    const stageFundingPlan = new Map();
    for (let i = 0; i < LEVEL_COUNT; i += 1) {
      const levelValue = i + 1;
      const total = targetPerLevel[i];
      const priorPurgeTarget = (total * 30n) / 100n;
      const day1Target = (total * 20n) / 100n;
      const day2Target = total - priorPurgeTarget - day1Target;
      stageFundingPlan.set(levelValue, {
        priorPurge: { target: priorPurgeTarget, contributed: 0n },
        day1: { target: day1Target, contributed: 0n },
        day2: { target: day2Target, contributed: 0n },
      });
    }
    const nextLevelValue = LEVEL_COUNT + 1;
    const nextLevelTotal = currentTarget;
    stageFundingPlan.set(nextLevelValue, {
      priorPurge: { target: (nextLevelTotal * 30n) / 100n, contributed: 0n },
      day1: { target: (nextLevelTotal * 20n) / 100n, contributed: 0n },
      day2: { target: nextLevelTotal - ((nextLevelTotal * 30n) / 100n) - ((nextLevelTotal * 20n) / 100n), contributed: 0n },
    });
    targetPerLevel.push(nextLevelTotal);

    const contributions = new Map();
    const strategyMintCounts = new Map();
    const noBonusExecutedLevels = new Set();
    const stakeEvents = [];
    const realizedWinnings = new Map();
    resetEarlyPurgeTracker();
    const initialCoinSnapshot = await snapshotPlayerCoinState(purgecoin, players);
    let coinSnapshotCursor = initialCoinSnapshot;
    const levelCoinAwardTotals = new Map();
    let totalCoinAwarded = 0n;
    const coinValueLedger = new Map();
    const bucketContext = {
      purgeGame,
      purgeTrophies,
      purgeGameAddress,
      purgeTrophiesAddress,
      players,
      contributions,
      realizedWinnings,
    };
    await (
      await primaryFunder.sendTransaction({
        to: purgeGameAddress,
        value: INITIAL_CARRYOVER_WEI,
      })
    ).wait();

    await fulfillStageFunding({
      stageName: "priorPurge",
      levelValue: 1,
      fundingPlan: stageFundingPlan,
      purgeGame,
      purgeNFT,
      players: stageFundingPlayers,
      contributions,
      referralCodes: referralAssignments,
      vrf,
      vrfConsumer: purgeGameAddress,
    });

    const levelDaySummaries = [];

    for (let levelIndex = 0; levelIndex < LEVEL_COUNT; levelIndex += 1) {
      const levelValue = levelIndex + 1;
      const levelCoinBefore = coinSnapshotCursor;
      const rng = createDeterministicRng(0x7777n + BigInt(levelValue));
      let levelCoinAwardTotal = 0n;

      await ensurePurchasePhase(purgeGame, advanceOperator, levelValue, 96, vrf, purgeGameAddress);
      const stakeEntries = await runStakeStrategies({
        purgecoin,
        purgeGame,
        players: stakingPlayers,
        strategy: STAKE_STRATEGY,
      });
      if (stakeEntries.length !== 0) {
        stakeEvents.push(...stakeEntries);
      }
      if (levelValue === 1 && state3MapPlayers.length !== 0) {
        await runStrategyMapPurchases({
          players: state3MapPlayers,
          purgeGame,
          purgeNFT,
          contributions,
          referralCodes: referralAssignments,
          targetLevel: levelValue,
          mintCountLedger: strategyMintCounts,
        });
      }

      await fulfillStageFunding({
        stageName: "day1",
        levelValue,
        fundingPlan: stageFundingPlan,
        purgeGame,
        purgeNFT,
        players: stageFundingPlayers,
        contributions,
        referralCodes: referralAssignments,
        vrf,
        vrfConsumer: purgeGameAddress,
      });

      await fulfillStageFunding({
        stageName: "day2",
        levelValue,
        fundingPlan: stageFundingPlan,
        purgeGame,
        purgeNFT,
        players: stageFundingPlayers,
        contributions,
        referralCodes: referralAssignments,
        vrf,
        vrfConsumer: purgeGameAddress,
      });

      const claimableBefore = await snapshotClaimableEth(purgeGame, players);

      let preInfo = await purgeGame.gameInfo();
      const desiredPrize = targetPerLevel[levelIndex];
      if (preInfo.prizePoolCurrent < desiredPrize) {
        const needed = desiredPrize - preInfo.prizePoolCurrent;
        const balanceBefore = await ethers.provider.getBalance(purgeGameAddress);
        const targetAbsolute = balanceBefore + needed;
        const seedResult = await seedContractWithMaps(
          purgeGame,
          purgeNFT,
          stageFundingPlayers,
          targetAbsolute,
          undefined,
          referralAssignments,
          levelValue,
          { vrf, vrfConsumer: purgeGameAddress }
        );
        mergeContributionMaps(contributions, seedResult.contributions);
        preInfo = await purgeGame.gameInfo();
      }
      expect(preInfo.prizePoolCurrent).to.be.gte(desiredPrize);
      const levelMintPriceWei = preInfo.price_;
      const totalPoolBefore = preInfo.carry_ + preInfo.prizePoolCurrent;
      const { receipts: mapAdvanceReceipts, finalInfo: mapFinalInfo } = await advanceThroughPurchasePhase(
        purgeGame,
        advanceOperator,
        levelValue,
        192,
        vrf,
        purgeGameAddress
      );

      const { ordered: orderedCredits, totals: creditTotals } = collectCredits(purgeGame, mapAdvanceReceipts);
      const creditedTotal = orderedCredits.reduce((sum, entry) => sum + entry.amount, 0n);
      const totalAfter = mapFinalInfo.carry_ + mapFinalInfo.prizePoolCurrent;
      const totalBeforeAfterFlow = preInfo.carry_ + preInfo.prizePoolCurrent;
      const recycledToPool = totalAfter > totalBeforeAfterFlow ? totalAfter - totalBeforeAfterFlow : 0n;

      console.log(`Level ${levelValue} map flow`);
      reportEthFlow([
        { bucket: "Carryover before jackpots", expected: preInfo.carry_, actual: preInfo.carry_ },
        { bucket: "Prize pool before jackpots", expected: preInfo.prizePoolCurrent, actual: preInfo.prizePoolCurrent },
        { bucket: "Carry saved for next level", expected: mapFinalInfo.carry_, actual: mapFinalInfo.carry_ },
        { bucket: "Prize pool after jackpots", expected: mapFinalInfo.prizePoolCurrent, actual: mapFinalInfo.prizePoolCurrent },
        { bucket: "Credited to participants", expected: creditedTotal, actual: creditedTotal },
        { bucket: "Recycled back to prize pool", expected: recycledToPool, actual: recycledToPool },
      ]);

      const topWinners = [...creditTotals.entries()]
        .sort((a, b) => (b[1] > a[1] ? 1 : -1))
        .slice(0, 10)
        .map(([address, amount]) => ({
          address: shortenAddress(address),
          winnings: formatEth(amount),
        }));
      console.log(`Level ${levelValue} top map winners`);
      console.table(topWinners);

      await snapshotMoneyBuckets(`Level ${levelValue} after map jackpot`, bucketContext);

      let pendingDailyMapActivity = { buyers: 0, quantity: 0n, totalCost: 0n };
      const noBonusStats = await runNoBonusMapStrategy({
        players: noBonusStrategyPlayers,
        purgeGame,
        purgeNFT,
        contributions,
        referralCodes: referralAssignments,
        targetLevel: levelValue,
        mintCountLedger: strategyMintCounts,
        executedLevels: noBonusExecutedLevels,
        strategy: NO_BONUS_STRATEGY,
      });
      pendingDailyMapActivity = accumulateDailyMapActivity(pendingDailyMapActivity, noBonusStats);
      const nextLevelValue = levelValue + 1;
      const strategyActivity = await runStrategyMapPurchases({
        players: state3MapPlayers,
        purgeGame,
        purgeNFT,
        contributions,
        referralCodes: referralAssignments,
        targetLevel: nextLevelValue,
        mintCountLedger: strategyMintCounts,
      });
      pendingDailyMapActivity = accumulateDailyMapActivity(pendingDailyMapActivity, strategyActivity);
      if (NEXT_LEVEL_DAY1_PREFUND_BPS !== 0n) {
        const nextLevelIndex = nextLevelValue - 1;
        const nextLevelTotal = nextLevelIndex < targetPerLevel.length ? targetPerLevel[nextLevelIndex] : 0n;
        if (nextLevelTotal !== 0n) {
          const dayOneWei = (nextLevelTotal * NEXT_LEVEL_DAY1_PREFUND_BPS) / 10000n;
          if (dayOneWei !== 0n) {
            const dayOneActivity = await primeNextLevelMaps({
              levelValue,
              purgeGame,
              purgeNFT,
              players: stageFundingPlayers,
              contributions,
              referralCodes: referralAssignments,
              stageFundingPlan,
              vrf,
              vrfConsumer: purgeGameAddress,
              absoluteWei: dayOneWei,
            });
            pendingDailyMapActivity = accumulateDailyMapActivity(pendingDailyMapActivity, dayOneActivity);
            if (dayOneActivity.totalCost !== 0n) {
              // map mints processed during advanceGame
            }
          }
        }
      }

      const daySummaries = [];
      let jackpotsExecuted = 0;
      while (true) {
        await time.increase(DAY_SECONDS);

        const dripActivity = await primeNextLevelMaps({
          levelValue,
          purgeGame,
          purgeNFT,
          players: stageFundingPlayers,
          contributions,
          referralCodes: referralAssignments,
          stageFundingPlan,
          vrf,
          vrfConsumer: purgeGameAddress,
          percentBps: NEXT_LEVEL_DAILY_PREFUND_BPS,
        });
        pendingDailyMapActivity = accumulateDailyMapActivity(pendingDailyMapActivity, dripActivity);

        const infoBefore = await purgeGame.gameInfo();
        if (Number(infoBefore.gameState_) !== 3) {
          break;
        }
        const counterBefore = Number(infoBefore.jackpotCounter_);
        const carryBefore = infoBefore.carry_;
        const prizePoolBefore = infoBefore.prizePoolCurrent;

        const pendingSnapshot = {
          buyers: pendingDailyMapActivity.buyers,
          quantity: pendingDailyMapActivity.quantity,
          totalCost: pendingDailyMapActivity.totalCost,
        };

        let infoAfter = infoBefore;
        let counterAfter = counterBefore;
        let paid = 0;
        for (let attempt = 0; attempt < 8; attempt += 1) {
          await runAdvanceGameTick({
            purgeGame,
            vrf,
            vrfConsumer: purgeGameAddress,
            operator: advanceOperator,
            label: `daily-${levelValue}-${daySummaries.length}-tick${attempt}`,
          });
          infoAfter = await purgeGame.gameInfo();
          counterAfter = Number(infoAfter.jackpotCounter_);
          paid = counterAfter - counterBefore;
          if (paid > 0) {
            break;
          }
          const stateChanged = Number(infoAfter.gameState_) !== 3;
          const counterReset = counterAfter < counterBefore;
          if (stateChanged || counterReset) {
            paid = JACKPOT_LEVEL_CAP - counterBefore;
            break;
          }
        }
        if (paid <= 0 && Number(infoAfter.gameState_) === 3 && counterAfter === counterBefore) {
          continue;
        }

        const dailyMapActivity = {
          buyers: pendingSnapshot.buyers,
          quantity: Number(pendingSnapshot.quantity),
          totalCost: pendingSnapshot.totalCost,
        };
        pendingDailyMapActivity = { buyers: 0, quantity: 0n, totalCost: 0n };

        const carryAfter = infoAfter.carry_;
        const prizePoolAfter = infoAfter.prizePoolCurrent;
        jackpotsExecuted += paid;
        const carryPaid = carryBefore > carryAfter ? carryBefore - carryAfter : 0n;
        const poolPaid = prizePoolBefore > prizePoolAfter ? prizePoolBefore - prizePoolAfter : 0n;
        daySummaries.push({
          level: levelValue,
          day: daySummaries.length + 1,
          jackpots: paid,
          carryBefore,
          carryAfter,
          prizePoolBefore,
          prizePoolAfter,
          carryPaid,
          poolPaid,
          totalPaid: carryPaid + poolPaid,
          mapBuyers: dailyMapActivity.buyers,
          mapQuantity: dailyMapActivity.quantity,
          mapSpent: dailyMapActivity.totalCost,
        });

        await completeDailyQuests({
          purgecoin,
          purgeNFT,
          purgeGame,
          questPlayers: questCompleterPlayers,
          referralCodes: referralAssignments,
          playerAffiliateCodes: referralCodes,
          contributions,
          mintCountLedger: strategyMintCounts,
          questTargetLevel: nextLevelValue,
          coinBank: deployer,
          vrf,
          vrfConsumer: purgeGameAddress,
          questMintOverrides,
          questAffiliateSupporters,
        });

        if (Number(infoAfter.gameState_) !== 3 || jackpotsExecuted >= JACKPOT_LEVEL_CAP) {
          break;
        }
      }

      expect(jackpotsExecuted).to.equal(JACKPOT_LEVEL_CAP);

      await ensurePurchasePhase(purgeGame, advanceOperator, levelValue + 1, 96, vrf, purgeGameAddress);
      const levelAfter = Number(await purgeGame.level());
      expect(levelAfter).to.equal(levelValue + 1);

      console.log(`Level ${levelValue} daily jackpots`);
      console.table(
        daySummaries.map((entry) => ({
          day: entry.day,
          jackpots: entry.jackpots,
          carryBefore: formatEth(entry.carryBefore),
          carryAfter: formatEth(entry.carryAfter),
          carryPaid: formatEth(entry.carryPaid),
          prizePoolBefore: formatEth(entry.prizePoolBefore),
          prizePoolAfter: formatEth(entry.prizePoolAfter),
          poolPaid: formatEth(entry.poolPaid),
          totalPaid: formatEth(entry.totalPaid),
          mapBuyers: entry.mapBuyers,
          mapQuantity: entry.mapQuantity,
          mapSpent: formatEth(entry.mapSpent),
        }))
      );
      levelDaySummaries.push(...daySummaries);

      await snapshotMoneyBuckets(`Level ${levelValue} after daily jackpots`, bucketContext);
      const claimStats = await claimPlayerWinnings(purgeGame, players, realizedWinnings);
      if (claimStats.claimantCount !== 0) {
        console.log(
          `Level ${levelValue} claims paid ${formatEth(claimStats.claimedTotal)} to ${claimStats.claimantCount} players`
        );
      } else {
        console.log(`Level ${levelValue} claims: no players had claimable ETH`);
      }
      await snapshotMoneyBuckets(`Level ${levelValue} after player claims`, bucketContext);
      await snapshotMoneyBuckets(`Level ${levelValue} after endgame settlement`, bucketContext);

      const levelCoinAfter = await snapshotPlayerCoinState(purgecoin, players);
      coinSnapshotCursor = levelCoinAfter;

      const claimableAfter = await snapshotClaimableEth(purgeGame, players);
      const levelSpend = levelContributions.get(levelValue) ?? new Map();
      let levelProfitables = 0;
      const levelRows = [];
      for (const player of players) {
        const addr = player.address;
        const spent = levelSpend.get(addr) ?? 0n;
        const before = claimableBefore.get(addr) ?? 0n;
        const after = claimableAfter.get(addr) ?? 0n;
        const claimedNow = claimStats.perPlayer.get(addr) ?? 0n;
        const winnings = claimedNow + (after - before);
        const coinAwardWei =
          coinStateTotal(levelCoinAfter.get(addr)) - coinStateTotal(levelCoinBefore.get(addr));
        const coinValueWei = coinMintValueWei(coinAwardWei, levelMintPriceWei, priceCoinUnit);
        const valuedNet = winnings + coinValueWei - spent;
        if (valuedNet > 0n) {
          levelProfitables += 1;
        }
        levelCoinAwardTotal += coinAwardWei;
        const prevCoinValue = coinValueLedger.get(addr) ?? 0n;
        coinValueLedger.set(addr, prevCoinValue + coinValueWei);
        levelRows.push({
          address: shortenAddress(addr),
          spent: formatEth(spent),
          winnings: formatEth(winnings),
          coinValue: formatEth(coinValueWei),
          net: formatEth(valuedNet),
          coinAwarded: formatCoin(coinAwardWei),
          netWei: valuedNet,
          coinAwardWei,
          coinValueWei,
        });
      }
      const levelProfitPercent = ((levelProfitables * 10000) / players.length) / 100;
      console.log(
        `Level ${levelValue} player profit: ${levelProfitables}/${players.length} (${levelProfitPercent.toFixed(
          2
        )}%)`
      );
      reportTopNetResults(`Level ${levelValue}`, levelRows);
      console.log(`Level ${levelValue} total coin minted: ${formatCoin(levelCoinAwardTotal)}`);
      levelCoinAwardTotals.set(levelValue, levelCoinAwardTotal);
      totalCoinAwarded += levelCoinAwardTotal;
    }

    const profitRows = [];
    const playerSummaries = new Map();
    let profitablePlayers = 0;
    let totalSpent = 0n;
    let totalWinnings = 0n;
    const finalCoinSnapshot = coinSnapshotCursor;

    for (const player of players) {
      const spent = contributions.get(player.address) ?? 0n;
      const outstanding = await purgeGame.connect(player).getWinnings();
      const outstandingNet = withdrawableAmount(outstanding);
      const realized = realizedWinnings.get(player.address) ?? 0n;
      const winnings = realized + outstandingNet;
      const coinValueWei = coinValueLedger.get(player.address) ?? 0n;
      const valuedNet = winnings + coinValueWei - spent;
      if (valuedNet > 0n) {
        profitablePlayers += 1;
      }
      totalSpent += spent;
      totalWinnings += winnings + coinValueWei;
      const coinAwardTotal =
        coinStateTotal(finalCoinSnapshot.get(player.address)) -
        coinStateTotal(initialCoinSnapshot.get(player.address));
      playerSummaries.set(player.address, {
        spent,
        ethWinnings: winnings,
        coinValueWei,
        totalValue: winnings + coinValueWei,
        netWei: valuedNet,
        coinAwardTotal,
      });
      profitRows.push({
        address: shortenAddress(player.address),
        spent: formatEth(spent),
        winnings: formatEth(winnings + coinValueWei),
        net: formatEth(valuedNet),
        coinAwarded: formatCoin(coinAwardTotal),
        coinValue: formatEth(coinValueWei),
        netWei: valuedNet,
        coinAwardWei: coinAwardTotal,
      });
    }

    const profitPercent = ((profitablePlayers * 10000) / players.length) / 100;
    console.log(
      `Players in profit: ${profitablePlayers}/${players.length} (${profitPercent.toFixed(
        2
      )}%), total spent ${formatEth(totalSpent)}, total winnings ${formatEth(totalWinnings)}`
    );
    const totalProfitWei = totalWinnings - totalSpent;
    let totalProfitPercent = 0;
    if (totalSpent !== 0n) {
      const pctTimes100 = (totalProfitWei * 10000n) / totalSpent;
      totalProfitPercent = Number(pctTimes100) / 100;
    }
    console.log(
      `Overall profitability vs spend: ${formatEth(totalProfitWei)} (${totalProfitPercent.toFixed(
        2
      )}%)`
    );
    reportTopNetResults("Simulation final standings", profitRows);
    if (levelCoinAwardTotals.size !== 0) {
      console.log("Coin minted per level");
      const coinRows = [];
      for (const [level, total] of levelCoinAwardTotals.entries()) {
        coinRows.push({ level, coinMinted: formatCoin(total) });
      }
      coinRows.sort((a, b) => a.level - b.level);
      console.table(coinRows);
      console.log(`Total coin minted across mints: ${formatCoin(totalCoinAwarded)}`);
      const totalMintEvents = totalEarlyPurgeMintCount();
      if (totalMintEvents > 0n) {
        const avgCoinPerMint = totalCoinAwarded / totalMintEvents;
        console.log(
          `Average coin per mint (${totalMintEvents.toString()} mints): ${formatCoin(avgCoinPerMint)}`
        );
      }
    }
    reportEarlyPurgeMintStats();
    if (stakeEvents.length !== 0) {
      let totalStakeBurned = 0n;
      const stakeRows = stakeEvents.map((entry) => {
        totalStakeBurned += entry.burnAmount;
        return {
          level: entry.level,
          targetLevel: entry.targetLevel,
          risk: entry.risk,
          burn: formatCoin(entry.burnAmount),
          player: shortenAddress(entry.player),
        };
      });
      console.log(
        `Stake strategy placed ${stakeEvents.length} stakes burning ${formatCoin(totalStakeBurned)} total`
      );
      console.table(stakeRows.slice(-10));
    }
    if (groupDefinitions.length !== 0) {
      const cohortRows = [];
      for (const group of groupDefinitions) {
        let groupSpent = 0n;
        let groupValue = 0n;
        let groupNet = 0n;
        let groupCoinAwarded = 0n;
        let groupMintCount = 0n;
        for (const player of group.players) {
          const summary = playerSummaries.get(player.address);
          if (!summary) continue;
          groupSpent += summary.spent;
          groupValue += summary.totalValue;
          groupNet += summary.netWei;
          groupCoinAwarded += summary.coinAwardTotal;
          groupMintCount += strategyMintCounts.get(player.address) ?? 0n;
        }
        const coinPerMint = groupMintCount === 0n ? 0n : groupCoinAwarded / groupMintCount;
        const playersDetailed = group.players
          .map((player) => {
            const summary = playerSummaries.get(player.address);
            if (!summary) return null;
            const questMints = strategyMintCounts.get(player.address) ?? 0n;
            return {
              address: player.address,
              netWei: summary.netWei,
              spent: summary.spent,
              totalValue: summary.totalValue,
              coinAwardTotal: summary.coinAwardTotal,
              questMints,
            };
          })
          .filter(Boolean);
        cohortRows.push({
          group: group.label,
          players: group.players.length,
          spent: formatEth(groupSpent),
          winnings: formatEth(groupValue),
          net: formatEth(groupNet),
          coinAwarded: formatCoin(groupCoinAwarded),
          mapsMinted: groupMintCount.toString(),
          coinPerMint: groupMintCount === 0n ? "-" : formatCoin(coinPerMint),
          playersDetailed,
        });
      }
      console.log("Strategy cohort profitability");
      console.table(
        cohortRows.map((row) => ({
          group: row.group,
          players: row.players,
          spent: row.spent,
          winnings: row.winnings,
          net: row.net,
          coinAwarded: row.coinAwarded,
          mapsMinted: row.mapsMinted,
          coinPerMint: row.coinPerMint,
        }))
      );
      for (const row of cohortRows) {
        if (!row.playersDetailed || row.playersDetailed.length === 0) continue;
        const sorted = [...row.playersDetailed].sort((a, b) => {
          if (a.netWei === b.netWei) return 0;
          return a.netWei < b.netWei ? 1 : -1;
        });
        const top = sorted.slice(0, 3);
        const bottom = sorted.slice(-3).reverse();
        console.log(`${row.group} top 3`);
        console.table(
          top.map((entry) => ({
            player: shortenAddress(entry.address),
            net: formatEth(entry.netWei),
            spent: formatEth(entry.spent),
            winnings: formatEth(entry.totalValue),
            coinAwarded: formatCoin(entry.coinAwardTotal),
            questMints: entry.questMints.toString(),
          }))
        );
        console.log(`${row.group} bottom 3`);
        console.table(
          bottom.map((entry) => ({
            player: shortenAddress(entry.address),
            net: formatEth(entry.netWei),
            spent: formatEth(entry.spent),
            winnings: formatEth(entry.totalValue),
            coinAwarded: formatCoin(entry.coinAwardTotal),
            questMints: entry.questMints.toString(),
          }))
        );
      }
    }

    await snapshotMoneyBuckets("Simulation complete", bucketContext);
  });
});
