// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseAAVEStrategy} from "./BaseAAVEStrategy.sol";
import {WETH} from "../../../interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStETH} from "../../../interfaces/lido/IStETH.sol";
import {IWstETH} from "../../../interfaces/lido/IWstETH.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {Constants} from "../../utils/Constants.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {AAVEHelper} from "./AAVEHelper.sol";

/**
 * @dev deposit into Lido and then supply in SparkFi and looping borrow wETH to get leveraged position.
 */
contract ETHLidoAAVEStrategy is BaseAAVEStrategy {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    IWstETH wstETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    IStETH stETH = IStETH(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    address payable constant wETH = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 aWstETH = ERC20(0x12B54025C112Aa61fAce2CDB7118740875A566E9);
    address constant stETHPool = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address constant wstETHUniPool = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa;
    address constant stETH_ETH_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    ///////////////////////////////
    // member storage
    ///////////////////////////////

    ///////////////////////////////
    // events
    ///////////////////////////////
    event ReceiveFromWrappedETH(uint256 _value);
    event SubmitToLidoFi(address indexed _requster, uint256 _asset, uint256 _mintedeStETH, uint256 _mintedWstETH);
    event SwapLossForDeleverage(address indexed _inToken, address indexed _outToken, uint256 _actual, uint256 _loss);

    constructor(address vault) BaseAAVEStrategy(ERC20(wETH), vault) {
        aavePool = sparkPool;
        _approveToken(address(wstETH), address(wstETH));
        _approveToken(address(stETH), address(wstETH));
    }

    ///////////////////////////////
    // earn with lido.fi
    ///////////////////////////////

    function _depositToLidoFi(uint256 _toDeposit, bool _submitDirectly, uint256 _swapCurveRatio)
        internal
        returns (uint256)
    {
        _toDeposit = _capAmountByBalance(ERC20(wETH), _toDeposit, false);
        uint256 _deposited;
        if (_submitDirectly) {
            // submit to Lido directly
            _deposited = _submitToLidoFi(_toDeposit);
        } else {
            // use dex to trade for supply
            _deposited = _swapToSupplyViaDex(_toDeposit, _swapCurveRatio);
        }
        return _deposited;
    }

    ///////////////////////////////
    // core external methods
    ///////////////////////////////

    /**
     * @dev swap collateral and repay debt in AAVE
     */
    function swapAndRepay(uint256 _supplyAmount, uint256 _repayAmount, uint256 _swapCurveRatio)
        external
        onlyStrategistOrOwner
    {
        if (_supplyAmount > 0) {
            _supplyAmount = _capAmountByBalance(AAVEHelper(_aaveHelper)._supplyToken(), _supplyAmount, false);
            _swapToAssetViaDex(_supplyAmount, _swapCurveRatio, false);
        }
        _repayAmount = _capAmountByBalance(AAVEHelper(_aaveHelper)._borrowToken(), _repayAmount, false);
        if (_repayAmount > 0) _repayDebtToAAVE(_repayAmount);
    }

    /**
     * @dev withdraw as much as possible supply collateral (wstETH) from AAVE
     */
    function redeem(uint256 _supplyAmount, bytes calldata /* _extraAction */ )
        external
        override
        onlyStrategistOrOwner
        returns (uint256)
    {
        uint256 _margin = AAVEHelper(_aaveHelper).getMaxRedeemableAmount();
        if (_margin == 0) {
            return _margin;
        }

        _supplyAmount = _supplyAmount > _margin ? _margin : _supplyAmount;
        _supplyAmount = _withdrawCollateralFromAAVE(_supplyAmount);
        return _supplyAmount;
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _collectAsset(uint256 _expectedAsset, bytes calldata _extraAction) internal override {
        uint256[] memory _previews = AAVEHelper(_aaveHelper).previewCollect(_expectedAsset);
        if (_previews[0] == 0) {
            return;
        }

        // simply create withdraw request within ether.fi if no need to interact with AAVE
        if (_previews[0] == 1) {
            _swapToAssetViaDex(_previews[1], _getParamsForSupplyRedeem(_extraAction), false);
            return;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        if (_previews[0] == 2) {
            _swapToAssetViaDex(
                _withdrawCollateralFromAAVE(_previews[1]), _getParamsForSupplyRedeem(_extraAction), false
            );
            return;
        }

        uint256 _expected = _previews[3] == _previews[2] ? 0 : _expectedAsset;
        _deleverageByFlashloan(_previews[1], _previews[2], _expected, _previews[3], _extraAction);
    }

    ///////////////////////////////
    // strategy customized methods
    ///////////////////////////////
    function totalAssets() public view override returns (uint256) {
        // Check supply in AAVE if any
        (uint256 _netSupply,,) = getNetSupplyAndDebt(true);

        return _asset.balanceOf(address(this)) + _convertSupplyToAsset(wstETH.balanceOf(address(this)))
            + stETH.balanceOf(address(this)) + _netSupply;
    }

    /**
     * @return assets in etherfi withdrawal queue and not claimed yet
     */
    function assetsInCollection() public view override returns (uint256) {
        return 0;
    }

    function _prepareSupplyFromAsset(uint256 _assetAmount, bytes memory _extraAction)
        internal
        override
        returns (uint256)
    {
        uint256 amount = _capAllocationAmount(_assetAmount);
        if (amount > 0) {
            emit AllocateInvestment(msg.sender, amount);
            SafeERC20.safeTransferFrom(_asset, _vault, address(this), amount);
            (bool _submitDirectly, uint256 _swapCurveRatio) = _getParamsForLidoDeposit(_extraAction);
            amount = _depositToLidoFi(amount, _submitDirectly, _swapCurveRatio);
        }
        return amount;
    }

    function _convertAssetToSupply(uint256 _assetAmount) public view override returns (uint256) {
        return wstETH.getWstETHByStETH(_assetAmount);
    }

    function _convertSupplyToAsset(uint256 _supplyAmount) public view override returns (uint256) {
        return wstETH.getStETHByWstETH(_supplyAmount);
    }

    ///////////////////////////////
    // handle flashloan callback from AAVE
    // https://aave.com/docs/developers/flash-loans
    ///////////////////////////////
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        ERC20 _supplyToken = AAVEHelper(_aaveHelper)._supplyToken();
        ERC20 _borrowToken = AAVEHelper(_aaveHelper)._borrowToken();

        if (msg.sender != address(sparkPool)) {
            revert Constants.WRONG_AAVE_FLASHLOAN_CALLER();
        }
        if (initiator != address(this)) {
            revert Constants.WRONG_AAVE_FLASHLOAN_INITIATOR();
        }
        if (asset != address(_borrowToken)) {
            revert Constants.WRONG_AAVE_FLASHLOAN_ASSET();
        }
        if (amount <= premium) {
            revert Constants.WRONG_AAVE_FLASHLOAN_PREMIUM();
        }
        if (_borrowToken.balanceOf(address(this)) < amount) {
            revert Constants.WRONG_AAVE_FLASHLOAN_AMOUNT();
        }

        (bool _lev, uint256 _expected, bytes memory _extraAction) = abi.decode(params, (bool, uint256, bytes));
        uint256 _toRepay = amount + premium;

        if (_lev) {
            _levWithFlashloan(amount, _toRepay, _extraAction);

            uint256 _borrowResidue = _borrowToken.balanceOf(address(this));
            if (_borrowResidue < _toRepay) {
                revert Constants.FAIL_TO_REPAY_FLASHLOAN_LEVERAGE();
            }
            _borrowResidue = _borrowResidue > _toRepay ? (_borrowResidue - _toRepay) : 0;

            // return any remaining to vault
            if (_borrowResidue > 0) {
                _returnAssetToVault(_borrowResidue);
            }
        } else {
            // Deleverage: use flashloan to clear debt in AAVE and then withdraw weETH from AAVE to swap for wETH
            // and lastly repay wETH flashloan
            if (_expected == 0) {
                // redeem everything
                _repayDebtToAAVE(type(uint256).max);
                _withdrawCollateralFromAAVE(type(uint256).max);
            } else {
                // redeem some collateral
                _repayDebtToAAVE(amount);
                _withdrawCollateralFromAAVE(_convertBorrowToSupply(_expected + _toRepay));
            }

            _approveToken(address(_supplyToken), _swapper);

            // NOTE!!! this flow might incur some slippage loss, please use at careful discretion
            uint256 _swapCurveRatio = _getParamsForSupplyRedeem(_extraAction);
            (uint256 _cappedIn, uint256 _actualOut) = _swapToAssetViaDex(_toRepay, _swapCurveRatio, true);

            uint256 _bestInTheory = _convertSupplyToAsset(_cappedIn);
            emit SwapLossForDeleverage(
                address(_supplyToken),
                address(_borrowToken),
                _actualOut,
                (_bestInTheory > _actualOut ? _bestInTheory - _actualOut : 0)
            );

            uint256 _supplyResidueValue = _supplyToken.balanceOf(address(this));
            if (_supplyResidueValue > 0) {
                _swapToAssetViaDex(_supplyResidueValue, _swapCurveRatio, false);
            }

            if (_borrowToken.balanceOf(address(this)) < _toRepay) {
                revert Constants.FAIL_TO_REPAY_FLASHLOAN_DELEVERAGE();
            }
        }

        return true;
    }

    function _swapToSupplyViaDex(uint256 _toDeposit, uint256 _swapCurveRatio) internal returns (uint256) {
        uint256 _deposited;
        uint256 _curveFlow = _toDeposit * _swapCurveRatio / Constants.TOTAL_BPS;

        _approveToken(address(AAVEHelper(_aaveHelper)._borrowToken()), _swapper);

        if (_curveFlow > 0) {
            _deposited += _swapToSupplyUsingCurve(
                AAVEHelper(_aaveHelper)._supplyToken(), AAVEHelper(_aaveHelper)._borrowToken(), _curveFlow
            );
        }
        uint256 _uniswapFlow = _toDeposit - _curveFlow;
        if (_uniswapFlow > 0) {
            _deposited += _swapToSupplyUsingUniswap(
                AAVEHelper(_aaveHelper)._supplyToken(), AAVEHelper(_aaveHelper)._borrowToken(), _uniswapFlow
            );
        }
        return _deposited;
    }

    function _swapToAssetViaDex(uint256 _amount, uint256 _swapCurveRatio, bool _fromExpectedOutput)
        internal
        returns (uint256, uint256)
    {
        uint256 _fromCurve = _amount * _swapCurveRatio / Constants.TOTAL_BPS;
        uint256 _fromUniswap = _amount - _fromCurve;
        uint256 _cappedIn1;
        uint256 _actualOut1;
        uint256 _cappedIn2;
        uint256 _actualOut2;

        _approveToken(address(AAVEHelper(_aaveHelper)._supplyToken()), _swapper);
        _approveToken(address(stETH), _swapper);

        if (_fromCurve > 0) {
            (_cappedIn1, _actualOut1) = _swapUsingCurve(
                AAVEHelper(_aaveHelper)._supplyToken(),
                AAVEHelper(_aaveHelper)._borrowToken(),
                _fromCurve,
                _fromExpectedOutput
            );
        }
        if (_fromUniswap > 0) {
            (_cappedIn2, _actualOut2) = _swapUsingUniswap(
                AAVEHelper(_aaveHelper)._supplyToken(),
                AAVEHelper(_aaveHelper)._borrowToken(),
                _fromUniswap,
                _fromExpectedOutput
            );
        }
        return (_cappedIn1 + _cappedIn2, _actualOut1 + _actualOut2);
    }

    function _swapUsingCurve(ERC20 _supplyToken, ERC20 _borrowToken, uint256 _amount, bool _expectedOutput)
        internal
        returns (uint256, uint256)
    {
        if (_expectedOutput) {
            // convert expected output ETH to input wstETH
            uint256 _expectedIn = _deduceExpectedUsingFeed(_amount, !_expectedOutput);
            uint256 _cappedIn = _capAmountByBalance(_supplyToken, _expectedIn, true);
            uint256 _actualOut = TokenSwapper(_swapper).swapInCurveWithETH(
                false, address(stETH), stETHPool, wstETH.unwrap(_cappedIn), _amount
            );
            return (_cappedIn, _actualOut);
        } else {
            // convert exact input wstETH to output ETH
            uint256 _expectedOut = _deduceExpectedUsingFeed(_amount, !_expectedOutput);
            uint256 _cappedIn = _capAmountByBalance(_supplyToken, _amount, false);
            uint256 _actualOut = TokenSwapper(_swapper).swapInCurveWithETH(
                false,
                address(stETH),
                stETHPool,
                wstETH.unwrap(_cappedIn),
                TokenSwapper(_swapper).applySlippageRelax(_expectedOut)
            );
            return (_cappedIn, _actualOut);
        }
    }

    function _swapToSupplyUsingCurve(ERC20 _supplyToken, ERC20 _borrowToken, uint256 _inAmount)
        internal
        returns (uint256)
    {
        uint256 _expectedOut = _deduceExpectedUsingFeed(_inAmount, false);
        uint256 _cappedIn = _capAmountByBalance(_borrowToken, _inAmount, false);
        uint256 _actualOut = TokenSwapper(_swapper).swapInCurveWithETH(
            true,
            address(stETH),
            stETHPool,
            _cappedIn,
            TokenSwapper(_swapper).applySlippageRelax(_convertSupplyToAsset(_expectedOut))
        );
        _actualOut = wstETH.wrap(_actualOut);
        return _actualOut;
    }

    function _swapUsingUniswap(ERC20 _supplyToken, ERC20 _borrowToken, uint256 _amount, bool _expectedOutput)
        internal
        returns (uint256, uint256)
    {
        if (_expectedOutput) {
            // convert expected output ETH to input wstETH
            uint256 _expectedIn = _deduceExpectedUsingFeed(_amount, !_expectedOutput);
            uint256 _cappedIn = _capAmountByBalance(_supplyToken, _expectedIn, true);
            uint256 _actualOut = TokenSwapper(_swapper).swapExactInWithUniswap(
                address(_supplyToken), address(_borrowToken), wstETHUniPool, _cappedIn, _amount
            );
            return (_cappedIn, _actualOut);
        } else {
            // convert exact input wstETH to output ETH
            uint256 _expectedOut = _deduceExpectedUsingFeed(_amount, !_expectedOutput);
            uint256 _cappedIn = _capAmountByBalance(_supplyToken, _amount, false);
            uint256 _actualOut = TokenSwapper(_swapper).swapExactInWithUniswap(
                address(_supplyToken),
                address(_borrowToken),
                wstETHUniPool,
                _cappedIn,
                TokenSwapper(_swapper).applySlippageRelax(_expectedOut)
            );
            return (_cappedIn, _actualOut);
        }
    }

    function _swapToSupplyUsingUniswap(ERC20 _supplyToken, ERC20 _borrowToken, uint256 _inAmount)
        internal
        returns (uint256)
    {
        uint256 _expectedOut = _deduceExpectedUsingFeed(_inAmount, false);
        uint256 _cappedIn = _capAmountByBalance(_borrowToken, _inAmount, false);
        uint256 _actualOut = TokenSwapper(_swapper).swapExactInWithUniswap(
            address(_borrowToken),
            address(_supplyToken),
            wstETHUniPool,
            _cappedIn,
            TokenSwapper(_swapper).applySlippageRelax(_expectedOut)
        );
        return _actualOut;
    }

    function _deduceExpectedUsingFeed(uint256 _equivalentAmount, bool _toAsset) internal view returns (uint256) {
        (int256 _stETHToETHPrice,, uint8 _priceDecimal) = TokenSwapper(_swapper).getPriceFromChainLink(stETH_ETH_FEED);
        if (_toAsset) {
            // wstETH -> stETH -> ETH
            return _convertSupplyToAsset(_equivalentAmount) * uint256(_stETHToETHPrice)
                / Constants.convertDecimalToUnit(_priceDecimal);
        } else {
            // ETH -> stETH -> wstETH
            return _convertAssetToSupply(
                Constants.convertDecimalToUnit(_priceDecimal) * _equivalentAmount / uint256(_stETHToETHPrice)
            );
        }
    }

    function _submitToLidoFi(uint256 _toDeposit) internal returns (uint256) {
        WETH(wETH).withdraw(_toDeposit);

        uint256 _stETHBefore = stETH.balanceOf(address(this));
        stETH.submit{value: _toDeposit}(Constants.ZRO_ADDR);
        uint256 _stETHAfter = stETH.balanceOf(address(this));
        uint256 _mintedstETH = _stETHAfter - _stETHBefore;

        uint256 _WstETHBefore;
        uint256 _WstETHAfter;
        if (_mintedstETH > 0) {
            _WstETHBefore = ERC20(address(wstETH)).balanceOf(address(this));
            wstETH.wrap(_mintedstETH);
            _WstETHAfter = ERC20(address(wstETH)).balanceOf(address(this));
        }

        uint256 _mintedSupply = _WstETHAfter - _WstETHBefore;
        emit SubmitToLidoFi(msg.sender, _toDeposit, _mintedstETH, _mintedSupply);
        return _mintedSupply;
    }

    function _getParamsForLidoDeposit(bytes memory _extraAction) internal view returns (bool, uint256) {
        (bool _submitDirectly, uint256 _swapCurveRatio) =
            _extraAction.length > 0 ? abi.decode(_extraAction, (bool, uint256)) : (true, Constants.TOTAL_BPS);
        return (_submitDirectly, _swapCurveRatio);
    }

    function _getParamsForSupplyRedeem(bytes memory _extraAction) internal view returns (uint256) {
        uint256 _swapCurveRatio = _extraAction.length > 0 ? abi.decode(_extraAction, (uint256)) : Constants.TOTAL_BPS;
        return _swapCurveRatio;
    }

    function _levWithFlashloan(uint256 amount, uint256 _toRepay, bytes memory _extraAction) internal {
        (bool _submitDirectly, uint256 _swapCurveRatio) = _getParamsForLidoDeposit(_extraAction);
        // Leverage: use flashloan to deposit borrowed wETH then supply wstETH to AAVE
        _supplyToAAVE(
            _depositToLidoFi(_capAmountByBalance(_asset, amount, false), _submitDirectly, _swapCurveRatio)
                + AAVEHelper(_aaveHelper)._supplyToken().balanceOf(address(this))
        );
        _borrowFromAAVE(_toRepay);
    }

    receive() external payable {
        if (msg.sender == wETH) {
            emit ReceiveFromWrappedETH(msg.value);
        }
    }
}
