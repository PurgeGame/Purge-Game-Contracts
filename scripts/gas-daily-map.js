import hre from "hardhat";

const { ethers } = hre;

function addrFrom(base, offset) {
  const value = base + BigInt(offset);
  return `0x${value.toString(16).padStart(40, "0")}`;
}

async function seedTrait(harness, lvl, traitId, base, total, batchSize) {
  for (let i = 0; i < total; i += batchSize) {
    const end = Math.min(i + batchSize, total);
    const batch = [];
    for (let j = i; j < end; j += 1) {
      batch.push(addrFrom(base, j));
    }
    const tx = await harness.seedTraitTickets(lvl, traitId, batch);
    await tx.wait();
  }
}

async function main() {
  const [deployer] = await ethers.getSigners();

  const MockCoinFactory = await ethers.getContractFactory("MockCoinModule");
  const coin = await MockCoinFactory.deploy();
  await coin.waitForDeployment();

  const MockBondsFactory = await ethers.getContractFactory("MockBondsJackpot");
  const bonds = await MockBondsFactory.deploy();
  await bonds.waitForDeployment();

  const HarnessFactory = await ethers.getContractFactory("JackpotGasHarness");
  const harness = await HarnessFactory.deploy();
  await harness.waitForDeployment();

  await (await harness.setBonds(await bonds.getAddress())).wait();

  const lvl = 81;
  const priceWei = ethers.parseEther("0.025");
  const rewardPoolWei = ethers.parseEther("10000");
  const currentPrizePoolWei = ethers.parseEther("1000");
  const dailyBudgetWei = ethers.parseEther("100");
  const dailyJackpotBaseWei = (dailyBudgetWei * 10000n) / 881n; // 5th daily jackpot (idx 4)
  const jackpotCounter = 4;

  await (await harness.setState(
    lvl,
    priceWei,
    rewardPoolWei,
    currentPrizePoolWei,
    dailyJackpotBaseWei,
    jackpotCounter
  )).wait();

  await (await harness.setDailyBurnCounts(0, 0, 0)).wait();

  const traits = [0, 64, 128, 192];
  const totalTickets = 300;
  const batchSize = 100;
  let base = 0x100000n;
  for (const trait of traits) {
    await seedTrait(harness, lvl, trait, base, totalTickets, batchSize);
    base += 0x100000n;
  }
  for (const trait of traits) {
    await seedTrait(harness, lvl + 1, trait, base, totalTickets, batchSize);
    base += 0x100000n;
  }

  const randWordRaw = BigInt(ethers.keccak256(ethers.toUtf8Bytes("gas-unique")));
  const randWord = randWordRaw & ~0xfffn;
  const tx = await harness.payDailyJackpot(true, lvl, randWord, await coin.getAddress());
  const receipt = await tx.wait();
  const pending = await harness.pendingMapMintsLength();
  console.log(`Gas used: ${receipt.gasUsed.toString()}`);
  console.log(`Pending MAP winners: ${pending.toString()}`);

  const HarnessFactory2 = await ethers.getContractFactory("JackpotGasHarness");
  const payoutHarness = await HarnessFactory2.deploy();
  await payoutHarness.waitForDeployment();
  await (await payoutHarness.setState(
    lvl,
    priceWei,
    0n,
    0n,
    0n,
    0
  )).wait();

  const winnerCount = 500;
  const winners = [];
  let baseWinner = 0x500000n;
  for (let i = 0; i < winnerCount; i += 1) {
    winners.push(addrFrom(baseWinner, i));
  }
  await hre.network.provider.send("evm_setBlockGasLimit", ["0x5f5e100"]); // 100,000,000
  const perWinner = ethers.parseEther("0.1");
  const mapBps = 2000;
  const tx2 = await payoutHarness.simulateMapPayout(
    winners,
    perWinner,
    mapBps,
    { gasLimit: 80_000_000 }
  );
  const receipt2 = await tx2.wait();
  const pending2 = await payoutHarness.pendingMapMintsLength();
  console.log(`Simulated 500 winners gas: ${receipt2.gasUsed.toString()}`);
  console.log(`Simulated pending MAP winners: ${pending2.toString()}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
