import { ethers } from "hardhat";

async function main() {
  const CWETH = "0x46208622DA27d91db4f0393733C8BA082ed83158";
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  const VeilLending = await ethers.getContractFactory("VeilLending");
  const veil = await VeilLending.deploy(CWETH, CWETH);
  await veil.waitForDeployment();
  const address = await veil.getAddress();
  console.log("VeilLending deployed to:", address);
}

main().catch(console.error);
