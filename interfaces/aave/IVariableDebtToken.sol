// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface IVariableDebtToken {

  /**
   * @notice Delegates borrowing power to a user on the specific debt token.
   * Delegation will still respect the liquidation constraints (even if delegated, a
   * delegatee cannot force a delegator HF to go below 1)
   * @param delegatee The address receiving the delegated borrowing power
   * @param amount The maximum amount being delegated.
   */
  function approveDelegation(address delegatee, uint256 amount) external;

}