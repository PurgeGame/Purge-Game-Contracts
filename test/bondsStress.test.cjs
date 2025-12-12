const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("DegenerusBonds Stress Tests", function () {
  let admin, game, steth, bonds, vrfCoord;
  let gameSigner;

  beforeEach(async function () {
    [admin] = await ethers.getSigners();

    const MockGame = await ethers.getContractFactory("MockGameBondBank");
    game = await MockGame.deploy();
    await game.waitForDeployment();

    const MockStETH = await ethers.getContractFactory("MockStETH");
    steth = await MockStETH.deploy();
    await steth.waitForDeployment();

    const MockVault = await ethers.getContractFactory("MockVault");
    const vault = await MockVault.deploy(await steth.getAddress());
    await vault.waitForDeployment();
    
    const MockVRF = await ethers.getContractFactory("MockVRFCoordinator");
    vrfCoord = await MockVRF.deploy();
    await vrfCoord.waitForDeployment();

    const Bonds = await ethers.getContractFactory("DegenerusBonds");
    bonds = await Bonds.deploy(await admin.getAddress(), await steth.getAddress());
    await bonds.waitForDeployment();

    const vrfAddr = await vrfCoord.getAddress();

    // Wire game and VRF
    await bonds.wire(
      [await game.getAddress(), await vault.getAddress(), ethers.ZeroAddress, vrfAddr],
      1,
      ethers.hexlify(ethers.randomBytes(32))
    );
    
    // Impersonate game for privileged calls
    gameSigner = await ethers.getImpersonatedSigner(await game.getAddress());
    await admin.sendTransaction({ to: await game.getAddress(), value: ethers.parseEther("200") });
    
    // Default available is 0, so no resolution happens by default.
  });

  it("Multiple Jackpots: Handles 2 simultaneous jackpots", async function () {
      await game.setAvailable(ethers.parseEther("1000000"));

      await game.setLevel(10);
      await bonds.connect(gameSigner).bondMaintenance(1, 0);
      await bonds.depositCurrentFor(admin.address, { value: ethers.parseEther("1") });

      await game.setLevel(15);
      await bonds.connect(gameSigner).bondMaintenance(2, 0);
      await bonds.depositCurrentFor(admin.address, { value: ethers.parseEther("1") });
      
      await game.setLevel(16);
      
      for(let i=0; i<50; i++) {
          await bonds.connect(gameSigner).depositFromGame(admin.address, 1n, { value: 1n });
      }
      
      const tx = await bonds.connect(gameSigner).bondMaintenance(12345, 0);
      const receipt = await tx.wait();
      
      console.log("Gas used for jackpots:", receipt.gasUsed.toString());
      expect(receipt.gasUsed).to.be.lt(15_000_000n);
  });

  it("GameOver Stress: 20 Active Series", async function () {
    await game.setAvailable(0);

    // Helper to get token contracts
    // We need to trigger at least one creation to get addresses?
    // Or just rely on burns.
    
    for (let i = 1; i <= 20; i++) {
        let lvl = i * 5;
        await game.setLevel(lvl);
        
        // Pass entropy to run jackpots
        await bonds.connect(gameSigner).bondMaintenance(12345 + i, 0);
        
        await bonds.depositCurrentFor(admin.address, { value: ethers.parseEther("0.1") });
        
        // Try to burn tokens if we have any.
        // Series created at `i*5`. Maturity `i*5 + 10` (15, 20, ...).
        
        let createdMat = lvl + 10;
        let tokenAddr = await bonds.seriesToken(createdMat);
        
        if (tokenAddr !== ethers.ZeroAddress) {
            const Token = await ethers.getContractAt("BondToken", tokenAddr);
            const bal = await Token.balanceOf(admin.address);
            if (bal > 0n) {
                // Determine if it's DGNS0 or DGNS5 by maturity digit.
                
                const isFive = createdMat % 10 === 5;
                await bonds.burnDGNS(isFive, bal);
            }
        }
    }
    
    // Now we should have burns registered in lanes.
    
    await bonds.connect(gameSigner).notifyGameOver();
    await bonds.connect(gameSigner).payBonds(0, 0, 0, { value: ethers.parseEther("100") });
    
    await bonds.connect(gameSigner).gameOver();
    
    const reqId = 1;
    const vrfAddr = await vrfCoord.getAddress();
    const vrfSigner = await ethers.getImpersonatedSigner(vrfAddr);
    await admin.sendTransaction({ to: vrfAddr, value: ethers.parseEther("1") });
    await bonds.connect(vrfSigner).fulfillRandomWords(reqId, [999999]);
    
    const gas = await bonds.connect(gameSigner).gameOver.estimateGas();
    console.log("GameOver Gas for 20 series:", gas.toString());
    
    expect(gas).to.be.lt(30_000_000n);
  });
});
