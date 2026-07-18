// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestV2Factory} from "./TestV2Factory.sol";
import {TestV2Pair} from "./TestV2Pair.sol";

interface ITestRouterToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract TestV2Router {
    address public immutable factory;

    constructor(address factory_) {
        require(factory_ != address(0), "FACTORY_ZERO");
        factory = factory_;
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(block.timestamp <= deadline, "EXPIRED");
        address pair = TestV2Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) pair = TestV2Factory(factory).createPair(tokenA, tokenB);

        (uint256 reserveA, uint256 reserveB) = getReserves(tokenA, tokenB);
        (amountA, amountB) = _quoteAddLiquidity(amountADesired, amountBDesired, amountAMin, amountBMin, reserveA, reserveB);

        require(ITestRouterToken(tokenA).transferFrom(msg.sender, pair, amountA), "TOKEN_A_TRANSFER");
        require(ITestRouterToken(tokenB).transferFrom(msg.sender, pair, amountB), "TOKEN_B_TRANSFER");
        liquidity = TestV2Pair(pair).mint(to);
    }

    function getReserves(address tokenA, address tokenB) public view returns (uint256 reserveA, uint256 reserveB) {
        address pair = TestV2Factory(factory).getPair(tokenA, tokenB);
        if (pair == address(0)) return (0, 0);
        (uint112 reserve0, uint112 reserve1, ) = TestV2Pair(pair).getReserves();
        (address token0, ) = _sortTokens(tokenA, tokenB);
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function swapExactTokensForTokens(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to
    ) external {
        address pair = TestV2Factory(factory).getPair(tokenIn, tokenOut);
        require(pair != address(0), "PAIR");
        require(ITestRouterToken(tokenIn).transferFrom(msg.sender, pair, amountIn), "TOKEN_IN_TRANSFER");
        address token0 = TestV2Pair(pair).token0();
        if (tokenOut == token0) {
            TestV2Pair(pair).swap(amountOut, 0, to);
        } else {
            TestV2Pair(pair).swap(0, amountOut, to);
        }
    }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        require(amountA > 0, "AMOUNT");
        require(reserveA > 0 && reserveB > 0, "RESERVES");
        return amountA * reserveB / reserveA;
    }

    function _quoteAddLiquidity(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 reserveA,
        uint256 reserveB
    ) private pure returns (uint256 amountA, uint256 amountB) {
        if (reserveA == 0 && reserveB == 0) {
            amountA = amountADesired;
            amountB = amountBDesired;
        } else {
            uint256 amountBOptimal = quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, "B_MIN");
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                uint256 amountAOptimal = quote(amountBDesired, reserveB, reserveA);
                require(amountAOptimal >= amountAMin, "A_MIN");
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
        }
        require(amountA >= amountAMin && amountB >= amountBMin, "MIN");
    }

    function _sortTokens(address tokenA, address tokenB) private pure returns (address token0, address token1) {
        require(tokenA != tokenB, "IDENTICAL");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZERO");
    }
}
