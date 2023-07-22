// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IOrderbookFactory} from "./interfaces/IOrderbookFactory.sol";
import {IOrderbook, SAFEXOrderbook} from "./interfaces/IOrderbook.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface IRevenue {
    function report(uint32 uid, address token, uint256 amount, bool isAdd) external;

    function isReportable(address token, uint32 uid) external view returns (bool);

    function refundFee(address to, address token, uint256 amount) external;

    function feeOf(uint32 uid, bool isMaker) external returns (uint32 feeNum);
}

// Onchain Matching engine for the orders
contract MatchingEngine is AccessControl, Initializable {
    // fee recipient
    address private feeTo;
    // fee denominator
    uint32 public immutable feeDenom = 1000000;
    // Factories
    address public orderbookFactory;
    // membership contract
    address public membership;
    // accountant contract
    address public accountant;

    // events
    event OrderCanceled(address orderbook, uint256 id, bool isBid, address owner);

    event OrderMatched(
        address orderbook, uint256 id, bool isBid, address sender, address owner, uint256 amount, uint256 price
    );

    event PairAdded(address orderbook, address base, address quote);

    error TooManyMatches(uint256 n);
    error InvalidFeeRate(uint256 feeNum, uint256 feeDenom);
    error NotContract(address newImpl);
    error InvalidRole(bytes32 role, address sender);

    constructor() {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Initialize the matching engine with orderbook factory and listing requirements.
     * It can be called only once.
     * @param orderbookFactory_ address of orderbook factory
     * @param membership_ membership contract address
     * @param accountant_ accountant contract address
     * @param treasury_ treasury to collect fees
     *
     * Requirements:
     * - `msg.sender` must have the default admin role.
     */
    function initialize(address orderbookFactory_, address membership_, address accountant_, address treasury_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        initializer
    {
        orderbookFactory = orderbookFactory_;
        membership = membership_;
        accountant = accountant_;
        feeTo = treasury_;
    }

    /**
     * @dev Executes a market buy order,
     * buys the base asset using the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param amount The amount of quote asset to be used for the market buy order
     * @param isMaker Boolean indicating if a order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @return bool True if the order was successfully executed, otherwise false.
     */
    function marketBuy(address base, address quote, uint256 amount, bool isMaker, uint32 n, uint32 uid)
        external
        returns (bool)
    {
        (uint256 withoutFee, address orderbook) = _deposit(base, quote, amount, true, uid, isMaker);
        // negate on give if the asset is not the base
        uint256 remaining = _limitOrder(orderbook, withoutFee, quote, true, type(uint256).max, n);
        // add make order on market price
        _detMake(orderbook, quote, remaining, mktPrice(base, quote), true, isMaker);
        return true;
    }

    /**
     * @dev Executes a market sell order,
     * sells the base asset for the quote asset at the best available price in the orderbook up to `n` orders,
     * and make an order at the market price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param amount The amount of base asset to be sold in the market sell order
     * @param isMaker Boolean indicating if an order should be made at the market price in orderbook
     * @param n The maximum number of orders to match in the orderbook
     * @return bool True if the order was successfully executed, otherwise false.
     */
    function marketSell(address base, address quote, uint256 amount, bool isMaker, uint32 n, uint32 uid)
        external
        returns (bool)
    {
        (uint256 withoutFee, address orderbook) = _deposit(base, quote, amount, false, uid, isMaker);
        // negate on give if the asset is not the base
        uint256 remaining = _limitOrder(orderbook, withoutFee, base, false, type(uint256).max, n);
        _detMake(orderbook, base, remaining, mktPrice(base, quote), false, isMaker);
        return true;
    }

    /**
     * @dev Executes a limit buy order,
     * places a limit order in the orderbook for buying the base asset using the quote asset at a specified price,
     * and make an order at the limit price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param amount The amount of quote asset to be used for the limit buy order
     * @param isMaker Boolean indicating if an order should be made at the limit price
     * @param n The maximum number of orders to match in the orderbook
     * @return bool True if the order was successfully executed, otherwise false.
     */
    function limitBuy(address base, address quote, uint256 price, uint256 amount, bool isMaker, uint32 n, uint32 uid)
        external
        returns (bool)
    {
        (uint256 withoutFee, address orderbook) = _deposit(base, quote, amount, true, uid, isMaker);
        uint256 remaining = _limitOrder(orderbook, withoutFee, quote, true, price, n);

        _detMake(orderbook, quote, remaining, price, true, isMaker);
        return true;
    }

    /**
     * @dev Executes a limit sell order,
     * places a limit order in the orderbook for selling the base asset for the quote asset at a specified price,
     * and makes an order at the limit price.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param amount The amount of base asset to be used for the limit sell order
     * @param isMaker Boolean indicating if an order should be made at the limit price
     * @param n The maximum number of orders to match in the orderbook
     * @return bool True if the order was successfully executed, otherwise false.
     */
    function limitSell(address base, address quote, uint256 price, uint256 amount, bool isMaker, uint32 n, uint32 uid)
        external
        returns (bool)
    {
        (uint256 withoutFee, address orderbook) = _deposit(base, quote, amount, false, uid, isMaker);
        uint256 remaining = _limitOrder(orderbook, withoutFee, base, false, price, n);
        _detMake(orderbook, base, remaining, price, false, isMaker);
        return true;
    }

    /**
     * @dev Stores a bid order in the orderbook for the base asset using the quote asset,
     * with a specified price `at`.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param amount The amount of quote asset to be used for the bid order
     * @return bool True if the order was successfully executed, otherwise false.
     */
    function makeBuy(address base, address quote, uint256 price, uint256 amount, uint32 uid) external returns (bool) {
        (uint256 withoutFee, address orderbook) = _deposit(base, quote, amount, false, uid, true);
        TransferHelper.safeTransfer(quote, orderbook, withoutFee);
        _makeOrder(orderbook, withoutFee, price, true);
        return true;
    }

    /**
     * @dev Stores an ask order in the orderbook for the quote asset using the base asset,
     * with a specified price `at`.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param price The price, base/quote regardless of decimals of the assets in the pair represented with 8 decimals (if 1000, base is 1000x quote)
     * @param amount The amount of base asset to be used for making ask order
     * @return bool True if the order was successfully executed, otherwise false.
     */
    function makeSell(address base, address quote, uint256 price, uint256 amount, uint32 uid) external returns (bool) {
        (uint256 withoutFee, address orderbook) = _deposit(base, quote, amount, false, uid, true);
        TransferHelper.safeTransfer(base, orderbook, withoutFee);
        _makeOrder(orderbook, withoutFee, price, false);
        return true;
    }

    /**
     * @dev Creates an orderbook for a new trading pair and returns its address
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @return book The address of the newly created orderbook
     */
    function addPair(address base, address quote) external returns (address book) {
        // create orderbook for the pair
        address orderBook = IOrderbookFactory(orderbookFactory).createBook(base, quote);
        emit PairAdded(orderBook, base, quote);
        return orderBook;
    }

    /**
     * @dev Cancels an order in an orderbook by the given order ID and order type.
     * @param base The address of the base asset for the trading pair
     * @param quote The address of the quote asset for the trading pair
     * @param orderId The ID of the order to cancel
     * @param isBid Boolean indicating if the order to cancel is an ask order
     * @return bool True if the order was successfully canceled, otherwise false.
     */
    function cancelOrder(address base, address quote, uint256 price, uint256 orderId, bool isBid, uint32 uid)
        external
        returns (bool)
    {
        address orderbook = IOrderbookFactory(orderbookFactory).getBookByPair(base, quote);
        (uint256 remaining, address _base, address _quote) =
            IOrderbook(orderbook).cancelOrder(isBid, price, orderId, msg.sender);
        // decrease point from orderbook
        if (uid != 0 && IRevenue(membership).isReportable(msg.sender, uid)) {
            // report cancelation to accountant
            IRevenue(accountant).report(uid, isBid ? quote : base, remaining, false);
            // refund fee from treasury to sender
            IRevenue(feeTo).refundFee(msg.sender, isBid ? quote : base, (remaining * 100) / feeDenom);
        }

        emit OrderCanceled(orderbook, orderId, isBid, msg.sender);
        return true;
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
    function getBaseQuote(address orderbook) external view returns (address base, address quote) {
        return IOrderbookFactory(orderbookFactory).getBaseQuote(orderbook);
    }

    /**
     * @dev returns addresses of pairs in OrderbookFactory registry
     * @return pairs list of pairs from start to end
     */
    function getPairs(uint256 start, uint256 end) external view returns (IOrderbookFactory.Pair[] memory pairs) {
        return IOrderbookFactory(orderbookFactory).getPairs(start, end);
    }

    /**
     * @dev Returns prices in the ask/bid orderbook for the given trading pair.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve prices from is an ask orderbook.
     * @param n The number of prices to retrieve.
     */
    function getPrices(address base, address quote, bool isBid, uint256 n) external view returns (uint256[] memory) {
        address orderbook = getBookByPair(base, quote);
        return IOrderbook(orderbook).getPrices(isBid, n);
    }

    /**
     * @dev Returns orders in the ask/bid orderbook for the given trading pair in a price.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve orders from is an ask orderbook.
     * @param price The price to retrieve orders from.
     * @param n The number of orders to retrieve.
     */
    function getOrders(address base, address quote, bool isBid, uint256 price, uint256 n)
        external
        view
        returns (SAFEXOrderbook.Order[] memory)
    {
        address orderbook = getBookByPair(base, quote);
        return IOrderbook(orderbook).getOrders(isBid, price, n);
    }

    /**
     * @dev Returns an order in the ask/bid orderbook for the given trading pair with order id.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @param isBid Boolean indicating if the orderbook to retrieve orders from is an ask orderbook.
     * @param orderId The order id to retrieve.
     */
    function getOrder(address base, address quote, bool isBid, uint256 orderId)
        external
        view
        returns (SAFEXOrderbook.Order memory)
    {
        address orderbook = getBookByPair(base, quote);
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
    function getOrderIds(address base, address quote, bool isBid, uint256 price, uint256 n)
        external
        view
        returns (uint256[] memory)
    {
        address orderbook = getBookByPair(base, quote);
        return IOrderbook(orderbook).getOrderIds(isBid, price, n);
    }

    /**
     * @dev Returns the address of the orderbook for the given base and quote asset addresses.
     * @param base The address of the base asset for the trading pair.
     * @param quote The address of the quote asset for the trading pair.
     * @return book The address of the orderbook.
     */
    function getBookByPair(address base, address quote) public view returns (address book) {
        return IOrderbookFactory(orderbookFactory).getBookByPair(base, quote);
    }

    function mktPrice(address base, address quote) public view returns (uint256) {
        address orderbook = getBookByPair(base, quote);
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
    function convert(address base, address quote, uint256 amount, bool isBid)
        external
        view
        returns (uint256 converted)
    {
        address orderbook = getBookByPair(base, quote);
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
     */
    function _makeOrder(address orderbook, uint256 withoutFee, uint256 price, bool isBid) internal {
        // create order
        if (isBid) {
            IOrderbook(orderbook).placeBid(msg.sender, price, withoutFee);
        } else {
            IOrderbook(orderbook).placeAsk(msg.sender, price, withoutFee);
        }
    }

    /**
     * @dev Match bid if `isBid` is true, match ask if `isBid` is false.
     */
    function _matchAt(address orderbook, address give, bool isBid, uint256 amount, uint256 price, uint32 i, uint32 n)
        internal
        returns (uint256 remaining, uint32 k)
    {
        if (n >= 20) {
            revert TooManyMatches(n);
        }
        remaining = amount;
        while (remaining > 0 && !IOrderbook(orderbook).isEmpty(!isBid, price) && i < n) {
            // fpop OrderLinkedList by price, if ask you get bid order, if bid you get ask order
            uint256 orderId = IOrderbook(orderbook).fpop(!isBid, price);
            // Get quote asset on bid order on buy, base asset on ask order on sell
            uint256 required = IOrderbook(orderbook).getRequired(!isBid, price, orderId);
            // order exists, and amount is not 0
            if (remaining <= required) {
                TransferHelper.safeTransfer(give, orderbook, remaining);
                address owner = IOrderbook(orderbook).execute(orderId, !isBid, price, msg.sender, remaining);
                // emit event order matched
                emit OrderMatched(orderbook, orderId, isBid, msg.sender, owner, remaining, price);
                // set last match price
                // end loop as remaining is 0
                return (0, n);
            }
            // order is null
            else if (required == 0) {
                continue;
            }
            // remaining >= depositAmount
            else {
                remaining -= required;
                TransferHelper.safeTransfer(give, orderbook, required);
                address owner = IOrderbook(orderbook).execute(orderId, !isBid, price, msg.sender, required);
                // emit event order matched
                emit OrderMatched(orderbook, orderId, isBid, msg.sender, owner, required, price);
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
     * @param isBid True if the order is an ask (sell) order, false if it is a bid (buy) order.
     * @param limitPrice The maximum price at which the order can be executed.
     * @param n The maximum number of matches to execute.
     * @return remaining The remaining amount of asset that was not traded.
     */
    function _limitOrder(address orderbook, uint256 amount, address give, bool isBid, uint256 limitPrice, uint32 n)
        internal
        returns (uint256 remaining)
    {
        remaining = amount;
        uint256 lmp = 0;
        uint32 i = 0;
        if (isBid) {
            // check if there is any matching ask order until matching ask order price is lower than the limit bid Price
            uint256 askHead = IOrderbook(orderbook).askHead();
            while (remaining > 0 && askHead != 0 && askHead <= limitPrice && i < n) {
                lmp = askHead;
                (remaining, i) = _matchAt(orderbook, give, isBid, remaining, askHead, i, n);
                askHead = IOrderbook(orderbook).askHead();
            }
        } else {
            // check if there is any maching bid order until matching bid order price is higher than the limit ask price
            uint256 bidHead = IOrderbook(orderbook).bidHead();
            while (remaining > 0 && bidHead != 0 && bidHead >= limitPrice && i < n) {
                lmp = bidHead;
                (remaining, i) = _matchAt(orderbook, give, isBid, remaining, bidHead, i, n);
                bidHead = IOrderbook(orderbook).bidHead();
            }
        }
        // set last match price
        if (lmp != 0) {
            IOrderbook(orderbook).setLmp(lmp);
        }
        return (remaining);
    }

    /**
     * @dev Determines if an order can be made at the market price,
     * and if so, makes the an order on the orderbook.
     * If an order cannot be made, transfers the remaining asset to either the orderbook or the user.
     * @param orderbook The address of the orderbook contract for the trading pair
     * @param asset The address of the asset to be traded after making order
     * @param remaining The remaining amount of the asset after the market order has been taken
     * @param price The price used to determine if an order can be made
     * @param isBid Boolean indicating if the order was a buy (true) or a sell (false)
     * @param isMaker Boolean indicating if an order is for storing in orderbook
     */
    function _detMake(address orderbook, address asset, uint256 remaining, uint256 price, bool isBid, bool isMaker)
        internal
    {
        if (remaining > 0) {
            address stopTo = isMaker ? orderbook : msg.sender;
            TransferHelper.safeTransfer(asset, stopTo, remaining);
            if (isMaker) _makeOrder(orderbook, remaining, price, isBid);
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
    function _deposit(address base, address quote, uint256 amount, bool isBid, uint32 uid, bool isMaker)
        internal
        returns (uint256 withoutFee, address book)
    {
        // check if sender has uid
        uint256 fee = _fee(base, quote, amount, isBid, uid, isMaker);
        withoutFee = amount - fee;
        if (isBid) {
            // transfer input asset give user to this contract
            TransferHelper.safeTransferFrom(quote, msg.sender, address(this), amount);
            TransferHelper.safeTransfer(quote, feeTo, fee);
        } else {
            // transfer input asset give user to this contract
            TransferHelper.safeTransferFrom(base, msg.sender, address(this), amount);
            TransferHelper.safeTransfer(base, feeTo, fee);
        }
        // get orderbook address from the base and quote asset
        book = getBookByPair(base, quote);
        return (withoutFee, book);
    }

    function _fee(address base, address quote, uint256 amount, bool isBid, uint32 uid, bool isMaker)
        internal
        returns (uint256 fee)
    {
        if (uid != 0 && IRevenue(membership).isReportable(msg.sender, uid)) {
            uint32 feeNum = IRevenue(accountant).feeOf(uid, isMaker);
            // report fee to accountant
            IRevenue(accountant).report(uid, isBid ? quote : base, amount, true);
            return (amount * feeNum) / feeDenom;
        } else {
            return amount / 1000;
        }
    }
}
