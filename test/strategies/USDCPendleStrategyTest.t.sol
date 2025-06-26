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
import {PendleStrategy} from "../../src/strategies/pendle/PendleStrategy.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {DummyPendleAAVEStrategy} from "../mock/DummyPendleAAVEStrategy.sol";
import {PendleHelper} from "../../src/strategies/pendle/PendleHelper.sol";
import {BasePendleStrategyTest} from "./BasePendleStrategyTest.t.sol";

interface IERC4626Vault {
    function convertToAssets(uint256 _share) external view returns (uint256);
    function decimals() external view returns (uint256);
}

// run this test with mainnet fork
// forge coverage --fork-url <rpc_url> --match-path USDCPendleStrategyTest -vvv --no-match-coverage "(script|test)"
contract USDCPendleStrategyTest is BasePendleStrategyTest {
    ///////////////////////////////
    // Note this address is only meaningful for this test
    ///////////////////////////////
    address public constant PENDLE_STRATEGY_ADDRESS = 0x63670E16dE53F8eb1CEf55A46120BF137C4020f4;
    string public constant PENDLE_STRATEGY_NAME = "sparklex.pendle.strategy";

    ///////////////////////////////
    // mainnet pendle PT pools
    ///////////////////////////////
    address public constant sUSDf_USDf_FEED = 0xe471bc940AA9831a0AeA21E6F40C1A1236EB4BB3;
    address public constant sUSDf_MARKET_ADDR = 0x45F163E583D34b8E276445dd3Da9aE077D137d72;
    address public constant wstUSR = 0x1202F5C7b4B9E47a1A484E8B270be34dbbC75055;
    address public constant wstUSR_MARKET_ADDR = 0x09fA04Aac9c6d1c6131352EE950CD67ecC6d4fB9;

    // expect events
    event AssetOracleAdded(address indexed assetToken, address indexed oracle);

    function setUp() public {
        _createForkMainnet(22727695);
        stkVault = new SparkleXVault(ERC20(usdc), "SparkleXVault", "SPXV");
        stkVOwner = stkVault.owner();

        vm.startPrank(stkVOwner);
        stkVault.setEarnRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        swapper = new TokenSwapper();
        mockRouter = new DummyDEXRouter();
    }

    function test_Mock_DummySwap(uint256 _inAmount) public {
        uint256 _usdc2PTPrice = 1080000000000000000; //1.08
        _inAmount = bound(_inAmount, 100000000, 1000000000000);

        DummyDEXRouter.TokenInput memory _input = _getDummyTokenInput(usdc, _inAmount);
        DummyDEXRouter.LimitOrderData memory emptyLimit;

        uint256 _outBalBefore = ERC20(address(PT_ADDR1)).balanceOf(usdcWhale);
        vm.startPrank(usdcWhale);
        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, _usdc2PTPrice);
        ERC20(usdc).approve(address(mockRouter), type(uint256).max);
        (uint256 _out,,) = mockRouter.swapExactTokenForPt(
            usdcWhale, address(MARKET_ADDR1), 0, _pendleSwapApproxParams, _input, emptyLimit
        );
        vm.stopPrank();
        assertEq(_out, ERC20(address(PT_ADDR1)).balanceOf(usdcWhale) - _outBalBefore);
    }

    function test_PT_price_BeforeExpire() public {
        (myStrategy, strategist) = _createPendleStrategy(false);

        uint32 _twap = 1800;
        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, _twap
        );

        uint256 _ptPrice = PendleStrategy(myStrategy).getPTPriceInAsset(usdc, address(PT_ADDR1));
        uint256 _ptToSyPrice = swapper.getPTPriceInSYFromPendle(address(MARKET_ADDR1), _twap);
        (int256 _usdcUSDPrice,,) = swapper.getPriceFromChainLink(USDC_USD_Feed);
        (int256 _yieldUSDPrice,,) = swapper.getPriceFromChainLink(YIELD_TOKEN_FEED1);
        assertTrue(
            _assertApproximateEq(
                _ptPrice,
                (
                    uint256(_yieldUSDPrice) * IERC4626Vault(UNDERLYING_YIELD_ADDR1).convertToAssets(Constants.ONE_ETHER)
                        * _ptToSyPrice / (uint256(_usdcUSDPrice) * Constants.ONE_ETHER)
                ),
                BIGGER_TOLERANCE
            )
        );

        // test price with intermediate oracles
        uint256 _sUSDfPrice = swapper.getPTPriceInAsset(
            usdc,
            USDC_USD_Feed,
            sUSDf_MARKET_ADDR,
            1800,
            swapper.USDf(),
            sUSDf_USDf_FEED,
            swapper.USDf_USD_FEED(),
            Constants.ONE_ETHER
        );
        assertTrue(_assertApproximateEq(_sUSDfPrice, Constants.ONE_ETHER, BIGGER_TOLERANCE));

        // test price with underlying as ERC4626
        uint256 _wstUSRPrice = swapper.getPTPriceInAsset(
            usdc, USDC_USD_Feed, wstUSR_MARKET_ADDR, 1800, wstUSR, wstUSR, swapper.USR_USD_FEED(), Constants.ONE_ETHER
        );
        assertTrue(_assertApproximateEq(_wstUSRPrice, Constants.ONE_ETHER, BIGGER_TOLERANCE));
    }

    function test_PT_price_AfterExpire() public {
        (myStrategy, strategist) = _createPendleStrategy(false);

        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );

        // forward to market expire
        vm.warp(MARKET_ADDR1.expiry() + 123);
        assertTrue(MARKET_ADDR1.isExpired());

        uint256 _ptPrice = PendleStrategy(myStrategy).getPTPriceInAsset(UNDERLYING_YIELD_ADDR1, address(PT_ADDR1));
        assertEq(_ptPrice, Constants.ONE_ETHER);

        _ptPrice = PendleStrategy(myStrategy).getPTPriceInAsset(usdc, address(PT_ADDR1));
        (int256 _usdcUSDPrice,,) = swapper.getPriceFromChainLink(USDC_USD_Feed);
        (int256 _yieldUSDPrice,,) = swapper.getPriceFromChainLink(YIELD_TOKEN_FEED1);
        assertTrue(
            _assertApproximateEq(
                _ptPrice,
                (
                    uint256(_yieldUSDPrice) * IERC4626Vault(UNDERLYING_YIELD_ADDR1).convertToAssets(Constants.ONE_ETHER)
                        * Constants.ONE_ETHER / (uint256(_usdcUSDPrice) * Constants.ONE_ETHER)
                ),
                BIGGER_TOLERANCE
            )
        );
    }

    function test_Dummy_BaseAAVE_WithPendlePT() public {
        DummyPendleAAVEStrategy _dummyPendleAaveStrategy = new DummyPendleAAVEStrategy(address(stkVault));
        assertFalse(_dummyPendleAaveStrategy.vaultPaused());
        bytes memory EMPTY_CALLDATA;

        bytes memory _dummyCallData = abi.encodeWithSelector(ERC20.transfer.selector, usdc, 0);
        vm.expectRevert(Constants.WRONG_SWAP_RECEIVER.selector);
        vm.startPrank(address(_dummyPendleAaveStrategy));
        swapper.swapWithPendleRouter(address(mockRouter), usdc, address(PT_ADDR1), magicUSDCAmount, 0, _dummyCallData);
        vm.stopPrank();

        bytes memory _dummyCallData2 = abi.encodeWithSelector(
            DummyPendleAAVEStrategy._reflectCall.selector, usdc, EMPTY_CALLDATA, EMPTY_CALLDATA, _dummyCallData
        );
        vm.expectRevert(Constants.WRONG_SWAP_RECEIVER.selector);
        vm.startPrank(address(_dummyPendleAaveStrategy));
        swapper.chainSwapWithPendleRouter(
            address(mockRouter), usdc, address(PT_ADDR1), magicUSDCAmount, 0, _dummyCallData2
        );
        vm.stopPrank();

        uint256 _supplyPTAmount = magicPTAmount;
        uint256 _borrowAmount = magicUSDCAmount;

        vm.startPrank(PT1_Whale);
        ERC20(address(PT_ADDR1)).transfer(address(_dummyPendleAaveStrategy), _supplyPTAmount);
        vm.stopPrank();

        address _borrowWhale = mockRouter._usdtWhale();
        vm.startPrank(_borrowWhale);
        SafeERC20.safeTransfer(ERC20(mockRouter.usdt()), address(_dummyPendleAaveStrategy), _borrowAmount);
        vm.stopPrank();

        if (block.timestamp < PT_ADDR1.expiry()) {
            vm.warp(PT_ADDR1.expiry() + 123);
        }
        assertTrue(PT_ADDR1.isExpired());

        uint256 _totalAssets = _dummyPendleAaveStrategy.totalAssets();

        assertTrue(
            _assertApproximateEq(
                _totalAssets,
                (
                    _dummyPendleAaveStrategy.convertFromBorrowToAsset(magicUSDCAmount)
                        + _dummyPendleAaveStrategy.convertFromPTSupply(_supplyPTAmount, true)
                ),
                BIGGER_TOLERANCE
            )
        );

        uint256 _supplyToBorrow = _dummyPendleAaveStrategy.convertFromPTSupply(_supplyPTAmount, false);
        assertTrue(_assertApproximateEq(_supplyToBorrow, _borrowAmount, BIGGER_TOLERANCE));

        uint256 _totalAssetToSupply = _dummyPendleAaveStrategy.convertToPTSupply(_totalAssets, true);
        assertTrue(_totalAssetToSupply > _supplyPTAmount);

        uint256 _borrowToSupply = _dummyPendleAaveStrategy.convertToPTSupply(_borrowAmount, false);
        assertTrue(_assertApproximateEq(_totalAssetToSupply, _borrowToSupply, BIGGER_TOLERANCE));

        vm.recordLogs();
        vm.startPrank(_dummyPendleAaveStrategy.owner());
        _dummyPendleAaveStrategy.invest(0, 0, EMPTY_CALLDATA);
        vm.stopPrank();
        Vm.Log[] memory logEntries = vm.getRecordedLogs();
        assertEq(0, logEntries.length);
    }

    ///////////////////////////////
    // Following Tests might be changed
    // if market on mainnet change
    ///////////////////////////////

    function test_SwapForPT() public {
        assertFalse(PT_ADDR1.isExpired());

        uint256 _testVal = 1000e6;
        uint256 _slippageAllowed = 9950;

        // check https://docs.pendle.finance/Developers/FAQ#how-do-i-fetch-the-pt-price
        uint256 _pt2AssetRate = pendleRouterStatic.getPtToAssetRate(address(MARKET_ADDR1));
        (int256 _usdcUsdPrice,,) = swapper.getPriceFromChainLink(USDC_USD_Feed);
        (int256 _yieldUSDPrice,,) = swapper.getPriceFromChainLink(YIELD_TOKEN_FEED1);
        // check https://docs.pendle.finance/Developers/Contracts/StandardizedYield#standard-sys
        uint256 _asset2SYRate = uint256(
            uint256(_usdcUsdPrice) * 1e18 * Constants.ONE_ETHER
                / (uint256(_yieldUSDPrice) * IERC4626Vault(UNDERLYING_YIELD_ADDR1).convertToAssets(Constants.ONE_ETHER))
        );
        uint256 _PT2SYRate = swapper.getPTPriceInSYFromPendle(address(MARKET_ADDR1), 0);
        uint256 _yield2USDCRate = _PT2SYRate * 1e18 / _asset2SYRate;

        console.log("_asset2SYRate:%d,_PT2SYRate:%d,_yield2USDCRate:%d", _asset2SYRate, _PT2SYRate, _yield2USDCRate);
        assertTrue(_assertApproximateEq(_pt2AssetRate, _yield2USDCRate, BIGGER_TOLERANCE));

        // call SDK to get bytes
        uint256 _minOut = 913658521822428953199; // max allowed slippage set in SDK with 10%
        bytes memory _callData =
            hex"c81f847a00000000000000000000000037305b1cd40574e4c5ce33f8e8306be057fd73410000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac000000000000000000000000000000000000000000000031878f20d3c25c7a6f00000000000000000000000000000000000000000000001b8433123cc14fd23e0000000000000000000000000000000000000000000000528c9936b643ef76ba00000000000000000000000000000000000000000000003708662479829fa47c000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000cc0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000003b9aca000000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000d4e9b0d466789d7f6201442eeccba6a75a552db000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a24e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000007400000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000003e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d444000000000000000000000000000000000000000000000000000000003b9aca00000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000053e2d6238da30000003200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000007eb59373d63627be64b42406b108b602174b4ccc000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000000000000000000000000000000000003b91089e000000000000000000000000fffd8963efd1fc6a506488495d951d5263988d250000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000003060f31dec048000000000000002e23355ab5297ddea7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000002986166b3ca557aec90000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000003b9aca0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002867b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a223939372e30333334363035343036353037222c22416d6f756e744f7574555344223a223939382e31323733303834363738323938222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a22383531303837323631303839383634323132313335222c2254696d657374616d70223a313734383336303030392c22526f7574654944223a2263313766303334382d656535622d346633332d626337382d3434613565643466633462353a63666336346435352d643463302d343262322d383137372d363835323537623061613939222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a22444350776d517a42326e792b693770584c624f7634786366736351733957552f536a6e4a4e7970666a642b5a694e4467456945335835773662567030664d42446e48562f486179594e66675739724f63726659724f6371674b515a5431736648696f456f4b2f647739525251663573434a324f6d426f42445231534561324a41677152534b35442b784a46314d5a504b726d3375645734364674796d6e71353038344b3138795667533348786e2f344e616c4d2f326b726474493679686b58475232394c594a45665a2f475a6e53364e7a2f6145625950526636394c677a7467747a6f347559444a334a4a76746a38586e71706d62716c487671447832727a626553423533484c68476f5a6842514d7162503367534a3648543063634739523162716e576555474d70674658507061593566434f6b466b4e744430447a4b665554364938364569736972613456776f51344c517355773d3d227d7d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

        assertEq(TARGET_SELECTOR_PENDLE, bytes4(_callData)); //(_callData[:4])

        vm.startPrank(usdcWhale);
        ERC20(usdc).approve(address(swapper), type(uint256).max);
        uint256 ptOut =
            swapper.swapWithPendleRouter(Constants.ZRO_ADDR, usdc, address(PT_ADDR1), _testVal, _minOut, _callData);
        vm.stopPrank();

        console.log("_pt2AssetRate:%d,ptOut:%d", _pt2AssetRate, ptOut);

        assertTrue(
            _assertApproximateEq((_testVal * 1e18 * 1e18 / (1e6 * _pt2AssetRate)), ptOut, BIGGER_TOLERANCE * 100)
        );
    }

    ///////////////////////////////
    // Following Tests use mainnet pendle router
    ///////////////////////////////

    function test_Basic_Pendle_InOut(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(false);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );
        _zapInWithPendlePT(usdc, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), magicUSDCAmount);
        _checkBasicInvariants(address(stkVault));
        uint256 _totalAssetsInStrategy = IStrategy(myStrategy).totalAssets();
        console.log("_totalAssetsInStrategyAfterBuy1:%d", _totalAssetsInStrategy);
        assertTrue(_assertApproximateEq(_totalAssetsInStrategy, magicUSDCAmount, 5 * MIN_SHARE));

        _stormOutFromPendlePT(usdc, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), magicPTAmount);
        _checkBasicInvariants(address(stkVault));
        _totalAssetsInStrategy = IStrategy(myStrategy).totalAssets();
        console.log("_totalAssetsInStrategyAfterSell1:%d", _totalAssetsInStrategy);
        assertTrue(_assertApproximateEq(_totalAssetsInStrategy, magicUSDCAmount, 5 * MIN_SHARE));

        _addPTMarket(address(MARKET_ADDR2), UNDERLYING_YIELD_ADDR2, YIELD_TOKEN_FEED2, 100);
        _zapInWithPendlePT(usdc, myStrategy, address(PT_ADDR2), address(MARKET_ADDR2), magicUSDCAmount);
        _checkBasicInvariants(address(stkVault));
        _totalAssetsInStrategy = IStrategy(myStrategy).totalAssets();
        uint256 _residueOfPT1AmountInAsset = PendleStrategy(myStrategy).getPTAmountInAsset(address(PT_ADDR1));
        console.log(
            "_totalAssetsInStrategyAfterBuy2:%d,_residueOfPT1AmountInAsset:%d",
            _totalAssetsInStrategy,
            _residueOfPT1AmountInAsset
        );
        assertTrue(
            _assertApproximateEq(_totalAssetsInStrategy, (magicUSDCAmount + _residueOfPT1AmountInAsset), 5 * MIN_SHARE)
        );

        address[] memory _activePTMarkets = PendleStrategy(myStrategy).getActivePTs();
        assertEq(2, _activePTMarkets.length);

        // forward to market expire
        vm.warp(block.timestamp + Constants.ONE_YEAR);
        assertTrue(MARKET_ADDR2.isExpired());
        _redeemAfterPendlePTExpire(usdc, myStrategy, address(PT_ADDR2), YT_ADDR2, magicPTAmount);
        _checkBasicInvariants(address(stkVault));
        _totalAssetsInStrategy = IStrategy(myStrategy).totalAssets();
        _residueOfPT1AmountInAsset = PendleStrategy(myStrategy).getPTAmountInAsset(address(PT_ADDR1));
        uint256 _residueOfPT2AmountInAsset = PendleStrategy(myStrategy).getPTAmountInAsset(address(PT_ADDR2));
        console.log(
            "_totalAssetsInStrategyAfterRedeem:%d,_residueOfPT1AmountInAsset:%d,_residueOfPT2AmountInAsset:%d",
            _totalAssetsInStrategy,
            _residueOfPT1AmountInAsset,
            _residueOfPT2AmountInAsset
        );
        // assume USDS is 1:1 to USDC after market expire
        assertTrue(
            _assertApproximateEq(
                _totalAssetsInStrategy,
                ((magicPTAmount / 1e12) + _residueOfPT1AmountInAsset + _residueOfPT2AmountInAsset),
                5 * MIN_SHARE
            )
        );

        bytes memory EMPTY_CALLDATA;
        vm.expectRevert(Constants.PT_STILL_IN_USE.selector);
        vm.startPrank(strategist);
        IStrategy(myStrategy).collectAll(EMPTY_CALLDATA);
        vm.stopPrank();
        assertTrue(PendleStrategy(myStrategy).getAllPTAmountsInAsset() > 0);
    }

    function test_Pendle_RollOver_BeforeExpire(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(false);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );
        bytes memory EMPTY_CALLDATA;

        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );
        _addPTMarket(address(MARKET_ADDR2), UNDERLYING_YIELD_ADDR2, YIELD_TOKEN_FEED2, 100);

        _zapInWithPendlePT(usdc, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), magicUSDCAmount);

        // roll over from PT1 to PT2 before PT1 expire
        vm.expectRevert(Constants.PT_NOT_FOUND.selector);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).rolloverPT(Constants.ZRO_ADDR, address(PT_ADDR2), magicPTAmount, EMPTY_CALLDATA);
        vm.stopPrank();
        vm.expectRevert(Constants.PT_NOT_FOUND.selector);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).rolloverPT(address(PT_ADDR1), Constants.ZRO_ADDR, magicPTAmount, EMPTY_CALLDATA);
        vm.stopPrank();

        assertEq(0, PendleStrategy(myStrategy).getPTAmountInAsset(wstUSR));

        assertEq(1e6, Constants.convertDecimalToUnit(6));
        assertEq(1e12, Constants.convertDecimalToUnit(12));
        assertEq(0, Constants.convertDecimalToUnit(0));

        bytes memory _callData =
            hex"9fa02c8600000000000000000000000073d5dbf81a4f3bfa7b335e6a2d4638d6017a4fa8000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000003a000000000000000000000000000000000000000000000000000000000000003c000000000000000000000000000000000000000000000000000000000000002e4594a88cc00000000000000000000000073d5dbf81a4f3bfa7b335e6a2d4638d6017a4fa80000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac0000000000000000000000000000000000000000000000410d586a20a4c0000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a349700000000000000000000000000000000000000000000003617d8f689460b717c0000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000484c81f847a00000000000000000000000063670e16de53f8eb1cef55a46120bf137c4020f4000000000000000000000000dace1121e10500e9e29d071f01593fd76b000f080000000000000000000000000000000000000000000000408e8708c7ac92fef30000000000000000000000000000000000000000000000209abb260ced2373d500000000000000000000000000000000000000000000004478229cb4beca734000000000000000000000000000000000000000000000004135764c19da46e7ab000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000009184e72a000000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000003800000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000000000000000000000000036a3b989d5a66dd24f0000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000fe6228a3866426e96611ed7a3d0dee918244fcb300000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000040000000000000000000000006088d94c5a40cecd3ae2d4e0710ca687b91c61d00000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e40d5f0e3b00000000000000000001a663888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000037bb7ab06e673293f4000000000000000000000000000000000000000000000040fcdbb76acc353d89000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000020000000000000000000000007eb59373d63627be64b42406b108b602174b4ccc80000000000000000000000048da0965ab2d2cbf1c17c09cfb5cbe67ad5b1406000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).rolloverPT(address(PT_ADDR1), address(PT_ADDR2), magicPTAmount, _callData);
        vm.stopPrank();

        assertTrue(_assertApproximateEq(IStrategy(myStrategy).totalAssets(), magicUSDCAmount, 2 * MIN_SHARE));
        _checkBasicInvariants(address(stkVault));
    }

    ///////////////////////////////
    // Following Tests use mock dummy router
    ///////////////////////////////

    function test_Basic_Pendle_Allocate(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetAmount, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        vm.expectRevert(Constants.INVALID_MARKET_TO_ADD.selector);
        _addPTMarket(Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, 100);

        uint256 _maxAllocation = stkVault.getAllocationAvailableForStrategy(myStrategy);
        uint256 _assetBalanceBeforeInStrategy = ERC20(usdc).balanceOf(myStrategy);
        bytes memory EMPTY_CALLDATA;
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(_maxAllocation, ERC20(usdc).balanceOf(myStrategy) - _assetBalanceBeforeInStrategy);
    }

    function test_Pendle_RollOver_AfterExpire(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetAmount, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );
        _addPTMarket(address(MARKET_ADDR2), UNDERLYING_YIELD_ADDR2, YIELD_TOKEN_FEED2, 100);

        vm.expectRevert(Constants.ZERO_TO_SWAP_IN_PENDLE.selector);
        _zapInWithPendlePT(UNDERLYING_YIELD_ADDR1, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), _assetAmount);

        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, USDC_TO_PT1_DUMMY_PRICE);
        _zapInWithPendlePT(usdc, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), _assetAmount);

        // forward to market expire
        vm.warp(MARKET_ADDR1.expiry() + 123);
        assertTrue(MARKET_ADDR1.isExpired());
        assertFalse(MARKET_ADDR2.isExpired());

        // roll over from PT1 to PT2 after PT1 expire
        uint256 _ptFromAmount = ERC20(address(PT_ADDR1)).balanceOf(myStrategy);
        bytes memory _callData =
            _generateSwapCalldataForRollover(myStrategy, address(PT_ADDR1), address(PT_ADDR2), _ptFromAmount);
        _prepareSwapForMockRouter(mockRouter, address(PT_ADDR1), address(PT_ADDR2), PT2_Whale, 150e16);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).rolloverPT(address(PT_ADDR1), address(PT_ADDR2), _ptFromAmount, _callData);
        vm.stopPrank();

        vm.expectRevert(Constants.ZERO_TO_SWAP_IN_PENDLE.selector);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).rolloverPT(address(PT_ADDR1), address(PT_ADDR2), _ptFromAmount, _callData);
        vm.stopPrank();

        bytes memory _empty;
        _removePTMarket(address(PT_ADDR1), _empty);
        (,,,,,, uint128 _twapSeconds) = PendleStrategy(myStrategy).ptInfos(address(PT_ADDR1));
        assertEq(0, _twapSeconds);

        // some generous sugardaddy send PT1 to the strategy after PT1 removed
        vm.startPrank(PT1_Whale);
        ERC20(address(PT_ADDR1)).transfer(myStrategy, magicPTAmount);
        vm.stopPrank();
        assertTrue(ERC20(address(PT_ADDR1)).balanceOf(myStrategy) >= magicPTAmount);

        assertEq(IStrategy(myStrategy).totalAssets(), PendleStrategy(myStrategy).getPTAmountInAsset(address(PT_ADDR2)));
        _checkBasicInvariants(address(stkVault));
    }

    function test_Remove_PTMarket_BeforeExpire(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetAmount, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        uint32 _twap = 900;
        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, _twap
        );
        (,,,,,, uint32 _twapSeconds) = PendleStrategy(myStrategy).ptInfos(address(PT_ADDR1));
        assertEq(_twap, _twapSeconds);

        address[] memory _activePTMarkets = PendleStrategy(myStrategy).getActivePTs();
        assertEq(1, _activePTMarkets.length);

        // ensure no same PT added
        vm.expectRevert(Constants.PT_ALREADY_EXISTS.selector);
        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, _twap
        );

        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, USDC_TO_PT1_DUMMY_PRICE);
        _zapInWithPendlePT(usdc, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), _assetAmount);
        uint256 _totalAssetsInStrategy = IStrategy(myStrategy).totalAssets();
        uint256 _pt1Balance = ERC20(address(PT_ADDR1)).balanceOf(myStrategy);
        uint256 _pt1PriceFromStrategy = PendleStrategy(myStrategy).getPTPrice(address(PT_ADDR1));
        console.log("_totalAssetsInStrategyAfterBuy1:%d,_assetAmount:%d", _totalAssetsInStrategy, _assetAmount);
        console.log("_pt1Balance:%d,_pt1PriceFromStrategy:%d", _pt1Balance, _pt1PriceFromStrategy);
        assertTrue(
            _assertApproximateEq(
                _totalAssetsInStrategy, PendleStrategy(myStrategy).getPTAmountInAsset(address(PT_ADDR1)), 2 * MIN_SHARE
            )
        );

        // remove PT market before expire
        _prepareSwapForMockRouter(
            mockRouter,
            address(PT_ADDR1),
            usdc,
            usdcWhale,
            (Constants.ONE_ETHER * Constants.ONE_ETHER / USDC_TO_PT1_DUMMY_PRICE)
        );
        bytes memory _callData = _generateSwapCalldataForSell(myStrategy, address(MARKET_ADDR1), 0, _pt1Balance);
        _removePTMarket(address(PT_ADDR1), _callData);
        _checkBasicInvariants(address(stkVault));
        (,,,,,, _twapSeconds) = PendleStrategy(myStrategy).ptInfos(address(PT_ADDR1));
        assertEq(0, _twapSeconds);

        _activePTMarkets = PendleStrategy(myStrategy).getActivePTs();
        assertEq(0, _activePTMarkets.length);

        uint256 _assetInStrategy = ERC20(usdc).balanceOf(myStrategy);
        uint256 _assetInVault = ERC20(usdc).balanceOf(address(stkVault));
        bytes memory EMPTY_CALLDATA;
        vm.startPrank(strategist);
        IStrategy(myStrategy).collect(_assetInStrategy, EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(_assetInStrategy, ERC20(usdc).balanceOf(address(stkVault)) - _assetInVault);

        // ensure removed PT can't be removed again
        vm.expectRevert(Constants.PT_NOT_FOUND.selector);
        _removePTMarket(address(PT_ADDR1), _callData);
    }

    function test_Remove_PTMarket_AfterExpire(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetAmount, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        uint32 _twap = 900;
        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, _twap
        );
        (,,,,,, uint32 _twapSeconds) = PendleStrategy(myStrategy).ptInfos(address(PT_ADDR1));
        assertEq(_twap, _twapSeconds);

        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, USDC_TO_PT1_DUMMY_PRICE);
        _zapInWithPendlePT(usdc, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), _assetAmount);
        uint256 _pt1Balance = ERC20(address(PT_ADDR1)).balanceOf(myStrategy);

        address[] memory _activePTMarkets = PendleStrategy(myStrategy).getActivePTs();
        assertEq(1, _activePTMarkets.length);

        // forward to market expire
        vm.warp(block.timestamp + Constants.ONE_YEAR);
        assertTrue(MARKET_ADDR1.isExpired());

        // remove PT market after expire
        _prepareSwapForMockRouter(mockRouter, address(PT_ADDR1), usdc, usdcWhale, 150e16);
        bytes memory _callData = _generateSwapCalldataForRedeem(myStrategy, YT_ADDR1, 0, _pt1Balance);
        _removePTMarket(address(PT_ADDR1), _callData);
        _checkBasicInvariants(address(stkVault));
        (,,,,,, _twapSeconds) = PendleStrategy(myStrategy).ptInfos(address(PT_ADDR1));
        assertEq(0, _twapSeconds);

        _activePTMarkets = PendleStrategy(myStrategy).getActivePTs();
        assertEq(0, _activePTMarkets.length);

        uint256 _assetInStrategy = IStrategy(myStrategy).totalAssets();
        uint256 _assetInVault = ERC20(usdc).balanceOf(address(stkVault));
        bytes memory EMPTY_CALLDATA;
        vm.startPrank(strategist);
        IStrategy(myStrategy).collectAll(EMPTY_CALLDATA);
        vm.stopPrank();
        assertEq(_assetInStrategy, ERC20(usdc).balanceOf(address(stkVault)) - _assetInVault);

        // ensure expired PT can't be added
        vm.expectRevert(Constants.PT_ALREADY_MATURED.selector);
        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );
    }

    function test_SetAssetOracle() public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        vm.startPrank(strategyOwner);
        PendleStrategy(myStrategy).setAssetOracle(usdc, Constants.ZRO_ADDR);
        vm.stopPrank();

        address USDT_USD_FEED = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
        vm.expectEmit();
        emit AssetOracleAdded(usdc, USDT_USD_FEED);

        vm.startPrank(strategyOwner);
        PendleStrategy(myStrategy).setAssetOracle(usdc, USDT_USD_FEED);
        vm.stopPrank();

        vm.expectRevert(Constants.PT_NOT_FOUND.selector);
        pendleHelper._checkValidityWithMarket(usdc, Constants.ZRO_ADDR, true);
        vm.expectRevert(Constants.PT_NOT_MATURED.selector);
        pendleHelper._checkValidityWithMarket(usdc, address(MARKET_ADDR1), false);

        // forward to market expire
        vm.warp(block.timestamp + Constants.ONE_YEAR);
        assertTrue(MARKET_ADDR1.isExpired());
        vm.expectRevert(Constants.PT_ALREADY_MATURED.selector);
        pendleHelper._checkValidityWithMarket(usdc, address(MARKET_ADDR1), true);

        bytes memory EMPTY_CALLDATA;
        vm.expectRevert(Constants.INVALID_HELPER_CALLER.selector);
        pendleHelper._swapPTForRollOver(
            address(PT_ADDR1), address(PT_ADDR2), magicPTAmount, EMPTY_CALLDATA, TARGET_SELECTOR_PENDLE, usdc
        );
        vm.expectRevert(Constants.INVALID_HELPER_CALLER.selector);
        pendleHelper._swapAssetForPT(usdc, address(PT_ADDR2), magicUSDCAmount, EMPTY_CALLDATA, TARGET_SELECTOR_PENDLE);
        vm.expectRevert(Constants.INVALID_HELPER_CALLER.selector);
        pendleHelper._swapPTForAsset(usdc, address(PT_ADDR2), magicUSDCAmount, EMPTY_CALLDATA, TARGET_SELECTOR_PENDLE);
    }

    function test_Invalid_Swap_Calldata(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetAmount, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );
        _addPTMarket(address(MARKET_ADDR2), UNDERLYING_YIELD_ADDR2, YIELD_TOKEN_FEED2, 100);
        bytes memory EMPTY_CALLDATA;

        vm.startPrank(strategist);
        PendleStrategy(myStrategy).allocate(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        bytes memory _invalidSwapData = abi.encodeWithSelector(PendleStrategy.collectAll.selector);
        vm.expectRevert(Constants.INVALID_SWAP_CALLDATA.selector);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).buyPTWithAsset(usdc, address(PT_ADDR1), _assetAmount, _invalidSwapData);
        vm.stopPrank();

        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, USDC_TO_PT1_DUMMY_PRICE);
        _zapInWithPendlePT(usdc, myStrategy, address(PT_ADDR1), address(MARKET_ADDR1), _assetAmount);

        uint256 _pt1Balance = ERC20(address(PT_ADDR1)).balanceOf(myStrategy);
        vm.expectRevert(Constants.INVALID_SWAP_CALLDATA.selector);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).rolloverPT(address(PT_ADDR1), address(PT_ADDR2), _pt1Balance, _invalidSwapData);
        vm.stopPrank();

        vm.expectRevert(Constants.INVALID_SWAP_CALLDATA.selector);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).sellPTForAsset(usdc, address(PT_ADDR1), _pt1Balance, _invalidSwapData);
        vm.stopPrank();

        // forward to market expire
        vm.warp(block.timestamp + Constants.ONE_YEAR);
        assertTrue(MARKET_ADDR1.isExpired());

        vm.expectRevert(Constants.INVALID_SWAP_CALLDATA.selector);
        vm.startPrank(strategist);
        PendleStrategy(myStrategy).redeemPTForAsset(usdc, address(PT_ADDR1), _pt1Balance, _invalidSwapData);
        vm.stopPrank();

        vm.expectRevert(Constants.ONLY_FOR_STRATEGIST_OR_OWNER.selector);
        vm.startPrank(_user);
        PendleStrategy(myStrategy).redeemPTForAsset(usdc, address(PT_ADDR1), _pt1Balance, _invalidSwapData);
        vm.stopPrank();
    }

    function test_Pause_PendleStrategy(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);

        address _user = TestUtils._getSugarUser();

        (uint256 _assetAmount, uint256 _share) = TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        TestUtils._toggleVaultPause(address(stkVault), true);

        vm.expectRevert(Constants.VAULT_ALREADY_PAUSED.selector);
        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );

        TestUtils._toggleVaultPause(address(stkVault), false);
        _addPTMarketWithIntermediateOracle(
            address(MARKET_ADDR1), UNDERLYING_YIELD_ADDR1, UNDERLYING_YIELD_ADDR1, YIELD_TOKEN_FEED1, 100
        );
        assertEq(1, PendleStrategy(myStrategy).getActivePTs().length);
    }

    function _zapInWithPendlePT(
        address _assetToken,
        address _strategy,
        address _pendlePT,
        address _pendleMarket,
        uint256 _assetAmount
    ) internal {
        bytes memory _callData;

        if (
            (_pendlePT == address(PT_ADDR1) && _assetAmount == magicUSDCAmount)
                || (_pendlePT == address(PT_ADDR2) && _assetAmount == magicUSDCAmount)
        ) {
            _callData = _getZapInCalldataFromSDK(_pendlePT, _assetAmount);
        } else {
            // calldata for dummy mock router
            _callData = _generateSwapCalldataForBuy(_strategy, _pendleMarket, 0, _assetAmount);
        }

        vm.startPrank(strategist);
        PendleStrategy(myStrategy).buyPTWithAsset(_assetToken, _pendlePT, _assetAmount, _callData);
        vm.stopPrank();
    }

    function _stormOutFromPendlePT(
        address _assetToken,
        address _strategy,
        address _pendlePT,
        address _pendleMarket,
        uint256 _ptAmount
    ) internal {
        bytes memory _callData;

        if (_pendlePT == address(PT_ADDR1) && _ptAmount == magicPTAmount) {
            _callData = _getStormOutCalldataFromSDK(_pendlePT, _ptAmount);
        } else {
            // calldata for dummy mock router
            _callData = _generateSwapCalldataForSell(_strategy, _pendleMarket, 0, _ptAmount);
        }

        vm.startPrank(strategist);
        PendleStrategy(myStrategy).sellPTForAsset(_assetToken, _pendlePT, _ptAmount, _callData);
        vm.stopPrank();
    }

    function _redeemAfterPendlePTExpire(
        address _assetToken,
        address _strategy,
        address _pendlePT,
        address _ytToken,
        uint256 _ptAmount
    ) internal {
        bytes memory _callData;

        if (_pendlePT == address(PT_ADDR2) && _ptAmount == magicPTAmount) {
            _callData = _getRedeemAfterExpireCalldataFromSDK(_pendlePT, _ptAmount);
        } else {
            // calldata for dummy mock router
            _callData = _generateSwapCalldataForRedeem(_strategy, _ytToken, 0, _ptAmount);
        }

        vm.startPrank(strategist);
        PendleStrategy(myStrategy).redeemPTForAsset(_assetToken, _pendlePT, _ptAmount, _callData);
        vm.stopPrank();
    }

    function _addPTMarket(
        address _pendleMarket,
        address _underlyingYieldToken,
        address _underlyingOracle,
        uint32 _twapSeconds
    ) internal {
        vm.startPrank(strategyOwner);
        PendleStrategy(myStrategy).addPT(
            _pendleMarket, _underlyingYieldToken, _underlyingOracle, Constants.ZRO_ADDR, _twapSeconds
        );
        vm.stopPrank();
    }

    function _addPTMarketWithIntermediateOracle(
        address _pendleMarket,
        address _underlyingYieldToken,
        address _underlyingOracle,
        address _intermediateOracle,
        uint32 _twapSeconds
    ) internal {
        vm.startPrank(strategyOwner);
        PendleStrategy(myStrategy).addPT(
            _pendleMarket, _underlyingYieldToken, _underlyingOracle, _intermediateOracle, _twapSeconds
        );
        vm.stopPrank();
    }

    function _removePTMarket(address _pendlePT, bytes memory _swapData) internal {
        vm.startPrank(strategyOwner);
        PendleStrategy(myStrategy).removePT(_pendlePT, _swapData);
        vm.stopPrank();
    }

    function _createPendleStrategy(bool _useMockRouter) internal returns (address, address) {
        bytes memory _constructorArgs = abi.encode(usdc, address(stkVault), USDC_USD_Feed);
        address _deployedStrategy = deployWithCreationCodeAndConstructorArgs(
            PENDLE_STRATEGY_NAME, type(PendleStrategy).creationCode, _constructorArgs
        );

        assertEq(_deployedStrategy, PENDLE_STRATEGY_ADDRESS);

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(_deployedStrategy, MAX_USDC_ALLOWED);
        vm.stopPrank();

        strategyOwner = PendleStrategy(_deployedStrategy).owner();

        address _routerAddr = (_useMockRouter ? address(mockRouter) : pendleRouterV4);
        pendleHelper = new PendleHelper(_deployedStrategy, _routerAddr, address(swapper));

        vm.startPrank(PendleStrategy(_deployedStrategy).owner());
        PendleStrategy(_deployedStrategy).setSwapper(address(swapper));
        PendleStrategy(_deployedStrategy).setPendleHelper(address(pendleHelper));
        vm.stopPrank();

        return (_deployedStrategy, PendleStrategy(_deployedStrategy).strategist());
    }

    function _getZapInCalldataFromSDK(address _pendlePT, uint256 _assetAmount) internal view returns (bytes memory) {
        bytes memory _callData;
        if (_pendlePT == address(PT_ADDR1) && _assetAmount == magicUSDCAmount) {
            // slippage 1% with aggragator enabled
            _callData =
                hex"c81f847a00000000000000000000000063670e16de53f8eb1cef55a46120bf137c4020f40000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac000000000000000000000000000000000000000000000042feb29d0fa502ce0c000000000000000000000000000000000000000000000021d5f7f23b9e542a010000000000000000000000000000000000000000000000470e22497d32e3f1ce000000000000000000000000000000000000000000000043abefe4773ca85402000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000cc0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000499602d20000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000fe6228a3866426e96611ed7a3d0dee918244fcb300000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a24e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000007400000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000003e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d44400000000000000000000000000000000000000000000000000000000499602d2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000053e2d6238da3000000320000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d44400000000000000000000000000000000000000000000000000000000498bc73c0000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000346dc5d638865000000c800000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000003b9adeb6ea4550000000000000038d7fe0da9030bd31c000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f94600000000000000000000000000000000000000000000000000000000499602d20000000000000000000000000000000000000000000000384678f3ec711881a30000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000499602d200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002887b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22313233342e343839393234353534333235222c22416d6f756e744f7574555344223a22313233332e32343732313633383636313334222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2231303438353831353630353039353235363434303630222c2254696d657374616d70223a313734393130363436302c22526f7574654944223a2266363166363064632d306138662d343630332d383464612d6264396432306162346431303a65656265313961392d376235302d343133312d623036302d333039383035393030306632222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a224d3737624779505a4b756a7a77692f3667704675794e552f49536f3434356a51775833306f6f444f71485a73516c7077762f7856745470673249545a64354b7a463939416972743359664239654f7a2f5534694134704c76466f45652b6f545630426c5756434f58395944764f426b30616b594e3777747377776331796878433436774e686439653449746c7237507270644b43536f745536755658713038354332787430393434705248314975356236666c43396e513156496250752b59525a4f4b5a65426a454c2b56593854574c7836546c7a764736786168533646444178734961496a51796b673365585777736c2b334b5551536c7a4376794f437a516979456379414a4f4b6a49426647347650346d7572433868346e4e2f3863644a4b3663706e694c70446b51446e4155574666387763744d5257597334363151544d354b43694c57377933314270497179302b2b4765513d3d227d7d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        } else if (_pendlePT == address(PT_ADDR2) && _assetAmount == magicUSDCAmount) {
            // slippage 1% with aggragator enabled
            _callData =
                hex"c81f847a00000000000000000000000063670e16de53f8eb1cef55a46120bf137c4020f4000000000000000000000000dace1121e10500e9e29d071f01593fd76b000f08000000000000000000000000000000000000000000000043392871a281d3b736000000000000000000000000000000000000000000000021f37e7247bb1ac3f70000000000000000000000000000000000000000000000474c2323303c1e9b87000000000000000000000000000000000000000000000043e6fce48f763587ef000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000420000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000499602d20000000000000000000000006b175474e89094c44da98b954eedeac495271d0f000000000000000000000000fe6228a3866426e96611ed7a3d0dee918244fcb300000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000060000000000000000000000006a000f20005980200259b80c5102003040001068000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000184987e7d8e000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000006b175474e89094c44da98b954eedeac495271d0f00000000000000000000000000000000000000000000000000000000499602d200000000000000000000000000000000000000000000004241bd916277fe18000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e8d4a51000000000000000000000000000f6e72db5454dd049d0788e411b06cfaf16853042000000000000000000000000f6e72db5454dd049d0788e411b06cfaf168530420953a2ce54264b28aeb3ec1b423cd13d00000000000000000000000001596a4f000000000000000000000000888888888889758f76e7103c6cbf23abbf58f94600000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        }
        return _callData;
    }

    function _getStormOutCalldataFromSDK(address _pendlePT, uint256 _ptAmount) internal view returns (bytes memory) {
        bytes memory _callData;
        if (_pendlePT == address(PT_ADDR1) && _ptAmount == magicPTAmount) {
            // slippage 1% with aggragator enabled
            _callData =
                hex"594a88cc00000000000000000000000063670e16de53f8eb1cef55a46120bf137c4020f40000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac0000000000000000000000000000000000000000000000410d586a20a4c0000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000045fba7f30000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000fe6228a3866426e96611ed7a3d0dee918244fcb300000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000a04e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000007400000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000003e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d444000000000000000000000000000000000000000000000037b69344c77bf9677a0000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000346dc5d638865000000c80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d44400000000000000000000000000000000000000000000000000000000480fb9e5000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000053e2d6238da300000032000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000004b9000000000000000000000000481a8e030000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000037b69344c77bf9677a000000000000000000000000000000000000000000000000000000004761f81c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000037b69344c77bf9677a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000027d7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22313230392e37303431363738343738393138222c22416d6f756e744f7574555344223a22313231302e32323736343939303331333131222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2231323039363939383433222c2254696d657374616d70223a313734393131313235322c22526f7574654944223a2263366431333566622d646232632d343463662d393530612d3461643165396363623466613a64366230623639362d303335642d346137342d626463622d303430383364656333646339222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a22546b4872367a5368473769756241425867765151524a7330517363664b322f344c784e39692b4570556a5a6474536f70363755465637464f54375a7846465572516d4a6d756e4e3136344f364a47427977642b6b3041796130775042704d397632564c35466c6249566a2b7277677130626f31612b7969774f71416c7447564a56703064526a687a506e6b37334575487459596652686956436544433751343449535741476b7653796164595a5a6f556e4d70662f34374b5739653235474b36467a5866506657742f734f3863445a4277566d5758686550686b44387076344465486370685a556d6a39384269786d4769694d3569445631656f3254706e62745a54665463427a78526774314b374c564b44324d4f6f45764b6b2b454b76646764416b47646d5a55516243595537312f476e356a62616b687177354b36497375736e6175674e675341344f504c2b76485a65724261413d3d227d7d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        }
        return _callData;
    }

    function _getRedeemAfterExpireCalldataFromSDK(address _pendlePT, uint256 _ptAmount)
        internal
        view
        returns (bytes memory)
    {
        bytes memory _callData;
        if (_pendlePT == address(PT_ADDR2) && _ptAmount == magicPTAmount) {
            // slippage 1% with aggragator enabled
            _callData =
                hex"47f1de2200000000000000000000000063670e16de53f8eb1cef55a46120bf137c4020f40000000000000000000000004eb0bb058bcfeac8a2b3c2fc3cae2b8ad7ff7f6e0000000000000000000000000000000000000000000000410d586a20a4c000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000046cf7100000000000000000000000000dc035d45d973e3ec169d2276ddab16f1e407384f000000000000000000000000fe6228a3866426e96611ed7a3d0dee918244fcb300000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000060000000000000000000000006a000f20005980200259b80c51020030400010680000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000002a4e3ead59e000000000000000000000000000010036c0190e009a000d0fc3541100a07380a000000000000000000000000dc035d45d973e3ec169d2276ddab16f1e407384f000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000425a698af856200000000000000000000000000000000000000000000000000000000000004839fd800000000000000000000000000000000000000000000000000000000048f4c2000e384003182143348bc1727135e6fb0800000000000000000000000001596a77000000000000000000000000888888888889758f76e7103c6cbf23abbf58f9460000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000100a188eec8f81263234da3622a406892f3d630f98c000000a000000000ff030000000000000000000000000000000000000000000000000000000000008d7ef9bb0000000000000000000000006a000f20005980200259b80c51020030400010680000000000000000000000000000000000000000000000000000000048f4c2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e8d4a5100000000000000000000000000000000000000000000000000000000000";
        }
        return _callData;
    }
}
