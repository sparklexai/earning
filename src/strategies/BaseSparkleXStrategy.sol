// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {Constants} from "../utils/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenSwapper} from "../utils/TokenSwapper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ISparkleXVault {
    function getAllocationAvailableForStrategy(address _strategyAddr) external view returns (uint256);
}

abstract contract BaseSparkleXStrategy is IStrategy, Ownable {
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
    uint256 SWAP_SLIPPAGE_BPS = 9960;
    ERC20 immutable _asset;
    address immutable _vault;
    address _strategist;
    address _swapper;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event StrategyCreated(address indexed owner, address indexed vault, address indexed token);
    event StrategistChanged(address indexed _old, address indexed _new);
    event SwapperChanged(address indexed _old, address indexed _new);

    constructor(ERC20 token, address vaultAddr) Ownable(msg.sender) {
        require(address(token) != Constants.ZRO_ADDR, "!invalid asset");
        require(vaultAddr != Constants.ZRO_ADDR, "!invalid vault");

        _asset = token;
        _vault = vaultAddr;
        _strategist = msg.sender;

        emit StrategyCreated(msg.sender, _vault, address(token));
    }

    /**
     * @dev allow only called by strategist.
     */
    modifier onlyStrategist() {
        require(msg.sender == _strategist, "!not strategist");
        _;
    }

    /**
     * @dev allow only called by strategist.
     */
    modifier onlyStrategistOrVault() {
        require(msg.sender == _strategist || msg.sender == _vault, "!not strategist nor vault");
        _;
    }

    ///////////////////////////////
    // base methods
    ///////////////////////////////

    function setStrategist(address _newStrategist) external onlyOwner {
        require(_newStrategist != Constants.ZRO_ADDR, "!invalid strategist");
        emit StrategistChanged(_strategist, _newStrategist);
        _strategist = _newStrategist;
    }

    function setSwapper(address _newSwapper) external onlyStrategist {
        require(_newSwapper != Constants.ZRO_ADDR, "!invalid token swapper");
        emit SwapperChanged(_swapper, _newSwapper);
        _swapper = _newSwapper;
    }

    function setSlippage(uint256 _slippage) external onlyStrategist {
        require(_slippage > 0 && _slippage < Constants.TOTAL_BPS, "!invalid slippage");
        SWAP_SLIPPAGE_BPS = _slippage;
    }

    function strategist() external view virtual returns (address) {
        return _strategist;
    }

    function asset() external view virtual returns (address) {
        return address(_asset);
    }

    function vault() external view virtual returns (address) {
        return _vault;
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _returnAssetToVault(uint256 amount) internal returns (uint256) {
        uint256 _returned = _capAmountByBalance(_asset, amount, false);
        if (_returned > 0) {
            _asset.transfer(_vault, _returned);
        }
        return _returned;
    }

    function _capAllocationAmount(uint256 _amount) internal returns (uint256) {
        uint256 _maxAllocation = ISparkleXVault(_vault).getAllocationAvailableForStrategy(address(this));
        return _amount > _maxAllocation ? _maxAllocation : _amount;
    }

    function _applySlippageMargin(uint256 _theory) internal view returns (uint256) {
        return _theory * Constants.TOTAL_BPS / SWAP_SLIPPAGE_BPS;
    }

    function _capAmountByBalance(ERC20 _token, uint256 _amount, bool _applyMargin) internal view returns (uint256) {
        uint256 _expected = _applyMargin ? _applySlippageMargin(_amount) : _amount;
        uint256 _balance = _token.balanceOf(address(this));
        return _balance > _expected ? _expected : _balance;
    }

    function _approveToken(address _token, address _spender) internal {
        if (ERC20(_token).allowance(address(this), _spender) == 0) {
            ERC20(_token).approve(_spender, type(uint256).max);
        }
    }
}
