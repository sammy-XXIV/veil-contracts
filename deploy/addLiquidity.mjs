import { ethers } from "ethers";
import * as dotenv from "dotenv";
dotenv.config();

const CWETH   = "0x46208622DA27d91db4f0393733C8BA082ed83158";
const WETH    = "0xff54739b16576FA5402F211D0b938469Ab9A5f3F";
const VEIL    = "0x8B694DD1B76B39c30CE5106a4752dD2729482bEB";
const BACKEND = "https://veil-backend-2gki.onrender.com";
const AMOUNT  = 500000;

const provider = new ethers.JsonRpcProvider("https://ethereum-sepolia-rpc.publicnode.com");
const signer   = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

console.log("Owner:", signer.address);

const weth  = new ethers.Contract(WETH, [
  "function mint(address,uint256) external",
  "function approve(address,uint256) external returns(bool)"
], signer);
const cweth = new ethers.Contract(CWETH, [
  "function wrap(address,uint256) external",
  "function setOperator(address,uint48) external"
], signer);

console.log("Minting WETH...");
await (await weth.mint(signer.address, AMOUNT)).wait();
console.log("Approving WETH...");
await (await weth.approve(CWETH, AMOUNT)).wait();
console.log("Wrapping to cWETH...");
await (await cweth.wrap(signer.address, AMOUNT)).wait();
console.log("Setting VEIL as operator...");
const until = Math.floor(Date.now()/1000) + 365*24*60*60;
await (await cweth.setOperator(VEIL, until)).wait();

console.log("Encrypting amount...");
const res = await fetch(`${BACKEND}/encrypt`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    amount: AMOUNT.toString(),
    contractAddress: VEIL,
    userAddress: signer.address
  })
});
const { handle, inputProof } = await res.json();

const veil = new ethers.Contract(VEIL, [
  "function addLiquidity(bytes32 encryptedAmount, bytes inputProof) external"
], signer);

console.log("Adding liquidity...");
const tx = await veil.addLiquidity(handle, inputProof, { gasLimit: 1000000 });
await tx.wait();
console.log("Pool funded! Tx:", tx.hash);
