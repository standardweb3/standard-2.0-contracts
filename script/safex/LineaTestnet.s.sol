// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockBTC} from "../../contracts/mock/MockBTC.sol";
import {SABT} from "../../contracts/sabt/SABT.sol";
import {BlockAccountant} from "../../contracts/sabt/BlockAccountant.sol";
import {Membership} from "../../contracts/sabt/Membership.sol";
import {Treasury} from "../../contracts/sabt/Treasury.sol";
import {MockToken} from "../../contracts/mock/MockToken.sol";
import {MatchingEngine} from "../../contracts/safex/MatchingEngine.sol";
import {OrderbookFactory} from "../../contracts/safex/orderbooks/OrderbookFactory.sol";
import {Multicall3} from "../Multicall3.sol";

contract Deployer is Script {
    function _setDeployer() internal {
        uint256 deployerPrivateKey = vm.envUint(
            "LINEA_TESTNET_DEPLOYER_KEY"
        );
        vm.startBroadcast(deployerPrivateKey);
    }
}

contract DeployMulticall3 is Deployer {
    function run() external {
        _setDeployer();
        new Multicall3();
        vm.stopBroadcast();
    }
}

contract DeployWETH is Deployer {
    function run() external {
        _setDeployer();
        vm.stopBroadcast();
    }
}

contract DeployTestnetAssetsAndContracts is Deployer {
    // Change address constants on deploying to other networks from DeployAssets
    /// Second per block to finalize
    uint32 constant spb = 12;
    address constant deployer_address = 0x34CCCa03631830cD8296c172bf3c31e126814ce9;
    address constant foundation_address = 0x34CCCa03631830cD8296c172bf3c31e126814ce9;
    address constant weth = 0x2C1b868d6596a18e32E61B901E4060C872647b6C;

    function run() external {
        _setDeployer();
        MockToken feeToken = new MockToken("Standard", "STND");
        MockToken stablecoin = new MockToken("Stablecoin", "STBC");
        OrderbookFactory orderbookFactory = new OrderbookFactory();
        MatchingEngine matchingEngine = new MatchingEngine();
        Membership membership = new Membership();
        SABT sabt = new SABT();
        membership.initialize(address(sabt), foundation_address);
        sabt.initialize(address(membership));
        // Setup accountant and treasury
        BlockAccountant accountant = new BlockAccountant();
        accountant.initialize(
            address(membership),
            address(matchingEngine),
            address(stablecoin),
            spb);
        Treasury treasury = new Treasury();
        treasury.initialize(address(accountant), address(sabt));
        matchingEngine.initialize(
            address(orderbookFactory),
            address(membership),
            address(accountant),
            address(treasury)
        );
        orderbookFactory.initialize(
            address(matchingEngine)
        );
        // Wire up matching engine with them
        accountant.grantRole(
            accountant.REPORTER_ROLE(),
            address(matchingEngine)
        );
        treasury.grantRole(treasury.REPORTER_ROLE(), address(matchingEngine));
        vm.stopBroadcast();
    }
}

contract DistributeTestnetAssets is Deployer {
    // Change address constants on deploying to other networks from DeployAssets
    address constant deployer_address = 0x34CCCa03631830cD8296c172bf3c31e126814ce9;
    address constant trader1_address =   0x6408fb579e106fC59f964eC33FE123738A2D0Da3;
    address constant trader2_address =   0xf5aE3B9dF4e6972a229E7915D55F9FBE5900fE95;
    address constant feeToken_address =0x0622C0b5F53FF7252A5F90b4031a9adaa67a2d02;
    address constant stablecoin_address = 0x11a681c574F8e1d72DDCEEe0855032A77dfF8355;

    MockToken public feeToken = MockToken(feeToken_address);
    MockToken public stablecoin = MockToken(stablecoin_address);

    function run() external {
        _setDeployer();
        // Mint fee Token to the deployer, trader1, trader2
        feeToken.mint(deployer_address,  1000000000000000000000000e18);
        feeToken.mint(trader1_address, 100000e18);
        feeToken.mint(trader2_address, 100000e18);

        // Mint stablecoin to the deployer, trader1, trader2
        stablecoin.mint(deployer_address, 100000e18);
        stablecoin.mint(trader1_address, 100000e18);
        stablecoin.mint(trader2_address, 100000e18);

        vm.stopBroadcast();
    }
}

contract SetupSABTInitialParameters is Deployer {
    // Change address constants on deploying to other networks from DeployAssets
    address constant matching_engine_address = 0xefe1D86c7A755Aa9890De8b7B64116d362Bb2fef;
    address constant membership_address = 0x172639ddC5433C00566Fd9e4c0D03761398e0e5D;
    address constant sabt_address = 0xAbE19aC56A8d813E8bf64d84caaF596a0Ece11C1;
    address constant feeToken_address = 0x0622C0b5F53FF7252A5F90b4031a9adaa67a2d02;
    address constant stablecoin_address =  0x11a681c574F8e1d72DDCEEe0855032A77dfF8355;
    address constant block_accountant_address = 0x116aC51bE4414332b6bbe1221cEF11FdaFdDD563;
    address constant treasury_address = 0xeFC59eC7cCB585b68B831B94B5184184E8407b0a;
    address constant deployer_address = 0x34CCCa03631830cD8296c172bf3c31e126814ce9;

    Membership public membership = Membership(membership_address);
    SABT public sabt = SABT(sabt_address);
    MockToken public stablecoin = MockToken(stablecoin_address);
    MockToken public feeToken = MockToken(feeToken_address);
    BlockAccountant public accountant =
        BlockAccountant(block_accountant_address);
    Treasury public treasury = Treasury(treasury_address);

    function run() external {
        _setDeployer();
        // set Fee in membership contract
        membership.setMembership(1, feeToken_address, 1000, 1000, 10000);

        // Get membership
        feeToken.approve(membership_address, 1e30);
        membership.register(1, feeToken_address);
        membership.subscribe(1, 1000000, feeToken_address);

        vm.stopBroadcast();
    }
}

contract SetupSAFEXInitialParameters is Deployer {
    // Change address constants on deploying to other networks from DeployAssets
    address constant matching_engine_address = 0xBB1A3D1a266c23B1ee8e6Cb3Fe1e1dfA57840c37;
    address constant feeToken_address = 0xE57Cdf5796C2f5281EDF1B81129E1D4Ff9190815;
    address constant stablecoin_address = 0xfB4c8b2658AB2bf32ab5Fc1627f115974B52FeA7;
    MatchingEngine public matchingEngine =
        MatchingEngine(matching_engine_address);
    MockToken public feeToken = MockToken(feeToken_address);
    MockToken public stablecoin = MockToken(stablecoin_address);

    function run() external {
        _setDeployer();
        // Setup pair between stablecoin and feeToken with price
        feeToken.approve(address(matchingEngine), 100000e18);
        matchingEngine.addPair(address(feeToken), address(stablecoin));

        // make a price in matching engine where 1 feeToken = 1000 stablecoin with buy and sell order
        feeToken.approve(address(matchingEngine), 100000e18);
        stablecoin.approve(address(matchingEngine), 100000e18);
        // add limit orders
        matchingEngine.limitSell(
            address(feeToken),
            address(stablecoin),
            1000e8,
            10000e18,
            true,
            1,
            0
        );
        matchingEngine.limitBuy(
            address(feeToken),
            address(stablecoin),
            1000e8,
            10000e18,
            false,
            1,
            1
        );
        vm.stopBroadcast();
    }
}