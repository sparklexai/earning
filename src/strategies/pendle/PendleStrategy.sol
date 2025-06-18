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
import {PendleHelper} from "./PendleHelper.sol";

// Structs for multi-PT management
struct PTInfo {
    address ptToken; // PT token address
    address market; // Pendle market address
    address syToken; // SY token address
    address underlyingYield; // underlying yieldToken of this market
    address underlyingOracle; // external oracle for underlying yieldToken of this market
    uint32 syOracleTwapSeconds; // use 900 or 1800 for most markets
}

contract PendleStrategy is BaseSparkleXStrategy {
    using Math for uint256;
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////////////////////
    // Constants and State Variables
    ///////////////////////////////
    mapping(address => address) _assetOracles;
    address public _pendleHelper;

    // Pendle contract addresses (Ethereum mainnet)
    address public constant PENDLE_ROUTER_V4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    uint256 public constant MAX_PT_TOKENS = 10;

    // PT portfolio management
    mapping(address => PTInfo) public ptInfos;
    EnumerableSet.AddressSet private activePTs;

    ///////////////////////////////
    // Events
    ///////////////////////////////
    event PendleHelperChanged(address indexed _old, address indexed _new);
    event PTAdded(
        address indexed market, address indexed underlyingYieldToken, address indexed _caller, uint32 twapSeconds
    );
    event PTRemoved(address indexed ptToken, address indexed _caller);
    event PTTokensRollover(
        address indexed fromPTToken, address indexed toPTToken, uint256 fromPTAmount, uint256 toPTmount
    );
    event PTTokensPurchased(address indexed assetToken, address indexed ptToken, uint256 assetAmount, uint256 ptAmount);
    event PTTokensSold(address indexed assetToken, address indexed ptToken, uint256 ptAmount, uint256 assetAmount);
    event PTTokensRedeemed(address indexed assetToken, address indexed ptToken, uint256 ptAmount, uint256 assetAmount);
    event AssetOracleAdded(address indexed assetToken, address indexed oracle);

    constructor(ERC20 token, address vault, address assetOracle) BaseSparkleXStrategy(token, vault) {
        if (assetOracle == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _assetOracles[address(token)] = assetOracle;
        emit AssetOracleAdded(address(token), assetOracle);
    }

    function setAssetOracle(address _asset, address _oracle) external onlyOwner {
        if (_oracle == Constants.ZRO_ADDR || _asset == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _assetOracles[_asset] = _oracle;
        emit AssetOracleAdded(_asset, _oracle);
    }

    function setPendleHelper(address _newHelper) external onlyOwner {
        if (_newHelper == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        emit PendleHelperChanged(_pendleHelper, _newHelper);
        _pendleHelper = _newHelper;
    }

    ///////////////////////////////
    // Strategy Implementation
    ///////////////////////////////

    function totalAssets() public view override returns (uint256 totalManagedAssets) {
        return _asset.balanceOf(address(this)) + getAllPTAmountsInAsset();
    }

    function assetsInCollection() external pure override returns (uint256 inCollectionAssets) {
        return 0;
    }

    /**
     * @dev simply transfer _asset with given amount from vault to this strategy
     */
    function allocate(uint256 amount, bytes calldata /* _extraAction */ ) public override onlyStrategistOrVault {
        amount = _capAllocationAmount(amount);
        if (amount == 0) {
            return;
        }
        SafeERC20.safeTransferFrom(_asset, _vault, address(this), amount);
        emit AllocateInvestment(msg.sender, amount);
    }

    function collect(uint256 amount, bytes calldata /* _extraAction */ ) external override onlyStrategistOrVault {
        if (amount == 0) {
            return;
        }
        amount = _returnAssetToVault(amount);
        emit CollectInvestment(msg.sender, amount);
    }

    /**
     * @dev ensure PT in all pendle market has been swapped back to asset
     */
    function collectAll(bytes calldata /* _extraAction */ ) external override onlyStrategistOrVault {
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
     * @param twapSeconds by default 900 or 1800 seconds for most market
     */
    function addPT(
        address marketAddress,
        address underlyingYieldToken,
        address underlyingOracleAddress,
        uint32 twapSeconds
    ) external onlyOwner {
        if (
            marketAddress == Constants.ZRO_ADDR || underlyingYieldToken == Constants.ZRO_ADDR
                || underlyingOracleAddress == Constants.ZRO_ADDR
        ) {
            revert Constants.INVALID_MARKET_TO_ADD();
        }
        if (activePTs.length() >= MAX_PT_TOKENS) {
            revert Constants.MAX_PT_EXCEEDED();
        }
        // Verify market not expire
        if (IPMarketV3(marketAddress).isExpired()) {
            revert Constants.PT_ALREADY_MATURED();
        }
        (IStandardizedYield _syToken, IPPrincipalToken _ptToken,) = IPMarketV3(marketAddress).readTokens();
        if (ptInfos[address(_ptToken)].ptToken != Constants.ZRO_ADDR) {
            revert Constants.PT_ALREADY_EXISTS();
        }

        // Create PT info
        ptInfos[address(_ptToken)] = PTInfo({
            ptToken: address(_ptToken),
            market: marketAddress,
            syToken: address(_syToken),
            underlyingYield: underlyingYieldToken,
            underlyingOracle: underlyingOracleAddress,
            syOracleTwapSeconds: twapSeconds
        });
        _assetOracles[underlyingYieldToken] = underlyingOracleAddress;
        emit AssetOracleAdded(underlyingYieldToken, underlyingOracleAddress);
        activePTs.add(address(_ptToken));
        emit PTAdded(marketAddress, underlyingYieldToken, msg.sender, twapSeconds);
    }

    /**
     * @notice Remove a Pendle market specified by given PT token from this strategy
     * @dev all PT of given market held in this strategy will be swapped back to asset of this strategy
     * @param ptToken PT token address of the pendle market to be removed
     * @param _swapData calldata from pendle SDK for possible redeem or swap
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

    /**
     * @notice Switch to ptTokenTo from ptTokenFrom
     * @param ptTokenFrom the PT market to exit (either expire or active)
     * @param ptTokenTo the PT market to enter (must be active)
     * @param ptFromAmount Amount of ptTokenFrom to swap
     * @param _swapData calldata from pendle SDK
     */
    function rolloverPT(address ptTokenFrom, address ptTokenTo, uint256 ptFromAmount, bytes calldata _swapData)
        external
        onlyStrategistOrOwner
        returns (uint256)
    {
        if (ptInfos[ptTokenFrom].ptToken == Constants.ZRO_ADDR) {
            revert Constants.PT_NOT_FOUND();
        }
        _checkMarketValidity(ptTokenTo, true);
        _approveToken(ptTokenFrom, _pendleHelper);
        uint256 ptReceived = PendleHelper(_pendleHelper)._swapPTForRollOver(
            ptTokenFrom,
            ptTokenTo,
            ptFromAmount,
            _swapData,
            TokenSwapper(_swapper).TARGET_SELECTOR_REFLECT(),
            address(_asset)
        );
        emit PTTokensRollover(ptTokenFrom, ptTokenTo, ptFromAmount, ptReceived);
        return ptReceived;
    }

    /**
     * @notice Buy specific PT tokens with given asset token
     * @param _assetToken purchase PT with this asset
     * @param ptToken PT token to buy
     * @param assetAmount Amount of asset token to spend
     * @param _swapData calldata from pendle SDK
     */
    function buyPTWithAsset(address _assetToken, address ptToken, uint256 assetAmount, bytes calldata _swapData)
        external
        onlyStrategistOrOwner
        returns (uint256)
    {
        _checkMarketValidity(ptToken, true);
        if (_assetToken == address(_asset)) {
            uint256 _assetBalance = _asset.balanceOf(address(this));
            if (assetAmount > _assetBalance) {
                allocate(assetAmount - _assetBalance, _swapData);
            }
        }
        _approveToken(_assetToken, _pendleHelper);
        uint256 ptReceived = PendleHelper(_pendleHelper)._swapAssetForPT(
            _assetToken, ptToken, assetAmount, _swapData, TokenSwapper(_swapper).TARGET_SELECTOR_BUY()
        );
        emit PTTokensPurchased(_assetToken, ptToken, assetAmount, ptReceived);
        return ptReceived;
    }

    /**
     * @notice Sell specific PT tokens for given asset token
     * @param _assetToken swap PT (before expire) for this asset
     * @param ptToken PT token to sell
     * @param ptAmount Amount of PT tokens to sell
     * @param _swapData calldata from pendle SDK
     */
    function sellPTForAsset(address _assetToken, address ptToken, uint256 ptAmount, bytes calldata _swapData)
        public
        onlyStrategistOrOwner
        returns (uint256)
    {
        _checkMarketValidity(ptToken, true);
        _approveToken(ptToken, _pendleHelper);
        uint256 assetAmount = PendleHelper(_pendleHelper)._swapPTForAsset(
            _assetToken, ptToken, ptAmount, _swapData, TokenSwapper(_swapper).TARGET_SELECTOR_SELL()
        );
        emit PTTokensSold(_assetToken, ptToken, ptAmount, assetAmount);
        return assetAmount;
    }

    /**
     * @notice Redeem mature PT tokens for given asset token
     * @param _assetToken redeem PT (after expire) for this asset
     * @param ptToken PT token to redeem
     * @param ptAmount Amount of PT tokens to redeem
     * @param _swapData calldata from pendle SDK
     */
    function redeemPTForAsset(address _assetToken, address ptToken, uint256 ptAmount, bytes calldata _swapData)
        public
        onlyStrategistOrOwner
        returns (uint256)
    {
        _checkMarketValidity(ptToken, false);
        _approveToken(ptToken, _pendleHelper);
        uint256 assetAmount = PendleHelper(_pendleHelper)._swapPTForAsset(
            _assetToken, ptToken, ptAmount, _swapData, TokenSwapper(_swapper).TARGET_SELECTOR_REDEEM()
        );
        emit PTTokensRedeemed(_assetToken, ptToken, ptAmount, assetAmount);
        return assetAmount;
    }

    ///////////////////////////////
    // Internal Functions
    ///////////////////////////////

    /* 
     * @dev By default SY is 1:1 mapping of underlying yieldToken 
     * @dev https://docs.pendle.finance/Developers/Contracts/StandardizedYield#standard-sys
     */
    function _syToUnderlyingRate(address /* _syToken */ ) internal pure returns (uint256) {
        return Constants.ONE_ETHER;
    }

    function _checkMarketValidity(address _ptToken, bool _beforeExpire) internal view {
        PTInfo memory ptInfo = ptInfos[_ptToken];
        if (ptInfo.ptToken == Constants.ZRO_ADDR) {
            revert Constants.PT_NOT_FOUND();
        }
        PendleHelper(_pendleHelper)._checkValidityWithMarket(_ptToken, ptInfo.market, _beforeExpire);
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
            return PendleHelper(_pendleHelper)._getAmountInAsset(address(_asset), ptToken, ptBalance);
        }
    }

    /* 
     * @dev calculate the price of PT in asset deomination scaled by 1e18
     */
    function getPTPrice(address ptToken) external view returns (uint256) {
        return getPTPriceInAsset(address(_asset), ptToken);
    }

    /**
     * @return the price of ptToken denominated in given _assetToken
     */
    function getPTPriceInAsset(address _assetToken, address ptToken) public view returns (uint256) {
        PTInfo memory ptInfo = ptInfos[ptToken];
        return TokenSwapper(_swapper).getPTPriceInAsset(
            _assetToken,
            _assetOracles[_assetToken],
            ptInfo.market,
            ptInfo.syOracleTwapSeconds,
            ptInfo.underlyingYield,
            ptInfo.underlyingOracle,
            _syToUnderlyingRate(ptInfo.syToken)
        );
    }

    /**
     * @return active PT markets used by this strategy
     */
    function getActivePTs() external view returns (address[] memory) {
        return activePTs.values();
    }

    /**
     * @dev Sum all PT currently held by this strategy in _asset denomination
     */
    function getAllPTAmountsInAsset() public view returns (uint256) {
        uint256 totalPTAmountInAsset;
        uint256 length = activePTs.length();
        for (uint256 i = 0; i < length; i++) {
            totalPTAmountInAsset += getPTAmountInAsset(activePTs.at(i));
        }
        return totalPTAmountInAsset;
    }
}
