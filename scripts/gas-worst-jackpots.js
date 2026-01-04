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
  const MockCoinFactory = await ethers.getContractFactory("MockCoinModule");
  const coin = await MockCoinFactory.deploy();
  await coin.waitForDeployment();

  const MockBondsFactory = await ethers.getContractFactory("MockBondsJackpotEnabled");
  const bonds = await MockBondsFactory.deploy();
  await bonds.waitForDeployment();

  const HarnessFactory = await ethers.getContractFactory("JackpotGasHarness");
  const harness = await HarnessFactory.deploy();
  await harness.waitForDeployment();

  await (await harness.setBonds(await bonds.getAddress())).wait();

  const lvl = 1;
  const priceWei = ethers.parseEther("0.025");
  const rewardPoolWei = ethers.parseEther("100000");
  const currentPrizePoolWei = ethers.parseEther("1000");
  const dailyBudgetWei = ethers.parseEther("1000");
  const dailyJackpotBaseWei = (dailyBudgetWei * 10000n) / 1225n; // last daily (idx 9)
  const jackpotCounter = 9;

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
  const totalTickets = 10000;
  const batchSize = 250;
  let base = 0x100000n;
  for (const trait of traits) {
    await seedTrait(harness, lvl, trait, base, totalTickets, batchSize);
    base += 0x100000n;
  }
  for (const trait of traits) {
    await seedTrait(harness, lvl + 1, trait, base, totalTickets, batchSize);
    base += 0x100000n;
  }

  await hre.network.provider.send("evm_setBlockGasLimit", ["0x5f5e100"]); // 100,000,000

  const randWordRaw = BigInt(ethers.keccak256(ethers.toUtf8Bytes("gas-worst-jackpot")));
  const randWordDaily = randWordRaw & ~0xfffn; // zero low 12 bits to pick traits 0/64/128/192

  const initSnap = await hre.network.provider.send("evm_snapshot");

  const txDaily = await harness.payDailyJackpot(true, lvl, randWordDaily, await coin.getAddress(), {
    gasLimit: 80_000_000,
  });
  await txDaily.wait();

  let baseSnap = await hre.network.provider.send("evm_snapshot");
  let bestMapRand = randWordDaily;
  let bestPending = 0n;

  const attempts = 200;
  for (let i = 0; i < attempts; i += 1) {
    await hre.network.provider.send("evm_revert", [baseSnap]);
    baseSnap = await hre.network.provider.send("evm_snapshot");

    const candidate = BigInt(ethers.keccak256(ethers.toUtf8Bytes(`map-rand-${i}`)));
    const txMap = await harness.payDailyMapJackpot(lvl, candidate, { gasLimit: 80_000_000 });
    await txMap.wait();

    const pending = await harness.pendingMapMintsLength();
    if (pending > bestPending) {
      bestPending = pending;
      bestMapRand = candidate;
    }
  }

  await hre.network.provider.send("evm_revert", [initSnap]);

  const tx = await harness.payDailyJackpotAndMapWithRand(
    lvl,
    randWordDaily,
    bestMapRand,
    await coin.getAddress(),
    {
      gasLimit: 80_000_000,
    }
  );
  const receipt = await tx.wait();
  const pending = await harness.pendingMapMintsLength();
  const limit = 14_000_000n;

  console.log(`payDailyJackpot+Map gas: ${receipt.gasUsed.toString()}`);
  console.log(`best map rand pending MAP winners (search ${attempts}): ${bestPending.toString()}`);
  console.log(`pending MAP winners: ${pending.toString()}`);
  if (receipt.gasUsed > limit) {
    throw new Error(`Gas ${receipt.gasUsed.toString()} exceeds 14,000,000`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
