// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface ICurvePool {
    function coins(uint256 i) external view returns (address);

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
}
