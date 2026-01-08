import fs from "node:fs";
import hre from "hardhat";

const { ethers } = hre;

function addrFrom(base, offset) {
  const value = base + BigInt(offset);
  return `0x${value.toString(16).padStart(40, "0")}`;
}

function readAddress(name) {
  const src = fs.readFileSync("contracts/ContractAddresses.sol", "utf8");
  const re = new RegExp(`\\b${name}\\s*=\\s*(0x[a-fA-F0-9]{40})`);
  const match = src.match(re);
  if (!match) {
    throw new Error(`Address ${name} not found in ContractAddresses.sol`);
  }
  return match[1];
}

async function setCode(address, artifactName) {
  const artifact = await hre.artifacts.readArtifact(artifactName);
  await hre.network.provider.send("hardhat_setCode", [address, artifact.deployedBytecode]);
}

async function main() {
  const coinAddr = readAddress("COIN");
  const gameAddr = readAddress("GAME");
  const affiliateAddr = readAddress("AFFILIATE");

  await hre.network.provider.send("evm_setBlockGasLimit", ["0x5f5e100"]); // 100,000,000

  await setCode(coinAddr, "MockBafCoinJackpotView");
  await setCode(gameAddr, "MockBafGameJackpotView");
  await setCode(affiliateAddr, "MockBafAffiliateJackpotView");

  const coin = await ethers.getContractAt("MockBafCoinJackpotView", coinAddr);
  const game = await ethers.getContractAt("MockBafGameJackpotView", gameAddr);
  const affiliate = await ethers.getContractAt("MockBafAffiliateJackpotView", affiliateAddr);

  const JackpotFactory = await ethers.getContractFactory("DegenerusJackpots");
  const jackpots = await JackpotFactory.deploy();
  await jackpots.waitForDeployment();

  const lvl = 100;
  await (await game.setLevel(lvl)).wait();

  const ticketAddrs = [
    addrFrom(0x100000n, 0),
    addrFrom(0x100000n, 1),
    addrFrom(0x100000n, 2),
    addrFrom(0x100000n, 3)
  ];

  const prevLevels = Array.from({ length: 20 }, (_, i) => lvl - 1 - i);
  const exterminators = prevLevels.map((_, i) => addrFrom(0x200000n, i));
  const affiliates = prevLevels.map((_, i) => addrFrom(0x300000n, i));
  const retroAddrs = prevLevels.map((_, i) => addrFrom(0x400000n, i));
  const topLastDayAddr = addrFrom(0x500000n, 0);

  const eligible = new Set([
    ...ticketAddrs,
    ...exterminators,
    ...affiliates,
    ...retroAddrs,
    topLastDayAddr
  ]);
  const eligibleAddrs = Array.from(eligible);

  const coinflipThreshold = ethers.parseEther("5000");
  await (await coin.setCoinflipAmountLastDayBatch(eligibleAddrs, coinflipThreshold)).wait();
  await (await game.setEthMintStreakCountBatch(eligibleAddrs, 3)).wait();
  await (await game.setPlayerBonusMultiplierBatch(ticketAddrs, 10_000)).wait();

  for (let i = 0; i < prevLevels.length; i += 1) {
    const level = prevLevels[i];
    await (await game.setLevelExterminator(level, exterminators[i])).wait();
    await (await affiliate.setAffiliateTop(level, affiliates[i], 1)).wait();
    await (await coin.setCoinflipTop(level, retroAddrs[i], 1)).wait();

    await (await game.seedTraitTicketsRange(level, 0, 64, ticketAddrs)).wait();
    await (await game.seedTraitTicketsRange(level, 64, 64, ticketAddrs)).wait();
    await (await game.seedTraitTicketsRange(level, 128, 64, ticketAddrs)).wait();
    await (await game.seedTraitTicketsRange(level, 192, 64, ticketAddrs)).wait();
  }

  await (await coin.setCoinflipTopLastDay(topLastDayAddr, 1)).wait();

  const coinSigner = await ethers.getSigner(coinAddr);
  const gameSigner = await ethers.getSigner(gameAddr);

  await hre.network.provider.send("hardhat_setBalance", [coinAddr, ethers.toBeHex(ethers.parseEther("1000"))]);
  await hre.network.provider.send("hardhat_setBalance", [gameAddr, ethers.toBeHex(ethers.parseEther("1000"))]);

  await hre.network.provider.request({ method: "hardhat_impersonateAccount", params: [coinAddr] });
  await hre.network.provider.request({ method: "hardhat_impersonateAccount", params: [gameAddr] });

  const baseAmount = ethers.parseEther("1000");
  for (let i = 0; i < ticketAddrs.length; i += 1) {
    const amount = baseAmount - ethers.parseEther((i * 10).toString());
    await (await jackpots.connect(coinSigner).recordBafFlip(ticketAddrs[i], lvl, amount)).wait();
  }

  const rngWord = ethers.keccak256(ethers.toUtf8Bytes("baf-gas-test"));
  const poolWei = ethers.parseEther("1000");

  const tx = await jackpots.connect(gameSigner).runBafJackpot(poolWei, lvl, rngWord, {
    gasLimit: 80_000_000
  });
  const receipt = await tx.wait();

  console.log(`runBafJackpot gasUsed: ${receipt.gasUsed.toString()}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
