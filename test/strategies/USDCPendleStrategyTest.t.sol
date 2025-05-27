// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../src/SparkleXVault.sol";
import {TokenSwapper} from "../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestUtils} from "../TestUtils.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {IPAllActionV3} from "@pendle/contracts/interfaces/IPAllActionV3.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IPMarketV3} from "@pendle/contracts/interfaces/IPMarketV3.sol";
import {IPRouterStatic} from "@pendle/contracts/interfaces/IPRouterStatic.sol";
import {IPSwapAggregator} from "@pendle/contracts/router/swap-aggregator/IPSwapAggregator.sol";
import "@pendle/contracts/interfaces/IPAllActionTypeV3.sol";

// run this test with mainnet fork
// forge coverage --fork-url <rpc_url> --match-path USDCPendleStrategyTest -vvv --no-match-coverage "(script|test)"
contract USDCPendleStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    address public stkVOwner;
    address public strategist;
    TokenSwapper public swapper;

    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address USDe = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address usdcWhale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; //sky:PSM
    address usdcUSDeCurvePool = 0x02950460E2b9529D0E00284A5fA2d7bDF3fA4d72;

    // check https://github.com/pendle-finance/pendle-core-v2-public/blob/main/deployments/1-core.json
    IPAllActionV3 pendleRouter = IPAllActionV3(0x888888888889758F76e7103c6CbF23ABbF58F946);
    IPRouterStatic pendleRouterStatic = IPRouterStatic(0x263833d47eA3fA4a30f269323aba6a107f9eB14C);
    address kyberSwapRouter = 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5;
    address paraSwapRouter = 0x6A000F20005980200259B80c5102003040001068;

    // EmptySwap means no swap aggregator is involved
    SwapData public emptySwap;
    // EmptyLimit means no limit order is involved
    LimitOrderData public emptyLimit;
    // DefaultApprox means no off-chain preparation is involved, more gas consuming (~ 180k gas)
    ApproxParams public defaultApprox = ApproxParams(0, type(uint256).max, 0, 256, 1e14);

    // mainnet pendle PT pool
    IPPrincipalToken sUSDeJUL31_PT = IPPrincipalToken(0x3b3fB9C57858EF816833dC91565EFcd85D96f634);
    IPMarketV3 sUSDeJUL31_Market = IPMarketV3(0x4339Ffe2B7592Dc783ed13cCE310531aB366dEac);

    function setUp() public {
        stkVault = new SparkleXVault(ERC20(usdc), "SparkleXVault", "SPXV");
        stkVOwner = stkVault.owner();

        swapper = new TokenSwapper();
    }

    function test_SwapForPT() public {
        assertFalse(sUSDeJUL31_PT.isExpired());

        uint256 _testVal = 1000e6;
        uint256 _slippageAllowed = 9950;

        vm.startPrank(usdcWhale);
        ERC20(usdc).approve(address(swapper), type(uint256).max);
        uint256 _syIN = swapper.swapInCurveTwoTokenPool(
            usdc,
            USDe,
            usdcUSDeCurvePool,
            _testVal,
            (_testVal * _slippageAllowed / Constants.TOTAL_BPS),
            _slippageAllowed
        );
        vm.stopPrank();

        // check https://docs.pendle.finance/Developers/FAQ#how-do-i-fetch-the-pt-price
        uint256 _pt2AssetRate = pendleRouterStatic.getPtToAssetRate(address(sUSDeJUL31_Market));
        uint256 _minOutExpected = _syIN * _pt2AssetRate * _slippageAllowed / (1e18 * Constants.TOTAL_BPS); //TODO
        //bytes memory _callData = "";

        vm.startPrank(usdcWhale);
        ERC20(USDe).approve(address(pendleRouter), type(uint256).max);
        (uint256 netPtOut,,) = pendleRouter.swapExactTokenForPt(
            address(this),
            address(sUSDeJUL31_Market),
            _minOutExpected,
            defaultApprox,
            //swapper.createPendleTokenInput(usdc, _testVal, USDe, SwapType.PARASWAP, paraSwapRouter, _callData),
            createTokenInputSimple(USDe, _syIN),
            emptyLimit
        );
        vm.stopPrank();
        console.log("_syIN:%d,_pt2AssetRate:%d,netPtOut:%d", _syIN, _pt2AssetRate, netPtOut);

        assertTrue(_assertApproximateEq(_syIN * 1e18 / _pt2AssetRate, netPtOut, BIGGER_TOLERANCE * 100));
    }
}
