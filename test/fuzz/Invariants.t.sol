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
import {Handler} from "./Handler.t.sol"
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

contract Invariants is StdInvariant, Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }
}
