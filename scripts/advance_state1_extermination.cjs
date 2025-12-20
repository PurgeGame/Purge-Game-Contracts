const { ethers, network } = require("hardhat");

const JACKPOT_RESET_TIME = 82620;
const TARGET_LEVEL = 20;
const PREV_LEVEL = TARGET_LEVEL - 1;
const TRAIT_ID = 1;
const TICKET_COUNT = 20_000;
const BURN_COUNT = 10_000;
const PRIZE_POOL = ethers.parseEther("1000");
const ADVANCE_CAP = 10_000;

function setField(slotValue, offsetBytes, sizeBytes, newValue) {
  const shift = BigInt(offsetBytes * 8);
  const mask = ((1n << BigInt(sizeBytes * 8)) - 1n) << shift;
  const v = BigInt(newValue) << shift;
  return (slotValue & ~mask) | v;
}

async function setStorageAt(address, slot, value) {
  await network.provider.send("hardhat_setStorageAt", [
    address,
    ethers.toBeHex(slot, 32),
    ethers.toBeHex(value, 32),
  ]);
}

async function main() {
  const [admin, caller] = await ethers.getSigners();

  const VRF = await ethers.getContractFactory("MockVRFCoordinator");
  const vrf = await VRF.deploy();
  await vrf.waitForDeployment();

  const StETH = await ethers.getContractFactory("MockStETH");
  const steth = await StETH.deploy();
  await steth.waitForDeployment();

  const Vault = await ethers.getContractFactory("MockVault");
  const vault = await Vault.deploy(await steth.getAddress());
  await vault.waitForDeployment();

  const Bonds = await ethers.getContractFactory("DegenerusBonds");
  const bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
  await bonds.waitForDeployment();

  const Affiliate = await ethers.getContractFactory("DegenerusAffiliate");
  const affiliate = await Affiliate.deploy(await bonds.getAddress(), await admin.getAddress());
  await affiliate.waitForDeployment();

  const affiliateAddr = await affiliate.getAddress();
  const dummyRenderer = ethers.Wallet.createRandom().address;
  const dummyTrophies = ethers.Wallet.createRandom().address;

  const MockCoinRead = await ethers.getContractFactory("MockCoinRead");
  const mockCoin = await MockCoinRead.deploy(affiliateAddr, await admin.getAddress());
  await mockCoin.waitForDeployment();

  const Coin = await ethers.getContractFactory("DegenerusCoin");
  const coin = await Coin.deploy(
    await bonds.getAddress(),
    await admin.getAddress(),
    affiliateAddr,
    await vault.getAddress()
  );
  await coin.waitForDeployment();

  const QuestModule = await ethers.getContractFactory("DegenerusQuestModule");
  const questModule = await QuestModule.deploy(await coin.getAddress());
  await questModule.waitForDeployment();

  const Endgame = await ethers.getContractFactory("DegenerusGameEndgameModule");
  const endgame = await Endgame.deploy();
  await endgame.waitForDeployment();

  const JackpotModule = await ethers.getContractFactory("DegenerusGameJackpotModule");
  const jackpotModule = await JackpotModule.deploy();
  await jackpotModule.waitForDeployment();

  const MintModule = await ethers.getContractFactory("DegenerusGameMintModule");
  const mintModule = await MintModule.deploy();
  await mintModule.waitForDeployment();

  const BondModule = await ethers.getContractFactory("DegenerusGameBondModule");
  const bondModule = await BondModule.deploy();
  await bondModule.waitForDeployment();

  const Gamepieces = await ethers.getContractFactory("DegenerusGamepieces");
  const nft = await Gamepieces.deploy(
    dummyRenderer,
    await coin.getAddress(),
    affiliateAddr,
    await vault.getAddress()
  );
  await nft.waitForDeployment();

  const Game = await ethers.getContractFactory("DegenerusGame");
  const game = await Game.deploy(
    await coin.getAddress(),
    await nft.getAddress(),
    await endgame.getAddress(),
    await jackpotModule.getAddress(),
    await mintModule.getAddress(),
    await bondModule.getAddress(),
    await steth.getAddress(),
    ethers.ZeroAddress, // jackpots (unused at level 20)
    await bonds.getAddress(),
    dummyTrophies,
    affiliateAddr,
    await vault.getAddress(),
    await admin.getAddress()
  );
  await game.waitForDeployment();

  // Wire coin/nft/game.
  await coin.wire([await game.getAddress(), await nft.getAddress(), await questModule.getAddress(), ethers.ZeroAddress]);
  const coinAddr = await coin.getAddress();
  const coinSigner = await ethers.getImpersonatedSigner(coinAddr);
  await network.provider.send("hardhat_setBalance", [coinAddr, ethers.toQuantity(ethers.parseEther("1"))]);
  await nft.connect(coinSigner).wire([await game.getAddress()]);

  await questModule.connect(coinSigner).wire([await game.getAddress()]);
  await affiliate.wire([await coin.getAddress(), await game.getAddress(), await nft.getAddress()]);

  // Wire bonds with game/vault/coin/vrf.
  await bonds.wire(
    [
      await game.getAddress(),
      await vault.getAddress(),
      await mockCoin.getAddress(),
      await vrf.getAddress(),
      ethers.ZeroAddress,
      dummyTrophies,
    ],
    1,
    ethers.hexlify(ethers.randomBytes(32))
  );

  // Wire game VRF.
  await game.wireVrf(await vrf.getAddress(), 1, ethers.hexlify(ethers.randomBytes(32)));

  // Ensure day index is > 0 so rngAndTimeGate passes.
  const latestBlock = await ethers.provider.getBlock("latest");
  const targetTs = JACKPOT_RESET_TIME + 2 * 86400;
  const nextTs = Math.max(Number(latestBlock.timestamp) + 1, targetTs);
  await network.provider.send("evm_setNextBlockTimestamp", [nextTs]);
  await network.provider.send("evm_mine");

  // Update slot 0: level, lastExterminatedTrait, gameState, dailyIdx.
  const slot0 = BigInt(await ethers.provider.getStorage(await game.getAddress(), 0));
  const day = Math.floor((nextTs - JACKPOT_RESET_TIME) / 86400);
  const dailyIdx = day > 0 ? day - 1 : 0;
  let newSlot0 = slot0;
  newSlot0 = setField(newSlot0, 6, 6, dailyIdx); // dailyIdx (uint48)
  newSlot0 = setField(newSlot0, 26, 3, TARGET_LEVEL); // level (uint24)
  newSlot0 = setField(newSlot0, 29, 2, TRAIT_ID); // lastExterminatedTrait (uint16)
  newSlot0 = setField(newSlot0, 31, 1, 1); // gameState (uint8) -> pregame
  await setStorageAt(await game.getAddress(), 0, newSlot0);

  // Set prize pool to 1000 ETH.
  await setStorageAt(await game.getAddress(), 4, PRIZE_POOL);
  // Zero lastPrizePool to avoid bond coin skims during upkeep.
  await setStorageAt(await game.getAddress(), 3, 0);

  // Set levelExterminators length and index (slot 18).
  const levelExSlot = 18n;
  await setStorageAt(await game.getAddress(), levelExSlot, 19n); // length
  const levelExBase = BigInt(ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [levelExSlot])));
  const exIdxSlot = levelExBase + BigInt(PREV_LEVEL - 1);
  await setStorageAt(
    await game.getAddress(),
    exIdxSlot,
    BigInt(ethers.zeroPadValue(await caller.getAddress(), 32))
  );

  // Set traitStartRemaining[TRAIT_ID] = BURN_COUNT (slot 64).
  const traitStartSlot = 64n + BigInt(Math.floor(TRAIT_ID / 8));
  const traitStartVal = BigInt(await ethers.provider.getStorage(await game.getAddress(), traitStartSlot));
  const shift = BigInt((TRAIT_ID % 8) * 32);
  const mask = ((1n << 32n) - 1n) << shift;
  const updated = (traitStartVal & ~mask) | (BigInt(BURN_COUNT) << shift);
  await setStorageAt(await game.getAddress(), traitStartSlot, updated);

  // Seed 20k tickets in traitBurnTicket[PREV_LEVEL][TRAIT_ID] (mapping slot 21).
  const traitBurnSlot = 21n;
  const base = BigInt(
    ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["uint24", "uint256"], [PREV_LEVEL, traitBurnSlot]))
  );
  const traitSlot = base + BigInt(TRAIT_ID);
  await setStorageAt(await game.getAddress(), traitSlot, BigInt(TICKET_COUNT)); // length
  const dataBase = BigInt(
    ethers.keccak256(ethers.AbiCoder.defaultAbiCoder().encode(["uint256"], [traitSlot]))
  );
  const holderPadded = ethers.zeroPadValue(await caller.getAddress(), 32);
  for (let i = 0; i < TICKET_COUNT; i++) {
    await setStorageAt(await game.getAddress(), dataBase + BigInt(i), BigInt(holderPadded));
    if (i !== 0 && i % 5000 === 0) {
      console.log(`Seeded ${i} tickets...`);
    }
  }

  console.log("Setup complete. Running advanceGame...");

  async function advanceDay() {
    const latest = await ethers.provider.getBlock("latest");
    const nextDay = Number(latest.timestamp) + 86401;
    await network.provider.send("evm_setNextBlockTimestamp", [nextDay]);
    await network.provider.send("evm_mine");
  }

  const targetState = 2n;
  let state = await game.gameState();
  let steps = 0;
  while (state !== targetState && steps < 10) {
    let receipt;
    try {
      const tx = await game.connect(caller).advanceGame(ADVANCE_CAP);
      receipt = await tx.wait();
      console.log(`advanceGame(${ADVANCE_CAP}) gasUsed=${receipt.gasUsed} stateBefore=${state}`);
    } catch (err) {
      if (err?.message?.includes("NotTimeYet")) {
        await advanceDay();
        continue;
      }
      throw err;
    }

    const fulfilled = await game.isRngFulfilled();
    if (!fulfilled) {
      const reqId = (await vrf.nextRequestId()) - 1n;
      const vrfAddr = await vrf.getAddress();
      const vrfSigner = await ethers.getImpersonatedSigner(vrfAddr);
      await network.provider.send("hardhat_setBalance", [vrfAddr, ethers.toQuantity(ethers.parseEther("1"))]);
      await game.connect(vrfSigner).rawFulfillRandomWords(reqId, [123456789n]);
      console.log(`Fulfilled VRF request ${reqId.toString()}`);
    }

    state = await game.gameState();
    console.log(`stateAfter=${state}`);
    steps += 1;
  }

  console.log(`Final gameState=${state} after ${steps} advanceGame calls.`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
