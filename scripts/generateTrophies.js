const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const MAP_FLAG = 1n << 200n;
const AFFILIATE_FLAG = 1n << 201n;
const STAKE_FLAG = 1n << 202n;
const BAF_FLAG = 1n << 203n;
const DEC_FLAG = 1n << 204n;

const RESERVED_SENTINEL = 0xffffn;
const TOP_AFFILIATE_SENTINEL = 0xfffen;
const STAKE_SENTINEL = 0xfffdn;
const BAF_SENTINEL = 0xfffan;
const DEC_SENTINEL = 0xfffbn;

const LEVEL_PRIMARY = 25n;
const LEVEL_DOUBLE = 90n;
const OUTPUT_ROOT = path.join(__dirname, "..", "artifacts", "tmp", "trophies");

const STATUS_STAKED = 1;
const STATUS_ETH = 2;
const STATUS_DOUBLE = 4;
const STATUS_DEFAULT = 0;
const STATUS_DOUBLE_WIN = STATUS_DOUBLE;

const symbolLabels = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"];

function encodeTraitValue(trait) {
  return BigInt(trait) << 152n;
}

function encodeSymbolTrait(quadrant, colorIdx, symbolIdx) {
  const packed = (quadrant << 6) | (colorIdx << 3) | symbolIdx;
  return BigInt(packed);
}

function encodeData(flags, trait, level = LEVEL_PRIMARY) {
  return encodeTraitValue(trait) | (level << 128n) | flags;
}

function slug(...parts) {
  return parts
    .filter(Boolean)
    .map((p) => p.toLowerCase().replace(/[^a-z0-9\-]+/g, "-").replace(/^-+|-+$/g, ""))
    .join("/");
}

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
  const renderer = await TrophyFactory.deploy(
    await coin.getAddress(),
    await icons.getAddress(),
    await registry.getAddress(),
    await assets.getAddress()
  );
  await renderer.waitForDeployment();

  await coin.callWire(await renderer.getAddress(), deployer.address, await nft.getAddress());

  fs.rmSync(OUTPUT_ROOT, { recursive: true, force: true });
  fs.mkdirSync(OUTPUT_ROOT, { recursive: true });

  let nextTokenId = 1n;

  async function renderVariant(name, data, statusFlags = STATUS_DEFAULT) {
    const tokenId = nextTokenId++;
    await nft.setOwner(tokenId, deployer.address);

    const uri = await renderer.tokenURI(tokenId, data, [statusFlags, 0, 0, 0]);
    const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
    const svg = Buffer.from(json.image.split(",")[1], "base64").toString();

    const svgPath = path.join(OUTPUT_ROOT, `${name}.svg`);
    const jsonPath = path.join(OUTPUT_ROOT, `${name}.json`);
    fs.mkdirSync(path.dirname(svgPath), { recursive: true });
    fs.writeFileSync(svgPath, svg);
    fs.writeFileSync(jsonPath, JSON.stringify(json, null, 2));
    console.log(`• wrote ${name}`);
  }

  const staticVariants = [
    { slug: slug("map", "standard"), flags: MAP_FLAG, trait: RESERVED_SENTINEL, level: LEVEL_PRIMARY },
    { slug: slug("affiliate", "top"), flags: AFFILIATE_FLAG, trait: TOP_AFFILIATE_SENTINEL, level: LEVEL_PRIMARY },
    { slug: slug("stake", "largest"), flags: STAKE_FLAG, trait: STAKE_SENTINEL, level: LEVEL_PRIMARY },
    { slug: slug("baf", "finale"), flags: BAF_FLAG, trait: BAF_SENTINEL, level: LEVEL_PRIMARY },
    { slug: slug("decimator", "finale"), flags: DEC_FLAG, trait: DEC_SENTINEL, level: LEVEL_PRIMARY },
  ];

  for (const variant of staticVariants) {
    const data = encodeData(variant.flags, variant.trait, variant.level);
    await renderVariant(variant.slug, data);
  }

  for (let quadrant = 0; quadrant < 4; quadrant++) {
    for (let symbol = 0; symbol < 8; symbol++) {
      const color = symbol % 8;
      const trait = encodeSymbolTrait(quadrant, color, symbol);
      const baseLabel = slug(
        "exterminator",
        `quadrant-${quadrant + 1}`,
        symbolLabels[symbol] || `symbol-${symbol}`
      );
      await renderVariant(baseLabel, encodeData(0n, trait, LEVEL_PRIMARY));
      await renderVariant(`${baseLabel}/double`, encodeData(0n, trait, LEVEL_DOUBLE), STATUS_DOUBLE_WIN);
    }
  }

  console.log(`Finished writing trophies to ${OUTPUT_ROOT}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
