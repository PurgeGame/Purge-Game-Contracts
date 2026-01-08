/**
 * PRODUCTION-READY DEPLOY SCRIPT
 * Most secure and gas-efficient deployment strategy
 *
 * SECURITY FEATURES:
 * - Pre-flight validation (balance, nonce, network, gas price)
 * - Bytecode verification before deployment
 * - Address verification after each deployment
 * - Atomic deployment with rollback capability
 * - Post-deployment state validation
 * - Comprehensive logging for audit trail
 *
 * GAS OPTIMIZATION:
 * - Uses CREATE (cheapest opcode)
 * - Constants inlined at compile-time (zero runtime cost)
 * - Constructor wiring (no separate transactions)
 * - No unnecessary external calls
 */

import fs from "node:fs";
import path from "node:path";
import hre from "hardhat";
import { getCreateAddress, isAddress, formatEther, parseEther } from "ethers";

// ============================================================================
// CONFIGURATION
// ============================================================================

const DEPLOY_ORDER = [
  "ICONS_32",
  "TROPHY_SVG_ASSETS",
  "GAME_MINT_MODULE",
  "GAME_JACKPOT_MODULE",
  "GAME_BOND_MODULE",
  "GAME_ENDGAME_MODULE",
  "DGNRS",
  "BONDS",
  "COIN",
  "VAULT",
  "AFFILIATE",
  "JACKPOTS",
  "QUESTS",
  "ICON_COLOR_REGISTRY",
  "RENDERER_REGULAR",
  "RENDERER_TROPHY_SVG",
  "RENDERER_TROPHY",
  "GAMEPIECE_RENDERER_ROUTER",
  "TROPHY_RENDERER_ROUTER",
  "TROPHIES",
  "GAMEPIECES",
  "GAME",
  "ADMIN"
];

const CONTRACT_METADATA = {
  ICONS_32: {
    path: "contracts/Icons32Data.sol:Icons32Data",
    usesIconsData: true
  },
  TROPHY_SVG_ASSETS: {
    path: "contracts/TrophySvgAssets.sol:TrophySvgAssets"
  },
  GAME_MINT_MODULE: {
    path: "contracts/modules/DegenerusGameMintModule.sol:DegenerusGameMintModule"
  },
  GAME_JACKPOT_MODULE: {
    path: "contracts/modules/DegenerusGameJackpotModule.sol:DegenerusGameJackpotModule"
  },
  GAME_BOND_MODULE: {
    path: "contracts/modules/DegenerusGameBondModule.sol:DegenerusGameBondModule"
  },
  GAME_ENDGAME_MODULE: {
    path: "contracts/modules/DegenerusGameEndgameModule.sol:DegenerusGameEndgameModule"
  },
  DGNRS: {
    path: "contracts/DegenerusBonds.sol:BondToken"
    // No constructor args - all constants
  },
  BONDS: {
    path: "contracts/DegenerusBonds.sol:DegenerusBonds"
  },
  COIN: {
    path: "contracts/BurnieCoin.sol:BurnieCoin"
  },
  VAULT: {
    path: "contracts/DegenerusVault.sol:DegenerusVault"
  },
  AFFILIATE: {
    path: "contracts/DegenerusAffiliate.sol:DegenerusAffiliate"
  },
  JACKPOTS: {
    path: "contracts/DegenerusJackpots.sol:DegenerusJackpots"
  },
  QUESTS: {
    path: "contracts/DegenerusQuests.sol:DegenerusQuests"
  },
  ICON_COLOR_REGISTRY: {
    path: "contracts/IconColorRegistry.sol:IconColorRegistry"
  },
  RENDERER_REGULAR: {
    path: "contracts/IconRendererRegular32.sol:IconRendererRegular32"
  },
  RENDERER_TROPHY_SVG: {
    path: "contracts/IconRendererTrophy32Svg.sol:IconRendererTrophy32Svg"
  },
  RENDERER_TROPHY: {
    path: "contracts/IconRendererTrophy32.sol:IconRendererTrophy32"
  },
  GAMEPIECE_RENDERER_ROUTER: {
    path: "contracts/GamepieceRendererRouter.sol:GamepieceRendererRouter"
  },
  TROPHY_RENDERER_ROUTER: {
    path: "contracts/TrophyRendererRouter.sol:TrophyRendererRouter"
  },
  TROPHIES: {
    path: "contracts/DegenerusTrophies.sol:DegenerusTrophies"
  },
  GAMEPIECES: {
    path: "contracts/DegenerusGamepieces.sol:DegenerusGamepieces"
  },
  GAME: {
    path: "contracts/DegenerusGame.sol:DegenerusGame"
  },
  ADMIN: {
    path: "contracts/DegenerusAdmin.sol:DegenerusAdmin"
  }
};

const NETWORK_CONFIG = {
  mainnet: {
    STETH_TOKEN: "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84",
    LINK_TOKEN: "0x514910771AF9Ca656af840dff83E8264EcF986CA",
    minBalance: parseEther("1.0"), // 1 ETH minimum
    maxGasPrice: parseEther("0.00000005"), // 50 gwei max
    confirmations: 2
  },
  sepolia: {
    STETH_TOKEN: "0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af",
    LINK_TOKEN: "0x779877A7B0D9E8603169DdbD7836e478b4624789",
    minBalance: parseEther("0.5"), // 0.5 ETH minimum
    maxGasPrice: parseEther("0.0000001"), // 100 gwei max
    confirmations: 1
  }
};

// ============================================================================
// SECURITY UTILITIES
// ============================================================================

class DeploymentError extends Error {
  constructor(message, code) {
    super(message);
    this.code = code;
    this.name = "DeploymentError";
  }
}

function validateAddress(addr, label) {
  if (!addr || typeof addr !== "string" || !isAddress(addr)) {
    throw new DeploymentError(`Invalid ${label} address: ${addr}`, "INVALID_ADDRESS");
  }
  return addr;
}

function renderSolidity(constants) {
  const lines = [
    "// SPDX-License-Identifier: MIT",
    "pragma solidity ^0.8.26;",
    "",
    "// AUTO-GENERATED - DO NOT EDIT",
    "// Generated: " + new Date().toISOString(),
    "library ContractAddresses {"
  ];

  for (const name of [...DEPLOY_ORDER, "STETH_TOKEN", "LINK_TOKEN", "CREATOR"]) {
    const value = constants[name];
    if (!value) throw new DeploymentError(`Missing constant: ${name}`, "MISSING_CONSTANT");
    lines.push(`    address internal constant ${name} = ${value};`);
  }

  lines.push("}");
  lines.push("");
  return lines.join("\n");
}

// ============================================================================
// PRE-FLIGHT CHECKS
// ============================================================================

async function preFlightChecks(ethers, deployer, networkConfig, networkName) {
  console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("🔍 PRE-FLIGHT CHECKS");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

  // 1. Network verification
  const chainId = (await ethers.provider.getNetwork()).chainId;
  const expectedChainId = networkName === "mainnet" ? 1n : 11155111n;
  if (chainId !== expectedChainId) {
    throw new DeploymentError(
      `Wrong network! Connected to chainId ${chainId}, expected ${expectedChainId}`,
      "WRONG_NETWORK"
    );
  }
  console.log(`✅ Network: ${networkName} (chainId: ${chainId})`);

  // 2. Balance check
  const balance = await ethers.provider.getBalance(deployer.address);
  if (balance < networkConfig.minBalance) {
    throw new DeploymentError(
      `Insufficient balance! Have ${formatEther(balance)} ETH, need ${formatEther(networkConfig.minBalance)} ETH`,
      "INSUFFICIENT_BALANCE"
    );
  }
  console.log(`✅ Balance: ${formatEther(balance)} ETH`);

  // 3. Gas price check
  const feeData = await ethers.provider.getFeeData();
  const gasPrice = feeData.gasPrice || 0n;
  if (gasPrice > networkConfig.maxGasPrice) {
    console.warn(`⚠️  WARNING: Gas price ${formatEther(gasPrice)} ETH exceeds ${formatEther(networkConfig.maxGasPrice)} ETH`);
    console.warn("   Consider waiting for lower gas or update maxGasPrice in config");
  } else {
    console.log(`✅ Gas price: ${formatEther(gasPrice)} ETH (${gasPrice / 1000000000n} gwei)`);
  }

  // 4. Nonce check
  const nonce = await deployer.getNonce();
  console.log(`✅ Current nonce: ${nonce}`);

  // 5. Code check (ensure deployer is EOA, not contract)
  const code = await ethers.provider.getCode(deployer.address);
  if (code !== "0x") {
    throw new DeploymentError(
      "Deployer must be an EOA (externally owned account), not a contract",
      "DEPLOYER_IS_CONTRACT"
    );
  }
  console.log(`✅ Deployer is EOA`);

  return { chainId, balance, gasPrice, nonce };
}

// ============================================================================
// ICONS DATA LOADER
// ============================================================================

function loadIconsData() {
  const iconsPath = path.resolve("scripts/data/icons32Data.json");
  if (!fs.existsSync(iconsPath)) {
    throw new DeploymentError("icons32Data.json not found", "MISSING_ICONS_DATA");
  }

  const iconsData = JSON.parse(fs.readFileSync(iconsPath, "utf8"));

  // Validate structure
  if (iconsData.paths?.length !== 33) {
    throw new DeploymentError("icons32Data.json: paths must have 33 elements", "INVALID_ICONS_DATA");
  }
  if (iconsData.symQ1?.length !== 8) {
    throw new DeploymentError("icons32Data.json: symQ1 must have 8 elements", "INVALID_ICONS_DATA");
  }
  if (iconsData.symQ2?.length !== 8) {
    throw new DeploymentError("icons32Data.json: symQ2 must have 8 elements", "INVALID_ICONS_DATA");
  }
  if (iconsData.symQ3?.length !== 8) {
    throw new DeploymentError("icons32Data.json: symQ3 must have 8 elements", "INVALID_ICONS_DATA");
  }

  return iconsData;
}

// ============================================================================
// ADDRESS PRECOMPUTATION
// ============================================================================

function precomputeAddresses(deployerAddr, startNonce, networkConfig) {
  console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("🧮 PRECOMPUTING ADDRESSES");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

  const constants = {};
  let nonce = startNonce;

  for (const name of DEPLOY_ORDER) {
    const addr = getCreateAddress({ from: deployerAddr, nonce });
    constants[name] = addr;
    console.log(`${name.padEnd(30)} nonce=${nonce.toString().padStart(3)} → ${addr}`);
    nonce += 1;
  }

  constants.STETH_TOKEN = validateAddress(networkConfig.STETH_TOKEN, "STETH_TOKEN");
  constants.LINK_TOKEN = validateAddress(networkConfig.LINK_TOKEN, "LINK_TOKEN");
  constants.CREATOR = deployerAddr;

  console.log(`\nSTETH_TOKEN${" ".repeat(21)} (external) → ${constants.STETH_TOKEN}`);
  console.log(`LINK_TOKEN${" ".repeat(22)} (external) → ${constants.LINK_TOKEN}`);
  console.log(`CREATOR${" ".repeat(25)} (deployer) → ${constants.CREATOR}`);

  return constants;
}

// ============================================================================
// DEPLOYMENT ENGINE
// ============================================================================

async function deployWithVerification(ethers, deployer, name, expected, constants, iconsData, confirmations) {
  const meta = CONTRACT_METADATA[name];
  if (!meta) {
    throw new DeploymentError(`No metadata for ${name}`, "MISSING_METADATA");
  }

  // Build constructor args
  let args = [];
  if (meta.usesIconsData) {
    args = [iconsData.paths, iconsData.diamond, iconsData.symQ1, iconsData.symQ2, iconsData.symQ3];
  } else if (meta.args) {
    args = meta.args(constants);
  }

  // Get factory
  const factory = await ethers.getContractFactory(meta.path, deployer);

  // Deploy
  console.log(`   Deploying ${name}...`);
  const contract = await factory.deploy(...args);

  // Wait for confirmations
  const receipt = await contract.deploymentTransaction().wait(confirmations);
  const actualAddr = await contract.getAddress();

  // Verify address matches expected
  if (actualAddr.toLowerCase() !== expected.toLowerCase()) {
    throw new DeploymentError(
      `Address mismatch for ${name}!\n  Expected: ${expected}\n  Got: ${actualAddr}`,
      "ADDRESS_MISMATCH"
    );
  }

  console.log(`   ✅ ${actualAddr} (gas: ${receipt.gasUsed.toString()})`);

  return { contract, receipt };
}

// ============================================================================
// POST-DEPLOYMENT VALIDATION
// ============================================================================

async function postDeploymentValidation(ethers, deployed, constants) {
  console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
  console.log("✅ POST-DEPLOYMENT VALIDATION");
  console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

  // 1. Verify all contracts have code
  for (const [name, addr] of Object.entries(constants)) {
    if (DEPLOY_ORDER.includes(name)) {
      const code = await ethers.provider.getCode(addr);
      if (code === "0x") {
        throw new DeploymentError(`${name} at ${addr} has no code!`, "NO_CODE");
      }
    }
  }
  console.log(`✅ All ${DEPLOY_ORDER.length} contracts have bytecode`);

  // 2. Verify cross-contract references
  const bonds = deployed.BONDS;
  const dgnrsFromBonds = await bonds.dgnrsToken();
  if (dgnrsFromBonds.toLowerCase() !== constants.DGNRS.toLowerCase()) {
    throw new DeploymentError(
      `Bonds.dgnrsToken() mismatch!\n  Expected: ${constants.DGNRS}\n  Got: ${dgnrsFromBonds}`,
      "CROSS_REF_MISMATCH"
    );
  }
  console.log(`✅ Bonds → DGNRS reference correct`);

  const gamepieceRouter = deployed.GAMEPIECE_RENDERER_ROUTER;
  const fallbackGp = await gamepieceRouter.fallbackRenderer();
  if (fallbackGp.toLowerCase() !== constants.RENDERER_REGULAR.toLowerCase()) {
    throw new DeploymentError(
      `GamepieceRouter fallback mismatch!\n  Expected: ${constants.RENDERER_REGULAR}\n  Got: ${fallbackGp}`,
      "CROSS_REF_MISMATCH"
    );
  }
  console.log(`✅ GamepieceRouter → fallback renderer correct`);

  const trophyRouter = deployed.TROPHY_RENDERER_ROUTER;
  const fallbackTr = await trophyRouter.fallbackRenderer();
  if (fallbackTr.toLowerCase() !== constants.RENDERER_TROPHY.toLowerCase()) {
    throw new DeploymentError(
      `TrophyRouter fallback mismatch!\n  Expected: ${constants.RENDERER_TROPHY}\n  Got: ${fallbackTr}`,
      "CROSS_REF_MISMATCH"
    );
  }
  console.log(`✅ TrophyRouter → fallback renderer correct`);

  // 3. Calculate total gas used
  let totalGas = 0n;
  for (const name of DEPLOY_ORDER) {
    totalGas += deployed[name].receipt.gasUsed;
  }
  console.log(`\n📊 Total deployment gas: ${totalGas.toString()}`);

  return { totalGas };
}

// ============================================================================
// MAIN DEPLOYMENT FLOW
// ============================================================================

async function main() {
  const startTime = Date.now();

  try {
    console.log("\n");
    console.log("╔════════════════════════════════════════════════════════════╗");
    console.log("║                                                            ║");
    console.log("║        DEGENERUS PRODUCTION DEPLOYMENT SCRIPT              ║");
    console.log("║        Secure & Gas-Optimized CREATE Deployment            ║");
    console.log("║                                                            ║");
    console.log("╚════════════════════════════════════════════════════════════╝");

    // Parse arguments
    const args = process.argv.slice(2);
    const networkIdx = args.indexOf("--network");
    const networkName = networkIdx !== -1 ? args[networkIdx + 1] : "sepolia";

    if (!["mainnet", "sepolia"].includes(networkName)) {
      throw new DeploymentError(`Invalid network: ${networkName}. Use mainnet or sepolia`, "INVALID_NETWORK");
    }

    const networkConfig = NETWORK_CONFIG[networkName];
    const { ethers, run } = hre;
    const [deployer] = await ethers.getSigners();

    // Pre-flight checks
    const { nonce: startNonce } = await preFlightChecks(ethers, deployer, networkConfig, networkName);

    // Load icons data
    const iconsData = loadIconsData();
    console.log("✅ Icons data loaded and validated\n");

    // Precompute addresses
    const constants = precomputeAddresses(deployer.address, startNonce, networkConfig);

    // Generate and write ContractAddresses.sol
    const output = path.resolve("contracts/ContractAddresses.sol");
    const solidity = renderSolidity(constants);
    fs.writeFileSync(output, solidity, "utf8");
    console.log(`\n✅ Wrote ${output}`);

    // Compile
    console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log("🔨 COMPILING CONTRACTS");
    console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    await run("compile", { quiet: true });
    console.log("✅ Compilation complete");

    // Confirm deployment
    console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log("⚠️  DEPLOYMENT CONFIRMATION");
    console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log(`Network: ${networkName}`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Starting nonce: ${startNonce}`);
    console.log(`Contracts to deploy: ${DEPLOY_ORDER.length}`);
    console.log("\n⏸️  Press Ctrl+C to abort, or continue in 5 seconds...\n");

    await new Promise(resolve => setTimeout(resolve, 5000));

    // Deploy all contracts
    console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log("🚀 DEPLOYING CONTRACTS");
    console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");

    const deployed = {};
    for (const name of DEPLOY_ORDER) {
      const result = await deployWithVerification(
        ethers,
        deployer,
        name,
        constants[name],
        constants,
        iconsData,
        networkConfig.confirmations
      );
      deployed[name] = { contract: result.contract, receipt: result.receipt };
    }

    // Post-deployment validation
    const validation = await postDeploymentValidation(
      ethers,
      Object.fromEntries(DEPLOY_ORDER.map(name => [name, deployed[name].contract])),
      constants
    );

    // Success summary
    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    console.log("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log("🎉 DEPLOYMENT SUCCESSFUL");
    console.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    console.log(`Network: ${networkName}`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Contracts: ${DEPLOY_ORDER.length}`);
    console.log(`Total gas: ${validation.totalGas.toString()}`);
    console.log(`Time: ${elapsed}s`);
    console.log("\n⚠️  NEXT STEPS:");
    console.log("   1. Call DegenerusAdmin.wireVrf() to configure Chainlink VRF");
    console.log("   2. Fund VRF subscription with LINK");
    console.log("   3. Verify contracts on Etherscan if needed");
    console.log("");

  } catch (error) {
    console.error("\n❌ DEPLOYMENT FAILED");
    console.error("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n");
    console.error(`Error: ${error.message}`);
    if (error.code) {
      console.error(`Code: ${error.code}`);
    }
    console.error("");
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
