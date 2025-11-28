const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

describe("PurgeGame Randomness Security", function () {
  async function deployFixture() {
    const [owner, player1, player2] = await ethers.getSigners();

    // Deploy Mocks
    const MockPurgeGameTrophies = await ethers.getContractFactory("MockPurgeGameTrophies");
    const trophies = await MockPurgeGameTrophies.deploy();

    const MockVRFCoordinator = await ethers.getContractFactory("MockGameDeps");
    const vrf = await MockVRFCoordinator.deploy();

    const MockLink = await ethers.getContractFactory("MockStETH"); // Reuse for LINK
    const link = await MockLink.deploy();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    const steth = await MockStETH.deploy();

    // Deploy Modules
    const PurgeGameJackpotModule = await ethers.getContractFactory("PurgeGameJackpotModule");
    const jackpotModule = await PurgeGameJackpotModule.deploy();

    const PurgeGameEndgameModule = await ethers.getContractFactory("PurgeGameEndgameModule");
    const endgameModule = await PurgeGameEndgameModule.deploy();

    // Deploy Core
    const Purgecoin = await ethers.getContractFactory("Purgecoin");
    const purgecoin = await Purgecoin.deploy(owner.address);

    const PurgeGame = await ethers.getContractFactory("PurgeGame");
    const game = await PurgeGame.deploy(
      await purgecoin.getAddress(),
      owner.address, // renderer (mock)
      owner.address, // nft (temp)
      await trophies.getAddress(),
      await endgameModule.getAddress(),
      await jackpotModule.getAddress(),
      await vrf.getAddress(),
      ethers.ZeroHash,
      1n,
      await link.getAddress(),
      await steth.getAddress()
    );

    const PurgeGameNFT = await ethers.getContractFactory("PurgeGameNFT");
    const nft = await PurgeGameNFT.deploy(
        owner.address, 
        owner.address, 
        await purgecoin.getAddress()
    );

    // Wiring
    await purgecoin.init(await game.getAddress(), await nft.getAddress(), await jackpotModule.getAddress());
    await nft.wireAll(await game.getAddress(), await trophies.getAddress());
    
    // Hack: We need to set the NFT address in PurgeGame. 
    // But PurgeGame constructor sets it immutable. 
    // We might need to redeploy PurgeGame with the correct NFT address if possible, 
    // or use a harness if PurgeGame was designed with a setter (it's immutable in the code).
    // Wait, PurgeGame takes `nftContract` in constructor.
    // Circular dependency?
    // PurgeGame needs NFT address. NFT needs Game address.
    // Usually solved by deploying one, then the other, then wiring.
    // But PurgeGame stores `nft` as immutable `IPurgeGameNFT private immutable nft;`.
    // This means we can't change it.
    // We need to pre-calculate the address or use a proxy?
    // Or maybe `PurgeGameNFT` is deployed first?
    // `PurgeGameNFT` constructor takes `coin`.
    // `PurgeGame` takes `nft`.
    // So: Coin -> NFT -> Game.
    // But NFT needs Game address for `onlyGame` modifier.
    // `PurgeGameNFT` has `wireAll`. So we can deploy NFT first.
    
    const nft2 = await PurgeGameNFT.deploy(
        owner.address, 
        owner.address, 
        await purgecoin.getAddress()
    );
    
    const game2 = await PurgeGame.deploy(
      await purgecoin.getAddress(),
      owner.address,
      await nft2.getAddress(),
      await trophies.getAddress(),
      await endgameModule.getAddress(),
      await jackpotModule.getAddress(),
      await vrf.getAddress(),
      ethers.ZeroHash,
      1n,
      await link.getAddress(),
      await steth.getAddress()
    );

    await purgecoin.init(await game2.getAddress(), await nft2.getAddress(), await jackpotModule.getAddress());
    await nft2.wireAll(await game2.getAddress(), await trophies.getAddress());

    return { game: game2, nft: nft2, vrf, owner, player1, purgecoin };
  }

  it("should prevent map purchase when RNG is requested", async function () {
    const { game, nft, vrf, player1 } = await loadFixture(deployFixture);

    // Advance to State 2 (Purchase)
    // This requires passing State 1 (Pregame)
    // Initial State is 0.
    // We need to trigger `advanceGame`.
    // But `advanceGame` checks `MustMintToday` if cap=0.
    // We can use cap != 0 to bypass mint check? No, cap is for dormant/loops.
    // First run: `gameState` is 0. `advanceGame` sets `gameState`?
    // Wait, `gameState` starts at 0.
    // `advanceGame`:
    // if (ts - 365 days > levelStartTime) -> reset to 0.
    // We need to get to State 2.
    // Typically `startLevel` or similar sets it off?
    // `PurgeGame.sol` doesn't have a `start` function.
    // Maybe `advanceGame` does it?
    // Ah, `_endLevel` sets `gameState = 1`.
    // How do we start Level 1?
    // In `PurgeGame.sol`, `gameState` 0 is Idle.
    // If we are in 0, `advanceGame` loops?
    // `rngAndTimeGate` checks `day == dailyIdx`.
    // It seems we need to understand how the game starts.
    // Usually there's an initializer or the first `advanceGame` kicks it off.
    
    // Let's look at `_endLevel`.
    // Is there a manual start?
    // The constructor doesn't set state.
    // `advanceGame`: 
    // `uint8 _gameState = gameState;`
    // `uint8 _phase = phase;`
    // `do { ... }`
    // If state is 0, nothing happens inside the loop?
    // `if (_gameState == 1) ...`
    // `if (_gameState == 2) ...`
    // `if (_gameState == 3) ...`
    // So if state is 0, `advanceGame` does nothing but emit `Advance(0, 0)`.
    
    // CHECK: Is there a `startSeason` or similar?
    // Searching `PurgeGame.sol`... I don't see it.
    // Maybe `Purgecoin.sol` calls something?
    // Maybe we need to hack the storage slot for `gameState` in the test since we don't have the full "start" script.
    // Or maybe I missed something in `PurgeGame`.
    // Ah, `endgameModule` might drive it?
    
    // For this test, I will simulate being in State 2 (Purchase) Phase 4 (Map Jackpot) where RNG is needed.
    // I'll use `hardhat_setStorageAt` to set `gameState = 2`, `phase = 4`, `level = 1`.
    
    // Slot layout for PurgeGameStorage?
    // Inherits `PurgeGameStorage`.
    // Let's assume standard packing.
    // `gameState` is uint8. `phase` is uint8.
    // They are likely packed together.
    
    // To be safe, I'll just use the fact that I can manipulate the contract via `game` if I can find the slot.
    // But easier: The `rngAndTimeGate` logic is generic. 
    // I just need to get into a state where `rngAndTimeGate` requests RNG.
    // That happens when `rngLockedFlag` is false, and we call `advanceGame`.
    
    // Let's try to force `gameState` to 2 using storage manipulation.
    // `gameState` is likely at slot 0 or nearby in `PurgeGameStorage`.
    
    // PurgeGameStorage.sol:
    // uint8 public gameState;
    // uint8 public phase;
    // ...
    // It's likely Slot 0 starts with these.
    
    const GAME_STATE_SLOT = 0; 
    // gameState is byte 0? Or packed?
    // `PurgeGameStorage` structure:
    // uint8 public gameState;
    // uint8 public phase;
    // uint8 public jackpotCounter;
    // ...
    
    // Let's set gameState = 2, phase = 3 (Decimator -> Map Jackpot).
    // packed: phase(2) | gameState(2) ?
    // Slot 0: 0x...0302 (phase=3, state=2)
    
    // Actually, let's just set `gameState` to 2 and `phase` to 3.
    // This should trigger RNG request in `advanceGame`.
    
    // Note: Hardhat storage layout might vary.
    
    // Alternative: We can rely on the fact that `nft._mintAndPurge` checks `rngLocked_`.
    // I can manually set `rngLockedFlag` to true in storage and verify revert.
    
    // Find `rngLockedFlag` slot.
    // In `PurgeGameStorage.sol`:
    // ...
    // bool public rngLockedFlag;
    // ...
    // It's a boolean.
    
    // gameState is in Slot 1.
    // Slot 1 layout:
    // level (3), lastExterminatedTrait (2), gameState (1), jackpotCounter (1), earlyPurgePercent (1), phase (1), ...
    // rngLockedFlag is at offset 3+2+1+1+1+1+1 = 10 bytes.
    
    const SLOT_1 = 1;
    
    // Helper to set storage
    async function setStorageAt(address, slot, value) {
        await ethers.provider.send("hardhat_setStorageAt", [
            address,
            ethers.toBeHex(slot),
            ethers.toBeHex(value, 32)
        ]);
    }

    // Construct Slot 1 Value
    // We want:
    // level = 1
    // lastExterminatedTrait = 420 (0x01A4)
    // gameState = 2 (Purchase)
    // phase = 4 (Map Jackpot)
    // rngLockedFlag = true
    
    // Values:
    // level = 1 -> 0x000001
    // lastExterminatedTrait = 420 -> 0x01A4
    // gameState = 2 -> 0x02
    // phase = 4 -> 0x04
    // rngLockedFlag = 1 -> 0x01
    
    let slot1Val = 0n;
    slot1Val |= 1n; // level
    slot1Val |= (420n << 24n); // lastExterminatedTrait
    slot1Val |= (2n << 40n); // gameState
    slot1Val |= (0n << 48n); // jackpotCounter
    slot1Val |= (0n << 56n); // earlyPurgePercent
    slot1Val |= (4n << 64n); // phase
    slot1Val |= (0n << 72n); // earlyPurgeBoostArmed
    slot1Val |= (1n << 80n); // rngLockedFlag
    
    await setStorageAt(await game.getAddress(), SLOT_1, slot1Val);
    
    // Now try to purchase map
    // mintAndPurge(quantity, payInCoin, affiliateCode)
    const quantity = 4; // 1 map
    
    // Expect revert "RngNotReady" (Custom Error 0x...) or just check name if decoding works
    await expect(
        nft.connect(player1).mintAndPurge(quantity, false, ethers.ZeroHash, { value: ethers.parseEther("0.025") })
    ).to.be.revertedWithCustomError(nft, "RngNotReady");

    // Unlocking RNG should allow it (if we fix the rest of the state)
    // Set rngLockedFlag = 0
    slot1Val &= ~(1n << 80n); 
    await setStorageAt(await game.getAddress(), SLOT_1, slot1Val);
    
    // Note: It might still revert with something else because our mock setup is imperfect (e.g. renderer), 
    // but we passed the RngNotReady check.
    // Actually, if we pass RngNotReady, we might hit "E()" or similar. 
    // But checking that it DOESN'T revert with RngNotReady is enough?
    // Or expect it to revert with something *else*.
    
    await expect(
        nft.connect(player1).mintAndPurge(quantity, false, ethers.ZeroHash, { value: ethers.parseEther("0.025") })
    ).to.not.be.revertedWithCustomError(nft, "RngNotReady");
  });
  
  it("should prevent reverseFlip when RNG is requested", async function () {
    const { game, player1 } = await loadFixture(deployFixture);
    const SLOT_1 = 1;
    
    // Set rngLockedFlag = 1
    let slot1Val = 0n;
    slot1Val |= (1n << 80n); // rngLockedFlag offset
    await setStorageAt(await game.getAddress(), SLOT_1, slot1Val);
    
    // Expect revert "RngLocked"
    await expect(
        game.connect(player1).reverseFlip()
    ).to.be.revertedWithCustomError(game, "RngLocked");
    
    // Unlock
    slot1Val &= ~(1n << 80n);
    await setStorageAt(await game.getAddress(), SLOT_1, slot1Val);
    
    // Should verify we pass the check (might fail later due to funds etc)
    // reverseFlip burns coin. Player has 0 coin.
    // So it should revert with E() or panic?
    // Actually Purgecoin.burnCoin checks balance.
    // But checking it doesn't revert with "RngLocked" is the goal.
    await expect(
        game.connect(player1).reverseFlip()
    ).to.not.be.revertedWithCustomError(game, "RngLocked");
  });

  // Helper to set storage
  async function setStorageAt(address, slot, value) {
      await ethers.provider.send("hardhat_setStorageAt", [
          address,
          ethers.toBeHex(slot),
          ethers.toBeHex(value, 32)
      ]);
  }
});
