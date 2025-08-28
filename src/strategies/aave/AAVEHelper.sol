// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {Constants} from "../../utils/Constants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseAAVEStrategy} from "./BaseAAVEStrategy.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";

contract AAVEHelper is Ownable {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    /**
     * @dev leverage ratio in AAVE with looping supply and borrow OR
     * @dev borrowing ratio in AAVE with respect to maximum allowed LTV
     */
    uint256 public LEVERAGE_RATIO_BPS = 9500;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IPool sparkPool = IPool(0xC13e21B648A5Ee794902342038FF3aDAB66BE987);
    IAaveOracle aaveOracle = IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    uint8 public _eMode;
    ERC20 public _supplyToken;
    ERC20 public _borrowToken;
    ERC20 public _supplyAToken;
    address public immutable _strategy;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event AAVEHelperCreated(
        address indexed strategy, address indexed supplyToken, address indexed borrowToken, uint8 eMode
    );
    event SupplyToAAVE(address indexed _caller, uint256 _supplied, uint256 _mintedAToken, uint256 _health);
    event BorrowFromAAVE(address indexed _caller, uint256 _borrowed, uint256 _health);
    event RepayDebtInAAVE(address indexed _caller, uint256 _repaid, uint256 _health);
    event AAVEHelperTokensChanged(
        address indexed supplyAToken, address indexed supplyToken, address indexed borrowToken, uint8 eMode
    );
    event AAVEPoolChanged(address indexed _old, address indexed _new);
    event AAVEOracleChanged(address indexed _old, address indexed _new);

    constructor(address strategy, ERC20 supplyToken, ERC20 borrowToken, ERC20 supplyAToken, uint8 eMode)
        Ownable(msg.sender)
    {
        if (block.chainid == 56) {
            _switchToBNBChain();
        }
        _strategy = strategy;

        address _newAAVEPool = address(BaseAAVEStrategy(_strategy).aavePool());
        if (_newAAVEPool != address(aavePool)) {
            emit AAVEPoolChanged(address(aavePool), _newAAVEPool);
            aavePool = IPool(_newAAVEPool);

            if (_newAAVEPool == address(sparkPool)) {
                address _newAAVEOracle = BaseAAVEStrategy(_strategy).sparkOracle();
                emit AAVEOracleChanged(address(aaveOracle), _newAAVEOracle);
                aaveOracle = IAaveOracle(_newAAVEOracle);
            }
        }

        _setTokensAndApprovals(supplyToken, borrowToken, supplyAToken);

        // Enable E Mode in AAVE for correlated assets
        if (eMode > 0) {
            _setEMode(eMode);
        }

        emit AAVEHelperCreated(_strategy, address(supplyToken), address(borrowToken), _eMode);
    }

    function _setEMode(uint8 eMode) internal {
        if (aavePool.getUserEMode(address(this)) != eMode) {
            aavePool.setUserEMode(eMode);
        }
        _eMode = eMode;
    }

    function setLeverageRatio(uint256 _ratio) external onlyOwner {
        if (_ratio > Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        LEVERAGE_RATIO_BPS = _ratio;
    }

    function setTokens(ERC20 supplyToken, ERC20 borrowToken, ERC20 supplyAToken, uint8 eMode) external onlyOwner {
        if (
            address(supplyToken) == Constants.ZRO_ADDR || address(borrowToken) == Constants.ZRO_ADDR
                || address(supplyAToken) == Constants.ZRO_ADDR
        ) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }

        (uint256 _netSupply, uint256 _debt,) = getSupplyAndDebt(true);
        if (_netSupply > 0 || _debt > 0) {
            revert Constants.POSITION_STILL_IN_USE();
        }

        _setTokensAndApprovals(supplyToken, borrowToken, supplyAToken);
        _setEMode(eMode);

        emit AAVEHelperTokensChanged(address(supplyAToken), address(supplyToken), address(borrowToken), eMode);
    }

    function _setTokensAndApprovals(ERC20 supplyToken, ERC20 borrowToken, ERC20 supplyAToken) internal {
        _supplyToken = supplyToken;
        _borrowToken = borrowToken;
        _supplyAToken = supplyAToken;

        SafeERC20.forceApprove(_supplyToken, address(aavePool), type(uint256).max);
        SafeERC20.forceApprove(_borrowToken, address(aavePool), type(uint256).max);
    }

    ///////////////////////////////
    // supply/withdraw and borrow/repay within AAVE
    ///////////////////////////////

    function supplyToAAVE(uint256 _supplyAmount) external returns (uint256) {
        if (msg.sender != _strategy) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        SafeERC20.safeTransferFrom(_supplyToken, msg.sender, address(this), _supplyAmount);

        uint256 _aTokenBefore = _supplyAToken.balanceOf(msg.sender);
        aavePool.supply(address(_supplyToken), _supplyAmount, msg.sender, 0);
        uint256 _aTokenAfter = _supplyAToken.balanceOf(msg.sender);
        uint256 _minted = _aTokenAfter - _aTokenBefore;

        (,,,,, uint256 newHealthFactor) = aavePool.getUserAccountData(msg.sender);
        emit SupplyToAAVE(msg.sender, _supplyAmount, _minted, newHealthFactor);
        return _minted;
    }

    function borrowFromAAVE(uint256 _toBorrow) external returns (uint256) {
        if (msg.sender != _strategy) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        uint256 _toBorrowBefore = _borrowToken.balanceOf(address(this));
        aavePool.borrow(address(_borrowToken), _toBorrow, 2, 0, msg.sender);
        uint256 _toBorrowAfter = _borrowToken.balanceOf(address(this));
        uint256 _borrowed = _toBorrowAfter - _toBorrowBefore;

        (,,,,, uint256 newHealthFactor) = aavePool.getUserAccountData(msg.sender);
        emit BorrowFromAAVE(msg.sender, _borrowed, newHealthFactor);
        SafeERC20.safeTransfer(_borrowToken, msg.sender, _borrowed);
        return _borrowed;
    }

    function repayDebtToAAVE(uint256 _debtToRepay) external returns (uint256) {
        if (msg.sender != _strategy) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        uint256 _borrowTokenOnBehalf = _borrowToken.balanceOf(msg.sender);
        SafeERC20.safeTransferFrom(_borrowToken, msg.sender, address(this), _borrowTokenOnBehalf);

        uint256 _borrowBefore = _borrowToken.balanceOf(address(this));
        uint256 _repaid = aavePool.repay(address(_borrowToken), _debtToRepay, 2, msg.sender);
        uint256 _borrowAfter = _borrowToken.balanceOf(address(this));

        uint256 _diff = _borrowBefore - _borrowAfter;
        if (_borrowTokenOnBehalf > _diff) {
            SafeERC20.safeTransfer(_borrowToken, msg.sender, _borrowTokenOnBehalf - _diff);
        }

        (,,,,, uint256 newHealthFactor) = aavePool.getUserAccountData(msg.sender);
        emit RepayDebtInAAVE(msg.sender, _repaid, newHealthFactor);
        return _repaid;
    }

    /**
     * @dev get maximum LTV specified by the AAVE E-Mode
     */
    function getMaxLTV() public view returns (uint256) {
        uint256 _ltv = 0;
        if (_eMode > 0) {
            if (address(aavePool) == address(sparkPool)) {
                DataTypes.EModeCategoryLegacy memory config = aavePool.getEModeCategoryData(_eMode);
                _ltv = config.ltv;
            } else {
                DataTypes.CollateralConfig memory config = aavePool.getEModeCategoryCollateralConfig(_eMode);
                _ltv = config.ltv;
            }
        } else {
            DataTypes.ReserveDataLegacy memory reserveData = aavePool.getReserveData(address(_supplyToken));
            _ltv = _getReserveLTV(reserveData.configuration);
        }
        require(_ltv < Constants.TOTAL_BPS, "wrong ltv!");
        return _ltv;
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
     * @dev Return available borrow token amount in its own denominations
     */
    function getAvailableBorrowAmount(address _position) public view returns (uint256, uint256) {
        (, uint256 totalDebtBase, uint256 availableBorrowsBase,,,) = aavePool.getUserAccountData(_position);

        uint256 _availableToBorrow = availableBorrowsBase > 0
            ? convertFromBaseAmount(
                address(_borrowToken), availableBorrowsBase, Constants.convertDecimalToUnit(_borrowToken.decimals())
            )
            : 0;
        uint256 _debtInBorrow = totalDebtBase > 0
            ? convertFromBaseAmount(
                address(_borrowToken), totalDebtBase, Constants.convertDecimalToUnit(_borrowToken.decimals())
            )
            : 0;
        return (_availableToBorrow, _debtInBorrow);
    }

    /**
     * @dev Return supply and borrow amount in their own denominations and base unit
     */
    function getTotalSupplyAndDebt(address _position) public view returns (uint256, uint256, uint256, uint256) {
        (uint256 totalCollateralBase, uint256 totalDebtBase,,,,) = aavePool.getUserAccountData(_position);
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
        return (_cAmount, _dAmount, totalCollateralBase, totalDebtBase);
    }

    /*
     * @dev calculate the maximum allowed position size in supply token denomination:
     * @dev   - for looping, it is the fully-leveraged supply in theory
     * @dev   - for simple borrowing, it is the debt amount capped by LTV
     */
    function getMaxLeverage(uint256 _amount) public view returns (uint256) {
        uint256 _maxLTV = getMaxLTV();
        if (!loopingBorrow()) {
            // NO LOOPing: simple borrowing
            return _amount * _maxLTV / Constants.TOTAL_BPS;
        } else {
            return _amount * _maxLTV / (Constants.TOTAL_BPS - _maxLTV);
        }
    }

    function applyLeverageMargin(uint256 _max) public view returns (uint256) {
        return _max * LEVERAGE_RATIO_BPS / Constants.TOTAL_BPS;
    }

    function getSafeLeveragedSupply(uint256 _initialSupply) public view returns (uint256) {
        return LEVERAGE_RATIO_BPS > 0 ? applyLeverageMargin(getMaxLeverage(_initialSupply)) : _initialSupply;
    }

    /**
     * @dev strategist could use this method to estimate the required amount of _borrowToken in flashloan for calling invest()
     * @dev The borrowed amount will be converted to _supplyToken later in flashloan callback
     */
    function previewLeverageForInvest(uint256 _assetAmount, uint256 _borrowAmount) public view returns (uint256) {
        (uint256 _netSupply, uint256 _debtInSupply,) = BaseAAVEStrategy(_strategy).getNetSupplyAndDebt(false);

        uint256 _initSupply = _netSupply + _supplyToken.balanceOf(_strategy)
            + (_assetAmount > 0 ? BaseAAVEStrategy(_strategy)._convertAssetToSupply(_assetAmount) : 0);

        if (_initSupply == 0) {
            revert Constants.ZERO_SUPPLY_FOR_AAVE_LEVERAGE();
        }

        uint256 _safeLeveraged = getSafeLeveragedSupply(_initSupply);
        uint256 _supplyToLeverage;

        if (!loopingBorrow()) {
            // NO LOOPing: simple borrowing
            if (_safeLeveraged <= _debtInSupply) {
                revert Constants.FAIL_TO_SAFE_LEVERAGE();
            }
            _supplyToLeverage = _safeLeveraged - _debtInSupply;
        } else {
            if (_safeLeveraged <= _initSupply + _debtInSupply) {
                revert Constants.FAIL_TO_SAFE_LEVERAGE();
            }
            _supplyToLeverage = _safeLeveraged - _initSupply - _debtInSupply;
        }

        uint256 _toBorrow = BaseAAVEStrategy(_strategy)._convertSupplyToBorrow(_supplyToLeverage);
        _toBorrow = _toBorrow > _borrowAmount ? _borrowAmount : _toBorrow;
        return _toBorrow;
    }

    /**
     * @dev strategist could use this method to estimate the amount required to prepare for calling collect()
     * @dev possible results are:
     * [0, _assetBalance] to indicate that strategy has enough asset to collect directly
     * [1, _supplyRequired, _supplyResidue] to indicate that strategy need to convert _supplyToken of _supplyRequired amout directly
     * [2, _supplyRequired, _supplyResidue] to indicate that strategy need to withdraw _supplyToken from AAVE first then convert _supplyRequired amout
     * [3, _netSuppliedAsset, _toBorrowForFull, _toBorrowForPortion, _amountForExtraAction] to indicate flashloan based deleverage required
     */
    function previewCollect(uint256 _amountToCollect) public view virtual returns (uint256[] memory) {
        uint256[] memory _result;
        uint256 _residue = ERC20(BaseAAVEStrategy(_strategy).asset()).balanceOf(_strategy);
        // case [0]
        if (_residue >= _amountToCollect) {
            _result = new uint256[](2);
            _result[0] = 0;
            _result[1] = _residue;
            return _result;
        }

        uint256 _supplyResidue = _supplyToken.balanceOf(_strategy);
        uint256 _supplyRequired = BaseAAVEStrategy(_strategy)._convertAssetToSupply(_amountToCollect - _residue);
        (uint256 _netSupply, uint256 _debt, uint256 _totalInSupply) =
            BaseAAVEStrategy(_strategy).getNetSupplyAndDebt(false);
        // simply convert _supplyToken back to _asset if no need to interact with AAVE
        // case [1]
        if (_supplyRequired <= _supplyResidue || _netSupply == 0) {
            _result = new uint256[](3);
            _result[0] = 1;
            _result[1] = TokenSwapper(BaseAAVEStrategy(_strategy)._swapper()).applySlippageMargin(_supplyRequired);
            _result[1] = _result[1] > _supplyResidue ? _supplyResidue : _result[1];
            _result[2] = _supplyResidue;
            return _result;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        // case [2]
        if (_debt == 0) {
            _result = new uint256[](3);
            _result[0] = 2;
            _result[1] = TokenSwapper(BaseAAVEStrategy(_strategy)._swapper()).applySlippageMargin(_supplyRequired);
            _result[1] = _result[1] > _netSupply ? _netSupply : _result[1];
            _result[2] = _supplyResidue;
            return _result;
        }

        // case [3] deleverage using flashloan
        (uint256 _netSupplyAsset, uint256 _debtAsset,) = BaseAAVEStrategy(_strategy).getNetSupplyAndDebt(true);
        uint256 _threshold = applyLeverageMargin(_netSupplyAsset);
        _result = new uint256[](5);
        _result[0] = 3;
        _result[1] = _netSupplyAsset;
        // borrow amount for full deleverage to repay entire debt
        _result[2] = TokenSwapper(BaseAAVEStrategy(_strategy)._swapper()).applySlippageMargin(_debtAsset);
        if (_amountToCollect < _threshold) {
            // borrow amount for partial deleverage to repay a portion of debt
            _result[3] = getMaxLeverage(_amountToCollect);
            _result[3] = _result[3] > _debtAsset ? _result[2] : _result[3];
            (,, uint256 _flFee) = useSparkFlashloan();
            _result[4] = _result[3] == _result[2]
                ? _totalInSupply
                : BaseAAVEStrategy(_strategy)._convertBorrowToSupply(
                    _result[3] + (_result[3] * _flFee / Constants.TOTAL_BPS) + _amountToCollect
                );
        } else {
            _result[3] = _result[2];
            _result[4] = _totalInSupply;
        }
        return _result;
    }

    /**
     * @dev fetch net supply, borrowed debt and total supply amounts in given denomination
     * @param _inAssetDenomination true for result in asset denomination or false in supply token denomination
     */
    function getSupplyAndDebt(bool _inAssetDenomination)
        public
        view
        returns (uint256 _netSupply, uint256 _debt, uint256 _totalSupply)
    {
        (uint256 _cAmount, uint256 _dAmount, uint256 totalCollateralBase, uint256 totalDebtBase) =
            getTotalSupplyAndDebt(_strategy);

        if (_inAssetDenomination) {
            _debt = totalDebtBase > 0 ? BaseAAVEStrategy(_strategy)._convertBorrowToAsset(_dAmount) : 0;
            _totalSupply = totalCollateralBase > 0 ? BaseAAVEStrategy(_strategy)._convertSupplyToAsset(_cAmount) : 0;
            _netSupply = totalCollateralBase > 0 ? (loopingBorrow() ? (_totalSupply - _debt) : _totalSupply) : 0;
        } else {
            _debt = totalDebtBase > 0 ? BaseAAVEStrategy(_strategy)._convertBorrowToSupply(_dAmount) : 0;
            _totalSupply = totalCollateralBase > 0 ? _cAmount : 0;
            _netSupply = totalCollateralBase > 0 ? (loopingBorrow() ? (_cAmount - _debt) : _cAmount) : 0;
        }
    }

    function getMaxRedeemableAmount() public view returns (uint256) {
        (uint256 _margin, uint256 _debtInBorrow) = getAvailableBorrowAmount(_strategy);

        if (_margin == 0) {
            return _margin;
        } else {
            return _debtInBorrow > 0 ? BaseAAVEStrategy(_strategy)._convertBorrowToSupply(_margin) : type(uint256).max;
        }
    }

    function useSparkFlashloan() public view returns (bool, address, uint256) {
        uint256 _aaveFee = aavePool.FLASHLOAN_PREMIUM_TOTAL();
        uint256 _sparkFee = sparkPool.FLASHLOAN_PREMIUM_TOTAL();
        bool _useSpark = _sparkFee < _aaveFee;
        uint256 _minFee = _useSpark ? _sparkFee : _aaveFee;
        address _flProvider = _useSpark ? address(sparkPool) : address(aavePool);
        return (_useSpark, _flProvider, _minFee);
    }

    function _switchToBNBChain() internal {
        // https://docs.kinza.finance/resources/deployed-contracts/bnb-chain
        aavePool = IPool(0xcB0620b181140e57D1C0D8b724cde623cA963c8C);
        aaveOracle = IAaveOracle(0xec203E7676C45455BF8cb43D28F9556F014Ab461);
        // https://aave.com/docs/resources/addresses
        sparkPool = IPool(0x6807dc923806fE8Fd134338EABCA509979a7e0cB);
    }

    function _getReserveLTV(DataTypes.ReserveConfigurationMap memory config) internal pure returns (uint256) {
        // bits 0-15
        return (config.data >> 0) & 0xFFFF;
    }

    function loopingBorrow() public view returns (bool) {
        return BaseAAVEStrategy(_strategy)._loopingBorrow();
    }
}
