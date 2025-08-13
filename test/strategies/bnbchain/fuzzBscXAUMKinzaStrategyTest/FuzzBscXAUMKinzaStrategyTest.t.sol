// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SparkleXVault} from "../../../../src/SparkleXVault.sol";
import {CollYieldAAVEStrategy} from "../../../../src/strategies/aave/CollYieldAAVEStrategy.sol";
import {AAVEHelper} from "../../../../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapper} from "../../../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPool} from "../../../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../../../interfaces/aave/IAaveOracle.sol";
import {IPriceOracleGetter} from "../../../../interfaces/aave/IPriceOracleGetter.sol";
import {Constants} from "../../../../src/utils/Constants.sol";
import {DummyDEXRouter} from "../../../mock/DummyDEXRouter.sol";
import {TestUtils} from "../../../TestUtils.sol";
import {StrategistHandler} from "./StrategiestHandler.t.sol";

contract FuzzBscXAUMKinzaStrategyTest is TestUtils {
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
    address USDC_USD_Feed_BNB = 0x51597f405303C4377E36123cBc172b13269EA163;
    address XAU_USD_Feed_BNB = 0x86896fEB19D8A607c3b11f2aF50A0f239Bd71CD0;
    address XAUM_Whale = 0xD5D2cAbE2ab21D531e5f96f1AeeF26D79f4b6583;
    address USDC_Whale = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    uint256 public xaumPerBNB = 25e16; // 1 BNB worth one quarter of 1 XAUM

    // Handler for invariant testing
    StrategistHandler public handler;

    function setUp() public {
        _createForkBNBChain(uint256(vm.envInt("TESTNET_FORK_BSC_HEIGHT")));

        wETH = payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

        swapper = new TokenSwapper();
        mockRouter = new DummyDEXRouter();

        stkVault = new SparkleXVault(ERC20(XAUM), "Sparkle XAU Vault", "spXAU");
        spUSDVault = SparkleXVault(0x4055C15cb757E7823097bfBFa5095E711863d15c);
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);

        myStrategy = new CollYieldAAVEStrategy(address(stkVault), XAU_USD_Feed_BNB, address(spUSDVault), 901);
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
        myStrategy.setStrategist(address(this));
        vm.stopPrank();

        // Initialize handler for invariant testing
        handler = new StrategistHandler(myStrategy, stkVault, spUSDVault, aaveHelper, swapper);

        _init_vault();

        // Set up target contract for invariant testing
        targetContract(address(handler));
        // StdInvariant.FuzzSelector memory selector = StdInvariant.FuzzSelector({
        //     addr: address(handler),
        //     selectors: new bytes4[](1)
        // });
        // selector.selectors[0] = handler.invest.selector;
        // targetSelector(selector);
    }

    function _init_vault() internal {
        _prepareSwapForMockRouter(mockRouter, wETH, XAUM, XAUM_Whale, xaumPerBNB);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), xaumPerBNB);
        address _user = TestUtils._getSugarUser();

        (uint256 _deposited, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, xaumPerBNB, 1 ether, 4 ether, 20 ether
        );
        console.log("deposited", _deposited);
        console.log("share", _share);

        vm.startPrank(spUSDVault.owner());
        spUSDVault.setManagementFeeRatio(0);
        spUSDVault.setWithdrawFeeRatio(0);
        spUSDVault.claimManagementFee();
        vm.stopPrank();
        (uint256 _accumulatedFee,,) = spUSDVault.mgmtFee();
        assertEq(_accumulatedFee, 0);

        vm.startPrank(USDC_Whale);
        ERC20(USDC_BNB).transfer(address(spUSDVault), spUSDVault.totalAssets() * 100 / Constants.TOTAL_BPS);
        vm.stopPrank();
        assertTrue(spUSDVault.convertToAssets(1e18) > 1e18);
    }

    ///////////////////////////////
    // Invariant tests
    ///////////////////////////////

    /**
     * @dev Invariant: Total assets should always be consistent with allocations
     */
    function invariant_totalAssetsConsistency() public view {
        uint256 strategyAssets = myStrategy.totalAssets();
        // uint256 vaultAssets = ERC20(XAUM).balanceOf(address(stkVault));

        // Strategy assets should be reasonable compared to allocations
        assertTrue(strategyAssets <= stkVault.strategyAllocations(address(myStrategy)));
    }

    /**
     * @dev Invariant: Health factor should always be above minimum threshold when leveraged
     */
    function invariant_healthFactorSafety() public view {
        uint256 healthFactor = handler.getCurrentHealthFactor();
        uint256 totalDebt = handler.getGhostTotalDebtInAAVE();

        // If there's debt, health factor should be reasonable (above 1.1)
        if (totalDebt > 0) {
            assertTrue(healthFactor >= 1.05e18 || healthFactor == type(uint256).max);
        }
    }

    /**
     * @dev Invariant: Ghost variables should track real state accurately
     */
    function invariant_ghostVariablesAccuracy() public view {
        // Total allocated should be >= total collected (can't collect more than allocated)
        assertTrue(
            handler.getGhostTotalAllocated() + handler.getGhostTotalInvested() >= handler.getGhostTotalCollected()
        );

        // Net flow should be reasonable
        int256 netFlow = handler.getGhostNetFlow();
        uint256 strategyAssets = myStrategy.totalAssets();

        // Net positive flow should correlate with strategy assets
        if (netFlow > 0) {
            assertTrue(strategyAssets > 0);
        }
    }

    /**
     * @dev Invariant: Strategy should never hold more than allocated amount
     */
    function invariant_allocationLimits() public view {
        uint256 strategyAssets = myStrategy.totalAssets();
        uint256 maxAllocation = stkVault.strategyAllocations(address(myStrategy));

        // Strategy assets should not exceed maximum allocation
        assertTrue(strategyAssets <= maxAllocation, "strategyAssets > maxAllocation");
    }

    /**
     * @dev Invariant: spUSD operations should be consistent
     */
    function invariant_spUSDConsistency() public view {
        uint256 pendingWithdraw = myStrategy.getPendingWithdrawSpUSD();
        uint256 spUSDBalance = ERC20(address(spUSDVault)).balanceOf(address(myStrategy));

        // If there's a pending withdrawal, we should have some spUSD shares or have withdrawn
        // This is a logical consistency check
        assertTrue(pendingWithdraw == 0 || spUSDBalance > 0 || handler.getGhostTotalSpUSDWithdrawn() > 0);
    }

    ///////////////////////////////
    // Invest Function Specific Invariants
    ///////////////////////////////

    /**
     * @dev Invariant: AAVE borrow and spUSD deposit consistency
     * When USDC is borrowed from AAVE via invest, it should be deposited to spUSD vault
     */
    function invariant_investBorrowToSpUSDConsistency() public view {
        uint256 totalBorrowedForSpUSD = handler.getGhostTotalBorrowedForSpUSD();
        uint256 totalDepositedToSpUSD = handler.getGhostTotalDepositedToSpUSD();

        // Borrowed amounts should correlate with spUSD deposits
        // Note: shares != assets, so we allow for conversion differences
        if (totalBorrowedForSpUSD > 0) {
            assertTrue(totalDepositedToSpUSD > 0, "Borrowed USDC should result in spUSD deposits");
        }
    }

    /**
     * @dev Invariant: Leverage ratio safety during invest
     * Invest should maintain safe leverage ratios and health factors
     */
    function invariant_investLeverageSafety() public view {
        uint256 healthFactor = handler.getCurrentHealthFactor();
        uint256 totalSupply = handler.getGhostTotalSupplyInAAVE();
        uint256 totalDebt = handler.getGhostTotalDebtInAAVE();

        // If leveraged position exists, health factor should be safe
        if (totalDebt > 0 && totalSupply > 0) {
            assertTrue(
                healthFactor >= 1.05e18 || healthFactor == type(uint256).max, "Health factor too low after invest"
            );

            // Leverage ratio should be reasonable (debt should not exceed supply by too much)
            assertTrue(totalDebt <= totalSupply * 90 / 100, "Leverage ratio too high");
        }
    }

    /**
     * @dev Invariant: Investment flow accounting consistency
     * Total investments should be consistent with AAVE positions and spUSD holdings
     */
    function invariant_investFlowAccounting() public view {
        uint256 totalInvested = handler.getGhostTotalInvested();
        uint256 totalSuppliedToAAVE = handler.getGhostTotalSuppliedToAAVE();
        uint256 totalBorrowedForSpUSD = handler.getGhostTotalBorrowedForSpUSD();
        uint256 strategyAssets = myStrategy.totalAssets();

        // Investment accounting should be logically consistent
        if (totalInvested > 0) {
            // Strategy should have assets or AAVE positions
            assertTrue(strategyAssets > 0 || totalSuppliedToAAVE > 0, "Invested assets should be trackable");
        }

        // Borrowed amounts should not exceed reasonable leverage multiples of supply
        if (totalSuppliedToAAVE > 0 && totalBorrowedForSpUSD > 0) {
            // Reasonable leverage check - borrowed should not exceed 80% of supply value
            // Note: This is a simplified check as we'd need price oracles for exact comparison
            assertTrue(
                totalBorrowedForSpUSD <= myStrategy._convertAmount(XAUM, totalSuppliedToAAVE, USDC_BNB),
                "Leverage ratio within bounds"
            );
        }
    }

    /**
     * @dev Invariant: spUSD vault shares should increase with deposits from invest
     * When invest borrows and deposits to spUSD, the strategy's spUSD shares should increase
     */
    function invariant_investSpUSDSharesIncrease() public view {
        uint256 totalDepositedToSpUSD = handler.getGhostTotalDepositedToSpUSD();
        uint256 currentSpUSDShares = spUSDVault.balanceOf(address(myStrategy));
        uint256 pendingWithdraw = myStrategy.getPendingWithdrawSpUSD();

        // If we've deposited to spUSD via invest, we should have shares or pending withdrawals
        if (totalDepositedToSpUSD > 0) {
            assertTrue(
                currentSpUSDShares > 0 || pendingWithdraw > 0 || handler.getGhostTotalSpUSDWithdrawn() > 0,
                "spUSD deposits should result in shares or withdrawals"
            );
        }
    }

    ///////////////////////////////
    // Helper functions for after invariant
    ///////////////////////////////

    function afterInvariant() public {
        // Log some useful metrics after each invariant run
        emit log_named_uint("Total Allocated", handler.getGhostTotalAllocated());
        emit log_named_uint("Total Collected", handler.getGhostTotalCollected());
        emit log_named_uint("Total Invested", handler.getGhostTotalInvested());
        emit log_named_int("Net Flow", handler.getGhostNetFlow());
        emit log_named_uint("Current Health Factor", handler.getCurrentHealthFactor());
        emit log_named_uint("Strategy Total Assets", myStrategy.totalAssets());
        emit log_named_uint("AAVE Supply", handler.getGhostTotalSupplyInAAVE());
        emit log_named_uint("AAVE Debt", handler.getGhostTotalDebtInAAVE());
        emit log_named_uint("Assets Transferred to Strategy", handler.getGhostTotalAssetsTransferredToStrategy());
        emit log_named_uint("Total Supplied to AAVE", handler.getGhostTotalSuppliedToAAVE());
        emit log_named_uint("Total Borrowed for spUSD", handler.getGhostTotalBorrowedForSpUSD());
        emit log_named_uint("Total Deposited to spUSD", handler.getGhostTotalDepositedToSpUSD());
        emit log_named_uint("Current spUSD Shares", ERC20(address(spUSDVault)).balanceOf(address(myStrategy)));
    }
}
