// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseSparkleXStrategy} from "../BaseSparkleXStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IVariableDebtToken} from "../../../interfaces/aave/IVariableDebtToken.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {Constants} from "../../utils/Constants.sol";
import {AAVEHelper} from "./AAVEHelper.sol";

abstract contract BaseAAVEStrategy is BaseSparkleXStrategy {
    using Math for uint256;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    ERC20 public immutable _supplyToken;
    ERC20 public immutable _borrowToken;
    ERC20 public immutable _supplyAToken;
    address public _aaveHelper;

    /**
     * @dev leverage ratio in AAVE with looping supply and borrow.
     */
    uint256 LEVERAGE_RATIO_BPS = 9500;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event BaseAAVEStrategyCreated(
        address indexed supplyToken, address indexed borrowToken, address indexed supplyAToken
    );
    event MakeInvest(address indexed _caller, uint256 _borrowAmount, uint256 _assetAmount);
    event DebtDelegateToAAVEHelper(address indexed _strategy, address indexed _helper);
    event AAVEHelperChanged(address indexed _old, address indexed _new);

    constructor(ERC20 token, address vault, ERC20 supplyToken, ERC20 borrowToken, ERC20 supplyAToken)
        BaseSparkleXStrategy(token, vault)
    {
        _supplyToken = supplyToken;
        _borrowToken = borrowToken;
        _supplyAToken = supplyAToken;

        emit BaseAAVEStrategyCreated(address(supplyToken), address(borrowToken), address(supplyAToken));
    }

    function setLeverageRatio(uint256 _ratio) external onlyStrategist {
        require(_ratio >= 0 && _ratio <= Constants.TOTAL_BPS, "invalid leverage ratio!");
        LEVERAGE_RATIO_BPS = _ratio;
    }

    function setAAVEHelper(address _newHelper) external onlyStrategist {
        require(
            _newHelper != Constants.ZRO_ADDR && AAVEHelper(_newHelper)._strategy() == address(this),
            "!invalid aave helper"
        );
        emit AAVEHelperChanged(_aaveHelper, _newHelper);
        _aaveHelper = _newHelper;
        _delegateCreditToHelper();
    }

    ///////////////////////////////
    // methods common to AAVE which might be overriden by children strategies
    ///////////////////////////////

    function _supplyToAAVE(uint256 _supplyAmount) internal {
        _supplyAmount = _capAmountByBalance(_supplyToken, _supplyAmount, false);
        _approveToken(address(_supplyToken), _aaveHelper);
        AAVEHelper(_aaveHelper).supplyToAAVE(_supplyAmount);
    }

    function _borrowFromAAVE(uint256 _toBorrow) internal returns (uint256) {
        (uint256 _availableToBorrow,) = AAVEHelper(_aaveHelper).getAvailableBorrowAmount(address(this));
        require(_availableToBorrow >= _toBorrow, "borrow too much in AAVE!");
        return AAVEHelper(_aaveHelper).borrowFromAAVE(_toBorrow);
    }

    function _repayDebtToAAVE(uint256 _debtToRepay) internal {
        _debtToRepay = _capAmountByBalance(_borrowToken, _debtToRepay, false);
        _approveToken(address(_borrowToken), _aaveHelper);
        AAVEHelper(_aaveHelper).repayDebtToAAVE(_debtToRepay);
    }

    function _withdrawCollateralFromAAVE(uint256 _toWithdraw) internal returns (uint256) {
        _approveToken(address(_supplyAToken), _aaveHelper);

        (uint256 _netSupply,,) = getNetSupplyAndDebt(false);
        if (_toWithdraw > _netSupply) {
            _toWithdraw = _netSupply;
        }

        return AAVEHelper(_aaveHelper).withdrawCollateralFromAAVE(_toWithdraw);
    }

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
                _returnAssetToVault(_borrowed);
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
    // convenient helper methods
    ///////////////////////////////

    /**
     * @dev Return net supply and borrow in their own denominations
     * @param _inAssetDenomination true for result in asset denomination or false in supply token denomination
     */
    function getNetSupplyAndDebt(bool _inAssetDenomination)
        public
        view
        returns (uint256 _netSupply, uint256 _debt, uint256 _totalSupply)
    {
        (uint256 _cAmount, uint256 _dAmount, uint256 totalCollateralBase, uint256 totalDebtBase) =
            AAVEHelper(_aaveHelper).getTotalSupplyAndDebt(address(this));

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
        return LEVERAGE_RATIO_BPS > 0
            ? _applyLeverageMargin(AAVEHelper(_aaveHelper).getMaxLeverage(_initialSupply))
            : _initialSupply;
    }

    function _delegateCreditToHelper() internal {
        address variableDebtToken = aavePool.getReserveVariableDebtToken(address(_borrowToken));
        IVariableDebtToken(variableDebtToken).approveDelegation(_aaveHelper, type(uint256).max);
        aavePool.setUserEMode(AAVEHelper(_aaveHelper)._eMode());
        emit DebtDelegateToAAVEHelper(address(this), _aaveHelper);
    }
}
