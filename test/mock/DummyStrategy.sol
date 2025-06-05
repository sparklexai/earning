// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DummyStrategy {
    uint256 _totalAssets;
    uint256 _assetsInCollection;
    address _asset;
    address _vault;
    address _strategist;

    constructor(address assetAddr, address vaultAddr) {
        _asset = assetAddr;
        _vault = vaultAddr;
    }

    function setTotalAssets(uint256 amount) external {
        _totalAssets = amount;
    }

    function setAssetsInCollection(uint256 amount) external {
        _assetsInCollection = amount;
    }

    function setStrategist(address strategistAddr) external {
        _strategist = strategistAddr;
    }

    function asset() external view returns (address assetTokenAddress) {
        return _asset;
    }

    function vault() external view returns (address vaultAddress) {
        return _vault;
    }

    function totalAssets() external view returns (uint256 totalManagedAssets) {
        return _totalAssets > 0 ? _totalAssets : ERC20(_asset).balanceOf(address(this));
    }

    function assetsInCollection() external view returns (uint256 inCollectionAssets) {
        return _assetsInCollection;
    }

    function allocate(uint256 amount) external {
        ERC20(_asset).transferFrom(_vault, address(this), amount);
    }

    function collect(uint256 amount) external {
        ERC20(_asset).transferFrom(address(this), _vault, amount);
    }

    function collectAll() external {
        ERC20(_asset).transferFrom(address(this), _vault, ERC20(_asset).balanceOf(address(this)));
    }

    function strategist() external view returns (address strategist) {
        return _strategist;
    }
}
