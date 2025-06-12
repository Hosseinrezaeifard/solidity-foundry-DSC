// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
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
// view & pure functions

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/*
 * @title DSCEngine
 * @author Patrick Collins
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    /* ============================ Errors ============================ */
    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();

    /* ============================ State Variables ============================ */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATOR_BONUS = 110;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount))
        private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /* ============================ Events ============================ */
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    event CollateralRedeemed(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );

    /* ============================ Modifiers ============================ */
    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) revert DSCEngine__MustBeMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        // if there is no price feed address corresponded to that token, then it's not allowed
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /* ============================ Functions ============================ */
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesLengthsMustBeTheSame();
        }
        // These feeds will be the USD pairs
        // For example ETH / USD or MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /* ============================ External Functions ============================ */
    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        // if mintDSC fails, it will revert the transaction including the depositCollateral
        // so the user's collateral will not be deposited
        // atomic transactions are one of the beauties of solidity :)
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /*
     * @notice Follows CEI pattern
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * this function is gonna be used to deposit collateral by a user
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // we're gonna add the amount of collateral to the msg.sender address's balance
        // the strucutre is a nested mapping
        // mapping(address user => mapping(address token => uint256 amount))
        // it's like this:
        //      [msg.sender][wethAddress][amount] == something;
        //      [msg.sender][wbtcAddress][amount] == something;

        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;

        // emit an event to let client know that the collateral has been deposited
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );

        // send the token to the contract
        // we don't need to check health factor here because we're not minting DSC
        // transferFrom is a function that allows us to transfer tokens from one address to another
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) revert DSCEngine__TransferFailed();
    }

    // in order to redeem collateral
    // 1. health factor must be above 1 AFTER collateral is pulled
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        // do our inside accounting
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] -= amountCollateral;

        // emit an event to let client know that the collateral has been redeemed
        emit CollateralRedeemed(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );

        bool success = IERC20(tokenCollateralAddress).transfer(
            msg.sender,
            amountCollateral
        );
        if (!success) revert DSCEngine__TransferFailed();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're withdrawing
     * @param amountCollateral: The amount of collateral you're withdrawing
     * @param amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */
    function redeemCollateralForDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /* @notice Follows CEI pattern
     * @param amountDscToMint: The amount of DSC to mint
     * @notice they must have more collateral value than minimum threshold
     */
    function mintDSC(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    function burnDSC(uint256 _amount) public moreThanZero(_amount) {
        s_DSCMinted[msg.sender] -= _amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(_amount);
    }

    // If we do start nearing undercollateralized, we need someone (liquidator) to liquidate people
    // $100 ETH backing $50 DSC
    // then the price of eth tanks to $20
    // $20 ETH backing $50 DSC => so the DSC isn't worth $1
    // If someone is almost undercollateralized, we will pay liquidator to liquidate them
    // for example $75 eth backing $50 DSC => $75 / $50 = 1.5 => 150% < 200% => undercollateralized
    // or $75 eth backing $100 DSC => ($75 * threshold(50)) / 100 = $37.5 => 37.5 / 50 = 0.75 => undercollateralized
    // so the liquidator will take the collateral and sell it to cover the debt

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        // 1. Check health factor of the user to see if the user is undercollateralized and liquidatable
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // We want to burn DSC "debt" and take their collateral
        // Bad user: $140 ETH, $100 DSC
        // debtToCover = $100 DSC
        // $100 DSC = ??? ETH? because we're giving the liquidator debt amount worth of eth + 10% bonus in the uint of collateral
        // ??? ETH?
        uint256 collateralAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );

        // + 10% bonus

        // So we are giving the liquidator $110 worth of collateral for 100 DSC Debt to get covered
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a treasury
        uint256 bonusCollateral = (collateralAmountFromDebtCovered *
            LIQUIDATOR_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = collateralAmountFromDebtCovered +
            bonusCollateral;
    }

    function getHealthFactor() external view {}

    /* ============================ Private & Internal View Functions ============================ */

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /*
     * @notice how close to liquidation is the user?
     * if a user goes below 1, they get liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral value
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return
            (collateralAdjustedForThreshold * LIQUIDATION_PRECISION) /
            totalDscMinted; // if this is below 1, the user can get liquidated
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /* ============================ Public & External View Functions ============================ */

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256) {
        // loop through each collateral token, get the amount they have deposited, and map to price to get USD value
        uint256 totalCollateralValueInUsd = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(
        address token,
        uint256 amount
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from Chainlink will be 1000 * 1e8
        // usdValueOfCollateral = ethValueInUsd (WITH 8 DECIMALS) * amount (IN WEI) = (1000 * 1e8) * 1000 * 1e18
        // usdValueOfCollateral = ethValueInUsd * amount = ((1000 * 1e8 * 1e10) * 1000 * 1e18) / 1e18
        // usdValueOfCollateral = ethValueInUsd * amount = ((1000 * 1e8 * ADDITIONAL_FEED_PRECISION) * 1000 * 1e18) / 1e18
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION * amount)) / PRECISION;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return
            (usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
}
