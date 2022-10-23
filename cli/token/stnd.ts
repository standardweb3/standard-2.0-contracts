import { task, types } from "hardhat/config";
import { BigNumber, constants } from "ethers";
import "@nomiclabs/hardhat-etherscan";
import { executeTx, deployContract, ZERO, MINTER_ROLE, recordAddress } from "../helper";
import "@tenderly/hardhat-tenderly"
import { ConstructorFragment } from "@ethersproject/abi";

task("stnd-deploy", "Deploy Standard Multichain Token")
  .addParam("proxy", "Add proxy pattern to the contract for upgradability")
  .addOptionalParam("parent", "mint initial total supply of 100,000,000 for parent usage or test", false, types.boolean)
  .setAction(async ({ proxy, parent }, { ethers }) => {

    const [deployer] = await ethers.getSigners();
    // INFO: hre can only be imported inside task
    const hre = require("hardhat")

    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    // Deploy  Impl
    console.log(`Deploying Standard Multichain Token Impl with the account: ${deployer.address}`);
    const TokenImpl = await ethers.getContractFactory("UChildAdministrableERC20")
    const impl = await TokenImpl.deploy()
    await deployContract(impl, "UChildAdministrableERC20")

    if (proxy == "true") {
      // Deploy Proxy
      console.log(`Deploying Standard Multichain Token Proxy with the account: ${deployer.address}`);
      const Proxy = await ethers.getContractFactory("UChildERC20Proxy")
      const proxy = await Proxy.deploy(impl.address)
      await deployContract(proxy, "UChildERC20Proxy")

      // Initialize proxy with necessary info
      const tx = await TokenImpl.attach(proxy.address).initialize("Standard", "STND", 18, "0xA6FA4fB5f76172d178d61B04b0ecd319C5d1C0aa");
      await executeTx(tx, "Execute initialize at")

      // Mint initial total supply if parent
      if (parent) {
        const mint = await TokenImpl.attach(proxy.address).mint(deployer.address, ethers.utils.parseUnits("100000000", 18));
        await executeTx(mint, "Execute Mint at")

        // Verify proxy
        await hre.run("verify:verify", {
          contract: "contracts/tokens/multichain/stnd_multichain_proxy.sol:UChildERC20Proxy",
          address: proxy.address,
          constructorArguments: [impl.address]
        })
      }
    } else {
      // Initialize impl with necessary info
      const tx = await TokenImpl.attach(impl.address).initialize("Standard", "STND", 18, "0xA6FA4fB5f76172d178d61B04b0ecd319C5d1C0aa");
      await executeTx(tx, "Execute initialize at")
      // Mint initial total supply if parent
      if (parent) {
        const mint = await TokenImpl.attach(impl.address).mint(deployer.address, ethers.utils.parseUnits("100000000", 18));
        await executeTx(mint, "Execute Mint at")
      }
    }


    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    // Verify Impl
    await hre.run("verify:verify", {
      contract: "contracts/tokens/multichain/stnd_multichain_impl.sol:UChildAdministrableERC20",
      address: impl.address,
      constructorArguments: []
    })

    const contracts = [
      {
        name: "UChildAdministrableERC20",
        address: impl.address
      },
      {
        name: "UChildERC20Proxy",
        address: proxy.address
      }]

    await hre.tenderly.verify(...contracts)
  });

task("stnd-add-handler", "Add bridge handler of stnd")
  .addParam("handler", "Address of handler contract")
  .addParam("stnd", "Address of Standard Token contract")
  .setAction(async ({ handler, stnd }, { ethers }) => {

    const [deployer] = await ethers.getSigners();

    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    // Grant role to handler
    const TokenImpl = await ethers.getContractFactory("UChildAdministrableERC20")
    const tx = await TokenImpl.attach(stnd).grantRole(MINTER_ROLE, handler);
    await executeTx(tx, "Execute grantRole at")

    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );
  })

task("bridgeToken-deploy", "Deploy Bridge Token")
  .addParam("name", "Name of Bridge Token")
  .addParam("symbol", "Symbol of Bridge Token")
  .addOptionalParam("handler", "Address of Bridge handler contract", "none", types.string)
  .setAction(async ({ name, symbol, handler }, { ethers }) => {

    const [deployer] = await ethers.getSigners();
    console.log(name)
    console.log(symbol)

    // INFO: hre can only be imported inside task
    const hre = require("hardhat")
    // Deploy BridgeToken
    console.log(`Deploying BridgeToken with the account: ${deployer.address}`);
    const BridgeToken = await ethers.getContractFactory("BridgeToken")
    const bridgeToken = await BridgeToken.deploy(name, symbol)
    await deployContract(bridgeToken, `BridgeToken:${name}`)

    // Add handler if given
    if (handler !== "none") {
      // Grant role to handler
      const TokenImpl = await ethers.getContractFactory("UChildAdministrableERC20")
      const tx = await BridgeToken.attach(bridgeToken.address).grantRole(MINTER_ROLE, handler);
      await executeTx(tx, "Execute grantRole at")
    }

    /*
    // Verify Impl
    await hre.run("verify:verify", {
      contract: "contracts/tokens/BridgeToken.sol:BridgeToken",
      address: bridgeToken.address,
      constructorArguments: [name, symbol]
    })
    */
  })


task("bridgeToken-add-handler", "Add bridge handler of token")
  .addParam("handler", "Address of handler contract")
  .addParam("token", "Address of Bridge Token contract")
  .setAction(async ({ handler, token }, { ethers }) => {

    const [deployer] = await ethers.getSigners();
    // INFO: hre can only be imported inside task
    const hre = require("hardhat")


    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    // Grant role to handler
    const BridgeToken = await ethers.getContractFactory("BridgeToken")
    const tx = await BridgeToken.attach(token).grantRole(MINTER_ROLE, handler);
    await executeTx(tx, "Execute grantRole at")

    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );
  })


task("stnd-anyswap-deploy", "Deploy Standard Multichain token which is compatible with Anyswap")
  .addOptionalParam("vault", "Address of Anyswap Vault", "none", types.string)
  .setAction(async ({ vault }, { ethers }) => {

    const [deployer] = await ethers.getSigners();
    // INFO: hre can only be imported inside task
    const hre = require("hardhat")

    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    // Deploy AnyswapV5ERC20
    console.log(`Deploying Standard Anyswap Multichain Token Impl with the account: ${deployer.address}`);
    const TokenImpl = await ethers.getContractFactory("AnyswapV5ERC20")
    const impl = await TokenImpl.deploy("Standard", "STND", 18, ZERO, deployer.address)
    await deployContract(impl, "AnyswapV5ERC20")

    // Init vault
    if (vault !== "none") {
      const tx = await impl.initVault(vault)
      await executeTx(tx, "Execute initVault at")
    }

    // Verify Impl
    await hre.run("verify:verify", {
      contract: "contracts/tokens/BridgeToken.sol:BridgeToken",
      address: impl.address,
      constructorArguments: ["Standard", "STND", 18, ZERO, deployer]
    })
  })

  task("stnd-mint", "Deploy Standard Multichain token which is compatible with Anyswap")
  .addParam("stnd", "Standard token address")
  .addParam("account", "account to mint")
  .addParam("amount", "Amount to mint to address")
  .setAction(async ({ stnd, account, amount }, { ethers }) => {

    const [deployer] = await ethers.getSigners();
    // INFO: hre can only be imported inside task
    const hre = require("hardhat")

    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    const TokenImpl = await ethers.getContractFactory("UChildAdministrableERC20")
    // mint certain amount
    const mint = await TokenImpl.attach(stnd).mint(account, ethers.utils.parseUnits(amount, 18));
    await executeTx(mint, "Execute Mint at")
  })



  task("stnd-approve", "Deploy Standard Multichain token which is compatible with Anyswap")
  .addParam("stnd", "Standard token address")
  .addParam("spender", "Spender account")
  .addParam("amount", "Amount to mint to address")
  .setAction(async ({ stnd, spender, amount }, { ethers }) => {

    const [deployer] = await ethers.getSigners();
    // INFO: hre can only be imported inside task
    const hre = require("hardhat")

    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    const TokenImpl = await ethers.getContractFactory("UChildAdministrableERC20")
    // approve certain amount
    const approve = await TokenImpl.attach(stnd).approve(spender, ethers.utils.parseUnits(amount, 18));
    await executeTx(approve, "Execute Approve at")
  })
