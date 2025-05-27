// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    address payable _etherfiHelper;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event EtherFiHelperChanged(address indexed _old, address indexed _new);

    constructor(address vault) BaseAAVEStrategy(ERC20(wETH), vault, ERC20(address(weETH)), ERC20(wETH), aWeETH) {
        _approveToken(address(_borrowToken), address(aavePool));
    }

    function setEtherFiHelper(address _newHelper) external onlyStrategist {
        require(_newHelper != Constants.ZRO_ADDR, "!invalid etherfi helper");
        emit EtherFiHelperChanged(_etherfiHelper, _newHelper);
        _etherfiHelper = payable(_newHelper);
    }

    ///////////////////////////////
    // earn with ether.fi
    ///////////////////////////////

    function _depositToEtherFi(uint256 _toDeposit) internal returns (uint256) {
        _toDeposit = _capAmountByBalance(ERC20(wETH), _toDeposit, false);
        _approveToken(wETH, _etherfiHelper);
        return EtherFiHelper(_etherfiHelper).depositToEtherFi(_toDeposit);
    }

    function _requestWithdrawFromEtherFi(uint256 _toWithdrawWeETH, uint256 _swapLoss) internal returns (uint256) {
        _toWithdrawWeETH = _capAmountByBalance(ERC20(address(weETH)), _toWithdrawWeETH, false);
        _approveToken(address(weETH), _etherfiHelper);
        return EtherFiHelper(_etherfiHelper).requestWithdrawFromEtherFi(_toWithdrawWeETH, _swapLoss);
    }

    function claimWithdrawFromEtherFi(uint256 _reqID) external returns (uint256) {
        uint256 _claimed = EtherFiHelper(_etherfiHelper).claimWithdrawFromEtherFi(_reqID);
        _returnAssetToVault(_claimed);
        return _claimed;
    }

    ///////////////////////////////
    // core external methods
    ///////////////////////////////

    function claimAndRepay(uint256[] calldata _reqIds, uint256 _repayAmount) external onlyStrategist {
        uint256 _reqLen = _reqIds.length;
        if (_reqLen > 0) {
            for (uint256 i = 0; i < _reqLen; i++) {
                EtherFiHelper(_etherfiHelper).claimWithdrawFromEtherFi(_reqIds[i]);
            }
        }
        _repayAmount = _capAmountByBalance(_borrowToken, _repayAmount, false);
        if (_repayAmount > 0) _repayDebtToAAVE(_repayAmount);
    }

    function redeem(uint256 _supplyAmount) external override onlyStrategist returns (uint256) {
        (uint256 _margin, uint256 _debtInBorrow) = AAVEHelper(_aaveHelper).getAvailableBorrowAmount(address(this));

        if (_margin == 0) {
            return _margin;
        } else {
            _margin = _debtInBorrow > 0 ? _convertBorrowToSupply(_margin) : _supplyAmount;
        }

        _supplyAmount = _supplyAmount > _margin ? _margin : _supplyAmount;
        _supplyAmount = _withdrawCollateralFromAAVE(_supplyAmount);
        uint256 _reqWithdraw = _capAmountByBalance(_supplyToken, _supplyAmount, false);
        _requestWithdrawFromEtherFi(_reqWithdraw, 0);
        return _reqWithdraw;
    }

    function _leveragePosition(uint256 _assetAmount, uint256 _borrowAmount) internal override {
        require(_borrowAmount > 0, "!invalid borrow amount to leverage in AAVE");

        _prepareSupplyFromAsset(_assetAmount);

        (uint256 _netSupply,,) = getNetSupplyAndDebt(false);
        uint256 _initSupply = _supplyToken.balanceOf(address(this)) + _netSupply;
        require(_initSupply > 0, "!zero supply amount to leverage in AAVE");

        uint256 _safeLeveraged = getSafeLeveragedSupply(_initSupply);
        uint256 _toBorrow = _safeLeveraged == _initSupply ? 0 : _convertSupplyToBorrow(_safeLeveraged - _initSupply);
        _toBorrow = _toBorrow > _borrowAmount ? _borrowAmount : _toBorrow;

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory interestRateModes = new uint256[](1);

        assets[0] = address(_borrowToken);
        amounts[0] = _toBorrow;
        interestRateModes[0] = 0;

        aavePool.flashLoan(address(this), assets, amounts, interestRateModes, address(this), abi.encode(true, 0), 0);
    }

    /**
     * @dev by default, this method will try to maximize the leverage
     */
    function allocate(uint256 amount) external override onlyStrategist {
        if (amount == 0) {
            return;
        }

        if (LEVERAGE_RATIO_BPS > 0) {
            _leveragePosition(amount, type(uint256).max);
        } else {
            _prepareSupplyFromAsset(amount);
            _supplyToAAVE(_supplyToken.balanceOf(address(this)));
        }
    }

    function collect(uint256 amount) public override onlyStrategistOrVault {
        if (amount == 0) {
            return;
        }
        _collectAsset(amount);
        emit CollectInvestment(msg.sender, amount);
        _returnAssetToVault(amount);
    }

    function collectAll() external override onlyStrategistOrVault {
        collect(totalAssets());
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

    function _collectAsset(uint256 _expectedAsset) internal {
        uint256 _residue = _asset.balanceOf(address(this));
        if (_residue >= _expectedAsset) {
            return;
        }

        uint256 _supplyResidue = _supplyToken.balanceOf(address(this));
        uint256 _supplyRequired = _convertAssetToSupply(_expectedAsset - _residue);
        (uint256 _netSupplyAsset, uint256 _debtAsset,) = getNetSupplyAndDebt(true);

        // simply create withdraw request within ether.fi if no need to interact with AAVE
        if (_supplyRequired <= _supplyResidue || _netSupplyAsset == 0) {
            _requestWithdrawFromEtherFi(_applySlippageMargin(_supplyRequired), 0);
            return;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        if (_debtAsset == 0) {
            _withdrawCollateralFromAAVE(_applySlippageMargin(_supplyRequired));
            _requestWithdrawFromEtherFi(_supplyToken.balanceOf(address(this)), 0);
            return;
        }

        _deleverageByFlashloan(_netSupplyAsset, _debtAsset, _expectedAsset);
    }

    function _deleverageByFlashloan(uint256 _netSupplyAsset, uint256 _debtAsset, uint256 _expectedAsset) internal {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory interestRateModes = new uint256[](1);

        assets[0] = address(_borrowToken);
        interestRateModes[0] = 0;

        if (_expectedAsset > 0 && _expectedAsset < _applyLeverageMargin(_netSupplyAsset)) {
            // deleverage a portion if possible
            amounts[0] = AAVEHelper(_aaveHelper).getMaxLeverage(_expectedAsset);
            aavePool.flashLoan(
                address(this), assets, amounts, interestRateModes, address(this), abi.encode(false, _expectedAsset), 0
            );
        } else {
            // deleverage everything
            amounts[0] = _applySlippageMargin(_debtAsset);
            aavePool.flashLoan(
                address(this), assets, amounts, interestRateModes, address(this), abi.encode(false, 0), 0
            );
        }
    }

    ///////////////////////////////
    // strategy customized methods
    ///////////////////////////////
    function totalAssets() public view override returns (uint256) {
        uint256 _residue = _asset.balanceOf(address(this));

        // Check how much we can claim from ether.fi
        uint256 _weETHBalance = ERC20(address(weETH)).balanceOf(address(this));
        uint256 _claimable = etherfiLP.getTotalEtherClaimOf(address(this)) + weETH.getEETHByWeETH(_weETHBalance);
        uint256 _toWithdraw = assetsInCollection();

        // Check supply in AAVE if any
        (uint256 _netSupply,,) = getNetSupplyAndDebt(true);

        return _residue + _claimable + _toWithdraw + _netSupply;
    }

    function assetsInCollection() public view override returns (uint256) {
        return EtherFiHelper(_etherfiHelper).getAllPendingValue(address(this));
    }

    function _prepareSupplyFromAsset(uint256 _assetAmount) internal override returns (uint256) {
        uint256 amount = _capAllocationAmount(_assetAmount);
        if (amount > 0) {
            emit AllocateInvestment(msg.sender, amount);
            _asset.transferFrom(_vault, address(this), amount);
            amount = _depositToEtherFi(amount);
        }
        return amount;
    }

    function _convertAssetToSupply(uint256 _assetAmount) internal view override returns (uint256) {
        return weETH.getWeETHByeETH(_assetAmount);
    }

    function _convertSupplyToAsset(uint256 _supplyAmount) internal view override returns (uint256) {
        return weETH.getEETHByWeETH(_supplyAmount);
    }

    function _convertBorrowToSupply(uint256 _borrowAmount) internal view override returns (uint256) {
        return weETH.getWeETHByeETH(_borrowAmount);
    }

    function _convertSupplyToBorrow(uint256 _supplyAmount) internal view override returns (uint256) {
        return weETH.getEETHByWeETH(_supplyAmount);
    }

    ///////////////////////////////
    // handle flashloan callback from AAVE
    // https://aave.com/docs/developers/flash-loans
    ///////////////////////////////
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        uint256 amount = amounts[0];

        require(msg.sender == address(aavePool), "wrong flashloan caller!");
        require(initiator == address(this), "wrong flashloan initiator!");
        require(assets[0] == address(_borrowToken), "wrong flashloan asset!");
        require(amount > premiums[0], "invalid flashloan premium!");

        require(_borrowToken.balanceOf(address(this)) >= amount, "wrong flashloan amount!");

        (bool _lev, uint256 _expected) = abi.decode(params, (bool, uint256));
        uint256 _toRepay = amount + premiums[0];

        if (_lev) {
            // Leverage: use flashloan to deposit borrowed wETH into ether.fi and then supply weETH to AAVE
            uint256 _supplyAmount =
                _depositToEtherFi(_capAmountByBalance(_asset, amount, false)) + _supplyToken.balanceOf(address(this));

            _supplyToAAVE(_supplyAmount);
            _borrowFromAAVE(_toRepay);

            uint256 _borrowResidue = _borrowToken.balanceOf(address(this));
            require(_borrowResidue >= _toRepay, "can't repay flashloan during leverage!");
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
            uint256 _expectedIn = TokenSwapper(_swapper).queryXWithYInCurve(
                address(_supplyToken), address(_borrowToken), weETHPool, _toRepay
            );
            uint256 _cappedIn = _capAmountByBalance(_supplyToken, _expectedIn, true);
            uint256 _actualOut = TokenSwapper(_swapper).swapInCurveTwoTokenPool(
                address(_supplyToken), address(_borrowToken), weETHPool, _cappedIn, _toRepay, SWAP_SLIPPAGE_BPS
            );

            uint256 _bestInTheory = _convertSupplyToAsset(_cappedIn);
            _requestWithdrawFromEtherFi(
                _supplyToken.balanceOf(address(this)), (_bestInTheory > _actualOut ? _bestInTheory - _actualOut : 0)
            );

            require(_borrowToken.balanceOf(address(this)) >= _toRepay, "can't repay flashloan!");
        }

        return true;
    }
}
