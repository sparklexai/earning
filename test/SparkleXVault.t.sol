// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
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

        assertEq(
            ERC20(wETH).balanceOf(address(stkVault)) * stkVault.EARN_RATIO_BPS() / Constants.TOTAL_BPS,
            stkVault.getAllocationAvailable()
        );
        _checkBasicInvariants(address(stkVault));

        uint256 _redeemed = TestUtils._makeRedemptionRequest(_user, _userShare, address(stkVault));

        _userShare = stkVault.balanceOf(_user);
        assertEq(0, _userShare);

        _totalAssets = stkVault.totalAssets();
        assertEq(_generousAsset, _totalAssets);

        assertEq(wETHVal, _redeemed);
    }

    function test_Withdraw_Fee(uint256 _feeBps) public {
        uint256 _generousAsset = _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();
        uint256 _testVal = wETHVal / 3;

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _share = stkVault.deposit(_testVal, _user);
        vm.stopPrank();
        uint256 _userShare = stkVault.balanceOf(_user);

        _feeBps = bound(_feeBps, 100, 1000);
        _changeWithdrawFee(stkVOwner, address(stkVault), _feeBps);

        address payable _feeRecipient = _getNextUserAddress();
        vm.startPrank(stkVOwner);
        stkVault.setFeeRecipient(_feeRecipient);
        vm.stopPrank();
        assertEq(_feeRecipient, stkVault.getFeeRecipient());

        uint256 _redeemed = TestUtils._makeRedemptionRequest(_user, _userShare, address(stkVault));

        _userShare = stkVault.balanceOf(_user);
        assertEq(0, _userShare);

        assertTrue(
            _assertApproximateEq(
                _testVal * (Constants.TOTAL_BPS - _feeBps) / Constants.TOTAL_BPS, _redeemed, COMP_TOLERANCE
            )
        );
        uint256 _feeExpected = _testVal * _feeBps / Constants.TOTAL_BPS;
        assertTrue(_assertApproximateEq(_feeExpected, ERC20(wETH).balanceOf(_feeRecipient), COMP_TOLERANCE));

        vm.startPrank(_user);
        _share = stkVault.deposit(_testVal, _user);
        vm.stopPrank();

        DummyStrategy myStrategy1 = new DummyStrategy(wETH, address(stkVault));
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy1), 100);
        vm.stopPrank();

        // ensure that user pay withdraw fee during request claim
        vm.startPrank(stkVOwner);
        myStrategy1.allocate(stkVault.getAllocationAvailableForStrategy(address(myStrategy1)));
        vm.stopPrank();
        TestUtils._makeRedemptionRequest(_user, _share, address(stkVault));
        assertEq(stkVault.userRedemptionRequestShares(_user), _share);
        vm.startPrank(stkVOwner);
        myStrategy1.collectAll();
        vm.stopPrank();
        vm.startPrank(_user);
        stkVault.claimRedemptionRequest();
        vm.stopPrank();
        assertTrue(_assertApproximateEq(_feeExpected * 2, ERC20(wETH).balanceOf(_feeRecipient), COMP_TOLERANCE));
    }

    function test_Basic_ManagementFee(uint256 _feeBps) public {
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

        // accumulate fee
        _feeBps = bound(_feeBps, 100, 1000);

        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(stkVOwner);
        stkVault.setWithdrawFeeRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        vm.startPrank(stkVOwner);
        stkVault.setManagementFeeRatio(_feeBps);
        vm.stopPrank();
        assertEq(_feeBps, stkVault.MANAGEMENT_FEE_BPS());

        uint256 _currentTime = block.timestamp;
        uint256 _timeElapsed = Constants.ONE_YEAR / 12;
        uint256 _targetTime = _currentTime + _timeElapsed;
        vm.warp(_targetTime);

        (,, uint256 _ts0) = stkVault.mgmtFee();
        vm.startPrank(stkVOwner);
        stkVault.accumulateManagementFee();
        vm.stopPrank();

        (uint256 _fee, uint256 _supply, uint256 _ts) = stkVault.mgmtFee();
        uint256 _expectedFee = (_totalAssets * (_targetTime - _ts0) * stkVault.MANAGEMENT_FEE_BPS())
            / (Constants.TOTAL_BPS * Constants.ONE_YEAR);
        console.log("_fee:%d,_supply:%d,_ts:%d", _fee, _supply, _ts);
        assertEq(_ts, _targetTime);
        assertEq(_supply, _totalAssets);
        assertTrue(_assertApproximateEq(_fee, _expectedFee, BIGGER_TOLERANCE));

        // accumulate fee again
        _currentTime = block.timestamp;
        _targetTime = _currentTime + _timeElapsed;
        vm.warp(_targetTime);

        vm.startPrank(stkVOwner);
        stkVault.accumulateManagementFee();
        vm.stopPrank();

        (uint256 _fee2,,) = stkVault.mgmtFee();
        uint256 _expectedFee2 = _fee
            + (_totalAssets * (_targetTime - _ts) * stkVault.MANAGEMENT_FEE_BPS())
                / (Constants.TOTAL_BPS * Constants.ONE_YEAR);
        console.log("_fee2:%d", _fee2);
        assertTrue(_assertApproximateEq(_fee2, _expectedFee2, BIGGER_TOLERANCE));

        vm.expectRevert(Constants.ONLY_FOR_CLAIMER_OR_OWNER.selector);
        vm.startPrank(_user);
        stkVault.claimManagementFee();
        vm.stopPrank();

        address payable _feeRecipient = _getNextUserAddress();
        vm.startPrank(stkVOwner);
        stkVault.setFeeRecipient(_feeRecipient);
        stkVault.claimManagementFee();
        vm.stopPrank();
        assertEq(_fee2, ERC20(wETH).balanceOf(_feeRecipient));

        (uint256 _fee3,,) = stkVault.mgmtFee();
        assertEq(_fee3, 0);
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

    function test_Strategy_Add_Remove(uint256 _testVal) public {
        // create the first strategy
        uint256 _alloc1 = 100;
        DummyStrategy myStrategy = new DummyStrategy(wETH, address(stkVault));

        // add the first strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), _alloc1);
        vm.stopPrank();
        assertEq(_alloc1, stkVault.strategyAllocations(address(myStrategy)));

        assertEq(address(myStrategy), stkVault.allStrategies(0));

        // can't add again
        vm.expectRevert(Constants.WRONG_STRATEGY_TO_ADD.selector);
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), _alloc1);
        vm.stopPrank();

        _fundFirstDepositGenerously(address(stkVault));

        // ensure that user can't claim withdraw request if not enough asset in vault
        address _user = TestUtils._getSugarUser();
        (uint256 _assetVal, uint256 _share) =
            TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 2 ether, 100 ether);
        _testVal = _assetVal;
        vm.startPrank(stkVOwner);
        myStrategy.allocate(stkVault.getAllocationAvailableForStrategy(address(myStrategy)));
        TestUtils._makeRedemptionRequest(_user, _share, address(stkVault));
        assertEq(_share, stkVault.userRedemptionRequestShares(_user));
        vm.expectRevert(Constants.LESS_REDEMPTION_TO_USER.selector);
        vm.startPrank(_user);
        stkVault.claimRedemptionRequest();
        vm.stopPrank();

        // create the second strategy
        uint256 _alloc2 = 10;
        DummyStrategy myStrategy2 = new DummyStrategy(wETH, address(stkVault));

        // add the second strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy2), _alloc2);
        vm.stopPrank();
        assertEq(_alloc2, stkVault.strategyAllocations(address(myStrategy2)));

        assertEq(address(myStrategy2), stkVault.allStrategies(1));

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
        assertEq(0, stkVault.getAllocationAvailableForStrategy(address(myStrategy)));
    }

    function test_Basic_Timelock_Owner() public {
        address _proposer = TestUtils._getSugarUser();
        address[] memory _proposers = new address[](1);
        _proposers[0] = _proposer;

        address _executor = TestUtils._getSugarUser();
        address[] memory _executors = new address[](1);
        _executors[0] = _executor;

        uint256 _minDelaySeconds = 600;
        TimelockController timelocker =
            new TimelockController(_minDelaySeconds, _proposers, _executors, Constants.ZRO_ADDR);

        vm.startPrank(stkVOwner);
        stkVault.transferOwnership(address(timelocker));
        vm.stopPrank();
        assertEq(address(timelocker), stkVault.owner());

        uint256 _newWithdrawFee = 365;
        bytes memory _setWithdrawFeeCall = abi.encodeWithSignature("setWithdrawFeeRatio(uint256)", _newWithdrawFee);

        bytes32 _id = timelocker.hashOperation(address(stkVault), 0, _setWithdrawFeeCall, bytes32(0), bytes32(0));
        vm.startPrank(_proposer);
        timelocker.schedule(address(stkVault), 0, _setWithdrawFeeCall, bytes32(0), bytes32(0), _minDelaySeconds);
        vm.stopPrank();
        assertTrue(timelocker.isOperationPending(_id));
        assertFalse(timelocker.isOperationReady(_id));

        vm.warp(block.timestamp + _minDelaySeconds * 2);
        assertTrue(timelocker.isOperationReady(_id));
        vm.startPrank(_executor);
        timelocker.execute(address(stkVault), 0, _setWithdrawFeeCall, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertEq(_newWithdrawFee, stkVault.WITHDRAW_FEE_BPS());
        assertTrue(timelocker.isOperationDone(_id));
    }
}
