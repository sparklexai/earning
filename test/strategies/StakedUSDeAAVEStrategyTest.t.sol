// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../src/SparkleXVault.sol";
import {StakedUSDeAAVEStrategy} from "../../src/strategies/aave/StakedUSDeAAVEStrategy.sol";
import {AAVEHelper} from "../../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapper} from "../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {WETH} from "../../interfaces/IWETH.sol";
import {IPool} from "../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../interfaces/aave/IAaveOracle.sol";
import {IPriceOracleGetter} from "../../interfaces/aave/IPriceOracleGetter.sol";
import {TestUtils} from "../TestUtils.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {IVariableDebtToken} from "../../interfaces/aave/IVariableDebtToken.sol";
import {DummyDEXRouter} from "../mock/DummyDEXRouter.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path StakedUSDeAAVEStrategyTest -vvv
contract StakedUSDeAAVEStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    StakedUSDeAAVEStrategy public myStrategy;
    TokenSwapper public swapper;
    AAVEHelper public aaveHelper;
    address public stkVOwner;
    address public strategist;
    address public aaveHelperOwner;
    address public strategyOwner;
    uint256 public usdcPerETH = 2000e18;
    DummyDEXRouter public mockRouter;
    uint256 public myTolerance = 200 * MIN_SHARE;
    address usdcWhale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; //sky:PSM
    address sUSDeWhale = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497; //fluid liquidity

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant sUSDe_USD_Feed = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099;

    IAaveOracle aaveOracle = IAaveOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    ERC20 aStakedUSDe = ERC20(0x4579a27aF00A62C0EB156349f31B345c08386419);
    address constant aUSDTDebt = 0x6df1C1E379bC5a00a7b4C6e67A203333772f45A8;

    function setUp() public {
        _createForkMainnet(uint256(vm.envInt("TESTNET_FORK_HEIGHT")));
        stkVault = new SparkleXVault(ERC20(USDC), "SparkleX USD Vault", "spUSD");
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);

        myStrategy = new StakedUSDeAAVEStrategy(address(stkVault));
        strategist = myStrategy.strategist();
        strategyOwner = myStrategy.owner();
        mockRouter = new DummyDEXRouter();

        swapper = new TokenSwapper();
        aaveHelper = new AAVEHelper(address(myStrategy), ERC20(sUSDe), ERC20(USDT), aStakedUSDe, 2);
        aaveHelperOwner = aaveHelper.owner();
        swapper.setWhitelist(address(myStrategy), true);

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), MAX_USDC_ALLOWED);
        vm.stopPrank();

        vm.startPrank(strategyOwner);
        myStrategy.setSwapper(address(swapper));
        myStrategy.setAAVEHelper(address(aaveHelper));
        vm.stopPrank();
        assertEq(
            IVariableDebtToken(aUSDTDebt).borrowAllowance(address(myStrategy), address(aaveHelper)), type(uint256).max
        );
    }

    function test_sUSDe_GetMaxLTV() public {
        uint256 _ltv = aaveHelper.getMaxLTV();
        // https://app.aave.com/reserve-overview/?underlyingAsset=0x9d39a5de30e57443bff2a8307a4256c8797a3497&marketName=proto_mainnet_v3
        assertEq(_ltv, 9000);
    }

    function test_sUSDe_Basic_Invest_Redeem(uint256 _testVal, uint256 _curveRatio) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _testVal = _assetVal;
        bytes memory EMPTY_CALLDATA;

        uint256 _initSupply = _testVal / 2;
        uint256 _initDebt = _initSupply * 7;

        vm.startPrank(strategist);
        myStrategy.invest(_initSupply, _initDebt, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt, uint256 _totalSupply) = myStrategy.getNetSupplyAndDebt(true);
        uint256 _flashloanFee = TestUtils._applyFlashLoanFee(aaveHelper, _debt);
        uint256 _totalAssets = stkVault.totalAssets();
        console.log("_totalSupply:%d,_initSupply:%d,_initDebt:%d", _totalSupply, _initSupply, _initDebt);
        console.log("_testVal:%d,_flashloanFee:%d,_totalAssets:%d", _testVal, _flashloanFee, _totalAssets);
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _flashloanFee), 2 * myTolerance));
        assertTrue(_assertApproximateEq(_initDebt + _flashloanFee, _debt, 2 * myTolerance));
        assertTrue(_assertApproximateEq(_totalSupply, (_initSupply + _initDebt), 2 * myTolerance));

        _checkBasicInvariants(address(stkVault));

        uint256 _toRedeem = aaveHelper.getMaxRedeemableAmount();
        vm.startPrank(strategist);
        myStrategy.redeem(_toRedeem, EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(ERC20(sUSDe).balanceOf(address(myStrategy)), _toRedeem);

        vm.startPrank(strategist);
        uint256 _repayAmount = myStrategy.convertSupplyToRepay();
        vm.stopPrank();
        assertEq(ERC20(sUSDe).balanceOf(address(myStrategy)), 0);

        (, uint256 _debt2,) = myStrategy.getNetSupplyAndDebt(true);
        console.log("_debt2:%d,_repayAmount:%d,_debt:%d", _debt2, _repayAmount, _debt);
        assertTrue(_assertApproximateEq(_debt2 + _repayAmount, _debt, 2 * myTolerance));

        _checkBasicInvariants(address(stkVault));
    }

    function test_sUSDe_Leverage_Collect_Everything(uint256 _testVal) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _testVal = _assetVal;
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        uint256 _flashloanFee = TestUtils._applyFlashLoanFee(aaveHelper, _debt);
        uint256 _totalAssets = stkVault.totalAssets();
        console.log("_testVal:%d,_totalAssets:%d,_flashloanFee:%d", _testVal, _totalAssets, _flashloanFee);
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _flashloanFee), 2 * myTolerance));

        uint256 _residue = ERC20(USDC).balanceOf(address(stkVault));
        console.log("_residue:%d,_netSupply:%d", _residue, _netSupply);
        assertTrue(_assertApproximateEq(_testVal, (_residue + _netSupply + _flashloanFee), 2 * myTolerance));

        _checkBasicInvariants(address(stkVault));

        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();

        _totalAssets = stkVault.totalAssets();
        console.log("_totalAssets:%d", _totalAssets);
        assertTrue(_assertApproximateEq(_testVal, (_totalAssets + _flashloanFee * 2), 2 * myTolerance));

        (uint256 _ltv,) = _printAAVEPosition();
        assertEq(_ltv, 0);

        _residue = ERC20(USDC).balanceOf(address(stkVault));
        console.log("_residue:%d", _residue);
        assertTrue(_assertApproximateEq(_residue, _totalAssets, 2 * myTolerance));

        _checkBasicInvariants(address(stkVault));

        vm.startPrank(stkVOwner);
        stkVault.removeStrategy(address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();

        assertEq(stkVault.strategyAllocations(address(myStrategy)), 0);
    }

    function test_sUSDe_Leverage_Collect_Portion(uint256 _testVal) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _testVal = _assetVal;
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        myStrategy.allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        uint256 _flashloanFee = TestUtils._applyFlashLoanFee(aaveHelper, _debt);
        assertTrue(_assertApproximateEq(_testVal, (stkVault.totalAssets() + _flashloanFee), 2 * myTolerance));

        assertTrue(
            _assertApproximateEq(
                _testVal, (ERC20(USDC).balanceOf(address(stkVault)) + _netSupply + _flashloanFee), 2 * myTolerance
            )
        );

        uint256 _vltBal = ERC20(USDC).balanceOf(address(stkVault));

        uint256 _portionVal = _testVal / 10;
        vm.startPrank(strategist);
        myStrategy.collect(_portionVal, EMPTY_CALLDATA);
        vm.stopPrank();
        assertTrue(_assertApproximateEq(_testVal, stkVault.totalAssets(), 2 * myTolerance));

        uint256 _portionVal2 = _portionVal * 3;
        vm.startPrank(strategist);
        myStrategy.collect(_portionVal2, EMPTY_CALLDATA);
        vm.stopPrank();
        assertTrue(_assertApproximateEq(_testVal, stkVault.totalAssets(), 2 * myTolerance));

        uint256 _vltBal2 = ERC20(USDC).balanceOf(address(stkVault));
        console.log("_vltBal:%d,_vltBal2:%d", _vltBal, _vltBal2);
        console.log("_portionVal:%d,_portionVal2:%d", _portionVal, _portionVal2);
        assertTrue(_assertApproximateEq((_vltBal2 - _vltBal), (_portionVal + _portionVal2), 2 * myTolerance));

        _checkBasicInvariants(address(stkVault));
    }

    function test_sUSDe_Invest_MaxBorrow(uint256 _testVal) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _testVal = _assetVal;
        bytes memory EMPTY_CALLDATA;

        uint256 _initSupply = _testVal / 3;
        vm.startPrank(strategist);
        myStrategy.invest(_initSupply, _initSupply * 3, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _netSupply0, uint256 _debt0,) = myStrategy.getNetSupplyAndDebt(false);

        uint256 _supplied = myStrategy._convertAssetToSupply(_initSupply);
        uint256 _newSupplied = _supplied + _netSupply0;
        uint256 _maxLeveraged = aaveHelper.getSafeLeveragedSupply(_newSupplied);
        uint256 _toBorrowed = _maxLeveraged - _newSupplied - _debt0;
        vm.startPrank(strategist);
        myStrategy.invest(_initSupply, type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        (uint256 _netSupply, uint256 _debt, uint256 _totalSupply) = myStrategy.getNetSupplyAndDebt(false);
        console.log("_maxLeveraged:%d,_newSupplied:%d", _maxLeveraged, _newSupplied);
        console.log("_totalSupply:%d,_netSupply:%d", _totalSupply, _netSupply);

        assertTrue(
            _assertApproximateEq(
                (_maxLeveraged * Constants.TOTAL_BPS / _newSupplied),
                (_totalSupply * Constants.TOTAL_BPS / _netSupply),
                COMP_TOLERANCE
            )
        );

        _checkBasicInvariants(address(stkVault));
    }

    function test_sUSDe_Multiple_Users(uint256 _testVal1, uint256 _testVal2, uint256 _testVal3) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user1 = TestUtils._getSugarUser();
        address _user2 = TestUtils._getSugarUser();
        address _user3 = TestUtils._getSugarUser();
        uint256 _timeElapsed = ONE_DAY_HEARTBEAT / 48;

        // deposit and make investment by looping AAVE from user1
        (uint256 _assetVal1,) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user1, usdcPerETH, _testVal1, 10 ether, 30 ether
        );

        _testVal1 = _assetVal1;
        _makeLoopingInvestment(8);

        // make some debt accured in AAVE
        uint256 _currentTime = block.timestamp;
        vm.warp(_currentTime + _timeElapsed);

        // deposit and make investment by looping into AAVE from user2
        (uint256 _assetVal2,) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user2, usdcPerETH, _testVal2, 10 ether, 30 ether
        );

        _testVal2 = _assetVal2;
        _makeLoopingInvestment(8);

        uint256 _redeemShareVal = stkVault.previewDeposit(ERC20(USDC).balanceOf(address(stkVault))) + myTolerance;
        _makeRedemptionByRedeemFromAAVE(_user1, _redeemShareVal);

        // make some debt accured in AAVE and earn yield in Ether.Fi
        _currentTime = block.timestamp;
        vm.warp(_currentTime + _timeElapsed);

        // deposit and make investment by looping into AAVE from user3
        (uint256 _assetVal3,) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user3, usdcPerETH, _testVal3, 10 ether, 30 ether
        );

        _testVal3 = _assetVal3;
        _makeLoopingInvestment(8);

        _makeRedemptionByRedeemFromAAVE(_user2, _redeemShareVal);

        // make some debt accured in AAVE
        _currentTime = block.timestamp;
        vm.warp(_currentTime + _timeElapsed);

        _makeRedemptionByRedeemFromAAVE(_user3, _redeemShareVal);

        // make some debt accured in AAVE
        _currentTime = block.timestamp;
        vm.warp(_currentTime + _timeElapsed);

        uint256 _totalAssets = stkVault.totalAssets();
        (, uint256 _debt,) = myStrategy.getNetSupplyAndDebt(true);
        uint256 _flashloanFee = TestUtils._applyFlashLoanFee(aaveHelper, _debt);
        bytes memory EMPTY_CALLDATA;

        // sugardaddy strategy to cover the accrued debt
        uint256 _sugar = _totalAssets * 500 / Constants.TOTAL_BPS;
        vm.startPrank(usdcWhale);
        ERC20(USDC).transfer(address(myStrategy), _sugar);
        vm.stopPrank();

        // collect all from this strategy
        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();

        uint256 _totalAssetsAfter = stkVault.totalAssets();
        console.log("_totalAssets:%d,_totalAssetsAfter:%d,_sugar:%d", _totalAssets, _totalAssetsAfter, _sugar);
        assertTrue(_assertApproximateEq((_totalAssets + _sugar), (_totalAssetsAfter + _flashloanFee), 2 * myTolerance));
        _checkBasicInvariants(address(stkVault));
    }

    function test_sUSDe_Invest_Zero_Borrow(uint256 _testVal) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _testVal = _assetVal;
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(stkVOwner);
        stkVault.setEarnRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        uint256 _expectedSupply = myStrategy._convertBorrowToSupply(myStrategy._convertAssetToBorrow(_assetVal));
        vm.startPrank(strategist);
        myStrategy.invest(type(uint256).max, 0, EMPTY_CALLDATA);
        vm.stopPrank();

        (, uint256 _hf) = _printAAVEPosition();
        assertEq(_hf, type(uint256).max);
        assertEq(stkVault.totalAssets(), myStrategy.totalAssets());
        (uint256 _netSupply,,) = myStrategy.getNetSupplyAndDebt(false);
        console.log("_netSupply:%d,_expectedSupply:%d", _netSupply, _expectedSupply);
        assertTrue(_assertApproximateEq(_expectedSupply, _netSupply, 100 * Constants.ONE_ETHER));

        _checkBasicInvariants(address(stkVault));
    }

    function test_sUSDe_Collateral_Price_Dip(uint256 _testVal) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        uint256 _liqThreshold = 9200;
        uint256 _collectPortion = 5000;

        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal,) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _testVal = _assetVal;

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

        assertTrue(
            _assertApproximateEq(
                (1e18 * _liqThreshold / _healthFactor) * 1e16, aaveHelper.getMaxLTV() * 1e16, BIGGER_TOLERANCE * 40
            )
        );

        uint256 _originalPrice = aaveOracle.getAssetPrice(sUSDe);
        (int256 _originalsUSDeToUSDRate,,) = swapper.getPriceFromChainLink(sUSDe_USD_Feed);
        uint256 _originalsUSDeToUSDPrice = uint256(_originalsUSDeToUSDRate);
        (uint256 _netSupply,,) = myStrategy.getNetSupplyAndDebt(true);

        // price dip 1.5% -> LTV exceed maximum allowed -> collect() to reduce LTV
        vm.mockCall(
            address(aaveOracle),
            abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, address(sUSDe)),
            abi.encode(_originalPrice * 9850 / Constants.TOTAL_BPS)
        );
        vm.mockCall(
            address(swapper),
            abi.encodeWithSelector(TokenSwapper.getPriceFromChainLink.selector, sUSDe_USD_Feed),
            abi.encode(_originalsUSDeToUSDPrice * 9850 / Constants.TOTAL_BPS, block.timestamp, 18)
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

        // price dip 3% -> LTV exceed maximum allowed -> collect() to reduce LTV
        vm.mockCall(
            address(aaveOracle),
            abi.encodeWithSelector(IPriceOracleGetter.getAssetPrice.selector, address(sUSDe)),
            abi.encode(_originalPrice * 9700 / Constants.TOTAL_BPS)
        );
        vm.mockCall(
            address(swapper),
            abi.encodeWithSelector(TokenSwapper.getPriceFromChainLink.selector, sUSDe_USD_Feed),
            abi.encode(_originalsUSDeToUSDPrice * 9700 / Constants.TOTAL_BPS, block.timestamp, 18)
        );
        (_ltv, _healthFactor) = _printAAVEPosition();
        assertTrue((1e18 * _liqThreshold / _healthFactor) > aaveHelper.getMaxLTV());
        vm.startPrank(strategist);
        myStrategy.collect(_netSupply * _collectPortion / Constants.TOTAL_BPS, EMPTY_CALLDATA);
        vm.stopPrank();
        (_ltv, _healthFactor) = _printAAVEPosition();
        assertTrue((1e18 * _liqThreshold / _healthFactor) < aaveHelper.getMaxLTV());
        (_netSupply,,) = myStrategy.getNetSupplyAndDebt(false);

        (_ltv, _healthFactor) = _printAAVEPosition();
        assertEq(0, _ltv);
        assertEq(0, myStrategy.totalAssets());

        _checkBasicInvariants(address(stkVault));

        vm.clearMockedCalls();
    }

    function test_sUSDe_Edge_Branches(uint256 _testVal) public {
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        (uint256 _assetVal,) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );
        _testVal = _assetVal;
        bytes memory EMPTY_CALLDATA;

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_CALLER.selector);
        myStrategy.executeOperation(USDC, 0, 1, strategist, EMPTY_CALLDATA);

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_INITIATOR.selector);
        vm.startPrank(address(aavePool));
        myStrategy.executeOperation(USDC, 0, 1, strategist, EMPTY_CALLDATA);
        vm.stopPrank();

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_ASSET.selector);
        vm.startPrank(address(aavePool));
        myStrategy.executeOperation(USDC, 0, 1, address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_PREMIUM.selector);
        vm.startPrank(address(aavePool));
        myStrategy.executeOperation(USDT, 0, 1, address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_AMOUNT.selector);
        vm.startPrank(address(aavePool));
        myStrategy.executeOperation(USDT, type(uint256).max, 0, address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();

        vm.recordLogs();
        vm.startPrank(strategist);
        myStrategy.swapBorrowToVault();
        myStrategy.convertSupplyToRepay();
        vm.stopPrank();
        Vm.Log[] memory logEntries = vm.getRecordedLogs();
        assertEq(0, logEntries.length);

        uint256 _sugar0 = 100 * Constants.ONE_ETHER;
        uint256 _toCollect = MIN_SHARE;
        vm.startPrank(sUSDeWhale);
        ERC20(sUSDe).transfer(address(myStrategy), _sugar0);
        vm.stopPrank();
        uint256[] memory _previewCollects = aaveHelper.previewCollect(_toCollect);
        vm.startPrank(strategist);
        myStrategy.collect(_toCollect, EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(_previewCollects[0], 1);
        assertTrue(ERC20(sUSDe).balanceOf(address(myStrategy)) < _sugar0);

        vm.startPrank(strategist);
        myStrategy.invest(_assetVal, 0, EMPTY_CALLDATA);
        vm.stopPrank();
        (uint256 _netSupply,,) = myStrategy.getNetSupplyAndDebt(false);
        _toCollect = 500 * MIN_SHARE;
        _previewCollects = aaveHelper.previewCollect(_toCollect);
        vm.startPrank(strategist);
        myStrategy.collect(_toCollect, EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(_previewCollects[0], 2);
        (uint256 _netSupplyLater,,) = myStrategy.getNetSupplyAndDebt(false);
        assertTrue(_netSupplyLater < _netSupply);
    }

    function _printAAVEPosition() internal view returns (uint256, uint256) {
        (uint256 _cBase, uint256 _dBase, uint256 _leftBase, uint256 _liqThresh, uint256 _ltv, uint256 _healthFactor) =
            aavePool.getUserAccountData(address(myStrategy));
        console.log("_ltv:%d,_liqThresh:%d,_healthFactor:%d", _ltv, _liqThresh, _healthFactor);
        console.log("_cBase:%d,_dBase:%d,_leftBase:%d", _cBase, _dBase, _leftBase);
        return (_ltv, _healthFactor);
    }

    function _makeLoopingInvestment(uint256 _leverage) internal {
        bytes memory EMPTY_CALLDATA;
        uint256 _availableAsset = stkVault.getAllocationAvailable();
        uint256 _borrowedDebt = _availableAsset * _leverage;
        vm.startPrank(strategist);
        myStrategy.invest(_availableAsset, _borrowedDebt, EMPTY_CALLDATA);
        vm.stopPrank();
        _checkBasicInvariants(address(stkVault));
    }

    function _makeRedemptionByRedeemFromAAVE(address _user, uint256 _share) internal {
        bytes memory EMPTY_CALLDATA;
        uint256 _redemptionShare = _share;
        uint256 _redemptioRequested = TestUtils._makeRedemptionRequest(_user, _redemptionShare, address(stkVault));
        vm.startPrank(strategist);
        myStrategy.invest(0, _redemptionShare, EMPTY_CALLDATA);
        myStrategy.swapBorrowToVault();
        vm.stopPrank();
        TestUtils._claimRedemptionRequest(_user, _redemptionShare, address(stkVault), COMP_TOLERANCE);
    }
}
