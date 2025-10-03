// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {FullMath} from "./FullMath.sol";
import {TickMath} from "./TickMath.sol";
import {INonfungiblePositionManager} from "../../../interfaces/uniswap/INonfungiblePositionManager.sol";
import {IUniswapV3PoolImmutables} from "../../../interfaces/uniswap/IUniswapV3PoolImmutables.sol";

library UniV3PositionMath {
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint8 internal constant q96_RESOLUTION = 96;

    /*
     * @dev this method returns latest uncollected fees owed to the position
     */
    function getLatestFees(address _nftMgr, address _pool, uint256 tokenId) public view returns (uint256, uint256) {
        INonfungiblePositionManager.NFTPositionData memory _positionData =
            INonfungiblePositionManager(_nftMgr).positions(tokenId);

        (uint256 _token0FeeLatest, uint256 _token1FeeLatest) = _calculateLatestFeeForPos(
            IUniswapV3PoolImmutables(_pool),
            _positionData.tickLower,
            _positionData.tickUpper,
            _positionData.liquidity,
            _positionData.feeGrowthInside0LastX128,
            _positionData.feeGrowthInside1LastX128
        );
        return (
            uint256(_positionData.tokensOwed0) + _token0FeeLatest, uint256(_positionData.tokensOwed1) + _token1FeeLatest
        );
    }

    // referece https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/PositionValue.sol#L111
    function _calculateLatestFeeForPos(
        IUniswapV3PoolImmutables pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 lastPositionFeeGrowthInside0LastX128,
        uint256 lastPositionFeeGrowthInside1LastX128
    ) private view returns (uint256 amount0, uint256 amount1) {
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = _getFeeGrowthInside(pool, tickLower, tickUpper);

        if (feeGrowthInside0X128 > lastPositionFeeGrowthInside0LastX128) {
            amount0 = FullMath.mulDiv(
                feeGrowthInside0X128 - lastPositionFeeGrowthInside0LastX128, uint256(liquidity), UniV3PositionMath.Q128
            );
        }

        if (feeGrowthInside1X128 > lastPositionFeeGrowthInside1LastX128) {
            amount1 = FullMath.mulDiv(
                feeGrowthInside1X128 - lastPositionFeeGrowthInside1LastX128, uint256(liquidity), UniV3PositionMath.Q128
            );
        }

        return (amount0, amount1);
    }

    function _getFeeGrowthInside(IUniswapV3PoolImmutables pool, int24 tickLower, int24 tickUpper)
        private
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent,,,,,) = pool.slot0();
        (,, uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128,,,,) = pool.ticks(tickLower);
        (,, uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128,,,,) = pool.ticks(tickUpper);

        if (tickCurrent < tickLower) {
            feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
        } else if (tickCurrent < tickUpper) {
            uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();

            uint256 _toMiusInside0 = lowerFeeGrowthOutside0X128 + upperFeeGrowthOutside0X128;
            if (feeGrowthGlobal0X128 > _toMiusInside0) {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - _toMiusInside0;
            } else {
                feeGrowthInside0X128 = 0;
            }

            uint256 _toMiusInside1 = lowerFeeGrowthOutside1X128 + upperFeeGrowthOutside1X128;
            if (feeGrowthGlobal1X128 > _toMiusInside1) {
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - _toMiusInside1;
            } else {
                feeGrowthInside1X128 = 0;
            }
        } else {
            feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
        }
    }

    /* 
     * @dev Computes the token0 and token1 value for a given position
     * @param _currentSqrtPX96 A sqrt price representing the current pool prices
     * @dev similar to https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/LiquidityAmounts.sol#L120
     */
    function getAmountsForPosition(address _nftMgr, uint256 tokenId, uint160 _currentSqrtPX96)
        public
        view
        returns (uint256, uint256)
    {
        INonfungiblePositionManager.NFTPositionData memory _positionData =
            INonfungiblePositionManager(_nftMgr).positions(tokenId);
        uint160 _pA = TickMath.getSqrtRatioAtTick(_positionData.tickLower);
        uint160 _pB = TickMath.getSqrtRatioAtTick(_positionData.tickUpper);
        if (_currentSqrtPX96 <= _pA) {
            uint256 amount0 =
                FullMath.mulDiv(uint256(_positionData.liquidity) << q96_RESOLUTION, (_pB - _pA), _pB) / _pA;
            return (amount0, 0);
        } else if (_currentSqrtPX96 < _pB) {
            uint256 amount0 = FullMath.mulDiv(
                uint256(_positionData.liquidity) << q96_RESOLUTION, (_pB - _currentSqrtPX96), _pB
            ) / _currentSqrtPX96;
            uint256 amount1 = FullMath.mulDiv(_positionData.liquidity, (_currentSqrtPX96 - _pA), Q96);
            return (amount0, amount1);
        } else {
            uint256 amount1 = FullMath.mulDiv(_positionData.liquidity, (_pB - _pA), Q96);
            return (0, amount1);
        }
    }
}
