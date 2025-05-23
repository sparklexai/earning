// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

contract DummyStrategy {
    uint256 _totalAssets;
    uint256 _assetsInCollection;
    address _asset;
    address _vault;
    address _strategist;

    constructor(address asset, address vault) {
        _asset = asset;
        _vault = vault;
    }

    function setTotalAssets(uint256 amount) external {
        _totalAssets = amount;
    }

    function setAssetsInCollection(uint256 amount) external {
        _assetsInCollection = amount;
    }

    function setStrategist(address strategist) external {
        _strategist = strategist;
    }

    function asset() external view returns (address assetTokenAddress) {
        return _asset;
    }

    function vault() external view returns (address vaultAddress) {
        return _vault;
    }

    function totalAssets() external view returns (uint256 totalManagedAssets) {
        return _totalAssets;
    }

    function assetsInCollection() external view returns (uint256 inCollectionAssets) {
        return _assetsInCollection;
    }

    function allocate(uint256 amount) external {}

    function collect(uint256 amount) external {}

    function collectAll() external {}

    function strategist() external view returns (address strategist) {
        return _strategist;
    }
}
