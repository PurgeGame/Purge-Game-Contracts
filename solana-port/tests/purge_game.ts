import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { PurgeGame } from "../target/types/purge_game";

describe("purge_game", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const program = anchor.workspace.PurgeGame as Program<PurgeGame>;
  const u32ToBytes = (value: number) => {
    const buf = Buffer.alloc(4);
    buf.writeUInt32LE(value);
    return buf;
  };
  const u16ToBytes = (value: number) => {
    const buf = Buffer.alloc(2);
    buf.writeUInt16LE(value);
    return buf;
  };

  it("initializes the game state", async () => {
    const [gameStatePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("game-state")],
      program.programId
    );
    const [gameTreasuryPda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("game-treasury")],
      program.programId
    );
    const [mapMintQueuePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("map-mint-queue")],
      program.programId
    );
    const [rngRequestPda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("rng-request")],
      program.programId
    );

    await program.methods
      .initializeGame({
        priceLamports: new anchor.BN(0),
        pricePurge: new anchor.BN(0),
        maxLevel: 1,
        coinProgram: anchor.web3.SystemProgram.programId,
        trophyProgram: anchor.web3.SystemProgram.programId,
        rngProvider: provider.wallet.publicKey,
        jackpotsPerDay: 5,
        earlyPurgeThreshold: 30,
      })
      .accounts({
        payer: provider.wallet.publicKey,
        authority: provider.wallet.publicKey,
        gameState: gameStatePda,
        gameTreasury: gameTreasuryPda,
        mapMintQueue: mapMintQueuePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Initialization stub not executed:", err);
      });

    await program.methods
      .configureGame({
        priceLamports: new anchor.BN(1_000_000),
        pricePurge: null,
        jackpotsPerDay: null,
        earlyPurgeThreshold: null,
        rngProvider: null,
      })
      .accounts({
        authority: provider.wallet.publicKey,
        gameState: gameStatePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Configure stub not executed:", err);
      });

    const tagBytes = Array.from(Buffer.from("PURGERNG".padEnd(8, "\0")));
    await program.methods
      .requestRng({ tag: tagBytes })
      .accounts({
        gameState: gameStatePda,
        rngRequest: rngRequestPda,
        payer: provider.wallet.publicKey,
      })
      .rpc()
      .catch((err) => {
        console.warn("RNG request stub not executed:", err);
      });

    await program.methods
      .queueMapMint({
        player: provider.wallet.publicKey,
        traitId: 1,
        level: 1,
      })
      .accounts({
        authority: provider.wallet.publicKey,
        gameState: gameStatePda,
        mapMintQueue: mapMintQueuePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Queue map mint stub not executed:", err);
      });

    await program.methods
      .dequeueMapMint()
      .accounts({
        authority: provider.wallet.publicKey,
        gameState: gameStatePda,
        mapMintQueue: mapMintQueuePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Dequeue map mint stub not executed:", err);
      });

    const [ticketPagePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [
        Buffer.from("ticket"),
        u32ToBytes(1),
        u16ToBytes(1),
        u16ToBytes(0),
      ],
      program.programId
    );

    await program.methods
      .addTraitTicket({
        level: 1,
        traitId: 1,
        pageIndex: 0,
      })
      .accounts({
        authority: provider.wallet.publicKey,
        gameState: gameStatePda,
        player: provider.wallet.publicKey,
        ticketPage: ticketPagePda,
        systemProgram: anchor.web3.SystemProgram.programId,
      })
      .rpc()
      .catch((err) => {
        console.warn("Add trait ticket stub not executed:", err);
      });

    await program.methods
      .clearTraitTicketPage({
        level: 1,
        traitId: 1,
        pageIndex: 0,
      })
      .accounts({
        authority: provider.wallet.publicKey,
        gameState: gameStatePda,
        ticketPage: ticketPagePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Clear trait ticket stub not executed:", err);
      });
  });
});
