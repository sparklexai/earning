// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../src/SparkleXVault.sol";
import {TokenSwapper} from "../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {TestUtils} from "../TestUtils.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {IPAllActionV3} from "@pendle/contracts/interfaces/IPAllActionV3.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IPMarketV3} from "@pendle/contracts/interfaces/IPMarketV3.sol";
import {IPRouterStatic} from "@pendle/contracts/interfaces/IPRouterStatic.sol";
import {DummyDEXRouter} from "../mock/DummyDEXRouter.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {PendleHelper} from "../../src/strategies/pendle/PendleHelper.sol";

contract BasePendleStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    address public stkVOwner;
    address public strategist;
    TokenSwapper public swapper;
    DummyDEXRouter public mockRouter;
    address public myStrategy;
    uint256 public usdcPerETH = 2000e18;
    uint256 public magicUSDCAmount = 1234567890;
    uint256 public magicPTAmount = 1200e18;
    address public strategyOwner;
    PendleHelper public pendleHelper;

    DummyDEXRouter.ApproxParams public _pendleSwapApproxParams = DummyDEXRouter.ApproxParams({
        guessMin: 0,
        guessMax: type(uint256).max,
        guessOffchain: 0,
        maxIteration: 256,
        eps: 1e14
    });

    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address usdcWhale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341; //sky:PSM

    // check https://github.com/pendle-finance/pendle-core-v2-public/blob/main/deployments/1-core.json
    IPRouterStatic pendleRouterStatic = IPRouterStatic(0x263833d47eA3fA4a30f269323aba6a107f9eB14C);
    address constant pendleRouterV4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;

    // mainnet chainlink aggregator
    address constant USDC_USD_Feed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    ///////////////////////////////
    // mainnet pendle PT pools: active
    ///////////////////////////////
    // sUSDe JUL31 market
    IPPrincipalToken PT_ADDR1 = IPPrincipalToken(0x3b3fB9C57858EF816833dC91565EFcd85D96f634);
    address YT_ADDR1 = 0xb7E51D15161C49C823f3951D579DEd61cD27272B;
    IPMarketV3 MARKET_ADDR1 = IPMarketV3(0x4339Ffe2B7592Dc783ed13cCE310531aB366dEac);
    address constant PT1_Whale = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant YIELD_TOKEN_FEED1 = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961; //usde oracle
    uint256 public constant USDC_TO_PT1_DUMMY_PRICE = 1010000000000000000; //1.01
    address public constant UNDERLYING_YIELD_ADDR1 = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    // USDS AUG15 market
    IPPrincipalToken PT_ADDR2 = IPPrincipalToken(0xFfEc096c087C13Cc268497B89A613cACE4DF9A48);
    address YT_ADDR2 = 0x4EB0Bb058BCFEAc8a2b3c2fC3CaE2B8aD7fF7f6e;
    IPMarketV3 MARKET_ADDR2 = IPMarketV3(0xdacE1121e10500e9e29d071F01593fD76B000f08);
    address constant PT2_Whale = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant YIELD_TOKEN_FEED2 = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;
    uint256 public constant USDC_TO_PT2_DUMMY_PRICE = 1010000000000000000; //1.01
    address public constant UNDERLYING_YIELD_ADDR2 = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    ///////////////////////////////
    // target selectors for pendle router swap calldata
    ///////////////////////////////
    bytes4 constant TARGET_SELECTOR_PENDLE = hex"c81f847a"; //swapExactTokenForPt()
    bytes4 constant TARGET_SELECTOR_PENDLE2 = hex"594a88cc"; //swapExactPtForToken()
    bytes4 constant TARGET_SELECTOR_PENDLE3 = hex"47f1de22"; //redeemPyToToken()

    function _generateSwapCalldataForBuy(address receiver, address market, uint256 minOut, uint256 inAmount)
        internal
        view
        returns (bytes memory)
    {
        DummyDEXRouter.TokenInput memory _input = _getDummyTokenInput(usdc, inAmount);
        DummyDEXRouter.LimitOrderData memory emptyLimit;
        return abi.encodeWithSelector(
            DummyDEXRouter.swapExactTokenForPt.selector,
            receiver,
            market,
            minOut,
            _pendleSwapApproxParams,
            _input,
            emptyLimit
        );
    }

    function _generateSwapCalldataForSell(address receiver, address market, uint256 minOut, uint256 inAmount)
        internal
        view
        returns (bytes memory)
    {
        DummyDEXRouter.TokenOutput memory _output = _getDummyTokenOutput(usdc, minOut);
        DummyDEXRouter.LimitOrderData memory emptyLimit;
        return abi.encodeWithSelector(
            DummyDEXRouter.swapExactPtForToken.selector, receiver, market, inAmount, _output, emptyLimit
        );
    }

    function _generateSwapCalldataForRedeem(address receiver, address ytToken, uint256 minOut, uint256 inAmount)
        internal
        view
        returns (bytes memory)
    {
        DummyDEXRouter.TokenOutput memory _output = _getDummyTokenOutput(usdc, minOut);
        return abi.encodeWithSelector(DummyDEXRouter.redeemPyToToken.selector, receiver, ytToken, inAmount, _output);
    }

    function _generateSwapCalldataForRollover(address receiver, address ptFrom, address ptTo, uint256 inAmount)
        internal
        view
        returns (bytes memory)
    {
        bytes memory _sellfCall1;
        bytes memory _sellfCall2 = abi.encode(receiver, ptFrom, ptTo, inAmount);
        bytes memory _reflectCall = _generateSwapCalldataForRedeem(receiver, Constants.ZRO_ADDR, 0, inAmount);
        return abi.encodeWithSelector(
            DummyDEXRouter.callAndReflect.selector, Constants.ZRO_ADDR, _sellfCall1, _sellfCall2, _reflectCall
        );
    }

    function _getDummyTokenInput(address _inToken, uint256 _inAmount)
        internal
        view
        returns (DummyDEXRouter.TokenInput memory)
    {
        DummyDEXRouter.SwapData memory emptySwap;
        DummyDEXRouter.TokenInput memory _input = DummyDEXRouter.TokenInput({
            tokenIn: _inToken,
            netTokenIn: _inAmount,
            tokenMintSy: _inToken,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        return _input;
    }

    function _getDummyTokenOutput(address _outToken, uint256 _minAmount)
        internal
        view
        returns (DummyDEXRouter.TokenOutput memory)
    {
        DummyDEXRouter.SwapData memory emptySwap;
        DummyDEXRouter.TokenOutput memory _output = DummyDEXRouter.TokenOutput({
            tokenOut: _outToken,
            minTokenOut: _minAmount,
            tokenRedeemSy: _outToken,
            pendleSwap: address(0),
            swapData: emptySwap
        });
        return _output;
    }
}
