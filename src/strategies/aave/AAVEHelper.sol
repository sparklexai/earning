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

contract AAVEHelper is Ownable {
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

    /**
     * @dev leverage ratio in AAVE with looping supply and borrow.
     */
    uint256 public LEVERAGE_RATIO_BPS = 9500;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveOracle aaveOracle = IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    uint8 public immutable _eMode;
    ERC20 public immutable _supplyToken;
    ERC20 public immutable _borrowToken;
    ERC20 public immutable _supplyAToken;
    address public immutable _strategy;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event AAVEHelperCreated(
        address indexed strategy, address indexed supplyToken, address indexed borrowToken, uint8 eMode
    );
    event SupplyToAAVE(address indexed _caller, uint256 _supplied, uint256 _mintedAToken, uint256 _health);
    event BorrowFromAAVE(address indexed _caller, uint256 _borrowed, uint256 _health);
    event RepayDebtInAAVE(address indexed _caller, uint256 _repaidETH, uint256 _health);

    constructor(address strategy, ERC20 supplyToken, ERC20 borrowToken, ERC20 supplyAToken, uint8 eMode)
        Ownable(msg.sender)
    {
        _strategy = strategy;

        supplyToken.approve(address(aavePool), type(uint256).max);
        borrowToken.approve(address(aavePool), type(uint256).max);
        supplyAToken.approve(address(aavePool), type(uint256).max);

        _supplyToken = supplyToken;
        _borrowToken = borrowToken;
        _supplyAToken = supplyAToken;

        // Enable E Mode in AAVE for correlated assets
        require(_checkEMode(eMode), "!invalid emode category");
        aavePool.setUserEMode(eMode);
        _eMode = eMode;

        emit AAVEHelperCreated(_strategy, address(supplyToken), address(borrowToken), _eMode);
    }

    function setLeverageRatio(uint256 _ratio) external onlyOwner {
        if (_ratio > Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        LEVERAGE_RATIO_BPS = _ratio;
    }

    ///////////////////////////////
    // supply/withdraw and borrow/repay within AAVE
    ///////////////////////////////

    function supplyToAAVE(uint256 _supplyAmount) external returns (uint256) {
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
        DataTypes.CollateralConfig memory config = aavePool.getEModeCategoryCollateralConfig(_eMode);
        uint256 _ltv = config.ltv;
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
    function getTotalSupplyAndDebt(address _position) external view returns (uint256, uint256, uint256, uint256) {
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

    function getMaxLeverage(uint256 _amount) public view returns (uint256) {
        uint256 _maxLTV = getMaxLTV();
        return _amount * _maxLTV / (Constants.TOTAL_BPS - _maxLTV);
    }

    function getMaxAllowedDebt(uint256 _supply) external view returns (uint256) {
        return _supply > 0 ? (_supply * getMaxLTV() / Constants.TOTAL_BPS) : 0;
    }

    function _checkEMode(uint8 _mode) internal pure returns (bool) {
        return (_mode == ETH_CATEGORY_AAVE || _mode == USDe_CATEGORY_AAVE || _mode == sUSDe_CATEGORY_AAVE);
    }

    function applyLeverageMargin(uint256 _max) public view returns (uint256) {
        return _max * LEVERAGE_RATIO_BPS / Constants.TOTAL_BPS;
    }

    function getSafeLeveragedSupply(uint256 _initialSupply) public view returns (uint256) {
        return LEVERAGE_RATIO_BPS > 0 ? applyLeverageMargin(getMaxLeverage(_initialSupply)) : _initialSupply;
    }
}
