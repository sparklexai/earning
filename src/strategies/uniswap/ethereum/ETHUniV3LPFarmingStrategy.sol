// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {UniV3LPFarmingStrategy, LPPositionInfo} from "../UniV3LPFarmingStrategy.sol";
import {TokenSwapper} from "../../../utils/TokenSwapper.sol";
import {Constants} from "../../../utils/Constants.sol";

interface IWstETH {
    function getStETHByWstETH(uint256 _share) external view returns (uint256);
}

contract ETHUniV3LPFarmingStrategy is UniV3LPFarmingStrategy {
    using Math for uint256;
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    address public constant wETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    constructor(address vault) UniV3LPFarmingStrategy(ERC20(wETH), vault) {}

    function _valuePairedTokenInAsset(LPPositionInfo calldata _positionInfo, uint256 _pairedTokenAmount)
        internal
        view
        override
        returns (uint256)
    {
        (address _pairedToken, bool _assetIsToken0) = getPairedTokenAddress(_positionInfo.pool);
        if (_positionInfo.assetOracle == Constants.ZRO_ADDR) {
            if (_pairedToken == wstETH) {
                uint256 _stETHEquivalent = IWstETH(wstETH).getStETHByWstETH(_pairedTokenAmount);
                return TokenSwapper(_swapper).convertAmountWithPriceFeed(
                    _positionInfo.otherOracle,
                    _positionInfo.otherOracleHeartbeat,
                    _stETHEquivalent,
                    ERC20(stETH),
                    _asset
                );
            } else {
                // use otherOracle directly
                return TokenSwapper(_swapper).convertAmountWithPriceFeed(
                    _positionInfo.otherOracle,
                    _positionInfo.otherOracleHeartbeat,
                    _pairedTokenAmount,
                    ERC20(_pairedToken),
                    _asset
                );
            }
        } else {
            // use both assetOracle and otherOracle
            return TokenSwapper(_swapper).convertAmountWithFeeds(
                ERC20(_pairedToken),
                _pairedTokenAmount,
                _positionInfo.otherOracle,
                _asset,
                _positionInfo.assetOracle,
                _positionInfo.otherOracleHeartbeat,
                _positionInfo.assetOracleHeartbeat
            );
        }
    }
}
