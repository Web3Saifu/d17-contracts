// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {D17SafeTransfer} from "./lib/D17SafeTransfer.sol";
import {ID17FactoryView, ID17Launch, IERC20BalanceView, IV2Factory, IV2PairView, IV2Router} from "./interfaces/ID17.sol";

contract D17LiquidityVault {
    using D17SafeTransfer for address;

    bytes32 public constant D17_LIQUIDITY_VAULT_ID = keccak256("D17_LIQUIDITY_VAULT_V14_1_REFUND_SCHEDULE_BURN_GATE");

    address public immutable launch;
    address public immutable token;
    address public immutable weth;
    address public immutable router;
    address public immutable routerFactory;
    address public immutable treasury;

    bool public poolCreated;
    address public officialPair;
    uint256 public tokenUsedForPool;
    uint256 public wethUsedForPool;
    uint256 public lpMinted;
    uint256 public lateTokenUsedForLp;
    uint256 public lateWethUsedForLp;
    uint256 public lateLpMinted;
    uint256 public preseededTokenReserve;
    uint256 public preseededWethReserve;
    uint256 private entered = 1;

    event OfficialPoolCreated(
        address indexed pair,
        uint256 tokenUsed,
        uint256 wethUsed,
        uint256 lpMinted,
        uint256 preseededTokenReserve,
        uint256 preseededWethReserve
    );
    event LateLiquidityAdded(
        address indexed locker,
        address indexed pair,
        uint256 tokenUsed,
        uint256 wethUsed,
        uint256 lpMinted
    );
    event ExcessWethSwept(address indexed recipient, uint256 amount);
    event UnsupportedTokenRecovered(address indexed token, address indexed recipient, uint256 amount);
    event UnexpectedEthSwept(address indexed recipient, uint256 amount);

    modifier nonReentrant() {
        require(entered == 1, "REENTRANT");
        entered = 2;
        _;
        entered = 1;
    }

    constructor(address launch_, address token_, address weth_, address router_, address treasury_) {
        require(launch_ != address(0), "LAUNCH_ZERO");
        require(token_ != address(0), "TOKEN_ZERO");
        require(weth_ != address(0), "WETH_ZERO");
        require(router_ != address(0), "ROUTER_ZERO");
        require(treasury_ != address(0), "TREASURY_ZERO");
        require(launch_.code.length > 0, "LAUNCH_NO_CODE");
        require(token_.code.length > 0, "TOKEN_NO_CODE");
        require(weth_.code.length > 0, "WETH_NO_CODE");
        require(router_.code.length > 0, "ROUTER_NO_CODE");

        address routerFactory_ = IV2Router(router_).factory();
        require(routerFactory_ != address(0), "ROUTER_FACTORY_ZERO");
        require(routerFactory_.code.length > 0, "ROUTER_FACTORY_NO_CODE");

        launch = launch_;
        token = token_;
        weth = weth_;
        router = router_;
        routerFactory = routerFactory_;
        treasury = treasury_;
    }

    receive() external payable {
        revert("DIRECT_ETH_REJECTED");
    }

    fallback() external payable {
        revert("UNSUPPORTED_CALL");
    }

    function createOfficialPool(uint256 minLpMinted, uint256 deadline)
        external
        nonReentrant
        returns (address pair, uint256 liquidityTokens, uint256 wethForPool, uint256 liquidity)
    {
        require(!poolCreated, "POOL_CREATED");
        require(block.timestamp <= deadline, "DEADLINE");
        // The launch pairs settled WETH with the proportional LP
        // token share at the canonical launch ratio; late settlers top up through
        // mintLateLiquidity() afterwards.
        require(block.timestamp >= ID17Launch(launch).poolCreationOpensAt(), "POOL_CREATION_NOT_OPEN");

        pair = IV2Factory(routerFactory).getPair(token, weth);
        if (pair == address(0)) {
            pair = IV2Factory(routerFactory).createPair(token, weth);
        }
        require(pair.code.length > 0, "PAIR_NO_CODE");
        require(IV2PairView(pair).totalSupply() == 0, "PAIR_ALREADY_LIVE");

        (uint256 tokenReserve, uint256 wethReserve) = _pairReserves(pair);
        uint256 tokenBalanceBefore = IERC20BalanceView(token).balanceOf(pair);
        uint256 wethBalanceBefore = IERC20BalanceView(weth).balanceOf(pair);
        uint256 preseededWeth = wethBalanceBefore > wethReserve ? wethBalanceBefore : wethReserve;
        require(tokenBalanceBefore == 0, "PAIR_PRESEEDED_TOKEN");

        (uint256 claimedLiquidityTokens, uint256 claimedWethForPool) = ID17Launch(launch).claimVaultLiquidityTokens();
        wethForPool = claimedWethForPool;
        liquidityTokens = IERC20BalanceView(token).balanceOf(address(this));
        require(liquidityTokens == claimedLiquidityTokens, "VAULT_TOKEN_BALANCE");
        require(liquidityTokens > 0, "NO_TOKEN_BALANCE");
        require(wethForPool > 0, "NO_WETH_FOR_POOL");
        require(IERC20BalanceView(weth).balanceOf(address(this)) >= wethForPool, "VAULT_WETH_BALANCE");

        token.safeTransfer(pair, liquidityTokens);
        weth.safeTransfer(pair, wethForPool);
        liquidity = IV2PairView(pair).mint(address(this));
        require(liquidity >= minLpMinted, "LP_SLIPPAGE");

        poolCreated = true;
        officialPair = pair;
        tokenUsedForPool = liquidityTokens;
        wethUsedForPool = wethForPool;
        lpMinted = liquidity;
        preseededTokenReserve = tokenReserve;
        preseededWethReserve = preseededWeth;

        ID17Launch(launch).markLiquidityPoolCreated(pair, liquidityTokens, wethForPool, liquidity);
        emit OfficialPoolCreated(pair, liquidityTokens, wethForPool, liquidity, tokenBalanceBefore, preseededWethReserve);
    }

    /// @notice Adds a late settler's LP-share WETH plus its reserved LP-token share to the
    /// official pair at the canonical launch ratio, minting the resulting LP to this vault
    /// (permanently locked, like the original position). Called by the settling locker in
    /// the same transaction as claimLateSettlement(): the launch has just transferred the
    /// reserved tokens here and the locker has just transferred the WETH here, so the exact
    /// amounts are always available and never linger in the vault.
    function mintLateLiquidity(uint256 tokenAmount, uint256 wethAmount)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        require(poolCreated, "POOL_NOT_CREATED");
        require(
            ID17FactoryView(ID17Launch(launch).factory()).isLocker(msg.sender),
            "NOT_D17_LOCKER"
        );
        require(tokenAmount > 0 && wethAmount > 0, "LATE_AMOUNTS_ZERO");
        require(IERC20BalanceView(token).balanceOf(address(this)) >= tokenAmount, "VAULT_TOKEN_BALANCE");
        require(IERC20BalanceView(weth).balanceOf(address(this)) >= wethAmount, "VAULT_WETH_BALANCE");

        token.safeTransfer(officialPair, tokenAmount);
        weth.safeTransfer(officialPair, wethAmount);
        liquidity = IV2PairView(officialPair).mint(address(this));
        require(liquidity > 0, "LATE_LP_ZERO");

        lateTokenUsedForLp += tokenAmount;
        lateWethUsedForLp += wethAmount;
        lateLpMinted += liquidity;

        emit LateLiquidityAdded(msg.sender, officialPair, tokenAmount, wethAmount, liquidity);
    }

    function sweepExcessWethToTreasury() external nonReentrant returns (uint256 amount) {
        require(poolCreated, "POOL_NOT_CREATED");
        amount = IERC20BalanceView(weth).balanceOf(address(this));
        require(amount > 0, "NO_EXCESS_WETH");
        weth.safeTransfer(treasury, amount);
        emit ExcessWethSwept(treasury, amount);
    }

    function recoverUnsupportedTokenToTreasury(address tokenAddress, uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT_ZERO");
        require(tokenAddress != address(0), "TOKEN_ZERO");
        require(tokenAddress != token, "D17_TOKEN_PROTECTED");
        require(tokenAddress != weth, "WETH_PROTECTED");
        require(tokenAddress != officialPair, "LP_PROTECTED");
        tokenAddress.safeTransfer(treasury, amount);
        emit UnsupportedTokenRecovered(tokenAddress, treasury, amount);
    }

    function sweepUnexpectedEthToTreasury() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        require(amount > 0, "NO_ETH_BALANCE");
        (bool ok, ) = treasury.call{value: amount}("");
        require(ok, "ETH_SWEEP_FAILED");
        emit UnexpectedEthSwept(treasury, amount);
    }

    function _pairReserves(address pair) internal view returns (uint256 tokenReserve, uint256 wethReserve) {
        (uint112 reserve0, uint112 reserve1, ) = IV2PairView(pair).getReserves();
        address token0 = IV2PairView(pair).token0();
        if (token0 == token) {
            tokenReserve = uint256(reserve0);
            wethReserve = uint256(reserve1);
        } else {
            tokenReserve = uint256(reserve1);
            wethReserve = uint256(reserve0);
        }
    }
}
