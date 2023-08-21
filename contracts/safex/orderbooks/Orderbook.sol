// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import {IOrderbook} from "../interfaces/IOrderbook.sol";
import {Initializable} from "../../security/Initializable.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {ExchangeLinkedList} from "../libraries/ExchangeLinkedList.sol";
import {ExchangeOrderbook} from "../libraries/ExchangeOrderbook.sol";

contract Orderbook is IOrderbook, Initializable {
    using ExchangeLinkedList for ExchangeLinkedList.PriceLinkedList;
    using ExchangeOrderbook for ExchangeOrderbook.OrderStorage;

    // Pair Struct
    struct Pair {
        uint256 id;
        address base;
        address quote;
        address engine;
    }

    Pair private pair;

    uint64 private decDiff;
    bool private baseBquote;

    ExchangeLinkedList.PriceLinkedList private priceLists;
    ExchangeOrderbook.OrderStorage private _askOrders;
    ExchangeOrderbook.OrderStorage private _bidOrders;

    error InvalidDecimals(uint8 base, uint8 quote);
    error InvalidAccess(address sender, address allowed);
    error OrderSizeTooSmall(uint256 amount, uint256 minRequired);

    function initialize(
        uint256 id_,
        address base_,
        address quote_,
        address engine_
    ) external initializer {
        uint8 baseD = TransferHelper.decimals(base_);
        uint8 quoteD = TransferHelper.decimals(quote_);
        if (baseD > 18 || quoteD > 18) {
            revert InvalidDecimals(baseD, quoteD);
        }
        (uint8 diff, bool baseBquote_) = _absdiff(baseD, quoteD);
        decDiff = uint64(10 ** diff);
        baseBquote = baseBquote_;
        pair = Pair(id_, base_, quote_, engine_);
    }

    modifier onlyEngine() {
        if (msg.sender != pair.engine) {
            revert InvalidAccess(msg.sender, pair.engine);
        }
        _;
    }

    function setLmp(uint256 price) external onlyEngine {
        priceLists._setLmp(price);
    }

    function placeAsk(
        address owner,
        uint256 price,
        uint256 amount
    ) external onlyEngine returns (uint32 id)  {
        id = _askOrders._createOrder(owner, amount);
        // check if the price is new in the list. if not, insert id to the list
        if (_askOrders._isEmpty(price)) {
            priceLists._insert(false, price);
        }
        _askOrders._insertId(price, id, amount);
        return id;
    }

    function placeBid(
        address owner,
        uint256 price,
        uint256 amount
    ) external onlyEngine returns (uint32 id) {
        id = _bidOrders._createOrder(owner, amount);
        // check if the price is new in the list. if not, insert id to the list
        if (_bidOrders._isEmpty(price)) {
            priceLists._insert(true, price);
        }
        _bidOrders._insertId(price, id, amount);
        return id;
    }

    function cancelOrder(
        bool isBid,
        uint256 price,
        uint32 orderId,
        address owner
    ) external onlyEngine returns (uint256 remaining) {
        ExchangeOrderbook.Order memory order = isBid
            ? _bidOrders._getOrder(orderId)
            : _askOrders._getOrder(orderId);
        if (order.owner != owner) {
            revert InvalidAccess(owner, order.owner);
        }
        isBid
            ? _bidOrders._deleteOrder(price, orderId)
            : _askOrders._deleteOrder(price, orderId);
        isBid
            ? TransferHelper.safeTransfer(
                pair.quote,
                owner,
                order.depositAmount
            )
            : TransferHelper.safeTransfer(
                pair.base,
                owner,
                order.depositAmount
            );

        return (order.depositAmount);
    }

    function execute(
        uint32 orderId,
        bool isBid,
        uint256 price,
        address sender,
        uint256 amount
    ) external onlyEngine returns (address owner) {
        ExchangeOrderbook.Order memory order = isBid
            ? _bidOrders._getOrder(orderId)
            : _askOrders._getOrder(orderId);
        uint256 converted = convert(price, amount, isBid);
        // if isBid == true, sender is matching ask order with bid order(i.e. selling base to receive quote), otherwise sender is matching bid order with ask order(i.e. buying base with quote)
        if (isBid) {
            // sender is matching ask order for base asset with quote asset
            TransferHelper.safeTransfer(pair.base, order.owner, amount);
            // send converted amount of quote asset from owner to sender
            TransferHelper.safeTransfer(pair.quote, sender, converted);
            // decrease remaining amount of order
            _bidOrders._decreaseOrder(price, orderId, converted);
        }
        // if the order is bid order on the base/quote pair
        else {
            // sender is matching bid order for quote asset with base asset
            // send deposited amount of quote asset from sender to owner
            TransferHelper.safeTransfer(pair.quote, order.owner, amount);
            // send converted amount of base asset from owner to sender
            TransferHelper.safeTransfer(pair.base, sender, converted);
            // decrease remaining amount of order
            _askOrders._decreaseOrder(price, orderId, converted);
        }
        return order.owner;
    }

    function fpop(
        bool isBid,
        uint256 price,
        uint256 remaining
    ) external onlyEngine returns (uint32 orderId, uint256 required) {
        orderId = isBid ? _bidOrders._head(price) : _askOrders._head(price);
        ExchangeOrderbook.Order memory order = isBid
            ? _bidOrders._getOrder(orderId)
            : _askOrders._getOrder(orderId);
        required = convert(price, order.depositAmount, !isBid);
        if (required <= remaining) {
            isBid ? _bidOrders._fpop(price) : _askOrders._fpop(price);
            if (isEmpty(isBid, price)) {
                isBid
                    ? priceLists.bidHead = priceLists._next(isBid, price)
                    : priceLists.askHead = priceLists._next(isBid, price);
            }
        }
        return (orderId, required);
    }

    function _absdiff(uint8 a, uint8 b) internal pure returns (uint8, bool) {
        return (a > b ? a - b : b - a, a > b);
    }

    // get required amount for executing the order
    function getRequired(
        bool isBid,
        uint256 price,
        uint32 orderId
    ) external view returns (uint256 required) {
        ExchangeOrderbook.Order memory order = isBid
            ? _bidOrders._getOrder(orderId)
            : _askOrders._getOrder(orderId);
        if (order.depositAmount == 0) {
            return 0;
        }
        /* if ask, required base amount is quoteAmount / price,
         * converting the number converting decimal from quote to base,
         * otherwise quote amount is baseAmount * price, converting decimal from base to quote
         */
        return convert(price, order.depositAmount, isBid);
    }

    /////////////////////////////////
    /// Price linked list methods ///
    /////////////////////////////////

    function heads() external view returns (uint256, uint256) {
        return priceLists._heads();
    }

    function askHead() external view returns (uint256) {
        return priceLists._askHead();
    }

    function bidHead() external view returns (uint256) {
        return priceLists._bidHead();
    }

    function mktPrice() external view returns (uint256) {
        return priceLists._mktPrice();
    }

    function getPrices(
        bool isBid,
        uint32 n
    ) external view returns (uint256[] memory) {
        return priceLists._getPrices(isBid, n);
    }

    function getOrderIds(
        bool isBid,
        uint256 price,
        uint32 n
    ) external view returns (uint32[] memory) {
        return
            isBid
                ? _bidOrders._getOrderIds(price, n)
                : _askOrders._getOrderIds(price, n);
    }

    function getOrders(
        bool isBid,
        uint256 price,
        uint32 n
    ) external view returns (ExchangeOrderbook.Order[] memory) {
        return
            isBid
                ? _bidOrders._getOrders(price, n)
                : _askOrders._getOrders(price, n);
    }

    function getOrder(
        bool isBid,
        uint32 orderId
    ) external view returns (ExchangeOrderbook.Order memory) {
        return
            isBid
                ? _bidOrders._getOrder(orderId)
                : _askOrders._getOrder(orderId);
    }

    function getBaseQuote() external view returns (address base, address quote) {
        return (pair.base, pair.quote);
    }

    /**
     * @dev get asset value in quote asset if isBid is true, otherwise get asset value in base asset
     * @param amount amount of asset in base asset if isBid is true, otherwise in quote asset
     * @param isBid if true, get asset value in quote asset, otherwise get asset value in base asset
     * @return converted asset value in quote asset if isBid is true, otherwise asset value in base asset
     */
    function assetValue(
        uint256 amount,
        bool isBid
    ) external view returns (uint256 converted) {
        return convert(priceLists._mktPrice(), amount, isBid);
    }

    function isEmpty(bool isBid, uint256 price) public view returns (bool) {
        return isBid ? _bidOrders._isEmpty(price) : _askOrders._isEmpty(price);
    }

    function convert(
        uint256 price,
        uint256 amount,
        bool isBid
    ) public view returns (uint256 converted) {
        if (isBid) {
            // convert quote to base
            return
                baseBquote
                    ? ((amount * price) / 1e8) / decDiff
                    : ((amount * price) / 1e8) * decDiff;
        } else {
            // convert base to quote
            return
                baseBquote
                    ? ((amount * 1e8) / price) * decDiff
                    : ((amount * 1e8) / price) / decDiff;
        }
    }
}
