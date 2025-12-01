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
const OUTPUT_SPECIAL_BADGE_ROOT = path.join(OUTPUT_ROOT, "badges-special");
const OUTPUT_SPECIAL_SYMBOL_ROOT = path.join(OUTPUT_ROOT, "symbols-special");
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
const MAP_BADGE_PATH =
  "M14.3675 2.15671C14.7781 2.01987 15.2219 2.01987 15.6325 2.15671L20.6325 3.82338C21.4491 4.09561 22 4.85988 22 5.72074V19.6126C22 20.9777 20.6626 21.9416 19.3675 21.5099L15 20.0541L9.63246 21.8433C9.22192 21.9801 8.77808 21.9801 8.36754 21.8433L3.36754 20.1766C2.55086 19.9044 2 19.1401 2 18.2792V4.38741C2 3.0223 3.33739 2.05836 4.63246 2.49004L9 3.94589L14.3675 2.15671ZM15 4.05408L9.63246 5.84326C9.22192 5.9801 8.77808 5.9801 8.36754 5.84326L4 4.38741V18.2792L9 19.9459L14.3675 18.1567C14.7781 18.0199 15.2219 18.0199 15.6325 18.1567L20 19.6126V5.72074L15 4.05408ZM13.2929 8.29288C13.6834 7.90235 14.3166 7.90235 14.7071 8.29288L15.5 9.08577L16.2929 8.29288C16.6834 7.90235 17.3166 7.90235 17.7071 8.29288C18.0976 8.6834 18.0976 9.31657 17.7071 9.70709L16.9142 10.5L17.7071 11.2929C18.0976 11.6834 18.0976 12.3166 17.7071 12.7071C17.3166 13.0976 16.6834 13.0976 16.2929 12.7071L15.5 11.9142L14.7071 12.7071C14.3166 13.0976 13.6834 13.0976 13.2929 12.7071C12.9024 12.3166 12.9024 11.6834 13.2929 11.2929L14.0858 10.5L13.2929 9.70709C12.9024 9.31657 12.9024 8.6834 13.2929 8.29288ZM6 16C6.55228 16 7 15.5523 7 15C7 14.4477 6.55228 14 6 14C5.44772 14 5 14.4477 5 15C5 15.5523 5.44772 16 6 16ZM9 12C9 12.5523 8.55228 13 8 13C7.44772 13 7 12.5523 7 12C7 11.4477 7.44772 11 8 11C8.55228 11 9 11.4477 9 12ZM11 12C11.5523 12 12 11.5523 12 11C12 10.4477 11.5523 9.99998 11 9.99998C10.4477 9.99998 10 10.4477 10 11C10 11.5523 10.4477 12 11 12Z";
const AFFILIATE_BADGE_PATH =
  "M511.717 490.424l-85.333-136.533c-1.559-2.495-4.294-4.011-7.236-4.011H94.88c-2.942 0-5.677 1.516-7.236 4.011L2.311 490.424c-3.552 5.684 0.534 13.056 7.236 13.056H504.48c6.703 0 10.789-7.372 7.237-13.056zM24.943 486.414L99.61 366.947h314.807l74.667 119.467H24.943zM188.747 179.214c-2.942 0-5.677 1.516-7.236 4.011L96.177 319.758c-3.552 5.684 0.534 13.056 7.236 13.056h307.2c6.702 0 10.789-7.372 7.236-13.056l-45.173-72.277h73.146c3.789 14.723 17.152 25.6 33.058 25.6 18.853 0 34.133-15.281 34.133-34.133s-15.281-34.133-34.133-34.133c-15.906 0-29.269 10.877-33.058 25.6H362.01l-29.493-47.189c-1.559-2.495-4.294-4.011-7.236-4.011H188.747zM478.88 221.88c9.427 0 17.067 7.64 17.067 17.067 0 9.427-7.64 17.067-17.067 17.067s-17.067-7.64-17.067-17.067c0-9.427 7.64-17.067 17.067-17.067zM395.217 315.747H118.81l74.667-119.467h127.074l74.666 119.467zM94.88 145.08c15.906 0 29.269-10.877 33.058-25.6h74.961l-13.437 30.713c-2.467 5.638 1.664 11.954 7.818 11.954h119.467c6.154 0 10.284-6.316 7.818-11.954L264.832 13.66c-2.983-6.817-12.653-6.817-15.636 0l-38.83 88.754H127.938c-3.789-14.723-17.152-25.6-33.058-25.6-18.853 0-34.133 15.281-34.133 34.133 0 18.852 15.281 34.133 34.133 34.133zM257.014 38.37l46.686 106.71h-93.371l46.685-106.71zM94.88 93.88c9.427 0 17.067 7.64 17.067 17.067 0 9.427-7.64 17.067-17.067 17.067-9.427 0-17.067-7.64-17.067-17.067 0-9.427 7.64-17.067 17.067-17.067z";
const BASE_COLORS = ["#f409cd", "#7c2bff", "#30d100", "#ed0e11", "#1317f7", "#f7931a", "#5e5e5e", "#ab8d3f"];
const RATIO_MID = 0.78;
const RATIO_IN = 0.62;
const TROPHY_BADGE_SCALE = 750000;

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

function isCryptoShrinkTarget(symbolIdx) {
  return symbolIdx === 0 || symbolIdx === 1 || symbolIdx === 4;
}

function isZodiacShrinkTarget(symbolIdx) {
  return symbolIdx >= 1 && symbolIdx <= 7;
}

function isGamblingShrinkTarget(symbolIdx) {
  return symbolIdx === 0 || symbolIdx === 6;
}

function symbolFitScale(quadrant, symbolIdx) {
  // Mirrors IconRendererTrophy32._symbolFitScale (excluding affiliate/decimator cases).
  let fit;
  if (quadrant === 0 && (symbolIdx === 3 || symbolIdx === 7)) {
    fit = 1.03;
  } else if (quadrant === 1 && symbolIdx === 6) {
    fit = 0.6;
  } else {
    fit = 0.8;
  }

  if (quadrant === 1 && isZodiacShrinkTarget(symbolIdx)) {
    fit *= 0.9;
  } else if (quadrant === 0 && isCryptoShrinkTarget(symbolIdx)) {
    fit *= 0.85;
  } else if (quadrant === 2) {
    if (isGamblingShrinkTarget(symbolIdx)) {
      fit *= 0.9;
    } else if (symbolIdx === 1) {
      fit *= 1.15;
    }
  } else if (quadrant === 3) {
    if (symbolIdx !== 6 && symbolIdx !== 7) {
      fit *= 0.9;
    }
  }

  return fit;
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

function writeSpecialBadgeSvg(name, svg) {
  const svgPath = path.join(OUTPUT_SPECIAL_BADGE_ROOT, `${name}.svg`);
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

function writeSpecialSymbolSvg(name, svg) {
  const svgPath = path.join(OUTPUT_SPECIAL_SYMBOL_ROOT, `${name}.svg`);
  fs.mkdirSync(path.dirname(svgPath), { recursive: true });
  fs.writeFileSync(svgPath, svg);
  const rel = path.relative(OUTPUT_ROOT, svgPath) || path.basename(svgPath);
  console.log(`• wrote ${rel}`);
}

function buildBadgeSvg(quadrant, colorIdx, symbolIdx, iconData) {
  const outerColor = BASE_COLORS[colorIdx] || "#888888";
  const midColor = "#111111";
  const innerColor = "#ffffff";
  const ICON_VB = 512;
  const CENTER = 256;
  const OUTER_RADIUS = CENTER;
  const MID_RADIUS = Math.round(OUTER_RADIUS * RATIO_MID);
  const INNER_RADIUS = Math.round(OUTER_RADIUS * RATIO_IN);
  const iconIndex = quadrant * 8 + symbolIdx;
  const pathMarkup = iconData.paths[iconIndex] || "";
  const vbW = ICON_VB;
  const vbH = ICON_VB;
  const symbolScale = symbolFitScale(quadrant, symbolIdx);
  const maxDim = Math.max(vbW, vbH) || 1;
  const scale = (2 * INNER_RADIUS * symbolScale) / maxDim;
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
  const vbW = 512;
  const vbH = 512;
  const body = iconData.paths[iconIndex] || "";
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${vbW} ${vbH}">${body}</svg>`;
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
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
  fs.mkdirSync(OUTPUT_SPECIAL_BADGE_ROOT, { recursive: true });
  fs.mkdirSync(OUTPUT_SPECIAL_SYMBOL_ROOT, { recursive: true });

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
      [tokenId.toString()],
      "",
      "",
      "",
      "",
      TROPHY_BADGE_SCALE
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

  const symbolTables = [iconData.symQ1 || [], iconData.symQ2 || [], iconData.symQ3 || [], iconData.symQ4 || []];

  const resolveSymbolName = (quadrant, symbolIdx) => {
    const table = symbolTables[quadrant];
    if (table && table[symbolIdx]) {
      return table[symbolIdx];
    }
    return symbolLabels[symbolIdx] || `symbol-${symbolIdx}`;
  };

  const formatBaseName = (quadrant, color, symbolIdx) => {
    const colorName = colorLabels[color] || `color-${color}`;
    const symbolRaw = resolveSymbolName(quadrant, symbolIdx);
    return slug(`quadrant-${quadrant + 1}-${colorName}-${symbolRaw}`);
  };

  for (let quadrant = 0; quadrant < 4; quadrant++) {
    for (let color = 0; color < 8; color++) {
      for (let symbol = 0; symbol < 8; symbol++) {
        const trait = encodeSymbolTrait(quadrant, color, symbol);
        const baseName = formatBaseName(quadrant, color, symbol);
        const primarySlug = slug("exterminator", baseName);
        const doubleSlug = slug("exterminator", `${baseName}-double`);
        await renderVariant(primarySlug, encodeData(0n, trait, LEVEL_PRIMARY));
        await renderVariant(doubleSlug, encodeData(0n, trait, LEVEL_DOUBLE), STATUS_DOUBLE_WIN);
      }
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
    {
      slug: slug("early-rush"),
      level: 5,
      lastEx: 12,
      traits: [
        encodeSymbolTrait(0, 4, 3),
        encodeSymbolTrait(1, 0, 1),
        encodeSymbolTrait(2, 7, 4),
        encodeSymbolTrait(3, 2, 5),
      ],
      remaining: [2200, 2140, 2070, 1990],
    },
    {
      slug: slug("lunar-spark"),
      level: 38,
      lastEx: 99,
      traits: [
        encodeSymbolTrait(0, 6, 5),
        encodeSymbolTrait(1, 4, 2),
        encodeSymbolTrait(2, 1, 7),
        encodeSymbolTrait(3, 5, 0),
      ],
      remaining: [880, 760, 540, 320],
    },
    {
      slug: slug("vegas-night"),
      level: 63,
      lastEx: 177,
      traits: [
        encodeSymbolTrait(0, 5, 6),
        encodeSymbolTrait(1, 2, 3),
        encodeSymbolTrait(2, 6, 1),
        encodeSymbolTrait(3, 0, 7),
      ],
      remaining: [540, 450, 430, 410],
    },
    {
      slug: slug("ember-strike"),
      level: 71,
      lastEx: 188,
      traits: [
        encodeSymbolTrait(0, 3, 4),
        encodeSymbolTrait(1, 6, 6),
        encodeSymbolTrait(2, 5, 2),
        encodeSymbolTrait(3, 7, 3),
      ],
      remaining: [400, 360, 330, 290],
    },
    {
      slug: slug("zenith-drive"),
      level: 84,
      lastEx: 200,
      traits: [
        encodeSymbolTrait(0, 2, 2),
        encodeSymbolTrait(1, 5, 0),
        encodeSymbolTrait(2, 3, 3),
        encodeSymbolTrait(3, 4, 4),
      ],
      remaining: [310, 305, 300, 295],
    },
  ];

  for (const sample of regularSamples) {
    await renderRegularToken(sample.slug, sample);
  }

  for (let quadrant = 0; quadrant < 4; quadrant++) {
    for (let colorIdx = 0; colorIdx < 8; colorIdx++) {
      for (let symbol = 0; symbol < 8; symbol++) {
        const baseName = formatBaseName(quadrant, colorIdx, symbol);
        const svg = buildBadgeSvg(quadrant, colorIdx, symbol, iconData);
        writeBadgeSvg(baseName, svg);
      }
    }
  }

  for (let quadrant = 0; quadrant < 4; quadrant++) {
    for (let symbol = 0; symbol < 8; symbol++) {
      const iconIndex = quadrant * 8 + symbol;
      const svg = buildSymbolSvg(iconIndex, iconData);
      const name = slug(`quadrant-${quadrant + 1}-${resolveSymbolName(quadrant, symbol)}`);
      writeSymbolSvg(name, svg);
    }
  }

  const specialBadges = [
    {
      slug: "map",
      svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="#30d100" d="${MAP_BADGE_PATH}"/></svg>`,
    },
    {
      slug: "affiliate",
      svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><path fill="#f409cd" d="${AFFILIATE_BADGE_PATH}"/></svg>`,
    },
  ];
  const stakePath = await assets.stakeBadgePath();
  specialBadges.push({
    slug: "stake",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640"><path fill="#4d2b1f" d="${stakePath}"/></svg>`,
  });
  const decPath = await assets.decimatorSymbol();
  specialBadges.push({
    slug: "decimator",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 1300">${decPath}</svg>`,
  });
  const bafPath = await assets.bafFlipSymbol();
  specialBadges.push({
    slug: "baf",
    svg: `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 130 130">${bafPath}</svg>`,
  });

  for (const badge of specialBadges) {
    writeSpecialBadgeSvg(badge.slug, badge.svg);
    writeSpecialSymbolSvg(badge.slug, badge.svg);
  }

  console.log(`Finished writing trophies to ${OUTPUT_ROOT}`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
