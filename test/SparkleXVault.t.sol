// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH} from "../interfaces/IWETH.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {Constants} from "../src/utils/Constants.sol";
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
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);
    }

    function test_Basic_Deposit_And_Withdraw() public {
        uint256 _generousAsset = _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _share = stkVault.deposit(wETHVal, _user);
        vm.stopPrank();

        uint256 _userShare = stkVault.balanceOf(_user);
        assertEq(_share, _userShare);

        uint256 _totalAssets = stkVault.totalAssets();
        assertEq(wETHVal + _generousAsset, _totalAssets);

        uint256 _redeemed = TestUtils._makeRedemptionRequest(_user, _userShare, address(stkVault));

        _userShare = stkVault.balanceOf(_user);
        assertEq(0, _userShare);

        _totalAssets = stkVault.totalAssets();
        assertEq(_generousAsset, _totalAssets);

        assertEq(wETHVal, _redeemed);
    }

    function test_Withdraw_Fee() public {
        uint256 _generousAsset = _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _share = stkVault.deposit(wETHVal, _user);
        vm.stopPrank();
        uint256 _userShare = stkVault.balanceOf(_user);

        uint256 _feeBps = 1000;
        _changeWithdrawFee(stkVOwner, address(stkVault), _feeBps);

        address payable _feeRecipient = _getNextUserAddress();
        vm.startPrank(stkVOwner);
        SparkleXVault(stkVault).setFeeRecipient(_feeRecipient);
        vm.stopPrank();
        assertEq(_feeRecipient, stkVault.getFeeRecipient());

        uint256 _redeemed = TestUtils._makeRedemptionRequest(_user, _userShare, address(stkVault));

        _userShare = stkVault.balanceOf(_user);
        assertEq(0, _userShare);

        assertEq(wETHVal * (Constants.TOTAL_BPS - _feeBps) / Constants.TOTAL_BPS, _redeemed);
        assertEq(wETHVal * _feeBps / Constants.TOTAL_BPS, ERC20(wETH).balanceOf(_feeRecipient));
    }

    function test_Deposit_Inflation() public {
        address _user = TestUtils._getSugarUser();
        address _attacker = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(_attacker);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        vm.stopPrank();

        uint256 _attackShare = 1 ether;
        vm.startPrank(_attacker);
        stkVault.deposit(_attackShare, _attacker);
        ERC20(wETH).transfer(address(stkVault), wETHVal - _attackShare);
        vm.stopPrank();
        assertEq(_attackShare - MIN_SHARE, stkVault.balanceOf(_attacker));

        uint256 _victimAmt = wETHVal * 990 / 1000;
        vm.startPrank(_user);
        uint256 _victimShare = stkVault.deposit(_victimAmt, _user);
        vm.stopPrank();

        assertTrue(_victimShare > 1);
        assertEq(_victimShare, stkVault.balanceOf(_user));

        uint256 _redeemed = TestUtils._makeRedemptionRequest(_user, _victimShare, address(stkVault));

        assertEq(0, stkVault.balanceOf(_user));
        console.log("_redeemed:%d,_victimAmt:%d", _redeemed, _victimAmt);
        assertTrue(_assertApproximateEq(_redeemed, _victimAmt, BIGGER_TOLERANCE));
    }

    function test_DepositWithReferral() public {
        uint256 _generousAsset = _fundFirstDepositGenerously(address(stkVault));

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
        assertEq(wETHVal + _generousAsset, _totalAssets);
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
