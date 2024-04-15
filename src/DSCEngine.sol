// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Utsav Bhikadiya
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC System sholud always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////////
    //// Errors ////
    ////////////////
    error DSCEngine__MustMoreThenZero();
    error DSCEngine__tokenAddressAndPricefeedAddressLengthMustBeSame();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintedFailed();
    error DSCEngine__HealthFactorIsOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////
    //// State variables ////
    /////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;
    uint256 private constant LIQUIDATION_BOUNS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    //// Events  ////
    ////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );
    ////////////////////
    //// Modifiers  ////
    ////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__MustMoreThenZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////////
    //// Functions  ////
    ////////////////////

    constructor(address[] memory tokenAddress, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddress.length != priceFeedAddress.length) {
            revert DSCEngine__tokenAddressAndPricefeedAddressLengthMustBeSame();
        }
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////
    //// external Functions ////
    ////////////////////////////

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
    */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDsctoMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDsctoMint);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @param burnAmountDsc: the amount of DSC you want ot burn
     * @notice This function will redeem your collateral.
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     * @notice this burns DSC and redeems collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 burnAmountDsc)
        external
    {
        burnDsc(burnAmountDsc);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /*
     * @param collateral : The erc20 collateral address to liquidate from the user
     * This is collateral that you're going to take from the user who is insolvent.
     * @param user : The user who has broken the health factor. Their _healthFactor should 
       be below MIN_HEALTH_FACTOR
     * @param debtToCover : The amount of DSC you want to burn to improve the users health factor

     * @notice : You can partially liquidate a user.
     * @notice : This function working assumes the protocol will be roughly 200% overcollaterlized 
       in order for this to work.
     * @notice : A known bug would be if the protocol were 100% or less collaterlized,then we wouldn't
        be able to incentive the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(msg.sender);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOk();
        }
        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User : $150 ETH , $100 DSC
        // debtTocover = $100
        // $100 od DSC == ?? ETH?
        // $100 / $2000 = 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We sholud implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bounsCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BOUNS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bounsCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        // We need to burn dsc
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthfactor = _healthFactor(user);
        if (endingUserHealthfactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ////////////////////////////
    //// internal Functions ////
    ////////////////////////////

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 burnAmountDsc, address onBehalfOf, address dscFrom) public moreThanZero(burnAmountDsc) {
        s_DSCMinted[onBehalfOf] -= burnAmountDsc;
        bool success = i_dsc.transferFrom(dscFrom, address(this), burnAmountDsc);
        // This conditonal is hypothtically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(burnAmountDsc);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getTotalCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        // total dsc minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        // $1000 ETH / $100 DSC
        // 1000 * 50 = 50000 / 100 = (500 / 100) > 1
        return (collateralAdjustForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. check Health factor (do they have enough collateral?)
        // 2. Revert if they don't
        uint256 userHealthFacotr = _healthFactor(user);
        if (userHealthFacotr < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFacotr);
        }
    }

    ////////////////////////////
    //// Public Functions //////
    ////////////////////////////

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    * @param amountDscToMint: The amount of DSC you want to mint
    *  @notice they must have more collateral value than the minimum threshold
     * You can only mint DSC if you hav enough collateral
     */
    function mintDsc(uint256 amountDsctoMint) public {
        s_DSCMinted[msg.sender] += amountDsctoMint;
        // if they minted to much ($150 DSC,$100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDsctoMint);
        if (!minted) {
            revert DSCEngine__MintedFailed();
        }
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /* 
     * @param burnAmountDsc: the amount of DSC you want ot burn
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * you DSC but keep your collateral in.
     */
    function burnDsc(uint256 burnAmountDsc) public moreThanZero(burnAmountDsc) {
        _burnDsc(burnAmountDsc, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    function getTotalCollateralValue(address user) public view returns (uint256 totalValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to the price , to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalValueInUsd += getValueInUsd(token, amount);
        }
        return totalValueInUsd;
    }

    function getValueInUsd(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $3000
        // The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        // $/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // (1000e18 * 1e18) / (2000e8 * 1e10) = 0.5000000000000000000
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    ////////////////////////////
    //// Getter Functions //////
    ////////////////////////////
    function getS_PriceFeed(address user) external view returns (address) {
        return s_priceFeeds[user];
    }
}
