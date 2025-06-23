// SPDX-License-Identifier: MIT

// This file has our invariants aka system properties that should always hold

// what are our invariants? (what are those properties that should always be true)
// 1. The total supply of DSC(Debt) should be less than the total value of collateral
// 2. Getter view functions should never revert => evergreen invariant

pragma solidity ^0.8.20;

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol"

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();
    }   
}