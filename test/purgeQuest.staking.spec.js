const { expect } = require("chai");
const { ethers } = require("hardhat");

const MILLION = 1_000_000n;

const QUEST_TYPES = {
  MINT_ANY: 0,
  MINT_ETH: 1,
  FLIP: 2,
  STAKE: 3,
  AFFILIATE: 4,
  DECIMATOR: 6,
};

const LARGE_PRINCIPAL = 10_000n * MILLION;
const LARGE_STAKE_CREDIT = 5_000n * MILLION;
const LARGE_DECIMATOR_BURN = 25_000n * MILLION;
const LARGE_AFFILIATE = 5_000n * MILLION;
const LONG_DISTANCE = 150;
const HIGH_RISK = 11;
const MINT_QUANTITY = 1_000;

function stakeFriendlyEntropy(day) {
  let entropy = BigInt(day);
  while (entropy % 5n !== BigInt(QUEST_TYPES.STAKE)) {
    entropy += 1n;
  }
  return entropy;
}

describe("PurgeQuestModule staking streaks", function () {
  it("allows a player to maintain a 60-day streak by completing every quest", async function () {
    const [coin, player] = await ethers.getSigners();

    const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
    const questModule = await QuestModule.deploy(await coin.getAddress());
    await questModule.waitForDeployment();

    const GameMock = await ethers.getContractFactory("QuestGameMock");
    const game = await GameMock.deploy();
    await game.waitForDeployment();
    await (
      await questModule.connect(coin).wireGame(await game.getAddress())
    ).wait();
    await (await game.setLevel(100)).wait();
    await (await game.setEthMintLastLevel(player.address, 100)).wait();

    let ethMintUnlocked = true;
    const unlockEthMint = async () => {};

    for (let day = 1; day <= 60; day += 1) {
      const entropy = stakeFriendlyEntropy(day);
      await (
        await questModule.connect(coin).rollDailyQuest(day, entropy)
      ).wait();

      const quests = await questModule.getActiveQuests();

      for (const quest of quests) {
        if (Number(quest.day) !== day) continue;
        const questType = Number(quest.questType);

        switch (questType) {
          case QUEST_TYPES.MINT_ANY: {
            if (!ethMintUnlocked) {
              await unlockEthMint();
            }
            await (
              await questModule
                .connect(coin)
                .handleMint(player.address, MINT_QUANTITY, false)
            ).wait();
            break;
          }
          case QUEST_TYPES.MINT_ETH: {
            if (!ethMintUnlocked) {
              await unlockEthMint();
            }
            await (
              await questModule
                .connect(coin)
                .handleMint(player.address, MINT_QUANTITY, true)
            ).wait();
            break;
          }
          case QUEST_TYPES.FLIP: {
            await (
              await questModule
                .connect(coin)
                .handleFlip(player.address, LARGE_STAKE_CREDIT)
            ).wait();
            break;
          }
          case QUEST_TYPES.STAKE: {
            await (
              await questModule
                .connect(coin)
                .handleStake(
                  player.address,
                  LARGE_PRINCIPAL,
                  LONG_DISTANCE,
                  HIGH_RISK
                )
            ).wait();
            break;
          }
          case QUEST_TYPES.AFFILIATE: {
            await (
              await questModule
                .connect(coin)
                .handleAffiliate(player.address, LARGE_AFFILIATE)
            ).wait();
            break;
          }
          case QUEST_TYPES.DECIMATOR: {
            await (
              await questModule
                .connect(coin)
                .handleDecimator(player.address, LARGE_DECIMATOR_BURN)
            ).wait();
            break;
          }
          default:
            throw new Error(`Unexpected quest type ${questType}`);
        }
      }

      const state = await questModule.playerQuestState(player.address);
      expect(state.streak).to.equal(BigInt(day));
      expect(state.lastCompletedDay).to.equal(BigInt(day));
    }

    const finalState = await questModule.playerQuestState(player.address);
    expect(finalState.streak).to.equal(60n);
    expect(finalState.lastCompletedDay).to.equal(60n);
    expect(finalState.completedToday).to.equal(true);
  });
});
