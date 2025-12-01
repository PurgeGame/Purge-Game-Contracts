const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const OUTPUT_DIR = path.join(__dirname, "..", "artifacts", "tmp", "bond-renders");

function decodeDataUri(uri) {
  const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
  const svg = Buffer.from(json.image.split(",")[1], "base64").toString();
  return { json, svg };
}

function writeRender(name, json, svg) {
  const svgPath = path.join(OUTPUT_DIR, `${name}.svg`);
  const jsonPath = path.join(OUTPUT_DIR, `${name}.json`);
  fs.mkdirSync(path.dirname(svgPath), { recursive: true });
  fs.writeFileSync(svgPath, svg);
  fs.writeFileSync(jsonPath, JSON.stringify(json, null, 2));
  console.log(`• wrote ${path.relative(OUTPUT_DIR, svgPath)}`);
}

async function deployRenderer() {
  const iconData = require("./data/icons32Data.json");

  const IconsFactory = await hre.ethers.getContractFactory("Icons32Data");
  const icons = await IconsFactory.deploy(
    iconData.paths,
    iconData.diamond,
    iconData.symQ1,
    iconData.symQ2,
    iconData.symQ3
  );
  await icons.waitForDeployment();

  const NFTFactory = await hre.ethers.getContractFactory(
    "contracts/mocks/TrophyRendererMocks.sol:MockNFT"
  );
  const nft = await NFTFactory.deploy();
  await nft.waitForDeployment();

  const RegistryFactory = await hre.ethers.getContractFactory(
    "contracts/mocks/TrophyRendererMocks.sol:MockRegistry"
  );
  const registry = await RegistryFactory.deploy();
  await registry.waitForDeployment();

  const CoinFactory = await hre.ethers.getContractFactory(
    "contracts/mocks/TrophyRendererMocks.sol:MockCoin"
  );
  const coin = await CoinFactory.deploy();
  await coin.waitForDeployment();

  const AssetsFactory = await hre.ethers.getContractFactory("TrophySvgAssets");
  const assets = await AssetsFactory.deploy();
  await assets.waitForDeployment();

  const RendererFactory = await hre.ethers.getContractFactory("IconRendererTrophy32");
  const renderer = await RendererFactory.deploy(
    await coin.getAddress(),
    await icons.getAddress(),
    await registry.getAddress(),
    await assets.getAddress()
  );
  await renderer.waitForDeployment();

  const [deployer] = await hre.ethers.getSigners();
  await coin.callWire(await renderer.getAddress(), deployer.address, await nft.getAddress());

  return { renderer, nft, owner: deployer.address };
}

async function main() {
  const { renderer, nft, owner } = await deployRenderer();

  const samples = [
    {
      name: "bond-early-unstaked-0pct",
      tokenId: 1,
      created: 120,
      current: 120,
      chanceBps: 200,
      staked: false,
    },
    {
      name: "bond-quarter-staked",
      tokenId: 2,
      created: 120,
      current: 90,
      chanceBps: 800,
      staked: true,
    },
    {
      name: "bond-half-unstaked",
      tokenId: 3,
      created: 100,
      current: 50,
      chanceBps: 2000,
      staked: false,
    },
    {
      name: "bond-threequarter-staked",
      tokenId: 4,
      created: 80,
      current: 20,
      chanceBps: 3500,
      staked: true,
    },
    {
      name: "bond-near-unstaked-94pct",
      tokenId: 5,
      created: 90,
      current: 5,
      chanceBps: 4500,
      staked: false,
    },
  ];

  for (const sample of samples) {
    await nft.setOwner(sample.tokenId, owner);
    const uri = await renderer.bondTokenURI(
      sample.tokenId,
      sample.created,
      sample.current,
      sample.chanceBps,
      sample.staked
    );
    const { json, svg } = decodeDataUri(uri);
    writeRender(sample.name, json, svg);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
