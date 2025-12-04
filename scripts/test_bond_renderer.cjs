const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const RendererFactory = await hre.ethers.getContractFactory("IconRendererBondTrophy");
  const renderer = await RendererFactory.deploy(hre.ethers.ZeroAddress, hre.ethers.ZeroAddress);
  await renderer.waitForDeployment();

  const OUTPUT_DIR = path.join(__dirname, "..", "artifacts", "tmp", "bond-renders-new");
  fs.rmSync(OUTPUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });

  // Test diverse odds scenarios: 2% (min), 10%, 25%, 50% (max)
  const scenarios = [
    { name: "tokenId1-odds02", tokenId: 1n, chance: 20 },
    { name: "tokenId1-odds50", tokenId: 1n, chance: 500 },
    { name: "tokenId2-odds02", tokenId: 2n, chance: 20 },
    { name: "tokenId2-odds50", tokenId: 2n, chance: 500 },
    { name: "tokenId3-odds25", tokenId: 3n, chance: 250 },
    { name: "tokenId4-odds10", tokenId: 4n, chance: 100 },
  ];

  for (const s of scenarios) {
    const uri = await renderer.bondTokenURI(s.tokenId, 1000, 500, s.chance, false, 0n);
    const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
    const svg = Buffer.from(json.image.split(",")[1], "base64").toString();
    
    fs.writeFileSync(path.join(OUTPUT_DIR, `${s.name}.svg`), svg);
    console.log(`Rendered ${s.name}.svg`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
