// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TestERC20} from "./TestERC20.sol";

interface ITestPairToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract TestV2Pair is TestERC20 {
    address public immutable token0;
    address public immutable token1;

    uint256 private reserve0;
    uint256 private reserve1;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, uint256 amount0Out, uint256 amount1Out, address indexed to);
    event Sync(uint256 reserve0, uint256 reserve1);

    constructor(address token0_, address token1_) TestERC20("Test V2 LP", "TV2-LP", 18) {
        require(token0_ != token1_, "IDENTICAL");
        require(token0_ != address(0), "ZERO");
        token0 = token0_;
        token1 = token1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        require(reserve0 <= type(uint112).max && reserve1 <= type(uint112).max, "RESERVE_OVERFLOW");
        return (uint112(reserve0), uint112(reserve1), uint32(block.timestamp));
    }

    function mint(address to) external returns (uint256 liquidity) {
        uint256 balance0 = ITestPairToken(token0).balanceOf(address(this));
        uint256 balance1 = ITestPairToken(token1).balanceOf(address(this));
        uint256 amount0 = balance0 - reserve0;
        uint256 amount1 = balance1 - reserve1;

        if (totalSupply == 0) {
            liquidity = _sqrt(amount0 * amount1);
        } else {
            liquidity = _min(amount0 * totalSupply / reserve0, amount1 * totalSupply / reserve1);
        }

        require(liquidity > 0, "INSUFFICIENT_LIQUIDITY");
        _mint(to, liquidity);
        reserve0 = balance0;
        reserve1 = balance1;
        emit Mint(msg.sender, amount0, amount1);
        emit Sync(balance0, balance1);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to) external {
        require(amount0Out > 0 || amount1Out > 0, "NO_OUTPUT");
        require(amount0Out < reserve0 && amount1Out < reserve1, "LIQUIDITY");
        if (amount0Out > 0) require(ITestPairToken(token0).transfer(to, amount0Out), "TOKEN0_OUT");
        if (amount1Out > 0) require(ITestPairToken(token1).transfer(to, amount1Out), "TOKEN1_OUT");

        uint256 balance0 = ITestPairToken(token0).balanceOf(address(this));
        uint256 balance1 = ITestPairToken(token1).balanceOf(address(this));
        reserve0 = balance0;
        reserve1 = balance1;
        emit Swap(msg.sender, amount0Out, amount1Out, to);
        emit Sync(balance0, balance1);
    }

    function skim(address to) external {
        uint256 balance0 = ITestPairToken(token0).balanceOf(address(this));
        uint256 balance1 = ITestPairToken(token1).balanceOf(address(this));
        if (balance0 > reserve0) require(ITestPairToken(token0).transfer(to, balance0 - reserve0), "TOKEN0_SKIM");
        if (balance1 > reserve1) require(ITestPairToken(token1).transfer(to, balance1 - reserve1), "TOKEN1_SKIM");
    }

    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y == 0) return 0;
        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
