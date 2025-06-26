// SPDX-License-Identifier: MIT

// This file has our invariants aka system properties that should always hold

// what are our invariants? (what are those properties that should always be true)
// 1. The total supply of DSC(Debt) should be less than the total value of collateral
// 2. Getter view functions should never revert => evergreen invariant

pragma solidity ^0.8.20;

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Handler} from "./Handler.t.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreCollateralThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("wethValue", wethValue);
        console.log("wbtcValue", wbtcValue);
        console.log("totalSupply", totalSupply);
        console.log("timesMintIsCalled", handler.timesMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNeverRevert() public view {
        dsce.getUsdValue(weth, 1000000000000000000000000000000000000000);
        dsce.getAccountCollateralValue(address(this));
        dsce.getTokenAmountFromUsd(weth, 1000000000000000000000000000000000000000);
        dsce.getPrecision();
        dsce.getAdditionalFeedPrecision();
        dsce.getLiquidationThreshold();
        dsce.getLiquidationBonus();
        dsce.getLiquidationPrecision();
        dsce.getMinHealthFactor();
        dsce.getCollateralTokens();
        dsce.getDsc();
        dsce.getCollateralTokenPriceFeed(weth);
        dsce.getAccountInformation(address(this));
        dsce.getCollateralBalanceOfUser(address(this), weth);
    }
}
