// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BaseSparkleXStrategy} from "../BaseSparkleXStrategy.sol";

contract StablePendleStrategy is BaseSparkleXStrategy {
    constructor(
        ERC20 token,
        address vault
    ) BaseSparkleXStrategy(token, vault) {}

    function totalAssets()
        external
        view
        override
        returns (uint256 totalManagedAssets)
    {}

    function assetsInCollection()
        external
        view
        override
        returns (uint256 inCollectionAssets)
    {}

    function allocate(uint256 amount) external override {}

    function collect(uint256 amount) external override {}

    function collectAll() external override {}
}
