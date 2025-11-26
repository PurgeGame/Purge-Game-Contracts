const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const fs = require("fs");
const path = require("path");
const abiCoder = ethers.AbiCoder.defaultAbiCoder();

// ============================================================================ 
// Constants & Config
// ============================================================================ 
const MILLION = 1_000_000n;
const DAY_SECONDS = 24 * 60 * 60;
const JACKPOT_RESET_TIME = 82620;
const QUEST_SLOT_COUNT = 2;
const QUEST_MINT_ATTEMPT_LIMIT = 8;
const QUEST_TIER_STREAK_SPAN = 7;
const QUEST_TIER_MAX_INDEX = 10;
const QUEST_MIN_MINT = 1;
const QUEST_MIN_TOKEN = 250;

const QUEST_TYPES = {
  MINT_ANY: 0,
  MINT_ETH: 1,
  FLIP: 2,
  STAKE: 3,
  AFFILIATE: 4,
  PURGE: 5,
  DECIMATOR: 6,
};

const QUEST_PACKED_VALUES = {
  mintAny: 0x0000000000000000000000080008000800080008000700060005000400030002n,
  mintEth: 0x0000000000000000000000050005000400040004000300030002000200020001n,
  flip: 0x0000000000000000000009c409c408fc076c060e04e203e80320028a01f40190n,
  stakePrincipal: 0x0000000000000000000009c409c40898072105dc04c903e8033902a3020d0190n,
  stakeDistanceMin: 0x00000000000000000000001900190019001900190019001900190014000f000an,
  stakeDistanceMax: 0x00000000000000000000004b004b004b004b00460041003c00370032002d0028n,
  affiliate: 0x00000000000000000000060e060e060e060e060e060e04e203e80320028a01f4n,
};

const QUEST_COMPLETION_PARAMS = {
  mintQuantity: 1,
  purgeQuantity: 1,
  flipAmount: 250n * MILLION,
  stakePrincipal: 250n * MILLION,
  stakeDistance: 120,
  stakeRisk: 14,
  affiliateAmount: 100n * MILLION,
  decimatorAmount: 100n * MILLION,
};

const MAX_SIMULATION_DAYS = 200;
const PANIC_DAY_THRESHOLD = 12;

const CUSTOM_ERROR_SELECTORS = {
  NotTimeYet: "0xb473605e",
  RngNotReady: "0xbb3e844f",
};

// ============================================================================ 
// Core Helpers
// ============================================================================ 

// --- Quest RNG Helpers ---
function questTier(streak) {
    const tier = Math.floor(Number(streak) / QUEST_TIER_STREAK_SPAN);
    return tier > QUEST_TIER_MAX_INDEX ? QUEST_TIER_MAX_INDEX : tier;
}

function questPackedValue(packed, tier) {
    const p = BigInt(packed);
    const t = BigInt(tier);
    return Number((p >> (t * 16n)) & 0xFFFFn);
}

function questRand(entropy, questType, tier, salt) {
    if (!entropy || entropy === 0n) return 0n;
    return BigInt(ethers.solidityPackedKeccak256(
        ["uint256", "uint8", "uint8", "uint8"],
        [entropy, questType, tier, salt]
    ));
}

function getQuestTargets(quest, streak) {
    const tier = questTier(streak);
    const entropy = quest.entropy;
    const type = Number(quest.questType);
    
    const result = { quantity: 1, amount: 0n, distance: 0, risk: 0 };

    if (type === QUEST_TYPES.MINT_ANY) {
        const maxVal = questPackedValue(QUEST_PACKED_VALUES.mintAny, tier);
        if (maxVal <= QUEST_MIN_MINT) {
            result.quantity = QUEST_MIN_MINT;
        } else {
            const rand = questRand(entropy, type, tier, 0);
            result.quantity = Number((rand % BigInt(maxVal)) + BigInt(QUEST_MIN_MINT));
        }
    } else if (type === QUEST_TYPES.MINT_ETH) {
        if (tier === 0) {
            result.quantity = QUEST_MIN_MINT;
        } else {
            const maxVal = questPackedValue(QUEST_PACKED_VALUES.mintEth, tier);
            if (maxVal <= QUEST_MIN_MINT) {
                result.quantity = QUEST_MIN_MINT;
            } else {
                const rand = questRand(entropy, type, tier, 0);
                result.quantity = Number((rand % BigInt(maxVal)) + BigInt(QUEST_MIN_MINT));
            }
        }
    } else if (type === QUEST_TYPES.FLIP) {
        const maxVal = questPackedValue(QUEST_PACKED_VALUES.flip, tier);
        const range = BigInt(maxVal) - BigInt(QUEST_MIN_TOKEN) + 1n;
        const rand = questRand(entropy, type, tier, 0);
        result.amount = (BigInt(QUEST_MIN_TOKEN) + (rand % range)) * MILLION;
    } else if (type === QUEST_TYPES.STAKE) {
        const maxVal = questPackedValue(QUEST_PACKED_VALUES.stakePrincipal, tier);
        const range = BigInt(maxVal) - BigInt(QUEST_MIN_TOKEN) + 1n;
        const rand = questRand(entropy, type, tier, 1);
        result.amount = (BigInt(QUEST_MIN_TOKEN) + (rand % range)) * MILLION; // principal
        
        const minDist = questPackedValue(QUEST_PACKED_VALUES.stakeDistanceMin, tier);
        const maxDist = questPackedValue(QUEST_PACKED_VALUES.stakeDistanceMax, tier);
        const rangeDist = BigInt(maxDist) - BigInt(minDist) + 1n;
        const randDist = questRand(entropy, type, tier, 2);
        result.distance = Number(BigInt(minDist) + (randDist % rangeDist));
        
        // Risk from quest object directly
        result.risk = Number(quest.stakeRisk);
    } else if (type === QUEST_TYPES.AFFILIATE) {
        const maxVal = questPackedValue(QUEST_PACKED_VALUES.affiliate, tier);
        const range = BigInt(maxVal) - BigInt(QUEST_MIN_TOKEN) + 1n;
        const rand = questRand(entropy, type, tier, 0);
        result.amount = (BigInt(QUEST_MIN_TOKEN) + (rand % range)) * MILLION;
    } else if (type === QUEST_TYPES.PURGE) {
        // Same as Mint ETH logic for target
        if (tier === 0) {
            result.quantity = QUEST_MIN_MINT;
        } else {
            const maxVal = questPackedValue(QUEST_PACKED_VALUES.mintEth, tier);
            if (maxVal <= QUEST_MIN_MINT) {
                result.quantity = QUEST_MIN_MINT;
            } else {
                const rand = questRand(entropy, type, tier, 0);
                result.quantity = Number((rand % BigInt(maxVal)) + BigInt(QUEST_MIN_MINT));
            }
        }
    } else if (type === QUEST_TYPES.DECIMATOR) {
       // Logic: base flip target * 2
        const maxVal = questPackedValue(QUEST_PACKED_VALUES.flip, tier);
        const range = BigInt(maxVal) - BigInt(QUEST_MIN_TOKEN) + 1n;
        const rand = questRand(entropy, QUEST_TYPES.FLIP, tier, 0); // Uses flip type hash
        const base = (BigInt(QUEST_MIN_TOKEN) + (rand % range));
        result.amount = base * 2n * MILLION;
    }
    
    return result;
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

  const MockStETH = await ethers.getContractFactory("MockStETH");
  const steth = await MockStETH.deploy();
  await steth.waitForDeployment();

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
    await link.getAddress(),
    await steth.getAddress()
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

let lastAdvanceTimestamp = null;
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
  cap = 1500,
  maxAttempts = 32,
}) {
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

async function executeStrategyMintCoin({
  player,
  targetLevel,
  purgeNFT,
  purgeGame,
  affiliateOverride,
  stats
}) {
  if (!stats) return;
  const playerStats = stats.get(player.address);
  if (playerStats.coinsToSpend <= 0n) return;

  const state = await purgeGame.gameState();
  if (Number(state) === 3) return;

  const info = await purgeGame.gameInfo();
  const priceCoin = await purgeGame.coinPriceUnit();
  // Cost per map in coin = roughly priceCoin / 4 (since mintAndPurge costs price/4, minus rebate)
  // Actually, in PurgeGameNFT.mintAndPurge:
  // coinCost = quantity * (priceUnit / 4)
  // mapRebate = (quantity / 4) * (priceUnit / 10)
  // Net burn = coinCost - mapRebate
  // For 1 map: cost = priceUnit/4. Rebate = 0 (integer division 1/4 = 0).
  // For 4 maps: cost = priceUnit. Rebate = priceUnit/10. Net = 0.9 * priceUnit. (0.225 per map)
  // Let's approximate cost as priceCoin / 4 for safety.
  
  const costPerMap = priceCoin / 4n;
  if (costPerMap === 0n) return;

  let quantity = playerStats.coinsToSpend / costPerMap;
  if (quantity < 1n) return;
  
  // Cap quantity per tx to avoid gas limits
  if (quantity > 150n) quantity = 150n;

  const affiliateCode = affiliateOverride ?? ethers.ZeroHash;

  try {
      const tx = await purgeNFT.connect(player).mintAndPurge(quantity, true, affiliateCode, { value: 0 });
      const receipt = await tx.wait();
      
      // Calculate actual spent? 
      // For simplicity, we deduct estimated cost. 
      // Or we can check balance difference, but that requires extra calls.
      // Let's just deduct quantity * costPerMap.
      const spent = quantity * costPerMap;
      playerStats.coinsToSpend -= spent;
      playerStats.tokensSpent += spent;
      playerStats.mapsPurchased += Number(quantity);

      // Capture token IDs
      for (const log of receipt.logs) {
          if (log.address === await purgeNFT.getAddress()) {
              try {
                  const parsed = purgeNFT.interface.parseLog(log);
                  if (parsed.name === 'Transfer' && parsed.args[1] === player.address && parsed.args[0] === ethers.ZeroAddress) {
                     playerStats.tokenIds.push(parsed.args[2]);
                  }
              } catch (e) {}
          }
      }
      return { quantity };
  } catch (err) {
      // Ignore errors (e.g. out of gas, or exact balance mismatch)
  }
}

// --- Game Rules Helpers ---
function getMinMapQuantity(level) {
    const lvl = Number(level);
    if (lvl === 0) return 4; // Edge case
    const mod = lvl % 100;
    if (mod >= 60) return 1;
    if (mod >= 40) return 2;
    return 4;
}

async function executeStrategyMint({
  player,
  quantity,
  targetLevel,
  purgeNFT,
  purgeGame,
  affiliateOverride,
  vrf,
  vrfConsumer,
  advanceOperator,
  stats
}) {
  const info = await purgeGame.gameInfo();
  // Ensure quantity meets minimum for the target level
  const minQty = getMinMapQuantity(targetLevel);
  const finalQty = quantity < minQty ? minQty : quantity;
  
  const price = info.price_;
  const mapCost = (price * BigInt(finalQty) * 25n) / 100n;
  const affiliateCode = affiliateOverride ?? ethers.ZeroHash;
  
  for (let attempt = 0; attempt < 5; attempt++) {
      try {
          const tx = await purgeNFT.connect(player).mintAndPurge(finalQty, false, affiliateCode, {
              value: mapCost,
            });
          const receipt = await tx.wait();
          
          // Capture token IDs from Transfer events (Mint: from 0x0 to player)
          if (stats) {
              const playerStats = stats.get(player.address);
              for (const log of receipt.logs) {
                  if (log.address === await purgeNFT.getAddress()) {
                      try {
                          const parsed = purgeNFT.interface.parseLog(log);
                          if (parsed.name === 'Transfer' && parsed.args[1] === player.address && parsed.args[0] === ethers.ZeroAddress) {
                             playerStats.tokenIds.push(parsed.args[2]);
                          }
                      } catch (e) {}
                  }
              }
          }

          return { cost: mapCost, quantity: finalQty };
      } catch (err) {
          if (isCustomError(err, "RngNotReady") && vrf && vrfConsumer && advanceOperator) {        await fulfillPendingVrfRequest(vrf, vrfConsumer);
        // Must advance game to consume RNG and unlock
        try {
          await (await purgeGame.connect(advanceOperator).advanceGame(1500)).wait();
        } catch (advErr) {
          // ignore advance errors (e.g. NotTimeYet), just retry mint
        }
        continue;
      }
      throw err;
    }
  }
  throw new Error("executeStrategyMint failed after retries");
}

// ============================================================================ 
// Minimal Quest Helpers (Adapted)
// ============================================================================ 

async function completeDailyQuestsMinimal({
  purgecoin,
  questModule,
  purgeNFT,
  purgeGame,
  questPlayers,
  vrf,
  vrfConsumer,
  advanceOperator,
  stats
}) {
  if (!questPlayers || questPlayers.length === 0) return;

  const [quests, questDetails] = await Promise.all([purgecoin.getActiveQuests(), questModule.getQuestDetails()]);

  for (const player of questPlayers) {
      // 1. Onboarding Check
      const lastLevel = await purgeGame.ethMintLastLevel(player.address);
      const currentLevel = await purgeGame.level();
      const needsOnboarding = lastLevel == 0n || (BigInt(currentLevel) > lastLevel && (BigInt(currentLevel) - lastLevel > 3n));

      if (needsOnboarding) {
          const minQty = getMinMapQuantity(currentLevel);
          try {
              const result = await executeStrategyMint({
                  player,
                  quantity: minQty,
                  targetLevel: currentLevel,
                  purgeNFT,
                  purgeGame,
                  vrf,
                  vrfConsumer,
                  advanceOperator,
                  stats
              });
              if (stats) {
                stats.get(player.address).ethSpent += result.cost;
                stats.get(player.address).mapsPurchased += result.quantity;
              }
          } catch (e) {
              // console.log(`    Onboarding failed for ${player.address.slice(0,6)}: ${e.message}`);
          }
      }

      // 2. Daily Quests
      const [streak, , progress, completed] = await purgecoin.playerQuestStates(player.address);
      
      for (let slot = 0; slot < QUEST_SLOT_COUNT; slot++) {
          const quest = quests[slot];
          if (quest.day === 0n) continue;
          if (completed[slot]) continue;

          const questType = Number(quest.questType);
          const targets = getQuestTargets(quest, streak);
          
          // Calculate remaining work
          const currentProgress = progress[slot];
          
          try {
            if (questType === QUEST_TYPES.MINT_ANY || questType === QUEST_TYPES.MINT_ETH) {
                 const targetQty = BigInt(targets.quantity);
                 const needed = targetQty > currentProgress ? targetQty - currentProgress : 0n;
                 if (needed === 0n) continue;
                 
                 const qtyToMint = Number(needed); // Safe cast for small int
                 
                 let usedCoin = false;
                 
                 // Try Coin Mint for MINT_ANY
                 if (questType === QUEST_TYPES.MINT_ANY) {
                     const minQty = getMinMapQuantity(currentLevel);
                     const effectiveQty = qtyToMint < minQty ? minQty : qtyToMint;
                     
                     const priceCoin = await purgeGame.coinPriceUnit();
                     const cost = (priceCoin / 4n) * BigInt(effectiveQty);
                     const bal = await purgecoin.balanceOf(player.address);

                     const state = await purgeGame.gameState();
                     
                     if (Number(state) !== 3 && bal >= cost) {
                         try {
                             await (await purgeNFT.connect(player).mintAndPurge(effectiveQty, true, ethers.ZeroHash, { value: 0 })).wait();
                             if (stats) {
                                 const ps = stats.get(player.address);
                                 ps.tokensSpent += cost;
                                 ps.mapsPurchased += effectiveQty;
                             }
                             usedCoin = true;
                         } catch(e) {}
                     }
                 }
    
                 if (!usedCoin) {
                      // For ETH mint, also ensure min quantity
                      const minQty = getMinMapQuantity(currentLevel);
                      const effectiveQty = qtyToMint < minQty ? minQty : qtyToMint;

                      try {
                          const result = await executeStrategyMint({
                              player,
                              quantity: effectiveQty,
                              purgeNFT,
                              purgeGame,
                              vrf,
                              vrfConsumer,
                              advanceOperator,
                              stats
                          });
                          if (stats) {
                            stats.get(player.address).ethSpent += result.cost;
                            stats.get(player.address).mapsPurchased += result.quantity;
                          }
                      } catch (e) {
                          // console.log(`    Quest Mint failed for ${player.address.slice(0,6)}: ${e.message}`);
                      }
                 }
            } else if (questType === QUEST_TYPES.FLIP) {
              const targetAmt = targets.amount;
              const needed = targetAmt > currentProgress ? targetAmt - currentProgress : 0n;
              if (needed > 0n) {
                  await (await purgecoin.connect(player).depositCoinflip(needed)).wait();
              }
            } else if (questType === QUEST_TYPES.PURGE) {
              const ownedIds = stats.get(player.address).tokenIds;
              if (ownedIds.length > 0) {
                  const fetchCount = ownedIds.length > targets.quantity ? targets.quantity : ownedIds.length;
                  const idsToPurge = ownedIds.splice(0, fetchCount);
                  if (idsToPurge.length > 0) {
                      const info = await purgeGame.gameInfo();
                      if (Number(info.gameState_) === 3) {
                          await (await purgeGame.connect(player).purge(idsToPurge)).wait();
                      }
                  }
              }
            } else if (questType === QUEST_TYPES.STAKE) {
              const principal = targets.amount;
              const distance = targets.distance;
              const risk = targets.risk;
              const safeRisk = risk > 11 ? 11 : risk;
              
              const bal = await purgecoin.balanceOf(player.address);
              if (bal >= principal) {
                  const currentLevel = await purgeGame.level();
                  let effectiveLevel = Number(currentLevel);
                  const state = Number(await purgeGame.gameState());
                  if (state !== 3 && effectiveLevel > 0) effectiveLevel -= 1;
                  
                  const targetLevel = effectiveLevel + distance;
                  
                  try {
                      await (await purgecoin.connect(player).stake(principal, targetLevel, safeRisk)).wait();
                      if (stats) {
                          const ps = stats.get(player.address);
                          ps.stakes.push({
                              principal: principal,
                              startLevel: Number(currentLevel),
                              distance: distance,
                              risk: safeRisk
                          });
                      }
                  } catch (e) {}
              }
            } else if (questType === QUEST_TYPES.DECIMATOR) {
                 const targetAmt = targets.amount;
                 const needed = targetAmt > currentProgress ? targetAmt - currentProgress : 0n;
                 if (needed > 0n) {
                     try {
                         await (await purgecoin.connect(player).decimatorBurn(needed)).wait();
                     } catch(e) {}
                 }
            }
          } catch (err) {
            // Ignore
          }
      }
  }
}

// ============================================================================ 
// Simulation Spec
// ============================================================================ 

describe("PurgeGame Strategy Simulation", function () {
  this.timeout(0);

  let system;
  let buckets = new Map(); // Map<string, Wallet[]>
  let stats = new Map();   // Map<address, Stats>
  let primaryFunder;
  let mintDayCounters = new Map(); // Map<level, number>

    async function getBucket(name, count = 5, fundAmount = ethers.parseEther("200")) {
        if (buckets.has(name)) return buckets.get(name);
  
        const newWallets = await createWallets(count, primaryFunder, fundAmount);    buckets.set(name, newWallets);

                    for (const wallet of newWallets) {

                        // Get initial token balance if any (e.g. funded quest completers)

                        const initialTokenBal = await system.purgecoin.balanceOf(wallet.address);

                        

                        stats.set(wallet.address, {

                            bucket: name,

                            ethSpent: 0n,

                            ethClaimed: 0n,

                            mapsPurchased: 0,

                            initialBalance: fundAmount,

                                              tokenIds: [], // Track owned tokens off-chain

                                              lastLevelTokenBalance: initialTokenBal,

                                              coinsToSpend: 0n,

                                              tokensSpent: 0n,
                                              
                                              decimatorCoins: 0n, // Track Decimator burn amount

                                                                                                                                          stakes: [] // { principal, startLevel, risk, distance }

                                                                                            

                                                                                                                                      });

                                                                                                                }

                                                                                            

                                                                                                                return newWallets;

                }
  it("Simulates gameplay with dynamic daily buckets (10 Runs Average)", async function () {
    const SIMULATION_RUNS = 10;
    const globalAggregates = {}; 

    console.log(`Starting ${SIMULATION_RUNS} simulation runs...`);

    for (let run = 1; run <= SIMULATION_RUNS; run++) {
        console.log(`\n--- Run ${run}/${SIMULATION_RUNS} ---`);
        
        // 1. Reset State
        buckets = new Map();
        stats = new Map();
        mintDayCounters = new Map();
        for (let i = 1; i <= 26; i++) mintDayCounters.set(i, 1);

        // 2. Setup Chain
        [primaryFunder] = await ethers.getSigners();
        await network.provider.send("hardhat_setBalance", [
            primaryFunder.address, 
            "0x152D02C7E14AF6800000" // 100,000 ETH
        ]);

        system = await deploySystem();
        const { purgeGame, purgeNFT, purgecoin, vrf } = system;
        const advanceOperator = primaryFunder;
        const vrfConsumer = await purgeGame.getAddress();

        // 3. Setup Quest Completers
        const qcName = "Quest Completer";
        const qcWallets = await getBucket(qcName, 5, ethers.parseEther("100"));
        const tokenAmount = ethers.parseUnits("50000", 6);
        for (const wallet of qcWallets) {
            await (await purgecoin.connect(primaryFunder).transfer(wallet.address, tokenAmount)).wait();
        }
        // 4. Run Simulation Loop
        let gameLevel = 1;
        const specialEventsTriggered = new Set();
        const globalDecimatorBurns = {}; 

        const log = (msg) => { if(run === 1) console.log(msg); }; // Only log details for run 1

        // --- Event Tracking ---
        await purgeGame.addListener("PlayerCredited", (player, amount) => {
            if (stats.has(player)) {
                const s = stats.get(player);
                const val = BigInt(amount);
                if (gameLevel === 21) {
                    s.bafRewards = (s.bafRewards || 0n) + val;
                } else if (gameLevel === 26) {
                    s.decRewards = (s.decRewards || 0n) + val;
                }
            }
        });

    // We will simulate up to the start of Level 26 (processing L25) and then process L26 to capture L25 payouts
    try {
    while (gameLevel <= 26) {
      log(`\n=== Processing Level ${gameLevel} ===`);

      // ------------------------------------------------------
      // Phase: Purchase (State 2)
      // ------------------------------------------------------

      let info = await purgeGame.gameInfo();
      let state = Number(info.gameState_);

      // Advance to State 2 if needed
      while (state !== 2 && state !== 3) {
        await runAdvanceGameTick({ purgeGame, vrf, vrfConsumer, operator: advanceOperator, label: "seek-purchase" });
        info = await purgeGame.gameInfo();
        state = Number(info.gameState_);
      }

      if (state === 2) {
        log(`Level ${gameLevel} Purchase Phase (State 2)`);

        while (state === 2) {
          const currentMintDay = mintDayCounters.get(gameLevel) || 1;
          if (currentMintDay > MAX_SIMULATION_DAYS) {
            throw new Error(`Simulation stuck in State 2 for >${MAX_SIMULATION_DAYS} days. Check prize pool targets.`);
          }

          // Only mint if we are in the accumulation phase (<= 2) AND haven't reached target
          // If phase > 2, we are processing airdrops/jackpots, so just advance.
          const phase = Number(info.phase_);
          const targetReached = info.prizePoolCurrent >= info.prizePoolTarget;
          const shouldMint = phase <= 2 && (!targetReached || currentMintDay === 1);

          // Special Events at Level 20: BAF Prep
                        // Special Events at Level 20: BAF Prep
                        /* 
                        if (gameLevel === 20 && !specialEventsTriggered.has(20)) {
                            specialEventsTriggered.add(20);
                            log("    !!! PREPPING LEVEL 20 BAF ELIGIBILITY (ALL PLAYERS) !!!");
                            for (const [address, data] of stats) {
                                try {
                                    const playerWallet = buckets.get(data.bucket).find(w => w.address === address);
                                    if (!playerWallet) continue;
                                    const flipped = await purgecoin.coinflipAmount(address);
                                    const target = 6000n * 1000000n;
                                    if (flipped < target) {
                                        const needed = target - flipped;
                                        const bal = await purgecoin.balanceOf(address);
                                        if (bal < needed) {
                                            const fundAmt = needed - bal;
                                            await (await purgecoin.connect(primaryFunder).transfer(address, fundAmt)).wait();
                                        }
                                        await (await purgecoin.connect(playerWallet).depositCoinflip(needed)).wait();
                                    }
                                } catch (e) {}
                            }
                        }
                        */

          // Special Events at Level 25
          if (gameLevel === 25 && !specialEventsTriggered.has(25)) {
              specialEventsTriggered.add(25);

              // Ensure RNG is unlocked before burning
              let rngIsLocked = await purgeGame.rngLocked();
              if (rngIsLocked) {
                  log("    RNG Locked at L25 start. Attempting to unlock...");
                  while (rngIsLocked) {
                      await runAdvanceGameTick({ purgeGame, vrf, vrfConsumer, operator: advanceOperator, label: `L${gameLevel}-unlock-rng` });
                      rngIsLocked = await purgeGame.rngLocked();
                      if (rngIsLocked) {
                          // This suggests a persistent lock, possibly due to multiple steps in transition
                          log("    RNG still locked. Advancing another tick.");
                      }
                  }
                  log("    RNG unlocked for L25 special actions.");
              }

              log("    !!! EXECUTING LEVEL 25 SPECIAL ACTIONS (DECIMATOR & BAF) !!!");
              
              let playerIndex = 0;
              for (const [address, data] of stats) {
                  const playerWallet = buckets.get(data.bucket).find(w => w.address === address);
                  if (!playerWallet) continue;

                  const isBafEligible = (playerIndex % 2 === 0);

                  // 1. BAF Qualification (Priority)
                  if (isBafEligible) {
                      if (data.tokenIds && data.tokenIds.length > 0) {
                          for (const tid of data.tokenIds) {
                              try {
                                  const tData = await system.purgeTrophies.trophyData(tid);
                                  const isBaf = (tData & (1n << 203n)) !== 0n;
                                  const alreadyStaked = await system.purgeTrophies.isTrophyStaked(tid);
                                  
                                  if (isBaf && !alreadyStaked) {
                                       const bal = await purgecoin.balanceOf(address);
                                       if (bal >= 5000n * MILLION) {
                                           await (await system.purgeTrophies.connect(playerWallet).setTrophyStake(tid, true)).wait();
                                           console.log(`      Player ${address.slice(0,6)} staked BAF Trophy ${tid}`);
                                       }
                                  }
                              } catch(e) {}
                          }
                      }
                  }

                  // 2. Decimator Burn (80% of remaining liquid tokens)
                  try {
                      const bal = await purgecoin.balanceOf(address);
                      if (bal > 0n) {
                          const burnAmt = (bal * 80n) / 100n;
                              await (await purgecoin.connect(playerWallet).decimatorBurn(burnAmt)).wait();
                              // Record burn
                              data.decimatorCoins += burnAmt;
                              globalDecimatorBurns[address] = (globalDecimatorBurns[address] || 0n) + burnAmt;
                          }
                  } catch(e) {
                      console.log("Decimator Burn Error:", e.message);
                  }
                  
                  playerIndex++;
              }
          }

          // Coin Minting Strategy: Spend earned coins on Day 1 of Purchase Phase
          if (currentMintDay === 1) {
              for (const [bucketName, walletList] of buckets.entries()) {
                  // Exclude Mint_Day_1_Single from coin recycling; they stick to their ETH strategy
                  if (bucketName === "Mint_Day_1_Single") continue;

                  for (const player of walletList) {
                       await executeStrategyMintCoin({
                           player,
                           targetLevel: gameLevel,
                           purgeNFT,
                           purgeGame,
                           affiliateOverride: ethers.ZeroHash,
                           stats
                       });
                  }
              }
          }

          if (shouldMint) {
            const bucketName = `Mint_Day_${currentMintDay}`;

                                  // Dynamic quantity scaling (Panic Mode)
                                  let quantity = 150;
                                  if (currentMintDay > PANIC_DAY_THRESHOLD) {
                                      const multiplier = currentMintDay - PANIC_DAY_THRESHOLD + 1;
                                      quantity = Math.min(150 * multiplier, 300); // Cap at 300 to fit gas limits
                                      console.log(`    !!! PANIC MODE: Scaling mints to ${quantity} (Day ${currentMintDay}) !!!`);
                                  }
            // Execute Mints
            const bucket = await getBucket(bucketName);
            console.log(`  Minting for ${bucketName} (Pool: ${ethers.formatEther(info.prizePoolCurrent)} / ${ethers.formatEther(info.prizePoolTarget)})`);
            for (const player of bucket) {
              try {
                                         const result = await executeStrategyMint({
                                             player,
                                             quantity,
                                             targetLevel: gameLevel,
                                             purgeNFT,
                                             purgeGame,
                                             vrf,
                                             vrfConsumer,
                                             advanceOperator,
                                             stats
                                         });                stats.get(player.address).ethSpent += result.cost;
                stats.get(player.address).mapsPurchased += result.quantity;
              } catch (e) {
                  console.log(`    Mint failed for ${player.address.slice(0,6)}: ${e.message}`);
              }
            }
            // Increment mint day only if we actually minted a new cohort
            mintDayCounters.set(gameLevel, currentMintDay + 1);
          } else {
            console.log(`  Waiting for phase transition (Day ${currentMintDay}, Phase ${phase})`);
          }

          // Quest Completers
          await completeDailyQuestsMinimal({
            purgecoin,
            questModule: system.questModule,
            purgeNFT,
            purgeGame,
            questPlayers: await getBucket("Quest Completer"),
            vrf,
            vrfConsumer,
            advanceOperator,
            stats
          });

          // Advance
          await runAdvanceGameTick({ purgeGame, vrf, vrfConsumer, operator: advanceOperator, label: `L${gameLevel}-purch-d${currentMintDay}` });

          info = await purgeGame.gameInfo();
          state = Number(info.gameState_);
        }
      }

      // ------------------------------------------------------
      // Phase: Purge (State 3)
      // ------------------------------------------------------

      if (state === 3) {
        console.log(`Level ${gameLevel} Purge Phase (State 3)`);

        const purgingPlayers = [];
        for (const [name, walletList] of buckets.entries()) {
          if (name.startsWith("Mint_Day_")) {
            purgingPlayers.push(...walletList);
          }
        }
        purgingPlayers.push(...(await getBucket("Quest Completer")));

        const nextLevel = gameLevel + 1;
        let purgeDay = 1;
        let purgeActive = true;

        while (state === 3 && purgeActive) {
          const nextLevelMintDay = mintDayCounters.get(nextLevel) || 1;
          console.log(`  Purge Day ${purgeDay} (Next Level Mint Day ${nextLevelMintDay})`);

                            // 1. Purge Actions (Current Level)

                            for (const player of purgingPlayers) {

                                const playerStats = stats.get(player.address);

                                const ownedIds = playerStats ? playerStats.tokenIds : [];

                                

                                if (ownedIds.length > 0) {

                                    try {

                                        // Purge up to 5 tokens

                                        const fetchCount = ownedIds.length > 5 ? 5 : ownedIds.length;

                                        const idsToPurge = [];

                                        // Take from the end (LIFO) or beginning? End is more efficient for array.

                                        // But we need to remove them from the stats array if purged successfully.

                                        // Let's just pick the first 5.

                                        for(let k=0; k<fetchCount; k++) {

                                            idsToPurge.push(ownedIds[k]);

                                        }

                                        

                                        if(idsToPurge.length > 0) {

                                            await (await purgeGame.connect(player).purge(idsToPurge)).wait();

                                            // Remove successfully purged IDs from stats

                                            // Note: In a real app we'd check receipts, but here we assume success if no throw

                                            playerStats.tokenIds.splice(0, fetchCount);

                                        }

                                    } catch(e) { 

                                        // If purge fails (e.g. bad phase), we keep the tokens

                                    }

                                }

                            }

          // 2. Mint Actions (Next Level)
          if (nextLevel <= 25) {
            const bucketName = `Mint_Day_${nextLevelMintDay}`;
            const bucket = await getBucket(bucketName);
            console.log(`    Minting for ${bucketName}`);

            for (const player of bucket) {
              try {
                                               const result = await executeStrategyMint({
                                                   player,
                                                   quantity: 150,
                                                   targetLevel: nextLevel,
                                                   purgeNFT,
                                                   purgeGame,
                                                   vrf,
                                                   vrfConsumer,
                                                   advanceOperator,
                                                   stats
                                               });                stats.get(player.address).ethSpent += result.cost;
                stats.get(player.address).mapsPurchased += result.quantity;
              } catch (e) { }
            }

                                  // Special Strategy: Day 1 Single Minter (Mints 4 tokens every level on Day 1)
                                  if (nextLevelMintDay === 1 && nextLevel <= 25) {
                                      const singleBucketName = "Mint_Day_1_Single";
                                      const singleBucket = await getBucket(singleBucketName, 200);
                                      console.log(`    Minting for ${singleBucketName} (4 Maps)`);              for (const player of singleBucket) {
                try {
                                                     const result = await executeStrategyMint({
                                                         player,
                                                         quantity: 4,
                                                         targetLevel: nextLevel,
                                                         purgeNFT,
                                                         purgeGame,
                                                         vrf,
                                                         vrfConsumer,
                                                         advanceOperator,
                                                         stats
                                                     });                  stats.get(player.address).ethSpent += result.cost;
                  stats.get(player.address).mapsPurchased += result.quantity;
                } catch (e) { }
              }
            }

            mintDayCounters.set(nextLevel, nextLevelMintDay + 1);
          }

          // 3. Quest Completers
          await completeDailyQuestsMinimal({
            purgecoin,
            questModule: system.questModule,
            purgeNFT,
            purgeGame,
            questPlayers: await getBucket("Quest Completer"),
            vrf,
            vrfConsumer,
            advanceOperator,
            stats
          });

          // 4. Advance
          await runAdvanceGameTick({ purgeGame, vrf, vrfConsumer, operator: advanceOperator, label: `L${gameLevel}-purge-d${purgeDay}` });
          purgeDay++;

          info = await purgeGame.gameInfo();
          state = Number(info.gameState_);

          if (purgeDay > 15) purgeActive = false;
        }
      }
      
      // End of Level: Update Coin Balances and calculate spendable amount for next level
      // Iterate all known wallets in stats
      for (const [address, data] of stats) {
          try {
              const currentBal = await purgecoin.balanceOf(address);
              const earned = currentBal > data.lastLevelTokenBalance ? currentBal - data.lastLevelTokenBalance : 0n;
              
              // Set 75% of earned coins to spend next level
              data.coinsToSpend = (earned * 75n) / 100n;
              
              // Update snapshot for next level tracking
              data.lastLevelTokenBalance = currentBal;
          } catch (e) {}
      }

      gameLevel++;
    }
    } catch (err) {
        log(`\nSimulation stopped early due to error: ${err.message}`);
    }


    // Harvest Data for this Run
    for (const [name, wallets] of buckets) {
        if (!globalAggregates[name]) {
            globalAggregates[name] = { 
                spent: 0n, claimed: 0n, tokens: 0n, maps: 0, 
                bafEth: 0n, decEth: 0n, decCoins: 0n, 
                count: 0 
            };
        }
        const g = globalAggregates[name];
        for (const w of wallets) {
            const s = stats.get(w.address);
            let claimable = 0n;
            try {
                claimable = await purgeGame.connect(w).getWinnings();
                // Trophies
                if (s.tokenIds) {
                    for (const tid of s.tokenIds) {
                        const raw = await system.purgeTrophies.trophyData(tid);
                        const owed = raw & ((1n << 128n) - 1n);
                        if (owed > 0n) claimable += owed;
                    }
                }
            } catch(e) {}
            
            const totalValue = (claimable > 1n ? claimable - 1n : 0n) + s.ethClaimed;
            const currentBal = await purgecoin.balanceOf(w.address);
            
            g.spent += s.ethSpent;
            g.claimed += totalValue;
            g.tokens += currentBal;
            g.maps += s.mapsPurchased;
            g.bafEth += s.bafRewards || 0n;
            g.decEth += s.decRewards || 0n;
            g.decCoins += globalDecimatorBurns[w.address] || 0n;
        }
        g.count++;
    }
  } // End of Runs Loop

  // Final Reporting
  const sortedKeys = Object.keys(globalAggregates).sort((a, b) => {
      if (a.startsWith("Mint_Day_") && b.startsWith("Mint_Day_")) {
          return parseInt(a.replace("Mint_Day_", ""), 10) - parseInt(b.replace("Mint_Day_", ""), 10);
      }
      return a.localeCompare(b);
  });

  const { purgeGame: finalPurgeGame } = system; 
  const finalMintPrice = await finalPurgeGame.mintPrice();
  const finalCoinPrice = await finalPurgeGame.coinPriceUnit();
  const getTokenValueEth = (rawTokenAmount) => {
      return Number(ethers.formatEther((rawTokenAmount * finalMintPrice * 80n) / (finalCoinPrice * 100n)));
  };
  const divBigInt = (val, div) => Number(ethers.formatEther(val)) / div;

  console.log(`\n\n=== AVERAGED SIMULATION RESULTS (${SIMULATION_RUNS} RUNS) ===`);
  console.log("Bucket".padEnd(25) + " | Avg Spent | Avg Claim | Avg Net | Avg Tokens | Avg Val | BAF ETH | Dec ETH | Dec Coins");
  console.log("-".repeat(110));

  for (const name of sortedKeys) {
      const g = globalAggregates[name];
      const runs = SIMULATION_RUNS;
      
      const avgSpent = divBigInt(g.spent, runs).toFixed(2);
      const avgClaim = divBigInt(g.claimed, runs).toFixed(2);
      const avgNet = (divBigInt(g.claimed, runs) - divBigInt(g.spent, runs)).toFixed(2);
      
      const avgTokensRaw = Number(ethers.formatUnits(g.tokens, 6)) / runs;
      const avgTokensFmt = avgTokensRaw > 1000000 ? (avgTokensRaw/1000000).toFixed(2) + "M" : (avgTokensRaw/1000).toFixed(0) + "k";
      
      const avgTokenValEth = getTokenValueEth(g.tokens / BigInt(runs));
      const avgVal = (Number(avgNet) + avgTokenValEth).toFixed(2);

      const avgBaf = divBigInt(g.bafEth, runs).toFixed(2);
      const avgDec = divBigInt(g.decEth, runs).toFixed(2);
      
      const avgDecCoinsRaw = Number(ethers.formatUnits(g.decCoins, 6)) / runs;
      const avgDecCoinsFmt = avgDecCoinsRaw > 1000000 ? (avgDecCoinsRaw/1000000).toFixed(2) + "M" : (avgDecCoinsRaw/1000).toFixed(0) + "k";

      console.log(`${name.padEnd(25)} | ${avgSpent.padEnd(9)} | ${avgClaim.padEnd(9)} | ${avgNet.padEnd(7)} | ${avgTokensFmt.padEnd(10)} | ${avgVal.padEnd(7)} | ${avgBaf.padEnd(7)} | ${avgDec.padEnd(7)} | ${avgDecCoinsFmt}`);
  }
  console.log("\nSimulation Complete.");
});
});
