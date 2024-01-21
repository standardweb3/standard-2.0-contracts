pragma solidity >=0.8;

import {MockToken} from "../../../contracts/mock/MockToken.sol";
import {MockBase} from "../../../contracts/mock/MockBase.sol";
import {MockQuote} from "../../../contracts/mock/MockQuote.sol";
import {MockBTC} from "../../../contracts/mock/MockBTC.sol";
import {ErrToken} from "../../../contracts/mock/MockTokenOver18Decimals.sol";
import {Utils} from "../../utils/Utils.sol";
import {MatchingEngine} from "../../../contracts/safex/MatchingEngine.sol";
import {OrderbookFactory} from "../../../contracts/safex/orderbooks/OrderbookFactory.sol";
import {Orderbook} from "../../../contracts/safex/orderbooks/Orderbook.sol";
import {ExchangeOrderbook} from "../../../contracts/safex/libraries/ExchangeOrderbook.sol";
import {IOrderbookFactory} from "../../../contracts/safex/interfaces/IOrderbookFactory.sol";
import {WETH9} from "../../../contracts/mock/WETH9.sol";
import {Treasury} from "../../../contracts/sabt/Treasury.sol";
import {BaseSetup} from "../OrderbookBaseSetup.sol";
import {console} from "forge-std/console.sol";
import {stdStorage, StdStorage, Test} from "forge-std/Test.sol";

contract LoopOutOfGasTest is BaseSetup {
    function testExchangeLinkedListOutOfGas() public {
        super.setUp();
        vm.prank(booker);
        matchingEngine.addPair(address(token1), address(token2));
        book = Orderbook(
            payable(
                orderbookFactory.getBookByPair(address(token1), address(token2))
            )
        );
        vm.prank(trader1);

        // placeBid or placeAsk two of them is using the _insert function it will revert
        // because the program will enter the (price < last) statement
        // and eventually, it will cause an infinite loop.
        matchingEngine.limitBuy(
            address(token1),
            address(token2),
            2,
            10,
            true,
            2,
            0
        );
        vm.prank(trader1);
        matchingEngine.limitBuy(
            address(token1),
            address(token2),
            5,
            10,
            true,
            2,
            0
        );
        vm.prank(trader1);
        matchingEngine.limitBuy(
            address(token1),
            address(token2),
            5,
            10,
            true,
            2,
            0
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitBuy(
            address(token1),
            address(token2),
            1,
            10,
            true,
            2,
            0
        );
    }

    function testExchangeLinkedListOutOfGasPlaceBid() public {
        super.setUp();
        vm.prank(booker);
        matchingEngine.addPair(address(token1), address(token2));
        book = Orderbook(
            payable(
                orderbookFactory.getBookByPair(address(token1), address(token2))
            )
        );
        // We can create the same example with placeBid function
        // This time the program will enter the while (price > last && last != 0) statement
        // and it will cause an infinite loop.
        vm.prank(trader1);
        matchingEngine.limitSell(
            address(token1),
            address(token2),
            2,
            5e7,
            true,
            2,
            0
        );
        vm.prank(trader1);
        matchingEngine.limitSell(
            address(token1),
            address(token2),
            5,
            2e7,
            true,
            2,
            0
        );
        vm.prank(trader1);
        matchingEngine.limitSell(
            address(token1),
            address(token2),
            5,
            2e7,
            true,
            2,
            0
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            address(token1),
            address(token2),
            6,
            2e7,
            true,
            2,
            0
        );
    }

    function testExchangeOrderbookOutOfGas() public {
        super.setUp();
        vm.prank(booker);
        matchingEngine.addPair(address(token1), address(token2));
        book = Orderbook(
            payable(
                orderbookFactory.getBookByPair(address(token1), address(token2))
            )
        );
        vm.prank(trader1);
        // placeBid or placeAsk two of them is using the _insertId function it will revert
        // because the program will enter the "if (amount > self.orders[head].depositAmount)."
        // statement, and eventually, it will cause an infinite loop.
        matchingEngine.limitSell(
            address(token1),
            address(token2),
            5,
            2e7,
            true,
            2,
            0
        );
        vm.prank(trader1);
        //vm.expectRevert("OutOfGas");
        matchingEngine.limitSell(
            address(token1),
            address(token2),
            1,
            1e8,
            true,
            2,
            0
        );
    }
}