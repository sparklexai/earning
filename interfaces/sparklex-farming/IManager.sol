// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface IManager {
    function userVaults(address) external view returns (address);

    function createUserVault(address _agent) external;

    function work(address _vaultAddr, uint256 _positionID, address _strategy, bytes calldata _data) external;
}
