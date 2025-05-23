// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH} from "../interfaces/IWETH.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {TestUtils} from "./TestUtils.sol";
import {DummyStrategy} from "./mock/DummyStrategy.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path SparkleXVault -vvv
contract SparkleXVaultTest is TestUtils {
    SparkleXVault public stkVault;
    address public stkVOwner;

    // events to check
    event AssetAdded(address indexed _depositor, address indexed _referralCode, uint256 _amount);

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

    function test_DepositWithReferral() public {
        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        vm.stopPrank();

        vm.expectEmit();
        emit AssetAdded(_user, stkVOwner, wETHVal);

        vm.startPrank(_user);
        uint256 _share = stkVault.depositWithReferral(wETHVal, _user, stkVOwner);
        vm.stopPrank();

        uint256 _userShare = stkVault.balanceOf(_user);
        assertEq(_share, _userShare);

        uint256 _totalAssets = stkVault.totalAssets();
        assertEq(wETHVal, _totalAssets);
    }

    function test_Strategy_Add_Remove() public {
        // create the first strategy
        uint256 _alloc1 = 100;
        DummyStrategy myStrategy = new DummyStrategy(wETH, address(stkVault));

        // add the first strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), _alloc1);
        vm.stopPrank();
        assertEq(_alloc1, stkVault.strategyAllocations(address(myStrategy)));

        // create the second strategy
        uint256 _alloc2 = 10;
        DummyStrategy myStrategy2 = new DummyStrategy(wETH, address(stkVault));

        // add the second strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy2), _alloc2);
        vm.stopPrank();
        assertEq(_alloc2, stkVault.strategyAllocations(address(myStrategy2)));

        // remove the second strategy
        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy2));
        vm.stopPrank();
        assertEq(0, stkVault.strategyAllocations(address(myStrategy2)));

        // remove the first strategy
        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy));
        vm.stopPrank();
        assertEq(0, stkVault.strategyAllocations(address(myStrategy)));
    }
}
