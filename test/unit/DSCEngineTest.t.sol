//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant WETH_USD_PRICE = 2000e8;
    uint256 public constant PRICE_PRECISION = 1e10;
    uint256 public constant ADDITIONAL_PRICE_PRECISION = 1e18;
    uint256 public constant DSC_TO_MINT_OVERCOLLATERALIZED = 5 ether;
    uint256 public constant AMOUNT_TO_BURN = 1 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////////
    //// CONSTRUCTOR TESTS /////
    ////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////
    //// PRICE TESTS /////
    //////////////////////

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // Price of eth is $2000 in this test ( see HelperConfig )
        // $2000 = 1 eth
        // $2000 / $100 = 0.05 eth
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = engine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15 * 2000 = 30,000
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = engine.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    ///////////////////////////////////
    //// DEPOSIT COLLATERAL TESTS /////
    ///////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        engine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralValueInUsd = engine.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(totalDscMinted, expectedDscMinted);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    ///////////////////////////////////
    //////// MINT DSC TESTS ///////////
    ///////////////////////////////////

    function testDepositCollateralAndMintDSC() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT_COLLATERAL);
        engine.depositCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, DSC_TO_MINT_OVERCOLLATERALIZED);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(USER);
        vm.stopPrank();
        uint256 expectedCollateralValueInUsd =
            (AMOUNT_COLLATERAL * WETH_USD_PRICE * PRICE_PRECISION) / ADDITIONAL_PRICE_PRECISION;
        assertEq(totalDscMinted, DSC_TO_MINT_OVERCOLLATERALIZED);
        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    function testMintDSC() public depositedCollateral {
        vm.startPrank(USER);
        engine.mintDSC(DSC_TO_MINT_OVERCOLLATERALIZED);
        (uint256 totalDscMinted,) = engine.getAccountInformation(USER);
        vm.stopPrank();
        assertEq(totalDscMinted, DSC_TO_MINT_OVERCOLLATERALIZED);
    }

    function testMintDscFailsIfHealthFactorBroken() public depositedCollateral {
        vm.startPrank(USER);

        uint256 amountToMint = (AMOUNT_COLLATERAL * WETH_USD_PRICE * PRICE_PRECISION) / ADDITIONAL_PRICE_PRECISION;

        uint256 expectedHealthFactor =
            engine.calculateHealthFactor(amountToMint, engine.getUsdValue(weth, AMOUNT_COLLATERAL));

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__HealthFactorBroken.selector, expectedHealthFactor));

        engine.mintDSC(amountToMint);

        vm.stopPrank();
    }

    ///////////////////////////////////
    //////// BURN DSC TESTS ///////////
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedMoreThanZero.selector);
        engine.burnDSC(0);
        vm.stopPrank();
    }

    function testBurnDsc() public depositedCollateral mintDsc {
        vm.startPrank(USER);
        dsc.approve(address(engine), AMOUNT_TO_BURN);
        engine.burnDSC(AMOUNT_TO_BURN);
        vm.stopPrank();

        uint256 expectedDscMinted = DSC_TO_MINT_OVERCOLLATERALIZED - AMOUNT_TO_BURN;
        (uint256 actualDscMinted,) = engine.getAccountInformation(USER);
        assertEq(expectedDscMinted, actualDscMinted);
    }

    ///////////////////////////////////
    //// REDEEM COLLATERAL TESTS //////
    ///////////////////////////////////
    modifier mintDsc() {
        vm.startPrank(USER);
        engine.mintDSC(DSC_TO_MINT_OVERCOLLATERALIZED);
        vm.stopPrank();
        _;
    }

    function testRedeemCollateral() public depositedCollateral mintDsc {
        vm.startPrank(USER);
        uint256 collateralToRedeem = 5 ether;
        engine.redeemCollateral(weth, collateralToRedeem);
        uint256 expectedCollateralValueInUsd = (
            (AMOUNT_COLLATERAL * WETH_USD_PRICE * PRICE_PRECISION) / ADDITIONAL_PRICE_PRECISION
        ) - (collateralToRedeem * WETH_USD_PRICE * PRICE_PRECISION) / ADDITIONAL_PRICE_PRECISION;
        uint256 actualCollateralValueInUsd = engine.getAccountCollateralValue(USER);
        vm.stopPrank();
        assertEq(expectedCollateralValueInUsd, actualCollateralValueInUsd);
    }

    ///////////////////////////////////
    //// REDEEM COLLATERAL TESTS //////
    ///////////////////////////////////

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 actualCollateralValueInUsd = engine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValueInUsd =
            (AMOUNT_COLLATERAL * WETH_USD_PRICE * PRICE_PRECISION) / ADDITIONAL_PRICE_PRECISION;
        assertEq(expectedCollateralValueInUsd, actualCollateralValueInUsd);
    }
}
