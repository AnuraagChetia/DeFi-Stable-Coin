//SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Handler} from "./Handler.t.sol";
import {console2} from "forge-std/console2.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine engine;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, engine, helperConfig) = deployer.run();
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
        handler = new Handler(dsc, engine);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalDscSupply = dsc.totalSupply();

        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console2.log("weth value: ", wethValue);
        console2.log("wbtc value: ", wbtcValue);
        console2.log("total dsc supply: ", totalDscSupply);

        assert(wbtcValue + wethValue >= totalDscSupply);
    }
}
