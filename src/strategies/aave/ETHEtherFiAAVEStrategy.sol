// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseAAVEStrategy} from "./BaseAAVEStrategy.sol";
import {WETH} from "../../../interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IeETH} from "../../../interfaces/etherfi/IeETH.sol";
import {IWeETH} from "../../../interfaces/etherfi/IWeETH.sol";
import {ILiquidityPool} from "../../../interfaces/etherfi/ILiquidityPool.sol";
import {IWithdrawRequestNFT} from "../../../interfaces/etherfi/IWithdrawRequestNFT.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {Constants} from "../../utils/Constants.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {EtherFiHelper} from "../etherfi/EtherFiHelper.sol";
import {AAVEHelper} from "./AAVEHelper.sol";

/**
 * @dev deposit into Ether.Fi and then supply in AAVE and looping borrow wETH to get leveraged position.
 */
contract ETHEtherFiAAVEStrategy is BaseAAVEStrategy {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    ILiquidityPool etherfiLP = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
    IWeETH weETH = IWeETH(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
    IeETH eETH = IeETH(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
    address payable constant wETH = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 aWeETH = ERC20(0xBdfa7b7893081B35Fb54027489e2Bc7A38275129);
    address constant weETHPool = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;
    address constant weETHUniPool = 0x202A6012894Ae5c288eA824cbc8A9bfb26A49b93;
    address constant weETH_ETH_FEED = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    address payable _etherfiHelper;
    uint256 public _swapCurveRatio = 5000;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event EtherFiHelperChanged(address indexed _old, address indexed _new);
    event SwapLossForDeleverage(address indexed _inToken, address indexed _outToken, uint256 _actual, uint256 _loss);

    constructor(address vault) BaseAAVEStrategy(ERC20(wETH), vault) {}

    function setEtherFiHelper(address _newHelper) external onlyOwner {
        if (_newHelper == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        emit EtherFiHelperChanged(_etherfiHelper, _newHelper);
        _etherfiHelper = payable(_newHelper);
        _approveToken(wETH, _etherfiHelper);
        _approveToken(address(weETH), _etherfiHelper);
    }

    function setSwapCurveRatio(uint256 _ratio) external onlyOwner {
        if (_ratio > Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        _swapCurveRatio = _ratio;
    }

    ///////////////////////////////
    // earn with ether.fi
    ///////////////////////////////

    function _depositToEtherFi(uint256 _toDeposit) internal returns (uint256) {
        _toDeposit = _capAmountByBalance(ERC20(wETH), _toDeposit, false);
        return EtherFiHelper(_etherfiHelper).depositToEtherFi(_toDeposit);
    }

    function _requestWithdrawFromEtherFi(uint256 _toWithdrawWeETH, uint256 _swapLoss) internal returns (uint256) {
        _toWithdrawWeETH = _capAmountByBalance(ERC20(address(weETH)), _toWithdrawWeETH, false);
        return EtherFiHelper(_etherfiHelper).requestWithdrawFromEtherFi(_toWithdrawWeETH, _swapLoss);
    }

    /**
     * @dev complete the withdrawal request with etherfi and return _asset directly to vault
     */
    function claimWithdrawFromEtherFi(uint256 _reqID) external onlyStrategist returns (uint256) {
        uint256 _claimed = EtherFiHelper(_etherfiHelper).claimWithdrawFromEtherFi(_reqID);
        _returnAssetToVault(_claimed);
        return _claimed;
    }

    ///////////////////////////////
    // core external methods
    ///////////////////////////////

    /**
     * @dev complete the withdrawal request with etherfi and repay debt in AAVE
     */
    function claimAndRepay(uint256[] calldata _reqIds, uint256 _repayAmount) external onlyStrategistOrOwner {
        uint256 _reqLen = _reqIds.length;
        if (_reqLen > 0) {
            for (uint256 i = 0; i < _reqLen; i++) {
                EtherFiHelper(_etherfiHelper).claimWithdrawFromEtherFi(_reqIds[i]);
            }
        }
        _repayAmount = _capAmountByBalance(AAVEHelper(_aaveHelper)._borrowToken(), _repayAmount, false);
        if (_repayAmount > 0) _repayDebtToAAVE(_repayAmount);
    }

    /**
     * @dev withdraw as much as possible supply collateral (weETH) from AAVE
     * @dev and submit etherfi withdrawal request for later debt repayment to lower LTV
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
        uint256 _reqWithdraw = _capAmountByBalance(AAVEHelper(_aaveHelper)._supplyToken(), _supplyAmount, false);
        _requestWithdrawFromEtherFi(_reqWithdraw, 0);
        return _reqWithdraw;
    }

    /**
     * @dev return all pending withdraw request in EtherFi: [requestID, amountOfEEth, anyLossDuringRequest, fee]
     */
    function getAllWithdrawRequests() public view returns (uint256[][] memory) {
        return EtherFiHelper(_etherfiHelper).getAllWithdrawRequests(address(this));
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
            _requestWithdrawFromEtherFi(_previews[1], 0);
            return;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        if (_previews[0] == 2) {
            _withdrawCollateralFromAAVE(_previews[1]);
            _requestWithdrawFromEtherFi(AAVEHelper(_aaveHelper)._supplyToken().balanceOf(address(this)), 0);
            return;
        }

        uint256 _expected = _previews[3] == _previews[2] ? 0 : _expectedAsset;
        _deleverageByFlashloan(_previews[1], _previews[2], _expected, _previews[3], _extraAction);
    }

    ///////////////////////////////
    // strategy customized methods
    ///////////////////////////////
    function totalAssets() public view override returns (uint256) {
        // Check how much we can claim from ether.fi
        uint256 _claimable = etherfiLP.getTotalEtherClaimOf(address(this))
            + weETH.getEETHByWeETH(ERC20(address(weETH)).balanceOf(address(this)));
        uint256 _toWithdraw = assetsInCollection();

        // Check supply in AAVE if any
        (uint256 _netSupply,,) = getNetSupplyAndDebt(true);

        return _asset.balanceOf(address(this)) + _claimable + _toWithdraw + _netSupply;
    }

    /**
     * @return assets in etherfi withdrawal queue and not claimed yet
     */
    function assetsInCollection() public view override returns (uint256) {
        return EtherFiHelper(_etherfiHelper).getAllPendingValue(address(this));
    }

    function _prepareSupplyFromAsset(uint256 _assetAmount, bytes memory /* _extraAction */ )
        internal
        override
        returns (uint256)
    {
        uint256 amount = _capAllocationAmount(_assetAmount);
        if (amount > 0) {
            emit AllocateInvestment(msg.sender, amount);
            SafeERC20.safeTransferFrom(_asset, _vault, address(this), amount);
            amount = _depositToEtherFi(amount);
        }
        return amount;
    }

    function _convertAssetToSupply(uint256 _assetAmount) public view override returns (uint256) {
        return weETH.getWeETHByeETH(_assetAmount);
    }

    function _convertSupplyToAsset(uint256 _supplyAmount) public view override returns (uint256) {
        return weETH.getEETHByWeETH(_supplyAmount);
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

        if (msg.sender != address(aavePool) && msg.sender != address(sparkPool)) {
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

        (bool _lev, uint256 _expected,) = abi.decode(params, (bool, uint256, bytes));
        uint256 _toRepay = amount + premium;

        if (_lev) {
            // Leverage: use flashloan to deposit borrowed wETH into ether.fi and then supply weETH to AAVE                ;

            _supplyToAAVE(
                _depositToEtherFi(_capAmountByBalance(_asset, amount, false)) + _supplyToken.balanceOf(address(this))
            );
            _borrowFromAAVE(_toRepay);

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
            uint256 _fromCurve = _toRepay * _swapCurveRatio / Constants.TOTAL_BPS;
            uint256 _fromUniswap = _toRepay - _fromCurve;
            uint256 _cappedIn1;
            uint256 _actualOut1;
            uint256 _cappedIn2;
            uint256 _actualOut2;
            if (_fromCurve > 0) {
                (_cappedIn1, _actualOut1) = _swapUsingCurve(_supplyToken, _borrowToken, _fromCurve);
            }
            if (_fromUniswap > 0) {
                (_cappedIn2, _actualOut2) = _swapUsingUniswap(_supplyToken, _borrowToken, _fromUniswap);
            }
            uint256 _actualOut = _actualOut1 + _actualOut2;

            uint256 _bestInTheory = _convertSupplyToAsset(_cappedIn1 + _cappedIn2);
            uint256 _swapLoss = (_bestInTheory > _actualOut ? _bestInTheory - _actualOut : 0);
            emit SwapLossForDeleverage(address(_supplyToken), address(_borrowToken), _actualOut, _swapLoss);

            uint256 _supplyResidueValue = _supplyToken.balanceOf(address(this));
            if (_supplyResidueValue > 0) {
                _requestWithdrawFromEtherFi(_supplyResidueValue, _swapLoss);
            }

            if (_borrowToken.balanceOf(address(this)) < _toRepay) {
                revert Constants.FAIL_TO_REPAY_FLASHLOAN_DELEVERAGE();
            }
        }

        return true;
    }

    function _swapUsingCurve(ERC20 _supplyToken, ERC20 _borrowToken, uint256 _expectOutAmount)
        internal
        returns (uint256, uint256)
    {
        uint256 _expectedIn = _deduceExpectedInFromOutput(_expectOutAmount);
        uint256 _cappedIn = _capAmountByBalance(_supplyToken, _expectedIn, true);
        uint256 _actualOut = TokenSwapper(_swapper).swapInCurveTwoTokenPool(
            address(_supplyToken), address(_borrowToken), weETHPool, _cappedIn, _expectOutAmount
        );
        return (_cappedIn, _actualOut);
    }

    function _swapUsingUniswap(ERC20 _supplyToken, ERC20 _borrowToken, uint256 _expectOutAmount)
        internal
        returns (uint256, uint256)
    {
        uint256 _expectedIn = _deduceExpectedInFromOutput(_expectOutAmount);
        uint256 _cappedIn = _capAmountByBalance(_supplyToken, _expectedIn, true);
        uint256 _actualOut = TokenSwapper(_swapper).swapExactInWithUniswap(
            address(_supplyToken), address(_borrowToken), weETHUniPool, _cappedIn, _expectOutAmount
        );
        return (_cappedIn, _actualOut);
    }

    function _deduceExpectedInFromOutput(uint256 _expectOutAmount) internal view returns (uint256) {
        (int256 _weETHToETHPrice,, uint8 _priceDecimal) = TokenSwapper(_swapper).getPriceFromChainLink(weETH_ETH_FEED);
        return _expectOutAmount * Constants.convertDecimalToUnit(_priceDecimal) / uint256(_weETHToETHPrice);
    }
}
