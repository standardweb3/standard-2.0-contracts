import { task } from "hardhat/config";
import { executeTx, deployContract, ZERO, recordAddress, executeFrom } from "../helper";

const assert = (condition, message) => {
    if (condition) return;
    throw new Error(message);
};


// npx hardhat --network rinkeby masterpool-deploy --stnd 0xccf56fb87850fe6cff0cd16f491933c138b7eadd --amount 1000000
task("dividend-deploy", "Deploy Standard DividendPool")
    .addParam("xstnd", "Address of StandardDividend")
    .setAction(async ({ xstnd }, { ethers }) => {
        const [deployer] = await ethers.getSigners();
        // Get before state
        console.log(
            `Deployer balance: ${ethers.utils.formatEther(
                await deployer.getBalance()
            )} ETH`
        );

        // Deploy Dividend Pool
        console.log(`Deploying Standard Dividend Strategy Pool with the account: ${deployer.address}`);
        const Pool = await ethers.getContractFactory("BondedStrategy");
        const pool = await Pool.deploy(xstnd);
        await deployContract(pool, "BondedStrategy")

        // Get results
        console.log(
            `Deployer balance: ${ethers.utils.formatEther(
                await deployer.getBalance()
            )} ETH`
        );

        // INFO: hre can only be imported inside task
        const hre = require("hardhat")
        // Verify MasterPool
        await hre.run("verify:verify", {
            contract: "contracts/pools/dividend/BondedStrategy.sol:BondedStrategy",
            address: pool.address,
            constructorArguments: [xstnd],
        })
    })

// npx hardhat --network rinkeby masterpool-deploy --stnd 0xccf56fb87850fe6cff0cd16f491933c138b7eadd --amount 1000000
task("dividend-verify", "Verify Standard DividendPool")
    .addParam("xstnd", "Address of StandardDividend")
    .addParam("dividend", "Dividend contract address")
    .setAction(async ({ xstnd, dividend }, { ethers }) => {

        // INFO: hre can only be imported inside task
        const hre = require("hardhat")
        // Verify MasterPool
        await hre.run("verify:verify", {
            contract: "contracts/pools/dividend/BondedStrategy.sol:BondedStrategy",
            address: dividend,
            constructorArguments: [xstnd],
        })
    })