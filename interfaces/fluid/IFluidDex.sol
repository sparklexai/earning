// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface IFluidDex {
    function swapIn(bool swap0to1_, uint256 amountIn_, uint256 amountOutMin_, address to_)
        external
        returns (uint256 amountOut_);
}
