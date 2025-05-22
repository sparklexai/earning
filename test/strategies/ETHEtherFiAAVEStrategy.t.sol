// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../src/SparkleXVault.sol";
import {ETHEtherFiAAVEStrategy} from "../../src/strategies/aave/ETHEtherFiAAVEStrategy.sol";
import {AAVEHelper} from "../../src/strategies/aave/AAVEHelper.sol";
import {EtherFiHelper} from "../../src/strategies/etherfi/EtherFiHelper.sol";
import {TokenSwapper} from "../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {WETH} from "../../interfaces/IWETH.sol";
import {ILiquidityPool} from "../../interfaces/etherfi/ILiquidityPool.sol";
import {IWeETH} from "../../interfaces/etherfi/IWeETH.sol";
import {IWithdrawRequestNFT} from "../../interfaces/etherfi/IWithdrawRequestNFT.sol";
import {IPool} from "../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../interfaces/aave/IAaveOracle.sol";
import {TestUtils} from "../TestUtils.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path ETHEtherFiAAVEStrategyTest -vvv
contract ETHEtherFiAAVEStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    ETHEtherFiAAVEStrategy public myStrategy;
    TokenSwapper public swapper;
    AAVEHelper public aaveHelper;
    EtherFiHelper public etherfiHelper;
    address public stkVOwner;
    address public strategist;

    address weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    ILiquidityPool etherfiLP = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
    IWithdrawRequestNFT etherfiWithdrawNFT = IWithdrawRequestNFT(0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c);
    IAaveOracle aaveOracle = IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address constant withdrawNFTAdmin = 0x0EF8fa4760Db8f5Cd4d993f3e3416f30f942D705;
    ERC20 aWeETH = ERC20(0xBdfa7b7893081B35Fb54027489e2Bc7A38275129);

    function setUp() public {
        stkVault = new SparkleXVault(ERC20(wETH), "SparkleXVault", "SPXV");
        stkVOwner = stkVault.owner();

        myStrategy = new ETHEtherFiAAVEStrategy(address(stkVault));
        strategist = myStrategy.strategist();

        swapper = new TokenSwapper();
        etherfiHelper = new EtherFiHelper();
        aaveHelper = new AAVEHelper(address(myStrategy), ERC20(weETH), ERC20(wETH), aWeETH, 1);

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), 100);
        vm.stopPrank();

        vm.startPrank(strategist);
        myStrategy.setSwapper(address(swapper));
        myStrategy.setEtherFiHelper(address(etherfiHelper));
        myStrategy.setAAVEHelper(address(aaveHelper));
        vm.stopPrank();
    }

    function test_GetMaxLTV() public {
        uint256 _ltv = aaveHelper.getMaxLTV();
        // https://app.aave.com/reserve-overview/?underlyingAsset=0xcd5fe23c85820f7b72d0926fc9b05b43e359b7ee&marketName=proto_mainnet_v3
        assertEq(_ltv, 9300);
    }

    function test_Yield_Collect_ZeroLeverage() public {
        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _share = stkVault.deposit(wETHVal, _user);
        vm.stopPrank();

        // now test yield without leverage
        vm.startPrank(strategist);
        myStrategy.setLeverageRatio(0);
        myStrategy.allocate(type(uint256).max);
        vm.stopPrank();

        uint256 _residue = ERC20(wETH).balanceOf(address(stkVault));
        uint256 _totalAssets = stkVault.totalAssets();
        assertTrue(_assertApproximateEq(wETHVal, _totalAssets, BIGGER_TOLERANCE));

        (uint256 _netSupply, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        assertTrue(_assertApproximateEq(wETHVal - _residue, _netSupply, BIGGER_TOLERANCE));
        assertEq(0, _debt);

        uint256 _toRedeem = 1000 * 1e18;
        uint256 _toRedeemShare = stkVault.convertToShares(_toRedeem);
        uint256 _redemptioRequested = TestUtils._makeRedemptionRequest(_user, _toRedeemShare, address(stkVault));
        assertEq(stkVault.userRedemptionRequestShares(_user), _toRedeemShare);
        assertEq(stkVault.userRedemptionRequestAssets(_user), _redemptioRequested);

        vm.startPrank(strategist);
        myStrategy.collect(_toRedeem);
        vm.stopPrank();

        (uint256 _reqId, IWithdrawRequestNFT.WithdrawRequest memory _request) = _checkLatestWithdrawReq();

        _finalizeWithdrawRequest(_reqId);
        _claimWithdrawRequest(strategist, _reqId);

        _residue = ERC20(wETH).balanceOf(address(stkVault));
        assertTrue(_toRedeem <= _residue);

        _totalAssets = stkVault.totalAssets();
        assertTrue(_assertApproximateEq(wETHVal, _totalAssets, BIGGER_TOLERANCE));

        (uint256 _newNetSupply, uint256 _newDebt,) = myStrategy.getNetSupplyAndDebt(true);
        assertEq(0, _newDebt);

        _claimRedemptionRequest(_user, _toRedeemShare);
    }

    function test_Leverage_Collect_Everything() public {
        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _testVal = 100 ether;
        uint256 _share = stkVault.deposit(_testVal, _user);
        vm.stopPrank();

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        uint256 _flashloanFee = TestUtils._applyFlashLoanFeeFromAAVE(_debt);
        uint256 _totalAssets = stkVault.totalAssets();
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _flashloanFee), BIGGER_TOLERANCE));

        uint256 _residue = ERC20(wETH).balanceOf(address(stkVault));
        assertTrue(_assertApproximateEq(_testVal, (_residue + _netSupply + _flashloanFee), BIGGER_TOLERANCE));

        uint256 _toRedeemShare = _share;
        uint256 _redemptioRequested = TestUtils._makeRedemptionRequest(_user, _toRedeemShare, address(stkVault));
        assertEq(stkVault.userRedemptionRequestShares(_user), (_toRedeemShare > _share ? _share : _toRedeemShare));
        assertEq(stkVault.userRedemptionRequestAssets(_user), _redemptioRequested);

        vm.startPrank(strategist);
        myStrategy.collectAll();
        vm.stopPrank();

        uint256[][] memory _activeWithdrawReqs = myStrategy.getAllWithdrawRequests();
        assertEq(_activeWithdrawReqs.length, 1);

        _totalAssets = stkVault.totalAssets();
        assertTrue(
            _assertApproximateEq(
                _testVal, (_totalAssets + _flashloanFee * 2 + _activeWithdrawReqs[0][2]), BIGGER_TOLERANCE
            )
        );

        uint256 _ltv = _printAAVEPosition();
        assertEq(_ltv, 0);

        uint256 _withdrawReqId = _activeWithdrawReqs[0][0];
        _finalizeWithdrawRequest(_withdrawReqId);
        _claimWithdrawRequest(strategist, _withdrawReqId);

        _residue = ERC20(wETH).balanceOf(address(stkVault));
        assertTrue(_assertApproximateEq(_residue, _totalAssets, COMP_TOLERANCE));

        _activeWithdrawReqs = myStrategy.getAllWithdrawRequests();
        assertEq(_activeWithdrawReqs.length, 0);

        _claimRedemptionRequest(_user, _toRedeemShare);
    }

    function test_Leverage_Collect_Portion() public {
        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _testVal = 100 ether;
        uint256 _share = stkVault.deposit(_testVal, _user);
        vm.stopPrank();

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        uint256 _flashloanFee = TestUtils._applyFlashLoanFeeFromAAVE(_debt);
        uint256 _totalAssets = stkVault.totalAssets();
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _flashloanFee), BIGGER_TOLERANCE));

        uint256 _residue = ERC20(wETH).balanceOf(address(stkVault));
        assertTrue(_assertApproximateEq(_testVal, (_residue + _netSupply + _flashloanFee), BIGGER_TOLERANCE));

        uint256 _toRedeemShare = (_share * 3 / 10);
        uint256 _redemptioRequested = TestUtils._makeRedemptionRequest(_user, _toRedeemShare, address(stkVault));
        assertEq(stkVault.userRedemptionRequestShares(_user), (_toRedeemShare > _share ? _share : _toRedeemShare));
        assertEq(stkVault.userRedemptionRequestAssets(_user), _redemptioRequested);

        uint256 _portionVal = _testVal / 10;
        vm.startPrank(strategist);
        myStrategy.collect(_portionVal);
        vm.stopPrank();

        uint256[][] memory _activeWithdrawReqs = myStrategy.getAllWithdrawRequests();
        assertEq(_activeWithdrawReqs.length, 1);

        _totalAssets = stkVault.totalAssets();
        uint256 _totalLoss = _flashloanFee
            + TestUtils._applyFlashLoanFeeFromAAVE(aaveHelper.getMaxLeverage(_portionVal)) + _activeWithdrawReqs[0][2]
            + _activeWithdrawReqs[0][3];
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _totalLoss), BIGGER_TOLERANCE));

        uint256 _portionVal2 = _portionVal * 2;
        vm.startPrank(strategist);
        myStrategy.collect(_portionVal2);
        vm.stopPrank();

        _activeWithdrawReqs = myStrategy.getAllWithdrawRequests();
        assertEq(_activeWithdrawReqs.length, 2);

        _totalAssets = stkVault.totalAssets();
        _totalLoss = _totalLoss + TestUtils._applyFlashLoanFeeFromAAVE(aaveHelper.getMaxLeverage(_portionVal2))
            + _activeWithdrawReqs[1][2] + _activeWithdrawReqs[1][3];
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _totalLoss), BIGGER_TOLERANCE));

        assertEq(_printAAVEPosition(), 9300);

        _finalizeWithdrawRequest(_activeWithdrawReqs[0][0]);
        _finalizeWithdrawRequest(_activeWithdrawReqs[1][0]);

        _claimWithdrawRequest(strategist, _activeWithdrawReqs[0][0]);
        _claimWithdrawRequest(strategist, _activeWithdrawReqs[1][0]);

        _residue = ERC20(wETH).balanceOf(address(stkVault));
        assertTrue(_residue >= (_portionVal + _portionVal2));

        _activeWithdrawReqs = myStrategy.getAllWithdrawRequests();
        assertEq(_activeWithdrawReqs.length, 0);

        _claimRedemptionRequest(_user, _toRedeemShare);
    }

    function test_Basic_Invest_Redeem() public {
        address _user = TestUtils._getSugarUser();

        vm.startPrank(_user);
        ERC20(wETH).approve(address(stkVault), type(uint256).max);
        uint256 _testVal = 100 ether;
        uint256 _share = stkVault.deposit(_testVal, _user);
        vm.stopPrank();

        uint256 _initSupply = _testVal / 2;
        uint256 _initDebt = _initSupply * 9;
        vm.startPrank(strategist);
        myStrategy.invest(_initSupply, _initDebt);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt, uint256 _totalSupply) = myStrategy.getNetSupplyAndDebt(true);
        uint256 _flashloanFee = TestUtils._applyFlashLoanFeeFromAAVE(_debt);
        uint256 _totalAssets = stkVault.totalAssets();
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _flashloanFee), BIGGER_TOLERANCE));
        assertTrue(_assertApproximateEq(_initDebt + _flashloanFee, _debt, BIGGER_TOLERANCE));
        assertTrue(_assertApproximateEq(_totalSupply, (_initSupply + _initDebt), BIGGER_TOLERANCE));

        uint256 _maxBorrow = aaveHelper.getAvailableBorrowAmount(address(myStrategy));
        uint256 _toRedeem = IWeETH(weETH).getWeETHByeETH(_maxBorrow);
        vm.startPrank(strategist);
        myStrategy.redeem(_toRedeem);
        vm.stopPrank();

        uint256[][] memory _activeWithdrawReqs = myStrategy.getAllWithdrawRequests();
        assertEq(_activeWithdrawReqs.length, 1);
        console.log("_maxBorrow:%d,_toRedeem:%d,_reqEETH:%d", _maxBorrow, _toRedeem, _activeWithdrawReqs[0][1]);
        assertTrue(_assertApproximateEq(_maxBorrow, _activeWithdrawReqs[0][1], COMP_TOLERANCE));

        uint256[] memory _reqIds = new uint256[](1);
        _reqIds[0] = _activeWithdrawReqs[0][0];

        _finalizeWithdrawRequest(_reqIds[0]);

        vm.startPrank(strategist);
        myStrategy.claimAndRepay(_reqIds, _maxBorrow);
        vm.stopPrank();

        _activeWithdrawReqs = myStrategy.getAllWithdrawRequests();
        assertEq(_activeWithdrawReqs.length, 0);

        (, uint256 _debt2,) = myStrategy.getNetSupplyAndDebt(true);
        assertTrue(_assertApproximateEq(_debt2 + _maxBorrow, _debt, COMP_TOLERANCE));
    }

    function _printAAVEPosition() internal view returns (uint256) {
        (uint256 _cBase, uint256 _dBase, uint256 _leftBase, uint256 _liqThresh, uint256 _ltv, uint256 _healthFactor) =
            aavePool.getUserAccountData(address(myStrategy));
        console.log("_ltv:%d,_liqThresh:%d,_healthFactor:%d", _ltv, _liqThresh, _healthFactor);
        console.log("_cBase:%d,_dBase:%d,_leftBase:%d", _cBase, _dBase, _leftBase);
        return _ltv;
    }

    function _finalizeWithdrawRequest(uint256 _reqID) internal {
        vm.startPrank(withdrawNFTAdmin);
        etherfiWithdrawNFT.finalizeRequests(_reqID);
        vm.stopPrank();
    }

    function _claimWithdrawRequest(address _user, uint256 _reqID) internal {
        vm.startPrank(_user);
        myStrategy.claimWithdrawFromEtherFi(_reqID);
        vm.stopPrank();
    }

    function _checkLatestWithdrawReq()
        internal
        view
        returns (uint256 _reqId, IWithdrawRequestNFT.WithdrawRequest memory _request)
    {
        _reqId = etherfiWithdrawNFT.nextRequestId() - 1;
        assertEq(etherfiWithdrawNFT.ownerOf(_reqId), address(etherfiHelper));
        assertEq(etherfiHelper.withdrawRequsters(_reqId), address(myStrategy));
        _request = etherfiWithdrawNFT.getRequest(_reqId);
        assertTrue(_request.isValid);
    }

    function _claimRedemptionRequest(address _user, uint256 _share) internal returns (uint256 _actualRedeemed) {
        _actualRedeemed = TestUtils._claimRedemptionRequest(_user, _share, address(stkVault), COMP_TOLERANCE);
    }
}
