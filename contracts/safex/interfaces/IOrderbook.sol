// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "../libraries/SAFEXOrderbook.sol";

interface IOrderbook {
    function initialize(uint256 id, address base_, address quote_, address engine_) external;

    function fpop(bool isBid, uint256 price) external returns (uint256 orderId);

    function setLmp(uint256 lmp) external;

    function mktPrice() external view returns (uint256);

    function assetValue(uint256 amount, bool isBid) external view returns (uint256 converted);

    function isEmpty(bool isBid, uint256 price) external view returns (bool);

    function getRequired(bool isBid, uint256 price, uint256 orderId) external view returns (uint256 required);

    function placeAsk(address owner, uint256 price, uint256 amount) external;

    function placeBid(address owner, uint256 price, uint256 amount) external;

    function cancelOrder(bool isBid, uint256 price, uint256 orderId, address owner)
        external
        returns (uint256 remaining, address base, address quote);

    function execute(uint256 orderId, bool isBid, uint256 price, address sender, uint256 amount)
        external
        returns (address owner);

    function heads() external view returns (uint256 bidHead, uint256 askHead);

    function askHead() external view returns (uint256);

    function bidHead() external view returns (uint256);

    function getPrices(bool isBid, uint256 n) external view returns (uint256[] memory);

    function getOrders(bool isBid, uint256 price, uint256 n) external view returns (SAFEXOrderbook.Order[] memory);

    function getOrder(bool isBid, uint256 orderId) external view returns (SAFEXOrderbook.Order memory);

    function getOrderIds(bool isBid, uint256 price, uint256 n) external view returns (uint256[] memory);

    function pushBack(uint256 orderId, uint256 price, bool isBid) external;
}
