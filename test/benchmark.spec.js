const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Massive System Benchmark (Gas & Calls)", function () {
  this.timeout(0); // No timeout for massive test

  let purgecoin, mockGame, deployer, game, vrf, link;
  let nft, trophies, renderer, quest, extJackpot, jackpotMod, endgameMod;
  const MILLION = 10n ** 6n;

  // Benchmark Results
  const results = {};

  before(async function () {
    [deployer] = await ethers.getSigners();

    // --- DEPLOYMENT ---
    const MockRenderer = await ethers.getContractFactory("MockRenderer");
    renderer = await MockRenderer.deploy();
    await renderer.waitForDeployment();

    const VRF = await ethers.getContractFactory("MockVRFCoordinator");
    vrf = await VRF.deploy(ethers.parseEther("500"));
    await vrf.waitForDeployment();

    const Link = await ethers.getContractFactory("MockLinkToken");
    link = await Link.deploy();
    await link.waitForDeployment();

    const Purgecoin = await ethers.getContractFactory("Purgecoin");
    purgecoin = await Purgecoin.deploy();
    await purgecoin.waitForDeployment();

    const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
    quest = await QuestModule.deploy(purgecoin.target);
    await quest.waitForDeployment();

    const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
    extJackpot = await ExternalJackpot.deploy();
    await extJackpot.waitForDeployment();

    const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
    nft = await PurgeGameNFT.deploy(renderer.target, renderer.target, purgecoin.target);
    await nft.waitForDeployment();

    const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
    trophies = await PurgeGameTrophies.deploy(nft.target);
    await trophies.waitForDeployment();

    const Endgame = await ethers.getContractFactory("PurgeGameEndgameModule");
    endgameMod = await Endgame.deploy();
    await endgameMod.waitForDeployment();

    const Jackpot = await ethers.getContractFactory("PurgeGameJackpotModule");
    jackpotMod = await Jackpot.deploy();
    await jackpotMod.waitForDeployment();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();
    await steth.waitForDeployment();

    const PurgeGame = await ethers.getContractFactory("PurgeGame");
    game = await PurgeGame.deploy(
        purgecoin.target,
        renderer.target,
        nft.target,
        trophies.target,
        endgameMod.target,
        jackpotMod.target,
        vrf.target,
        ethers.ZeroHash, 
        1n, 
        link.target,
        steth.target
    );
    await game.waitForDeployment();

    await purgecoin.wire(
        game.target,
        nft.target,
        trophies.target,
        renderer.target,
        renderer.target,
        quest.target,
        extJackpot.target,
        deployer.address
    );
    
    // Mint tokens to deployer for distribution
    await network.provider.request({ method: "hardhat_impersonateAccount", params: [game.target] });
    await network.provider.send("hardhat_setBalance", [game.target, "0xDE0B6B3A7640000"]);
    const gameSigner = await ethers.getSigner(game.target);
    await purgecoin.connect(gameSigner).burnie(ethers.parseUnits("1000000000000", 6), ethers.ZeroAddress); // 1 Trillion

    // Start Game
    const price = await game.mintPrice();
    await nft.mintAndPurge(4, false, ethers.ZeroHash, { value: (price * 4n * 25n) / 100n });
  });

  // --- HELPERS ---
  const setupPlayers = async (count, streak = 0) => {
      console.log(`  Creating ${count} wallets...`);
      const wallets = [];
      for(let i=0; i<count; i++) wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
      
      console.log(`  Funding ETH...`);
      const chunkSize = 100;
      for (let i = 0; i < wallets.length; i += chunkSize) {
          await Promise.all(wallets.slice(i, i + chunkSize).map(w => network.provider.send("hardhat_setBalance", [w.address, "0xDE0B6B3A7640000"])));
      }
      return wallets;
  };

  const advanceUntilDone = async (checkDoneFn, label) => {
      console.log(`  Running Advance Loop for ${label}...`);
      let calls = 0;
      let maxGas = 0n;
      let totalGas = 0n;
      
      // Max loop safety
      while (calls < 500) {
          // Check RNG
          let rngLocked = await game.rngLocked();
          if (rngLocked) {
              if (!(await game.isRngFulfilled())) {
                  const VRF = await ethers.getContractFactory("MockVRFCoordinator");
                  const vrfContract = VRF.attach(vrf.target);
                  const reqId = await vrfContract.lastRequestId();
                  await vrfContract.fulfill(game.target, reqId, 1n);
                  rngLocked = false; // Unlocked conceptually
              }
          }

          if (await checkDoneFn()) break;

          try {
              const tx = await game.advanceGame(0);
              const rc = await tx.wait();
              const gas = rc.gasUsed;
              if (gas > maxGas) maxGas = gas;
              totalGas += gas;
              calls++;
          } catch(e) {
              if (e.message.includes("MustMintToday")) {
                  // Handle MustMintToday
                  // Fulfill RNG first if needed
                  if (await game.rngLocked()) {
                      if (!(await game.isRngFulfilled())) {
                          const VRF = await ethers.getContractFactory("MockVRFCoordinator");
                          const vrfContract = VRF.attach(vrf.target);
                          const reqId = await vrfContract.lastRequestId();
                          await vrfContract.fulfill(game.target, reqId, 1n);
                      }
                  }
                  
                  if (!await game.rngLocked() || await game.isRngFulfilled()) {
                      console.log("  Minting daily map to continue...");
                      const price = await game.mintPrice();
                      // Min quantity logic: 4 for early levels
                      await nft.mintAndPurge(4, false, ethers.ZeroHash, { value: (price * 4n * 25n) / 100n });
                  } else {
                      // Wait loop?
                  }
              } else {
                  console.log("Advance Error:", e.message);
              }
          }
          
          // Tick time
          await network.provider.send("evm_increaseTime", [600]); // 10 mins
          await network.provider.send("evm_mine");
      }
      console.log(`\n  Done. Calls: ${calls}, MaxGas: ${maxGas}, TotalGas: ${totalGas}`);
      return { calls, maxGas, totalGas };
  };

  it("BENCHMARK: Coinflips (5,000 players)", async function () {
      const COUNT = 5000;
      const wallets = await setupPlayers(COUNT);
      
      console.log(`  Depositing ${COUNT} coinflips...`);
      for(let i=0; i<wallets.length; i++) {
          if (i % 500 === 0) process.stdout.write(`${i}...`);
          const w = wallets[i];
          await purgecoin.transfer(w.address, 1000n * MILLION);
          await purgecoin.connect(w).depositCoinflip(100n * MILLION);
      }
      console.log("Deposits complete.");

      const checkDone = async () => {
          const bal = await purgecoin.coinflipAmount(wallets[COUNT-1].address);
          return bal == 0n;
      };

      results.Coinflips = await advanceUntilDone(checkDone, "Coinflips");
  });

  it("BENCHMARK: Decimator (10,000 players)", async function () {
      console.log("  Redeploying for Decimator...");
      const MockRenderer = await ethers.getContractFactory("MockRenderer");
      renderer = await MockRenderer.deploy();
      const Purgecoin = await ethers.getContractFactory("Purgecoin");
      purgecoin = await Purgecoin.deploy();
      const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
      extJackpot = await ExternalJackpot.deploy();
      const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
      nft = await PurgeGameNFT.deploy(renderer.target, renderer.target, purgecoin.target);
      const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
      trophies = await PurgeGameTrophies.deploy(nft.target);
      const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
      quest = await QuestModule.deploy(purgecoin.target);
      const GameHarness = await ethers.getContractFactory("PurgeGameHarness");
      game = await GameHarness.deploy(
        purgecoin.target,
        renderer.target,
        nft.target,
        trophies.target,
        endgameMod.target, 
        jackpotMod.target, 
        vrf.target, 
        ethers.ZeroHash, 
        1n, 
        link.target
      );
      await purgecoin.wire(
        game.target,
        nft.target,
        trophies.target,
        renderer.target,
        renderer.target,
        quest.target,
        extJackpot.target,
        deployer.address
      );
      
      await network.provider.request({ method: "hardhat_impersonateAccount", params: [game.target] });
      await network.provider.send("hardhat_setBalance", [game.target, "0xDE0B6B3A7640000"]);
      const gameSigner = await ethers.getSigner(game.target);
      await purgecoin.connect(gameSigner).burnie(ethers.parseUnits("1000000000000", 6), ethers.ZeroAddress);

      // Level 25
      await game.harnessSetState(25, 2, 1);
      await game.harnessSetPrize(ethers.parseEther("1000"));
      
      const COUNT = 10000;
      const wallets = await setupPlayers(COUNT);
      
      console.log(`  Executing ${COUNT} Decimator Burns...`);
      for(let i=0; i<wallets.length; i++) {
          if (i % 1000 === 0) process.stdout.write(`${i}...`);
          const w = wallets[i];
          await purgecoin.transfer(w.address, 1000n * MILLION);
          await purgecoin.connect(w).decimatorBurn(100n * MILLION);
      }
      console.log("Burns complete.");
      
      const checkDone = async () => {
          const info = await game.gameInfo();
          return info.gameState_ == 3;
      };
      
      results.Decimator = await advanceUntilDone(checkDone, "Decimator");
  });

  it("BENCHMARK: BAF (1,000 players)", async function () {
      console.log("  Redeploying for BAF...");
      const MockRenderer = await ethers.getContractFactory("MockRenderer");
      renderer = await MockRenderer.deploy();
      const Purgecoin = await ethers.getContractFactory("Purgecoin");
      purgecoin = await Purgecoin.deploy();
      const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
      extJackpot = await ExternalJackpot.deploy();
      const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
      nft = await PurgeGameNFT.deploy(renderer.target, renderer.target, purgecoin.target);
      const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
      trophies = await PurgeGameTrophies.deploy(nft.target);
      const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
      quest = await QuestModule.deploy(purgecoin.target);
      const GameHarness = await ethers.getContractFactory("PurgeGameHarness");
      game = await GameHarness.deploy(
        purgecoin.target,
        renderer.target,
        nft.target,
        trophies.target,
        endgameMod.target, 
        jackpotMod.target, 
        vrf.target, 
        ethers.ZeroHash, 
        1n, 
        link.target
      );
      await purgecoin.wire(
        game.target,
        nft.target,
        trophies.target,
        renderer.target,
        renderer.target,
        quest.target,
        extJackpot.target,
        deployer.address
      );
      
      await network.provider.request({ method: "hardhat_impersonateAccount", params: [game.target] });
      await network.provider.send("hardhat_setBalance", [game.target, "0xDE0B6B3A7640000"]);
      const gameSigner = await ethers.getSigner(game.target);
      await purgecoin.connect(gameSigner).burnie(ethers.parseUnits("1000000000000", 6), ethers.ZeroAddress);

      await game.harnessSetState(20, 2, 1);
      await game.harnessSetPrize(ethers.parseEther("1000"));
      
      const COUNT = 1000;
      const wallets = await setupPlayers(COUNT);
      
      console.log(`  Making players eligible for BAF...`);
      for(const w of wallets) {
          await purgecoin.transfer(w.address, 10000n * MILLION);
          await purgecoin.connect(w).depositCoinflip(6000n * MILLION);
      }
      
      const checkDone = async () => {
          const info = await game.gameInfo();
          return info.gameState_ == 3;
      };
      
      results.BAF = await advanceUntilDone(checkDone, "BAF");
  });

  it("BENCHMARK: Map Jackpot (1,000 players)", async function () {
      console.log("  Redeploying for Map Jackpot...");
      const MockRenderer = await ethers.getContractFactory("MockRenderer");
      renderer = await MockRenderer.deploy();
      const Purgecoin = await ethers.getContractFactory("Purgecoin");
      purgecoin = await Purgecoin.deploy();
      const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
      extJackpot = await ExternalJackpot.deploy();
      const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
      nft = await PurgeGameNFT.deploy(renderer.target, renderer.target, purgecoin.target);
      const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
      trophies = await PurgeGameTrophies.deploy(nft.target);
      const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
      quest = await QuestModule.deploy(purgecoin.target);
      const GameHarness = await ethers.getContractFactory("PurgeGameHarness");
      game = await GameHarness.deploy(
        purgecoin.target,
        renderer.target,
        nft.target,
        trophies.target,
        endgameMod.target, 
        jackpotMod.target, 
        vrf.target, 
        ethers.ZeroHash, 
        1n, 
        link.target
      );
      await purgecoin.wire(
        game.target,
        nft.target,
        trophies.target,
        renderer.target,
        renderer.target,
        quest.target,
        extJackpot.target,
        deployer.address
      );
      
      await network.provider.request({ method: "hardhat_impersonateAccount", params: [game.target] });
      await network.provider.send("hardhat_setBalance", [game.target, "0xDE0B6B3A7640000"]);
      const gameSigner = await ethers.getSigner(game.target);
      await purgecoin.connect(gameSigner).burnie(ethers.parseUnits("1000000000000", 6), ethers.ZeroAddress);

      await game.harnessSetState(16, 2, 1);
      await game.harnessSetPrize(ethers.parseEther("1000"));
      
      const COUNT = 1000;
      const wallets = await setupPlayers(COUNT);
      
      console.log(`  Minting ${COUNT} Maps...`);
      const price = await game.mintPrice();
      const wei = (price * 4n * 25n) / 100n;
      
      for(const w of wallets) {
          await nft.connect(w).mintAndPurge(4, false, ethers.ZeroHash, { value: wei });
      }
      
      const checkDone = async () => {
          const info = await game.gameInfo();
          return info.gameState_ == 3;
      };
      
      results.MapJackpot = await advanceUntilDone(checkDone, "Map Jackpot");
  });

  after(function() {
      console.log("\n\n=== BENCHMARK RESULTS ===");
      console.table(results);
  });
});
