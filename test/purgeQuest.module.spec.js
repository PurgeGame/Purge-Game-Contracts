const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

const MILLION = 1_000_000n;
const QUEST_TYPE_COUNT = 7n;

const QUEST_TYPES = {
  MINT_ANY: 0,
  MINT_ETH: 1,
  FLIP: 2,
  STAKE: 3,
  AFFILIATE: 4,
  PURGE: 5,
  DECIMATOR: 6,
};

const QUEST_STAKE_REQUIRE_PRINCIPAL = 1;
const QUEST_STAKE_REQUIRE_DISTANCE = 1 << 1;
const QUEST_STAKE_REQUIRE_RISK = 1 << 2;

const LARGE_PRINCIPAL = 10_000n * MILLION;
const LARGE_TOKEN_CREDIT = 5_000n * MILLION;
const LARGE_AFFILIATE = 4_000n * MILLION;
const DECIMATOR_BURN = 20_000n * MILLION;
const LARGE_PURGE = 5_000;
const LARGE_MINT = 1_000;
const LONG_DISTANCE = 200;
const HIGH_RISK = 14;

function deriveQuestDetails(entropy) {
  const questType = Number(entropy % QUEST_TYPE_COUNT);
  const highDifficulty = Number(entropy & 0x3ffn) >= 900;
  let stakeMask = 0;
  let stakeRisk = 0;
  if (questType === QUEST_TYPES.STAKE) {
    stakeMask = QUEST_STAKE_REQUIRE_DISTANCE;
    const requirePrincipal = ((entropy >> 16n) & 1n) === 0n;
    if (requirePrincipal) {
      stakeMask |= QUEST_STAKE_REQUIRE_PRINCIPAL;
    } else {
      stakeMask |= QUEST_STAKE_REQUIRE_RISK;
      stakeRisk = Number(2n + ((entropy >> 40n) % 10n));
    }
  }
  return { questType, highDifficulty, stakeMask, stakeRisk };
}

function findEntropy({
  questType,
  highDifficulty,
  requirePrincipal,
  requireRisk,
} = {}) {
  for (let attempt = 1n; attempt < 1_000_000n; attempt += 1n) {
    const details = deriveQuestDetails(attempt);
    if (questType !== undefined && details.questType !== questType) continue;
    if (highDifficulty !== undefined && details.highDifficulty !== highDifficulty)
      continue;
    if (questType === QUEST_TYPES.STAKE) {
      const hasPrincipal =
        (details.stakeMask & QUEST_STAKE_REQUIRE_PRINCIPAL) !== 0;
      const hasRisk = (details.stakeMask & QUEST_STAKE_REQUIRE_RISK) !== 0;
      if (
        requirePrincipal !== undefined &&
        hasPrincipal !== requirePrincipal
      ) {
        continue;
      }
      if (requireRisk !== undefined && hasRisk !== requireRisk) {
        continue;
      }
    }
    return attempt;
  }
  throw new Error("No entropy found for requested quest type");
}

async function deployQuestFixture() {
  const [coin, player, other] = await ethers.getSigners();

  const QuestModule = await ethers.getContractFactory("PurgeQuestModule");
  const questModule = await QuestModule.deploy(await coin.getAddress());
  await questModule.waitForDeployment();

  const GameMock = await ethers.getContractFactory("QuestGameMock");
  const game = await GameMock.deploy();
  await game.waitForDeployment();

  return { coin, player, other, questModule, game };
}

async function deployQuestWithGameFixture() {
  const setup = await deployQuestFixture();
  await (
    await setup.questModule
      .connect(setup.coin)
      .wireGame(await setup.game.getAddress())
  ).wait();
  await (await setup.game.setLevel(100)).wait();
  await (await setup.game.setPhase(0)).wait();
  await (
    await setup.game.setEthMintLastLevel(await setup.player.getAddress(), 100)
  ).wait();
  await (await setup.game.setGameState(3)).wait();
  return setup;
}

async function rollDay(questModule, coin, day, entropy) {
  await (await questModule.connect(coin).rollDailyQuest(day, entropy)).wait();
  return questModule.getActiveQuests();
}

async function ensureMintHistory(game, player, level = 100) {
  await (await game.setLevel(level)).wait();
  await (
    await game.setEthMintLastLevel(await player.getAddress(), level)
  ).wait();
}

async function clearMintHistory(game, player) {
  await (await game.setEthMintLastLevel(await player.getAddress(), 0)).wait();
}

async function completeQuest(questModule, coin, player, quest) {
  const questType = Number(quest.questType);
  switch (questType) {
    case QUEST_TYPES.MINT_ANY:
      await (
        await questModule
          .connect(coin)
          .handleMint(await player.getAddress(), LARGE_MINT, false)
      ).wait();
      break;
    case QUEST_TYPES.MINT_ETH:
      await (
        await questModule
          .connect(coin)
          .handleMint(await player.getAddress(), LARGE_MINT, true)
      ).wait();
      break;
    case QUEST_TYPES.FLIP:
      await (
        await questModule
          .connect(coin)
          .handleFlip(await player.getAddress(), LARGE_TOKEN_CREDIT)
      ).wait();
      break;
    case QUEST_TYPES.STAKE: {
      const requiresRisk =
        (Number(quest.stakeMask) & QUEST_STAKE_REQUIRE_RISK) !== 0;
      const riskTarget = requiresRisk
        ? Math.max(Number(quest.stakeRisk), HIGH_RISK)
        : HIGH_RISK;
      await (
        await questModule
          .connect(coin)
          .handleStake(
            await player.getAddress(),
            LARGE_PRINCIPAL,
            LONG_DISTANCE,
            riskTarget
          )
      ).wait();
      break;
    }
    case QUEST_TYPES.AFFILIATE:
      await (
        await questModule
          .connect(coin)
          .handleAffiliate(await player.getAddress(), LARGE_AFFILIATE)
      ).wait();
      break;
    case QUEST_TYPES.PURGE:
      await (
        await questModule
          .connect(coin)
          .handlePurge(await player.getAddress(), LARGE_PURGE)
      ).wait();
      break;
    case QUEST_TYPES.DECIMATOR:
      await (
        await questModule
          .connect(coin)
          .handleDecimator(await player.getAddress(), DECIMATOR_BURN)
      ).wait();
      break;
    default:
      throw new Error(`Unhandled quest type ${questType}`);
  }
}

async function completeAllQuestsForDay(setup, day, entropy) {
  const { questModule, coin, player } = setup;
  const quests = await rollDay(questModule, coin, day, entropy);
  for (const quest of quests) {
    if (quest.day !== BigInt(day)) continue;
    await completeQuest(questModule, coin, player, quest);
  }
}

describe("PurgeQuestModule", function () {
  describe("admin controls", function () {
    it("only allows the coin to wire the game", async function () {
      const { questModule, game, coin, player } = await loadFixture(
        deployQuestFixture
      );
      await expect(
        questModule.connect(player).wireGame(await game.getAddress())
      ).to.be.revertedWithCustomError(questModule, "OnlyCoin");
      await expect(
        questModule.connect(coin).wireGame(await game.getAddress())
      ).to.not.be.reverted;
    });

    it("only allows the coin to prime a forced mint quest", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player } = setup;
      await expect(
        questModule.connect(player).primeMintEthQuest(5)
      ).to.be.revertedWithCustomError(questModule, "OnlyCoin");
      await expect(
        questModule.connect(coin).primeMintEthQuest(5)
      ).to.not.be.reverted;
    });
  });

  describe("rolling quests", function () {
    it("rejects invalid inputs and enforces onlyCoin on roll", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player } = setup;
      await expect(
        questModule.connect(player).rollDailyQuest(1, 10n)
      ).to.be.revertedWithCustomError(questModule, "OnlyCoin");
      await expect(
        questModule.connect(coin).rollDailyQuest(0, 10n)
      ).to.be.revertedWithCustomError(questModule, "InvalidQuestDay");
      await expect(
        questModule.connect(coin).rollDailyQuest(1, 0n)
      ).to.be.revertedWithCustomError(questModule, "InvalidEntropy");
    });

    it("caches daily quests and keeps slot types distinct", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin } = setup;
      const entropy = findEntropy({ questType: QUEST_TYPES.MINT_ANY });
      const quests = await rollDay(questModule, coin, 1, entropy);
      expect(quests[0].day).to.equal(1n);
      expect(quests[1].day).to.equal(1n);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.MINT_ANY);
      expect(Number(quests[1].questType)).to.not.equal(QUEST_TYPES.MINT_ANY);
      const [rolled, questType] = await questModule
        .connect(coin)
        .rollDailyQuest.staticCall(1, entropy);
      expect(rolled).to.equal(false);
      expect(Number(questType)).to.equal(QUEST_TYPES.MINT_ANY);
    });

    it("re-rolls duplicate quest slots caused by conversions", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, game } = setup;
      await (await game.setGameState(1)).wait();
      for (let i = 0; i < 25; i += 1) {
        const day = 10 + i;
        const entropy = BigInt(1000 + i * 7919);
        await expect(questModule.connect(coin).rollDailyQuest(day, entropy)).to.not.be.reverted;
        const quests = await questModule.getActiveQuests();
        expect(Number(quests[0].questType)).to.not.equal(Number(quests[1].questType));
      }
    });

    it("forces a mint-ETH quest when primed for a day", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin } = setup;
      const flipEntropy = findEntropy({ questType: QUEST_TYPES.FLIP });
      await (
        await questModule.connect(coin).primeMintEthQuest(5)
      ).wait();
      let quests = await rollDay(questModule, coin, 5, flipEntropy);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.MINT_ETH);
      quests = await rollDay(questModule, coin, 6, flipEntropy);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.FLIP);
    });

    it("converts purge quests outside of purge phase but locks completed days", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player, game } = setup;
      const purgeEntropy = findEntropy({ questType: QUEST_TYPES.PURGE });
      await (await game.setGameState(1)).wait();
      let quests = await rollDay(questModule, coin, 1, purgeEntropy);
      const fallbackDay1 =
        Number(quests[1].questType) === QUEST_TYPES.MINT_ETH
          ? QUEST_TYPES.STAKE
          : QUEST_TYPES.MINT_ETH;
      expect(Number(quests[0].questType)).to.equal(fallbackDay1);
      await (await game.setGameState(3)).wait();
      quests = await rollDay(questModule, coin, 2, purgeEntropy);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.PURGE);
      const fallbackConverted =
        Number(quests[1].questType) === QUEST_TYPES.MINT_ETH
          ? QUEST_TYPES.STAKE
          : QUEST_TYPES.MINT_ETH;
      await (
        await questModule
          .connect(coin)
          .handlePurge(await player.getAddress(), LARGE_PURGE)
      ).wait();
      await (await game.setGameState(1)).wait();
      const active = await questModule.getActiveQuest();
      expect(Number(active.questType)).to.equal(fallbackConverted);
    });

    it("enforces the decimator unlock schedule", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, game } = setup;
      const entropy = findEntropy({ questType: QUEST_TYPES.DECIMATOR });
      await (await game.setLevel(10)).wait();
      let quests = await rollDay(questModule, coin, 1, entropy);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.FLIP);
      await (await game.setLevel(35)).wait();
      quests = await rollDay(questModule, coin, 2, entropy);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.DECIMATOR);
      await (await game.setLevel(95)).wait();
      quests = await rollDay(questModule, coin, 3, entropy);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.FLIP);
    });
  });

  describe("mint quests", function () {
    it("awards progress for mint-any quests when the player recently minted", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player, game } = setup;
      await ensureMintHistory(game, player);
      const entropy = findEntropy({ questType: QUEST_TYPES.MINT_ANY });
      const quests = await rollDay(questModule, coin, 1, entropy);
      expect(Number(quests[0].questType)).to.equal(QUEST_TYPES.MINT_ANY);
      const result = await questModule
        .connect(coin)
        .handleMint.staticCall(await player.getAddress(), LARGE_MINT, false);
      expect(result.completed).to.equal(true);
      expect(result.reward).to.equal(100n * MILLION);
      expect(result.hardMode).to.equal(false);
      expect(Number(result.questType)).to.equal(QUEST_TYPES.MINT_ANY);
      expect(result.streak).to.equal(0n);
      await (
        await questModule
          .connect(coin)
          .handleMint(await player.getAddress(), LARGE_MINT, false)
      ).wait();
      const state = await questModule.playerQuestState(await player.getAddress());
      expect(state.streak).to.equal(0n);
      expect(state.lastCompletedDay).to.equal(0n);
      expect(state.progress).to.equal(BigInt(LARGE_MINT));
      expect(state.completedToday).to.equal(true);
    });

    it("forces an ETH mint quest when the player has no recent ETH mints", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player, game } = setup;
      await clearMintHistory(game, player);
      const entropy = findEntropy({ questType: QUEST_TYPES.MINT_ETH });
      await rollDay(questModule, coin, 1, entropy);
      const forced = await questModule
        .connect(coin)
        .handleMint.staticCall(await player.getAddress(), 1, true);
      expect(forced.completed).to.equal(true);
      expect(forced.reward).to.equal(0n);
      expect(Number(forced.questType)).to.equal(QUEST_TYPES.MINT_ETH);
      expect(forced.streak).to.equal(1n);
      await (
        await questModule
          .connect(coin)
          .handleMint(await player.getAddress(), 1, true)
      ).wait();
      let state = await questModule.playerQuestState(await player.getAddress());
      expect(state.streak).to.equal(1n);
      expect(state.lastCompletedDay).to.equal(1n);
      expect(state.completedToday).to.equal(false);
      await ensureMintHistory(game, player);
      const questReward = await questModule
        .connect(coin)
        .handleMint.staticCall(await player.getAddress(), LARGE_MINT, true);
      expect(questReward.reward).to.equal(100n * MILLION);
      expect(questReward.streak).to.equal(1n);
      await (
        await questModule
          .connect(coin)
          .handleMint(await player.getAddress(), LARGE_MINT, true)
      ).wait();
      state = await questModule.playerQuestState(await player.getAddress());
      expect(state.completedToday).to.equal(true);
    });

    it("completes both mint quests when an ETH mint satisfies each target", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player, game } = setup;
      await ensureMintHistory(game, player);

      let combinedQuests;
      for (let day = 1; day < 1500; day += 1) {
        const entropy = BigInt(10_000 + day);
        await (
          await questModule.connect(coin).rollDailyQuest(day, entropy)
        ).wait();
        const quests = await questModule.getActiveQuests();
        const slotTypes = quests.map((q) => Number(q.questType));
        const hasMintAny = slotTypes.includes(QUEST_TYPES.MINT_ANY);
        const hasMintEth = slotTypes.includes(QUEST_TYPES.MINT_ETH);
        const bothStandard = quests.every((q) => !q.highDifficulty && q.day === BigInt(day));
        if (hasMintAny && hasMintEth && bothStandard) {
          combinedQuests = quests;
          break;
        }
      }

      expect(combinedQuests, "missing Mint Any + Mint ETH day").to.not.equal(
        undefined
      );

      const staticResult = await questModule
        .connect(coin)
        .handleMint.staticCall(await player.getAddress(), LARGE_MINT, true);
      expect(staticResult.completed).to.equal(true);
      expect(staticResult.reward).to.equal(200n * MILLION);
      expect(staticResult.streak).to.equal(1n);

      await (
        await questModule
          .connect(coin)
          .handleMint(await player.getAddress(), LARGE_MINT, true)
      ).wait();

      const state = await questModule.playerQuestStates(
        await player.getAddress()
      );
      expect(state.streak).to.equal(1n);
      expect(state.completed[0]).to.equal(true);
      expect(state.completed[1]).to.equal(true);
    });
  });

  describe("token quests", function () {
    it("tracks flip progress using the highest credit", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player } = setup;
      const entropy = findEntropy({ questType: QUEST_TYPES.FLIP });
      await rollDay(questModule, coin, 1, entropy);
      const first = await questModule
        .connect(coin)
        .handleFlip.staticCall(await player.getAddress(), 50n * MILLION);
      expect(first.completed).to.equal(false);
      expect(Number(first.questType)).to.equal(QUEST_TYPES.FLIP);
      await (
        await questModule
          .connect(coin)
          .handleFlip(await player.getAddress(), 50n * MILLION)
      ).wait();
      const completion = await questModule
        .connect(coin)
        .handleFlip.staticCall(await player.getAddress(), 6_000n * MILLION);
      expect(completion.completed).to.equal(true);
      expect(completion.reward).to.equal(100n * MILLION);
      await (
        await questModule
          .connect(coin)
          .handleFlip(await player.getAddress(), 6_000n * MILLION)
      ).wait();
      const viewState = await questModule.playerQuestStates(
        await player.getAddress()
      );
      expect(viewState.progress[0]).to.equal(6_000n * MILLION);
      expect(viewState.completed[0]).to.equal(true);
    });

    it("requires huge burns for decimator quests when they are active", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player, game } = setup;
      await (await game.setLevel(35)).wait();
      const entropy = findEntropy({ questType: QUEST_TYPES.DECIMATOR });
      await rollDay(questModule, coin, 1, entropy);
      const miss = await questModule
        .connect(coin)
        .handleDecimator.staticCall(await player.getAddress(), 100n * MILLION);
      expect(miss.completed).to.equal(false);
      const finish = await questModule
        .connect(coin)
        .handleDecimator.staticCall(await player.getAddress(), DECIMATOR_BURN);
      expect(finish.completed).to.equal(true);
      expect(Number(finish.questType)).to.equal(QUEST_TYPES.DECIMATOR);
      await (
        await questModule
          .connect(coin)
          .handleDecimator(await player.getAddress(), DECIMATOR_BURN)
      ).wait();
    });

    it("enforces every stake condition based on the mask", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player } = setup;
      const principalEntropy = findEntropy({
        questType: QUEST_TYPES.STAKE,
        requirePrincipal: true,
      });
      await rollDay(questModule, coin, 1, principalEntropy);
      const failPrincipal = await questModule
        .connect(coin)
        .handleStake.staticCall(await player.getAddress(), 1, LONG_DISTANCE, 1);
      expect(failPrincipal.completed).to.equal(false);
      const passPrincipal = await questModule
        .connect(coin)
        .handleStake.staticCall(
          await player.getAddress(),
          LARGE_PRINCIPAL,
          LONG_DISTANCE,
          HIGH_RISK
        );
      expect(passPrincipal.completed).to.equal(true);
      await (
        await questModule
          .connect(coin)
          .handleStake(
            await player.getAddress(),
            LARGE_PRINCIPAL,
            LONG_DISTANCE,
            HIGH_RISK
          )
      ).wait();

      const riskEntropy = findEntropy({
        questType: QUEST_TYPES.STAKE,
        requireRisk: true,
      });
      await rollDay(questModule, coin, 2, riskEntropy);
      const quests = await questModule.getActiveQuests();
      const riskQuest = quests.find((quest) => Number(quest.questType) === QUEST_TYPES.STAKE);
      const targetRisk = Number(riskQuest.stakeRisk);
      const failRisk = await questModule
        .connect(coin)
        .handleStake.staticCall(
          await player.getAddress(),
          LARGE_PRINCIPAL,
          LONG_DISTANCE,
          targetRisk - 1
        );
      expect(failRisk.completed).to.equal(false);
      const passRisk = await questModule
        .connect(coin)
        .handleStake.staticCall(
          await player.getAddress(),
          LARGE_PRINCIPAL,
          LONG_DISTANCE,
          targetRisk + 1
        );
      expect(passRisk.completed).to.equal(true);
      await (
        await questModule
          .connect(coin)
          .handleStake(
            await player.getAddress(),
            LARGE_PRINCIPAL,
            LONG_DISTANCE,
            targetRisk + 1
          )
      ).wait();
    });

    it("tracks affiliate progress cumulatively", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player } = setup;
      const entropy = findEntropy({ questType: QUEST_TYPES.AFFILIATE });
      await rollDay(questModule, coin, 1, entropy);
      const miss = await questModule
        .connect(coin)
        .handleAffiliate.staticCall(await player.getAddress(), 10n * MILLION);
      expect(miss.completed).to.equal(false);
      await (
        await questModule
          .connect(coin)
          .handleAffiliate(await player.getAddress(), 10n * MILLION)
      ).wait();
      const finish = await questModule
        .connect(coin)
        .handleAffiliate.staticCall(
          await player.getAddress(),
          LARGE_AFFILIATE
        );
      expect(finish.completed).to.equal(true);
      await (
        await questModule
          .connect(coin)
          .handleAffiliate(await player.getAddress(), LARGE_AFFILIATE)
      ).wait();
      const state = await questModule.playerQuestStates(
        await player.getAddress()
      );
      expect(state.progress[0]).to.equal(LARGE_AFFILIATE + 10n * MILLION);
      expect(state.completed[0]).to.equal(true);
    });
  });

  describe("purge quests", function () {
    it("pays out larger rewards for high difficulty purge quests and locks the day", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player, game } = setup;
      const warmupEntropy = findEntropy({ questType: QUEST_TYPES.MINT_ANY });
      for (let day = 1; day <= 6; day += 1) {
        await completeAllQuestsForDay(setup, day, warmupEntropy);
      }
      const warmedState = await questModule.playerQuestState(await player.getAddress());
      expect(warmedState.streak).to.equal(6n);
      await (await game.setGameState(3)).wait();
      const entropy = findEntropy({
        questType: QUEST_TYPES.PURGE,
        highDifficulty: true,
      });
      const purgeDay = 7;
      const quests = await rollDay(questModule, coin, purgeDay, entropy);
      const otherSlot = Number(quests[0].questType) === QUEST_TYPES.PURGE ? quests[1] : quests[0];
      if (Number(otherSlot.questType) !== QUEST_TYPES.PURGE) {
        await completeQuest(questModule, coin, player, otherSlot);
      }
      const fallbackConverted =
        Number(otherSlot.questType) === QUEST_TYPES.MINT_ETH
          ? QUEST_TYPES.STAKE
          : QUEST_TYPES.MINT_ETH;
      const res = await questModule
        .connect(coin)
        .handlePurge.staticCall(await player.getAddress(), LARGE_PURGE);
      expect(res.hardMode).to.equal(true);
      expect(res.reward).to.equal(125n * MILLION);
      await (
        await questModule
          .connect(coin)
          .handlePurge(await player.getAddress(), LARGE_PURGE)
      ).wait();
      await (await game.setGameState(1)).wait();
      const info = await questModule.getActiveQuest();
      expect(Number(info.questType)).to.equal(fallbackConverted);
    });
  });

  describe("view helpers and streaks", function () {
    it("resets streaks after missing a day and only increments after both quests", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, player } = setup;
      const entropy = findEntropy({ questType: QUEST_TYPES.MINT_ANY });
      await completeAllQuestsForDay(setup, 1, entropy);
      let state = await questModule.playerQuestState(await player.getAddress());
      expect(state.streak).to.equal(1n);
      expect(state.lastCompletedDay).to.equal(1n);
      await rollDay(questModule, setup.coin, 2, entropy);
      await completeAllQuestsForDay(setup, 3, entropy);
      state = await questModule.playerQuestState(await player.getAddress());
      expect(state.streak).to.equal(1n);
      expect(state.lastCompletedDay).to.equal(3n);
    });

    it("reports progress per slot and clears it once a new day rolls", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player } = setup;
      const entropy = findEntropy({ questType: QUEST_TYPES.MINT_ANY });
      await rollDay(questModule, coin, 1, entropy);
      await (
        await questModule
          .connect(coin)
          .handleMint(await player.getAddress(), LARGE_MINT, false)
      ).wait();
      let view = await questModule.playerQuestStates(await player.getAddress());
      expect(view.progress[0]).to.equal(BigInt(LARGE_MINT));
      expect(view.completed[0]).to.equal(true);
      await rollDay(questModule, coin, 2, entropy);
      view = await questModule.playerQuestStates(await player.getAddress());
      expect(view.progress[0]).to.equal(0n);
      expect(view.completed[0]).to.equal(false);
    });

    it("includes streak bonuses and hard mode boosts in rewards", async function () {
      const setup = await loadFixture(deployQuestWithGameFixture);
      const { questModule, coin, player } = setup;
      const entropy = findEntropy({ questType: QUEST_TYPES.MINT_ANY });
      for (let day = 1; day <= 9; day += 1) {
        await completeAllQuestsForDay(setup, day, entropy);
      }
      const hardEntropy = findEntropy({
        questType: QUEST_TYPES.FLIP,
        highDifficulty: true,
      });
      const targetDay = 10;
      const quests = await rollDay(questModule, coin, targetDay, hardEntropy);
      const hardQuest = quests[0];
      expect(Number(hardQuest.questType)).to.equal(QUEST_TYPES.FLIP);
      await completeQuest(questModule, coin, player, quests[1]);
      const payout = await questModule
        .connect(coin)
        .handleFlip.staticCall(await player.getAddress(), LARGE_TOKEN_CREDIT);
      const streak = 10n;
      const baseReward = 200n * MILLION;
      let streakBonusUnits = 0n;
      if (streak >= 5n && (streak === 5n || streak % 10n === 0n)) {
        streakBonusUnits = streak * 100n;
        if (streakBonusUnits > 3000n) streakBonusUnits = 3000n;
      }
      const streakBonus = streakBonusUnits * MILLION;
      const hardBonus = streak >= 7n ? 50n * MILLION : 0n;
      const expectedReward = (baseReward + hardBonus) / 2n + streakBonus;
      expect(payout.reward).to.equal(expectedReward);
      expect(payout.hardMode).to.equal(true);
      expect(payout.streak).to.equal(streak);
      await (
        await questModule
          .connect(coin)
          .handleFlip(await player.getAddress(), LARGE_TOKEN_CREDIT)
      ).wait();
      const state = await questModule.playerQuestState(await player.getAddress());
      expect(state.streak).to.equal(streak);
      expect(state.lastCompletedDay).to.equal(BigInt(targetDay));
    });
  });
});
