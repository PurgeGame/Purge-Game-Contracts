const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const RendererFactory = await hre.ethers.getContractFactory("IconRendererBongTrophy");
  const renderer = await RendererFactory.deploy(hre.ethers.ZeroAddress, hre.ethers.ZeroAddress);
  await renderer.waitForDeployment();

  const OUTPUT_DIR = path.join(__dirname, "..", "artifacts", "tmp", "bong-renders-new");
  fs.rmSync(OUTPUT_DIR, { recursive: true, force: true });
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });

  // Test diverse odds scenarios: 2% (min), 10%, 25%, 50% (max)
  const scenarios = [
    { name: "tokenId1-odds05", tokenId: 1n, chance: 50 },
    { name: "tokenId1-odds10", tokenId: 1n, chance: 100 },
    { name: "tokenId1-odds15", tokenId: 1n, chance: 150 },
    { name: "tokenId1-odds20", tokenId: 1n, chance: 200 },
    { name: "tokenId1-odds25", tokenId: 1n, chance: 250 },
    { name: "tokenId1-odds30", tokenId: 1n, chance: 300 },
    { name: "tokenId1-odds35", tokenId: 1n, chance: 350 },
    { name: "tokenId1-odds40", tokenId: 1n, chance: 400 },
    { name: "tokenId1-odds45", tokenId: 1n, chance: 450 },
    { name: "tokenId1-odds50", tokenId: 1n, chance: 500 },
  ];

  for (const s of scenarios) {
    const uri = await renderer.bongTokenURI(s.tokenId, 1000, 500, s.chance, false, 0n);
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
