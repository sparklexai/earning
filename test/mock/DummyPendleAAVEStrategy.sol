// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {BaseAAVEStrategy} from "../../src/strategies/aave/BaseAAVEStrategy.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IOracleAggregatorV3} from "../../interfaces/chainlink/IOracleAggregatorV3.sol";

contract DummyPendleAAVEStrategy is BaseAAVEStrategy {
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant susde = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC_USD_Feed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant sUSDe_USD_Feed = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099;
    address constant USDT_USD_Feed = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    ///////////////////////////////
    // mainnet pendle PT pools: active
    ///////////////////////////////
    // sUSDe JUL31 market
    address public constant sUSDePT = 0x3b3fB9C57858EF816833dC91565EFcd85D96f634;
    address public constant asUSDePT = 0xDE6eF6CB4aBd3A473ffC2942eEf5D84536F8E864;

    ERC20 public _supplyToken = ERC20(sUSDePT);
    ERC20 public _borrowToken = ERC20(usdt);
    ERC20 public _supplyAToken = ERC20(asUSDePT);

    constructor(address vault) BaseAAVEStrategy(ERC20(usdc), vault) {}

    function allocate(uint256 amount, bytes calldata _extraAction) external override {
        _asset.transferFrom(_vault, address(this), amount);
    }

    function assetsInCollection() external view override returns (uint256) {
        return 0;
    }

    function collect(uint256 amount, bytes calldata _extraAction) public override {
        _asset.transferFrom(address(this), _vault, amount);
    }

    function collectAll(bytes calldata _extraAction) public override {
        _asset.transferFrom(address(this), _vault, totalAssets());
    }

    function totalAssets() public view override returns (uint256) {
        uint256 _supply2Asset = convertFromPTSupply(_supplyToken.balanceOf(address(this)), true);
        uint256 _borrow2Asset = convertFromBorrowToAsset(_borrowToken.balanceOf(address(this)));
        return _asset.balanceOf(address(this)) + _supply2Asset + _borrow2Asset;
    }

    function convertFromPTSupply(uint256 _supplyPTAmount, bool _toAsset) public view returns (uint256) {
        if (!IPPrincipalToken(address(_supplyToken)).isExpired()) {
            revert Constants.PT_NOT_MATURED();
        }
        (uint256 _supplyRate, uint256 _assetRate, uint256 _borrowRate) = _getPricesFromOracleFeeds();
        return _toAsset
            ? (_convertSupplyToAsset(_supplyPTAmount) * _supplyRate / (1e12 * _assetRate))
            : (_convertSupplyToBorrow(_supplyPTAmount) * _supplyRate / (1e12 * _borrowRate));
    }

    function convertToPTSupply(uint256 _fromAmount, bool _fromAsset) public view returns (uint256) {
        if (!IPPrincipalToken(address(_supplyToken)).isExpired()) {
            revert Constants.PT_NOT_MATURED();
        }
        (uint256 _supplyRate, uint256 _assetRate, uint256 _borrowRate) = _getPricesFromOracleFeeds();
        return _fromAsset
            ? (_convertAssetToSupply(_fromAmount) * _assetRate * 1e12 / _supplyRate)
            : (_convertBorrowToSupply(_fromAmount) * _borrowRate * 1e12 / _supplyRate);
    }

    function convertFromBorrowToAsset(uint256 _borrowAmount) public view returns (uint256) {
        (, uint256 _assetRate, uint256 _borrowRate) = _getPricesFromOracleFeeds();
        return (_convertBorrowToAsset(_borrowAmount) * _borrowRate / _assetRate);
    }

    function _getPricesFromOracleFeeds() internal view returns (uint256, uint256, uint256) {
        uint256 _supplyRate = _getPriceFromOracleFeed(sUSDe_USD_Feed);
        uint256 _assetRate = _getPriceFromOracleFeed(USDC_USD_Feed);
        uint256 _borrowRate = _getPriceFromOracleFeed(USDT_USD_Feed);
        return (_supplyRate, _assetRate, _borrowRate);
    }

    function _getPriceFromOracleFeed(address _feed) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = IOracleAggregatorV3(_feed).latestRoundData();
        return uint256(answer);
    }
}
