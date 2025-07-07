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
import {DummyPendleAAVEStrategy} from "./mock/DummyPendleAAVEStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path SparkleXVault -vvv
contract SparkleXVaultTest is TestUtils {
    SparkleXVault public stkVault;
    address public stkVOwner;

    // events to check
    event AssetAdded(address indexed _depositor, address indexed _referralCode, uint256 _amount);
    event ManagementFeeUpdated(uint256 _addedFee, uint256 _newTotalAssets, uint256 _newTimestamp, uint256 _feeBps);

    function setUp() public {
        stkVault = new SparkleXVault(ERC20(wETH), "SparkleX-ETH-Vault", "SPX-ETH-V");
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);
    }

    function test_Basic_Deposit_And_Withdraw() public {
        uint256 _generousAsset = _fundFirstDepositGenerously(address(stkVault));

        uint256 _tinyDust = 1;
        vm.startPrank(TestUtils._getSugarUser());
        ERC20(wETH).transfer(address(stkVault), _tinyDust);
        vm.stopPrank();
        assertTrue(stkVault.totalSupply() < stkVault.totalAssets());

        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        vm.stopPrank();

        vm.expectRevert(Constants.ZERO_SHARE_TO_MINT.selector);
        vm.startPrank(_user);
        stkVault.deposit(1, _user);
        vm.stopPrank();

        vm.startPrank(_user);
        uint256 _share = stkVault.deposit(wETHVal, _user);
        vm.stopPrank();

        uint256 _userShare = stkVault.balanceOf(_user);
        assertEq(_share, _userShare);

        uint256 _totalAssets = stkVault.totalAssets();
        assertEq(wETHVal + _generousAsset + _tinyDust, _totalAssets);

        assertEq(
            ERC20(wETH).balanceOf(address(stkVault)) * stkVault.EARN_RATIO_BPS() / Constants.TOTAL_BPS,
            stkVault.getAllocationAvailable()
        );
        _checkBasicInvariants(address(stkVault));

        uint256 _redeemed = TestUtils._makeRedemptionRequest(_user, _userShare, address(stkVault));

        _userShare = stkVault.balanceOf(_user);
        assertEq(0, _userShare);

        _totalAssets = stkVault.totalAssets();
        assertEq(_generousAsset + _tinyDust * 2, _totalAssets);

        assertEq(wETHVal - _tinyDust, _redeemed);
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

        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        new DummyPendleAAVEStrategy(Constants.ZRO_ADDR);

        DummyStrategy myStrategy1 = new DummyStrategy(wETH, address(stkVault));
        vm.startPrank(stkVOwner);
        stkVault.setEarnRatio(Constants.TOTAL_BPS);
        stkVault.addStrategy(address(myStrategy1), MAX_ETH_ALLOWED);
        vm.stopPrank();

        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(stkVOwner);
        stkVault.setEarnRatio(Constants.TOTAL_BPS + 1);
        vm.stopPrank();

        // ensure that user pay withdraw fee during request claim
        bytes memory EMPTY_CALLDATA;
        uint256 _availableForStrategy = stkVault.getAllocationAvailableForStrategy(address(myStrategy1));
        assertEq(_availableForStrategy, stkVault.totalAssets());
        vm.startPrank(stkVOwner);
        myStrategy1.allocate(_availableForStrategy, EMPTY_CALLDATA);
        vm.stopPrank();
        uint256 _residueShare = 123456789;
        TestUtils._makeRedemptionRequest(_user, _share - _residueShare, address(stkVault));
        assertEq(stkVault.userRedemptionRequestShares(_user), _share - _residueShare);

        vm.expectRevert(Constants.USER_REDEMPTION_NOT_CLAIMED.selector);
        vm.startPrank(_user);
        stkVault.requestRedemption(_residueShare);
        vm.stopPrank();

        vm.startPrank(stkVOwner);
        myStrategy1.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();
        vm.startPrank(_user);
        stkVault.claimRedemptionRequest();
        vm.stopPrank();
        uint256 _balInRecipient = ERC20(wETH).balanceOf(_feeRecipient);
        console.log("_fee2:%d,_balRecipient:%d", _feeExpected * 2, _balInRecipient);
        assertTrue(_assertApproximateEq(_feeExpected * 2, _balInRecipient, BIGGER_TOLERANCE));

        _changeWithdrawFee(stkVOwner, address(stkVault), 0);
        assertEq(0, stkVault.WITHDRAW_FEE_BPS());

        _balInRecipient = ERC20(wETH).balanceOf(_feeRecipient);
        _redeemed = TestUtils._makeRedemptionRequest(_user, _residueShare, address(stkVault));
        assertEq(_balInRecipient, ERC20(wETH).balanceOf(_feeRecipient));
        assertEq(_redeemed, _residueShare);
    }

    function test_Basic_ManagementFee(uint256 _feeBps) public {
        uint256 _generousAsset = _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _share = stkVault.deposit(wETHVal, _user);
        vm.stopPrank();
        assertEq(_share, stkVault.balanceOf(_user));

        uint256 _totalAssets = stkVault.totalAssets();
        assertEq(wETHVal + _generousAsset, _totalAssets);

        // accumulate fee
        _feeBps = bound(_feeBps, 100, 1000);

        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(stkVOwner);
        stkVault.setWithdrawFeeRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(stkVOwner);
        stkVault.setManagementFeeRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        uint256 _tsEmitted = block.timestamp;
        (uint256 _feeAccumulated,) = stkVault.previewManagementFeeAccumulated(_totalAssets, _tsEmitted);

        vm.expectEmit();
        emit ManagementFeeUpdated(_feeAccumulated, _totalAssets, _tsEmitted, 200);

        vm.startPrank(stkVOwner);
        stkVault.setManagementFeeRatio(_feeBps);
        vm.stopPrank();
        (uint256 _fee, uint256 _supply, uint256 _ts) = stkVault.mgmtFee();
        assertEq(_feeBps, stkVault.MANAGEMENT_FEE_BPS());
        assertEq(_feeAccumulated, _fee);

        uint256 _timeElapsed = Constants.ONE_YEAR / 12;
        uint256 _targetTime = block.timestamp + _timeElapsed;
        vm.warp(_targetTime);

        (,, uint256 _ts0) = stkVault.mgmtFee();

        vm.startPrank(stkVOwner);
        stkVault.accumulateManagementFee();
        vm.stopPrank();
        (_fee, _supply, _ts) = stkVault.mgmtFee();

        vm.expectRevert(Constants.ONLY_FOR_CLAIMER_OR_OWNER.selector);
        vm.startPrank(_user);
        stkVault.accumulateManagementFee();
        vm.stopPrank();

        uint256 _expectedFee = (_totalAssets * (_targetTime - _ts0) * stkVault.MANAGEMENT_FEE_BPS())
            / (Constants.TOTAL_BPS * Constants.ONE_YEAR);
        console.log("_fee:%d,_supply:%d,_ts:%d", _fee, _supply, _ts);
        assertEq(_ts, _targetTime);
        assertEq(_supply, _totalAssets);
        assertTrue(_assertApproximateEq(_fee, _expectedFee, BIGGER_TOLERANCE));

        // accumulate fee again
        _targetTime = block.timestamp + _timeElapsed;
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

        vm.recordLogs();
        vm.startPrank(stkVOwner);
        stkVault.claimManagementFee();
        vm.stopPrank();
        Vm.Log[] memory logEntries = vm.getRecordedLogs();
        assertEq(0, logEntries.length);
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
        address _generousPoorUser = TestUtils._getSugarUser();
        vm.startPrank(_generousPoorUser);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        vm.stopPrank();
        vm.expectRevert(Constants.TOO_SMALL_FIRST_SHARE.selector);
        vm.startPrank(_generousPoorUser);
        stkVault.deposit(MIN_SHARE - 1, _generousPoorUser);
        vm.stopPrank();

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

        vm.recordLogs();
        vm.startPrank(stkVOwner);
        stkVault.requestRedemption(_userShare);
        stkVault.claimRedemptionRequest();
        vm.stopPrank();
        Vm.Log[] memory logEntries = vm.getRecordedLogs();
        assertEq(0, logEntries.length);
    }

    function test_Strategy_Add_Remove(uint256 _testVal) public {
        // create the first strategy
        uint256 _alloc1 = MAX_ETH_ALLOWED;
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
        bytes memory EMPTY_CALLDATA;

        // ensure that user can't claim withdraw request if not enough asset in vault
        address _user = TestUtils._getSugarUser();
        (uint256 _assetVal, uint256 _share) =
            TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 2 ether, 100 ether);
        _testVal = _assetVal;
        vm.startPrank(stkVOwner);
        myStrategy.allocate(stkVault.getAllocationAvailableForStrategy(address(myStrategy)), EMPTY_CALLDATA);
        vm.stopPrank();

        // not enough asset to make the redeem
        vm.expectRevert();
        vm.startPrank(_user);
        stkVault.redeem(_share, _user, _user);
        vm.stopPrank();

        TestUtils._makeRedemptionRequest(_user, _share, address(stkVault));
        assertEq(_share, stkVault.userRedemptionRequestShares(_user));
        vm.expectRevert(Constants.LESS_REDEMPTION_TO_USER.selector);
        vm.startPrank(_user);
        stkVault.claimRedemptionRequest();
        vm.stopPrank();

        // create the second strategy
        uint256 _alloc2 = MAX_ETH_ALLOWED;
        DummyStrategy myStrategy2 = new DummyStrategy(wETH, address(stkVault));

        // add the second strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy2), _alloc2);
        vm.stopPrank();
        assertEq(_alloc2, stkVault.strategyAllocations(address(myStrategy2)));

        assertEq(address(myStrategy2), stkVault.allStrategies(1));

        // remove the second strategy
        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy2), EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(0, stkVault.strategyAllocations(address(myStrategy2)));

        // can't remove the second strategy again
        vm.expectRevert(Constants.WRONG_STRATEGY_TO_REMOVE.selector);
        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy2), EMPTY_CALLDATA);
        vm.stopPrank();

        // remove the first strategy
        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy), EMPTY_CALLDATA);
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

    function test_TotalAsset_After_RemoveStrategy(uint256 _testVal) public {
        // create the first strategy
        uint256 _alloc1 = MAX_ETH_ALLOWED;
        DummyStrategy myStrategy = new DummyStrategy(wETH, address(stkVault));

        // add the first strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), _alloc1);
        vm.stopPrank();
        assertEq(address(myStrategy), stkVault.allStrategies(0));

        _fundFirstDepositGenerously(address(stkVault));
        bytes memory EMPTY_CALLDATA;

        address _user = TestUtils._getSugarUser();
        TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 2 ether, 100 ether);
        uint256 _assetAllocated1 = stkVault.getAllocationAvailableForStrategy(address(myStrategy));
        vm.startPrank(stkVOwner);
        myStrategy.allocate(_assetAllocated1, EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(_assetAllocated1, myStrategy.totalAssets());

        // create the second strategy
        uint256 _alloc2 = MAX_ETH_ALLOWED;
        DummyStrategy myStrategy2 = new DummyStrategy(wETH, address(stkVault));

        // add the second strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy2), _alloc2);
        vm.stopPrank();
        assertEq(address(myStrategy2), stkVault.allStrategies(1));

        address _user2 = TestUtils._getSugarUser();
        TestUtils._makeVaultDeposit(address(stkVault), _user2, _testVal, 2 ether, 100 ether);
        vm.startPrank(stkVOwner);
        myStrategy2.allocate(stkVault.getAllocationAvailableForStrategy(address(myStrategy2)), EMPTY_CALLDATA);
        vm.stopPrank();

        // remove the first strategy
        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(0, myStrategy.totalAssets());
        assertEq(Constants.ZRO_ADDR, stkVault.allStrategies(0));
        assertEq(address(myStrategy2), stkVault.allStrategies(1));

        // check totalAssets() match after 1st strategy removed
        assertEq(stkVault.totalAssets(), myStrategy2.totalAssets() + ERC20(wETH).balanceOf(address(stkVault)));
        _checkBasicInvariants(address(stkVault));

        // create the third strategy
        uint256 _alloc3 = MAX_ETH_ALLOWED;
        DummyStrategy myStrategy3 = new DummyStrategy(wETH, address(stkVault));

        // add the third strategy
        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy3), _alloc3);
        vm.stopPrank();
        assertEq(address(myStrategy3), stkVault.allStrategies(0));
        vm.startPrank(stkVOwner);
        myStrategy3.allocate(stkVault.getAllocationAvailableForStrategy(address(myStrategy3)), EMPTY_CALLDATA);
        vm.stopPrank();
        uint256 _totalAssetsInStrategy3 = myStrategy3.totalAssets();
        assertEq(
            stkVault.totalAssets(),
            myStrategy2.totalAssets() + _totalAssetsInStrategy3 + ERC20(wETH).balanceOf(address(stkVault))
        );
        assertTrue(_totalAssetsInStrategy3 > 0);
        _checkBasicInvariants(address(stkVault));

        vm.startPrank(stkVOwner);
        stkVault.updateStrategyAllocation(address(myStrategy3), 1);
        vm.stopPrank();
        assertEq(1, stkVault.strategyAllocations(address(myStrategy3)));
        assertEq(0, stkVault.getAllocationAvailableForStrategy(address(myStrategy3)));
    }

    function test_AddStrategy_TooMany() public {
        _fundFirstDepositGenerously(address(stkVault));
        
        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        new DummyPendleAAVEStrategy(address(stkVault));

        // add enough strategies
        for (uint256 i = 0; i < MAX_STRATEGIES_NUM; i++) {
            DummyStrategy myStrategy = new DummyStrategy(wETH, address(stkVault));
            vm.startPrank(stkVOwner);
            stkVault.addStrategy(address(myStrategy), MAX_ETH_ALLOWED);
            vm.stopPrank();
        }
        assertEq(MAX_STRATEGIES_NUM, stkVault.activeStrategies());
        bytes memory EMPTY_CALLDATA;

        address _replacedStrategy = stkVault.allStrategies(MAX_STRATEGIES_NUM / 2);

        // fail to add any new strategy due to capacity full
        DummyStrategy anewStrategy = new DummyStrategy(wETH, address(stkVault));
        vm.expectRevert(Constants.TOO_MANY_STRATEGIES.selector);

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(anewStrategy), MAX_ETH_ALLOWED);
        vm.stopPrank();

        // make the replacement
        uint256 _oldAlloc = MAX_ETH_ALLOWED;
        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(_replacedStrategy), EMPTY_CALLDATA);
        stkVault.addStrategy(address(anewStrategy), _oldAlloc);
        vm.stopPrank();
        assertEq(address(anewStrategy), stkVault.allStrategies(MAX_STRATEGIES_NUM / 2));
        assertEq(MAX_STRATEGIES_NUM, stkVault.activeStrategies());
        _checkBasicInvariants(address(stkVault));

        // update allocation for new strategy
        uint256 _newAlloc = 12345;

        vm.expectRevert(Constants.WRONG_STRATEGY_ALLOC_UPDATE.selector);
        vm.startPrank(stkVOwner);
        stkVault.updateStrategyAllocation(address(anewStrategy), 0);
        vm.stopPrank();

        vm.startPrank(stkVOwner);
        stkVault.updateStrategyAllocation(address(anewStrategy), _newAlloc);
        vm.stopPrank();

        assertEq(_newAlloc, stkVault.strategyAllocations(address(anewStrategy)));
    }

    function test_Vault_Pause() public {
        _fundFirstDepositGenerously(address(stkVault));
        address _user = TestUtils._getSugarUser();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _user));
        vm.startPrank(_user);
        stkVault.setPauseCommander(_user);
        vm.stopPrank();

        vm.startPrank(stkVOwner);
        stkVault.setPauseCommander(_user);
        vm.stopPrank();
        assertEq(_user, stkVault._pauseCommander());

        TestUtils._toggleVaultPause(address(stkVault), true);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.startPrank(stkVOwner);
        stkVault.accumulateManagementFee();
        vm.stopPrank();

        vm.warp(block.timestamp + Constants.ONE_YEAR);

        TestUtils._toggleVaultPause(address(stkVault), false);

        vm.startPrank(stkVOwner);
        stkVault.accumulateManagementFee();
        vm.stopPrank();
        (uint256 _fee,,) = stkVault.mgmtFee();
        assertTrue(_fee > 0);
    }
}
