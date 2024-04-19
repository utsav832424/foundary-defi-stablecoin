// Handler is going to narrow down the way we call function
// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dsce;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public constant MAX_DEPOSIT_SIZE = type(uint96).max;
    uint256 public timeMintDscCalled;
    address[] public usersWithCollateralDeposited;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;
        address[] memory collaterlTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collaterlTokens[0]);
        wbtc = ERC20Mock(collaterlTokens[1]);
    }

    function mintDsc(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        console.log("addressSeed : ", addressSeed);
        console.log("usersWithCollateralDeposited.length : ", usersWithCollateralDeposited.length);
        console.log("sender : ", sender);
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);

        uint256 maxDscToMint = (collateralValueInUsd / 2) - totalDscMinted;
        if (totalDscMinted > (collateralValueInUsd / 2)) {
            return;
        }

        amount = bound(amount, 0, maxDscToMint);
        if (amount > maxDscToMint) {
            amount = maxDscToMint;
        }
        if (amount == 0) {
            return;
        }
        vm.startPrank(sender);
        dsce.mintDsc(amount);
        vm.stopPrank();
        timeMintDscCalled++;
    }

    function depositCollateral(uint256 collateralseed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralSeed(collateralseed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralseed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralSeed(collateralseed);
        uint256 maxCollateralToRedeem = dsce.getCollateralDeposited(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        vm.prank(msg.sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    function _getCollateralSeed(uint256 collaterlSeed) private view returns (ERC20Mock) {
        if (collaterlSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
