// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

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
    
    ///////////////////////////////
    // Actors management
    ///////////////////////////////
    address[] public actors;
    address internal currentActor;
    
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
    
    mapping(address => uint256) public ghost_userAllocations;
    mapping(address => uint256) public ghost_userCollections;
    mapping(address => uint256) public ghost_userInvestments;
    
    ///////////////////////////////
    // State tracking
    ///////////////////////////////
    uint256 public ghost_lastHealthFactor;
    uint256 public ghost_totalSupplyInAAVE;
    uint256 public ghost_totalDebtInAAVE;
    
    ///////////////////////////////
    // Events for debugging
    ///////////////////////////////
    event HandlerAllocate(address actor, uint256 amount, uint256 totalAssetsBefore, uint256 totalAssetsAfter);
    event HandlerCollect(address actor, uint256 amount, uint256 totalAssetsBefore, uint256 totalAssetsAfter);
    event HandlerInvest(address actor, uint256 assetAmount, uint256 borrowAmount);
    event HandlerRedeem(address actor, uint256 amount, uint256 redeemed);
    event HandlerClaimAndRepay(address actor, uint256 repayAmount);
    
    ///////////////////////////////
    // Modifiers
    ///////////////////////////////
    modifier useActor(uint256 actorIndexSeed) {
        if (actors.length > 0) {
            currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
            vm.startPrank(currentActor);
        }
        _;
        if (actors.length > 0) {
            vm.stopPrank();
        }
    }
    
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
        
        // Initialize actors
        _initializeActors();
        
        // Initialize ghost variables
        _updateGhostVariables();
    }
    
    function _initializeActors() internal {
        // Add some default actors
        actors.push(address(0x1111));
        // actors.push(address(0x2222));
        // actors.push(address(0x3333));
        // actors.push(address(0x4444));
        // actors.push(address(0x5555));
        
        // Give actors some initial balance
        for (uint256 i = 0; i < actors.length; i++) {
            vm.deal(actors[i], 100 ether);
            deal(address(asset), actors[i], 1000e18);
            deal(address(borrowToken), actors[i], 1000e18);
        }
        vm.prank(strategy.owner());
        strategy.setStrategist(actors[0]);
    }

    function _updateGhostVariables() internal {
        // Update AAVE position info
        try strategy.getNetSupplyAndDebt(false) returns (uint256 netSupply, uint256 debt, uint256 totalSupply) {
            ghost_totalSupplyInAAVE = totalSupply;
            ghost_totalDebtInAAVE = debt;
        } catch {
            // Handle case where strategy is not initialized
        }
        
        // Update health factor by calling AAVE pool directly
        try IPool(0xcB0620b181140e57D1C0D8b724cde623cA963c8C).getUserAccountData(address(strategy)) returns (
            uint256, uint256, uint256, uint256, uint256, uint256 healthFactor
        ) {
            ghost_lastHealthFactor = healthFactor;
        } catch {
            ghost_lastHealthFactor = type(uint256).max; // No debt case
        }
    }
    
    ///////////////////////////////
    // Handler functions - Core Strategy Operations
    ///////////////////////////////
    
    /**
     * @dev Handler for strategy.allocate() - allocates assets from vault to strategy
     */
    function allocate(uint256 amount, uint256 actorIndexSeed) external useActor(actorIndexSeed) countCall("allocate") {
        // Bound the amount to reasonable values
        amount = bound(amount, 1e6, vault.getAllocationAvailableForStrategy(address(strategy)));
        
        if (amount == 0) return;
        
        uint256 totalAssetsBefore = strategy.totalAssets();
        
        // Ensure vault has enough assets
        uint256 vaultBalance = asset.balanceOf(address(vault));
        if (vaultBalance < amount) {
            // Mint assets to vault if needed
            deal(address(asset), address(vault), amount);
        }
        
        // Call allocate as strategist
        vm.startPrank(strategy.strategist());
        try strategy.allocate(amount, "") {
            ghost_totalAllocated += amount;
            ghost_userAllocations[currentActor] += amount;
            
            uint256 totalAssetsAfter = strategy.totalAssets();
            emit HandlerAllocate(currentActor, amount, totalAssetsBefore, totalAssetsAfter);
            
            _updateGhostVariables();
        } catch {
            // Handle revert cases gracefully
        }
        vm.stopPrank();
    }
    
    /**
     * @dev Handler for strategy.collect() - collects assets from strategy back to vault
     */
    function collect(uint256 amount, uint256 actorIndexSeed) external useActor(actorIndexSeed) countCall("collect") {
        uint256 totalAssets = strategy.totalAssets();
        if (totalAssets == 0) return;
        
        // Bound amount to available assets
        amount = bound(amount, 1, totalAssets);
        
        uint256 totalAssetsBefore = totalAssets;
        
        // Call collect as strategist
        vm.startPrank(strategy.strategist());
        try strategy.collect(amount, "") {
            ghost_totalCollected += amount;
            ghost_userCollections[currentActor] += amount;
            
            uint256 totalAssetsAfter = strategy.totalAssets();
            emit HandlerCollect(currentActor, amount, totalAssetsBefore, totalAssetsAfter);
            
            _updateGhostVariables();
        } catch {
            // Handle revert cases gracefully
        }
        vm.stopPrank();
    }
    
    /**
     * @dev Handler for strategy.collectAll() - collects all assets from strategy
     */
    function collectAll(uint256 actorIndexSeed) external useActor(actorIndexSeed) countCall("collectAll") {
        uint256 totalAssets = strategy.totalAssets();
        if (totalAssets == 0) return;
        
        // Call collectAll as strategist
        vm.startPrank(strategy.strategist());
        try strategy.collectAll("") {
            ghost_totalCollected += totalAssets;
            ghost_userCollections[currentActor] += totalAssets;
            
            _updateGhostVariables();
        } catch {
            // Handle revert cases gracefully
        }
        vm.stopPrank();
    }
    
    /**
     * @dev Handler for strategy.invest() - direct investment with leverage
     */
    function invest(
        uint256 assetAmount, 
        uint256 borrowAmount, 
        uint256 actorIndexSeed
    ) external useActor(actorIndexSeed) countCall("invest") {
        // Bound amounts to reasonable values
        assetAmount = bound(assetAmount, 0, vault.getAllocationAvailableForStrategy(address(strategy)));
        borrowAmount = bound(borrowAmount, 0, 1000000e6); // Max 1M USDC
        
        // Skip if both amounts are zero
        if (assetAmount == 0 && borrowAmount == 0) return;
        
        // Ensure vault has enough assets if assetAmount > 0
        if (assetAmount > 0) {
            uint256 vaultBalance = asset.balanceOf(address(vault));
            if (vaultBalance < assetAmount) {
                deal(address(asset), address(vault), assetAmount);
            }
        }
        
        // Call invest as strategist
        vm.startPrank(strategy.strategist());
        try strategy.invest(assetAmount, borrowAmount, "") {
            ghost_totalInvested += assetAmount;
            ghost_userInvestments[currentActor] += assetAmount;
            if (borrowAmount > 0) {
                ghost_totalBorrowedFromAAVE += borrowAmount;
            }
            
            emit HandlerInvest(currentActor, assetAmount, borrowAmount);
            _updateGhostVariables();
        } catch {
            // Handle revert cases gracefully
        }
        vm.stopPrank();
    }
    
    /**
     * @dev Handler for strategy.redeem() - redeems collateral from AAVE
     */
    function redeem(uint256 supplyAmount, uint256 actorIndexSeed) external useActor(actorIndexSeed) countCall("redeem") {
        // Get maximum redeemable amount
        uint256 maxRedeemable;
        try aaveHelper.getMaxRedeemableAmount() returns (uint256 max) {
            maxRedeemable = max;
        } catch {
            return; // No position to redeem
        }
        
        if (maxRedeemable == 0) return;
        
        // Bound amount to maximum redeemable
        supplyAmount = bound(supplyAmount, 1, maxRedeemable);
        
        // Call redeem as strategist
        vm.startPrank(strategy.strategist());
        try strategy.redeem(supplyAmount, "") returns (uint256 redeemed) {
            ghost_totalRedeemed += redeemed;
            
            emit HandlerRedeem(currentActor, supplyAmount, redeemed);
            _updateGhostVariables();
        } catch {
            // Handle revert cases gracefully
        }
        vm.stopPrank();
    }
    
    ///////////////////////////////
    // Handler functions - SpUSD Operations
    ///////////////////////////////
    
    /**
     * @dev Handler for strategy.claimWithdrawFromSpUSD() - claims pending spUSD withdrawals
     */
    function claimWithdrawFromSpUSD(uint256 actorIndexSeed) external useActor(actorIndexSeed) countCall("claimWithdrawFromSpUSD") {
        uint256 pendingWithdraw = strategy.getPendingWithdrawSpUSD();
        if (pendingWithdraw == 0) return;
        
        // Call claim as strategist
        vm.startPrank(strategy.strategist());
        try strategy.claimWithdrawFromSpUSD() returns (uint256 claimed) {
            ghost_totalSpUSDWithdrawn += claimed;
            
            _updateGhostVariables();
        } catch {
            // Handle revert cases gracefully
        }
        vm.stopPrank();
    }
    
    /**
     * @dev Handler for strategy.claimAndRepay() - claims spUSD and repays AAVE debt
     */
    function claimAndRepay(uint256 repayAmount, uint256 actorIndexSeed) external useActor(actorIndexSeed) countCall("claimAndRepay") {
        // Check if there's debt to repay
        uint256 totalDebt;
        try strategy.getNetSupplyAndDebt(false) returns (uint256, uint256 debt, uint256) {
            totalDebt = debt;
        } catch {
            return; // No debt
        }
        
        if (totalDebt == 0) return;
        
        // Bound repay amount
        repayAmount = bound(repayAmount, 1, totalDebt);
        
        // Call claimAndRepay as strategist
        vm.startPrank(strategy.strategist());
        try strategy.claimAndRepay(repayAmount) {
            ghost_totalRepaidToAAVE += repayAmount;
            
            emit HandlerClaimAndRepay(currentActor, repayAmount);
            _updateGhostVariables();
        } catch {
            // Handle revert cases gracefully
        }
        vm.stopPrank();
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
    
    function getActorsCount() external view returns (uint256) {
        return actors.length;
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
    
    function getGhostUserAllocations(address user) external view returns (uint256) {
        return ghost_userAllocations[user];
    }
    
    function getGhostUserCollections(address user) external view returns (uint256) {
        return ghost_userCollections[user];
    }
    
    function getGhostUserInvestments(address user) external view returns (uint256) {
        return ghost_userInvestments[user];
    }
    
    function getGhostTotalSpUSDWithdrawn() external view returns (uint256) {
        return ghost_totalSpUSDWithdrawn;
    }
}