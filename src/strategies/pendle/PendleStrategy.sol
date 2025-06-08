// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseSparkleXStrategy} from "../BaseSparkleXStrategy.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {Constants} from "../../utils/Constants.sol";
import {IPMarketV3} from "@pendle/contracts/interfaces/IPMarketV3.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "@pendle/contracts/interfaces/IStandardizedYield.sol";

// Structs for multi-PT management
struct PTInfo {
    address ptToken; // PT token address
    address market; // Pendle market address
    address syToken; // SY token address
    address underlyingYield; // underlying yieldToken of this market
    address underlyingOracle; // external oracle for underlying yieldToken of this market
    uint256 targetWeight;
}

contract PendleStrategy is BaseSparkleXStrategy {
    using Math for uint256;
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////////////////////
    // Constants and State Variables
    ///////////////////////////////
    address public _pendleRouter;
    mapping(address => address) _assetOracles;

    // Pendle contract addresses (Ethereum mainnet)
    address public constant PENDLE_ROUTER_V4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    bytes4 public constant TARGET_SELECTOR_BUY = hex"c81f847a"; //swapExactTokenForPt()
    bytes4 public constant TARGET_SELECTOR_SELL = hex"594a88cc"; //swapExactPtForToken()
    bytes4 public constant TARGET_SELECTOR_REDEEM = hex"47f1de22"; //redeemPyToToken()
    bytes4 public constant TARGET_SELECTOR_REFLECT = hex"9fa02c86"; //callAndReflect()

    uint256 public constant MAX_PT_TOKENS = 10;

    // PT portfolio management
    mapping(address => PTInfo) public ptInfos;
    EnumerableSet.AddressSet private activePTs;

    ///////////////////////////////
    // Events
    ///////////////////////////////
    event PTAdded(
        address indexed market, address indexed underlyingYieldToken, address indexed _caller, uint256 weight
    );
    event PTRemoved(address indexed ptToken, address indexed _caller);
    event PTTokensRollover(
        address indexed fromPTToken, address indexed toPTToken, uint256 fromPTAmount, uint256 toPTmount
    );
    event PTTokensPurchased(address indexed assetToken, address indexed ptToken, uint256 assetAmount, uint256 ptAmount);
    event PTTokensSold(address indexed assetToken, address indexed ptToken, uint256 ptAmount, uint256 assetAmount);
    event PTTokensRedeemed(address indexed assetToken, address indexed ptToken, uint256 ptAmount, uint256 assetAmount);
    event AssetOracleAdded(address indexed assetToken, address indexed oracle);

    constructor(ERC20 token, address vault, address pendleRouter, address assetOracle)
        BaseSparkleXStrategy(token, vault)
    {
        if (assetOracle == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _assetOracles[address(token)] = assetOracle;
        emit AssetOracleAdded(address(token), assetOracle);

        _pendleRouter = pendleRouter == Constants.ZRO_ADDR ? PENDLE_ROUTER_V4 : pendleRouter;
    }

    function setAssetOracle(address _asset, address _oracle) external onlyOwner {
        if (_oracle == Constants.ZRO_ADDR || _asset == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _assetOracles[_asset] = _oracle;
        emit AssetOracleAdded(_asset, _oracle);
    }

    ///////////////////////////////
    // Strategy Implementation
    ///////////////////////////////

    function totalAssets() public view override returns (uint256 totalManagedAssets) {
        return _asset.balanceOf(address(this)) + getAllPTAmountsInAsset();
    }

    function assetsInCollection() external view override returns (uint256 inCollectionAssets) {
        return 0;
    }

    function allocate(uint256 amount) public override onlyStrategistOrVault {
        amount = _capAllocationAmount(amount);
        if (amount == 0) {
            return;
        }
        _asset.safeTransferFrom(_vault, address(this), amount);
        emit AllocateInvestment(msg.sender, amount);
    }

    function collect(uint256 amount) public override onlyStrategistOrVault {
        if (amount == 0) {
            return;
        }
        amount = _returnAssetToVault(amount);
        emit CollectInvestment(msg.sender, amount);
    }

    /**
     * @dev ensure PT in all pendle market has been swapped back to asset
     */
    function collectAll() external override onlyStrategistOrVault {
        if (getAllPTAmountsInAsset() > 0) {
            revert Constants.PT_STILL_IN_USE();
        }
        uint256 _assetBalance = _returnAssetToVault(type(uint256).max);
        emit CollectInvestment(msg.sender, _assetBalance);
    }

    ///////////////////////////////
    // PT Management Functions
    ///////////////////////////////

    /**
     * @notice Add a new Pendle market to this strategy
     * @param marketAddress Pendle market address
     * @param underlyingYieldToken underlying yieldToken address of the pendle market
     * @param underlyingOracleAddress external oracle address for underlying yieldToken
     * @param weight allocation weight in basis points for the pendle market to be added
     */
    function addPT(address marketAddress, address underlyingYieldToken, address underlyingOracleAddress, uint256 weight)
        external
        onlyOwner
    {
        if (
            marketAddress == Constants.ZRO_ADDR || underlyingYieldToken == Constants.ZRO_ADDR
                || underlyingOracleAddress == Constants.ZRO_ADDR
        ) {
            revert Constants.INVALID_MARKET_TO_ADD();
        }
        (IStandardizedYield _syToken, IPPrincipalToken _ptToken,) = IPMarketV3(marketAddress).readTokens();
        if (ptInfos[address(_ptToken)].ptToken != Constants.ZRO_ADDR) {
            revert Constants.PT_ALREADY_EXISTS();
        }
        if (activePTs.length() >= MAX_PT_TOKENS) {
            revert Constants.MAX_PT_EXCEEDED();
        }
        // Verify market not expire
        if (IPMarketV3(marketAddress).isExpired()) {
            revert Constants.PT_ALREADY_MATURED();
        }

        // Create PT info
        ptInfos[address(_ptToken)] = PTInfo({
            ptToken: address(_ptToken),
            market: marketAddress,
            syToken: address(_syToken),
            underlyingYield: underlyingYieldToken,
            underlyingOracle: underlyingOracleAddress,
            targetWeight: weight
        });
        _assetOracles[underlyingYieldToken] = underlyingOracleAddress;
        emit AssetOracleAdded(underlyingYieldToken, underlyingOracleAddress);
        activePTs.add(address(_ptToken));
        emit PTAdded(marketAddress, underlyingYieldToken, msg.sender, weight);
    }

    /**
     * @notice Remove a Pendle market specified by given PT token from this strategy
     * @dev all PT of given market held in this strategy will be swapped back to asset of this strategy
     * @param ptToken PT token address of the pendle market to be removed
     */
    function removePT(address ptToken, bytes calldata _swapData) external onlyOwner {
        PTInfo memory ptInfo = ptInfos[ptToken];
        if (ptInfo.ptToken == Constants.ZRO_ADDR) {
            revert Constants.PT_NOT_FOUND();
        }

        uint256 _ptBalanace = ERC20(ptToken).balanceOf(address(this));
        if (_ptBalanace > 0 && _swapData.length > 0) {
            if (IPMarketV3(ptInfo.market).isExpired()) {
                redeemPTForAsset(address(_asset), ptToken, _ptBalanace, _swapData);
            } else {
                sellPTForAsset(address(_asset), ptToken, _ptBalanace, _swapData);
            }
        }

        activePTs.remove(ptToken);
        delete ptInfos[ptToken];

        emit PTRemoved(ptToken, msg.sender);
    }

    ///////////////////////////////
    // Trading Functions
    ///////////////////////////////

    function rolloverPT(address ptTokenFrom, address ptTokenTo, uint256 ptFromAmount, bytes calldata _swapData)
        external
        onlyStrategistOrOwner
    {
        if (ptInfos[ptTokenFrom].ptToken == Constants.ZRO_ADDR) {
            revert Constants.PT_NOT_FOUND();
        }
        _checkMarketValidity(ptTokenTo, true);

        ptFromAmount = _capAmountByBalance(ERC20(ptTokenFrom), ptFromAmount, false);
        uint256 _minOut = _getMinExpectedPTForRollover(ptTokenFrom, ptTokenTo, ptFromAmount);
        bytes4 _funcSelector = _getFunctionSelector(_swapData);
        if (_funcSelector != TARGET_SELECTOR_REFLECT) {
            revert Constants.INVALID_SWAP_CALLDATA();
        }
        _approveToken(ptTokenFrom, _swapper);
        uint256 ptReceived = TokenSwapper(_swapper).chainSwapWithPendleRouter(
            _pendleRouter, ptTokenFrom, ptTokenTo, ptFromAmount, _minOut, _swapData
        );
        emit PTTokensRollover(ptTokenFrom, ptTokenTo, ptFromAmount, ptReceived);
    }

    /**
     * @notice Buy specific PT tokens with USDC
     * @param ptToken PT token to buy
     * @param assetAmount Amount of USDC to spend
     * @param _swapData calldata from pendle SDK
     */
    function buyPTWithAsset(address _assetToken, address ptToken, uint256 assetAmount, bytes calldata _swapData)
        external
        onlyStrategistOrOwner
    {
        _checkMarketValidity(ptToken, true);
        if (_assetToken == address(_asset)) {
            uint256 _assetBalance = _asset.balanceOf(address(this));
            if (assetAmount > _assetBalance) {
                allocate(assetAmount - _assetBalance);
            }
        }

        assetAmount = _capAmountByBalance(ERC20(_assetToken), assetAmount, false);
        uint256 _minOut = _getMinExpectedPT(_assetToken, ptToken, assetAmount);
        bytes4 _funcSelector = _getFunctionSelector(_swapData);
        if (_funcSelector != TARGET_SELECTOR_BUY) {
            revert Constants.INVALID_SWAP_CALLDATA();
        }
        _approveToken(_assetToken, _swapper);
        uint256 ptReceived = TokenSwapper(_swapper).swapWithPendleRouter(
            _pendleRouter, _assetToken, ptToken, assetAmount, _minOut, _swapData
        );
        emit PTTokensPurchased(_assetToken, ptToken, assetAmount, ptReceived);
    }

    /**
     * @notice Sell specific PT tokens for USDC
     * @param ptToken PT token to sell
     * @param ptAmount Amount of PT tokens to sell
     * @param _swapData calldata from pendle SDK
     */
    function sellPTForAsset(address _assetToken, address ptToken, uint256 ptAmount, bytes calldata _swapData)
        public
        onlyStrategistOrOwner
    {
        _checkMarketValidity(ptToken, true);
        uint256 assetAmount = _swapPTForAsset(_assetToken, ptToken, ptAmount, _swapData, TARGET_SELECTOR_SELL);
        emit PTTokensSold(_assetToken, ptToken, ptAmount, assetAmount);
    }

    /**
     * @notice Redeem mature PT tokens for asset
     * @param ptToken PT token to redeem
     * @param ptAmount Amount of PT tokens to redeem
     * @param _swapData calldata from pendle SDK
     */
    function redeemPTForAsset(address _assetToken, address ptToken, uint256 ptAmount, bytes calldata _swapData)
        public
        onlyStrategistOrOwner
    {
        _checkMarketValidity(ptToken, false);
        uint256 assetAmount = _swapPTForAsset(_assetToken, ptToken, ptAmount, _swapData, TARGET_SELECTOR_REDEEM);
        emit PTTokensRedeemed(_assetToken, ptToken, ptAmount, assetAmount);
    }

    ///////////////////////////////
    // Internal Functions
    ///////////////////////////////

    function _swapPTForAsset(
        address _assetToken,
        address ptToken,
        uint256 ptAmount,
        bytes calldata _swapData,
        bytes4 _targetSelector
    ) internal returns (uint256) {
        ptAmount = _capAmountByBalance(ERC20(ptToken), ptAmount, false);
        uint256 _minOut = _getMinExpectedAsset(_assetToken, ptToken, ptAmount);
        bytes4 _funcSelector = _getFunctionSelector(_swapData);
        if (_funcSelector != _targetSelector) {
            revert Constants.INVALID_SWAP_CALLDATA();
        }
        _approveToken(ptToken, _swapper);
        return TokenSwapper(_swapper).swapWithPendleRouter(
            _pendleRouter, ptToken, _assetToken, ptAmount, _minOut, _swapData
        );
    }

    /* 
     * @dev By default SY is 1:1 mapping of underlying yieldToken 
     * @dev https://docs.pendle.finance/Developers/Contracts/StandardizedYield#standard-sys
     */
    function _syToUnderlyingRate(address _syToken) internal view returns (uint256) {
        return Constants.ONE_ETHER;
    }

    function _getMinExpectedPTForRollover(address _ptTokenFrom, address _ptTokenTo, uint256 _ptAmountFrom)
        internal
        view
        returns (uint256)
    {
        uint256 _fromInAsset = _getAmountInAsset(address(_asset), _ptTokenFrom, _ptAmountFrom);
        uint256 _outInTheory = _getAmountInPT(address(_asset), _ptTokenTo, _fromInAsset);
        return _outInTheory;
    }

    function _getMinExpectedPT(address _assetToken, address _ptToken, uint256 _assetIn)
        internal
        view
        returns (uint256)
    {
        uint256 _outInTheory = _getAmountInPT(_assetToken, _ptToken, _assetIn);
        return _outInTheory;
    }

    function _getMinExpectedAsset(address _assetToken, address _ptToken, uint256 _ptIn)
        internal
        view
        returns (uint256)
    {
        uint256 _outInTheory = _getAmountInAsset(_assetToken, _ptToken, _ptIn);
        return _outInTheory;
    }

    function _getAmountInAsset(address _assetToken, address ptToken, uint256 ptAmount)
        internal
        view
        returns (uint256)
    {
        return ptAmount * getPTPriceInAsset(_assetToken, ptToken)
            * Constants.convertDecimalToUnit(ERC20(_assetToken).decimals())
            / (Constants.convertDecimalToUnit(ERC20(ptToken).decimals()) * Constants.ONE_ETHER);
    }

    function _getAmountInPT(address _assetToken, address ptToken, uint256 assetAmount)
        internal
        view
        returns (uint256)
    {
        return assetAmount * Constants.ONE_ETHER * Constants.convertDecimalToUnit(ERC20(ptToken).decimals())
            / (Constants.convertDecimalToUnit(ERC20(_assetToken).decimals()) * getPTPriceInAsset(_assetToken, ptToken));
    }

    function _getFunctionSelector(bytes calldata _data) internal pure returns (bytes4) {
        bytes4 selector = bytes4(_data[:4]);
        return selector;
    }

    function _checkMarketValidity(address _ptToken, bool _beforeExpire) internal {
        PTInfo memory ptInfo = ptInfos[_ptToken];
        if (ptInfo.ptToken == Constants.ZRO_ADDR) {
            revert Constants.PT_NOT_FOUND();
        }
        if (_beforeExpire && IPMarketV3(ptInfo.market).isExpired()) {
            revert Constants.PT_ALREADY_MATURED();
        } else if (!_beforeExpire && !IPMarketV3(ptInfo.market).isExpired()) {
            revert Constants.PT_NOT_MATURED();
        }
    }

    ///////////////////////////////
    // convenient view Functions
    ///////////////////////////////

    /* 
     * @dev calculate the amount of PT currently held in this strategy in asset deomination
     */
    function getPTAmountInAsset(address ptToken) public view returns (uint256) {
        uint256 ptBalance = ERC20(ptToken).balanceOf(address(this));
        if (ptBalance == 0) {
            return ptBalance;
        } else {
            return _getAmountInAsset(address(_asset), ptToken, ptBalance);
        }
    }

    /* 
     * @dev calculate the price of PT in asset deomination scaled by 1e18
     */
    function getPTPrice(address ptToken) public view returns (uint256) {
        return getPTPriceInAsset(address(_asset), ptToken);
    }

    function getPTPriceInAsset(address _assetToken, address ptToken) public view returns (uint256) {
        PTInfo memory ptInfo = ptInfos[ptToken];
        // 1:1 value at maturity
        uint256 _ptPriceInSY = IPMarketV3(ptInfo.market).isExpired()
            ? Constants.ONE_ETHER
            : TokenSwapper(_swapper).getPTPriceInSYFromPendle(ptInfo.market, 0);
        uint256 _pt2UnderlyingRateScaled = _ptPriceInSY * _syToUnderlyingRate(ptInfo.syToken) * Constants.ONE_ETHER
            / (Constants.ONE_ETHER * Constants.ONE_ETHER);

        if (ptInfo.underlyingYield == _assetToken) {
            return _pt2UnderlyingRateScaled;
        }

        // ensure asset and underlying oracles return prices in same base unit like USD
        (int256 _underlyingPrice,, uint8 _decimal) =
            TokenSwapper(_swapper).getPriceFromChainLink(ptInfo.underlyingOracle);
        (int256 _assetPrice,, uint8 _assetPriceDecimal) =
            TokenSwapper(_swapper).getPriceFromChainLink(_assetOracles[_assetToken]);
        return _pt2UnderlyingRateScaled * Constants.convertDecimalToUnit(_assetPriceDecimal) * uint256(_underlyingPrice)
            / (Constants.convertDecimalToUnit(_decimal) * uint256(_assetPrice));
    }

    function getActivePTs() public view returns (address[] memory) {
        return activePTs.values();
    }

    function getAllPTAmountsInAsset() public view returns (uint256) {
        uint256 totalPTAmountInAsset;
        uint256 length = activePTs.length();
        for (uint256 i = 0; i < length; i++) {
            totalPTAmountInAsset += getPTAmountInAsset(activePTs.at(i));
        }
        return totalPTAmountInAsset;
    }
}
