// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseAAVEStrategy} from "./BaseAAVEStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {Constants} from "../../utils/Constants.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {AAVEHelper} from "./AAVEHelper.sol";

/**
 * @dev swap for sUSDe then supply in AAVE and looping borrow USDT to get leveraged position.
 */
contract StakedUSDeAAVEStrategy is BaseAAVEStrategy {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant sUSDe_USD_Feed = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099;
    address public constant FLUID_USDC_USDT_POOL = 0x667701e51B4D1Ca244F17C78F7aB8744B4C99F9B;
    address public constant FLUID_sUSDe_USDT_POOL = 0x1DD125C32e4B5086c63CC13B3cA02C4A2a61Fa9b;

    ///////////////////////////////
    // member storage
    ///////////////////////////////

    ///////////////////////////////
    // events
    ///////////////////////////////

    constructor(address vault) BaseAAVEStrategy(ERC20(USDC), vault) {}

    ///////////////////////////////
    // earn with Ethena StakedUSDe
    ///////////////////////////////

    /*
     * @dev swap borrowed token with given amount to asset token and return to vault
     */
    function swapBorrowToVault() public onlyStrategistOrOwner returns (uint256) {
        uint256 _borrowToSwap = ERC20(USDT).balanceOf(address(this));
        return _swapBorrowToVault(_borrowToSwap);
    }

    function _swapBorrowToVault(uint256 _borrowToSwap) internal returns (uint256) {
        if (_borrowToSwap == 0) {
            return _borrowToSwap;
        }
        uint256 _minOut = _convertBorrowToAsset(_borrowToSwap);
        _approveToken(USDT, _swapper);
        uint256 _toVault =
            TokenSwapper(_swapper).singleSwapViaFluid(USDT, USDC, false, FLUID_USDC_USDT_POOL, _borrowToSwap, _minOut);
        return _returnAssetToVault(_toVault);
    }

    function _swapFromUSDCToStakedUSDe(uint256 _toSwap) internal returns (uint256) {
        uint256 _minOutIntermediate = _convertAssetToBorrow(_toSwap);
        _approveToken(USDC, _swapper);
        uint256 _intermediate = TokenSwapper(_swapper).singleSwapViaFluid(
            USDC, USDT, true, FLUID_USDC_USDT_POOL, _toSwap, _minOutIntermediate
        );
        uint256 _minOut = _convertBorrowToSupply(_intermediate);
        _approveToken(USDT, _swapper);
        return
            TokenSwapper(_swapper).singleSwapViaFluid(USDT, sUSDe, false, FLUID_sUSDe_USDT_POOL, _intermediate, _minOut);
    }

    function _swapFromStakedUSDeToUSDC(uint256 _toSwap) internal returns (uint256) {
        _toSwap = _capAmountByBalance(ERC20(sUSDe), _toSwap, false);
        if (_toSwap == 0) {
            return _toSwap;
        }
        uint256 _minOutIntermediate = _convertSupplyToBorrow(_toSwap);
        _approveToken(sUSDe, _swapper);
        uint256 _intermediate = TokenSwapper(_swapper).singleSwapViaFluid(
            sUSDe, USDT, true, FLUID_sUSDe_USDT_POOL, _toSwap, _minOutIntermediate
        );
        uint256 _minOut = _convertBorrowToAsset(_intermediate);
        _approveToken(USDT, _swapper);
        return
            TokenSwapper(_swapper).singleSwapViaFluid(USDT, USDC, false, FLUID_USDC_USDT_POOL, _intermediate, _minOut);
    }

    function _swapFromStakedUSDeToUSDT(uint256 _toSwap) internal returns (uint256) {
        _toSwap = _capAmountByBalance(ERC20(sUSDe), _toSwap, false);
        if (_toSwap == 0) {
            return _toSwap;
        }
        uint256 _minOut = _convertSupplyToBorrow(_toSwap);
        _approveToken(sUSDe, _swapper);
        uint256 _actualOut =
            TokenSwapper(_swapper).singleSwapViaFluid(sUSDe, USDT, true, FLUID_sUSDe_USDT_POOL, _toSwap, _minOut);
        return _actualOut;
    }

    function _swapFromStakedUSDeToUSDTByOutput(uint256 _targetOutput) internal returns (uint256) {
        uint256 _expectedIn = _convertBorrowToSupply(_targetOutput);
        uint256 _cappedIn = _capAmountByBalance(ERC20(sUSDe), _expectedIn, true);
        return _swapFromStakedUSDeToUSDT(_cappedIn);
    }

    function _swapFromUSDTToStakedUSDe(uint256 _toSwap) internal returns (uint256) {
        uint256 _minOut = _convertBorrowToSupply(_toSwap);
        _approveToken(USDT, _swapper);
        return TokenSwapper(_swapper).singleSwapViaFluid(USDT, sUSDe, false, FLUID_sUSDe_USDT_POOL, _toSwap, _minOut);
    }

    ///////////////////////////////
    // core external methods
    ///////////////////////////////

    /**
     * @dev convert the supplied collateral (with already withdrawn amount) and repay borrowed debt in AAVE
     */
    function convertSupplyToRepay() external onlyStrategistOrOwner returns (uint256) {
        _swapFromStakedUSDeToUSDT(ERC20(sUSDe).balanceOf(address(this)));
        uint256 _repayAmount = AAVEHelper(_aaveHelper)._borrowToken().balanceOf(address(this));
        if (_repayAmount > 0) {
            _repayDebtToAAVE(_repayAmount);
        }
        uint256 _residue = AAVEHelper(_aaveHelper)._borrowToken().balanceOf(address(this));
        if (_residue > 0) {
            _swapBorrowToVault(_residue);
        }
        return _repayAmount;
    }

    /**
     * @dev withdraw as much as possible supply collateral (sUSDe) from AAVE
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

        // simply swap back from supply token
        if (_previews[0] == 1) {
            _swapFromStakedUSDeToUSDC(_previews[1]);
            return;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        if (_previews[0] == 2) {
            _withdrawCollateralFromAAVE(_previews[1]);
            _swapFromStakedUSDeToUSDC(AAVEHelper(_aaveHelper)._supplyToken().balanceOf(address(this)));
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
        return _asset.balanceOf(address(this)) + _netSupply
            + _convertBorrowToAsset(ERC20(USDT).balanceOf(address(this)))
            + _convertSupplyToAsset(ERC20(sUSDe).balanceOf(address(this)));
    }

    function assetsInCollection() public view override returns (uint256) {
        return 0;
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
            amount = _swapFromUSDCToStakedUSDe(amount);
        }
        return amount;
    }

    function _convertAssetToBorrow(uint256 _assetAmount) public view override returns (uint256) {
        return TokenSwapper(_swapper).convertAmountWithFeeds(
            ERC20(USDC),
            _assetAmount,
            TokenSwapper(_swapper).getAssetOracle(USDC),
            ERC20(USDT),
            TokenSwapper(_swapper).getAssetOracle(USDT),
            TokenSwapper(_swapper).DEFAULT_Heartbeat(),
            TokenSwapper(_swapper).DEFAULT_Heartbeat()
        );
    }

    function _convertAssetToSupply(uint256 _assetAmount) public view override returns (uint256) {
        return TokenSwapper(_swapper).convertAmountWithFeeds(
            ERC20(USDC),
            _assetAmount,
            TokenSwapper(_swapper).getAssetOracle(USDC),
            ERC20(sUSDe),
            sUSDe_USD_Feed,
            TokenSwapper(_swapper).DEFAULT_Heartbeat(),
            TokenSwapper(_swapper).DEFAULT_Heartbeat()
        );
    }

    function _convertSupplyToAsset(uint256 _supplyAmount) public view override returns (uint256) {
        return TokenSwapper(_swapper).convertAmountWithFeeds(
            ERC20(sUSDe),
            _supplyAmount,
            sUSDe_USD_Feed,
            ERC20(USDC),
            TokenSwapper(_swapper).getAssetOracle(USDC),
            TokenSwapper(_swapper).DEFAULT_Heartbeat(),
            TokenSwapper(_swapper).DEFAULT_Heartbeat()
        );
    }

    function _convertSupplyToBorrow(uint256 _supplyAmount) public view override returns (uint256) {
        return TokenSwapper(_swapper).convertAmountWithFeeds(
            ERC20(sUSDe),
            _supplyAmount,
            sUSDe_USD_Feed,
            ERC20(USDT),
            TokenSwapper(_swapper).getAssetOracle(USDT),
            TokenSwapper(_swapper).DEFAULT_Heartbeat(),
            TokenSwapper(_swapper).DEFAULT_Heartbeat()
        );
    }

    function _convertBorrowToAsset(uint256 _borrowAmount) public view override returns (uint256) {
        return TokenSwapper(_swapper).convertAmountWithFeeds(
            ERC20(USDT),
            _borrowAmount,
            TokenSwapper(_swapper).getAssetOracle(USDT),
            ERC20(USDC),
            TokenSwapper(_swapper).getAssetOracle(USDC),
            TokenSwapper(_swapper).DEFAULT_Heartbeat(),
            TokenSwapper(_swapper).DEFAULT_Heartbeat()
        );
    }

    function _convertBorrowToSupply(uint256 _borrowAmount) public view override returns (uint256) {
        return TokenSwapper(_swapper).convertAmountWithFeeds(
            ERC20(USDT),
            _borrowAmount,
            TokenSwapper(_swapper).getAssetOracle(USDT),
            ERC20(sUSDe),
            sUSDe_USD_Feed,
            TokenSwapper(_swapper).DEFAULT_Heartbeat(),
            TokenSwapper(_swapper).DEFAULT_Heartbeat()
        );
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

        _approveToken(address(_borrowToken), address(aavePool));
        _approveToken(address(_borrowToken), address(sparkPool));

        if (_lev) {
            // Leverage: use flashloan to supply borrowed token to AAVE
            _supplyToAAVE(
                _swapFromUSDTToStakedUSDe(_capAmountByBalance(_borrowToken, amount, false))
                    + _supplyToken.balanceOf(address(this))
            );
            _borrowFromAAVE(_toRepay);

            uint256 _borrowResidue = _borrowToken.balanceOf(address(this));
            if (_borrowResidue < _toRepay) {
                revert Constants.FAIL_TO_REPAY_FLASHLOAN_LEVERAGE();
            }
            _borrowResidue = _borrowResidue > _toRepay ? (_borrowResidue - _toRepay) : 0;

            // return any remaining to vault
            if (_borrowResidue > 0) {
                _swapBorrowToVault(_borrowResidue);
            }
        } else {
            // Deleverage: use flashloan to clear debt in AAVE
            // and then withdraw collateral from AAVE to swap for asset
            // and lastly repay flashloan
            if (_expected == 0) {
                // redeem everything
                _repayDebtToAAVE(type(uint256).max);
                _withdrawCollateralFromAAVE(type(uint256).max);
            } else {
                // redeem some collateral
                _repayDebtToAAVE(amount);
                _withdrawCollateralFromAAVE(_convertBorrowToSupply(_expected + _toRepay));
            }

            // NOTE!!! this flow might incur some slippage loss, please use at careful discretion
            uint256 _actualOut = _swapFromStakedUSDeToUSDTByOutput(_toRepay);
            uint256 _supplyResidueValue = _supplyToken.balanceOf(address(this));
            if (_supplyResidueValue > 0) {
                uint256 _assetFromSupplyResidue = _swapFromStakedUSDeToUSDC(_supplyResidueValue);
                _returnAssetToVault(_assetFromSupplyResidue);
            }

            uint256 _borrowBalance = _borrowToken.balanceOf(address(this));
            if (_borrowBalance < _toRepay) {
                revert Constants.FAIL_TO_REPAY_FLASHLOAN_DELEVERAGE();
            }

            uint256 _borrowResidueValue = _borrowBalance - _toRepay;
            if (_borrowResidueValue > 0) {
                _swapBorrowToVault(_borrowResidueValue);
            }
        }

        return true;
    }
}
