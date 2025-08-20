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
     * @dev same logic as https://github.com/Uniswap/v3-periphery/blob/main/contracts/NonfungiblePositionManager.sol/#L330
     */
    function triggerFeeUpdate(address _nftMgr, uint256 tokenId, address _pool) public returns (uint256, uint256) {
        INonfungiblePositionManager.NFTPositionData memory _positionData =
            INonfungiblePositionManager(_nftMgr).positions(tokenId);
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        if (_positionData.liquidity > 0) {
            // trigger an update of the position fees owed and fee growth snapshots if position has any liquidity
            IUniswapV3PoolImmutables(_pool).burn(_positionData.tickLower, _positionData.tickUpper, 0);
            INonfungiblePositionManager.NFTPositionData memory _positionDataNew =
                INonfungiblePositionManager(_nftMgr).positions(tokenId);

            tokensOwed0 += uint128(
                FullMath.mulDiv(
                    _positionDataNew.feeGrowthInside0LastX128 - _positionData.feeGrowthInside0LastX128,
                    _positionData.liquidity,
                    Q128
                )
            );
            tokensOwed1 += uint128(
                FullMath.mulDiv(
                    _positionDataNew.feeGrowthInside1LastX128 - _positionData.feeGrowthInside1LastX128,
                    _positionData.liquidity,
                    Q128
                )
            );
        }
        return (uint256(tokensOwed0), uint256(tokensOwed1));
    }

    /*
     * @dev this method returns uncollected fees owed to the position as of the last computation
     * @dev which might under-estimate the actual accumulated fees.
     * @dev for accurate fee number, use triggerFeeUpdate() instead
     */
    function getLastComputedFees(address _nftMgr, uint256 tokenId) public view returns (uint256, uint256) {
        INonfungiblePositionManager.NFTPositionData memory _positionData =
            INonfungiblePositionManager(_nftMgr).positions(tokenId);
        return (uint256(_positionData.tokensOwed0), uint256(_positionData.tokensOwed1));
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
        } else if (_currentSqrtPX96 >= _pB) {
            uint256 amount1 = FullMath.mulDiv(_positionData.liquidity, (_pB - _pA), Q96);
            return (0, amount1);
        } else {
            uint256 amount0 = FullMath.mulDiv(
                uint256(_positionData.liquidity) << q96_RESOLUTION, (_pB - _currentSqrtPX96), _pB
            ) / _currentSqrtPX96;
            uint256 amount1 = FullMath.mulDiv(_positionData.liquidity, (_currentSqrtPX96 - _pA), Q96);
            return (amount0, amount1);
        }
    }
}
