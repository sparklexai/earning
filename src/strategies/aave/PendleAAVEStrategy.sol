// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseAAVEStrategy} from "./BaseAAVEStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "../../utils/Constants.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {AAVEHelper} from "./AAVEHelper.sol";
import {IPMarketV3} from "@pendle/contracts/interfaces/IPMarketV3.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "@pendle/contracts/interfaces/IStandardizedYield.sol";
import {PendleHelper} from "../pendle/PendleHelper.sol";

interface IERC4626Vault {
    function asset() external view returns (address);
}

/**
 * @dev deposit _asset into Pendle sUSDe market and then supply the PT in AAVE
 * @dev and looping-borrow stablecoin to get leveraged position.
 */
contract PendleAAVEStrategy is BaseAAVEStrategy {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    IPMarketV3 public pendleMarket;
    address public _pendleHelper;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event PendleHelperChanged(address indexed _old, address indexed _new);
    event PendleMarketChanged(address indexed _old, address indexed _new);
    event PTTokensPurchased(address indexed assetToken, address indexed ptToken, uint256 assetAmount, uint256 ptAmount);
    event PTTokensSwapped(address indexed assetToken, address indexed ptToken, uint256 ptAmount, uint256 assetAmount);

    constructor(address asset, address vault) BaseAAVEStrategy(ERC20(asset), vault) {}

    /**
     * @dev allow only called by strategist or owner or aavePool.
     */
    modifier onlyStrategistOrOwnerOrAAVE() {
        if (
            msg.sender != _strategist && msg.sender != owner() && msg.sender != address(aavePool)
                && msg.sender != address(sparkPool)
        ) {
            revert Constants.ONLY_FOR_STRATEGIST_OR_OWNER_OR_FL();
        }
        _;
    }

    // call this after aaveHelper.setTokens()
    function setPendleMarket(address _newMarket) external onlyOwner {
        if (_newMarket == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        (, IPPrincipalToken _PT,) = IPMarketV3(_newMarket).readTokens();

        if (address(_PT) != address(AAVEHelper(_aaveHelper)._supplyToken())) {
            revert Constants.DIFFERENT_TOKEN_IN_AAVE_HELPER();
        }

        _prepareAllowanceForHelper();
        emit PendleMarketChanged(address(pendleMarket), _newMarket);
        pendleMarket = IPMarketV3(_newMarket);
    }

    function setPendleHelper(address _newHelper) external onlyOwner {
        if (_newHelper == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        emit PendleHelperChanged(_pendleHelper, _newHelper);
        _pendleHelper = _newHelper;
    }

    ///////////////////////////////
    // earn with Pendle: Trading Functions
    ///////////////////////////////
    function getPTPriceInAssetWithHeartbeat(address _assetToken, address ptToken, uint32 _heartbeat)
        public
        view
        returns (uint256)
    {
        address _syToken = IPPrincipalToken(ptToken).SY();
        address _yieldToken = IStandardizedYield(_syToken).yieldToken();
        address _yieldOracle = TokenSwapper(_swapper).getAssetOracle(_yieldToken);
        return TokenSwapper(_swapper).getPTPriceInAsset(
            _assetToken,
            TokenSwapper(_swapper).getAssetOracle(_assetToken),
            address(pendleMarket),
            TokenSwapper(_swapper).PENDLE_ORACLE_TWAP(),
            _heartbeat,
            _yieldToken,
            (_yieldOracle == Constants.ZRO_ADDR ? _yieldToken : _yieldOracle),
            (
                _yieldOracle == Constants.ZRO_ADDR
                    ? TokenSwapper(_swapper).getAssetOracle(IERC4626Vault(_yieldToken).asset())
                    : Constants.ZRO_ADDR
            ),
            Constants.ONE_ETHER
        );
    }

    function getPTPriceInAsset(address _assetToken, address ptToken) public view returns (uint256) {
        return getPTPriceInAssetWithHeartbeat(_assetToken, ptToken, TokenSwapper(_swapper).DEFAULT_Heartbeat());
    }

    /**
     * @notice Buy PT tokens with given asset token
     * @param _assetToken purchase PT with this asset
     * @param assetAmount Amount of asset token to spend
     * @param _swapData calldata from pendle SDK
     */
    function buyPTWithAsset(address _assetToken, uint256 assetAmount, bytes memory _swapData)
        public
        onlyStrategistOrOwnerOrAAVE
        onlyVaultNotPaused
        returns (uint256)
    {
        address ptToken = address(AAVEHelper(_aaveHelper)._supplyToken());
        PendleHelper(_pendleHelper)._checkValidityWithMarket(ptToken, address(pendleMarket), true);
        _approveToken(_assetToken, _pendleHelper);
        uint256 ptReceived = PendleHelper(_pendleHelper)._swapAssetForPT(
            _assetToken, ptToken, assetAmount, _swapData, TokenSwapper(_swapper).TARGET_SELECTOR_BUY()
        );
        emit PTTokensPurchased(_assetToken, ptToken, assetAmount, ptReceived);
        return ptReceived;
    }

    /**
     * @notice Swap PT tokens for given asset token
     * @param _assetToken swap PT for this asset
     * @param ptAmount Amount of PT tokens to sell
     * @param _swapData calldata from pendle SDK
     */
    function swapPTForAsset(address _assetToken, uint256 ptAmount, bool _redeemPT, bytes memory _swapData)
        public
        onlyStrategistOrOwnerOrAAVE
        returns (uint256)
    {
        address ptToken = address(AAVEHelper(_aaveHelper)._supplyToken());
        PendleHelper(_pendleHelper)._checkValidityWithMarket(ptToken, address(pendleMarket), !_redeemPT);
        _approveToken(ptToken, _pendleHelper);
        uint256 assetAmount = PendleHelper(_pendleHelper)._swapPTForAsset(
            _assetToken,
            ptToken,
            ptAmount,
            _swapData,
            (
                _redeemPT
                    ? TokenSwapper(_swapper).TARGET_SELECTOR_REDEEM()
                    : TokenSwapper(_swapper).TARGET_SELECTOR_SELL()
            )
        );
        emit PTTokensSwapped(_assetToken, ptToken, ptAmount, assetAmount);
        return assetAmount;
    }

    ///////////////////////////////
    // Internal Functions
    ///////////////////////////////

    /**
     * @dev withdraw as much as possible supply collateral (PT) from AAVE
     * @dev and repay the debt to lower LTV
     */
    function redeem(uint256 _supplyAmount, bytes calldata _extraAction)
        external
        override
        onlyStrategistOrOwner
        returns (uint256)
    {
        uint256 _margin = AAVEHelper(_aaveHelper).getMaxRedeemableAmount();

        if (_margin == 0) {
            return _margin;
        }

        if (_supplyAmount > _margin) {
            revert Constants.TOO_MUCH_SUPPLY_TO_REDEEM();
        }

        _supplyAmount = _withdrawCollateralFromAAVE(_supplyAmount);
        uint256 _ptAmount = _capAmountByBalance(AAVEHelper(_aaveHelper)._supplyToken(), _supplyAmount, false);
        uint256 _repaidDebt;
        if (_extraAction.length > 0) {
            _repaidDebt = _swapPTToAsset(address(AAVEHelper(_aaveHelper)._borrowToken()), _ptAmount, _extraAction);
            if (_repaidDebt > 0) {
                _repayDebtToAAVE(_repaidDebt);
            }
        }

        return _repaidDebt;
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _swapPTToAsset(address _assetToken, uint256 _ptAmount, bytes memory _swapData)
        internal
        returns (uint256)
    {
        return swapPTForAsset(
            address(_assetToken),
            _ptAmount,
            IPPrincipalToken(address(AAVEHelper(_aaveHelper)._supplyToken())).isExpired(),
            _swapData
        );
    }

    function _collectAsset(uint256 _expectedAsset, bytes calldata _extraAction) internal override {
        uint256[] memory _previews = AAVEHelper(_aaveHelper).previewCollect(_expectedAsset);
        if (_previews[0] == 0) {
            return;
        }

        // simply swap PT back to _asset if no need to interact with AAVE
        if (_previews[0] == 1) {
            _swapPTToAsset(
                address(_asset),
                _capAmountByBalance(AAVEHelper(_aaveHelper)._supplyToken(), _previews[1], false),
                _extraAction
            );
            return;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        if (_previews[0] == 2) {
            _withdrawCollateralFromAAVE(_previews[1]);
            _swapPTToAsset(
                address(_asset),
                _capAmountByBalance(AAVEHelper(_aaveHelper)._supplyToken(), _previews[1] + _previews[2], false),
                _extraAction
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
        ERC20 _ptToken = AAVEHelper(_aaveHelper)._supplyToken();
        // Check how much PT we have
        uint256 _ptBalance = PendleHelper(_pendleHelper)._getAmountInAsset(
            address(_asset), address(_ptToken), _ptToken.balanceOf(address(this))
        );

        // Check supply in AAVE if any
        (uint256 _netSupply,,) = getNetSupplyAndDebt(true);

        return _asset.balanceOf(address(this)) + _ptBalance + _netSupply;
    }

    function assetsInCollection() external pure override returns (uint256) {
        return 0;
    }

    function _prepareSupplyFromAsset(uint256 _assetAmount, bytes memory _swapData)
        internal
        override
        returns (uint256)
    {
        uint256 amount = _capAllocationAmount(_assetAmount);
        if (amount > 0) {
            SafeERC20.safeTransferFrom(_asset, _vault, address(this), amount);
            if (_swapData.length > 0) {
                (bytes memory _prepareCalldata,,) = abi.decode(_swapData, (bytes, uint256, bytes));
                amount = buyPTWithAsset(address(_asset), _assetAmount, _prepareCalldata);
            }
            emit AllocateInvestment(msg.sender, amount);
        }
        return amount;
    }

    function _convertAssetToSupply(uint256 _assetAmount) public view override returns (uint256) {
        return PendleHelper(_pendleHelper)._getAmountInPT(
            address(_asset), address(AAVEHelper(_aaveHelper)._supplyToken()), _assetAmount
        );
    }

    function _convertSupplyToAsset(uint256 _supplyAmount) public view override returns (uint256) {
        return PendleHelper(_pendleHelper)._getAmountInAsset(
            address(_asset), address(AAVEHelper(_aaveHelper)._supplyToken()), _supplyAmount
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
        if (msg.sender != address(aavePool) && msg.sender != address(sparkPool)) {
            revert Constants.WRONG_AAVE_FLASHLOAN_CALLER();
        }
        if (initiator != address(this)) {
            revert Constants.WRONG_AAVE_FLASHLOAN_INITIATOR();
        }
        if (asset != address(AAVEHelper(_aaveHelper)._borrowToken())) {
            revert Constants.WRONG_AAVE_FLASHLOAN_ASSET();
        }
        if (amount <= premium) {
            revert Constants.WRONG_AAVE_FLASHLOAN_PREMIUM();
        }
        if (AAVEHelper(_aaveHelper)._borrowToken().balanceOf(address(this)) < amount) {
            revert Constants.WRONG_AAVE_FLASHLOAN_AMOUNT();
        }

        (bool _lev, uint256 _expected, bytes memory _extraAction) = abi.decode(params, (bool, uint256, bytes));
        uint256 _toRepay = amount + premium;

        if (_lev) {
            // decode from _extraAction
            (,, bytes memory _calldataInFL) = abi.decode(_extraAction, (bytes, uint256, bytes));

            // Leverage: use flashloan to covert borrowed stablecoin to PT and then supply to AAVE
            _supplyToAAVE(
                buyPTWithAsset(address(AAVEHelper(_aaveHelper)._borrowToken()), amount, _calldataInFL)
                    + AAVEHelper(_aaveHelper)._supplyToken().balanceOf(address(this))
            );
            _borrowFromAAVE(_toRepay);

            uint256 _borrowResidue = AAVEHelper(_aaveHelper)._borrowToken().balanceOf(address(this));
            if (_borrowResidue < _toRepay) {
                revert Constants.FAIL_TO_REPAY_FLASHLOAN_LEVERAGE();
            }
            _borrowResidue = _borrowResidue > _toRepay ? (_borrowResidue - _toRepay) : 0;

            // return any remaining to vault
            if (_borrowResidue > 0) {
                _returnAssetToVault(_borrowResidue);
            }
        } else {
            // Deleverage: use flashloan to clear debt in AAVE
            // and then swap withdrawn PT (_supplyToken) for _asset
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

            _swapPTToAsset(
                address(AAVEHelper(_aaveHelper)._borrowToken()),
                AAVEHelper(_aaveHelper)._supplyToken().balanceOf(address(this)),
                _extraAction
            );

            if (AAVEHelper(_aaveHelper)._borrowToken().balanceOf(address(this)) < _toRepay) {
                revert Constants.FAIL_TO_REPAY_FLASHLOAN_DELEVERAGE();
            }
        }

        return true;
    }
}
