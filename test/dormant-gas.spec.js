const { expect } = require("chai");
const { ethers, network } = require("hardhat");

async function setStorageAt(address, slot, value) {
    await network.provider.send("hardhat_setStorageAt", [address, slot, value]);
}

describe("PurgeGameNFT dormant gas", function () {
    this.timeout(0);

    it("estimates gas usage for processing dormant tokens", async function () {
        const [deployer] = await ethers.getSigners();

        const Renderer = await ethers.getContractFactory("contracts/test/MockNFTDeps.sol:MockRenderer");
        const Coin = await ethers.getContractFactory("contracts/test/MockNFTDeps.sol:MockCoin");
        const Game = await ethers.getContractFactory("contracts/test/MockNFTDeps.sol:MockGame");
        const Trophies = await ethers.getContractFactory("contracts/test/MockNFTDeps.sol:MockTrophies");
        const NFT = await ethers.getContractFactory("PurgeGameNFT");

        const renderer = await Renderer.deploy();
        await renderer.waitForDeployment();

        const coin = await Coin.deploy();
        await coin.waitForDeployment();

        const game = await Game.deploy();
        await game.waitForDeployment();

        const trophies = await Trophies.deploy();
        await trophies.waitForDeployment();

        const rendererAddress = await renderer.getAddress();
        const coinAddress = await coin.getAddress();
        const gameAddress = await game.getAddress();
        const trophiesAddress = await trophies.getAddress();

        const nft = await NFT.deploy(rendererAddress, rendererAddress, coinAddress);
        await nft.waitForDeployment();
        const nftAddress = await nft.getAddress();

        await coin.wireAll(nftAddress, gameAddress, trophiesAddress);

        const mintedTotal = 3220; // leave 3000 tokens after initial 220 batch
        const owner = deployer.address;

        const currentIndexSlot = ethers.zeroPadValue(ethers.toBeHex(0), 32);
        await setStorageAt(
            nftAddress,
            currentIndexSlot,
            ethers.zeroPadValue(ethers.toBeHex(mintedTotal), 32)
        );

        const ownershipMappingSlot = 3;
        const ownerValue = BigInt(owner);
        const nextInitialized = 1n << 225n;
        const packedValue = ownerValue | nextInitialized;
        const packedHex = ethers.zeroPadValue(ethers.toBeHex(packedValue), 32);
        const abiCoder = ethers.AbiCoder.defaultAbiCoder();

        for (let tokenId = 0; tokenId < mintedTotal; tokenId++) {
            const slot = ethers.keccak256(abiCoder.encode(["uint256", "uint256"], [tokenId, ownershipMappingSlot]));
            await setStorageAt(nftAddress, slot, packedHex);
        }

        await game.finalizePurchase(nftAddress, mintedTotal);

        const remaining = mintedTotal - 220;
        const tx = await nft.processDormant(mintedTotal);
        const receipt = await tx.wait();

        const gasUsed = receipt.gasUsed;
        const gasPerToken = gasUsed / BigInt(remaining);

        console.log(
            `Dormant sweep gas: total=${gasUsed.toString()} for ${remaining} tokens (~${gasPerToken.toString()} gas/token)`
        );
    });
});
