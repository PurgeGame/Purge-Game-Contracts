#!/usr/bin/env node
/**
 * Fetches real trophy metadata/SVGs from the deployed Degenerus NFT contract.
 *
 * Example:
 *   SEPOLIA_RPC_URL=https://... node scripts/generateTrophiesLive.js --token 1234 --token 5678
 *
 * Options:
 *   --token <id>         Repeatable. Fetch an explicit token id.
 *   --range <start-end>  Inclusive numeric range (e.g. --range 1200-1210).
 *   --output <dir>       Target directory (default artifacts/tmp/trophies-live).
 *   --wallets <file>     Override wallets.json path (defaults to repo wallets.json/env/test locations).
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const DEFAULT_OUTPUT = path.join(ROOT, "artifacts", "tmp", "trophies-live");
const NFT_ARTIFACT = path.join(ROOT, "artifacts", "contracts", "DegenerusGameNFT.sol", "DegenerusGameNFT.json");
const WALLET_CANDIDATES = [
  path.join(ROOT, "wallets.json"),
  path.join(ROOT, "env", "wallets.json"),
  path.join(ROOT, "test", "wallets.json"),
];

function loadWallets(explicitPath) {
  const paths = explicitPath ? [explicitPath] : WALLET_CANDIDATES;
  for (const candidate of paths) {
    if (!candidate) continue;
    if (fs.existsSync(candidate)) {
      return JSON.parse(fs.readFileSync(candidate, "utf8"));
    }
  }
  throw new Error("wallets.json not found (checked repo root, env/, and test/)");
}

function collectTokenIds(argv) {
  const ids = new Set();
  let outputDir = DEFAULT_OUTPUT;
  let walletPath = "";
  let rpcUrl = "";

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--token" || arg === "-t") {
      const val = argv[++i];
      if (val === undefined) throw new Error("--token requires a value");
      const parsed = Number(val);
      if (!Number.isInteger(parsed) || parsed < 0) {
        throw new Error(`Invalid token id: ${val}`);
      }
      ids.add(parsed);
    } else if (arg === "--range") {
      const val = argv[++i];
      if (!val) throw new Error("--range requires start-end");
      const [startStr, endStr] = val.split(/[-:]/);
      const start = Number(startStr);
      const end = Number(endStr);
      if (![start, end].every((n) => Number.isInteger(n))) {
        throw new Error(`Invalid range: ${val}`);
      }
      if (end < start) throw new Error(`Range end ${end} < start ${start}`);
      for (let id = start; id <= end; id++) {
        ids.add(id);
      }
    } else if (arg === "--output") {
      outputDir = argv[++i];
      if (!outputDir) throw new Error("--output requires a directory");
    } else if (arg === "--wallets") {
      walletPath = argv[++i];
      if (!walletPath) throw new Error("--wallets requires a path");
    } else if (arg === "--rpc") {
      rpcUrl = argv[++i];
      if (!rpcUrl) throw new Error("--rpc requires a URL");
    } else if (arg === "--help" || arg === "-h" || arg === "help") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return { ids: Array.from(ids).sort((a, b) => a - b), outputDir, walletPath, rpcUrl };
}

function printHelp() {
  console.log(`
Usage: node scripts/generateTrophiesLive.js --token <id> [...]

Options:
  --token <id>         Fetch the specified token id (repeatable).
  --range a-b          Fetch every token between a and b inclusive.
  --output <dir>       Write files to this directory (default ${DEFAULT_OUTPUT}).
  --wallets <file>     Explicit wallets.json path.
  --rpc <url>          JSON-RPC URL (defaults to env DEGEN_RPC_URL/SEPOLIA_RPC_URL/RPC_URL).
  --help               Show this message.
`);
}

function decodeMetadata(uri) {
  if (!uri || !uri.startsWith("data:")) {
    throw new Error("tokenURI is not a data URI");
  }
  const [, payload] = uri.split("base64,", 2);
  if (!payload) throw new Error("Unexpected tokenURI format");
  const metadataJson = Buffer.from(payload, "base64").toString("utf8");
  const metadata = JSON.parse(metadataJson);
  const imageField = metadata.image || metadata.image_data || metadata.animation_url;
  if (!imageField) {
    throw new Error("Metadata missing image/image_data field");
  }
  const imagePayload = imageField.startsWith("data:")
    ? imageField.split("base64,", 2)[1]
    : imageField;
  const svg = Buffer.from(imagePayload, "base64").toString("utf8");
  return { metadata, metadataJson, svg };
}

function resolveRpcUrl(cliRpc) {
  return (
    cliRpc ||
    process.env.DEGEN_RPC_URL ||
    process.env.SEPOLIA_RPC_URL ||
    process.env.RPC_URL ||
    ""
  );
}

async function main() {
  const { ids, outputDir, walletPath, rpcUrl: rpcCli } = collectTokenIds(process.argv.slice(2));
  if (ids.length === 0) {
    throw new Error("No token ids provided. Use --token or --range.");
  }
  const wallets = loadWallets(walletPath);
  const nftAddr = wallets?.contracts?.nft;
  if (!nftAddr) {
    throw new Error("wallets.json missing contracts.nft address");
  }
  const rpcUrl = resolveRpcUrl(rpcCli);
  if (!rpcUrl) {
    throw new Error("Missing RPC URL. Set DEGEN_RPC_URL/SEPOLIA_RPC_URL/RPC_URL or pass --rpc.");
  }
  if (!fs.existsSync(NFT_ARTIFACT)) {
    throw new Error(`Missing artifact: ${NFT_ARTIFACT}`);
  }
  const { abi } = JSON.parse(fs.readFileSync(NFT_ARTIFACT, "utf8"));

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const nft = new ethers.Contract(nftAddr, abi, provider);
  fs.mkdirSync(outputDir, { recursive: true });

  console.log(`Writing ${ids.length} token(s) from ${nftAddr} via ${rpcUrl} → ${outputDir}`);
  for (const tokenId of ids) {
    try {
      const uri = await nft.tokenURI(tokenId);
      const { metadata, metadataJson, svg } = decodeMetadata(uri);
      const base = `token-${tokenId}`;
      const svgPath = path.join(outputDir, `${base}.svg`);
      const jsonPath = path.join(outputDir, `${base}.json`);
      fs.writeFileSync(svgPath, svg);
      fs.writeFileSync(jsonPath, metadataJson);
      console.log(`• token ${tokenId} "${metadata.name || "unnamed"}"`);
    } catch (err) {
      console.error(`✖ token ${tokenId} failed: ${err.message || err}`);
    }
  }

  console.log("Done.");
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
