// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;
import {IOrderbookFactory} from "./interfaces/IOrderbookFactory.sol";
import {IOrderbook, ExchangeOrderbook} from "./interfaces/IOrderbook.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

enum YieldMode {
    AUTOMATIC,
    VOID,
    CLAIMABLE
}

enum GasMode {
    VOID,
    CLAIMABLE 
}

interface IERC20Rebasing {
  // changes the yield mode of the caller and update the balance
  // to reflect the configuration
  function configure(YieldMode) external returns (uint256);
  // "claimable" yield mode accounts can call this this claim their yield
  // to another address
  function claim(address recipient, uint256 amount) external returns (uint256);
  // read the claimable amount for an account
  function getClaimableAmount(address account) external view returns (uint256);
}

interface IBlast{
    // configure
    function configureContract(address contractAddress, YieldMode _yield, GasMode gasMode, address governor) external;
    function configure(YieldMode _yield, GasMode gasMode, address governor) external;

    // base configuration options
    function configureClaimableYield() external;
    function configureClaimableYieldOnBehalf(address contractAddress) external;
    function configureAutomaticYield() external;
    function configureAutomaticYieldOnBehalf(address contractAddress) external;
    function configureVoidYield() external;
    function configureVoidYieldOnBehalf(address contractAddress) external;
    function configureClaimableGas() external;
    function configureClaimableGasOnBehalf(address contractAddress) external;
    function configureVoidGas() external;
    function configureVoidGasOnBehalf(address contractAddress) external;
    function configureGovernor(address _governor) external;
    function configureGovernorOnBehalf(address _newGovernor, address contractAddress) external;

    // claim yield
    function claimYield(address contractAddress, address recipientOfYield, uint256 amount) external returns (uint256);
    function claimAllYield(address contractAddress, address recipientOfYield) external returns (uint256);

    // claim gas
    function claimAllGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGasAtMinClaimRate(address contractAddress, address recipientOfGas, uint256 minClaimRateBips) external returns (uint256);
    function claimMaxGas(address contractAddress, address recipientOfGas) external returns (uint256);
    function claimGas(address contractAddress, address recipientOfGas, uint256 gasToClaim, uint256 gasSecondsToConsume) external returns (uint256);

    // read functions
    function readClaimableYield(address contractAddress) external view returns (uint256);
    function readYieldConfiguration(address contractAddress) external view returns (uint8);
    function readGasParams(address contractAddress) external view returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode);
}

interface IBlastPoints {
	function configurePointsOperator(address operator) external;
}

interface IRevenue {
    function report(
        uint32 uid,
        address token,
        uint256 amount,
        bool isAdd
    ) external;

    function isReportable(
        address token,
        uint32 uid
    ) external view returns (bool);

    function refundFee(address to, address token, uint256 amount) external;

    function feeOf(uint32 uid, bool isMaker) external returns (uint32 feeNum);
}

interface IDecimals {
    function decimals() external view returns (uint8 decimals);
}

// Onchain Matching engine for the orders
contract MatchingEngine is Initializable, ReentrancyGuard {
    IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);
    // NOTE: these addresses differ on the Blast mainnet and testnet; the lines below are the mainnet addresses
    IERC20Rebasing public constant USDB = IERC20Rebasing(0x4300000000000000000000000000000000000003);
    IERC20Rebasing public constant WETH = IERC20Rebasing(0x4300000000000000000000000000000000000004);
  

    // fee recipient
    address private feeTo;
    // fee denominator
    uint32 public immutable feeDenom = 1000000;
    // Factories
    address public orderbookFactory;
    // WETH
    //address public WETH;
    struct OrderData {
        uint256 withoutFee;
        address orderbook;
        uint256 bidHead;
        uint256 askHead;
        uint256 mp;
        bool clear;
    }

    event OrderDeposit(
        address sender,
        address asset,
        uint256 fee
    );
    
    event OrderCanceled(
        address orderbook,
        uint256 id,
        bool isBid,
        address indexed owner,
        uint256 amount
    );

    /**
    * @dev This event is emitted when an order is successfully matched with a counterparty.
    * @param orderbook The address of the order book contract to get base and quote asset contract address.
    * @param id The unique identifier of the canceled order in bid/ask order database.
    * @param isBid A boolean indicating whether the matched order is a bid (true) or ask (false).
    * @param sender The address initiating the match.
    * @param owner The address of the order owner whose order is matched with the sender.
    * @param price The price at which the order is matched.
    * @param amount The matched amount of the asset being traded in the match. if isBid==true, it is base asset, if isBid==false, it is quote asset.
    */
    event OrderMatched(
        address orderbook,
        uint256 id,
        bool isBid,
        address sender,
        address owner,
        uint256 price,
        uint256 amount
    );

    
    event OrderPlaced(
        address orderbook,
        uint256 id,
        address owner,
        bool isBid,
        uint256 price,
        uint256 amount
    );

    event PairAdded(address orderbook, address base, address quote, uint8 bDecimal, uint8 qDecimal);

    error TooManyMatches(uint256 n);
    error InvalidFeeRate(uint256 feeNum, uint256 feeDenom);
    error NotContract(address newImpl);
    error InvalidRole(bytes32 role, address sender);
    error OrderSizeTooSmall(uint256 amount, uint256 minRequired);
    error NoOrderMade(address base, address quote);
    error InvalidPair(address base, address quote, address pair);
    error NoLastMatchedPrice(address base, address quote);
    error InvalidAccess(address sender, address dev);
    error BidPriceTooLow(uint256 limitPrice, uint256 lmp, uint256 minBidPrice);
    error AskPriceTooHigh(uint256 limitPrice, uint256 lmp, uint256 maxAskPrice);


    constructor() {
        IBlastPoints(0x2536FE9ab3F511540F2f9e2eC2A805005C3Dd800).configurePointsOperator(0x34CCCa03631830cD8296c172bf3c31e126814ce9);
        BLAST.configureClaimableGas(); 
        USDB.configure(YieldMode.AUTOMATIC); //configure claimable yield for USDB
        WETH.configure(YieldMode.AUTOMATIC); //configure claimable yield for WETH
        //IBlast(0x4300000000000000000000000000000000000002).configureVoidYield();
    }

    function configureVoidYield() external {
        if (msg.sender != 0x34CCCa03631830cD8296c172bf3c31e126814ce9)  {
            revert InvalidAccess(msg.sender, 0x34CCCa03631830cD8296c172bf3c31e126814ce9);
        }
        IBlast(0x4300000000000000000000000000000000000002).configureVoidYield();
    }

    function configureAutomaticYield() external {
        if (msg.sender != 0x34CCCa03631830cD8296c172bf3c31e126814ce9)   {
            revert InvalidAccess(msg.sender, 0x34CCCa03631830cD8296c172bf3c31e126814ce9);
        }
        IBlast(0x4300000000000000000000000000000000000002).configureAutomaticYield();
    }

    function configureClaimableYield() external  {
        if (msg.sender != 0x34CCCa03631830cD8296c172bf3c31e126814ce9) {
            revert InvalidAccess(msg.sender, 0x34CCCa03631830cD8296c172bf3c31e126814ce9);
        }
        IBlast(0x4300000000000000000000000000000000000002).configureClaimableYield();
    }

    function claimMyContractsGas() external {
        if (msg.sender != 0x34CCCa03631830cD8296c172bf3c31e126814ce9) {
            revert InvalidAccess(msg.sender, 0x34CCCa03631830cD8296c172bf3c31e126814ce9);
        }
        BLAST.claimAllGas(address(this), msg.sender);
    }

    receive() external payable {
        assert(msg.sender == address(WETH)); // only accept ETH via fallback from the WETH contract
    }

    /**
     * @dev Initialize the matching engine with orderbook factory and listing requirements.
     * It can be called only once.
     * @param orderbookFactory_ address of orderbook factory
     * @param treasury_ address of treasury contract
     * @param WETH_ address of wrapped ether contract
     *
     * Requirements:
     * - `msg.sender` must have the default admin role.
     */
    function initialize(
        address orderbookFactory_,
        address treasury_,
        address WETH_
    ) external initializer {
        orderbookFactory = orderbookFactory_;
        feeTo = treasury_;
        //WETH = WETH_;
    }

    /**
     * @dev Executes a market buy order,
     * buys the base asset using the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param quoteAmount The amount of quote asset to be used for the market buy order
     * @param isMaker Boolean indicating if a order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @param recipient The address of the order owner
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function marketBuy(
        address base,
        address quote,
        uint256 quoteAmount,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        public
        nonReentrant
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        OrderData memory orderData;
        // reuse quoteAmount variable as minRequired from _deposit to avoid stack too deep error
        (orderData.withoutFee, orderData.orderbook) = _deposit(
            base,
            quote,
            0,
            quoteAmount,
            true,
            uid,
            isMaker
        );

        
        orderData.mp = mktPrice(base, quote);

        // reuse withoutFee variable due to stack too deep error
        (orderData.withoutFee, orderData.bidHead, orderData.askHead) = _limitOrder(
            orderData.orderbook,
            orderData.withoutFee,
            quote,
            recipient,
            true,
            orderData.mp * 11/10,
            n
        );

        // add make order on market price
        _detMake(
            base,
            quote,
            orderData.orderbook,
            orderData.withoutFee,
            orderData.mp * 11/10 <= orderData.askHead ? orderData.mp * 11/10 : orderData.askHead == 0 ? orderData.mp * 11/10 : orderData.askHead,
            true,
            isMaker,
            recipient
        );

        return (
            orderData.mp * 11/10 <= orderData.askHead ? orderData.mp * 11/10 : orderData.askHead == 0 ? orderData.mp * 11/10 : orderData.askHead,
            quoteAmount - orderData.withoutFee,
            orderData.withoutFee
        );
    }

    /**
     * @dev Executes a market sell order,
     * sells the base asset for the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param baseAmount The amount of base asset to be sold in the market sell order
     * @param isMaker Boolean indicating if an order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function marketSell(
        address base,
        address quote,
        uint256 baseAmount,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        public
        nonReentrant
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        OrderData memory orderData;
        (orderData.withoutFee, orderData.orderbook) = _deposit(
            base,
            quote,
            0,
            baseAmount,
            false,
            uid,
            isMaker
        );

        orderData.mp = mktPrice(base, quote);

        // reuse withoutFee variable for storing remaining amount after matching due to stack too deep error
        (orderData.withoutFee, orderData.bidHead, orderData.askHead) = _limitOrder(
            orderData.orderbook,
            orderData.withoutFee,
            base,
            recipient,
            false,
            orderData.mp * 9/10,
            n
        );

        _detMake(
            base,
            quote,
            orderData.orderbook,
            orderData.withoutFee,
            orderData.mp * 9/10 >= orderData.bidHead ? orderData.mp * 9/10 : orderData.bidHead,
            false,
            isMaker,
            recipient
        );
        return (
            orderData.mp * 9/10 >= orderData.bidHead ? orderData.mp * 9/10 : orderData.bidHead,
            baseAmount - orderData.withoutFee,
            orderData.withoutFee
        );
    }

    /**
     * @dev Executes a market buy order,
     * buys the base asset using the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price with quote asset as native Ethereum(or other network currencies).
     * @param base The address of the base asset for the trading pair
     * @param isMaker Boolean indicating if a order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @param recipient The address of the recipient to receive traded asset and claim ownership of made order
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function marketBuyETH(
        address base,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        external
        payable
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        IWETH(address(WETH)).deposit{value: msg.value}();
        return marketBuy(base, address(WETH), msg.value, isMaker, n, uid, recipient);
    }

    /**
     * @dev Executes a market sell order,
     * sells the base asset for the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price with base asset as native Ethereum(or other network currencies).
     * @param quote The address of the quote asset for the trading pair
     * @param isMaker Boolean indicating if an order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @param recipient The address of the recipient to receive traded asset and claim ownership of made order
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function marketSellETH(
        address quote,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        external
        payable
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        IWETH(address(WETH)).deposit{value: msg.value}();
        return marketSell(address(WETH), quote, msg.value, isMaker, n, uid, recipient);
    }

    /**
     * @dev Executes a limit buy order,
     * places a limit order in the orderbook for buying the base asset using the quote asset at a specified price,
     * and make an order at the limit price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param quoteAmount The amount of quote asset to be used for the limit buy order
     * @param isMaker Boolean indicating if an order should be made at the limit price
     * @param n The maximum number of orders to match in the orderbook
     * @param recipient The address of the recipient to receive traded asset and claim ownership of made order
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function limitBuy(
        address base,
        address quote,
        uint256 price,
        uint256 quoteAmount,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        public
        nonReentrant
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        OrderData memory orderData;
        (orderData.withoutFee, orderData.orderbook) = _deposit(
            base,
            quote,
            price,
            quoteAmount,
            true,
            uid,
            isMaker
        );
        // reuse withoutFee variable for storing remaining amount after matching due to stack too deep error
        (orderData.withoutFee, orderData.bidHead, orderData.askHead) = _limitOrder(
            orderData.orderbook,
            orderData.withoutFee,
            quote,
            recipient,
            true,
            price,
            n
        );

        _detMake(
            base,
            quote,
            orderData.orderbook,
            orderData.withoutFee,
            orderData.askHead == 0 ? price : price < orderData.askHead ? price : orderData.askHead,
            true,
            isMaker,
            recipient
        );
        return (
            orderData.askHead == 0 ? price : price < orderData.askHead ? price : orderData.askHead,
            quoteAmount - orderData.withoutFee,
            orderData.withoutFee
        );
    }

    /**
     * @dev Executes a limit sell order,
     * places a limit order in the orderbook for selling the base asset for the quote asset at a specified price,
     * and makes an order at the limit price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param baseAmount The amount of base asset to be used for the limit sell order
     * @param isMaker Boolean indicating if an order should be made at the limit price
     * @param n The maximum number of orders to match in the orderbook
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function limitSell(
        address base,
        address quote,
        uint256 price,
        uint256 baseAmount,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        public
        nonReentrant
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        OrderData memory orderData;
        (orderData.withoutFee, orderData.orderbook) = _deposit(
            base,
            quote,
            price,
            baseAmount,
            false,
            uid,
            isMaker
        );
        // reuse withoutFee variable for storing remaining amount after matching due to stack too deep error
        (orderData.withoutFee, orderData.bidHead, orderData.askHead) = _limitOrder(
            orderData.orderbook,
            orderData.withoutFee,
            base,
            recipient,
            false,
            price,
            n
        );
        _detMake(
            base,
            quote,
            orderData.orderbook,
            orderData.withoutFee,
            orderData.bidHead == 0 ? price : price > orderData.bidHead ? price : orderData.bidHead,
            false,
            isMaker,
            recipient
        );
        return (
            orderData.bidHead == 0 ? price : price > orderData.bidHead ? price : orderData.bidHead,
            baseAmount - orderData.withoutFee,
            orderData.withoutFee
        );
    }

    /**
     * @dev Executes a limit buy order,
     * places a limit order in the orderbook for buying the base asset using the quote asset at a specified price,
     * and make an order at the limit price with quote asset as native Ethereum(or network currencies).
     * @param base The address of the base asset for the trading pair
     * @param isMaker Boolean indicating if a order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @param recipient The address of the recipient to receive traded asset and claim ownership of made order
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function limitBuyETH(
        address base,
        uint256 price,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        external
        payable
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        IWETH(address(WETH)).deposit{value: msg.value}();
        return
            limitBuy(base, address(WETH), price, msg.value, isMaker, n, uid, recipient);
    }

    /**
     * @dev Executes a limit sell order,
     * places a limit order in the orderbook for selling the base asset for the quote asset at a specified price,
     * and makes an order at the limit price with base asset as native Ethereum(or network currencies).
     * @param quote The address of the quote asset for the trading pair
     * @param isMaker Boolean indicating if an order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @param recipient The address of the recipient to receive traded asset and claim ownership of made order
     * @return makePrice price where the order is placed
     * @return matched matched amount
     * @return placed placed amount
     */
    function limitSellETH(
        address quote,
        uint256 price,
        bool isMaker,
        uint32 n,
        uint32 uid,
        address recipient
    )
        external
        payable
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        IWETH(address(WETH)).deposit{value: msg.value}();
        return
            limitSell(
                address(WETH),
                quote,
                price,
                msg.value,
                isMaker,
                n,
                uid,
                recipient
            );
    }

    /**
     * @dev Creates an orderbook for a new trading pair and returns its address
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @return book The address of the newly created orderbook
     */
    function addPair(
        address base,
        address quote
    ) public returns (address book) {
        // create orderbook for the pair
        address orderBook = IOrderbookFactory(orderbookFactory).createBook(
            base,
            quote
        );
        uint8 bDecimal = IDecimals(base).decimals();
        uint8 qDecimal = IDecimals(quote).decimals();
        emit PairAdded(orderBook, base, quote, bDecimal, qDecimal);
        return orderBook;
    }

    /**
     * @dev Cancels an order in an orderbook by the given order ID and order type.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param isBid Boolean indicating if the order to cancel is an ask order
     * @param orderId The ID of the order to cancel
     * @return refunded Refunded amount from order
     */
    function cancelOrder(
        address base,
        address quote,
        bool isBid,
        uint32 orderId,
        uint32 uid
    ) public nonReentrant returns (uint256 refunded) {
        address orderbook = IOrderbookFactory(orderbookFactory).getPair(
            base,
            quote
        );

        if (orderbook == address(0)) {
            revert InvalidPair(base, quote, orderbook);
        }

        uint256 remaining = IOrderbook(orderbook).cancelOrder(
            isBid,
            orderId,
            msg.sender
        );
        // decrease point from orderbook
        if (uid != 0 && IRevenue(feeTo).isReportable(msg.sender, uid)) {
            // report cancelation to accountant
            IRevenue(feeTo).report(uid, isBid ? quote : base, remaining, false);
            // refund fee from treasury to sender
            IRevenue(feeTo).refundFee(
                msg.sender,
                isBid ? quote : base,
                (remaining * 100) / feeDenom
            );
        }

        emit OrderCanceled(orderbook, orderId, isBid, msg.sender, remaining);
        return remaining;
    }

    function cancelOrders(
        address[] memory base,
        address[] memory quote,
        bool[] memory isBid,
        uint32[] memory orderIds,
        uint32 uid
    ) external returns (uint256[] memory refunded) {
        refunded = new uint256[](orderIds.length);
        for (uint32 i = 0; i < orderIds.length; i++) {
            refunded[i] = cancelOrder(
                base[i],
                quote[i],
                isBid[i],
                orderIds[i],
                uid
            );
        }
        return refunded;
    }

    /**
     * @dev Cancels an order in an orderbook by the given order ID and order type.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param price The price of the order to rematch
     * @param orderId The ID of the order to cancel
     * @param isBid Boolean indicating if the order to cancel is an ask order
     * @param uid The ID of the user
     * @return makePrice price where the order is placed
     * @return matched matched amount of an order
     * @return placed placed amount of an order
     */
    function rematchOrder(
        address base,
        address quote,
        uint256 price,
        bool isBid,
        uint32 orderId,
        bool isMarket,
        bool isMaker,
        uint32 n,
        uint32 uid
    )
        external
        nonReentrant
        returns (uint256 makePrice, uint256 matched, uint256 placed)
    {
        address orderbook = IOrderbookFactory(orderbookFactory).getPair(
            base,
            quote
        );
        uint256 remaining = IOrderbook(orderbook).cancelOrder(
            isBid,
            orderId,
            msg.sender
        );
        if (isBid) {
            if (isMarket) {
                return
                    marketBuy(
                        base,
                        quote,
                        remaining,
                        isMaker,
                        n,
                        uid,
                        msg.sender
                    );
            } else {
                return
                    limitBuy(
                        base,
                        quote,
                        price,
                        remaining,
                        isMaker,
                        n,
                        uid,
                        msg.sender
                    );
            }
        } else {
            if (isMarket) {
                return
                    marketSell(
                        base,
                        quote,
                        remaining,
                        isMaker,
                        n,
                        uid,
                        msg.sender
                    );
            } else {
                return
                    limitSell(
                        base,
                        quote,
                        price,
                        remaining,
                        isMaker,
                        n,
                        uid,
                        msg.sender
                    );
            }
        }
    }

    /**
     * @dev Returns the address of the orderbook with the given ID.
     * @param id The ID of the orderbook to retrieve.
     * @return The address of the orderbook.
     */
    function getOrderbookById(uint256 id) external view returns (address) {
        return IOrderbookFactory(orderbookFactory).getBook(id);
    }

    /**
     * @dev Returns the base and quote asset addresses for the given orderbook.
     * @param orderbook The address of the orderbook to retrieve the base and quote asset addresses for.
     * @return base The address of the base asset.
     * @return quote The address of the quote asset.
     */
    function getBaseQuote(
        address orderbook
    ) external view returns (address base, address quote) {
        return IOrderbookFactory(orderbookFactory).getBaseQuote(orderbook);
    }
    
    /**
     * @dev returns addresses of pairs in OrderbookFactory registry
     * @return pairs list of pairs from start to end
     */
    function getPairs(
        uint256 start,
        uint256 end
    ) external view returns (IOrderbookFactory.Pair[] memory pairs) {
        return IOrderbookFactory(orderbookFactory).getPairs(start, end);
    }

    /**
     * @dev returns addresses of pairs in OrderbookFactory registry
     * @return pairs list of pairs from start to end
     */
    function getPairsWithIds(
        uint256[] memory ids
    ) external view returns (IOrderbookFactory.Pair[] memory pairs) {
        return IOrderbookFactory(orderbookFactory).getPairsWithIds(ids);
    }

    /**
     * @dev returns addresses of pairs in OrderbookFactory registry
     * @return names list of pair names from start to end
     */
    function getPairNames(
        uint256 start,
        uint256 end
    ) external view returns (string[] memory names) {
        return IOrderbookFactory(orderbookFactory).getPairNames(start, end);
    }

    /**
     * @dev returns addresses of pairs in OrderbookFactory registry
     * @return names list of pair names from start to end
     */
    function getPairNamesWithIds(
        uint256[] memory ids
    ) external view returns (string[] memory names) {
        return IOrderbookFactory(orderbookFactory).getPairNamesWithIds(ids);
    }

    /**
     * @dev returns addresses of pairs in OrderbookFactory registry
     * @return mktPrices list of mktPrices from start to end
     */
    function getMktPrices(
        uint256 start,
        uint256 end
    ) external view returns (uint256[] memory mktPrices) {
        IOrderbookFactory.Pair[] memory pairs = IOrderbookFactory(
            orderbookFactory
        ).getPairs(start, end);
        mktPrices = new uint256[](pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            try this.mktPrice(pairs[i].base, pairs[i].quote) returns (
                uint256 price
            ) {
                uint256 p = price;
                mktPrices[i] = p;
            } catch {
                uint256 p = 0;
                mktPrices[i] = p;
            }
        }
        return mktPrices;
    }

    /**
     * @dev returns addresses of pairs in OrderbookFactory registry
     * @return mktPrices list of mktPrices from start to end
     */
    function getMktPricesWithIds(
        uint256[] memory ids
    ) external view returns (uint256[] memory mktPrices) {
        IOrderbookFactory.Pair[] memory pairs = IOrderbookFactory(
            orderbookFactory
        ).getPairsWithIds(ids);
        mktPrices = new uint256[](pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            try this.mktPrice(pairs[i].base, pairs[i].quote) returns (
                uint256 price
            ) {
                uint256 p = price;
                mktPrices[i] = p;
            } catch {
                uint256 p = 0;
                mktPrices[i] = p;
            }
        }
        return mktPrices;
    }

    /**
     * @dev Returns prices in the ask/bid orderbook for the given trading pair.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve prices from is an ask orderbook.
     * @param n The number of prices to retrieve.
     */
    function getPrices(
        address base,
        address quote,
        bool isBid,
        uint32 n
    ) external view returns (uint256[] memory) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).getPrices(isBid, n);
    }

    function getPricesPaginated(
        address base,
        address quote,
        bool isBid,
        uint32 start,
        uint32 end
    ) external view returns (uint256[] memory) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).getPricesPaginated(isBid, start, end);
    }

    /**
     * @dev Returns orders in the ask/bid orderbook for the given trading pair in a price.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve orders from is an ask orderbook.
     * @param price The price to retrieve orders from.
     * @param n The number of orders to retrieve.
     */
    function getOrders(
        address base,
        address quote,
        bool isBid,
        uint256 price,
        uint32 n
    ) external view returns (ExchangeOrderbook.Order[] memory) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).getOrders(isBid, price, n);
    }

    function getOrdersPaginated(
        address base,
        address quote,
        bool isBid,
        uint256 price,
        uint32 start,
        uint32 end
    ) external view returns (ExchangeOrderbook.Order[] memory) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).getOrdersPaginated(isBid, price, start, end);
    }

    /**
     * @dev Returns an order in the ask/bid orderbook for the given trading pair with order id.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve orders from is an ask orderbook.
     * @param orderId The order id to retrieve.
     */
    function getOrder(
        address base,
        address quote,
        bool isBid,
        uint32 orderId
    ) external view returns (ExchangeOrderbook.Order memory) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).getOrder(isBid, orderId);
    }

    /**
     * @dev Returns order ids in the ask/bid orderbook for the given trading pair in a price.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve orders from is an ask orderbook.
     * @param price The price to retrieve orders from.
     * @param n The number of order ids to retrieve.
     */
    function getOrderIds(
        address base,
        address quote,
        bool isBid,
        uint256 price,
        uint32 n
    ) external view returns (uint32[] memory) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).getOrderIds(isBid, price, n);
    }

    /**
     * @dev Returns the address of the orderbook for the given base and quote asset addresses.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @return book The address of the orderbook.
     */
    function getPair(
        address base,
        address quote
    ) public view returns (address book) {
        return IOrderbookFactory(orderbookFactory).getPair(base, quote);
    }

    function heads(
        address base,
        address quote
    ) external view returns (uint256 bidHead, uint256 askHead) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).heads();
    }

    function mktPrice(
        address base,
        address quote
    ) public view returns (uint256) {
        address orderbook = getPair(base, quote);
        return IOrderbook(orderbook).mktPrice();
    }

    /**
     * @dev return converted amount from base to quote or vice versa
     * @param base address of base asset
     * @param quote address of quote asset
     * @param amount amount of base or quote asset
     * @param isBid if true, amount is quote asset, otherwise base asset
     * @return converted converted amount from base to quote or vice versa.
     * if true, amount is quote asset, otherwise base asset
     * if orderbook does not exist, return 0
     */
    function convert(
        address base,
        address quote,
        uint256 amount,
        bool isBid
    ) public view returns (uint256 converted) {
        address orderbook = getPair(base, quote);
        if (base == quote) {
            return amount;
        } else if (orderbook == address(0)) {
            return 0;
        } else {
            return IOrderbook(orderbook).assetValue(amount, isBid);
        }
    }

    /**
     * @dev Internal function which makes an order on the orderbook.
     * @param orderbook The address of the orderbook contract for the trading pair
     * @param withoutFee The remaining amount of the asset after the market order has been executed
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param isBid Boolean indicating if the order is a buy (false) or a sell (true)
     * @param recipient The address of the recipient to receive traded asset and claim ownership of made order
     */
    function _makeOrder(
        address orderbook,
        uint256 withoutFee,
        uint256 price,
        bool isBid,
        address recipient
    ) internal {
        uint32 id;
        // create order
        if (isBid) {
            id = IOrderbook(orderbook).placeBid(recipient, price, withoutFee);
        } else {
            id = IOrderbook(orderbook).placeAsk(recipient, price, withoutFee);
        }

        emit OrderPlaced(orderbook, id, recipient, isBid, price, withoutFee);
    }

    /**
     * @dev Match bid if `isBid` is true, match ask if `isBid` is false.
     */
    function _matchAt(
        address orderbook,
        address give,
        address recipient,
        bool isBid,
        uint256 amount,
        uint256 price,
        uint32 i,
        uint32 n
    ) internal returns (uint256 remaining, uint32 k) {
        if (n > 20) {
            revert TooManyMatches(n);
        }
        remaining = amount;
        while (
            remaining > 0 &&
            !IOrderbook(orderbook).isEmpty(!isBid, price) &&
            i < n
        ) {
            // fpop OrderLinkedList by price, if ask you get bid order, if bid you get ask order. Get quote asset on bid order on buy, base asset on ask order on sell
            (uint32 orderId, uint256 required, bool clear) = IOrderbook(orderbook).fpop(
                !isBid,
                price,
                remaining
            );
            // order exists, and amount is not 0
            if (remaining <= required) {
                // set last matching price
                IOrderbook(orderbook).setLmp(price);
                // execute order
                TransferHelper.safeTransfer(give, orderbook, remaining);
                address owner = IOrderbook(orderbook).execute(
                    orderId,
                    !isBid,
                    recipient,
                    remaining,
                    clear
                );
                // emit event order matched
                emit OrderMatched(
                    orderbook,
                    orderId,
                    isBid,
                    recipient,
                    owner,
                    price,
                    remaining
                );
                // end loop as remaining is 0
                return (0, n);
            }
            // order is null
            else if (required == 0) {
                ++i;
                continue;
            }
            // remaining >= depositAmount
            else {
                remaining -= required;
                TransferHelper.safeTransfer(give, orderbook, required);
                address owner = IOrderbook(orderbook).execute(
                    orderId,
                    !isBid,
                    recipient,
                    required,
                    clear
                );
                // emit event order matched
                emit OrderMatched(
                    orderbook,
                    orderId,
                    isBid,
                    recipient,
                    owner,
                    price,
                    required
                );
                ++i;
            }
        }
        k = i;
        return (remaining, k);
    }

    /**
     * @dev Executes limit order by matching orders in the orderbook based on the provided limit price.
     * @param orderbook The address of the orderbook to execute the limit order on.
     * @param amount The amount of asset to trade.
     * @param give The address of the asset to be traded.
     * @param recipient The address to receive asset after matching a trade
     * @param isBid True if the order is an ask (sell) order, false if it is a bid (buy) order.
     * @param limitPrice The maximum price at which the order can be executed.
     * @param n The maximum number of matches to execute.
     * @return remaining The remaining amount of asset that was not traded.
     */
    function _limitOrder(
        address orderbook,
        uint256 amount,
        address give,
        address recipient,
        bool isBid,
        uint256 limitPrice,
        uint32 n
    ) internal returns (uint256 remaining, uint256 bidHead, uint256 askHead) {
        remaining = amount;
        uint256 lmp = IOrderbook(orderbook).lmp();
        uint32 i = 0;
        if (isBid) {
            // check limit bid price is within 10% spread of last matched price
            if (lmp != 0 && limitPrice < lmp * 9 /10) {
                revert BidPriceTooLow(limitPrice, lmp, lmp * 9/10);
            }
            // check if there is any matching ask order until matching ask order price is lower than the limit bid Price
            askHead = IOrderbook(orderbook).clearEmptyHead(false);
            while (
                remaining > 0 && askHead != 0 && askHead <= limitPrice && i < n
            ) {
                lmp = askHead;
                (remaining, i) = _matchAt(
                    orderbook,
                    give,
                    recipient,
                    isBid,
                    remaining,
                    askHead,
                    i,
                    n
                );
                // i == 0 when orders are all empty and only head price is left
                askHead = i == 0
                    ? 0
                    : IOrderbook(orderbook).clearEmptyHead(false);
            }
            // set last match price
            if (lmp != 0) {
                IOrderbook(orderbook).setLmp(lmp);
            } else {
                // when ask book is empty, get bid head as last matching price
                lmp = IOrderbook(orderbook).clearEmptyHead(true);
            }
            return (remaining, lmp, askHead); // return bidHead, and askHead
        } else {
            // check limit ask price is within 10% spread of last matched price
            if(lmp != 0 && limitPrice > lmp * 11 / 10 ) {
                revert AskPriceTooHigh(limitPrice, lmp, lmp * 11 / 10);
            }
            // check if there is any maching bid order until matching bid order price is higher than the limit ask price
            bidHead = IOrderbook(orderbook).clearEmptyHead(true);
            while (
                remaining > 0 && bidHead != 0 && bidHead >= limitPrice && i < n
            ) {
                lmp = bidHead;
                (remaining, i) = _matchAt(
                    orderbook,
                    give,
                    recipient,
                    isBid,
                    remaining,
                    bidHead,
                    i,
                    n
                );
                // i == 0 when orders are all empty and only head price is left
                bidHead = i == 0
                    ? 0
                    : IOrderbook(orderbook).clearEmptyHead(true);
            }
            // set last match price
            if (lmp != 0) {
                IOrderbook(orderbook).setLmp(lmp);
            } else {
                // when bid book is empty, get ask head as last matching price
                lmp = IOrderbook(orderbook).clearEmptyHead(false);
            }
            return (remaining, bidHead, lmp); // return bidHead, askHead
        }
    }

    /**
     * @dev Determines if an order can be made at the market price,
     * and if so, makes the an order on the orderbook.
     * If an order cannot be made, transfers the remaining asset to either the orderbook or the user.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param orderbook The address of the orderbook contract for the trading pair
     * @param remaining The remaining amount of the asset after the market order has been taken
     * @param price The price used to determine if an order can be made
     * @param isBid Boolean indicating if the order was a buy (true) or a sell (false)
     * @param isMaker Boolean indicating if an order is for storing in orderbook
     * @param recipient The address to receive asset after matching a trade and making an order
     */
    function _detMake(
        address base,
        address quote,
        address orderbook,
        uint256 remaining,
        uint256 price,
        bool isBid,
        bool isMaker,
        address recipient
    ) internal {
        if (remaining > 0) {
            address stopTo = isMaker ? orderbook : recipient;
            TransferHelper.safeTransfer(
                isBid ? quote : base,
                stopTo,
                remaining
            );
            if (isMaker)
                _makeOrder(orderbook, remaining, price, isBid, recipient);
        }
    }

    /**
     * @dev Deposit amount of asset to the contract with the given asset information and subtracts the fee.
     * @param base The address of the base asset.
     * @param quote The address of the quote asset.
     * @param amount The amount of asset to deposit.
     * @param isBid Whether it is an ask order or not.
     * If ask, the quote asset is transferred to the contract.
     * @return withoutFee The amount of asset without the fee.
     * @return book The address of the orderbook for the given asset pair.
     */
    function _deposit(
        address base,
        address quote,
        uint256 price,
        uint256 amount,
        bool isBid,
        uint32 uid,
        bool isMaker
    ) internal returns (uint256 withoutFee, address book) {
        // get orderbook address from the base and quote asset
        book = getPair(base, quote);
        if (book == address(0)) {
            book = addPair(base, quote);
        }
        // check if amount is valid in case of both market and limit
        uint256 converted = _convert(book, price, amount, !isBid);
        uint256 minRequired = _convert(book, price, 1, !isBid);

        if (converted <= minRequired) {
            revert OrderSizeTooSmall(amount, minRequired);
        }
        // check if sender has uid
        uint256 fee = _fee(base, quote, amount, isBid, uid, isMaker);
        withoutFee = amount - fee;
        if (isBid) {
            // transfer input asset give user to this contract
            if (quote != address(WETH)) {
                TransferHelper.safeTransferFrom(
                    quote,
                    msg.sender,
                    address(this),
                    amount
                );
            }
            TransferHelper.safeTransfer(quote, feeTo, fee);
        } else {
            // transfer input asset give user to this contract
            if (base != address(WETH)) {
                TransferHelper.safeTransferFrom(
                    base,
                    msg.sender,
                    address(this),
                    amount
                );
            }
            TransferHelper.safeTransfer(base, feeTo, fee);
        }
        emit OrderDeposit(msg.sender, isBid ? quote : base, fee);
        return (withoutFee, book);
    }

    function _fee(
        address base,
        address quote,
        uint256 amount,
        bool isBid,
        uint32 uid,
        bool isMaker
    ) internal returns (uint256 fee) {
        if (uid != 0 && IRevenue(feeTo).isReportable(msg.sender, uid)) {
            uint32 feeNum = IRevenue(feeTo).feeOf(uid, isMaker);
            // report fee to accountant
            IRevenue(feeTo).report(uid, isBid ? quote : base, amount, true);
            return (amount * feeNum) / feeDenom;
        } else {
            return amount / 100;
        }
    }

    /**
     * @dev return converted amount from base to quote or vice versa
     * @param orderbook address of orderbook
     * @param price price of base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote) proposed by a trader
     * @param amount amount of base or quote asset
     * @param isBid if true, amount is quote asset, otherwise base asset
     * @return converted converted amount from base to quote or vice versa.
     * if true, amount is quote asset, otherwise base asset
     * if orderbook does not exist, return 0
     */
    function _convert(
        address orderbook,
        uint256 price,
        uint256 amount,
        bool isBid
    ) internal view returns (uint256 converted) {
        if (orderbook == address(0)) {
            return 0;
        } else {
            return
                price == 0
                    ? IOrderbook(orderbook).assetValue(amount, isBid)
                    : IOrderbook(orderbook).convert(price, amount, isBid);
        }
    }

}
