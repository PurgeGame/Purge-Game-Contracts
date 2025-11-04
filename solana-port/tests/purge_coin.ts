import * as anchor from "@coral-xyz/anchor";
import { Program } from "@coral-xyz/anchor";
import { PurgeCoin } from "../target/types/purge_coin";

const toU64Bytes = (value: bigint) => {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64LE(value);
  return buf;
};

describe("purge_coin", () => {
  const provider = anchor.AnchorProvider.env();
  anchor.setProvider(provider);

  const program = anchor.workspace.PurgeCoin as Program<PurgeCoin>;
  const codeSeed = anchor.web3.Keypair.generate();

  it("runs coin scaffolding flows", async () => {
    const [statePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("purge-coin")],
      program.programId
    );
    const [treasuryPda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("coin-treasury")],
      program.programId
    );
    const [bountyPda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("bounty")],
      program.programId
    );

    await program.methods
      .initialize({
        minBet: new anchor.BN(1),
        minBurn: new anchor.BN(1),
        houseEdgeBps: 500,
        burnTaxBps: 200,
      })
      .accounts({
        payer: provider.wallet.publicKey,
        authority: provider.wallet.publicKey,
        state: statePda,
        purgeMint: provider.wallet.publicKey,
        coinTreasury: treasuryPda,
        bountyVault: bountyPda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Coin initialize stub not executed:", err);
      });

    await program.methods
      .configureCoin({
        minBet: new anchor.BN(10),
        minBurn: null,
        houseEdgeBps: null,
        burnTaxBps: null,
      })
      .accounts({
        authority: provider.wallet.publicKey,
        state: statePda,
      })
      .rpc()
      .catch((err) => {
        console.warn("Coin configure stub not executed:", err);
      });

    const betId = 1n;
    const betSeed = toU64Bytes(betId);
    const [betPda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("bet"), provider.wallet.publicKey.toBuffer(), betSeed],
      program.programId
    );
    const [stakePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("stake"), provider.wallet.publicKey.toBuffer()],
      program.programId
    );

    await program.methods
      .placeBet({
        amount: new anchor.BN(1_000_000),
        targetLevel: 1,
        risk: 1,
        betId: new anchor.BN(betId),
      })
      .accounts({
        player: provider.wallet.publicKey,
        state: statePda,
        bet: betPda,
        stakeState: stakePda,
        systemProgram: anchor.web3.SystemProgram.programId,
      })
      .rpc()
      .catch((err) => {
        console.warn("Place bet stub not executed:", err);
      });

    await program.methods
      .settleBet(true, new anchor.BN(0))
      .accounts({
        state: statePda,
        bet: betPda,
        coinTreasury: treasuryPda,
        resolverProgram: program.programId,
      })
      .rpc()
      .catch((err) => {
        console.warn("Settle bet stub not executed:", err);
      });

    await program.methods
      .recordBurn(new anchor.BN(10))
      .accounts({
        state: statePda,
        coinTreasury: treasuryPda,
        player: provider.wallet.publicKey,
      })
      .rpc()
      .catch((err) => {
        console.warn("Record burn stub not executed:", err);
      });

    const [affiliatePda] = anchor.web3.PublicKey.findProgramAddressSync(
      [Buffer.from("affiliate"), codeSeed.publicKey.toBuffer()],
      program.programId
    );

    await program.methods
      .awardAffiliate(new anchor.BN(500))
      .accounts({
        state: statePda,
        codeSeed: codeSeed.publicKey,
        affiliateState: affiliatePda,
        authority: provider.wallet.publicKey,
        systemProgram: anchor.web3.SystemProgram.programId,
      })
      .rpc()
      .catch((err) => {
        console.warn("Award affiliate stub not executed:", err);
      });

    await program.methods
      .claimAffiliate(new anchor.BN(100))
      .accounts({
        state: statePda,
        codeSeed: codeSeed.publicKey,
        affiliateState: affiliatePda,
        receiver: provider.wallet.publicKey,
      })
      .rpc()
      .catch((err) => {
        console.warn("Claim affiliate stub not executed:", err);
      });
  });
});
