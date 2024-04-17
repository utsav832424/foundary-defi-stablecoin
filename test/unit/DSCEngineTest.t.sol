// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    address public liquidator = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant amountTomint = 100 ether;
    uint256 public constant collateralTocover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthNotSameWithRriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__tokenAddressAndPricefeedAddressLengthMustBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////
    // Price Tests  ///////
    ///////////////////////
    function testGetValueInUsd() public view {
        uint256 ethAmount = 10e18;
        // 10e18 * 2000 = 20000
        uint256 expectedUsd = 20000e18;
        uint256 actualusd = dsce.getValueInUsd(weth, ethAmount);
        assertEq(actualusd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $100$  / $2000 ETH
        uint256 expectedAmont = 0.05 ether;
        uint256 actualAmount = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedAmont, actualAmount);
    }

    function testGetAccountInformaion() public {
        vm.startPrank(USER);
        (uint256 totalDScMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(0, totalDScMinted);
        assertEq(0, collateralValueInUsd);
        vm.stopPrank();
    }

    /////////////////////////////////////
    // deposit and mint collateral dsc //
    /////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustMoreThenZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testIfTokenIsNotApproved() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(randToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountTomint);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
        vm.stopPrank();
    }

    function testDepositCollateralAndMintDsc() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(AMOUNT);
        assertEq(AMOUNT, dsc.balanceOf(USER));
        vm.stopPrank();
    }

    function testRevetsIfMintDscWithoutDepositCollateral() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.mintDsc(AMOUNT);
        vm.stopPrank();
    }

    function testGetDscMintedOfUser() public depositCollateral {
        vm.prank(USER);
        dsce.mintDsc(AMOUNT);
        uint256 actualAMount = dsce.getDscMintedOfUser(USER);
        assertEq(AMOUNT, actualAMount);
    }

    function testGetCollateralDeposited() public depositCollateral {
        vm.prank(USER);
        uint256 actualDepositedValue = dsce.getCollateralDeposited(USER, weth);
        assertEq(actualDepositedValue, AMOUNT);
    }

    function testRevertsIfMintDscIsZero() public depositCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustMoreThenZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    ////////////////////////////
    // Redeem collateral dsc ///
    ////////////////////////////

    function testRevertsIfRedeemAmountIsZero() public depositCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(AMOUNT_COLLATERAL);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.redeemCollateral(weth, AMOUNT);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositCollateralAndMintDsc {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, 9e18);
        vm.stopPrank();
    }

    function testBurnDsc() public depositCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), amountTomint);
        dsce.burnDsc(amountTomint);
        uint256 balAfterBurn = dsce.getDscMintedOfUser(USER);
        assertEq(balAfterBurn, 0);
        vm.stopPrank();
    }

    function testRevertsIfBurnDscAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountTomint);
        vm.expectRevert(DSCEngine.DSCEngine__MustMoreThenZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    /////////////////////
    // liquidate tests //
    ////////////////////

    function testliquidated() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountTomint);
        vm.stopPrank();

        int256 ethUsdUpdatePrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatePrice);

        ERC20Mock(weth).mint(liquidator, collateralTocover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralTocover);
        dsce.depositCollateralAndMintDsc(weth, collateralTocover, amountTomint);
        dsc.approve(address(dsce), amountTomint);
        dsce.liquidate(weth, USER, amountTomint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountTomint);
        vm.stopPrank();

        int256 ethUsdUpdatePrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatePrice);

        ERC20Mock(weth).mint(liquidator, collateralTocover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralTocover);
        dsce.depositCollateralAndMintDsc(weth, collateralTocover, amountTomint);
        dsc.approve(address(dsce), amountTomint);
        dsce.liquidate(weth, USER, amountTomint);
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountTomint)
            + (dsce.getTokenAmountFromUsd(weth, amountTomint) / dsce.getLiquidationBonus());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testRevertsIfStratingHealthFactorIsOk() public depositCollateralAndMintDsc {
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorIsOk.selector);
        dsce.liquidate(weth, USER, amountTomint);
    }
}
