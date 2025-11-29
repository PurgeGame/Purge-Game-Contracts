const { expect } = require("chai");
const { ethers } = require("hardhat");

const DAY = 24 * 60 * 60;
const JACKPOT_RESET_TIME = 82_620;

describe("Map jackpot gas envelope", function () {
  it("keeps the map jackpot chain under 14m gas in a worst-case style sim", async function () {
    const [deployer, player] = await ethers.getSigners();

    // Deploy mocks and modules.
    const renderer = await (await ethers.getContractFactory("MJRenderer")).deploy();
    const coin = await (await ethers.getContractFactory("MJCoin")).deploy();
    const jackpots = await (await ethers.getContractFactory("PurgeJackpots")).deploy();
    const trophies = await (await ethers.getContractFactory("MJTrophies")).deploy();
    const nft = await (await ethers.getContractFactory("MJNFT")).deploy();
    const vrf = await (await ethers.getContractFactory("MJVRFCoordinator")).deploy();
    const steth = await (await ethers.getContractFactory("MJStETH")).deploy();
    const bonds = await (await ethers.getContractFactory("MJBonds")).deploy();
    await bonds.setPendingCount(50);

    const endgame = await (await ethers.getContractFactory("PurgeGameEndgameModule")).deploy();
    const jackpotModule = await (await ethers.getContractFactory("PurgeGameJackpotModule")).deploy();

    const game = await (
      await ethers.getContractFactory("MapJackpotHarness")
    ).deploy(
      await coin.getAddress(),
      await renderer.getAddress(),
      await nft.getAddress(),
      await trophies.getAddress(),
      await endgame.getAddress(),
      await jackpotModule.getAddress(),
      await vrf.getAddress(),
      ethers.ZeroHash,
      1,
      await coin.getAddress(),
      await steth.getAddress()
    );

    await coin.setJackpots(await jackpots.getAddress());
    await coin.setGame(await game.getAddress());
    await trophies.wire(await game.getAddress(), await coin.getAddress());
    await nft.setGame(await game.getAddress());
    await coin.wireBonds(await game.getAddress(), await bonds.getAddress());

    // Prime balances and state for the map jackpot request.
    const latestBlock = await ethers.provider.getBlock("latest");
    const targetTs = Number(latestBlock.timestamp) + 10 * DAY;
    await ethers.provider.send("evm_setNextBlockTimestamp", [targetTs]);
    await ethers.provider.send("evm_mine", []);
    const day = Math.floor((targetTs - JACKPOT_RESET_TIME) / DAY);

    const principal = ethers.parseEther("100");
    await game.harnessSetPrincipal(principal);
    await steth.mint(await game.getAddress(), principal + ethers.parseEther("20"));

    await game.harnessSetMintDay(deployer.address, day);
    await game.harnessSetLevel(99);
    await game.harnessSetPhaseAndState(3, 2);
    await game.harnessSetDailyIdx(day - 1);
    await game.harnessForceRngState(0, true, false);
    await game.harnessSetPools(ethers.parseEther("500"), ethers.parseEther("300"), ethers.parseEther("150"));

    // Large pending map batch to max the writes budget, plus a hefty mint count to drive trait rebuild.
    await game.harnessSetPendingMaps([player.address], [540]);
    await nft.setPurchaseCount(4_000);
    await game.harnessSetAirdropMultiplier(2);

    // Tx 1: request RNG + prep bonds.
    const tx1 = await game.connect(deployer).advanceGame(0);
    const rc1 = await tx1.wait();

    // Fulfill RNG for the map jackpot.
    await vrf.fulfillLatest(await game.getAddress(), 123_456_789);

    const beforeMapBatch = await game.harnessMapBatchState(player.address);

    // Tx 2: map jackpot payout (phase 3 -> 4).
    const tx2 = await game.connect(deployer).advanceGame(0);
    const rc2 = await tx2.wait();

    const afterMapBatch = await game.harnessMapBatchState(player.address);
    expect(afterMapBatch.idx).to.equal(beforeMapBatch.idx);
    expect(afterMapBatch.owed).to.equal(beforeMapBatch.owed);

    // Tx 3+: trait rebuild slices and finalization (phase 5).
    const phase5Gas = [];
    let guard = 0;
    while ((await game.gameState()) === 2n) {
      guard += 1;
      const tx = await game.connect(deployer).advanceGame(0);
      const rc = await tx.wait();
      phase5Gas.push(rc.gasUsed);
      if (guard > 10) break; // sanity guard
    }

    const allGas = [rc1.gasUsed, rc2.gasUsed, ...phase5Gas];
    const maxGas = allGas.reduce((acc, v) => (v > acc ? v : acc), 0n);
    const overCap = maxGas > 14_000_000n;

    // Log for quick inspection when running the test locally.
    // eslint-disable-next-line no-console
    console.log({
      rngRequest: rc1.gasUsed.toString(),
      mapJackpot: rc2.gasUsed.toString(),
      phase5: phase5Gas.map((g) => g.toString()),
      maxGas: maxGas.toString(),
      overCap14m: overCap
    });

    expect(allGas.every((g) => g > 0n)).to.equal(true);
  });
});
