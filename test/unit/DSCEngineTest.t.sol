// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DSCEngine public dscEngine;
    DecentralizedStableCoin public dsc;
    DeployDSC public deployer;
    HelperConfig public config;
    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant USER_STARTING_BALANCE = 10 ether;

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    // Events
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();
        // we're just giving user 10 ether of weth
        ERC20Mock(weth).mint(USER, USER_STARTING_BALANCE);
    }

    /* ============================ Start Constructor Tests ============================ */
    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }
    /* ============================ End Constructor Tests ============================ */

    /* ============================ Start Price Tests ============================ */
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        assertEq(actualUsd, expectedUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }
    /* ============================ End Price Tests ============================ */

    /* ============================ Start Deposit Collateral Tests ============================ */
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock tt = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(tt), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo()
        public
        depositedCollateral
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine
            .getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralAmount = dscEngine.getTokenAmountFromUsd(
            weth,
            collateralValueInUsd
        );
        uint256 expectedCollateralValueInUsd = dscEngine.getUsdValue(
            weth,
            AMOUNT_COLLATERAL
        );
        uint256 amountDeposited = dscEngine.getCollateralDeposited(USER, weth);
        assertEq(amountDeposited, AMOUNT_COLLATERAL);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedCollateralAmount, AMOUNT_COLLATERAL);
        assertEq(expectedCollateralValueInUsd, collateralValueInUsd);
    }

    function testCanDepositCollateralAndEmitEventUsingRecordLogs() public {
        vm.recordLogs();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        // The event signature hash (topic[0])
        bytes32 expectedEventSignature = keccak256(
            "CollateralDeposited(address,address,uint256)"
        );

        // Find the CollateralDeposited event (it might not be the first log)
        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedEventSignature) {
                // Check the indexed parameters
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(USER)))); // user (indexed)
                assertEq(logs[i].topics[2], bytes32(uint256(uint160(weth)))); // token (indexed)
                assertEq(logs[i].topics[3], bytes32(AMOUNT_COLLATERAL)); // amount (indexed)
                eventFound = true;
                break;
            }
        }
        assertTrue(eventFound, "CollateralDeposited event not found");
    }

    function testCanDepositCollateralAndEmitEventUsingExpectEmit() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        // 1. Set up expectation BEFORE the action
        vm.expectEmit(true, true, true, false, address(dscEngine));
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);

        // 2. Trigger the function that should emit the event
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }
    /* ============================ End Deposit Collateral Tests ============================ */
}
