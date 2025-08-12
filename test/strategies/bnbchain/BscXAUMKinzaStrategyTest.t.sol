// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../../src/SparkleXVault.sol";
import {CollYieldAAVEStrategy} from "../../../src/strategies/aave/CollYieldAAVEStrategy.sol";
import {AAVEHelper} from "../../../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapper} from "../../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";
import {IPriceOracleGetter} from "../../../interfaces/aave/IPriceOracleGetter.sol";
import {TestUtils} from "../../TestUtils.sol";
import {Constants} from "../../../src/utils/Constants.sol";
import {DummyDEXRouter} from "../../mock/DummyDEXRouter.sol";
import {DummyStrategy} from "../../mock/DummyStrategy.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path BscXAUMKinzaStrategyTest -vvv
contract BscXAUMKinzaStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    SparkleXVault public spUSDVault;
    CollYieldAAVEStrategy public myStrategy;
    TokenSwapper public swapper;
    AAVEHelper public aaveHelper;
    address public stkVOwner;
    address public strategist;
    address public aaveHelperOwner;
    address public strategyOwner;
    DummyDEXRouter public mockRouter;

    address XAUM = 0x23AE4fd8E7844cdBc97775496eBd0E8248656028;
    IAaveOracle aaveOracle = IAaveOracle(0xec203E7676C45455BF8cb43D28F9556F014Ab461);
    IPool aavePool = IPool(0xcB0620b181140e57D1C0D8b724cde623cA963c8C);
    ERC20 kXAUM = ERC20(0xC390614e71512B2Aa9D91AfA7E183cb00EB92518);
    address USDC_BNB = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address USDT_BNB = 0x55d398326f99059fF775485246999027B3197955;
    address USDC_USD_Feed_BNB = 0x51597f405303C4377E36123cBc172b13269EA163;
    address USDT_USD_Feed_BNB = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address XAUM_Whale = 0xD5D2cAbE2ab21D531e5f96f1AeeF26D79f4b6583;
    address USDC_Whale = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    uint256 public xaumPerBNB = 25e16; // 1 BNB worth one quarter of 1 XAUM
    address XAUM_USDT_POOL = 0x497E224d7008fE47349035ddd98beDB773e1f4C5;
    address USDT_USDC_POOL = 0x92b7807bF19b7DDdf89b706143896d05228f3121;
    address XAU_USD_Feed_BNB = 0x86896fEB19D8A607c3b11f2aF50A0f239Bd71CD0;
    uint256 constant _liqThreshold = 8500;

    // events to check

    function setUp() public {
        _createForkBNBChain(uint256(vm.envInt("TESTNET_FORK_BSC_HEIGHT")));

        wETH = payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

        swapper = new TokenSwapper();
        mockRouter = new DummyDEXRouter();

        stkVault = new SparkleXVault(ERC20(XAUM), "Sparkle XAU Vault", "spXAU");
        spUSDVault = SparkleXVault(0x4055C15cb757E7823097bfBFa5095E711863d15c);
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);

        myStrategy = new CollYieldAAVEStrategy(address(stkVault), XAU_USD_Feed_BNB, address(spUSDVault), 601);
        strategist = myStrategy.strategist();
        assertEq(address(stkVault), myStrategy.vault());
        assertEq(stkVault.asset(), myStrategy.asset());
        strategyOwner = myStrategy.owner();

        aaveHelper = new AAVEHelper(address(myStrategy), ERC20(XAUM), ERC20(USDC_BNB), kXAUM, 0);
        aaveHelperOwner = aaveHelper.owner();

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), MAX_ETH_ALLOWED);
        vm.stopPrank();

        vm.startPrank(strategyOwner);
        myStrategy.setSwapper(address(swapper));
        myStrategy.setAAVEHelper(address(aaveHelper));
        vm.stopPrank();

        vm.startPrank(swapper.owner());
        swapper.setWhitelist(address(myStrategy), true);
        vm.stopPrank();

        assertFalse(aaveHelper.loopingBorrow());
    }

    function test_XAUM_GetMaxLTV() public {
        uint256 _ltv = aaveHelper.getMaxLTV();
        // https://app.kinza.finance/#/details/XAUM
        assertEq(_ltv, 8000);
    }

    function test_XAUM_Invest_Redeem_Repay(uint256 _testVal) public {
        _prepareSwapForMockRouter(mockRouter, wETH, XAUM, XAUM_Whale, xaumPerBNB);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), xaumPerBNB);
        address _user = TestUtils._getSugarUser();

        (uint256 _deposited, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, xaumPerBNB, _testVal, 4 ether, 20 ether
        );

        uint256 _totalAsset = stkVault.totalAssets();
        uint256 _maxBorrow = myStrategy._convertSupplyToBorrow(aaveHelper.getSafeLeveragedSupply(_totalAsset));
        bytes memory EMPTY_CALLDATA;
        uint256 _maxLTV = aaveHelper.getMaxLTV();

        vm.startPrank(strategist);
        myStrategy.invest(_totalAsset, _maxBorrow, EMPTY_CALLDATA);
        vm.stopPrank();
        (, uint256 _healthFactor) = _printAAVEPosition();
        assertTrue(
            _assertApproximateEq((1e18 * _liqThreshold / _healthFactor) * 1e16, _maxLTV * 1e16, 200 * BIGGER_TOLERANCE)
        );

        uint256 _maxRedeem = aaveHelper.getMaxRedeemableAmount();
        assertTrue(_maxRedeem > 0);
        vm.startPrank(strategist);
        myStrategy.redeem(_maxRedeem, EMPTY_CALLDATA);
        vm.stopPrank();
        (, uint256 _healthFactor2) = _printAAVEPosition();
        assertTrue(_healthFactor2 < _healthFactor);

        // collect from spUSD and repay the debt
        uint256 _spUSDBal = spUSDVault.balanceOf(address(myStrategy));
        vm.startPrank(strategist);
        myStrategy.requestWithdrawalFromSpUSD(_spUSDBal / 2);
        myStrategy.claimAndRepay(ERC20(USDC_BNB).balanceOf(address(myStrategy)));
        vm.stopPrank();
        (, uint256 _healthFactor3) = _printAAVEPosition();
        assertTrue(_healthFactor3 > _healthFactor);
        assertTrue(_spUSDBal > spUSDVault.balanceOf(address(myStrategy)));
    }

    function test_XAUM_Collect_Everything(uint256 _testVal) public {
        _prepareSwapForMockRouter(mockRouter, wETH, XAUM, XAUM_Whale, xaumPerBNB);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), xaumPerBNB);
        address _user = TestUtils._getSugarUser();

        (uint256 _deposited, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, xaumPerBNB, _testVal, 4 ether, 20 ether
        );

        uint256 _totalAsset = stkVault.totalAssets();
        uint256 _maxBorrow = myStrategy._convertSupplyToBorrow(aaveHelper.getSafeLeveragedSupply(_totalAsset));
        bytes memory EMPTY_CALLDATA;
        uint256 _maxLTV = aaveHelper.getMaxLTV();

        vm.startPrank(strategist);
        myStrategy.invest(_totalAsset, _maxBorrow, EMPTY_CALLDATA);
        vm.stopPrank();

        _sugardaddySPUSD();

        // collect all from spUSD and clear the debt to collect everything
        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        myStrategy.claimAndRepay(type(uint256).max);
        vm.stopPrank();
        (, uint256 _healthFactor) = _printAAVEPosition();
        assertEq(_healthFactor, type(uint256).max);
        (uint256 _netSupply,,) = myStrategy.getNetSupplyAndDebt(true);
        assertEq(_netSupply, myStrategy.totalAssets());
    }

    function test_XAUM_Collect_Portion(uint256 _testVal) public {
        _prepareSwapForMockRouter(mockRouter, wETH, XAUM, XAUM_Whale, xaumPerBNB);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), xaumPerBNB);
        address _user = TestUtils._getSugarUser();

        (uint256 _deposited, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, xaumPerBNB, _testVal, 4 ether, 20 ether
        );

        uint256 _totalAsset = stkVault.totalAssets();
        uint256 _maxBorrow = myStrategy._convertSupplyToBorrow(aaveHelper.getSafeLeveragedSupply(_totalAsset));
        bytes memory EMPTY_CALLDATA;
        uint256 _maxLTV = aaveHelper.getMaxLTV();

        vm.startPrank(strategist);
        myStrategy.invest(_totalAsset, _maxBorrow, EMPTY_CALLDATA);
        vm.stopPrank();
        (, uint256 _debtInAsset,) = myStrategy.getNetSupplyAndDebt(true);

        uint256 _portions = 5;
        uint256 _collectPortion = _totalAsset / _portions;

        // collect from spUSD and repay the debt to collect some collateral
        for (uint256 i = 0; i < _portions; i++) {
            if (i == _portions - 1) {
                _sugardaddySPUSD();
            }
            vm.startPrank(strategist);
            myStrategy.collect(_collectPortion, EMPTY_CALLDATA);
            myStrategy.claimAndRepay(type(uint256).max);
            vm.stopPrank();
            (, uint256 _healthFactor) = _printAAVEPosition();
            if (_healthFactor == type(uint256).max) {
                break;
            }
        }
        (uint256 _netSupply,,) = myStrategy.getNetSupplyAndDebt(true);
        assertEq(_netSupply, myStrategy.totalAssets());
    }

    function test_XAUM_spUSD_WaitClaim(uint256 _testVal) public {
        _prepareSwapForMockRouter(mockRouter, wETH, XAUM, XAUM_Whale, xaumPerBNB);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), xaumPerBNB);
        address _user = TestUtils._getSugarUser();

        (uint256 _deposited, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, xaumPerBNB, _testVal, 4 ether, 20 ether
        );

        DummyStrategy _dummyStrategy = new DummyStrategy(USDC_BNB, address(spUSDVault));
        vm.startPrank(spUSDVault.owner());
        spUSDVault.addStrategy(address(_dummyStrategy), MAX_ETH_ALLOWED);
        vm.stopPrank();

        bytes memory EMPTY_CALLDATA;
        vm.startPrank(strategist);
        myStrategy.invest(_deposited, type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        _dummyStrategy.allocate(spUSDVault.getAllocationAvailableForStrategy(address(_dummyStrategy)), EMPTY_CALLDATA);

        _sugardaddySPUSD();

        uint256 _spUSDVal = spUSDVault.balanceOf(address(myStrategy));
        assertTrue(_spUSDVal > 0);
        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(_spUSDVal, myStrategy.getPendingWithdrawSpUSD());
        assertEq(0, myStrategy.assetsInCollection());

        vm.startPrank(address(_dummyStrategy));
        ERC20(USDC_BNB).approve(address(_dummyStrategy), type(uint256).max);
        _dummyStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();

        uint256 _worthDebtVal = spUSDVault.convertToAssets(_spUSDVal);
        console.log("_spUSDVal:%d,_worthDebtVal:%d", _spUSDVal, _worthDebtVal);
        (, uint256 _debtInAsset,) = myStrategy.getNetSupplyAndDebt(false);
        uint256 _debtVal = myStrategy._convertAmount(XAUM, _debtInAsset, USDC_BNB);
        console.log("_debtInAsset:%d,_debtVal:%d", _debtInAsset, _debtVal);
        assertTrue(_worthDebtVal > _debtVal);

        vm.startPrank(strategist);
        myStrategy.claimWithdrawFromSpUSD();
        myStrategy.claimAndRepay(type(uint256).max);
        vm.stopPrank();
        assertEq(0, myStrategy.getPendingWithdrawSpUSD());
        (, uint256 _healthFactor) = _printAAVEPosition();
        assertEq(_healthFactor, type(uint256).max);
    }

    function test_XAUM_Switch_Borrow(uint256 _testVal) public {
        test_XAUM_Collect_Everything(_testVal);

        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(0, myStrategy.totalAssets());
        assertEq(spUSDVault.balanceOf(address(myStrategy)), 0);

        // change from USDC to USDT as borrow token
        vm.startPrank(aaveHelperOwner);
        aaveHelper.setTokens(ERC20(XAUM), ERC20(USDT_BNB), kXAUM, 0);
        vm.stopPrank();
        assertEq(address(aaveHelper._borrowToken()), USDT_BNB);

        vm.startPrank(strategist);
        myStrategy.approveAllowanceForHelper();
        myStrategy.setBorrowToSPUSDPool(USDT_USDC_POOL, Constants.ZRO_ADDR);
        myStrategy.invest(
            stkVault.getAllocationAvailableForStrategy(address(myStrategy)), type(uint256).max, EMPTY_CALLDATA
        );
        vm.stopPrank();
        assertTrue(spUSDVault.balanceOf(address(myStrategy)) > 0);

        _sugardaddySPUSD();

        // collect all from spUSD and clear the debt to collect everything
        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        myStrategy.claimAndRepay(type(uint256).max);
        vm.stopPrank();
        (, uint256 _healthFactor) = _printAAVEPosition();
        assertEq(_healthFactor, type(uint256).max);
    }

    function test_XAUM_Compound(uint256 _testVal) public {
        _prepareSwapForMockRouter(mockRouter, wETH, XAUM, XAUM_Whale, xaumPerBNB);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), xaumPerBNB);
        address _user = TestUtils._getSugarUser();

        (uint256 _deposited, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, xaumPerBNB, _testVal, 4 ether, 20 ether
        );

        uint256 _totalAsset = stkVault.totalAssets();
        uint256 _maxBorrow = myStrategy._convertSupplyToBorrow(aaveHelper.getSafeLeveragedSupply(_totalAsset));
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        myStrategy.invest(_totalAsset, _maxBorrow, EMPTY_CALLDATA);
        vm.stopPrank();
        uint256 _spUSDVal = spUSDVault.balanceOf(address(myStrategy));
        uint256 _spUSDWorth = spUSDVault.convertToAssets(_spUSDVal);

        _sugardaddySPUSD();
        uint256 _profit = spUSDVault.convertToAssets(_spUSDVal) - _spUSDWorth;
        uint256 _profitShare = spUSDVault.convertToShares(_profit);

        // prepare for compounding
        uint256 _assetBal = ERC20(XAUM).balanceOf(address(myStrategy));
        assertEq(_assetBal, 0);

        vm.expectRevert(Constants.BORROW_SWAP_POOL_INVALID.selector);
        vm.startPrank(strategist);
        myStrategy.swapViaUniswap(address(spUSDVault), 1, USDT_USDC_POOL, XAUM_USDT_POOL);
        vm.stopPrank();

        vm.startPrank(strategist);
        myStrategy.setBorrowSwapPoolApproval(USDT_USDC_POOL, true);
        myStrategy.setBorrowSwapPoolApproval(XAUM_USDT_POOL, true);
        uint256 _withdrawnProfit = myStrategy.requestWithdrawalFromSpUSD(_profitShare);
        myStrategy.swapViaUniswap(USDC_BNB, _withdrawnProfit, USDT_USDC_POOL, XAUM_USDT_POOL);
        vm.stopPrank();
        _assetBal = ERC20(XAUM).balanceOf(address(myStrategy));
        assertTrue(_assetBal > 0);
    }

    function test_XAUM_Edge_Cases(uint256 _testVal) public {}

    function _printAAVEPosition() internal view returns (uint256, uint256) {
        (uint256 _cBase, uint256 _dBase, uint256 _leftBase, uint256 _liqThresh, uint256 _ltv, uint256 _healthFactor) =
            aavePool.getUserAccountData(address(myStrategy));
        console.log("_ltv:%d,_liqThresh:%d,_healthFactor:%d", _ltv, _liqThresh, _healthFactor);
        console.log("_cBase:%d,_dBase:%d,_leftBase:%d", _cBase, _dBase, _leftBase);
        return (_ltv, _healthFactor);
    }

    function _sugardaddySPUSD() internal {
        // sugardaddy some yield profit for spUSD
        vm.startPrank(USDC_Whale);
        ERC20(USDC_BNB).transfer(address(spUSDVault), spUSDVault.totalAssets() * 500 / Constants.TOTAL_BPS);
        vm.stopPrank();
    }
}
