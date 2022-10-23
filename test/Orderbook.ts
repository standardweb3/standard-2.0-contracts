import { exec } from "child_process";
import { assert } from "console";
import { FACTORY_ROLE, ZERO } from "../cli/helper";
import { executeTx, deployContract, ChainId, getAddress } from "./helper";
const { EtherscanProvider } = require("@ethersproject/providers");
const { expect } = require("chai");
const { ethers } = require("hardhat");
const {
  now,
  mine,
  setTime,
  setTimeAndMine,
  Ganache,
  impersonate,
  skipBlocks,
  stopMining,
  startMining,
  addToBlock,
} = require("./helpers");

const expectArray = (actual, expected) => {
  for (let i = 0; i < actual.length; i++) {
    expect(actual[i].toString()).to.equal(expected[i].toString());
  }
};

describe("Basic Operations", function () {
  before(async function () {
    // setup the whole contracts
    const [deployer] = await ethers.getSigners();

    // Get before state
    console.log(
      `Deployer balance: ${ethers.utils.formatEther(
        await deployer.getBalance()
      )} ETH`
    );

    // Deploy two tokens
    const Token = await ethers.getContractFactory("ERC20PresetMinterPauser");
    const token1 = await Token.deploy("Token1", "TK1");
    await deployContract(token1, "Token1");
    const token2 = await Token.deploy("Token2", "TK2");
    await deployContract(token2, "Token2");

    // mint tokens for test
    const token1Mint = await token1.mint(deployer.address, ethers.utils.parseEther("1000000"));
    await executeTx(token1Mint, "Execute mint at");
    const token2Mint = await token2.mint(deployer.address, ethers.utils.parseEther("1000000"));
    await executeTx(token2Mint, "Execute mint at");

    // Deploy OrderFactory
    const OrderFactory = await ethers.getContractFactory("OrderFactory");
    const orderFactory = await OrderFactory.deploy();
    await deployContract(orderFactory, "OrderFactory");

    // Deploy OrderbookFactory
    const OrderbookFactory = await ethers.getContractFactory("OrderbookFactory");
    const orderbookFactory = await OrderbookFactory.deploy();
    await deployContract(orderbookFactory, "OrderbookFactory");

    // Deploy Matching Engine
    const MatchingEngine = await ethers.getContractFactory("MatchingEngine");
    const matchingEngine = await MatchingEngine.deploy();
    await deployContract(matchingEngine, "MatchingEngine");

    // initialize Matching Engine
    const initMatchingEngine = await matchingEngine.initialize(
      orderbookFactory.address,
      orderFactory.address
    );

    await executeTx(initMatchingEngine, "Initialize Matching Engine at");


    // initialize Orderbook Factory
    const initOrderbookFactory = await orderbookFactory.initialize(
      "0x0000000000000000000000000000000000000000",
      matchingEngine.address
    );

    await executeTx(initOrderbookFactory, "Initialize Orderbook Factory at");

    // initialize Order Factory
    const initOrderFactory = await orderFactory.initialize(
      "0x0000000000000000000000000000000000000000",
    );

    await executeTx(initOrderFactory, "Initialize Order Factory at");

    // Approve Matching Engine to use tokens
    const approveToken1 = await token1.approve(matchingEngine.address, ethers.utils.parseEther("1000000"));
    await executeTx(approveToken1, "Approve Matching Engine to use Token1 at");
    const approveToken2 = await token2.approve(matchingEngine.address, ethers.utils.parseEther("1000000"));
    await executeTx(approveToken2, "Approve Matching Engine to use Token2 at");

    this.matchingEngine = matchingEngine;
    this.orderFactory = orderFactory;
    this.orderbookFactory = orderbookFactory;
    this.token1 = token1;
    this.token2 = token2;
    this.deployer = deployer;
  });

  it("A orderbook should be able to open a book between two tokens", async function () {
    // create a orderbook
    const addBook = await this.matchingEngine.addBook(
      this.token1.address,
      this.token2.address
    );
    await executeTx(addBook, "Create orderbook at");
    
    const orderbookAddress = await this.matchingEngine.orderbooks(0);
    const orderbook = await ethers.getContractAt("Orderbook", orderbookAddress);
    const token1 = await orderbook.bid();
    const token2 = await orderbook.ask();
    expect(token1).to.equal(this.token1.address);
    expect(token2).to.equal(this.token2.address);

    // Once an orderbook is set between pair, you cannot add another vice versa
  });

  

  it("An orderbook should be able to store bid limit order", async function () {
    const before = await this.token1.balanceOf(this.deployer.address);
    // <base>/<quote>(<token1>/<token2>) = 1.00000000
    const limitSell = await this.matchingEngine.limitSell(this.token1.address, this.token2.address, ethers.utils.parseEther("1000"), 100000000);
    await executeTx(limitSell, "limit sell at");
    const after =  await this.token1.balanceOf(this.deployer.address);
    expect(before.sub(after).toString()).to.equal(ethers.utils.parseEther("997").toString());
  });

  it("An orderbook should be able to store ask limit order and match existing one", async function () {
    const before = await this.token1.balanceOf(this.deployer.address);
    const limitBuy = await this.matchingEngine.limitBuy(this.token1.address, this.token2.address, ethers.utils.parseEther("1000"), 100000000);
    await executeTx(limitBuy, "Limit buy at");
    const after =  await this.token1.balanceOf(this.deployer.address);
  });

  it("An orderbook should be able to store bid order and match existing one", async function () {
    
  });

  it("An orderbook should be able to bid multiple price orders", async function () {
    
  });

  it("An orderbook should be able to ask multiple price orders", async function () {
    
  });

  it("An orderbook should match ask orders to bidOrders at lowestBid then lowest bid should be updated after depleting lowest bid orders", async function () {
    
  });

  it("An orderbook should match bid orders to askOrders at highestAsk then highest ask should be updated after depleting highest ask orders", async function () {
   
  });
});

