// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {D17Launch} from "./D17Launch.sol";
import {ID17LaunchFactory} from "./interfaces/ID17LaunchFactory.sol";

interface ID17FactoryConfigView {
    function weth() external view returns (address);
    function router() external view returns (address);
}

interface IV2RouterFactoryView {
    function factory() external view returns (address);
}

interface ID17LiquidityVaultFactory {
    function deployVault(address launch, address token, address weth, address router, address treasury)
        external
        returns (address liquidityVault);
}

interface ID17TokenFactory {
    function deployToken(address tokenOwner, string calldata name, string calldata symbol, uint256 maxSupply)
        external
        returns (address token);
}

interface ID17LaunchToken {
    function configureTradingGate(
        address launch,
        address d17Factory,
        address weth,
        address routerFactory,
        address liquidityVault,
        uint256 tradingOpenAt
    ) external;
    function configureMetadata(
        string calldata description,
        string calldata logoSvgUri,
        ID17LaunchFactory.Link[] calldata links
    ) external;
    function mint(address to, uint256 amount) external;
    function closeMinting() external;
    function renounceOwnership() external;
}

contract D17LaunchFactory is ID17LaunchFactory {
    address public constant CANONICAL_DEAD_RECIPIENT = 0x000000000000000000000000000000000000dEaD;

    address public immutable d17Factory;
    address public immutable tokenFactory;
    address public immutable liquidityVaultFactory;

    modifier onlyD17Factory() {
        require(msg.sender == d17Factory, "NOT_D17_FACTORY");
        _;
    }

    constructor(address d17Factory_, address tokenFactory_, address liquidityVaultFactory_) {
        require(d17Factory_ != address(0), "FACTORY_ZERO");
        require(tokenFactory_ != address(0), "TOKEN_FACTORY_ZERO");
        require(liquidityVaultFactory_ != address(0), "VAULT_FACTORY_ZERO");
        require(d17Factory_.code.length > 0, "FACTORY_NO_CODE");
        require(tokenFactory_.code.length > 0, "TOKEN_FACTORY_NO_CODE");
        require(liquidityVaultFactory_.code.length > 0, "VAULT_FACTORY_NO_CODE");
        d17Factory = d17Factory_;
        tokenFactory = tokenFactory_;
        liquidityVaultFactory = liquidityVaultFactory_;
    }

    function deployLaunch(LaunchConfig calldata config, address creator)
        external
        onlyD17Factory
        returns (address token, address launch, address liquidityVault)
    {
        require(creator != address(0), "CREATOR_ZERO");
        token = ID17TokenFactory(tokenFactory).deployToken(
            address(this),
            config.tokenName,
            config.tokenSymbol,
            config.tokenSupply
        );

        D17Launch deployedLaunch = new D17Launch(
            d17Factory,
            address(this),
            token,
            ID17FactoryConfigView(d17Factory).weth(),
            config.treasury,
            _metadataHash(config),
            config.startTime,
            config.roundSeconds,
            config.refundSeconds,
            config.settlementSeconds,
            config.minCommitWeth,
            config.minPhase1Weth,
            config.minAnchorPriceWad,
            config.roundSharesBps,
            config.treasuryBps,
            config.refundPenaltyBps,
            config.saleTokens,
            config.lpTokens,
            config.deadTokens,
            config.deadRecipient,
            config.manualDistributionTokens,
            creator,
            config.burnUnsoldSaleTokens
        );
        launch = address(deployedLaunch);

        address weth = ID17FactoryConfigView(d17Factory).weth();
        address router = ID17FactoryConfigView(d17Factory).router();
        address routerFactory = IV2RouterFactoryView(router).factory();
        liquidityVault =
            ID17LiquidityVaultFactory(liquidityVaultFactory).deployVault(launch, token, weth, router, config.treasury);

        deployedLaunch.configureLiquidityVault(liquidityVault);
        ID17LaunchToken(token).configureTradingGate(
            launch,
            d17Factory,
            weth,
            routerFactory,
            liquidityVault,
            deployedLaunch.tradingOpenAt()
        );
        ID17LaunchToken(token).configureMetadata(config.description, config.logoSvgUri, config.links);

        ID17LaunchToken(token).mint(launch, config.saleTokens + config.lpTokens);
        if (config.manualDistributionTokens > 0) ID17LaunchToken(token).mint(creator, config.manualDistributionTokens);
        if (config.deadTokens > 0) ID17LaunchToken(token).mint(CANONICAL_DEAD_RECIPIENT, config.deadTokens);
        ID17LaunchToken(token).closeMinting();
        ID17LaunchToken(token).renounceOwnership();
    }

    function _metadataHash(LaunchConfig calldata config) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                config.tokenName,
                config.tokenSymbol,
                config.description,
                config.logoSvgUri,
                config.links
            )
        );
    }
}
