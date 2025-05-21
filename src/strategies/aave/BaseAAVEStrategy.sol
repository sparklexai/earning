// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseSparkleXStrategy} from "../BaseSparkleXStrategy.sol";
import {WETH} from "../../../interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {Constants} from "../../utils/Constants.sol";

abstract contract BaseAAVEStrategy is BaseSparkleXStrategy {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////
    uint8 constant ETH_CATEGORY_AAVE = 1;
    uint8 constant sUSDe_CATEGORY_AAVE = 2;
    uint8 constant USDe_CATEGORY_AAVE = 11;

    /**
     * @dev variable rate.
     */
    uint256 constant INTEREST_MODE = 2;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveOracle aaveOracle = IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    uint8 immutable _eMode;
    ERC20 immutable _supplyToken;
    ERC20 immutable _borrowToken;
    ERC20 immutable _supplyAToken;
    ERC20 immutable _variableDebtToken;

    /**
     * @dev leverage ratio in AAVE with looping supply and borrow.
     */
    uint256 LEVERAGE_RATIO_BPS = 9500;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event BaseAAVEStrategyCreated(address indexed supplyToken, address indexed borrowToken, uint8 eMode);
    event SupplyToAAVE(uint256 _supplied, uint256 _mintedAToken);
    event BorrowFromAAVE(uint256 _borrowed, uint256 _ltv, uint256 _health);
    event RepayDebtInAAVE(uint256 _repaidETH, uint256 _ltv, uint256 _health);
    event WithdrawFromAAVE(uint256 _withdrawn, uint256 _ltv, uint256 _health);
    event MakeInvest(address indexed _caller, uint256 _borrowAmount, uint256 _assetAmount);

    constructor(ERC20 token, address vault, ERC20 supplyToken, ERC20 borrowToken, ERC20 supplyAToken, uint8 eMode)
        BaseSparkleXStrategy(token, vault)
    {
        supplyToken.approve(address(aavePool), type(uint256).max);
        borrowToken.approve(address(aavePool), type(uint256).max);
        supplyAToken.approve(address(aavePool), type(uint256).max);

        _supplyToken = supplyToken;
        _borrowToken = borrowToken;
        _supplyAToken = supplyAToken;

        // Enable E Mode in AAVE for correlated assets
        require(
            eMode == ETH_CATEGORY_AAVE || eMode == USDe_CATEGORY_AAVE || eMode == sUSDe_CATEGORY_AAVE,
            "!invalid emode category"
        );
        aavePool.setUserEMode(eMode);
        _eMode = eMode;

        emit BaseAAVEStrategyCreated(address(supplyToken), address(borrowToken), _eMode);
    }

    function setLeverageRatio(uint256 _ratio) external onlyStrategist {
        require(_ratio >= 0 && _ratio <= Constants.TOTAL_BPS, "invalid leverage ratio!");
        LEVERAGE_RATIO_BPS = _ratio;
    }

    ///////////////////////////////
    // methods common to AAVE which might be overriden by children strategies
    ///////////////////////////////

    /**
     * @dev strategist could use this method to adjust the position in AAVE for multiple scenarios:
     * @dev  [A]: _assetAmount = 0 & _borrowAmount > 0: simply add debt via AAVE.borrow()
     * @dev  [B]: _assetAmount > 0 & _borrowAmount = 0: simply add collateral via AAVE.supply()
     * @dev  [C]: _assetAmount > 0 & _borrowAmount > 0: complete position leveraging
     * @dev Note if _borrowAmount > 0 (case [A] & [C]) borrowed token might be converted to _asset and then sent back to _vault
     */
    function invest(uint256 _assetAmount, uint256 _borrowAmount) external virtual onlyStrategist {
        require(_borrowAmount > 0 || _assetAmount > 0, "!invalid invest amounts to AAVE");

        if (_borrowAmount == 0) {
            uint256 _supplyAmount = _prepareSupplyFromAsset(_assetAmount);
            _supplyToAAVE(_supplyAmount);
        } else {
            if (_assetAmount > 0) {
                _leveragePosition(_assetAmount, _borrowAmount);
            } else {
                uint256 _borrowed = _borrowFromAAVE(_borrowAmount);
                _prepareAssetFromBorrow(_borrowed);
            }
        }
        emit MakeInvest(msg.sender, _borrowAmount, _assetAmount);
    }

    /**
     * @dev strategist could use this method to withdraw supply token (collateral) in AAVE
     * @dev Note it will increase the position LTV thus higher liquidation risk
     */
    function redeem(uint256 _supplyAmount) external virtual onlyStrategist returns (uint256) {
        return _supplyAmount;
    }

    /**
     * @dev complete position leveraging in AAVE using given asset token amount and debt amount increased by given _borrowAmount
     * @dev Note that this method should check position should keep below maximum LTV
     */
    function _leveragePosition(uint256 _assetAmount, uint256 _borrowAmount) internal virtual {}

    /**
     * @dev convert borrow token with given amount to asset token
     */
    function _prepareAssetFromBorrow(uint256 _borrowAmount) internal virtual returns (uint256) {
        return _borrowAmount;
    }

    /**
     * @dev convert asset token with given amount to supply token
     */
    function _prepareSupplyFromAsset(uint256 _assetAmount) internal virtual returns (uint256) {
        return _assetAmount;
    }

    /**
     * @dev convert _asset token with given amount in its denomination to supply token denomination
     */
    function _convertAssetToSupply(uint256 _assetAmount) internal view virtual returns (uint256) {
        return _assetAmount;
    }

    /**
     * @dev convert supply token with given amount in its denomination to strategy asset denomination
     */
    function _convertSupplyToAsset(uint256 _supplyAmount) internal view virtual returns (uint256) {
        return _supplyAmount;
    }

    /**
     * @dev convert supply token with given amount in its denomination to borrow token denomination
     */
    function _convertSupplyToBorrow(uint256 _supplyAmount) internal view virtual returns (uint256) {
        return _supplyAmount;
    }

    /**
     * @dev convert borrow token with given amount in its denomination to strategy asset denomination
     */
    function _convertBorrowToAsset(uint256 _borrowAmount) internal view virtual returns (uint256) {
        return _borrowAmount;
    }

    /**
     * @dev convert borrow token with given amount in its denomination to supply token denomination
     */
    function _convertBorrowToSupply(uint256 _borrowAmount) internal view virtual returns (uint256) {
        return _borrowAmount;
    }

    ///////////////////////////////
    // supply/withdraw and borrow/repay within AAVE
    ///////////////////////////////

    function _supplyToAAVE(uint256 _supplyAmount) internal {
        uint256 _toSupply = _supplyAmount > 0 ? _supplyAmount : _supplyToken.balanceOf(address(this));
        uint256 _aTokenBefore = _supplyAToken.balanceOf(address(this));
        aavePool.supply(address(_supplyToken), _toSupply, address(this), 0);
        uint256 _aTokenAfter = _supplyAToken.balanceOf(address(this));
        emit SupplyToAAVE(_toSupply, _aTokenAfter - _aTokenBefore);
    }

    function _borrowFromAAVE(uint256 _toBorrow) internal returns (uint256) {
        uint256 _availableToBorrow = getAvailableBorrowAmount();
        require(_availableToBorrow >= _toBorrow, "borrow too much in AAVE!");

        uint256 _toBorrowBefore = _borrowToken.balanceOf(address(this));
        aavePool.borrow(address(_borrowToken), _toBorrow, 2, 0, address(this));
        uint256 _toBorrowAfter = _borrowToken.balanceOf(address(this));
        uint256 _borrowed = _toBorrowAfter - _toBorrowBefore;

        (,,,, uint256 newLtv, uint256 newHealthFactor) = aavePool.getUserAccountData(address(this));
        emit BorrowFromAAVE(_borrowed, newLtv, newHealthFactor);
        return _borrowed;
    }

    function _repayDebtToAAVE(uint256 _debtToRepay) internal {
        if (_debtToRepay < type(uint256).max) {
            require(_borrowToken.balanceOf(address(this)) >= _debtToRepay, "not enough to repay in AAVE!");
        }
        uint256 _repaid = aavePool.repay(address(_borrowToken), _debtToRepay, 2, address(this));

        (,,,, uint256 newLtv, uint256 newHealthFactor) = aavePool.getUserAccountData(address(this));
        emit RepayDebtInAAVE(_repaid, newLtv, newHealthFactor);
    }

    function _withdrawCollateralFromAAVE(uint256 _assetToWithdraw) internal returns (uint256) {
        uint256 _withdrawn = aavePool.withdraw(address(_supplyToken), _assetToWithdraw, address(this));

        (,,,, uint256 newLtv, uint256 newHealthFactor) = aavePool.getUserAccountData(address(this));
        emit WithdrawFromAAVE(_withdrawn, newLtv, newHealthFactor);
        return _withdrawn;
    }

    function getMaxLTV() public view returns (uint256) {
        DataTypes.CollateralConfig memory config = aavePool.getEModeCategoryCollateralConfig(_eMode);
        uint256 _ltv = config.ltv;
        require(_ltv < Constants.TOTAL_BPS, "wrong ltv!");
        return _ltv;
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _getMaxAllowedDebt(uint256 _supply) internal view returns (uint256) {
        return _supply > 0 ? (_supply * getMaxLTV() / Constants.TOTAL_BPS) : 0;
    }

    /**
     * @dev convert asset from given amount in base unit denomination in its own native denomination
     * @param _nativeUnit 1e18 for most ETH related token, like most ERC20
     */
    function convertFromBaseAmount(address _asset, uint256 _baseAmount, uint256 _nativeUnit)
        public
        view
        returns (uint256)
    {
        uint256 _assetPriceInBase = aaveOracle.getAssetPrice(_asset);
        return _baseAmount * _nativeUnit / _assetPriceInBase;
    }

    /**
     * @dev Return net supply and borrow in their own denominations
     * @param _inAssetDenomination true for result in asset denomination or false in supply token denomination
     */
    function getNetSupplyAndDebt(bool _inAssetDenomination)
        public
        view
        returns (uint256 _netSupply, uint256 _debt, uint256 _totalSupply)
    {
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = aavePool.getUserAccountData(address(this));
        uint256 _cAmount = totalCollateralBase > 0
            ? convertFromBaseAmount(
                address(_supplyToken), totalCollateralBase, Constants.convertDecimalToUnit(_supplyToken.decimals())
            )
            : 0;
        uint256 _dAmount = totalDebtBase > 0
            ? convertFromBaseAmount(
                address(_borrowToken), totalDebtBase, Constants.convertDecimalToUnit(_borrowToken.decimals())
            )
            : 0;
        if (_inAssetDenomination) {
            _debt = totalDebtBase > 0 ? _convertBorrowToAsset(_dAmount) : 0;
            _totalSupply = totalCollateralBase > 0 ? _convertSupplyToAsset(_cAmount) : 0;
            _netSupply = totalCollateralBase > 0 ? _totalSupply - _debt : 0;
        } else {
            _debt = totalDebtBase > 0 ? _convertBorrowToSupply(_dAmount) : 0;
            _totalSupply = totalCollateralBase > 0 ? _cAmount : 0;
            _netSupply = totalCollateralBase > 0 ? _cAmount - _debt : 0;
        }
    }

    function _applyLeverageMargin(uint256 _max) internal view returns (uint256) {
        return _max * LEVERAGE_RATIO_BPS / Constants.TOTAL_BPS;
    }

    function getSafeLeveragedSupply(uint256 _initialSupply) public view returns (uint256) {
        return LEVERAGE_RATIO_BPS > 0 ? _applyLeverageMargin(getMaxLeverage(_initialSupply)) : _initialSupply;
    }

    function getMaxLeverage(uint256 _amount) public view returns (uint256) {
        uint256 _maxLTV = getMaxLTV();
        return _amount * _maxLTV / (Constants.TOTAL_BPS - _maxLTV);
    }

    /**
     * @dev Return available borrow token amount in its own denominations
     */
    function getAvailableBorrowAmount() public view returns (uint256) {
        (,, uint256 availableBorrowsBase,,,) = aavePool.getUserAccountData(address(this));

        uint256 _availableToBorrow = availableBorrowsBase > 0
            ? convertFromBaseAmount(
                address(_borrowToken), availableBorrowsBase, Constants.convertDecimalToUnit(_borrowToken.decimals())
            )
            : 0;
        return _availableToBorrow;
    }
}
