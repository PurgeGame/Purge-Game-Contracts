import * as anchor from "@coral-xyz/anchor";

type PurgeGameProgram = typeof anchor.workspace.PurgeGame;
type PurgeCoinProgram = typeof anchor.workspace.PurgeCoin;
type PurgeTrophiesProgram = typeof anchor.workspace.PurgeTrophies;

const PDA_SEEDS = {
  game: {
    state: Buffer.from("game-state"),
    treasury: Buffer.from("game-treasury"),
    mapQueue: Buffer.from("map-mint-queue"),
    rngRequest: Buffer.from("rng-request"),
  },
  coin: {
    state: Buffer.from("purge-coin"),
    treasury: Buffer.from("coin-treasury"),
    bounty: Buffer.from("bounty"),
    stake: Buffer.from("stake"),
    bet: Buffer.from("bet"),
  },
  trophies: {
    state: Buffer.from("trophies"),
    vault: Buffer.from("trophy-vault"),
    queue: Buffer.from("map-reward-queue"),
    sample: Buffer.from("stake-sample"),
  },
};

const u64Bytes = (value: bigint) => {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64LE(value);
  return buf;
};

export default async function main(provider: anchor.AnchorProvider) {
  anchor.setProvider(provider);

  const purgeGame = anchor.workspace.PurgeGame as PurgeGameProgram;
  const purgeCoin = anchor.workspace.PurgeCoin as PurgeCoinProgram;
  const purgeTrophies = anchor.workspace.PurgeTrophies as PurgeTrophiesProgram;

  if (process.env.DEPLOY_PURGE_GAME === "true") {
    const [gameState] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.game.state],
      purgeGame.programId
    );
    const [gameTreasury] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.game.treasury],
      purgeGame.programId
    );
    const [mapMintQueue] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.game.mapQueue],
      purgeGame.programId
    );

    await purgeGame.methods
      .initializeGame({
        priceLamports: new anchor.BN(2_500_000),
        pricePurge: new anchor.BN(1_000_000_000),
        maxLevel: 1000,
        coinProgram: purgeCoin.programId,
        trophyProgram: purgeTrophies.programId,
        rngProvider: provider.wallet.publicKey,
        jackpotsPerDay: 5,
        earlyPurgeThreshold: 30,
      })
      .accounts({
        payer: provider.wallet.publicKey,
        authority: provider.wallet.publicKey,
        gameState,
        gameTreasury,
        mapMintQueue,
      })
      .rpc();

    if (process.env.SEED_MAP_MINT === "true") {
      await purgeGame.methods
        .queueMapMint({
          player: provider.wallet.publicKey,
          traitId: 1,
          level: 1,
        })
        .accounts({
          authority: provider.wallet.publicKey,
          gameState,
          mapMintQueue,
        })
        .rpc();
    }
  }

  if (process.env.DEPLOY_PURGE_COIN === "true") {
    const [coinState] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.coin.state],
      purgeCoin.programId
    );
    const [coinTreasury] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.coin.treasury],
      purgeCoin.programId
    );
    const [bountyVault] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.coin.bounty],
      purgeCoin.programId
    );

    await purgeCoin.methods
      .initialize({
        minBet: new anchor.BN(100_000),
        minBurn: new anchor.BN(100_000),
        houseEdgeBps: 500,
        burnTaxBps: 200,
      })
      .accounts({
        payer: provider.wallet.publicKey,
        authority: provider.wallet.publicKey,
        state: coinState,
        purgeMint: provider.wallet.publicKey,
        coinTreasury,
        bountyVault,
      })
      .rpc();

    if (process.env.SEED_SAMPLE_BET === "true") {
      const betId = 1n;
      const [betPda] = anchor.web3.PublicKey.findProgramAddressSync(
        [PDA_SEEDS.coin.bet, provider.wallet.publicKey.toBuffer(), u64Bytes(betId)],
        purgeCoin.programId
      );
      const [stakeState] = anchor.web3.PublicKey.findProgramAddressSync(
        [PDA_SEEDS.coin.stake, provider.wallet.publicKey.toBuffer()],
        purgeCoin.programId
      );

      await purgeCoin.methods
        .placeBet({
          amount: new anchor.BN(1_000_000),
          targetLevel: 1,
          risk: 1,
          betId: new anchor.BN(betId),
        })
        .accounts({
          player: provider.wallet.publicKey,
          state: coinState,
          bet: betPda,
          stakeState,
          systemProgram: anchor.web3.SystemProgram.programId,
        })
        .rpc();
    }
  }

  if (process.env.DEPLOY_PURGE_TROPHIES === "true") {
    const [trophyState] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.trophies.state],
      purgeTrophies.programId
    );
    const [trophyVault] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.trophies.vault],
      purgeTrophies.programId
    );
    const [mapRewardQueue] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.trophies.queue],
      purgeTrophies.programId
    );
    const [stakeSample] = anchor.web3.PublicKey.findProgramAddressSync(
      [PDA_SEEDS.trophies.sample],
      purgeTrophies.programId
    );

    await purgeTrophies.methods
      .initialize({
        mapRewardBasisPoints: 500,
        mapRewardMinimum: new anchor.BN(1_000),
        purgeCoinProgram: purgeCoin.programId,
        purgeGameProgram: purgeGame.programId,
        gameAuthority: provider.wallet.publicKey,
      })
      .accounts({
        payer: provider.wallet.publicKey,
        authority: provider.wallet.publicKey,
        state: trophyState,
        trophyVault,
        mapRewardQueue,
        stakeSample,
      })
      .rpc();
  }

  console.log("Migration script executed. Configure environment variables to enable flows.");
}

// Ensure the script returns a promise for Anchor CLI compatibility.
main(anchor.AnchorProvider.env()).catch((err) => {
  console.error(err);
  process.exit(1);
});
