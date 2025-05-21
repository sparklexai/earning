// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface ICurvePool {

  function coins(uint256 i) external view returns(address);

}