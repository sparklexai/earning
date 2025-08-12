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
import {TokenSwapper} from "../../utils/TokenSwapper.sol";

abstract contract BaseAAVEStrategy is BaseSparkleXStrategy {
    using Math for uint256;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IPool sparkPool = IPool(0xC13e21B648A5Ee794902342038FF3aDAB66BE987);

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    address public _aaveHelper;
    bool public _loopingBorrow = true;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event MakeInvest(address indexed _caller, uint256 _borrowAmount, uint256 _assetAmount);
    event DebtDelegateToAAVEHelper(
        address indexed _strategy, address indexed _helper, address indexed _variableDebt, uint8 _eMode
    );
    event AAVEHelperChanged(address indexed _old, address indexed _new);
    event WithdrawFromAAVE(address indexed _caller, uint256 _withdrawn, uint256 _health);

    constructor(ERC20 token, address vault) BaseSparkleXStrategy(token, vault) {
        if (block.chainid == 56) {
            _switchToBNBChain();
        }
        _approveToken(address(token), address(aavePool));
        _approveToken(address(token), address(sparkPool));
        _loopingBorrow = true;
    }

    function setAAVEHelper(address _newHelper) external onlyOwner {
        if (_newHelper == Constants.ZRO_ADDR || AAVEHelper(_newHelper)._strategy() != address(this)) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }

        if (_aaveHelper != Constants.ZRO_ADDR) {
            _revokeTokenApproval(address(AAVEHelper(_aaveHelper)._supplyToken()), _aaveHelper);
            _revokeTokenApproval(address(AAVEHelper(_aaveHelper)._borrowToken()), _aaveHelper);
            _approveDelegationToAAVEHelper(0, AAVEHelper(_aaveHelper)._eMode());
        }

        emit AAVEHelperChanged(_aaveHelper, _newHelper);

        _aaveHelper = _newHelper;
        _prepareAllowanceForHelper();
    }

    function _prepareAllowanceForHelper() internal {
        _delegateCreditToHelper();
        _approveToken(address(AAVEHelper(_aaveHelper)._supplyToken()), _aaveHelper);
        _approveToken(address(AAVEHelper(_aaveHelper)._borrowToken()), _aaveHelper);
        _approveToken(address(AAVEHelper(_aaveHelper)._borrowToken()), address(aavePool));
    }

    ///////////////////////////////
    // methods common to AAVE which might be overriden by children strategies
    ///////////////////////////////

    /**
     * @dev by default, this method will try to maximize the allowed leverage by looping in AAVE
     * @dev i.e., borrowing as much as possible ETH and convert to weETH for AAVE supply
     */
    function allocate(uint256 amount, bytes calldata _extraAction) external virtual onlyStrategist onlyVaultNotPaused {
        if (amount == 0) {
            return;
        }

        if (AAVEHelper(_aaveHelper).LEVERAGE_RATIO_BPS() > 0) {
            _leveragePosition(amount, type(uint256).max, _extraAction);
        } else {
            _prepareSupplyFromAsset(amount, _extraAction);
            _supplyToAAVE(AAVEHelper(_aaveHelper)._supplyToken().balanceOf(address(this)));
        }
        emit AllocateInvestment(msg.sender, amount);
    }

    /**
     * @dev use flashloan to deleverage the position in AAVE
     * @dev and swap in curve to return amount to vault
     */
    function collect(uint256 amount, bytes calldata _extraAction) public virtual onlyStrategistOrVault {
        if (amount == 0) {
            return;
        }
        _collectAsset(amount, _extraAction);
        emit CollectInvestment(msg.sender, amount);
        _returnAssetToVault(amount);
    }

    /**
     * @dev use flashloan to fully deleverage the position in AAVE
     * @dev and swap in curve to return everything to vault
     */
    function collectAll(bytes calldata _extraAction) public virtual onlyStrategistOrVault {
        collect(totalAssets(), _extraAction);
    }

    function totalAssets() public view virtual returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function _collectAsset(uint256 _expectedAsset, bytes calldata _extraAction) internal virtual {}

    function _supplyToAAVE(uint256 _supplyAmount) internal {
        AAVEHelper(_aaveHelper).supplyToAAVE(
            _capAmountByBalance(AAVEHelper(_aaveHelper)._supplyToken(), _supplyAmount, false)
        );
    }

    function _borrowFromAAVE(uint256 _toBorrow) internal returns (uint256) {
        (uint256 _availableToBorrow,) = AAVEHelper(_aaveHelper).getAvailableBorrowAmount(address(this));
        if (_availableToBorrow < _toBorrow) {
            revert Constants.TOO_MUCH_TO_BORROW();
        }
        return AAVEHelper(_aaveHelper).borrowFromAAVE(_toBorrow);
    }

    function _repayDebtToAAVE(uint256 _debtToRepay) internal {
        AAVEHelper(_aaveHelper).repayDebtToAAVE(
            _capAmountByBalance(AAVEHelper(_aaveHelper)._borrowToken(), _debtToRepay, false)
        );
    }

    function _withdrawCollateralFromAAVE(uint256 _toWithdraw) internal returns (uint256) {
        (uint256 _netSupply,,) = getNetSupplyAndDebt(false);
        if (_toWithdraw > _netSupply) {
            _toWithdraw = _netSupply;
        }
        uint256 _withdrawn =
            aavePool.withdraw(address(AAVEHelper(_aaveHelper)._supplyToken()), _toWithdraw, address(this));
        (,,,,, uint256 newHealthFactor) = aavePool.getUserAccountData(address(this));
        emit WithdrawFromAAVE(msg.sender, _withdrawn, newHealthFactor);
        return _withdrawn;
    }

    /**
     * @dev strategist could use this method to adjust the position in AAVE for multiple scenarios:
     * @dev  [A]: _assetAmount = 0 & _borrowAmount > 0: simply add debt via AAVE.borrow()
     * @dev  [B]: _assetAmount > 0 & _borrowAmount = 0: simply add collateral via AAVE.supply()
     * @dev  [C]: _assetAmount > 0 & _borrowAmount > 0: complete position leveraging
     * @dev Note if _borrowAmount > 0 (case [A] & [C]) borrowed token might be converted to _asset and then sent back to _vault
     */
    function invest(uint256 _assetAmount, uint256 _borrowAmount, bytes memory _extraAction)
        external
        virtual
        onlyStrategistOrOwner
        onlyVaultNotPaused
    {
        if (_borrowAmount == 0 && _assetAmount == 0) {
            return;
        }

        if (_borrowAmount == 0) {
            _supplyToAAVE(_prepareSupplyFromAsset(_assetAmount, _extraAction));
        } else {
            if (_assetAmount > 0) {
                _leveragePosition(_assetAmount, _borrowAmount, _extraAction);
            } else {
                uint256 _borrowed = _borrowFromAAVE(_borrowAmount);
                if (address(AAVEHelper(_aaveHelper)._borrowToken()) == address(_asset)) {
                    _returnAssetToVault(_borrowed);
                }
            }
        }
        emit MakeInvest(msg.sender, _borrowAmount, _assetAmount);
    }

    /**
     * @dev strategist could use this method to withdraw supply token (collateral) in AAVE
     * @dev Please be careful this will increase the position LTV temporarily (higher liquidation risk)
     */
    function redeem(uint256 _supplyAmount, bytes calldata /* _extraAction */ )
        external
        virtual
        onlyStrategistOrOwner
        returns (uint256)
    {
        return _supplyAmount;
    }

    /**
     * @dev complete position leveraging in AAVE using given asset token amount and debt amount increased by given _borrowAmount
     * @dev Note that this method should check position should keep below maximum LTV
     */
    function _leveragePosition(uint256 _assetAmount, uint256 _borrowAmount, bytes memory _extraAction)
        internal
        virtual
    {
        _prepareSupplyFromAsset(_assetAmount, _extraAction);
        uint256 _toBorrow = AAVEHelper(_aaveHelper).previewLeverageForInvest(0, _borrowAmount);

        // use flashloan to leverage position
        (, address _flProvider,) = AAVEHelper(_aaveHelper).useSparkFlashloan();
        IPool(_flProvider).flashLoanSimple(
            address(this),
            address(AAVEHelper(_aaveHelper)._borrowToken()),
            _toBorrow,
            abi.encode(true, 0, _extraAction),
            0
        );
    }

    function _deleverageByFlashloan(
        uint256 _netSupplyAsset,
        uint256 _debtAsset,
        uint256 _expectedAsset,
        uint256 _deleveragedAmount,
        bytes calldata _extraAction
    ) internal {
        (, address _flProvider,) = AAVEHelper(_aaveHelper).useSparkFlashloan();
        if (_expectedAsset > 0 && _expectedAsset < AAVEHelper(_aaveHelper).applyLeverageMargin(_netSupplyAsset)) {
            // deleverage a portion if possible
            IPool(_flProvider).flashLoanSimple(
                address(this),
                address(AAVEHelper(_aaveHelper)._borrowToken()),
                _deleveragedAmount,
                abi.encode(false, _expectedAsset, _extraAction),
                0
            );
        } else {
            // deleverage everything
            IPool(_flProvider).flashLoanSimple(
                address(this),
                address(AAVEHelper(_aaveHelper)._borrowToken()),
                _debtAsset,
                abi.encode(false, 0, _extraAction),
                0
            );
        }
    }

    /**
     * @dev convert asset token with given amount to supply token
     */
    function _prepareSupplyFromAsset(uint256 _assetAmount, bytes memory /* _swapData */ )
        internal
        virtual
        returns (uint256)
    {
        return _assetAmount;
    }

    /**
     * @dev convert _asset token with given amount in its denomination to borrow token denomination
     */
    function _convertAssetToBorrow(uint256 _assetAmount) public view virtual returns (uint256) {
        return _assetAmount;
    }

    /**
     * @dev convert _asset token with given amount in its denomination to supply token denomination
     */
    function _convertAssetToSupply(uint256 _assetAmount) public view virtual returns (uint256) {
        return _assetAmount;
    }

    /**
     * @dev convert supply token with given amount in its denomination to strategy asset denomination
     */
    function _convertSupplyToAsset(uint256 _supplyAmount) public view virtual returns (uint256) {
        return _supplyAmount;
    }

    /**
     * @dev convert supply token with given amount in its denomination to borrow token denomination
     */
    function _convertSupplyToBorrow(uint256 _supplyAmount) public view virtual returns (uint256) {
        return _convertSupplyToAsset(_supplyAmount);
    }

    /**
     * @dev convert borrow token with given amount in its denomination to strategy asset denomination
     */
    function _convertBorrowToAsset(uint256 _borrowAmount) public view virtual returns (uint256) {
        return _borrowAmount;
    }

    /**
     * @dev convert borrow token with given amount in its denomination to supply token denomination
     */
    function _convertBorrowToSupply(uint256 _borrowAmount) public view virtual returns (uint256) {
        return _convertAssetToSupply(_borrowAmount);
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    /**
     * @dev Return net supply and borrow in their own denominations
     * @param _inAssetDenomination true for result in asset denomination or false in supply token denomination
     */
    function getNetSupplyAndDebt(bool _inAssetDenomination) public view returns (uint256, uint256, uint256) {
        return AAVEHelper(_aaveHelper).getSupplyAndDebt(_inAssetDenomination);
    }

    function _delegateCreditToHelper() internal {
        uint8 _eMode = AAVEHelper(_aaveHelper)._eMode();
        address variableDebtToken = _approveDelegationToAAVEHelper(type(uint256).max, _eMode);
        if (aavePool.getUserEMode(address(this)) != _eMode) {
            aavePool.setUserEMode(_eMode);
        }
        emit DebtDelegateToAAVEHelper(address(this), _aaveHelper, variableDebtToken, _eMode);
    }

    function _approveDelegationToAAVEHelper(uint256 _allowance, uint8 _eMode) internal returns (address) {
        address variableDebtToken;
        address _borrowTokenAddr = address(AAVEHelper(_aaveHelper)._borrowToken());

        try aavePool.getReserveVariableDebtToken(_borrowTokenAddr) returns (address _variableDebtAddr) {
            variableDebtToken = _variableDebtAddr;
        } catch {
            DataTypes.ReserveDataLegacy memory _reserveData = aavePool.getReserveData(_borrowTokenAddr);
            variableDebtToken = _reserveData.variableDebtTokenAddress;
        }

        IVariableDebtToken(variableDebtToken).approveDelegation(_aaveHelper, _allowance);
        return variableDebtToken;
    }

    function _switchToBNBChain() internal {
        // https://docs.kinza.finance/resources/deployed-contracts/bnb-chain
        aavePool = IPool(0xcB0620b181140e57D1C0D8b724cde623cA963c8C);
        // https://aave.com/docs/resources/addresses
        sparkPool = IPool(0x6807dc923806fE8Fd134338EABCA509979a7e0cB);
    }
}
