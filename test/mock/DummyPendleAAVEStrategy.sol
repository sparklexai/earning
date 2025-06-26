// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {BaseAAVEStrategy} from "../../src/strategies/aave/BaseAAVEStrategy.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IOracleAggregatorV3} from "../../interfaces/chainlink/IOracleAggregatorV3.sol";

contract DummyPendleAAVEStrategy is BaseAAVEStrategy {
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant usde = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant USDC_USD_Feed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant USDe_USD_Feed = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    address constant USDT_USD_Feed = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    ///////////////////////////////
    // mainnet pendle PT pools: active
    ///////////////////////////////
    // USDe JUL31 market
    address public constant USDePT = 0x917459337CaAC939D41d7493B3999f571D20D667;
    address public constant aUSDePT = 0x312ffC57778CEfa11989733e6E08143E7E229c1c;

    ERC20 public _supplyToken = ERC20(USDePT);
    ERC20 public _borrowToken = ERC20(usdt);
    ERC20 public _supplyAToken = ERC20(aUSDePT);

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
        BaseAAVEStrategy.collectAll(_extraAction);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 _supply2Asset = convertFromPTSupply(_supplyToken.balanceOf(address(this)), true);
        uint256 _borrow2Asset = convertFromBorrowToAsset(_borrowToken.balanceOf(address(this)));
        return BaseAAVEStrategy.totalAssets() + _supply2Asset + _borrow2Asset;
    }

    function convertFromPTSupply(uint256 _supplyPTAmount, bool _toAsset) public view returns (uint256) {
        if (!IPPrincipalToken(address(_supplyToken)).isExpired()) {
            revert Constants.PT_NOT_MATURED();
        }
        (uint256 _supplyRate, uint256 _assetRate, uint256 _borrowRate) = _getPricesFromOracleFeeds();
        return _toAsset
            ? (super._convertSupplyToAsset(_supplyPTAmount) * _supplyRate / (1e12 * _assetRate))
            : (super._convertSupplyToBorrow(_supplyPTAmount) * _supplyRate / (1e12 * _borrowRate));
    }

    function convertToPTSupply(uint256 _fromAmount, bool _fromAsset) public view returns (uint256) {
        if (!IPPrincipalToken(address(_supplyToken)).isExpired()) {
            revert Constants.PT_NOT_MATURED();
        }
        (uint256 _supplyRate, uint256 _assetRate, uint256 _borrowRate) = _getPricesFromOracleFeeds();
        return _fromAsset
            ? (super._convertAssetToSupply(_fromAmount) * _assetRate * 1e12 / _supplyRate)
            : (super._convertBorrowToSupply(_fromAmount) * _borrowRate * 1e12 / _supplyRate);
    }

    function convertFromBorrowToAsset(uint256 _borrowAmount) public view returns (uint256) {
        (, uint256 _assetRate, uint256 _borrowRate) = _getPricesFromOracleFeeds();
        return (super._convertBorrowToAsset(_borrowAmount) * _borrowRate / _assetRate);
    }

    function _getPricesFromOracleFeeds() internal view returns (uint256, uint256, uint256) {
        uint256 _supplyRate = _getPriceFromOracleFeed(USDe_USD_Feed);
        uint256 _assetRate = _getPriceFromOracleFeed(USDC_USD_Feed);
        uint256 _borrowRate = _getPriceFromOracleFeed(USDT_USD_Feed);
        return (_supplyRate, _assetRate, _borrowRate);
    }

    function _getPriceFromOracleFeed(address _feed) internal view returns (uint256) {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = IOracleAggregatorV3(_feed).latestRoundData();
        return uint256(answer);
    }

    function _strategy() external view returns (address) {
        return address(0);
    }

    function _reflectCall(address _t0, bytes memory _t1, bytes memory _t2, bytes memory _t3) external {}
}
