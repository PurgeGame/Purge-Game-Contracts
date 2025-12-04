const hre = require("hardhat");

async function main() {
  const RendererFactory = await hre.ethers.getContractFactory("IconRendererBongTrophy");
  // Deploy with null addresses to trigger random fallback
  const renderer = await RendererFactory.deploy(hre.ethers.ZeroAddress, hre.ethers.ZeroAddress);
  await renderer.waitForDeployment();

  console.log("Renderer deployed to:", await renderer.getAddress());

  const tokens = [1n, 2n, 3n, 12345n];
  
  for (const tokenId of tokens) {
    const uri = await renderer.bongTokenURI(tokenId, 1000, 500, 500, false, 0n);
    const json = JSON.parse(Buffer.from(uri.split(",")[1], "base64").toString());
    const svg = Buffer.from(json.image.split(",")[1], "base64").toString();
    
    // Extract colors roughly
    const fillColors = svg.match(/fill='#([0-9a-f]{6})'/gi) || [];
    console.log(`Token ${tokenId}: found ${fillColors.length} color fills.`);
    if (fillColors.length > 0) {
        console.log(`   Colors: ${fillColors.join(", ")}`);
    } else {
        console.log("   SVG content head:", svg.substring(0, 200));
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
