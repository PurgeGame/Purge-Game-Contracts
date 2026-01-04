import hre from "hardhat";

const { ethers } = hre;

function addrFrom(base, offset) {
  const value = base + BigInt(offset);
  return `0x${value.toString(16).padStart(40, "0")}`;
}

async function main() {
  const HarnessFactory = await ethers.getContractFactory("JackpotGasHarness");
  const harness = await HarnessFactory.deploy();
  await harness.waitForDeployment();

  const lvl = 1;
  const priceWei = ethers.parseEther("0.025");
  await (await harness.setState(
    lvl,
    priceWei,
    0n,
    0n,
    0n,
    0
  )).wait();

  const ethWinnersCount = 321;
  const mapWinnersCount = 150;

  const ethWinners = [];
  for (let i = 0; i < ethWinnersCount; i += 1) {
    ethWinners.push(addrFrom(0x100000n, i));
  }

  const mapWinners = [];
  for (let i = 0; i < mapWinnersCount; i += 1) {
    mapWinners.push(addrFrom(0x200000n, i));
  }

  const ethPerWinner = ethers.parseEther("0.1");
  const mapPerWinner = priceWei / 4n; // 1 map per winner
  const mapBps = 10_000;

  await hre.network.provider.send("evm_setBlockGasLimit", ["0x5f5e100"]); // 100,000,000

  const tx = await harness.simulateWorstCaseWrites(
    ethWinners,
    ethPerWinner,
    mapWinners,
    mapPerWinner,
    mapBps,
    { gasLimit: 80_000_000 }
  );
  const receipt = await tx.wait();

  console.log(`simulateWorstCaseWrites gas: ${receipt.gasUsed.toString()}`);
  if (receipt.gasUsed > 14_000_000n) {
    throw new Error(`Gas ${receipt.gasUsed.toString()} exceeds 14,000,000`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
