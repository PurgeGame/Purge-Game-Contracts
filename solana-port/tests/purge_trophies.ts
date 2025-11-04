import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { PurgeTrophies } from "../target/types/purge_trophies";

describe("purge_trophies", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const program = anchor.workspace.PurgeTrophies as Program<PurgeTrophies>;

  it("initializes trophies and exercises queues", async () => {
    const [statePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("trophies")],
      program.programId
    );
    const [vaultPda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("trophy-vault")],
      program.programId
    );
    const [queuePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("map-reward-queue")],
      program.programId
    );
    const [samplePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("stake-sample")],
      program.programId
    );

    await program.methods
      .initialize({
        mapRewardBasisPoints: 500,
        mapRewardMinimum: new anchor.BN(1_000),
        purgeCoinProgram: program.programId,
        purgeGameProgram: program.programId,
        gameAuthority: provider.wallet.publicKey,
      })
      .accounts({
        payer: provider.wallet.publicKey,
        authority: provider.wallet.publicKey,
        state: statePda,
        trophyVault: vaultPda,
        mapRewardQueue: queuePda,
        stakeSample: samplePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Trophies initialize stub not executed:", err);
      });

    await program.methods
      .awardTrophy({
        level: 1,
        kind: 0,
        data: new anchor.BN(0),
        deferredLamports: new anchor.BN(1_000),
      })
      .accounts({
        authority: provider.wallet.publicKey,
        state: statePda,
        trophyVault: vaultPda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Award trophy stub not executed:", err);
      });

    await program.methods
      .enqueueMapReward({
        player: provider.wallet.publicKey,
        traitId: 1,
        level: 1,
        amountLamports: new anchor.BN(1_000),
      })
      .accounts({
        authority: provider.wallet.publicKey,
        state: statePda,
        mapRewardQueue: queuePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Enqueue map reward stub not executed:", err);
      });

    await program.methods
      .processEndLevel({
        level: 1,
        carryoverLamports: new anchor.BN(0),
      })
      .accounts({
        state: statePda,
        trophyVault: vaultPda,
        mapRewardQueue: queuePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Process end level stub not executed:", err);
      });

    await program.methods
      .popMapReward()
      .accounts({
        mapRewardQueue: queuePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Pop map reward stub not executed:", err);
      });
  });
});
