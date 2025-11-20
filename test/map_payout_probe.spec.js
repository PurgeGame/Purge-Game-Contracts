const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const DAY_SECONDS = 24 * 60 * 60;
const JACKPOT_RESET_TIME = 82620;

function randomJackpotWord(label = "vrf") {
  const timeSalt = BigInt(Date.now());
  const randomSalt = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER));
  return BigInt(ethers.solidityPackedKeccak256(["string", "uint256", "uint256"], [label, timeSalt, randomSalt]));
}

async function deploySystem() {
  const [deployer] = await ethers.getSigners();
  const Renderer = await ethers.getContractFactory("MockRenderer");
  const renderer = await Renderer.deploy();
  const trophyRenderer = await Renderer.deploy();
  const VRF = await ethers.getContractFactory("MockVRFCoordinator");
  const vrf = await VRF.deploy(ethers.parseEther("500"));
  const Link = await ethers.getContractFactory("MockLinkToken");
  const link = await Link.deploy();
  const Purgecoin = await ethers.getContractFactory("Purgecoin");
  const purgecoin = await Purgecoin.deploy();
  const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
  const questModule = await QuestModule.deploy(await purgecoin.getAddress());
  const ExternalJackpot = await ethers.getContractFactory("PurgeCoinExternalJackpotModule");
  const externalJackpot = await ExternalJackpot.deploy();
  const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
  const purgeNFT = await PurgeGameNFT.deploy(await renderer.getAddress(), await trophyRenderer.getAddress(), await purgecoin.getAddress());
  const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
  const purgeTrophies = await PurgeGameTrophies.deploy(await purgeNFT.getAddress());
  const Endgame = await ethers.getContractFactory("PurgeGameEndgameModule");
  const endgameModule = await Endgame.deploy();
  const Jackpot = await ethers.getContractFactory("PurgeGameJackpotModule");
  const jackpotModule = await Jackpot.deploy();
  const PurgeGame = await ethers.getContractFactory("PurgeGame");
  const purgeGame = await PurgeGame.deploy(
    await purgecoin.getAddress(), await renderer.getAddress(), await purgeNFT.getAddress(), await purgeTrophies.getAddress(),
    await endgameModule.getAddress(), await jackpotModule.getAddress(), await vrf.getAddress(), ethers.ZeroHash, 1n, await link.getAddress()
  );
  await (await purgecoin.wire(await purgeGame.getAddress(), await purgeNFT.getAddress(), await purgeTrophies.getAddress(), await renderer.getAddress(), await trophyRenderer.getAddress(), await questModule.getAddress(), await externalJackpot.getAddress())).wait();
  
  return { purgeGame, purgecoin, purgeNFT, vrf, deployer };
}

async function fulfillPendingVrfRequest(vrf, consumer) {
  const requestId = await vrf.lastRequestId();
  if (requestId && requestId !== 0n) {
    await (await vrf.fulfill(consumer, requestId, randomJackpotWord())).wait();
  }
}

async function runAdvanceGameTick(purgeGame, vrf, vrfConsumer, operator) {
  try {
    await purgeGame.connect(operator).advanceGame(1500);
    await fulfillPendingVrfRequest(vrf, vrfConsumer);
  } catch (e) {
    if (e.message.includes("NotTimeYet") || e.message.includes("RngNotReady")) {
      await time.increase(DAY_SECONDS);
    }
  }
}

async function setRichBalance(address) {
  await ethers.provider.send("hardhat_setBalance", [
    address,
    "0x10000000000000000000000000000", // ~4.7M ETH in hex (increased from original 0x10000...)
  ]);
}

describe("Map Payout Probe", function () {
  this.timeout(0);
  let system, owner, referrer, player;

  before(async function () {
    system = await deploySystem();
    [owner, referrer, player] = await ethers.getSigners();
    
    await setRichBalance(owner.address);
    await setRichBalance(referrer.address);
    await setRichBalance(player.address);
    
    // Setup Referral
    const code = ethers.solidityPackedKeccak256(["string"], ["REF"]);
    await system.purgecoin.connect(referrer).createAffiliateCode(code, 10); // 10% rakeback
    await system.purgecoin.connect(player).referPlayer(code);
  });

  async function probePurchase(label) {
    const { purgeGame, purgeNFT, purgecoin } = system;
    const quantity = 4; // Minimum map purchase
    
    const balanceBefore = await purgecoin.balanceOf(player.address);
    const flipBefore = await purgecoin.coinflipAmount(player.address);
    const refBalanceBefore = await purgecoin.balanceOf(referrer.address);
    const refFlipBefore = await purgecoin.coinflipAmount(referrer.address);

    const info = await purgeGame.gameInfo();
    const price = info.price_;
    const cost = (price * BigInt(quantity) * 25n) / 100n;

    // Execute Mint
    await (await purgeNFT.connect(player).mintAndPurge(quantity, false, ethers.ZeroHash, { value: cost })).wait();

    const balanceAfter = await purgecoin.balanceOf(player.address);
    const flipAfter = await purgecoin.coinflipAmount(player.address);
    const refBalanceAfter = await purgecoin.balanceOf(referrer.address);
    const refFlipAfter = await purgecoin.coinflipAmount(referrer.address);

    // Analysis
    // Note: Tokens are often credited as "Flip Stake" (bonusCoinflip) rather than direct transfer
    const playerGain = (balanceAfter - balanceBefore) + (flipAfter - flipBefore);
    const refGain = (refBalanceAfter - refBalanceBefore) + (refFlipAfter - refFlipBefore);
    
    const total = playerGain + refGain;
    
    // Rough breakdown estimation based on known logic:
    // Affiliate: ~15% base? + Bonuses
    // Map Bonus: (Qty / 40) * PriceUnit?
    // Rakeback: 10% of Affiliate Reward goes to Player
    
    console.log(`${label.padEnd(20)} | Total: ${ethers.formatUnits(total, 6).padEnd(8)} | Player: ${ethers.formatUnits(playerGain, 6).padEnd(8)} | Ref: ${ethers.formatUnits(refGain, 6).padEnd(8)}`);
  }

  it("Probes map payouts at different stages", async function () {
      console.log("\nState                | Total    | Player   | Referrer");
      console.log("-".repeat(60));
      
      const { purgeGame, vrf } = system;
      const vrfConsumer = await purgeGame.getAddress();

      // 1. Early Purchase (0% pool)
      await probePurchase("Early (0% Pool)");

      // Advance to ~50% pool (Mid Phase)
      // Need to pump pool. Minting increases pool.
      // Target is small in L1 (~125 ETH).
      // Just mint a bunch from owner to fill it.
      
      let info = await purgeGame.gameInfo();
      while (info.prizePoolCurrent < info.prizePoolTarget / 2n) {
          const cost = (info.price_ * 100n * 25n) / 100n; // 100 maps
          await system.purgeNFT.connect(owner).mintAndPurge(100, false, ethers.ZeroHash, { value: cost });
          info = await purgeGame.gameInfo();
      }
      await probePurchase("Mid (50% Pool)");

      // Advance to ~100% pool (Late Phase)
      while (info.prizePoolCurrent < info.prizePoolTarget) {
          const cost = (info.price_ * 100n * 25n) / 100n;
          await system.purgeNFT.connect(owner).mintAndPurge(100, false, ethers.ZeroHash, { value: cost });
          info = await purgeGame.gameInfo();
      }
      await probePurchase("Late (100% Pool)");
      
      // Advance to Purge Phase
      // Must advance ticks to trigger state change
      let state = Number(info.gameState_);
      while (state !== 3) {
          await runAdvanceGameTick(purgeGame, vrf, vrfConsumer, owner);
          info = await purgeGame.gameInfo();
          state = Number(info.gameState_);
      }
      await probePurchase("Purge Phase");
  });
});
