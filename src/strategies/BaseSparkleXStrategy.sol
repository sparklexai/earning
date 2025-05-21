// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {Constants} from "../utils/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveRouter} from "../../interfaces/curve/ICurveRouter.sol";
import {ICurvePool} from "../../interfaces/curve/ICurvePool.sol";
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
    ICurveRouter curveRouter = ICurveRouter(0x16C6521Dff6baB339122a0FE25a9116693265353);

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    uint256 SWAP_SLIPPAGE_BPS = 9960;
    ERC20 immutable _asset;
    address immutable _vault;
    address _strategist;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event StrategyCreated(address indexed owner, address indexed vault, address indexed token);
    event SwapInCurve(address indexed inToken, address indexed outToken, uint256 _in, uint256 _out);

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
        _strategist = _newStrategist;
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
        _asset.transfer(_vault, _returned);
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

    ///////////////////////////////
    // Curve swap related: currently support typical 2-token stable pool like weeth<->weth
    // https://docs.curve.fi/router/CurveRouterNG/#_swap_params
    ///////////////////////////////

    /**
     * @dev swap in a curve 2-token pool with expected minimum and best-in-theory output for a given input-output pair.
     */
    function _swapInCurveTwoTokenPool(
        address inToken,
        address outToken,
        address singlePool,
        uint256 _inAmount,
        uint256 _minOut
    ) internal returns (uint256) {
        address[11] memory _route = [
            inToken,
            singlePool,
            outToken,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR
        ];
        // swap_type = 1 (exchange), pool_type = 1 (stable)
        uint256[5] memory _swapParams = [
            _getCurvePoolIndex(singlePool, inToken),
            _getCurvePoolIndex(singlePool, outToken),
            uint256(1),
            uint256(1),
            uint256(2)
        ];
        uint256[5] memory _dummy = [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)];
        uint256[5][5] memory _params = [_swapParams, _dummy, _dummy, _dummy, _dummy];
        address[5] memory _pools =
            [singlePool, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR];

        uint256 _dy = _minOut;
        if (_dy == 0) {
            _dy = curveRouter.get_dy(_route, _params, _inAmount, _pools) * SWAP_SLIPPAGE_BPS / Constants.TOTAL_BPS;
        }

        uint256 _out = curveRouter.exchange(_route, _params, _inAmount, _dy, _pools, address(this));
        emit SwapInCurve(inToken, outToken, _inAmount, _out);
        return _out;
    }

    function _getCurvePoolIndex(address _twoTokenPool, address _token) internal view returns (uint256) {
        if (ICurvePool(_twoTokenPool).coins(0) == _token) {
            return 0;
        } else {
            return 1;
        }
    }

    function _queryXWithYInCurve(address inToken, address outToken, address singlePool, uint256 _minOut)
        internal
        view
        returns (uint256)
    {
        address[11] memory _route = [
            inToken,
            singlePool,
            outToken,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR
        ];
        uint256[5] memory _swapParams = [uint256(1), uint256(0), uint256(1), uint256(1), uint256(2)];
        uint256[5] memory _dummy = [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)];
        uint256[5][5] memory _params = [_swapParams, _dummy, _dummy, _dummy, _dummy];
        address[5] memory _pools =
            [singlePool, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR];
        address[5] memory _dummy_pools =
            [Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR];
        return curveRouter.get_dx(_route, _params, _minOut, _pools, _dummy_pools, _dummy_pools);
    }
}
