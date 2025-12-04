const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("PurgeBongs gas", function () {
    it("resolves 100 bongs within 14m gas in advanceGame slice", async function () {
        const [deployer, game] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const mockStEth = await MockERC20.deploy();
        const stEthAddress = await mockStEth.getAddress();
        const MockCoin = await ethers.getContractFactory("MockCoin");
        const mockCoin = await MockCoin.deploy();
        const coinAddress = await mockCoin.getAddress();

        const PurgeBongs = await ethers.getContractFactory("PurgeBongs");
        const bongs = await PurgeBongs.deploy(stEthAddress);
        const bongsAddress = await bongs.getAddress();

        // Wire coin and game
        await bongs.wire([coinAddress, game.address]);

        // Mint 100 bongs via 10 batches (baseWei capped at 1 ETH per batch, 10 bongs each)
        const batchQty = 10;
        const batches = 10;
        const baseWeiTotal = ethers.parseEther("1"); // total principal per batch
        const basePerBong = baseWeiTotal / BigInt(batchQty);
        const MULT_SCALE = 10n ** 18n;
        for (let i = 0; i < batches; i++) {
            const priceMult = await bongs.priceMultiplier();
            const pricePerBong = (basePerBong * priceMult) / MULT_SCALE;
            const totalPrice = pricePerBong * BigInt(batchQty);
            await bongs.buy(baseWeiTotal, batchQty, false, ethers.ZeroHash, { value: totalPrice });
        }

        // Resolve with capped batch size 100, rngWord provided, budget sized for delta (0.9 ETH per bong worst case)
        const tx = await bongs.connect(game).payBongs(0, 0, 0, 42, 100, { value: ethers.parseEther("90") });
        const receipt = await tx.wait();

        expect(Number(receipt.gasUsed)).to.be.lessThan(14_000_000);
        expect(await bongs.resolvePending()).to.equal(false);
    });
});
