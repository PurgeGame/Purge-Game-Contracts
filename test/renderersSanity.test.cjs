const { expect } = require("chai");
const { ethers } = require("hardhat");

function decodeBase64DataUrl(uri, prefix) {
  expect(uri.startsWith(prefix)).to.equal(true);
  const b64 = uri.slice(prefix.length);
  return Buffer.from(b64, "base64").toString("utf8");
}

describe("Renderers sanity", function () {
  it("renders bond progress arc when not matured", async function () {
    const admin = ethers.Wallet.createRandom().address;

    const MockCoin = await ethers.getContractFactory("MockCoinRead");
    const coin = await MockCoin.deploy(ethers.ZeroAddress, admin);
    await coin.waitForDeployment();

    const MockIcons = await ethers.getContractFactory("MockIcons32");
    const icons = await MockIcons.deploy();
    await icons.waitForDeployment();

    const MockNft = await ethers.getContractFactory("MockERC721Lite");
    const nft = await MockNft.deploy();
    await nft.waitForDeployment();

    const Registry = await ethers.getContractFactory("IconColorRegistry");
    const registry = await Registry.deploy(await nft.getAddress());
    await registry.waitForDeployment();

    const Assets = await ethers.getContractFactory("TrophySvgAssets");
    const assets = await Assets.deploy();
    await assets.waitForDeployment();

    const Svg = await ethers.getContractFactory("IconRendererTrophy32Svg");
    const svg = await Svg.deploy(
      await coin.getAddress(),
      await icons.getAddress(),
      await registry.getAddress(),
      await assets.getAddress(),
      admin
    );
    await svg.waitForDeployment();

    const TrophyRenderer = await ethers.getContractFactory("IconRendererTrophy32");
    const renderer = await TrophyRenderer.deploy(
      await icons.getAddress(),
      await registry.getAddress(),
      await svg.getAddress(),
      admin
    );
    await renderer.waitForDeployment();

    const adminSigner = await ethers.getImpersonatedSigner(admin);
    await ethers.provider.send("hardhat_setBalance", [
      admin,
      ethers.toQuantity(ethers.parseEther("1")),
    ]);
    await svg.connect(adminSigner).wire([await nft.getAddress()]);
    await renderer.connect(adminSigner).wire([await nft.getAddress()]);

    const tokenUri = await renderer.bondTokenURI(1, 100, 50, 500, false, 0);
    const jsonStr = decodeBase64DataUrl(tokenUri, "data:application/json;base64,");
    const meta = JSON.parse(jsonStr);
    const svgStr = decodeBase64DataUrl(meta.image, "data:image/svg+xml;base64,");

    expect(svgStr).to.include("<svg");
    expect(svgStr).to.include("bondeg");
  });

  it("omits bond progress arc when matured", async function () {
    const admin = ethers.Wallet.createRandom().address;

    const MockCoin = await ethers.getContractFactory("MockCoinRead");
    const coin = await MockCoin.deploy(ethers.ZeroAddress, admin);
    await coin.waitForDeployment();

    const MockIcons = await ethers.getContractFactory("MockIcons32");
    const icons = await MockIcons.deploy();
    await icons.waitForDeployment();

    const MockNft = await ethers.getContractFactory("MockERC721Lite");
    const nft = await MockNft.deploy();
    await nft.waitForDeployment();

    const Registry = await ethers.getContractFactory("IconColorRegistry");
    const registry = await Registry.deploy(await nft.getAddress());
    await registry.waitForDeployment();

    const Assets = await ethers.getContractFactory("TrophySvgAssets");
    const assets = await Assets.deploy();
    await assets.waitForDeployment();

    const Svg = await ethers.getContractFactory("IconRendererTrophy32Svg");
    const svg = await Svg.deploy(
      await coin.getAddress(),
      await icons.getAddress(),
      await registry.getAddress(),
      await assets.getAddress(),
      admin
    );
    await svg.waitForDeployment();

    const TrophyRenderer = await ethers.getContractFactory("IconRendererTrophy32");
    const renderer = await TrophyRenderer.deploy(
      await icons.getAddress(),
      await registry.getAddress(),
      await svg.getAddress(),
      admin
    );
    await renderer.waitForDeployment();

    const adminSigner = await ethers.getImpersonatedSigner(admin);
    await ethers.provider.send("hardhat_setBalance", [
      admin,
      ethers.toQuantity(ethers.parseEther("1")),
    ]);
    await svg.connect(adminSigner).wire([await nft.getAddress()]);
    await renderer.connect(adminSigner).wire([await nft.getAddress()]);

    const tokenUri = await renderer.bondTokenURI(1, 100, 0, 500, false, 0);
    const jsonStr = decodeBase64DataUrl(tokenUri, "data:application/json;base64,");
    const meta = JSON.parse(jsonStr);
    const svgStr = decodeBase64DataUrl(meta.image, "data:image/svg+xml;base64,");

    expect(svgStr).to.include("<svg");
    expect(svgStr).to.not.include("bondeg");
  });

  it("renders regular tokenURI JSON + SVG", async function () {
    const [owner] = await ethers.getSigners();
    const admin = ethers.Wallet.createRandom().address;

    const MockCoin = await ethers.getContractFactory("MockCoinRead");
    const coin = await MockCoin.deploy(ethers.ZeroAddress, admin);
    await coin.waitForDeployment();

    const MockIcons = await ethers.getContractFactory("MockIcons32");
    const icons = await MockIcons.deploy();
    await icons.waitForDeployment();

    const MockNft = await ethers.getContractFactory("MockERC721Lite");
    const nft = await MockNft.deploy();
    await nft.waitForDeployment();
    await nft.mint(await owner.getAddress(), 1);

    const Registry = await ethers.getContractFactory("IconColorRegistry");
    const registry = await Registry.deploy(await nft.getAddress());
    await registry.waitForDeployment();

    const RegularRenderer = await ethers.getContractFactory("IconRendererRegular32");
    const renderer = await RegularRenderer.deploy(
      await coin.getAddress(),
      await icons.getAddress(),
      await registry.getAddress(),
      admin
    );
    await renderer.waitForDeployment();

    const adminSigner = await ethers.getImpersonatedSigner(admin);
    await ethers.provider.send("hardhat_setBalance", [
      admin,
      ethers.toQuantity(ethers.parseEther("1")),
    ]);
    await renderer.connect(adminSigner).wire([ethers.ZeroAddress, await nft.getAddress()]);

    const trait0 = 0; // col=0 sym=0
    const trait1 = (1 << 3) | 1; // col=1 sym=1
    const trait2 = (2 << 3) | 2; // col=2 sym=2
    const trait3 = (3 << 3) | 3; // col=3 sym=3
    const traitsPacked = trait0 | (trait1 << 6) | (trait2 << 12) | (trait3 << 18);
    const lastExterminated = 420;
    const level = 5;
    const data =
      (BigInt(lastExterminated) << 56n) |
      (BigInt(level) << 32n) |
      BigInt(traitsPacked);
    const remaining = [100, 100, 100, 100];

    const tokenUri = await renderer.tokenURI(1, data, remaining);
    const jsonStr = decodeBase64DataUrl(tokenUri, "data:application/json;base64,");
    const meta = JSON.parse(jsonStr);
    const svgStr = decodeBase64DataUrl(meta.image, "data:image/svg+xml;base64,");

    expect(meta.name).to.include("#1");
    expect(svgStr).to.include("<svg");
  });

  it("renders genesis token #0 as the placeholder trophy", async function () {
    const [owner] = await ethers.getSigners();
    const admin = ethers.Wallet.createRandom().address;

    const MockCoin = await ethers.getContractFactory("MockCoinRead");
    const coin = await MockCoin.deploy(ethers.ZeroAddress, admin);
    await coin.waitForDeployment();

    const MockIcons = await ethers.getContractFactory("MockIcons32");
    const icons = await MockIcons.deploy();
    await icons.waitForDeployment();

    const MockNft = await ethers.getContractFactory("MockERC721Lite");
    const nft = await MockNft.deploy();
    await nft.waitForDeployment();

    const Registry = await ethers.getContractFactory("IconColorRegistry");
    const registry = await Registry.deploy(await nft.getAddress());
    await registry.waitForDeployment();

    const RegularRenderer = await ethers.getContractFactory("IconRendererRegular32");
    const renderer = await RegularRenderer.deploy(
      await coin.getAddress(),
      await icons.getAddress(),
      await registry.getAddress(),
      admin
    );
    await renderer.waitForDeployment();

    const uri = await renderer.tokenURI(0, 0, [0, 0, 0, 0]);
    const jsonStr = decodeBase64DataUrl(uri, "data:application/json;base64,");
    const meta = JSON.parse(jsonStr);
    const svgStr = decodeBase64DataUrl(meta.image, "data:image/svg+xml;base64,");

    expect(meta.name).to.include("Genesis");
    expect(svgStr).to.include("viewBox='0 0 512 512'");
    expect(svgStr).to.include("href='#flame-icon'");
    expect(svgStr).to.include("<polygon");

    const ExposedNft = await ethers.getContractFactory("ExposedDegenerusGamepieces");
    const gamepieces = await ExposedNft.deploy(
      await renderer.getAddress(),
      await coin.getAddress(),
      ethers.ZeroAddress,
      await owner.getAddress()
    );
    await gamepieces.waitForDeployment();

    const uriFromNft = await gamepieces.tokenURI(0);
    const jsonStr2 = decodeBase64DataUrl(uriFromNft, "data:application/json;base64,");
    const meta2 = JSON.parse(jsonStr2);
    const svgStr2 = decodeBase64DataUrl(meta2.image, "data:image/svg+xml;base64,");

    expect(meta2.name).to.include("Genesis");
    expect(svgStr2).to.include("viewBox='0 0 512 512'");
  });
});
