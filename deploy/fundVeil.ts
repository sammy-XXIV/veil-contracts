import { ethers } from "hardhat";

async function main() {
  const CWETH = "0x46208622DA27d91db4f0393733C8BA082ed83158";
  const WETH  = "0xff54739b16576FA5402F211D0b938469Ab9A5f3F";
  const VEIL  = "0x4A1E8949008eE1A31D306b52d7547f00d7e9bc3c";
  const AMOUNT = ethers.parseUnits("5000000000000", 18); // 500 cWETH worth of WETH

  const [signer] = await ethers.getSigners();
  console.log("Funding with:", signer.address);

  const weth = new ethers.Contract(WETH, [
    "function mint(address to, uint256 amount) external",
    "function approve(address spender, uint256 amount) external returns (bool)",
  ], signer);

  const cweth = new ethers.Contract(CWETH, [
    "function wrap(address to, uint256 amount) external",
    "function setOperator(address operator, uint48 until) external",
  ], signer);

  const veil = new ethers.Contract(VEIL, [
    "function addLiquidity(uint256 amount) external",
  ], signer);

  console.log("Minting WETH...");
  await (await weth.mint(signer.address, AMOUNT)).wait();

  console.log("Approving...");
  await (await weth.approve(CWETH, AMOUNT)).wait();

  console.log("Wrapping to cWETH...");
  await (await cweth.wrap(VEIL, AMOUNT)).wait();

  console.log("Setting operator...");
  const until = Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60;
  await (await cweth.setOperator(VEIL, until)).wait();

  console.log("Adding liquidity record...");
  await (await veil.addLiquidity(50000000000)).wait(); // 500 cWETH = 500 * 10^8

  console.log("Done! Pool funded with 500 cWETH.");
}

main().catch(console.error);
