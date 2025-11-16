const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const JACKPOT_RESET_TIME = 82_620n;
const DAY = 86_400n;

function scrambleEntropy(word, salt) {
  const shiftedLeft = (word << 64n) & ((1n << 256n) - 1n);
  const shiftedRight = word >> 192n;
  const scrambled = (shiftedLeft | shiftedRight) ^ (salt << 128n) ^ 0x05n;
  return scrambled & ((1n << 256n) - 1n);
}

function questEntropy(entropyWord, level, counter) {
  const abiCoder = ethers.AbiCoder.defaultAbiCoder();
  const encoded = abiCoder.encode(
    ["uint256", "uint24", "uint8", "string"],
    [entropyWord, level, counter, "daily-quest"]
  );
  return BigInt(ethers.keccak256(encoded));
}

async function moveToTimestamp(minTimestamp) {
  const current = BigInt(await time.latest());
  const target = current >= minTimestamp ? current + 1n : minTimestamp;
  await time.setNextBlockTimestamp(Number(target));
  return target;
}

async function deployJackpotFixture() {
  const Module = await ethers.getContractFactory("PurgeGameJackpotModule");
  const module = await Module.deploy();
  await module.waitForDeployment();

  const CoinMock = await ethers.getContractFactory("JackpotCoinModuleMock");
  const coin = await CoinMock.deploy();
  await coin.waitForDeployment();

  const TrophyMock = await ethers.getContractFactory("JackpotTrophiesModuleMock");
  const trophies = await TrophyMock.deploy();
  await trophies.waitForDeployment();

  return { module, coin, trophies };
}

describe("PurgeGameJackpotModule quest rolls", function () {
  it("rolls quests for early-purge jackpots", async function () {
    const { module, coin, trophies } = await loadFixture(deployJackpotFixture);
    const targetTs = await moveToTimestamp(JACKPOT_RESET_TIME + DAY);

    const lvl = 25;
    const rngWord = 123_456_789n;
    await (
      await module.payDailyJackpot(false, lvl, rngWord, await coin.getAddress(), await trophies.getAddress())
    ).wait();

    const expectedDay = (targetTs - JACKPOT_RESET_TIME) / DAY;
    expect(await coin.lastRollDay()).to.equal(expectedDay);
    const scrambled = scrambleEntropy(rngWord, 0n);
    const expectedEntropy = questEntropy(scrambled, lvl, 0);
    expect(await coin.lastRollEntropy()).to.equal(expectedEntropy);
    expect(await coin.rollCount()).to.equal(1n);
  });

  it("rolls quests for map jackpots", async function () {
    const { module, coin, trophies } = await loadFixture(deployJackpotFixture);
    const targetTs = await moveToTimestamp(JACKPOT_RESET_TIME + 2n * DAY);

    const lvl = 50;
    const rngWord = 987_654_321n;
    await (
      await module.payMapJackpot(lvl, rngWord, 0, await coin.getAddress(), await trophies.getAddress())
    ).wait();

    const expectedDay = (targetTs - JACKPOT_RESET_TIME) / DAY;
    expect(await coin.lastRollDay()).to.equal(expectedDay);
    const expectedEntropy = questEntropy(rngWord, lvl, 0);
    expect(await coin.lastRollEntropy()).to.equal(expectedEntropy);
    expect(await coin.rollCount()).to.equal(1n);
    expect(await coin.lastPrimeDay()).to.equal(expectedDay + 1n);
  });
});
