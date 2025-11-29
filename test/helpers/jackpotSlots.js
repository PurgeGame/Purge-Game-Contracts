const { artifacts } = require("hardhat");

const CONTRACT_PATH = "contracts/modules/PurgeJackpots.sol:PurgeJackpots";

async function getJackpotSlots() {
  const buildInfo = await artifacts.getBuildInfo(CONTRACT_PATH);
  if (!buildInfo) {
    throw new Error(`Build info missing for ${CONTRACT_PATH}`);
  }
  const storage = buildInfo.output.contracts["contracts/modules/PurgeJackpots.sol"].PurgeJackpots.storageLayout
    .storage;

  const slotOf = (label) => {
    const entry = storage.find((item) => item.label === label);
    if (!entry) throw new Error(`slot for ${label} not found`);
    return BigInt(entry.slot);
  };

  return {
    decBurnSlot: slotOf("decBurn"),
    decPlayersCountSlot: slotOf("decPlayersCount"),
    decBucketRosterSlot: slotOf("decBucketRoster"),
    decBucketBurnTotalSlot: slotOf("decBucketBurnTotal"),
    decBucketTopSlot: slotOf("decBucketTop"),
    decBucketFillCountSlot: slotOf("decBucketFillCount"),
    decBucketIndexSlot: slotOf("decBucketIndex"),
    decBucketOffsetSlot: slotOf("decBucketOffset"),
    decClaimRoundSlot: slotOf("decClaimRound"),
  };
}

module.exports = { getJackpotSlots };
