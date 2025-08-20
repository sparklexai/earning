// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {console} from "forge-std/console.sol";
import {Test} from "forge-std/Test.sol";
import {SparkleXVault} from "../../../../src/SparkleXVault.sol";
import {CollYieldAAVEStrategy} from "../../../../src/strategies/aave/CollYieldAAVEStrategy.sol";
import {AAVEHelper} from "../../../../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapper} from "../../../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Constants} from "../../../../src/utils/Constants.sol";
import {IPool} from "../../../../interfaces/aave/IPool.sol";

contract StrategistHandler is Test {
    ///////////////////////////////
    // Target contracts
    ///////////////////////////////
    CollYieldAAVEStrategy public strategy;
    SparkleXVault public vault;
    SparkleXVault public spUSDVault;
    AAVEHelper public aaveHelper;
    TokenSwapper public swapper;
    ERC20 public asset;
    ERC20 public borrowToken;
    IPool public aavePool = IPool(0xcB0620b181140e57D1C0D8b724cde623cA963c8C);
    uint256 public MIN_ASSET_TO_INVEST = 1e15;
    ERC20 kXAUM = ERC20(0xC390614e71512B2Aa9D91AfA7E183cb00EB92518);

    ///////////////////////////////
    // Ghost variables for invariants
    ///////////////////////////////
    uint256 public ghost_totalAllocated;
    uint256 public ghost_totalCollected;
    uint256 public ghost_totalInvested;
    uint256 public ghost_totalRedeemed;
    uint256 public ghost_totalSpUSDDeposited;
    uint256 public ghost_totalSpUSDWithdrawn;
    uint256 public ghost_totalBorrowedFromAAVE;
    uint256 public ghost_totalRepaidToAAVE;

    // New ghost variables for invest function tracking
    uint256 public ghost_totalAssetsTransferredToStrategy;
    uint256 public ghost_totalSuppliedToAAVE;
    uint256 public ghost_totalBorrowedForSpUSD;
    uint256 public ghost_totalDepositedToSpUSD;

    ///////////////////////////////
    // State tracking
    ///////////////////////////////
    uint256 public ghost_lastHealthFactor;
    uint256 public ghost_totalSupplyInAAVE;
    uint256 public ghost_totalDebtInAAVE;
    uint256 public ghost_spUSDTotalAssets;

    ///////////////////////////////
    // Events for debugging
    ///////////////////////////////
    event HandlerAllocate(uint256 amount, uint256 totalAssetsBefore, uint256 totalAssetsAfter);
    event HandlerCollect(uint256 amount, uint256 totalAssetsBefore, uint256 totalAssetsAfter);
    event HandlerInvest(uint256 assetAmount, uint256 borrowAmount);
    event HandlerRedeem(uint256 amount, uint256 redeemed);
    event HandlerClaimAndRepay(uint256 repayAmount);

    ///////////////////////////////
    // Modifiers
    ///////////////////////////////
    modifier countCall(string memory functionName) {
        _;
    }

    ///////////////////////////////
    // Setup and initialization
    ///////////////////////////////
    constructor(
        CollYieldAAVEStrategy _strategy,
        SparkleXVault _vault,
        SparkleXVault _spUSDVault,
        AAVEHelper _aaveHelper,
        TokenSwapper _swapper
    ) {
        strategy = _strategy;
        vault = _vault;
        spUSDVault = _spUSDVault;
        aaveHelper = _aaveHelper;
        swapper = _swapper;
        asset = ERC20(vault.asset());
        borrowToken = aaveHelper._borrowToken();

        // Initialize ghost variables
        _updateGhostVariables();
        ghost_spUSDTotalAssets = spUSDVault.totalAssets();
        console.log("spUSD_TotalAssets", ghost_spUSDTotalAssets);
    }

    function _updateGhostVariables() internal {
        // Update AAVE position info
        (, uint256 debt, uint256 totalSupply) = strategy.getNetSupplyAndDebt(false);
        ghost_totalSupplyInAAVE = totalSupply;
        ghost_totalDebtInAAVE = debt;

        // Update health factor by calling AAVE pool directly
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(strategy));
        ghost_lastHealthFactor = healthFactor;
    }

    ///////////////////////////////
    // Handler functions - Core Strategy Operations
    ///////////////////////////////

    /**
     * @dev Handler for strategy.allocate() - allocates assets from vault to strategy
     */
    function allocate(uint256 amount) external countCall("allocate") {
        // Bound the amount to reasonable values
        uint256 allocationAvailable = vault.getAllocationAvailableForStrategy(address(strategy));
        console.log("allocationAvailable", allocationAvailable);
        amount = bound(amount, 0, allocationAvailable);

        if (amount < MIN_ASSET_TO_INVEST) return;
        if (!_checkLeverage(amount)) return;

        uint256 totalAssetsBefore = strategy.totalAssets();

        // Ensure vault has enough assets
        uint256 vaultBalance = asset.balanceOf(address(vault));
        if (vaultBalance < amount) {
            // Mint assets to vault if needed
            deal(address(asset), address(vault), amount);
        }

        uint256 spUSDSharesBefore = spUSDVault.balanceOf(address(strategy));
        uint256 supplyBefore = kXAUM.balanceOf(address(strategy));
        (, uint256 debtBefore,) = strategy.getNetSupplyAndDebt(false);

        // Call allocate as strategist
        vm.startPrank(strategy.strategist());
        strategy.allocate(amount, "");
        (, uint256 debtAfter,) = strategy.getNetSupplyAndDebt(false);
        uint256 supplyAfter = kXAUM.balanceOf(address(strategy));

        uint256 spUSDSharesAfter = spUSDVault.balanceOf(address(strategy));

        // Track AAVE supply increase
        if (supplyAfter > supplyBefore) {
            uint256 actualSupplied = supplyAfter - supplyBefore;
            ghost_totalSuppliedToAAVE += actualSupplied;
            ghost_totalAllocated += actualSupplied;
            console.log("allocate", actualSupplied);
        }

        // Track AAVE borrowing
        if (debtAfter > debtBefore) {
            uint256 actualBorrowed = debtAfter - debtBefore;
            ghost_totalBorrowedFromAAVE += actualBorrowed;
            ghost_totalBorrowedForSpUSD += actualBorrowed;
        }

        // Track spUSD deposits
        if (spUSDSharesAfter > spUSDSharesBefore) {
            ghost_totalDepositedToSpUSD += (spUSDSharesAfter - spUSDSharesBefore);
        }

        uint256 totalAssetsAfter = strategy.totalAssets();
        emit HandlerAllocate(amount, totalAssetsBefore, totalAssetsAfter);

        _updateGhostVariables();
        vm.stopPrank();
    }

    /**
     * @dev Handler for strategy.collect() - collects assets from strategy back to vault
     */
    function collect(uint256 amount) external countCall("collect") {
        uint256 totalAssets = strategy.totalAssets();
        console.log("totalAssets-collect", totalAssets);
        if (totalAssets == 0) return;

        // Bound amount to available assets
        amount = bound(amount, 1, totalAssets);

        uint256 totalAssetsBefore = totalAssets;
        uint256 spUSDSharesBefore = spUSDVault.balanceOf(address(strategy));

        // Call collect as strategist
        vm.startPrank(strategy.strategist());
        uint256 _assetBefore = asset.balanceOf(address(vault));
        strategy.collect(amount, "");
        (, uint256 _debt0,) = strategy.getNetSupplyAndDebt(true);
        if (_debt0 > 0) {
            strategy.claimAndRepay(type(uint256).max);
        } else {
            strategy.claimWithdrawFromSpUSD();
        }
        strategy.redeem(amount, "");
        uint256 _assetAfter = asset.balanceOf(address(vault));
        ghost_totalCollected += (_assetAfter - _assetBefore);
        console.log("collect", _assetAfter - _assetBefore);
        (uint256 _netSupply, uint256 _debt,) = strategy.getNetSupplyAndDebt(true);
        console.log("totalAssets-afterCollect", strategy.totalAssets());
        console.log("_netSupply-afterCollect", _netSupply);
        console.log("_debt-afterCollect", _debt);
        uint256 spUSDSharesAfter = spUSDVault.balanceOf(address(strategy));

        // Track spUSD deposits
        if (spUSDSharesAfter < spUSDSharesBefore) {
            ghost_totalSpUSDWithdrawn += (spUSDSharesBefore - spUSDSharesAfter);
        }

        uint256 totalAssetsAfter = strategy.totalAssets();
        emit HandlerCollect(amount, totalAssetsBefore, totalAssetsAfter);

        _updateGhostVariables();
        vm.stopPrank();
    }

    /**
     * @dev Handler for strategy.collectAll() - collects all assets from strategy
     */
    function collectAll() external countCall("collectAll") {
        uint256 totalAssets = strategy.totalAssets();
        console.log("totalAssets-collectAll", totalAssets);
        if (totalAssets == 0) return;
        uint256 spUSDSharesBefore = spUSDVault.balanceOf(address(strategy));

        // Call collectAll as strategist
        (, uint256 _debt0,) = strategy.getNetSupplyAndDebt(true);
        _sugardaddySPUSD(strategy._convertAmount(strategy.asset(), _debt0, spUSDVault.asset()));
        vm.startPrank(strategy.strategist());
        uint256 _assetBefore = asset.balanceOf(address(vault));
        strategy.collectAll("");
        (, _debt0,) = strategy.getNetSupplyAndDebt(true);
        if (_debt0 > 0) {
            strategy.claimAndRepay(type(uint256).max);
        } else {
            strategy.claimWithdrawFromSpUSD();
        }
        strategy.collectAll("");
        uint256 _assetAfter = asset.balanceOf(address(vault));
        ghost_totalCollected += (_assetAfter - _assetBefore);
        console.log("collectAll", _assetAfter - _assetBefore);
        (uint256 _netSupply, uint256 _debt,) = strategy.getNetSupplyAndDebt(true);
        console.log("totalAssets-afterCollectAll", strategy.totalAssets());
        console.log("_netSupply-afterCollectAll", _netSupply);
        console.log("_debt-afterCollectAll", _debt);
        uint256 spUSDSharesAfter = spUSDVault.balanceOf(address(strategy));

        // Track spUSD deposits
        if (spUSDSharesAfter < spUSDSharesBefore) {
            ghost_totalSpUSDWithdrawn += (spUSDSharesBefore - spUSDSharesAfter);
        }

        _updateGhostVariables();
        vm.stopPrank();
    }

    /**
     * @dev Handler for strategy.invest() - direct investment with leverage
     */
    function invest(uint256 assetAmount, uint256 borrowAmount) external countCall("invest") {
        // Bound amounts to reasonable values
        assetAmount = bound(assetAmount, 0, vault.getAllocationAvailableForStrategy(address(strategy)));
        borrowAmount = bound(borrowAmount, 1e6, 1000000 * Constants.ONE_ETHER); // Max 1M USDC

        // Skip if both amounts are zero
        if (assetAmount == 0 && borrowAmount == 0) return;
        if (!_checkLeverage(assetAmount)) return;
        borrowAmount = aaveHelper.previewLeverageForInvest(assetAmount, borrowAmount);
        (uint256 _maxBorrowable,) = aaveHelper.getAvailableBorrowAmount(address(strategy));
        if (assetAmount == 0 && borrowAmount >= _maxBorrowable) {
            return;
        }

        // Ensure vault has enough assets if assetAmount > 0
        if (assetAmount > 0) {
            uint256 vaultBalance = asset.balanceOf(address(vault));
            if (vaultBalance < assetAmount) {
                deal(address(asset), address(vault), assetAmount);
            }
        }

        // Track before state for invariant checking
        // uint256 strategyAssetsBefore = asset.balanceOf(address(strategy));
        uint256 spUSDSharesBefore = ERC20(address(spUSDVault)).balanceOf(address(strategy));
        uint256 supplyBefore = kXAUM.balanceOf(address(strategy));
        (, uint256 debtBefore,) = strategy.getNetSupplyAndDebt(false);

        // Call invest as strategist
        vm.startPrank(strategy.strategist());
        strategy.invest(assetAmount, borrowAmount, "");

        // Track after state and update ghost variables
        // uint256 strategyAssetsAfter = asset.balanceOf(address(strategy));
        uint256 spUSDSharesAfter = ERC20(address(spUSDVault)).balanceOf(address(strategy));
        (, uint256 debtAfter,) = strategy.getNetSupplyAndDebt(false);
        uint256 supplyAfter = kXAUM.balanceOf(address(strategy));

        // Update ghost variables based on actual changes
        if (assetAmount > 0) {
            ghost_totalAssetsTransferredToStrategy += assetAmount;
        }

        // Track AAVE supply increase
        if (supplyAfter > supplyBefore) {
            uint256 actualInvested = supplyAfter - supplyBefore;
            ghost_totalSuppliedToAAVE += actualInvested;
            ghost_totalInvested += actualInvested;
            console.log("invest", actualInvested);
        }

        // Track AAVE borrowing
        if (debtAfter > debtBefore) {
            uint256 actualBorrowed = debtAfter - debtBefore;
            ghost_totalBorrowedFromAAVE += actualBorrowed;
            ghost_totalBorrowedForSpUSD += actualBorrowed;
        }

        // Track spUSD deposits
        if (spUSDSharesAfter > spUSDSharesBefore) {
            ghost_totalDepositedToSpUSD += (spUSDSharesAfter - spUSDSharesBefore);
        }

        emit HandlerInvest(assetAmount, borrowAmount);
        _updateGhostVariables();
        vm.stopPrank();
    }

    /**
     * @dev Handler for strategy.redeem() - redeems collateral from AAVE
     */
    function redeem(uint256 supplyAmount) external countCall("redeem") {
        // Get maximum redeemable amount
        uint256 maxRedeemable;
        maxRedeemable = aaveHelper.getMaxRedeemableAmount();
        if (maxRedeemable == 0) return;
        // Bound amount to maximum redeemable
        supplyAmount = bound(supplyAmount, 0, maxRedeemable);

        if (supplyAmount == 0) {
            return;
        }

        // Call redeem as strategist
        uint256 _assetBefore = asset.balanceOf(address(vault));
        vm.startPrank(strategy.strategist());
        strategy.redeem(supplyAmount, "");
        uint256 _assetAfter = asset.balanceOf(address(vault));
        ghost_totalCollected += (_assetAfter - _assetBefore);
        console.log("redeem", _assetAfter - _assetBefore);
        ghost_totalRedeemed += supplyAmount;
        emit HandlerRedeem(supplyAmount, supplyAmount);
        _updateGhostVariables();
        vm.stopPrank();
    }

    ///////////////////////////////
    // Handler functions - SpUSD Operations
    ///////////////////////////////

    /**
     * @dev Handler for strategy.claimWithdrawFromSpUSD() - claims pending spUSD withdrawals
     */
    // function claimWithdrawFromSpUSD() external countCall("claimWithdrawFromSpUSD") {
    //     uint256 pendingWithdraw = strategy.getPendingWithdrawSpUSD();
    //     if (pendingWithdraw == 0) return;

    //     // Call claim as strategist
    //     vm.startPrank(strategy.strategist());
    //     strategy.claimWithdrawFromSpUSD();
    //     ghost_totalSpUSDWithdrawn += pendingWithdraw;
    //     _updateGhostVariables();
    //     vm.stopPrank();
    // }

    /**
     * @dev Handler for strategy.claimAndRepay() - claims spUSD and repays AAVE debt
     */
    function claimAndRepay(uint256 repayAmount) external countCall("claimAndRepay") {
        // Check if there's debt to repay
        uint256 totalDebt;
        (,, totalDebt) = strategy.getNetSupplyAndDebt(false);

        if (totalDebt == 0) return;

        // Bound repay amount
        repayAmount = bound(repayAmount, 0, totalDebt);

        if (repayAmount == 0) {
            return;
        }
        uint256 spUSDSharesBefore = spUSDVault.balanceOf(address(strategy));

        // Call claimAndRepay as strategist
        vm.startPrank(strategy.strategist());
        strategy.claimAndRepay(repayAmount);
        uint256 spUSDSharesAfter = spUSDVault.balanceOf(address(strategy));

        // Track spUSD deposits
        if (spUSDSharesAfter < spUSDSharesBefore) {
            ghost_totalSpUSDWithdrawn += (spUSDSharesBefore - spUSDSharesAfter);
        }

        ghost_totalRepaidToAAVE += repayAmount;
        emit HandlerClaimAndRepay(repayAmount);
        _updateGhostVariables();
        vm.stopPrank();
    }

    function _checkLeverage(uint256 _assetAmount) internal view returns (bool) {
        (uint256 _netSupply, uint256 _debt,) = strategy.getNetSupplyAndDebt(true);
        uint256 _initSupply = _assetAmount + _netSupply + aaveHelper._supplyToken().balanceOf(address(strategy));
        uint256 _safeLeveraged = aaveHelper.getSafeLeveragedSupply(_initSupply);
        if (_initSupply < MIN_ASSET_TO_INVEST || _safeLeveraged <= _debt) {
            return false;
        } else {
            return true;
        }
    }

    function _sugardaddySPUSD(uint256 _amount) internal {
        // sugardaddy some yield profit for spUSD
        (uint256 _accumulatedFee,, uint256 _lastUpdateTimestamp) = spUSDVault.mgmtFee();
        console.log("_accumulatedFee", _accumulatedFee);
        console.log("_lastUpdateTimestamp", _lastUpdateTimestamp);
        (uint256 _newFee,) = spUSDVault.previewManagementFeeAccumulated(ghost_spUSDTotalAssets, block.timestamp);
        console.log("_newFee", _newFee);
        console.log("block.timestamp", block.timestamp);
        deal(spUSDVault.asset(), address(spUSDVault), _amount * 1000 / Constants.TOTAL_BPS);
    }

    ///////////////////////////////
    // View functions for invariants
    ///////////////////////////////

    function getGhostTotalAllocated() external view returns (uint256) {
        return ghost_totalAllocated;
    }

    function getGhostTotalCollected() external view returns (uint256) {
        return ghost_totalCollected;
    }

    function getGhostTotalInvested() external view returns (uint256) {
        return ghost_totalInvested;
    }

    function getGhostNetFlow() external view returns (int256) {
        return int256(ghost_totalAllocated + ghost_totalInvested) - int256(ghost_totalCollected);
    }

    function getCurrentHealthFactor() external view returns (uint256) {
        return ghost_lastHealthFactor;
    }

    function getGhostTotalSupplyInAAVE() external view returns (uint256) {
        return ghost_totalSupplyInAAVE;
    }

    function getGhostTotalDebtInAAVE() external view returns (uint256) {
        return ghost_totalDebtInAAVE;
    }

    function getGhostTotalBorrowedFromAAVE() external view returns (uint256) {
        return ghost_totalBorrowedFromAAVE;
    }

    function getGhostTotalRepaidToAAVE() external view returns (uint256) {
        return ghost_totalRepaidToAAVE;
    }

    function getGhostTotalSpUSDWithdrawn() external view returns (uint256) {
        return ghost_totalSpUSDWithdrawn;
    }

    // New getter functions for invest tracking
    function getGhostTotalAssetsTransferredToStrategy() external view returns (uint256) {
        return ghost_totalAssetsTransferredToStrategy;
    }

    function getGhostTotalSuppliedToAAVE() external view returns (uint256) {
        return ghost_totalSuppliedToAAVE;
    }

    function getGhostTotalBorrowedForSpUSD() external view returns (uint256) {
        return ghost_totalBorrowedForSpUSD;
    }

    function getGhostTotalDepositedToSpUSD() external view returns (uint256) {
        return ghost_totalDepositedToSpUSD;
    }
}
