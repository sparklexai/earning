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
    IAaveOracle aaveOracle =
        IAaveOracle(0xec203E7676C45455BF8cb43D28F9556F014Ab461);
    IPool aavePool = IPool(0xcB0620b181140e57D1C0D8b724cde623cA963c8C);
    ERC20 kXAUM = ERC20(0xC390614e71512B2Aa9D91AfA7E183cb00EB92518);
    address USDC_BNB = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address USDC_USD_Feed_BNB = 0x51597f405303C4377E36123cBc172b13269EA163;
    address XAUM_Whale = 0xD5D2cAbE2ab21D531e5f96f1AeeF26D79f4b6583;
    uint256 public xaumPerBNB = 25e16; // 1 BNB worth one quarter of 1 XAUM
    
    // Handler for invariant testing
    StrategistHandler public handler;

    function setUp() public {
        _createForkBNBChain(uint256(vm.envInt("TESTNET_FORK_BSC_HEIGHT")));

        wETH = payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

        swapper = new TokenSwapper();
        mockRouter = new DummyDEXRouter();

        stkVault = new SparkleXVault(ERC20(XAUM), "Sparkle XAU Vault", "spXAU");
        spUSDVault = new SparkleXVault(
            ERC20(USDC_BNB),
            "Sparkle USD Vault",
            "spUSD"
        );
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);
        _changeWithdrawFee(stkVOwner, address(spUSDVault), 0);

        myStrategy = new CollYieldAAVEStrategy(
            address(stkVault),
            USDC_USD_Feed_BNB,
            address(spUSDVault),
            901
        );
        strategist = myStrategy.strategist();
        assertEq(address(stkVault), myStrategy.vault());
        assertEq(stkVault.asset(), myStrategy.asset());
        strategyOwner = myStrategy.owner();

        aaveHelper = new AAVEHelper(
            address(myStrategy),
            ERC20(XAUM),
            ERC20(USDC_BNB),
            kXAUM,
            0
        );
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
        handler = new StrategistHandler(
            myStrategy,
            stkVault,
            spUSDVault,
            aaveHelper,
            swapper
        );

        _init_vault();
        
        // Set up target contract for invariant testing
        targetContract(address(handler));
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
    }
    
    ///////////////////////////////
    // Invariant tests
    ///////////////////////////////
    
    /**
     * @dev Invariant: Total assets should always be consistent with allocations
     */
    function invariant_totalAssetsConsistency() public {
        uint256 strategyAssets = myStrategy.totalAssets();
        uint256 vaultAssets = ERC20(XAUM).balanceOf(address(stkVault));
        
        // Strategy assets should be reasonable compared to allocations
        assertTrue(strategyAssets <= stkVault.strategyAllocations(address(myStrategy)));
    }
    
    /**
     * @dev Invariant: Health factor should always be above minimum threshold when leveraged
     */
    function invariant_healthFactorSafety() public {
        uint256 healthFactor = handler.getCurrentHealthFactor();
        uint256 totalDebt = handler.getGhostTotalDebtInAAVE();
        
        // If there's debt, health factor should be reasonable (above 1.1)
        if (totalDebt > 0) {
            assertTrue(healthFactor >= 1.1e18 || healthFactor == type(uint256).max);
        }
    }
    
    /**
     * @dev Invariant: Ghost variables should track real state accurately
     */
    function invariant_ghostVariablesAccuracy() public {
        // Total allocated should be >= total collected (can't collect more than allocated)
        assertTrue(handler.getGhostTotalAllocated() >= handler.getGhostTotalCollected());
        
        // Net flow should be reasonable
        int256 netFlow = handler.getGhostNetFlow();
        uint256 strategyAssets = myStrategy.totalAssets();
        
        // Net positive flow should correlate with strategy assets
        if (netFlow > 0) {
            assertTrue(strategyAssets > 0);
        }
    }
    
    /**
     * @dev Invariant: AAVE debt should not exceed borrowed amounts
     */
    function invariant_debtConsistency() public {
        uint256 totalBorrowed = handler.getGhostTotalBorrowedFromAAVE();
        uint256 totalRepaid = handler.getGhostTotalRepaidToAAVE();
        uint256 currentDebt = handler.getGhostTotalDebtInAAVE();
        
        // Current debt should be approximately borrowed - repaid (allowing for interest)
        if (totalBorrowed > totalRepaid) {
            assertTrue(currentDebt >= (totalBorrowed - totalRepaid));
            // Debt shouldn't be unreasonably high due to interest
            assertTrue(currentDebt <= (totalBorrowed - totalRepaid) * 2);
        } else {
            // If we've repaid more than borrowed, debt should be zero or very small
            assertTrue(currentDebt <= 1e6); // Allow for small rounding errors
        }
    }
    
    /**
     * @dev Invariant: Strategy should never hold more than allocated amount
     */
    function invariant_allocationLimits() public {
        uint256 strategyAssets = myStrategy.totalAssets();
        uint256 maxAllocation = stkVault.strategyAllocations(address(myStrategy));
        
        // Strategy assets should not exceed maximum allocation
        assertTrue(strategyAssets <= maxAllocation);
    }
    
    /**
     * @dev Invariant: spUSD operations should be consistent
     */
    function invariant_spUSDConsistency() public {
        uint256 pendingWithdraw = myStrategy.getPendingWithdrawSpUSD();
        uint256 spUSDBalance = ERC20(address(spUSDVault)).balanceOf(address(myStrategy));
        
        // If there's a pending withdrawal, we should have some spUSD shares or have withdrawn
        // This is a logical consistency check
        assertTrue(pendingWithdraw == 0 || spUSDBalance > 0 || handler.getGhostTotalSpUSDWithdrawn() > 0);
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
    }
}
