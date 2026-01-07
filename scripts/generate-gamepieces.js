import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import hre from "hardhat";

function parseEnvInt(name, fallback) {
  const raw = process.env[name];
  if (!raw) return fallback;
  const val = Number.parseInt(raw, 10);
  return Number.isFinite(val) ? val : fallback;
}

const COUNT = parseEnvInt("COUNT", 50);
const STARTING_COUNT = parseEnvInt("STARTING_COUNT", 10);
const START_REMAINING = parseEnvInt("START_REMAINING", 1000);
const LEVEL = parseEnvInt("LEVEL", 1);
const LAST_EX = parseEnvInt("LAST_EX", 420);
const REMAINING_MIN = parseEnvInt("REMAINING_MIN", 1);
const REMAINING_MAX = parseEnvInt("REMAINING_MAX", START_REMAINING);
const TOKEN_ID_MAX = 1_000_000;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const MASK_64 = (1n << 64n) - 1n;
const IMAGE_PREFIX = "data:image/svg+xml;base64,";
const JSON_PREFIX = "data:application/json;base64,";

function weightedBucket(rnd32) {
  const scaled = Number((BigInt(rnd32) * 75n) >> 32n);
  if (scaled < 10) return 0;
  if (scaled < 20) return 1;
  if (scaled < 30) return 2;
  if (scaled < 40) return 3;
  if (scaled < 49) return 4;
  if (scaled < 58) return 5;
  if (scaled < 67) return 6;
  return 7;
}

function traitFromWord(word64) {
  const category = weightedBucket(Number(word64 & 0xffffffffn));
  const sub = weightedBucket(Number((word64 >> 32n) & 0xffffffffn));
  return (category << 3) | sub;
}

function packedTraitsForToken(tokenId) {
  const hash = hre.ethers.solidityPackedKeccak256(["uint256"], [tokenId]);
  const rand = BigInt(hash);
  const traitA = traitFromWord(rand & MASK_64);
  const traitB = traitFromWord((rand >> 64n) & MASK_64) | 64;
  const traitC = traitFromWord((rand >> 128n) & MASK_64) | 128;
  const traitD = traitFromWord((rand >> 192n) & MASK_64) | 192;
  return (
    BigInt(traitA) |
    (BigInt(traitB) << 8n) |
    (BigInt(traitC) << 16n) |
    (BigInt(traitD) << 24n)
  );
}

function randomTokenId(used) {
  while (true) {
    const id = crypto.randomInt(1, TOKEN_ID_MAX + 1);
    if (!used.has(id)) {
      used.add(id);
      return id;
    }
  }
}

function randomRemaining() {
  const min = Math.max(1, REMAINING_MIN);
  const max = Math.max(min, REMAINING_MAX);
  return crypto.randomInt(min, max + 1);
}

function decodeTokenURI(uri) {
  if (!uri.startsWith(JSON_PREFIX)) {
    throw new Error("Unexpected tokenURI prefix");
  }
  const jsonBase64 = uri.slice(JSON_PREFIX.length);
  const jsonStr = Buffer.from(jsonBase64, "base64").toString("utf8");
  const meta = JSON.parse(jsonStr);
  const image = meta.image || "";
  if (!image.startsWith(IMAGE_PREFIX)) {
    throw new Error("Unexpected image prefix");
  }
  const svgBase64 = image.slice(IMAGE_PREFIX.length);
  const svg = Buffer.from(svgBase64, "base64").toString("utf8");
  return { meta, svg };
}

function ensureOutputDir() {
  const baseDir = path.resolve("gamepieces_samples");
  fs.mkdirSync(baseDir, { recursive: true });
  const stamp = new Date()
    .toISOString()
    .replace(/\..+/, "")
    .replace(/[-:]/g, "")
    .replace("T", "_");
  const label = (process.env.OUTPUT_LABEL || "").trim();
  const safeLabel = label.replace(/[^A-Za-z0-9_-]+/g, "");
  const dirName = safeLabel ? `${stamp}_${safeLabel}` : stamp;
  const outDir = path.join(baseDir, dirName);
  fs.mkdirSync(outDir);
  return outDir;
}

async function main() {
  const { ethers } = hre;
  const [deployer] = await ethers.getSigners();

  const iconsPath = path.resolve("scripts/data/icons32Data.json");
  const iconsRaw = fs.readFileSync(iconsPath, "utf8");
  const iconsData = JSON.parse(iconsRaw);
  if (iconsData.paths?.length !== 33) throw new Error("icons32Data.json paths length mismatch");
  if (iconsData.symQ1?.length !== 8) throw new Error("icons32Data.json symQ1 length mismatch");
  if (iconsData.symQ2?.length !== 8) throw new Error("icons32Data.json symQ2 length mismatch");
  if (iconsData.symQ3?.length !== 8) throw new Error("icons32Data.json symQ3 length mismatch");

  const NftFactory = await ethers.getContractFactory("contracts/test/MockNftOwner.sol:MockNftOwner");
  const nft = await NftFactory.deploy(deployer.address);
  await nft.waitForDeployment();

  const RegistryFactory = await ethers.getContractFactory("contracts/IconColorRegistry.sol:IconColorRegistry");
  const registry = await RegistryFactory.deploy(await nft.getAddress(), ZERO_ADDRESS);
  await registry.waitForDeployment();

  const IconsFactory = await ethers.getContractFactory("contracts/Icons32Data.sol:Icons32Data");
  const icons = await IconsFactory.deploy(
    iconsData.paths,
    iconsData.diamond,
    iconsData.symQ1,
    iconsData.symQ2,
    iconsData.symQ3
  );
  await icons.waitForDeployment();

  const GameFactory = await ethers.getContractFactory("contracts/test/MockGameStartTraits.sol:MockGameStartTraits");
  const game = await GameFactory.deploy(START_REMAINING);
  await game.waitForDeployment();

  const RendererFactory = await ethers.getContractFactory("contracts/IconRendererRegular32.sol:IconRendererRegular32");
  const renderer = await RendererFactory.deploy(
    await icons.getAddress(),
    await registry.getAddress(),
    ZERO_ADDRESS,
    deployer.address
  );
  await renderer.waitForDeployment();

  await (await renderer.wire([await game.getAddress(), await nft.getAddress()])).wait();

  const outDir = ensureOutputDir();
  const usedIds = new Set();
  const manifest = {
    level: LEVEL,
    lastExterminated: LAST_EX,
    startRemaining: START_REMAINING,
    count: COUNT,
    startingSizedCount: STARTING_COUNT,
    outputDir: outDir,
    items: []
  };

  for (let i = 0; i < COUNT; i += 1) {
    const tokenId = randomTokenId(usedIds);
    const traitsPacked = packedTraitsForToken(tokenId);
    const data =
      traitsPacked |
      (BigInt(LEVEL) << 32n) |
      (BigInt(LAST_EX) << 56n);
    const isStart = i < STARTING_COUNT;
    const remaining = isStart
      ? [START_REMAINING, START_REMAINING, START_REMAINING, START_REMAINING]
      : [randomRemaining(), randomRemaining(), randomRemaining(), randomRemaining()];

    const tokenUri = await renderer.tokenURI(tokenId, data, remaining);
    const { svg } = decodeTokenURI(tokenUri);

    const prefix = isStart
      ? `start_${String(i + 1).padStart(2, "0")}`
      : `rand_${String(i + 1 - STARTING_COUNT).padStart(2, "0")}`;
    const filename = `${prefix}_token_${tokenId}.svg`;
    fs.writeFileSync(path.join(outDir, filename), svg, "utf8");

    manifest.items.push({
      tokenId,
      file: filename,
      type: isStart ? "starting" : "random",
      remaining,
      traitsPacked: traitsPacked.toString()
    });
  }

  fs.writeFileSync(path.join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2), "utf8");
  console.log(`Wrote ${COUNT} gamepieces to ${outDir}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
