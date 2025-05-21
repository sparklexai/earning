// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH} from "../interfaces/IWETH.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";

contract TestUtils is Test {
    address payable constant wETH = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));
    uint256 constant wETHVal = 10000 ether;
    uint256 constant COMP_TOLERANCE = 10000;
    uint256 constant BIGGER_TOLERANCE = 3 * 1e16;

    function _getSugarUser() internal returns (address payable) {
        address payable _user = _getNextUserAddress();
        vm.deal(_user, 1000000 ether);

        vm.startPrank(_user);
        WETH(wETH).deposit{value: wETHVal}();
        vm.stopPrank();

        uint256 _asset = ERC20(wETH).balanceOf(_user);
        assertEq(_asset, wETHVal);

        return _user;
    }

    function _getNextUserAddress() internal returns (address payable) {
        address payable _user = payable(address(uint160(uint256(nextUser))));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return _user;
    }

    function _assertApproximateEq(uint256 _num1, uint256 _num2, uint256 _tolerance) internal pure returns (bool) {
        if (_num1 > _num2) {
            return _tolerance >= (_num1 - _num2);
        } else {
            return _tolerance >= (_num2 - _num1);
        }
    }

    function _applyFlashLoanFeeFromAAVE(uint256 _amt) internal pure returns (uint256) {
        return _amt * 5 / 10000;
    }

    function _makeRedemptionRequest(address _user, uint256 _share, address _vault) internal returns (uint256) {
        vm.startPrank(_user);
        ERC20(_vault).approve(_vault, type(uint256).max);
        uint256 _asset = SparkleXVault(_vault).requestRedemption(_share);
        vm.stopPrank();
        return _asset;
    }

    function _claimRedemptionRequest(address _user, uint256 _share, address _vault, uint256 _tolerance)
        internal
        returns (uint256 _actualRedeemed)
    {
        uint256 _worthForRequestedShare =
            SparkleXVault(_vault).previewRedeem(SparkleXVault(_vault).userRedemptionRequestShares(_user));
        console.log(
            "_currentWorthForRequested:%d,_totalAssets:%d", _worthForRequestedShare, SparkleXVault(_vault).totalAssets()
        );

        uint256 _currentWorth = SparkleXVault(_vault).previewRedeem(_share);
        uint256 _requestedAsset = SparkleXVault(_vault).userRedemptionRequestAssets(_user);
        uint256 _less = _requestedAsset > _currentWorth ? _currentWorth : _requestedAsset;
        vm.startPrank(_user);
        _actualRedeemed = SparkleXVault(_vault).claimRedemptionRequest();
        vm.stopPrank();

        assertTrue(_assertApproximateEq(_less, _actualRedeemed, _tolerance));
    }
}
