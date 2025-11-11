const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  const iconData = require("./data/icons32Data.json");

  const IconsFactory = await hre.ethers.getContractFactory("Icons32Data");
  const icons = await IconsFactory.deploy(
    iconData.paths,
    iconData.vbW,
    iconData.vbH,
    iconData.diamond,
    iconData.symQ1,
    iconData.symQ2,
    iconData.symQ3
  );
  await icons.waitForDeployment();

  const RegistryFactory = await hre.ethers.getContractFactory(
    "contracts/mocks/TrophyRendererMocks.sol:MockRegistry"
  );
  const registry = await RegistryFactory.deploy();
  await registry.waitForDeployment();

  const NFTFactory = await hre.ethers.getContractFactory(
    "contracts/mocks/TrophyRendererMocks.sol:MockNFT"
  );
  const nft = await NFTFactory.deploy();
  await nft.waitForDeployment();

  const CoinFactory = await hre.ethers.getContractFactory(
    "contracts/mocks/TrophyRendererMocks.sol:MockCoin"
  );
  const coin = await CoinFactory.deploy();
  await coin.waitForDeployment();

  const AssetsFactory = await hre.ethers.getContractFactory("TrophySvgAssets");
  const assets = await AssetsFactory.deploy();
  await assets.waitForDeployment();

  const TrophyFactory = await hre.ethers.getContractFactory("IconRendererTrophy32");
  const trophyRenderer = await TrophyFactory.deploy(
    await coin.getAddress(),
    await icons.getAddress(),
    await registry.getAddress(),
    await assets.getAddress()
  );
  await trophyRenderer.waitForDeployment();

  const gameAddr = deployer.address;
  await coin.callWire(
    await trophyRenderer.getAddress(),
    gameAddr,
    await nft.getAddress()
  );

  const tokenId = 1n;
  await nft.setOwner(tokenId, deployer.address);

  await registry.setTopAffiliateColor(deployer.address, tokenId, "#1e90ff");

  const level = 25n;
  const data = (0xfffen << 152n) | (level << 128n) | (1n << 201n);

  const statusFlags = [3, 0, 0, 0]; // bit0 = staked, bit1 = ETH attachment
  const uri = await trophyRenderer.tokenURI(tokenId, data, statusFlags);
  const json = Buffer.from(uri.split(",")[1], "base64").toString();
  const metadata = JSON.parse(json);
  const svg = Buffer.from(metadata.image.split(",")[1], "base64").toString();

  const outPath = path.join(__dirname, "..", "artifacts", "tmp", "affiliate-trophy.svg");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, svg);

  console.log("Metadata:\n", metadata);
  console.log("\nSVG written to:", outPath);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
