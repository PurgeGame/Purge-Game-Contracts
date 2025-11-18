const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const abiCoder = ethers.AbiCoder.defaultAbiCoder();

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
    questModule,
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
const QUEST_SLOT_COUNT = 2;
const QUEST_TIER_STREAK_SPAN = 7;
const QUEST_TIER_MAX_INDEX = 10;
const QUEST_MIN_MINT = 1;
const QUEST_MIN_TOKEN = 250;
const QUEST_PACKED_VALUES = {
  mintAny: 0x0000000000000000000000080008000800080008000700060005000400030002n,
  mintEth: 0x0000000000000000000000050005000400040004000300030002000200020001n,
  flip: 0x0000000000000000000009c409c408fc076c060e04e203e80320028a01f40190n,
  stakePrincipal: 0x0000000000000000000009c409c40898072105dc04c903e8033902a3020d0190n,
  stakeDistanceMin: 0x00000000000000000000001900190019001900190019001900190014000f000an,
  stakeDistanceMax: 0x00000000000000000000004b004b004b004b00460041003c00370032002d0028n,
  affiliate: 0x00000000000000000000060e060e060e060e060e060e04e203e80320028a01f4n,
};
const QUEST_STAKE_REQUIRE_PRINCIPAL = 1;
const QUEST_STAKE_REQUIRE_DISTANCE = 1 << 1;
const QUEST_STAKE_REQUIRE_RISK = 1 << 2;
const SKIP_STAKE_QUESTS_FOR_SIM = true;
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
const QUEST_FLIP_ATTEMPT_LIMIT = QUEST_MINT_ATTEMPT_LIMIT * 2;
const QUEST_STAKE_MATURITY_BUFFER = 10;
const QUEST_STAKE_DISTANCE_STEP = 10;
const QUEST_PREFUND_COINS = 5_000n * MILLION;
const CUSTOM_ERROR_SELECTORS = {
  NotTimeYet: "0xb473605e",
  RngNotReady: "0xbb3e844f",
};
const STAKE_STRATEGY = {
  playerCount: 10,
  burnAmount: 5_000n * MILLION,
  targetLead: 30,
  risk: 5,
  maxPerLevel: 1,
};
const BUCKET_PURCHASE_DAY_RANGE = { min: 5, max: 10 };
const BUCKET_PURCHASE_FIRST_LEVEL_MULTIPLIER = 2;
const AFFILIATE_HELPER_BUFFER_WEI = ethers.parseEther("0.05");

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
  ensureEthBalance,
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
    const ensureBalanceFn = ensureEthBalance
      ? async (requiredWei) => ensureEthBalance(player, requiredWei)
      : undefined;
    const spent = await executeStrategyMint({
      player,
      quantity: playerQuantity,
      targetLevel,
      purgeNFT,
      purgeGame,
      contributions,
      referralCodes,
      ensurePlayerEth: ensureBalanceFn,
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
  ensurePlayerEth,
}) {
  const info = await purgeGame.gameInfo();
  const price = info.price_;
  const mapCost = (price * BigInt(quantity) * 25n) / 100n;
  if (ensurePlayerEth) {
    await ensurePlayerEth(mapCost);
  }
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
  if (fields.filter(Boolean).some((msg) => msg.includes(name))) {
    return true;
  }
  const selector = CUSTOM_ERROR_SELECTORS[name];
  if (!selector) return false;
  const data = typeof err.data === "string" ? err.data.toLowerCase() : "";
  return data.startsWith(selector) || data.startsWith(`0x${selector.replace(/^0x/, "")}`);
}

function describeError(err) {
  if (!err) return "unknown";
  if (typeof err === "string") return err;
  const fields = [err.shortMessage, err.reason, err.message, err.code];
  for (const field of fields) {
    if (field) return field;
  }
  if (typeof err.data === "string" && err.data.length !== 0) {
    return err.data;
  }
  try {
    return JSON.stringify(err);
  } catch (jsonErr) {
    return String(err);
  }
}

const ADVANCE_GAME_CAP = 1500;
const DAILY_JACKPOT_PROGRESS_ATTEMPTS = 64;
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

function formatCoinThousands(value) {
  if (value === undefined) return "-";
  const unit = 1000n * 1_000_000n;
  let bigintValue;
  if (typeof value === "bigint") {
    bigintValue = value;
  } else if (typeof value === "number") {
    bigintValue = BigInt(Math.trunc(value));
  } else if (value?.toBigInt) {
    bigintValue = value.toBigInt();
  } else {
    bigintValue = BigInt(value.toString());
  }
  const thousands = bigintValue / unit;
  return `${thousands.toString()}k PURGE`;
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

async function unlockRngForQuests({ purgeGame, vrf, vrfConsumer, operator, label = "rng" }) {
  if (!purgeGame || !operator) {
    return;
  }
  for (let attempt = 0; attempt < 8; attempt += 1) {
    if (!(await purgeGame.rngLocked())) {
      return;
    }
    await fulfillPendingVrfRequest(vrf, vrfConsumer);
    await runAdvanceGameTick({
      purgeGame,
      vrf,
      vrfConsumer,
      operator,
      label: `${label}-${attempt}`,
    });
  }
  throw new Error(`RNG remained locked after multiple attempts (${label})`);
}

async function waitForJackpotProgress({
  purgeGame,
  vrf,
  vrfConsumer,
  operator,
  levelValue,
  dayIndex,
  counterBefore,
}) {
  let infoAfter = await purgeGame.gameInfo();
  let counterAfter = counterBefore;
  let paid = 0;
  for (let attempt = 0; attempt < DAILY_JACKPOT_PROGRESS_ATTEMPTS; attempt += 1) {
    await runAdvanceGameTick({
      purgeGame,
      vrf,
      vrfConsumer,
      operator,
      label: `daily-${levelValue}-${dayIndex}-tick${attempt}`,
    });
    infoAfter = await purgeGame.gameInfo();
    counterAfter = Number(infoAfter.jackpotCounter_);
    paid = counterAfter - counterBefore;
    const stateChanged = Number(infoAfter.gameState_) !== 3;
    const counterReset = counterAfter < counterBefore;
    if (paid > 0 || stateChanged || counterReset) {
      if (paid <= 0 && (stateChanged || counterReset)) {
        paid = JACKPOT_LEVEL_CAP - counterBefore;
      }
      return { infoAfter, counterAfter, paid };
    }
  }
  throw new Error(
    `Jackpot processing stalled at level ${levelValue} day ${dayIndex + 1} after ${DAILY_JACKPOT_PROGRESS_ATTEMPTS} advanceGame attempts`
  );
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
  questModule,
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
  advanceOperator,
  questMintOverrides,
  questAffiliateSupporters,
}) {
  if (!questPlayers || questPlayers.length === 0) {
    return;
  }
  const questSnapshots = await snapshotQuestData(purgecoin, questModule);
  const duplicateQuestSlots = new Set();
  const questTypeOrder = new Map();
  const quests = questSnapshots.quests ?? [];
  for (let i = 0; i < quests.length; i += 1) {
    const questInfo = quests[i];
    const questTypeValue = Number(questInfo?.questType ?? -1);
    const usage = questTypeOrder.get(questTypeValue) ?? 0;
    questTypeOrder.set(questTypeValue, usage + 1);
    if (usage > 0) {
      duplicateQuestSlots.add(i);
    }
  }
  for (let slot = 0; slot < QUEST_SLOT_COUNT; slot += 1) {
    if (duplicateQuestSlots.has(slot)) {
      const typeVal = Number(quests?.[slot]?.questType ?? -1);
      console.warn(`Skipping quest slot ${slot} due to duplicate quest type ${questTypeLabel(typeVal)}`);
      continue;
    }
    const questTiers = await snapshotQuestTiers(questModule, questPlayers);
    for (const player of questPlayers) {
      await ensureQuestSlotComplete(
        {
          purgecoin,
          questModule,
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
          advanceOperator,
          questMintOverrides,
          questAffiliateSupporters,
          questTiers,
          questSnapshots,
        },
        player,
        slot
      );
    }
  }
}

async function ensureQuestSlotComplete(context, player, slot) {
  const { purgecoin } = context;
  const [, , , completed] = await purgecoin.playerQuestStates(player.address);
  if (completed[slot]) {
    return;
  }
  const questData = await resolveQuestSlot(context, slot);
  if (!questData) {
    return;
  }
  const { quest, questDetail } = questData;
  await performQuestAction(context, player, quest, slot, questDetail);
}

async function resolveQuestSlot(context, slot) {
  const { purgecoin, questModule, questSnapshots } = context;
  let quests;
  let questDetails;
  if (questSnapshots && questSnapshots.quests && questSnapshots.questDetails) {
    ({ quests, questDetails } = questSnapshots);
  } else {
    ({ quests, questDetails } = await snapshotQuestData(purgecoin, questModule));
  }
  if (!quests || quests.length <= slot) return null;
  const quest = quests[slot];
  if (!quest || quest.day === 0n) return null;
  const detail = questDetails?.[slot];
  if (!detail || detail.day === 0n) {
    return { quest, questDetail: undefined };
  }
  return { quest, questDetail: detail };
}

async function refreshQuestIfChanged(context, quest, slot) {
  const next = await resolveQuestSlot(context, slot);
  if (!next || !next.quest || next.quest.day === 0n) {
    return { questChanged: true, quest: undefined, questDetail: undefined };
  }
  if (!quest || next.quest.day !== quest.day || next.quest.questType !== quest.questType) {
    return { questChanged: true, quest: next.quest, questDetail: next.questDetail };
  }
  return null;
}

async function performQuestAction(context, player, quest, slot, questDetail) {
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
    questTiers,
    questModule,
    advanceOperator,
  } = context;
  let activeQuest = quest;
  let activeQuestDetail = questDetail;
  const maxRefreshes = 3;
  for (let refresh = 0; refresh < maxRefreshes; refresh += 1) {
    if (!activeQuest || activeQuest.day === 0n) {
      return;
    }
    const questEntropy = activeQuestDetail ? bigNumberToBigInt(activeQuestDetail.entropy) : 0n;
    const questTier = questTiers.get(player.address) ?? 0;
    const questType = Number(activeQuest.questType);
    const questStakeMask = valueToNumber(activeQuestDetail?.stakeMask ?? activeQuest.stakeMask ?? 0);
    const questStakeRisk = valueToNumber(activeQuestDetail?.stakeRisk ?? activeQuest.stakeRisk ?? 0);
    switch (questType) {
      case QUEST_TYPES.MINT_ANY: {
        const requiredQuantity = questMintAnyTarget(questTier, questEntropy);
        const quantity = Math.max(requiredQuantity, QUEST_COMPLETION_PARAMS.mintQuantity);
        const mintResult = await performQuestCoinMint({
          purgeNFT,
          purgeGame,
          purgecoin,
          player,
          referralCodes,
          playerAffiliateCodes,
          coinBank,
          quantity,
          contributions,
          targetLevel: questTargetLevel,
          mintCountLedger,
          slot,
          vrf,
          vrfConsumer,
          questMintOverrides,
          questAffiliateSupporters,
          questModule,
          quest: activeQuest,
          advanceOperator,
          questMeta: { expectedQuantity: requiredQuantity },
        });
        if (mintResult?.questChanged) {
          activeQuest = mintResult.quest;
          activeQuestDetail = mintResult.questDetail;
          continue;
        }
        return;
      }
      case QUEST_TYPES.MINT_ETH: {
        const requiredEthQuantity = questMintEthTarget(questTier, questEntropy);
        const ethQuantity = Math.max(requiredEthQuantity, QUEST_COMPLETION_PARAMS.mintQuantity);
        const ethResult = await performQuestEthMint({
          purgecoin,
          player,
          purgeNFT,
          purgeGame,
          contributions,
          referralCodes,
          playerAffiliateCodes,
          targetLevel: questTargetLevel,
          mintCountLedger,
          quantity: ethQuantity,
          slot,
          vrf,
          vrfConsumer,
          questMintOverrides,
          questAffiliateSupporters,
          questModule,
          quest: activeQuest,
          advanceOperator,
          questMeta: { expectedQuantity: requiredEthQuantity },
        });
        if (ethResult?.questChanged) {
          activeQuest = ethResult.quest;
          activeQuestDetail = ethResult.questDetail;
          continue;
        }
        return;
      }
      case QUEST_TYPES.FLIP: {
        const requiredTokens = questFlipTargetTokens(questTier, questEntropy);
        const requiredAmount = BigInt(requiredTokens) * MILLION;
        const amount =
          requiredAmount > QUEST_COMPLETION_PARAMS.flipAmount ? requiredAmount : QUEST_COMPLETION_PARAMS.flipAmount;
        const flipResult = await performQuestFlip(context, player, activeQuest, slot, amount, {
          targetTokens: requiredTokens,
        });
        if (flipResult?.questChanged) {
          activeQuest = flipResult.quest;
          activeQuestDetail = flipResult.questDetail;
          continue;
        }
        return;
      }
      case QUEST_TYPES.STAKE: {
        if (SKIP_STAKE_QUESTS_FOR_SIM) {
          return;
        }
        const requiredPrincipal = BigInt(questStakePrincipalTarget(questTier, questEntropy)) * MILLION;
        const requiredDistance = questStakeDistanceTarget(questTier, questEntropy);
        const distanceOverride = Number(requiredDistance);
        let riskOverride = 1;
        if ((questStakeMask & QUEST_STAKE_REQUIRE_RISK) !== 0) {
          riskOverride = Math.max(1, questStakeRisk);
        }
        const stakeResult = await performQuestStake(context, player, activeQuest, slot, {
          principalOverride: requiredPrincipal,
          distanceOverride,
          riskOverride,
        });
        if (stakeResult?.questChanged) {
          activeQuest = stakeResult.quest;
          activeQuestDetail = stakeResult.questDetail;
          continue;
        }
        return;
      }
      case QUEST_TYPES.AFFILIATE: {
        const requiredTokens = questAffiliateTargetTokens(questTier, questEntropy);
        const requiredAmount = BigInt(requiredTokens) * MILLION;
        const priceUnit = bigNumberToBigInt(await purgeGame.coinPriceUnit());
        let affiliateQuantity = estimateAffiliateMintQuantity(requiredAmount, priceUnit);
        affiliateQuantity = Math.max(affiliateQuantity, QUEST_COMPLETION_PARAMS.mintQuantity);
        const affiliateResult = await performQuestAffiliate(context, player, activeQuest, slot, affiliateQuantity);
        if (affiliateResult?.questChanged) {
          activeQuest = affiliateResult.quest;
          activeQuestDetail = affiliateResult.questDetail;
          continue;
        }
        return;
      }
      case QUEST_TYPES.PURGE: {
        const requiredQuantity = questMintEthTarget(questTier, questEntropy);
        const quantity = Math.max(requiredQuantity, QUEST_COMPLETION_PARAMS.purgeQuantity);
        const purgeResult = await performQuestPurge(context, player, activeQuest, slot, quantity);
        if (purgeResult?.questChanged) {
          activeQuest = purgeResult.quest;
          activeQuestDetail = purgeResult.questDetail;
          continue;
        }
        return;
      }
      case QUEST_TYPES.DECIMATOR: {
        const requiredTokens = questDecimatorTargetTokens(questTier, questEntropy);
        const requiredAmount = BigInt(requiredTokens) * MILLION;
        const amount =
          requiredAmount > QUEST_COMPLETION_PARAMS.decimatorAmount
            ? requiredAmount
            : QUEST_COMPLETION_PARAMS.decimatorAmount;
        const decResult = await performQuestDecimator(context, player, activeQuest, slot, amount);
        if (decResult?.questChanged) {
          activeQuest = decResult.quest;
          activeQuestDetail = decResult.questDetail;
          continue;
        }
        return;
      }
      default:
        return;
    }
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

async function ensureWalletEthBalance(wallet, funder, requiredWei, bufferWei = 0n) {
  if (!wallet?.address || !funder || !requiredWei || requiredWei <= 0n) {
    return;
  }
  if (wallet.address === funder.address) {
    return;
  }
  const desiredBalance = requiredWei + (bufferWei > 0n ? bufferWei : 0n);
  const currentBalance = await ethers.provider.getBalance(wallet.address);
  if (currentBalance >= desiredBalance) {
    return;
  }
  const topUp = desiredBalance - currentBalance;
  const tx = await funder.sendTransaction({ to: wallet.address, value: topUp });
  await tx.wait();
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
      const code = referralCodes?.get(beneficiary.address);
      if (code) {
        plan.mintOverrides.set(supporter.address, code);
      }
    }
  }
  for (let i = 0; i < filtered.length; i += 1) {
    const beneficiary = filtered[i];
    if (!beneficiary?.address) continue;
    const supporters = [];
    for (let offset = 1; offset < filtered.length; offset += 1) {
      supporters.push(filtered[(i + offset) % filtered.length]);
    }
    plan.affiliateSupporters.set(beneficiary.address, supporters);
  }
  return plan;
}

async function snapshotQuestTiers(questModule, players) {
  const tiers = new Map();
  if (!players || players.length === 0) {
    return tiers;
  }
  for (const player of players) {
    const [streak] = await questModule.playerQuestState(player.address);
    const numeric = valueToNumber(streak);
    tiers.set(player.address, computeQuestTier(numeric));
  }
  return tiers;
}

function computeQuestTier(streak) {
  const tier = Math.floor(streak / QUEST_TIER_STREAK_SPAN);
  return tier > QUEST_TIER_MAX_INDEX ? QUEST_TIER_MAX_INDEX : tier;
}

function questPackedValue(packed, tier) {
  const shift = BigInt(tier) * 16n;
  return Number((packed >> shift) & 0xffffn);
}

function questRand(entropy, questType, tier, salt) {
  if (!entropy || entropy === 0n) return 0n;
  const encoded = abiCoder.encode(["uint256", "uint8", "uint8", "uint8"], [entropy, questType, tier, salt]);
  return BigInt(ethers.keccak256(encoded));
}

function questTypeLabel(value) {
  for (const [label, typeValue] of Object.entries(QUEST_TYPES)) {
    if (typeValue === value) {
      return label;
    }
  }
  return `type-${value}`;
}

async function snapshotQuestData(purgecoin, questModule) {
  const [quests, questDetails] = await Promise.all([purgecoin.getActiveQuests(), questModule.getQuestDetails()]);
  return { quests, questDetails };
}

function questMintAnyTarget(tier, entropy) {
  const maxVal = questPackedValue(QUEST_PACKED_VALUES.mintAny, tier);
  if (maxVal <= QUEST_MIN_MINT) return QUEST_MIN_MINT;
  const rand = questRand(entropy, QUEST_TYPES.MINT_ANY, tier, 0);
  return Number(rand % BigInt(maxVal)) + QUEST_MIN_MINT;
}

function questMintEthTarget(tier, entropy) {
  if (tier === 0) return QUEST_MIN_MINT;
  const maxVal = questPackedValue(QUEST_PACKED_VALUES.mintEth, tier);
  if (maxVal <= QUEST_MIN_MINT) return QUEST_MIN_MINT;
  const rand = questRand(entropy, QUEST_TYPES.MINT_ETH, tier, 0);
  return Number(rand % BigInt(maxVal)) + QUEST_MIN_MINT;
}

function questFlipTargetTokens(tier, entropy) {
  const maxVal = questPackedValue(QUEST_PACKED_VALUES.flip, tier);
  const range = BigInt(maxVal - QUEST_MIN_TOKEN + 1);
  const rand = questRand(entropy, QUEST_TYPES.FLIP, tier, 0);
  return Number(BigInt(QUEST_MIN_TOKEN) + (rand % range));
}

function questDecimatorTargetTokens(tier, entropy) {
  const base = questFlipTargetTokens(tier, entropy);
  return base * 2;
}

function questStakePrincipalTarget(tier, entropy) {
  const maxVal = questPackedValue(QUEST_PACKED_VALUES.stakePrincipal, tier);
  const range = BigInt(maxVal - QUEST_MIN_TOKEN + 1);
  const rand = questRand(entropy, QUEST_TYPES.STAKE, tier, 1);
  return Number(BigInt(QUEST_MIN_TOKEN) + (rand % range));
}

function questStakeDistanceTarget(tier, entropy) {
  const minVal = questPackedValue(QUEST_PACKED_VALUES.stakeDistanceMin, tier);
  const maxVal = questPackedValue(QUEST_PACKED_VALUES.stakeDistanceMax, tier);
  const range = BigInt(maxVal - minVal + 1);
  const rand = questRand(entropy, QUEST_TYPES.STAKE, tier, 2);
  return Number(BigInt(minVal) + (rand % range));
}

function questAffiliateTargetTokens(tier, entropy) {
  const maxVal = questPackedValue(QUEST_PACKED_VALUES.affiliate, tier);
  const range = BigInt(maxVal - QUEST_MIN_TOKEN + 1);
  const rand = questRand(entropy, QUEST_TYPES.AFFILIATE, tier, 0);
  return Number(BigInt(QUEST_MIN_TOKEN) + (rand % range));
}

function estimateAffiliateMintQuantity(targetAmount, priceUnit) {
  if (priceUnit === 0n) return QUEST_COMPLETION_PARAMS.mintQuantity;
  const numerator = targetAmount * 10000n;
  const denominator = priceUnit * 375n;
  if (denominator === 0n) return QUEST_COMPLETION_PARAMS.mintQuantity;
  const quotient = (numerator + denominator - 1n) / denominator;
  const estimated = Number(quotient);
  return estimated <= 0 ? QUEST_COMPLETION_PARAMS.mintQuantity : estimated;
}

function bigNumberToBigInt(value) {
  if (!value) return 0n;
  if (typeof value === "bigint") return value;
  if (typeof value === "number") return BigInt(value);
  if (value.toBigInt) return value.toBigInt();
  return BigInt(value.toString());
}

function valueToNumber(value) {
  if (typeof value === "number") return value;
  if (typeof value === "bigint") return Number(value);
  if (!value) return 0;
  return Number(value);
}

async function hasRecentEthMint(purgeGame, playerAddress) {
  if (!playerAddress) {
    return false;
  }
  const [currentLevelRaw, lastLevelRaw] = await Promise.all([
    purgeGame.level(),
    purgeGame.ethMintLastLevel(playerAddress),
  ]);
  const currentLevel = Number(currentLevelRaw);
  const lastLevel = Number(lastLevelRaw);
  if (!lastLevel || lastLevel <= 0) {
    return false;
  }
  if (currentLevel <= lastLevel) {
    return true;
  }
  return currentLevel - lastLevel <= 3;
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
  questModule,
  quest,
  advanceOperator,
  questMeta = {},
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
      questModule,
      quest,
      advanceOperator,
      questMeta,
    });
    return;
  }
  const mintedRecently = await hasRecentEthMint(purgeGame, player.address);
  if (!mintedRecently) {
    await performQuestEthMint({
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
      questAffiliateSupporters,
      questModule,
      quest,
      advanceOperator,
      questMeta,
    });
    return;
  }
  const priceUnit = await purgeGame.coinPriceUnit();
  const baseCost = BigInt(quantity) * (priceUnit / 4n);
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    const questUpdate = await refreshQuestIfChanged({ purgecoin, questModule }, quest, slot);
    if (questUpdate) {
      return questUpdate;
    }
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
  questModule,
  quest,
  questMeta = {},
  advanceOperator,
}) {
  const affiliateOverride = questMintOverrides?.get(player.address);
  const failureReasons = new Set();
  let rngLockedSkips = 0;
  const targetQuantity = typeof questMeta.expectedQuantity === "number" ? questMeta.expectedQuantity : quantity;
  const dynamicLimit = Math.max(QUEST_MINT_ATTEMPT_LIMIT, Math.ceil(targetQuantity / Math.max(1, quantity)) + 2);
  for (let attempt = 0; attempt < dynamicLimit; attempt += 1) {
    const questUpdate = await refreshQuestIfChanged({ purgecoin, questModule }, quest, slot);
    if (questUpdate) {
      return questUpdate;
    }
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
        rngLockedSkips += 1;
        await unlockRngForQuests({
          purgeGame,
          vrf,
          vrfConsumer,
          operator: advanceOperator,
          label: `eth-quest-${player.address}`,
        });
        continue;
      }
      failureReasons.add(describeError(err));
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
  const [, , progress] = await purgecoin.playerQuestStates(player.address);
  const questProgress = progress?.[slot] ?? 0n;
  const reasons = failureReasons.size === 0 ? "unknown" : Array.from(failureReasons).join(" | ");
  console.warn(
    `ETH quest mint did not complete for ${player.address} (progress ${questProgress.toString()}, rngSkips ${rngLockedSkips}) [reasons: ${reasons}]`
  );
}

async function performQuestFlip(context, player, quest, slot, overrideAmount, questMeta = {}) {
  const { purgecoin, coinBank, vrf, vrfConsumer, purgeGame, advanceOperator } = context;
  const amount = overrideAmount ?? QUEST_COMPLETION_PARAMS.flipAmount;
  const failureReasons = new Set();
  let rngLockedSkips = 0;
  let bettingPausedSkips = 0;
  let dynamicLimit = QUEST_FLIP_ATTEMPT_LIMIT;
  if (questMeta.targetTokens) {
    const targetWei = BigInt(questMeta.targetTokens) * MILLION;
    const perAttempt = BigInt(amount);
    if (perAttempt > 0n) {
      const required = Number((targetWei + perAttempt - 1n) / perAttempt);
      dynamicLimit = Math.max(dynamicLimit, required + 2);
    }
  }
  for (let attempt = 0; attempt < dynamicLimit; attempt += 1) {
    const questUpdate = await refreshQuestIfChanged(context, quest, slot);
    if (questUpdate) {
      return questUpdate;
    }
    await ensureCoinBalance(purgecoin, coinBank, player, amount);
    if (await purgeGame.rngLocked()) {
      rngLockedSkips += 1;
      await unlockRngForQuests({
        purgeGame,
        vrf,
        vrfConsumer,
        operator: advanceOperator,
        label: `flip-quest-${player.address}`,
      });
      continue;
    }
    try {
      await (await purgecoin.connect(player).depositCoinflip(amount)).wait();
    } catch (err) {
      if (err?.shortMessage?.includes("BettingPaused")) {
        bettingPausedSkips += 1;
        await unlockRngForQuests({
          purgeGame,
          vrf,
          vrfConsumer,
          operator: advanceOperator,
          label: `flip-bet-${player.address}`,
        });
        continue;
      }
      failureReasons.add(describeError(err));
      throw err;
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  const [, , progress] = await purgecoin.playerQuestStates(player.address);
  const questProgress = progress?.[slot] ?? 0n;
  const reasons = failureReasons.size === 0 ? "unknown" : Array.from(failureReasons).join(" | ");
  console.warn(
    `Flip quest did not complete for ${player.address} (progress ${questProgress.toString()}, rngSkips ${rngLockedSkips}, bettingSkips ${bettingPausedSkips}) [reasons: ${reasons}]`
  );
}

async function performQuestStake(context, player, quest, slot, overrides = {}) {
  const { purgecoin, coinBank, questTargetLevel, vrf, vrfConsumer, purgeGame } = context;
  const principal = overrides.principalOverride ?? QUEST_COMPLETION_PARAMS.stakePrincipal;
  const mask = Number(quest.stakeMask ?? 0);
  const distanceTarget = overrides.distanceOverride ?? QUEST_COMPLETION_PARAMS.stakeDistance;
  let baseRisk;
  if (overrides.riskOverride !== undefined) {
    baseRisk = Number(overrides.riskOverride);
  } else if ((mask & QUEST_STAKE_REQUIRE_RISK) !== 0) {
    baseRisk = Number(quest.stakeRisk);
  } else {
    baseRisk = 1;
  }
  const contractMaxRisk = 11;
  if (baseRisk < 1) baseRisk = 1;
  if (baseRisk > contractMaxRisk) baseRisk = contractMaxRisk;
  let distanceBonus = 0;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    const questUpdate = await refreshQuestIfChanged(context, quest, slot);
    if (questUpdate) {
      return questUpdate;
    }
    const info = await purgeGame.gameInfo();
    const currentLevel = Number(await purgeGame.level());
    const gameStateValue = Number(info.gameState_ ?? info.gameState ?? 0);
    let effectiveLevel = currentLevel;
    if (gameStateValue !== 3) {
      effectiveLevel = currentLevel === 0 ? 0 : currentLevel - 1;
    }
    const attemptDistance = distanceTarget + distanceBonus;
    const baseTargetLevel = Number(questTargetLevel ?? 0) + attemptDistance;
    const maturityFloor = effectiveLevel + attemptDistance + QUEST_STAKE_MATURITY_BUFFER;
    const minTarget = Math.max(baseTargetLevel, maturityFloor);
    const maxTargetLevel = effectiveLevel + 500;
    if (minTarget > maxTargetLevel) {
      distanceBonus += QUEST_STAKE_DISTANCE_STEP;
      continue;
    }
    let candidateTarget = minTarget;
    let riskValue = baseRisk > contractMaxRisk ? contractMaxRisk : baseRisk;
    const maxRiskForTarget = candidateTarget + 1 - effectiveLevel;
    if (maxRiskForTarget <= 0) {
      distanceBonus += QUEST_STAKE_DISTANCE_STEP;
      continue;
    }
    if (riskValue > maxRiskForTarget) {
      riskValue = maxRiskForTarget;
    }
    if (riskValue <= 0) {
      riskValue = 1;
    }
    await ensureCoinBalance(purgecoin, coinBank, player, principal);
    try {
      await (await purgecoin.connect(player).stake(principal, candidateTarget, riskValue)).wait();
    } catch (err) {
      if (isCustomError(err, "StakeInvalid")) {
        distanceBonus += QUEST_STAKE_DISTANCE_STEP;
        continue;
      }
      if (isCustomError(err, "BettingPaused")) {
        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        await time.increase(5);
        continue;
      }
      if (isCustomError(err, "Insufficient")) {
        console.warn(
          `Stake quest insufficient for ${player.address}: target ${candidateTarget}, effective ${effectiveLevel}, maxRisk ${maxRiskForTarget}, risk ${riskValue}`
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

async function performQuestAffiliate(context, player, quest, slot, quantityOverride) {
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
  const quantity = quantityOverride ?? QUEST_COMPLETION_PARAMS.mintQuantity;
  const helperEntry = questAffiliateSupporters?.get(player.address);
  const helperList = Array.isArray(helperEntry)
    ? helperEntry.filter(Boolean)
    : helperEntry
    ? [helperEntry]
    : [];
  const helpers = helperList.length === 0 ? [coinBank] : helperList;
  let helperCursor = 0;
  const maxAttempts = helpers.length * QUEST_MINT_ATTEMPT_LIMIT;
  for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
    const questUpdate = await refreshQuestIfChanged(context, quest, slot);
    if (questUpdate) {
      return questUpdate;
    }
    const helper = helpers[helperCursor % helpers.length];
    helperCursor += 1;
    try {
      await executeStrategyMint({
        player: helper,
        quantity,
        targetLevel: questTargetLevel,
        purgeNFT,
        purgeGame,
        contributions,
        referralCodes,
        affiliateOverride: code,
        ensurePlayerEth:
          helper?.address && coinBank
            ? (requiredWei) => ensureWalletEthBalance(helper, coinBank, requiredWei, AFFILIATE_HELPER_BUFFER_WEI)
            : undefined,
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
      mintCountLedger.set(helper.address, prev + BigInt(quantity));
    }
    const [, , , completed] = await purgecoin.playerQuestStates(player.address);
    if (completed[slot]) {
      return;
    }
  }
  console.warn(`Affiliate quest did not complete for ${player.address}`);
}

async function performQuestPurge(context, player, quest, slot, quantityOverride) {
  const { purgecoin, purgeNFT, purgeGame, referralCodes, contributions, vrf, vrfConsumer } = context;
  const quantity = quantityOverride ?? QUEST_COMPLETION_PARAMS.purgeQuantity;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    const questUpdate = await refreshQuestIfChanged(context, quest, slot);
    if (questUpdate) {
      return questUpdate;
    }
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

async function performQuestDecimator(context, player, quest, slot, overrideAmount) {
  const { purgecoin, coinBank } = context;
  const amount = overrideAmount ?? QUEST_COMPLETION_PARAMS.decimatorAmount;
  for (let attempt = 0; attempt < QUEST_MINT_ATTEMPT_LIMIT; attempt += 1) {
    const questUpdate = await refreshQuestIfChanged(context, quest, slot);
    if (questUpdate) {
      return questUpdate;
    }
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
    const questStrategyPlayers = await createWallets(25, secondaryFunder, ethers.parseEther("50"));
    const basePlayers = [...firstBatch, ...secondBatch];
    const players = [...basePlayers, ...questStrategyPlayers];
    const questCompleterPlayers = questStrategyPlayers;
    const stakingPlayers = basePlayers.slice(0, Math.min(STAKE_STRATEGY.playerCount, basePlayers.length));

    const system = await deploySystem();
    const { purgeGame, purgeNFT, purgeTrophies, purgecoin, deployer, vrf, questModule } = system;
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

    await purgecoin.connect(deployer).setQuestPurgeEnabled(false);
    await prefundPlayersWithCoin(purgecoin, deployer, questCompleterPlayers, QUEST_PREFUND_COINS);

    const targetPerLevel = [];
    let currentTarget = MAP_PURCHASE_TARGET_WEI;
    for (let i = 0; i < LEVEL_COUNT; i += 1) {
      targetPerLevel.push(currentTarget);
      currentTarget = (currentTarget * 110n) / 100n;
    }

    const nextLevelValue = LEVEL_COUNT + 1;
    const nextLevelTotal = currentTarget;
    targetPerLevel.push(nextLevelTotal);

    const contributions = new Map();
    const strategyMintCounts = new Map();
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
    const BUCKET_PLAYER_COUNT = 10;
    const BUCKET_PLAYER_MINT_QUANTITY = 20;
    const BUCKET_PURCHASE_MIN_MINT_QUANTITY = BUCKET_PLAYER_MINT_QUANTITY;
    const BUCKET_PURCHASE_MAX_MINT_QUANTITY = BUCKET_PLAYER_MINT_QUANTITY * 500;
    const BUCKET_DAILY_QUANTITY_MULTIPLIER = 5;
    const BUCKET_DAILY_MINT_QUANTITY = BUCKET_PLAYER_MINT_QUANTITY * BUCKET_DAILY_QUANTITY_MULTIPLIER;
    const BUCKET_PLAYER_FUNDING = ethers.parseEther("1");
    const BUCKET_MINT_BUFFER_WEI = ethers.parseEther("0.05");
    const BUCKET_DAY_CAP = 1024;
    const bucketGroups = [];
    const bucketFunders = [primaryFunder, secondaryFunder];
    let bucketFunderCursor = 0;
    const bucketAffiliateRng = createDeterministicRng(0xc0ffee1234n);
    const BUCKET_AFFILIATE_COUNT = 10;
    const bucketAffiliateOwners = await createWallets(BUCKET_AFFILIATE_COUNT, primaryFunder, ethers.parseEther("1"));
    const bucketAffiliateCodes = [];
    for (let i = 0; i < bucketAffiliateOwners.length; i += 1) {
      const owner = bucketAffiliateOwners[i];
      const code = ethers.solidityPackedKeccak256(["string", "uint256"], ["bucket-aff", i]);
      const rakeback = 5 + (i % 6);
      await (await purgecoin.connect(owner).createAffiliateCode(code, rakeback)).wait();
      bucketAffiliateCodes.push(code);
    }

    function bucketLabelForDay(dayIndex) {
      return `Day ${dayIndex + 1}`;
    }

    async function createBucket(dayIndex, label) {
      if (bucketGroups.length >= BUCKET_DAY_CAP && !bucketGroups[dayIndex]) {
        throw new Error(`Exceeded bucket day cap of ${BUCKET_DAY_CAP}`);
      }
      const funder = bucketFunders[bucketFunderCursor % bucketFunders.length];
      bucketFunderCursor += 1;
      const bucketPlayers = await createWallets(BUCKET_PLAYER_COUNT, funder, BUCKET_PLAYER_FUNDING);
      players.push(...bucketPlayers);
      const bucket = {
        label,
        players: bucketPlayers,
        funder,
        stats: { buyers: 0, quantity: 0n, totalCost: 0n },
      };
      bucketGroups[dayIndex] = bucket;
      const activeCodes = bucketAffiliateCodes.length !== 0 ? bucketAffiliateCodes : [];
      for (const player of bucketPlayers) {
        let selectedCode = ethers.ZeroHash;
        if (activeCodes.length !== 0) {
          selectedCode = activeCodes[bucketAffiliateRng(activeCodes.length)];
        }
        if (selectedCode !== ethers.ZeroHash) {
          await (await purgecoin.connect(player).referPlayer(selectedCode)).wait();
        }
        referralAssignments.set(player.address, selectedCode);
      }
      return bucket;
    }

    async function ensureMintBucket(dayIndex) {
      if (bucketGroups[dayIndex]) {
        return bucketGroups[dayIndex];
      }
      const label = bucketLabelForDay(dayIndex);
      return createBucket(dayIndex, label);
    }

    function desiredPurchaseDayCount(levelValue) {
      const baseMin = Math.max(1, BUCKET_PURCHASE_DAY_RANGE.min ?? 5);
      const baseMax = Math.max(baseMin, BUCKET_PURCHASE_DAY_RANGE.max ?? baseMin);
      const multiplier = levelValue === 1 ? Math.max(1, BUCKET_PURCHASE_FIRST_LEVEL_MULTIPLIER) : 1;
      const minDays = baseMin * multiplier;
      const maxDays = baseMax * multiplier;
      if (minDays >= maxDays) {
        return minDays;
      }
      const rng = createDeterministicRng(0xabcd1234n + BigInt(levelValue));
      const span = maxDays - minDays + 1;
      return minDays + (span > 0 ? rng(span) : 0);
    }

    function recordBucketStats(bucket, stats) {
      if (!bucket || !stats) return;
      bucket.stats.buyers += stats.buyers ?? 0;
      bucket.stats.quantity += stats.quantity ?? 0n;
      bucket.stats.totalCost += stats.totalCost ?? 0n;
    }

    async function performBucketMints({ bucket, quantityPerPlayer, targetLevel }) {
      const stats = await runStrategyMapPurchases({
        players: bucket.players,
        purgeGame,
        purgeNFT,
        contributions,
        referralCodes: referralAssignments,
        targetLevel,
        quantity: quantityPerPlayer,
        mintCountLedger: strategyMintCounts,
        ensureEthBalance: (player, requiredWei) => ensureBucketPlayerFunds(bucket, player, requiredWei),
      });
      recordBucketStats(bucket, stats);
      return stats;
    }

    async function runPurchaseBuckets(levelValue, targetWei) {
      const usage = [];
      let info = await purgeGame.gameInfo();
      const desiredDays = desiredPurchaseDayCount(levelValue);
      let bucketIndex = 0;
      while (info.prizePoolCurrent < targetWei && bucketIndex < desiredDays) {
        const bucket = await ensureMintBucket(bucketIndex);
        const remaining = targetWei > info.prizePoolCurrent ? targetWei - info.prizePoolCurrent : 0n;
        const bucketsRemaining = desiredDays - bucketIndex;
        let quantityPerPlayer = BUCKET_PURCHASE_MIN_MINT_QUANTITY;
        if (remaining > 0n) {
          const price = info.price_;
          const perPlayerUnitCost = (price * 25n) / 100n;
          const bucketUnitCost = perPlayerUnitCost * BigInt(bucket.players.length);
          if (bucketUnitCost > 0n) {
            const bucketCostTarget = (remaining + BigInt(bucketsRemaining) - 1n) / BigInt(bucketsRemaining);
            const qty = (bucketCostTarget + bucketUnitCost - 1n) / bucketUnitCost;
            const qtyNumber = Number(qty);
            if (qtyNumber > quantityPerPlayer) {
              quantityPerPlayer = qtyNumber;
            }
          }
        }
        if (quantityPerPlayer < BUCKET_PURCHASE_MIN_MINT_QUANTITY) {
          quantityPerPlayer = BUCKET_PURCHASE_MIN_MINT_QUANTITY;
        }
        if (quantityPerPlayer > BUCKET_PURCHASE_MAX_MINT_QUANTITY) {
          quantityPerPlayer = BUCKET_PURCHASE_MAX_MINT_QUANTITY;
        }
        const stats = await performBucketMints({
          bucket,
          quantityPerPlayer,
          targetLevel: levelValue,
        });
        usage.push({
          label: bucket.label,
          buyers: stats.buyers,
          quantity: stats.quantity,
          totalCost: stats.totalCost,
        });
        bucketIndex += 1;
        info = await purgeGame.gameInfo();
      }
      while (info.prizePoolCurrent < targetWei) {
        const bucket = await ensureMintBucket(bucketIndex);
        const remaining = targetWei > info.prizePoolCurrent ? targetWei - info.prizePoolCurrent : 0n;
        const price = info.price_;
        const perPlayerUnitCost = (price * 25n) / 100n;
        const bucketUnitCost = perPlayerUnitCost * BigInt(bucket.players.length);
        let quantityPerPlayer = BUCKET_PURCHASE_MAX_MINT_QUANTITY;
        if (bucketUnitCost > 0n && remaining > 0n) {
          const qty = (remaining + bucketUnitCost - 1n) / bucketUnitCost;
          const qtyNumber = Number(qty);
          quantityPerPlayer = Math.max(
            BUCKET_PURCHASE_MIN_MINT_QUANTITY,
            Math.min(qtyNumber, BUCKET_PURCHASE_MAX_MINT_QUANTITY)
          );
        }
        const stats = await performBucketMints({
          bucket,
          quantityPerPlayer,
          targetLevel: levelValue,
        });
        usage.push({
          label: bucket.label,
          buyers: stats.buyers,
          quantity: stats.quantity,
          totalCost: stats.totalCost,
        });
        bucketIndex += 1;
        info = await purgeGame.gameInfo();
        if (bucketIndex >= BUCKET_DAY_CAP) {
          throw new Error(`Level ${levelValue} did not reach target prize pool after ${bucketIndex} buckets`);
        }
      }
      return usage;
    }

    async function ensureBucketPlayerFunds(bucket, player, requiredWei) {
      const sponsor = bucket?.funder ?? bucketFunders[0];
      if (!sponsor) {
        throw new Error("No sponsor available for bucket funding");
      }
      const buffer = BUCKET_MINT_BUFFER_WEI;
      const desiredBalance = requiredWei + buffer;
      const currentBalance = await ethers.provider.getBalance(player.address);
      if (currentBalance >= desiredBalance) {
        return;
      }
      const needed = desiredBalance - currentBalance;
      const tx = await sponsor.sendTransaction({ to: player.address, value: needed });
      await tx.wait();
    }

    async function runDailyBucketMints({ dayIndex, targetLevel }) {
      const bucket = await ensureMintBucket(dayIndex);
      const stats = await performBucketMints({
        bucket,
        quantityPerPlayer: BUCKET_DAILY_MINT_QUANTITY,
        targetLevel,
      });
      return { ...stats, day: dayIndex + 1, bucket: bucket.label };
    }
    await (
      await primaryFunder.sendTransaction({
        to: purgeGameAddress,
        value: INITIAL_CARRYOVER_WEI,
      })
    ).wait();

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
      // map-day mint funding handled by bucket simulation

      const claimableBefore = await snapshotClaimableEth(purgeGame, players);

      let preInfo = await purgeGame.gameInfo();
      const desiredPrize = targetPerLevel[levelIndex];
      if (preInfo.prizePoolCurrent < desiredPrize) {
        const bucketUsage = await runPurchaseBuckets(levelValue, desiredPrize);
        if (bucketUsage.length !== 0) {
          console.log(`Level ${levelValue} mint buckets`);
          console.table(
            bucketUsage.map((entry) => ({
              bucket: entry.label,
              buyers: entry.buyers,
              quantity: entry.quantity.toString(),
              spent: formatEth(entry.totalCost),
            }))
          );
        }
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

      let pendingDailyMapActivity = { buyers: 0, quantity: 0n, totalCost: 0n };
      const nextLevelValue = levelValue + 1;

      const daySummaries = [];
      let jackpotsExecuted = 0;
      while (true) {
        await time.increase(DAY_SECONDS);

        const bucketActivity = await runDailyBucketMints({
          dayIndex: daySummaries.length,
          targetLevel: nextLevelValue,
        });
        pendingDailyMapActivity = accumulateDailyMapActivity(pendingDailyMapActivity, bucketActivity);

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

        const { infoAfter, paid } = await waitForJackpotProgress({
          purgeGame,
          vrf,
          vrfConsumer: purgeGameAddress,
          operator: advanceOperator,
          levelValue,
          dayIndex: daySummaries.length,
          counterBefore,
        });

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
          questModule,
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
          advanceOperator,
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

      const claimStats = await claimPlayerWinnings(purgeGame, players, realizedWinnings);
      if (claimStats.claimantCount !== 0) {
        console.log(
          `Level ${levelValue} claims paid ${formatEth(claimStats.claimedTotal)} to ${claimStats.claimantCount} players`
        );
      } else {
        console.log(`Level ${levelValue} claims: no players had claimable ETH`);
      }
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
    const buildGroupSummary = (label, groupPlayers, options = {}) => {
      const { isBucket = false, isDayOne = false } = options;
      let spentTotal = 0n;
      let ethWinningsTotal = 0n;
      let coinValueTotal = 0n;
      let totalValue = 0n;
      let netTotal = 0n;
      let coinAwardedTotal = 0n;
      let mintCountTotal = 0n;
      const playerRows = [];
      for (const player of groupPlayers) {
        const summary = playerSummaries.get(player.address);
        if (!summary) continue;
        spentTotal += summary.spent;
        ethWinningsTotal += summary.ethWinnings;
        coinValueTotal += summary.coinValueWei;
        totalValue += summary.totalValue;
        netTotal += summary.netWei;
        coinAwardedTotal += summary.coinAwardTotal;
        const playerMintCount = strategyMintCounts.get(player.address) ?? 0n;
        mintCountTotal += playerMintCount;
        playerRows.push({
          address: player.address,
          spent: summary.spent,
          ethWinnings: summary.ethWinnings,
          coinAwardWei: summary.coinAwardTotal,
          coinValueWei: summary.coinValueWei,
          totalValue: summary.totalValue,
          netWei: summary.netWei,
          mintCount: playerMintCount,
        });
      }
      return {
        label,
        playerCount: groupPlayers.length,
        totals: {
          spent: spentTotal,
          ethWinnings: ethWinningsTotal,
          coinValue: coinValueTotal,
          totalValue,
          net: netTotal,
          coinAwarded: coinAwardedTotal,
          mintCount: mintCountTotal,
        },
        rows: playerRows,
        isBucket,
        isDayOne,
      };
    };

    const bucketSummaries = bucketGroups
      .map((bucket, idx) => {
        if (!bucket || bucket.players.length === 0) return null;
        const isDayOneBucket = bucket.label === "Day 1" || idx === 0;
        return buildGroupSummary(bucket.label, bucket.players, { isBucket: true, isDayOne: isDayOneBucket });
      })
      .filter(Boolean);
    if (bucketSummaries.length !== 0) {
      console.log("Bucket profitability totals");
      console.table(
        bucketSummaries.map((summary) => ({
          bucket: summary.label,
          players: summary.playerCount,
          spent: formatEth(summary.totals.spent),
          ethWinnings: formatEth(summary.totals.ethWinnings),
          coinAwarded: formatCoinThousands(summary.totals.coinAwarded),
          coinValue: formatEth(summary.totals.coinValue),
          winningsInclCoin: formatEth(summary.totals.totalValue),
          net: formatEth(summary.totals.net),
        }))
      );
      for (const summary of bucketSummaries) {
        if (summary.rows.length === 0) continue;
        console.log(`${summary.label} player breakdown`);
        console.table(
          summary.rows.map((entry) => ({
            player: shortenAddress(entry.address),
            spent: formatEth(entry.spent),
            ethWinnings: formatEth(entry.ethWinnings),
            coinAwarded: formatCoinThousands(entry.coinAwardWei),
            coinValue: formatEth(entry.coinValueWei),
            winningsInclCoin: formatEth(entry.totalValue),
            net: formatEth(entry.netWei),
          }))
        );
        if (summary.isDayOne) {
          const sorted = [...summary.rows].sort((a, b) => {
            if (a.netWei === b.netWei) return 0;
            return a.netWei < b.netWei ? 1 : -1;
          });
          const top = sorted.slice(0, 3);
          const bottom = sorted.slice(-3).reverse();
          if (top.length !== 0) {
            console.log(`${summary.label} top 3`);
            console.table(
              top.map((entry) => ({
                player: shortenAddress(entry.address),
                net: formatEth(entry.netWei),
                spent: formatEth(entry.spent),
                winningsInclCoin: formatEth(entry.totalValue),
                coinAwarded: formatCoinThousands(entry.coinAwardWei),
              }))
            );
          }
          if (bottom.length !== 0) {
            console.log(`${summary.label} bottom 3`);
            console.table(
              bottom.map((entry) => ({
                player: shortenAddress(entry.address),
                net: formatEth(entry.netWei),
                spent: formatEth(entry.spent),
                winningsInclCoin: formatEth(entry.totalValue),
                coinAwarded: formatCoinThousands(entry.coinAwardWei),
              }))
            );
          }
        }
      }
    }

    if (questStrategyPlayers.length !== 0) {
      const questSummary = buildGroupSummary("Quest strategy", questStrategyPlayers);
      console.log("Quest strategy totals");
      console.table([
        {
          group: questSummary.label,
          players: questSummary.playerCount,
          spent: formatEth(questSummary.totals.spent),
          ethWinnings: formatEth(questSummary.totals.ethWinnings),
          coinAwarded: formatCoinThousands(questSummary.totals.coinAwarded),
          coinValue: formatEth(questSummary.totals.coinValue),
          winningsInclCoin: formatEth(questSummary.totals.totalValue),
          net: formatEth(questSummary.totals.net),
        },
      ]);
      if (questSummary.rows.length !== 0) {
        console.log("Quest strategy player breakdown");
        console.table(
          questSummary.rows.map((entry) => ({
            player: shortenAddress(entry.address),
            spent: formatEth(entry.spent),
            ethWinnings: formatEth(entry.ethWinnings),
            coinAwarded: formatCoinThousands(entry.coinAwardWei),
            coinValue: formatEth(entry.coinValueWei),
            winningsInclCoin: formatEth(entry.totalValue),
            net: formatEth(entry.netWei),
          }))
        );
      }
    }

    await snapshotMoneyBuckets("Simulation complete", bucketContext);
  });
});
