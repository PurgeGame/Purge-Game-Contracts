const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Real Gas Benchmark (Keeper Mode)", function () {
  this.timeout(0); 

  let purgecoin, game, vrf, nft, link, keeper, deployer;
  const MILLION = 10n ** 6n;

  before(async function () {
    [deployer, keeper] = await ethers.getSigners();

    const MockRenderer = await ethers.getContractFactory("MockRenderer");
    const renderer = await MockRenderer.deploy();
    const VRF = await ethers.getContractFactory("MockVRFCoordinator");
    vrf = await VRF.deploy(ethers.parseEther("500"));
    const Link = await ethers.getContractFactory("MockLinkToken");
    link = await Link.deploy();
    const Purgecoin = await ethers.getContractFactory("Purgecoin");
    purgecoin = await Purgecoin.deploy();
    const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
    const quest = await QuestModule.deploy(purgecoin.target);
    const ExternalJackpot = await ethers.getContractFactory("PurgeJackpots");
    const extJackpot = await ExternalJackpot.deploy();
    const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
    nft = await PurgeGameNFT.deploy(renderer.target, renderer.target, purgecoin.target);
    const PurgeGameTrophies = await ethers.getContractFactory("PurgeGameTrophies");
    const trophies = await PurgeGameTrophies.deploy(nft.target);
    const Endgame = await ethers.getContractFactory("PurgeGameEndgameModule");
    const endgameMod = await Endgame.deploy();
    const Jackpot = await ethers.getContractFactory("PurgeGameJackpotModule");
    const jackpotMod = await Jackpot.deploy();
    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();

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

    const price = await game.mintPrice();
    await nft.mintAndPurge(4, false, ethers.ZeroHash, { value: (price * 4n * 25n) / 100n });
  });

  const ensureRng = async () => {
      if (await game.rngLocked()) {
          if (!(await game.isRngFulfilled())) {
              const VRF = await ethers.getContractFactory("MockVRFCoordinator");
              const vrfContract = VRF.attach(vrf.target);
              const reqId = await vrfContract.lastRequestId();
              await vrfContract.fulfill(game.target, reqId, 1n);
          }
      }
  };

  const advanceDayAndKeeperMint = async () => {
      await network.provider.send("evm_increaseTime", [86400]); 
      await network.provider.send("evm_mine");
      
      // Ensure RNG is ready before minting (in case time jump triggered lock?)
      // Time jump doesn't trigger lock until someone calls the contract.
      // But if it was LEFT locked...
      await ensureRng();
      
      const price = await game.mintPrice();
      await nft.connect(keeper).mintAndPurge(4, false, ethers.ZeroHash, { value: (price * 4n * 25n) / 100n });
  };

  it("REAL GAS TEST: 5000 Coinflips (Batch 250)", async function () {
      console.log("Setting up 5000 flippers...");
      const wallets = [];
      for(let i=0; i<5000; i++) wallets.push(ethers.Wallet.createRandom().connect(ethers.provider));
      
      const chunkSize = 100;
      for (let i = 0; i < wallets.length; i += chunkSize) {
          await Promise.all(wallets.slice(i, i + chunkSize).map(w => network.provider.send("hardhat_setBalance", [w.address, "0xDE0B6B3A7640000"])));
      }
      
      for (const w of wallets) {
          await purgecoin.transfer(w.address, 1000n * MILLION);
          await purgecoin.connect(w).depositCoinflip(100n * MILLION);
      }
      console.log("Deposits done. Processing...");

      let processedCount = 0;
      let maxGas = 0n;
      let loops = 0;
      
      while (processedCount < 5000 && loops < 50) {
          await advanceDayAndKeeperMint();
          
          try { await game.connect(keeper).advanceGame(0); } catch(e) {}
          
          await ensureRng();
          
          // Force processing
          const tx = await game.connect(keeper).advanceGame(0);
          const rc = await tx.wait();
          const gas = rc.gasUsed;
          
          // Filter out low-gas calls (overhead only)
          if (gas > 200_000n) {
              console.log(`Batch Gas: ${gas}`);
              if (gas > maxGas) maxGas = gas;
              if (gas > 15_000_000n) throw new Error("GAS EXCEEDED 15M");
          }
          
          let p = 0;
          for(let k=0; k<5000; k+=500) {
              if (await purgecoin.coinflipAmount(wallets[k].address) == 0n) p += 500;
          }
          processedCount = p;
          loops++;
      }
      
      console.log(`Max Gas: ${maxGas}`);
      expect(maxGas).to.be.gt(1_000_000n);
      expect(maxGas).to.be.lt(15_000_000n);
  });
});
