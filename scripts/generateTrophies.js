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
const ETH_ATTACHMENT_MASK = (1n << 128n) - 1n;

const LEVEL_PRIMARY = 25n;
const LEVEL_DOUBLE = 90n;
const OUTPUT_ROOT = path.join(__dirname, "..", "artifacts", "tmp", "trophies");
const OUTPUT_REGULAR_ROOT = path.join(OUTPUT_ROOT, "regular");
const OUTPUT_BADGE_ROOT = path.join(OUTPUT_ROOT, "badges");
const OUTPUT_SYMBOL_ROOT = path.join(OUTPUT_ROOT, "symbols");
const WEI_PER_ETH = 1_000_000_000_000_000_000n;
const SAMPLE_TRAIT_WIN_POOL_WEI = 100n * WEI_PER_ETH; // mirrors a 100 ETH pool for showcase purposes
const SAMPLE_AFFILIATE_ATTACHMENT = SAMPLE_TRAIT_WIN_POOL_WEI / 100n; // affiliate gets 1% of the pool on-chain

const STATUS_STAKED = 1;
const STATUS_ETH = 2;
const STATUS_DOUBLE = 4;
const STATUS_DEFAULT = 0;
const STATUS_DOUBLE_WIN = STATUS_DOUBLE;

const symbolLabels = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"];
const colorLabels = ["pink", "purple", "green", "red", "blue", "orange", "silver", "gold"];
const BASE_COLORS = ["#f409cd", "#7c2bff", "#30d100", "#ed0e11", "#1317f7", "#f7931a", "#5e5e5e", "#ab8d3f"];
const RATIO_MID = 0.78;
const RATIO_IN = 0.62;

function encodeTraitValue(trait) {
  return BigInt(trait) << 152n;
}

function encodeSymbolTrait(quadrant, colorIdx, symbolIdx) {
  const packed = (quadrant << 6) | (colorIdx << 3) | symbolIdx;
  return BigInt(packed);
}

function encodeData(flags, trait, level = LEVEL_PRIMARY, ethAttachment = 0n) {
  return encodeTraitValue(trait) | (level << 128n) | flags | (ethAttachment & ETH_ATTACHMENT_MASK);
}

function slug(...parts) {
  return parts
    .filter(Boolean)
    .map((p) => p.toLowerCase().replace(/[^a-z0-9\-]+/g, "-").replace(/^-+|-+$/g, ""))
    .join("/");
}

function packTraits(traits) {
  return traits.reduce((acc, value, idx) => acc | (BigInt(value) << BigInt(idx * 8)), 0n);
}

function decodeTokenUriData(uri) {
  const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
  const svg = Buffer.from(json.image.split(",")[1], "base64").toString();
  return { json, svg };
}

function writeArtifact(baseDir, name, json, svg) {
  const svgPath = path.join(baseDir, `${name}.svg`);
  const jsonPath = path.join(baseDir, `${name}.json`);
  fs.mkdirSync(path.dirname(svgPath), { recursive: true });
  fs.writeFileSync(svgPath, svg);
  fs.writeFileSync(jsonPath, JSON.stringify(json, null, 2));
  const rel = path.relative(OUTPUT_ROOT, svgPath) || path.basename(svgPath);
  console.log(`• wrote ${rel}`);
}

function writeBadgeSvg(name, svg) {
  const svgPath = path.join(OUTPUT_BADGE_ROOT, `${name}.svg`);
  fs.mkdirSync(path.dirname(svgPath), { recursive: true });
  fs.writeFileSync(svgPath, svg);
  const rel = path.relative(OUTPUT_ROOT, svgPath) || path.basename(svgPath);
  console.log(`• wrote ${rel}`);
}

function writeSymbolSvg(name, svg) {
  const svgPath = path.join(OUTPUT_SYMBOL_ROOT, `${name}.svg`);
  fs.mkdirSync(path.dirname(svgPath), { recursive: true });
  fs.writeFileSync(svgPath, svg);
  const rel = path.relative(OUTPUT_ROOT, svgPath) || path.basename(svgPath);
  console.log(`• wrote ${rel}`);
}

function buildBadgeSvg(quadrant, colorIdx, symbolIdx, iconData) {
  const outerColor = BASE_COLORS[colorIdx] || "#888888";
  const midColor = "#111111";
  const innerColor = "#ffffff";
  const CENTER = 256;
  const OUTER_RADIUS = CENTER;
  const MID_RADIUS = Math.round(OUTER_RADIUS * RATIO_MID);
  const INNER_RADIUS = Math.round(OUTER_RADIUS * RATIO_IN);
  const iconIndex = quadrant * 8 + symbolIdx;
  const pathMarkup = iconData.paths[iconIndex] || "";
  const vbW = iconData.vbW[iconIndex] || 1;
  const vbH = iconData.vbH[iconIndex] || 1;
  const innerDiameter = INNER_RADIUS * 2;
  const scale = (innerDiameter * 0.7) / Math.max(vbW, vbH);
  const tx = CENTER - (vbW * scale) / 2;
  const ty = CENTER - (vbH * scale) / 2;
  const transform = `matrix(${scale} 0 0 ${scale} ${tx} ${ty})`;
  const requiresSolidFill = quadrant === 0 && (symbolIdx === 1 || symbolIdx === 5);
  const strokeColor = requiresSolidFill ? "none" : outerColor;
  const symbolGroup = `<g fill="${outerColor}" stroke="${strokeColor}" style="vector-effect:non-scaling-stroke">${pathMarkup}</g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${CENTER * 2} ${CENTER * 2}">
<circle cx="${CENTER}" cy="${CENTER}" r="${OUTER_RADIUS}" fill="${outerColor}"/>
<circle cx="${CENTER}" cy="${CENTER}" r="${MID_RADIUS}" fill="${midColor}"/>
<circle cx="${CENTER}" cy="${CENTER}" r="${INNER_RADIUS}" fill="${innerColor}"/>
<g transform="${transform}">${symbolGroup}</g>
</svg>`;
}

function buildSymbolSvg(iconIndex, iconData) {
  const vbW = iconData.vbW[iconIndex] || 512;
  const vbH = iconData.vbH[iconIndex] || 512;
  const body = iconData.paths[iconIndex] || "";
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${vbW} ${vbH}">${body}</svg>`;
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
  const RegularFactory = await hre.ethers.getContractFactory("IconRendererRegular32");
  const regularRenderer = await RegularFactory.deploy(
    await coin.getAddress(),
    await icons.getAddress(),
    await registry.getAddress()
  );
  await regularRenderer.waitForDeployment();
  await coin.callWire(await regularRenderer.getAddress(), deployer.address, await nft.getAddress());

  fs.rmSync(OUTPUT_ROOT, { recursive: true, force: true });
  fs.mkdirSync(OUTPUT_ROOT, { recursive: true });
  fs.mkdirSync(OUTPUT_REGULAR_ROOT, { recursive: true });
  fs.mkdirSync(OUTPUT_BADGE_ROOT, { recursive: true });
  fs.mkdirSync(OUTPUT_SYMBOL_ROOT, { recursive: true });

  let nextTokenId = 1n;

  async function renderVariant(name, data, statusFlags = STATUS_DEFAULT, root = OUTPUT_ROOT) {
    const tokenId = nextTokenId++;
    await nft.setOwner(tokenId, deployer.address);

    const combinedStatus = statusFlags | STATUS_STAKED | STATUS_ETH;
    const uri = await renderer.tokenURI(tokenId, data, [combinedStatus, 0, 0, 0]);
    const { json, svg } = decodeTokenUriData(uri);
    writeArtifact(root, name, json, svg);
  }

  async function renderRegularToken(name, { level, lastEx, traits, remaining }) {
    const tokenId = nextTokenId++;
    await nft.setOwner(tokenId, deployer.address);
    await registry.setCustomColorsForMany(
      deployer.address,
      [tokenId],
      "",
      "",
      "",
      "",
      750000
    );

    const packedTraits = packTraits(traits);
    const data = (BigInt(lastEx) << 56n) | (BigInt(level) << 32n) | packedTraits;
    const rem = remaining.map((value) => BigInt(value));
    const uri = await regularRenderer.tokenURI(tokenId, data, rem);
    const { json, svg } = decodeTokenUriData(uri);
    writeArtifact(OUTPUT_REGULAR_ROOT, name, json, svg);
  }

  const staticVariants = [
    { slug: slug("map", "standard"), flags: MAP_FLAG, trait: RESERVED_SENTINEL, level: LEVEL_PRIMARY },
    {
      slug: slug("affiliate", "top"),
      flags: AFFILIATE_FLAG,
      trait: TOP_AFFILIATE_SENTINEL,
      level: LEVEL_PRIMARY,
      attachment: SAMPLE_AFFILIATE_ATTACHMENT,
    },
    { slug: slug("stake", "largest"), flags: STAKE_FLAG, trait: STAKE_SENTINEL, level: LEVEL_PRIMARY },
    { slug: slug("baf", "finale"), flags: BAF_FLAG, trait: BAF_SENTINEL, level: LEVEL_PRIMARY },
    { slug: slug("decimator", "finale"), flags: DEC_FLAG, trait: DEC_SENTINEL, level: LEVEL_PRIMARY },
  ];

  for (const variant of staticVariants) {
    const data = encodeData(variant.flags, variant.trait, variant.level, variant.attachment ?? 0n);
    await renderVariant(variant.slug, data);
  }

  for (let quadrant = 0; quadrant < 4; quadrant++) {
    for (let symbol = 0; symbol < 8; symbol++) {
      const color = symbol % 8;
      const trait = encodeSymbolTrait(quadrant, color, symbol);
      const colorName = colorLabels[color] || `color-${color}`;
      const symbolName = symbolLabels[symbol] || `symbol-${symbol}`;
      const baseLabel = slug(
        "exterminator",
        `quadrant-${quadrant + 1}`,
        colorName,
        symbolName
      );
      await renderVariant(baseLabel, encodeData(0n, trait, LEVEL_PRIMARY));
      await renderVariant(`${baseLabel}/double`, encodeData(0n, trait, LEVEL_DOUBLE), STATUS_DOUBLE_WIN);
    }
  }

  const regularSamples = [
    {
      slug: slug("prime-blend"),
      level: 27,
      lastEx: 420,
      traits: [
        encodeSymbolTrait(0, 0, 0),
        encodeSymbolTrait(1, 3, 2),
        encodeSymbolTrait(2, 4, 5),
        encodeSymbolTrait(3, 6, 1),
      ],
      remaining: [1200, 845, 432, 210],
    },
    {
      slug: slug("elite-wave"),
      level: 52,
      lastEx: 18,
      traits: [
        encodeSymbolTrait(0, 2, 7),
        encodeSymbolTrait(1, 5, 1),
        encodeSymbolTrait(2, 6, 3),
        encodeSymbolTrait(3, 1, 4),
      ],
      remaining: [620, 590, 420, 280],
    },
    {
      slug: slug("inverted-level-90"),
      level: 90,
      lastEx: 0,
      traits: [
        encodeSymbolTrait(0, 7, 0),
        encodeSymbolTrait(1, 6, 3),
        encodeSymbolTrait(2, 5, 6),
        encodeSymbolTrait(3, 4, 1),
      ],
      remaining: [250, 250, 250, 250],
    },
    {
      slug: slug("referral-special"),
      level: 12,
      lastEx: 255,
      traits: [
        encodeSymbolTrait(0, 1, 5),
        encodeSymbolTrait(1, 7, 7),
        encodeSymbolTrait(2, 0, 2),
        encodeSymbolTrait(3, 3, 6),
      ],
      remaining: [1888, 1776, 1664, 1552],
    },
  ];

  for (const sample of regularSamples) {
    await renderRegularToken(sample.slug, sample);
  }

  for (let quadrant = 0; quadrant < 4; quadrant++) {
    for (let colorIdx = 0; colorIdx < 8; colorIdx++) {
      for (let symbol = 0; symbol < 8; symbol++) {
        const baseLabel = slug(
          `quadrant-${quadrant + 1}`,
          colorLabels[colorIdx] || `color-${colorIdx}`,
          symbolLabels[symbol] || `symbol-${symbol}`
        );
        const svg = buildBadgeSvg(quadrant, colorIdx, symbol, iconData);
        writeBadgeSvg(baseLabel, svg);
      }
    }
  }

  for (let quadrant = 0; quadrant < 4; quadrant++) {
    for (let symbol = 0; symbol < 8; symbol++) {
      const iconIndex = quadrant * 8 + symbol;
      const svg = buildSymbolSvg(iconIndex, iconData);
      const name = slug(`quadrant-${quadrant + 1}`, symbolLabels[symbol] || `symbol-${symbol}`);
      writeSymbolSvg(name, svg);
    }
  }

  console.log(`Finished writing trophies to ${OUTPUT_ROOT}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
