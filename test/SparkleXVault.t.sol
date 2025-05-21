// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH} from "../interfaces/IWETH.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {TestUtils} from "./TestUtils.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path SparkleXVault -vvv
contract SparkleXVaultTest is TestUtils {
    SparkleXVault public stkVault;
    address public stkVOwner;

    function setUp() public {
        stkVault = new SparkleXVault(ERC20(wETH), "SparkleX-ETH-Vault", "SPX-ETH-V");
        stkVOwner = stkVault.owner();
    }

    function test_Basic_Deposit_And_Withdraw() public {
        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _share = stkVault.deposit(wETHVal, _user);
        vm.stopPrank();

        uint256 _userShare = stkVault.balanceOf(_user);
        assertEq(_share, _userShare);

        uint256 _totalAssets = stkVault.totalAssets();
        assertEq(wETHVal, _totalAssets);

        uint256 _redeemed = TestUtils._makeRedemptionRequest(_user, _userShare, address(stkVault));

        _userShare = stkVault.balanceOf(_user);
        assertEq(0, _userShare);

        _totalAssets = stkVault.totalAssets();
        assertEq(0, _totalAssets);

        assertEq(wETHVal, _redeemed);
    }
}
