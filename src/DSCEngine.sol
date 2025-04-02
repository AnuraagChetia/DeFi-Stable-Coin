//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Anuraag Chetia
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, showld the value of all collateral <= the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on MakerDAO DSS (DAI) System.
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////////////////////
    /////////// ERRORS //////////////
    /////////////////////////////////

    error DSCEngine__NeedMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOk();
    error DSCEngine__HealthFactorNotImproved();

    /////////////////////////////////
    /////////// TYPES ///////////////
    /////////////////////////////////
    using OracleLib for AggregatorV3Interface;
    /////////////////////////////////
    /////// STATE VARIABLES /////////
    /////////////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% liquidation bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /////////////////////////////////
    /////////// EVENTS //////////////
    /////////////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    /////////////////////////////////
    /////////// MODIFIERS ///////////
    /////////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /////////////////////////////////
    /////////// FUNCTIONS ///////////
    /////////////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////////////
    //////EXTERNAL FUNCTIONS ////////
    /////////////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of dsc to mint
     * @notice this function will deposit your collateral and mint dsc in one transaction
     */
    function depositCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    /**
     * @notice Follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool successs = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!successs) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress The address of the token to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of dsc to burn
     * @notice This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral already checks health factor
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Follows CEI
     * @param amountDscToMint The amount of DSC to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_dsc.mint(msg.sender, amountDscToMint);
        if (!success) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDSC(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit... but just in case
    }

    /**
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The address of the user to liquidate who has broken the health factor. Their healthfactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This funnction working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivize the liquidator
     * For Example, if the price of the collateral fell plummeted before anyone could be liquidated
     *
     * @notice Follows CEI
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check health factor
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOk();
        }

        // burn their DSC (which is in debt)
        // and take their collateral
        uint256 collateralAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        // also give them 10% bonus for liquidating
        uint256 bonusCollateral = (collateralAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToLiquidate = collateralAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToLiquidate);

        // burn the dsc
        _burnDSC(debtToCover, user, msg.sender);

        // check the health factor again
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // check if the health factor is broken of the liquidator
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    /////////////////////////////////////////////////
    ////// PRIVATE & INTERNAL VIEW FUNCTIONS ////////
    /////////////////////////////////////////////////
    /**
     * @notice This function is used to get the account information for a user
     * @param user The address of the user to get the account information for
     * returns totalDSCMinted  - The total amount of DSC minted by the user
     * returns collateralValueInUsd - The total value of the collateral in USD
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];

        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, they can get liquidated
     *
     * @param user The address of the user to check the health factor for
     * @return healthFactor - The health factor of the user
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // Check Health Factor
        uint256 userHealthFactor = _healthFactor(user);
        // Revert if Health Factor is broken
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken(userHealthFactor);
        }
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
        moreThanZero(amountCollateral)
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factor being broken
     */
    function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom)
        private
        moreThanZero(amountDscToBurn)
    {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /////////////////////////////////////////////////
    ////// PUBLIC & EXTERNAL VIEW FUNCTIONS /////////
    /////////////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token and check the amount of collateral deposited by the user
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256 valueInUsd) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        return (uint256(price) * amount * ADDITIONAL_FEED_PRECISION) / PRECISION;
        // CL returns price in 8 decimals, so we need to multiply by 1e10 to get 19 decimals
        // We also need to divide by 1e18 to get the value in USD
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address collateral, address user) public view returns (uint256) {
        return s_collateralDeposited[user][collateral];
    }
}
