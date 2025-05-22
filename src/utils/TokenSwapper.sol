// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveRouter} from "../../interfaces/curve/ICurveRouter.sol";
import {ICurvePool} from "../../interfaces/curve/ICurvePool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Constants} from "./Constants.sol";

contract TokenSwapper {
    using Math for uint256;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    ICurveRouter curveRouter = ICurveRouter(0x16C6521Dff6baB339122a0FE25a9116693265353);

    ///////////////////////////////
    // events
    ///////////////////////////////
    event SwapInCurve(address indexed inToken, address indexed outToken, address _receiver, uint256 _in, uint256 _out);

    constructor() {}

    function _approveTokenToDex(address _token, address _dex) internal {
        if (ERC20(_token).allowance(address(this), _dex) == 0) {
            ERC20(_token).approve(_dex, type(uint256).max);
        }
    }

    ///////////////////////////////
    // Curve swap related: currently support typical 2-token stable pool like weeth<->weth
    // https://docs.curve.fi/router/CurveRouterNG/#_swap_params
    ///////////////////////////////

    /**
     * @dev swap in a curve 2-token pool with expected minimum and best-in-theory output for a given input-output pair.
     */
    function swapInCurveTwoTokenPool(
        address inToken,
        address outToken,
        address singlePool,
        uint256 _inAmount,
        uint256 _minOut,
        uint256 _slippageAllowed
    ) external returns (uint256) {
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
            _dy = curveRouter.get_dy(_route, _params, _inAmount, _pools) * _slippageAllowed / Constants.TOTAL_BPS;
        }

        ERC20(inToken).transferFrom(msg.sender, address(this), _inAmount);
        _approveTokenToDex(inToken, address(curveRouter));
        uint256 _out = curveRouter.exchange(_route, _params, _inAmount, _dy, _pools, msg.sender);
        emit SwapInCurve(inToken, outToken, msg.sender, _inAmount, _out);
        return _out;
    }

    function _getCurvePoolIndex(address _twoTokenPool, address _token) internal view returns (uint256) {
        if (ICurvePool(_twoTokenPool).coins(0) == _token) {
            return 0;
        } else {
            return 1;
        }
    }

    function queryXWithYInCurve(address inToken, address outToken, address singlePool, uint256 _minOut)
        external
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
