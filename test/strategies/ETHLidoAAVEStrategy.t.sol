// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../src/SparkleXVault.sol";
import {ETHLidoAAVEStrategy} from "../../src/strategies/aave/ETHLidoAAVEStrategy.sol";
import {AAVEHelper} from "../../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapperWithFallback} from "../../src/utils/TokenSwapperWithFallback.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {WETH} from "../../interfaces/IWETH.sol";
import {IWstETH} from "../../interfaces/lido/IWstETH.sol";
import {IStETH} from "../../interfaces/lido/IStETH.sol";
import {IPool} from "../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../interfaces/aave/IAaveOracle.sol";
import {IPriceOracleGetter} from "../../interfaces/aave/IPriceOracleGetter.sol";
import {TestUtils} from "../TestUtils.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {IVariableDebtToken} from "../../interfaces/aave/IVariableDebtToken.sol";
import {TokenSwapper} from "../../src/utils/TokenSwapper.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path ETHLidoAAVEStrategyTest -vvv
contract ETHLidoAAVEStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    ETHLidoAAVEStrategy public myStrategy;
    TokenSwapperWithFallback public swapper;
    AAVEHelper public aaveHelper;
    address public stkVOwner;
    address public strategist;
    address public aaveHelperOwner;
    address public strategyOwner;

    address wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    IAaveOracle aaveOracle = IAaveOracle(0x8105f69D9C41644c6A0803fDA7D03Aa70996cFD9);
    IPool aavePool = IPool(0xC13e21B648A5Ee794902342038FF3aDAB66BE987);
    ERC20 aWstETH = ERC20(0x12B54025C112Aa61fAce2CDB7118740875A566E9);
    address constant aWstETHDebt = 0xd5c3E3B566a42A6110513Ac7670C1a86D76E13E6;
    address constant stETH_ETH_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    address sparkFi_wstETH_Oracle = 0x2750e4CB635aF1FCCFB10C0eA54B5b5bfC2759b6;

    // events to check
    bytes32 swapUniswapEventSignature = keccak256("SwapInUniswap(address,address,address,uint256,uint256)");
    bytes32 swapCurveEventSignature = keccak256("SwapInCurve(address,address,address,uint256,uint256)");

    function setUp() public {
        _createForkMainnet(uint256(vm.envInt("TESTNET_FORK_HEIGHT")));
        stkVault = new SparkleXVault(ERC20(wETH), "SparkleX ETH Vault", "spETH");
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);

        myStrategy = new ETHLidoAAVEStrategy(address(stkVault));
        strategist = myStrategy.strategist();
        strategyOwner = myStrategy.owner();

        swapper = new TokenSwapperWithFallback();
        aaveHelper = new AAVEHelper(address(myStrategy), ERC20(wstETH), ERC20(wETH), aWstETH, 1);
        aaveHelperOwner = aaveHelper.owner();
        swapper.setWhitelist(address(myStrategy), true);

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), MAX_ETH_ALLOWED);
        vm.stopPrank();

        vm.startPrank(strategyOwner);
        myStrategy.setSwapper(address(swapper));
        myStrategy.setAAVEHelper(address(aaveHelper));
        vm.stopPrank();
    }

    function test_LidoLoop_GetMaxLTV() public {
        uint256 _ltv = aaveHelper.getMaxLTV();
        // https://app.spark.fi/markets/1/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0
        assertEq(_ltv, 9200);
    }

    function test_LidoLoop_Invest_Redeem(uint256 _testVal, uint256 _curveRatio) public {
        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);
        bytes memory EMPTY_CALLDATA;

        uint256 _initSupply = _testVal / 2;
        uint256 _initDebt = _initSupply * 9;

        _curveRatio = bound(_curveRatio, 0, Constants.TOTAL_BPS);

        vm.startPrank(strategist);
        myStrategy.invest(_initSupply / 2, _initDebt / 2, abi.encode(true, _curveRatio));
        myStrategy.invest(_initSupply / 2, _initDebt / 2, abi.encode(false, _curveRatio));
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt, uint256 _totalSupply) = myStrategy.getNetSupplyAndDebt(true);
        console.log("_testVal:%d,_initSupply:%d,_initDebt:%d", _testVal, _initSupply, _initDebt);
        assertTrue(_assertApproximateEq(_testVal, stkVault.totalAssets(), 3 * BIGGER_TOLERANCE));
        assertTrue(_assertApproximateEq(_initDebt, _debt, 3 * BIGGER_TOLERANCE));
        assertTrue(_assertApproximateEq(_totalSupply, (_initSupply + _initDebt), 3 * BIGGER_TOLERANCE));

        _checkBasicInvariants(address(stkVault));

        (uint256 _maxBorrow,) = aaveHelper.getAvailableBorrowAmount(address(myStrategy));
        uint256 _toRedeem = IWstETH(wstETH).getStETHByWstETH(_maxBorrow);
        vm.startPrank(strategist);
        myStrategy.redeem(_toRedeem, EMPTY_CALLDATA);
        myStrategy.swapAndRepay(_toRedeem, _toRedeem, _curveRatio);
        vm.stopPrank();

        (, uint256 _debt2,) = myStrategy.getNetSupplyAndDebt(true);
        console.log("_debt2:%d,_maxBorrow:%d,_debt:%d", _debt2, _maxBorrow, _debt);
        assertTrue(_assertApproximateEq(_debt2 + _maxBorrow, _debt, 3 * BIGGER_TOLERANCE));

        _checkBasicInvariants(address(stkVault));
    }

    function test_LidoLoop_Collect_Everything(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        assertTrue(_assertApproximateEq(_testVal, stkVault.totalAssets(), BIGGER_TOLERANCE));

        assertTrue(
            _assertApproximateEq(_testVal, ERC20(wETH).balanceOf(address(stkVault)) + _netSupply, BIGGER_TOLERANCE)
        );

        vm.recordLogs();
        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();
        Vm.Log[] memory logEntries = vm.getRecordedLogs();
        assertTrue(TestUtils._findTargetEvent(logEntries, swapCurveEventSignature));
        assertFalse(TestUtils._findTargetEvent(logEntries, swapUniswapEventSignature));
        uint256 _ta = stkVault.totalAssets();
        uint256 _assetBal = ERC20(wETH).balanceOf(address(stkVault));
        console.log("_testVal:%d,_ta:%d,_assetBal:%d", _testVal, _ta, _assetBal);

        assertTrue(_assertApproximateEq(_testVal, _ta, 10 * BIGGER_TOLERANCE));
        assertTrue(_assertApproximateEq(_testVal, _assetBal, 10 * BIGGER_TOLERANCE));

        (uint256 _ltv,) = _printAAVEPosition();
        assertEq(_ltv, 0);

        _checkBasicInvariants(address(stkVault));

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();
        assertTrue(_assertApproximateEq(_ta, stkVault.totalAssets(), BIGGER_TOLERANCE));

        bytes memory _useUniswap = abi.encode(0);
        vm.recordLogs();
        vm.startPrank(strategist);
        myStrategy.collectAll(_useUniswap);
        vm.stopPrank();
        logEntries = vm.getRecordedLogs();
        assertTrue(TestUtils._findTargetEvent(logEntries, swapUniswapEventSignature));
        assertFalse(TestUtils._findTargetEvent(logEntries, swapCurveEventSignature));

        uint256 _ta2 = stkVault.totalAssets();
        uint256 _assetBal2 = ERC20(wETH).balanceOf(address(stkVault));
        console.log("_ta2:%d,_assetBal2:%d", _ta2, _assetBal2);

        assertTrue(_assertApproximateEq(_ta, _ta2, 10 * BIGGER_TOLERANCE));

        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(stkVault.strategyAllocations(address(myStrategy)), 0);
    }

    function test_LidoLoop_Collect_Portion(uint256 _testVal) public {
        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal, uint256 _share) =
            TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 2 ether, 5 ether);
        _testVal = _assetVal;
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        assertTrue(_assertApproximateEq(_testVal, stkVault.totalAssets(), BIGGER_TOLERANCE));

        assertTrue(
            _assertApproximateEq(_testVal, (ERC20(wETH).balanceOf(address(stkVault)) + _netSupply), BIGGER_TOLERANCE)
        );

        uint256 _toRedeemShare = (_share * 3 / 10);
        uint256 _redemptioRequested = TestUtils._makeRedemptionRequest(_user, _toRedeemShare, address(stkVault));

        uint256 _portionVal = _testVal / 10;
        vm.startPrank(strategist);
        myStrategy.collect(_portionVal, EMPTY_CALLDATA);
        myStrategy.collect(_portionVal * 3, EMPTY_CALLDATA);
        vm.stopPrank();

        assertTrue(_assertApproximateEq(_testVal, stkVault.totalAssets(), 5 * BIGGER_TOLERANCE));

        uint256 _vltBal = ERC20(wETH).balanceOf(address(stkVault));
        console.log("_vltBal:%d,_portionVal:%d", _vltBal, _portionVal);
        assertTrue(_assertApproximateEq(_vltBal, (_portionVal + _portionVal * 3), BIGGER_TOLERANCE));

        _claimRedemptionRequest(_user, _toRedeemShare);
    }

    function test_LidoLoop_Price_Dip(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));
        uint256 _liqThreshold = 9300;
        uint256 _collectPortion = 5000;

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);

        vm.startPrank(stkVOwner);
        stkVault.setEarnRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        vm.startPrank(aaveHelperOwner);
        aaveHelper.setLeverageRatio(Constants.TOTAL_BPS);
        vm.stopPrank();
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _ltv, uint256 _healthFactor) = _printAAVEPosition();
        uint256 _currentLTV = (1e18 * _liqThreshold / _healthFactor) * 1e16;
        console.log("_currentLTV:%d", _currentLTV);
        assertTrue(_assertApproximateEq(_currentLTV, aaveHelper.getMaxLTV() * 1e16, BIGGER_TOLERANCE * 30));

        uint256 _originalPrice = aaveOracle.getAssetPrice(wstETH);
        (int256 _originalStETHToETHRate,,) = swapper.getPriceFromChainLink(stETH_ETH_FEED);
        uint256 _originalStETHToETHPrice = uint256(_originalStETHToETHRate);
        (uint256 _netSupply,,) = myStrategy.getNetSupplyAndDebt(true);

        // price dip 1% -> LTV exceed maximum allowed -> collect() to reduce LTV
        vm.mockCall(
            address(aaveOracle),
            abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, address(wstETH)),
            abi.encode(_originalPrice * 9900 / Constants.TOTAL_BPS)
        );
        vm.mockCall(
            address(swapper),
            abi.encodeWithSelector(TokenSwapper.getPriceFromChainLink.selector, stETH_ETH_FEED),
            abi.encode(_originalStETHToETHPrice * 9900 / Constants.TOTAL_BPS, block.timestamp, 18)
        );
        (_ltv, _healthFactor) = _printAAVEPosition();
        assertTrue((1e18 * _liqThreshold / _healthFactor) > aaveHelper.getMaxLTV());
        assertEq(0, aaveHelper.getMaxRedeemableAmount());

        vm.startPrank(strategist);
        assertEq(0, myStrategy.redeem(_netSupply, EMPTY_CALLDATA));
        vm.stopPrank();

        vm.startPrank(strategist);
        myStrategy.collect(_netSupply * _collectPortion / Constants.TOTAL_BPS, EMPTY_CALLDATA);
        vm.stopPrank();
        (_ltv, _healthFactor) = _printAAVEPosition();
        assertTrue((1e18 * _liqThreshold / _healthFactor) < aaveHelper.getMaxLTV());
        (_netSupply,,) = myStrategy.getNetSupplyAndDebt(false);

        // price dip 3% -> LTV exceed maximum allowed -> collectAll()
        vm.mockCall(
            address(aaveOracle),
            abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, address(wstETH)),
            abi.encode(_originalPrice * 9700 / Constants.TOTAL_BPS)
        );
        vm.mockCall(
            address(swapper),
            abi.encodeWithSelector(TokenSwapper.getPriceFromChainLink.selector, stETH_ETH_FEED),
            abi.encode(_originalStETHToETHPrice * 9700 / Constants.TOTAL_BPS, block.timestamp, 18)
        );
        (_ltv, _healthFactor) = _printAAVEPosition();
        assertTrue((1e18 * _liqThreshold / _healthFactor) > aaveHelper.getMaxLTV());

        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();
        (_ltv, _healthFactor) = _printAAVEPosition();
        assertEq(0, _ltv);

        uint256 _ta = stkVault.totalAssets();
        console.log("_testVal:%d,_portionVal:%d", _testVal, _ta);
        assertTrue(_assertApproximateEq(_testVal, _ta, 10 * BIGGER_TOLERANCE));

        vm.clearMockedCalls();
    }

    function _printAAVEPosition() internal view returns (uint256, uint256) {
        (uint256 _cBase, uint256 _dBase, uint256 _leftBase, uint256 _liqThresh, uint256 _ltv, uint256 _healthFactor) =
            aavePool.getUserAccountData(address(myStrategy));
        console.log("_ltv:%d,_liqThresh:%d,_healthFactor:%d", _ltv, _liqThresh, _healthFactor);
        console.log("_cBase:%d,_dBase:%d,_leftBase:%d", _cBase, _dBase, _leftBase);
        return (_ltv, _healthFactor);
    }

    function _claimRedemptionRequest(address _user, uint256 _share) internal returns (uint256 _actualRedeemed) {
        _actualRedeemed = TestUtils._claimRedemptionRequest(_user, _share, address(stkVault), COMP_TOLERANCE);
    }
}
