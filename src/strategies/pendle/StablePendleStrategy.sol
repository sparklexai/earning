// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {BaseSparkleXStrategy} from "../BaseSparkleXStrategy.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {Constants} from "../../utils/Constants.sol";

interface IPPrincipalToken {
    function isExpired() external view returns (bool);
    function expiry() external view returns (uint256);
    function SY() external view returns (address);
    function YT() external view returns (address);
}

interface IPYieldToken {
    function redeemPY(address receiver) external returns (uint256 amountSyOut);
    function mintPY(address receiverPT, address receiverYT) external returns (uint256 amountPYOut);
    function isExpired() external view returns (bool);
    function pyIndexStored() external view returns (uint256);
}

interface IPMarketV3 {
    function readTokens() external view returns (address SY, address PT, address YT);
    function swapExactPtForSy(address receiver, uint256 exactPtIn, bytes calldata data)
        external
        returns (uint256 netSyOut, uint256 netSyFee);
    function swapSyForExactPt(address receiver, uint256 exactPtOut, bytes calldata data)
        external
        returns (uint256 netSyIn, uint256 netSyFee);
    function observe(uint256[] memory secondsAgos) external view returns (uint256[] memory lnImpliedRateCumulative);
    function increaseObservationsCardinalityNext(uint16 observationCardinalityNext) external;
}

interface IPRouterStatic {
    function getPtToAssetRate(address market) external view returns (uint256 ptToAssetRate);
}

// Structs for multi-PT management
struct PTInfo {
    address ptToken;           // PT token address
    address ytToken;           // YT token address
    address market;            // Pendle market address
    address standardizedYield; // SY token address
}

contract StablePendleStrategy is BaseSparkleXStrategy {
    using Math for uint256;
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////////////////////
    // Constants and State Variables
    ///////////////////////////////
    
    // Pendle contract addresses (Ethereum mainnet)
    address public constant PENDLE_ROUTER_V4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address public constant PENDLE_ROUTER_STATIC = 0x263833d47eA3fA4a30f269323aba6a107f9eB14C;
    
    uint256 public constant MAX_PT_TOKENS = 10;
    
    // PT portfolio management
    mapping(address => PTInfo) public ptInfos;
    EnumerableSet.AddressSet private activePTs;
    
    ///////////////////////////////
    // Events
    ///////////////////////////////
    event PTAdded(address indexed ptToken, address indexed market, uint256 targetWeight);
    event PTRemoved(address indexed ptToken);
    event PTTokensPurchased(address indexed ptToken, uint256 usdcAmount, uint256 ptAmount);
    event PTTokensSold(address indexed ptToken, uint256 ptAmount, uint256 usdcAmount);
    event PTTokensRedeemed(address indexed ptToken, uint256 ptAmount, uint256 underlyingAmount);

    ///////////////////////////////
    // Errors
    ///////////////////////////////
    error PTNotFound();
    error PTAlreadyExists();
    error PTNotMatured();
    error PTAlreadyMatured();
    error InsufficientPTBalance();
    error InsufficientUSDCBalance();
    error SlippageExceeded();
    error InvalidSwapData();
    error MaxPTsExceeded();

    constructor(
        ERC20 token, // USDC
        address vault
    ) BaseSparkleXStrategy(token, vault) {
        // Set up initial approvals for Pendle Router
        _approveToken(address(_asset), PENDLE_ROUTER_V4);
    }

    ///////////////////////////////
    // Strategy Implementation
    ///////////////////////////////

    function totalAssets()
        external
        view
        override
        returns (uint256 totalManagedAssets)
    {
        uint256 usdcBalance = _asset.balanceOf(address(this));
        uint256 totalPTValue = 0;
        
        // Sum up all PT token values
        uint256 length = activePTs.length();
        for (uint256 i = 0; i < length; i++) {
            address ptToken = activePTs.at(i);
            totalPTValue += _getPTValue(ptToken);
        }
        
        return usdcBalance + totalPTValue;
    }

    function assetsInCollection()
        external
        view
        override
        returns (uint256 inCollectionAssets)
    {
        // All assets are available for collection
        return this.totalAssets();
    }

    function allocate(uint256 amount) external override onlyStrategistOrVault {
        amount = _capAllocationAmount(amount);
        if (amount == 0) return;

        // Receive USDC from vault
        _asset.safeTransferFrom(_vault, address(this), amount);
        
        emit AllocateInvestment(msg.sender, amount);
    }

    function collect(uint256 amount) external override onlyStrategistOrVault {
        if (amount == 0) return;
        _returnAssetToVault(amount);
        emit CollectInvestment(msg.sender, amount);
    }

    function collectAll() external override onlyStrategistOrVault {
        uint256 totalAvailable = _asset.balanceOf(address(this));
        _returnAssetToVault(totalAvailable);
        emit CollectInvestment(msg.sender, totalAvailable);
    }

    ///////////////////////////////
    // PT Management Functions
    ///////////////////////////////

    /**
     * @notice Add a new PT token to the strategy
     * @param ptToken PT token address
     * @param market Pendle market address
     * @param targetWeight Target allocation weight in basis points (optional, for tracking only)
     */
    function addPT(
        address ptToken,
        address market,
        uint256 targetWeight
    ) external onlyStrategist {
        if (ptInfos[ptToken].ptToken != address(0)) revert PTAlreadyExists();
        if (activePTs.length() >= MAX_PT_TOKENS) revert MaxPTsExceeded();

        IPPrincipalToken pt = IPPrincipalToken(ptToken);
        
        // Verify market compatibility
        (address marketSY, address marketPT, address marketYT) = IPMarketV3(market).readTokens();
        if (marketPT != ptToken) revert InvalidSwapData();

        // Create PT info
        PTInfo storage ptInfo = ptInfos[ptToken];
        ptInfo.ptToken = ptToken;
        ptInfo.ytToken = pt.YT();
        ptInfo.market = market;
        ptInfo.standardizedYield = pt.SY();

        activePTs.add(ptToken);

        // Set up approvals
        _approveToken(ptToken, market);
        _approveToken(ptInfo.standardizedYield, market);
        _approveToken(ptInfo.standardizedYield, PENDLE_ROUTER_V4);

        emit PTAdded(ptToken, market, targetWeight);
    }

    /**
     * @notice Remove a PT token from the strategy
     * @param ptToken PT token address
     */
    function removePT(address ptToken) external onlyStrategist {
        PTInfo storage ptInfo = ptInfos[ptToken];
        if (ptInfo.ptToken == address(0)) revert PTNotFound();

        // Liquidate any remaining PT tokens
        uint256 ptBalance = ERC20(ptToken).balanceOf(address(this));
        if (ptBalance > 0) {
            if (IPPrincipalToken(ptToken).isExpired()) {
                _redeemPT(ptToken, ptBalance);
            } else {
                _sellPTTokens(ptToken, ptBalance, 0);
            }
        }

        activePTs.remove(ptToken);
        delete ptInfos[ptToken];

        emit PTRemoved(ptToken);
    }

    ///////////////////////////////
    // Trading Functions
    ///////////////////////////////

    /**
     * @notice Buy specific PT tokens with USDC
     * @param ptToken PT token to buy
     * @param usdcAmount Amount of USDC to spend
     * @param minPTOut Minimum PT tokens expected
     * @param swapData Encoded swap data for routing
     */
    function buyPTTokens(
        address ptToken,
        uint256 usdcAmount,
        uint256 minPTOut,
        bytes calldata swapData
    ) external onlyStrategist {
        PTInfo storage ptInfo = ptInfos[ptToken];
        if (ptInfo.ptToken == address(0)) revert PTNotFound();
        if (IPPrincipalToken(ptToken).isExpired()) revert PTAlreadyMatured();
        if (usdcAmount > _asset.balanceOf(address(this))) revert InsufficientUSDCBalance();

        uint256 ptReceived;
        
        if (swapData.length > 0) {
            // Use TokenSwapper for complex routing via Pendle Router
            _approveToken(address(_asset), _swapper);
            ptReceived = TokenSwapper(_swapper).swapWithPendleRouter(
                address(_asset),
                ptToken,
                usdcAmount,
                minPTOut,
                swapData
            );
        } else {
            revert InvalidSwapData();
        }

        if (ptReceived < minPTOut) revert SlippageExceeded();

        emit PTTokensPurchased(ptToken, usdcAmount, ptReceived);
    }

    /**
     * @notice Sell specific PT tokens for USDC
     * @param ptToken PT token to sell
     * @param ptAmount Amount of PT tokens to sell
     * @param minUSDCOut Minimum USDC expected
     */
    function sellPTTokens(
        address ptToken,
        uint256 ptAmount,
        uint256 minUSDCOut
    ) external onlyStrategist {
        _sellPTTokens(ptToken, ptAmount, minUSDCOut);
        emit PTTokensSold(ptToken, ptAmount, minUSDCOut);
    }

    /**
     * @notice Redeem mature PT tokens for underlying asset
     * @param ptToken PT token to redeem
     * @param ptAmount Amount of PT tokens to redeem
     */
    function redeemPTTokens(address ptToken, uint256 ptAmount) external onlyStrategist {
        PTInfo storage ptInfo = ptInfos[ptToken];
        if (ptInfo.ptToken == address(0)) revert PTNotFound();
        if (!IPPrincipalToken(ptToken).isExpired()) revert PTNotMatured();

        uint256 redeemed = _redeemPT(ptToken, ptAmount);
        emit PTTokensRedeemed(ptToken, ptAmount, redeemed);
    }

    ///////////////////////////////
    // Internal Functions
    ///////////////////////////////

    function _sellPTTokens(address ptToken, uint256 ptAmount, uint256 minUSDCOut) internal {
        PTInfo storage ptInfo = ptInfos[ptToken];
        if (ptAmount > ERC20(ptToken).balanceOf(address(this))) revert InsufficientPTBalance();

        _approveToken(ptToken, ptInfo.market);

        // Swap PT -> SY via Pendle market
        (uint256 syReceived,) = IPMarketV3(ptInfo.market).swapExactPtForSy(
            address(this),
            ptAmount,
            ""
        );

        if (syReceived < minUSDCOut) revert SlippageExceeded();
    }

    function _redeemPT(address ptToken, uint256 ptAmount) internal returns (uint256) {
        PTInfo storage ptInfo = ptInfos[ptToken];
        if (ptAmount > ERC20(ptToken).balanceOf(address(this))) revert InsufficientPTBalance();

        uint256 balanceBefore = _asset.balanceOf(address(this));
        
        ERC20(ptToken).safeTransfer(ptInfo.ytToken, ptAmount);
        uint256 syOut = IPYieldToken(ptInfo.ytToken).redeemPY(address(this));

        uint256 balanceAfter = _asset.balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }

    function _getPTValue(address ptToken) internal view returns (uint256) {
        uint256 ptBalance = ERC20(ptToken).balanceOf(address(this));
        if (ptBalance == 0) return 0;

        PTInfo storage ptInfo = ptInfos[ptToken];
        
        if (IPPrincipalToken(ptToken).isExpired()) {
            return ptBalance; // 1:1 value at maturity
        }

        uint256 ptPrice = _getPTPrice(ptToken);
        return (ptBalance * ptPrice) / 1e18;
    }

    function _getPTPrice(address ptToken) internal view returns (uint256) {
        PTInfo storage ptInfo = ptInfos[ptToken];
        
        try IPRouterStatic(PENDLE_ROUTER_STATIC).getPtToAssetRate(ptInfo.market) returns (uint256 rate) {
            return rate;
        } catch {
            return 9e17; // 90% fallback price
        }
    }

    ///////////////////////////////
    // View Functions
    ///////////////////////////////

    function getActivePTs() external view returns (address[] memory) {
        return activePTs.values();
    }

    function getPTInfo(address ptToken) external view returns (PTInfo memory) {
        return ptInfos[ptToken];
    }

    function getPTBalance(address ptToken) external view returns (uint256) {
        return ERC20(ptToken).balanceOf(address(this));
    }

    function getPTValue(address ptToken) external view returns (uint256) {
        return _getPTValue(ptToken);
    }

    function getPortfolioBreakdown() external view returns (address[] memory tokens, uint256[] memory values) {
        uint256 length = activePTs.length();
        tokens = new address[](length);
        values = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            address ptToken = activePTs.at(i);
            tokens[i] = ptToken;
            values[i] = _getPTValue(ptToken);
        }
    }

    function getUSDCBalance() external view returns (uint256) {
        return _asset.balanceOf(address(this));
    }

    function getCurrentPTPrice(address ptToken) external view returns (uint256) {
        return _getPTPrice(ptToken);
    }
}
