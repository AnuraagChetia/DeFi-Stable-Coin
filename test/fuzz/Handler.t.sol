//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {console2} from "forge-std/console2.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine engine;
    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DecentralizedStableCoin _dsc, DSCEngine _engine) {
        dsc = _dsc;
        engine = _engine;
        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);

        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);

        engine.depositCollateral(address(collateral), amountCollateral);

        vm.stopPrank();
    }

    function mintDsc(uint256 amount) public {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(msg.sender);
        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);

        if (maxDscToMint < 0) return;

        amount = bound(amount, 0, uint256(maxDscToMint));

        if (amount == 0) return;

        vm.prank(msg.sender);
        engine.mintDSC(amount);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        uint256 maxCollateralToRedeem = engine.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);

        if (amountCollateral == 0) return;
        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    // HELPER FUNCTION

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
