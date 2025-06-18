// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {SparkleXVault} from "../../src/SparkleXVault.sol";
import {PendleAAVEStrategy} from "../../src/strategies/aave/PendleAAVEStrategy.sol";
import {AAVEHelper} from "../../src/strategies/aave/AAVEHelper.sol";
import {TokenSwapper} from "../../src/utils/TokenSwapper.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {IWithdrawRequestNFT} from "../../interfaces/etherfi/IWithdrawRequestNFT.sol";
import {IPool} from "../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../interfaces/aave/IAaveOracle.sol";
import {IPriceOracleGetter} from "../../interfaces/aave/IPriceOracleGetter.sol";
import {TestUtils} from "../TestUtils.sol";
import {Constants} from "../../src/utils/Constants.sol";
import {IPAllActionV3} from "@pendle/contracts/interfaces/IPAllActionV3.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IPMarketV3} from "@pendle/contracts/interfaces/IPMarketV3.sol";
import {PendleHelper} from "../../src/strategies/pendle/PendleHelper.sol";
import {DummyDEXRouter} from "../mock/DummyDEXRouter.sol";
import {BasePendleStrategyTest} from "./BasePendleStrategyTest.t.sol";

// run this test with mainnet fork
// forge test --fork-url <rpc_url> --match-path USDCPendleAAVEStrategyTest -vvv
contract USDCPendleAAVEStrategyTest is BasePendleStrategyTest {
    AAVEHelper public aaveHelper;
    address public aaveHelperOwner;
    address public swapperOwner;
    uint256 public magicUSDCAmountLeveraged = 9000000000; //9000e6
    uint256 public magicUSDCAmountCollect = 365000000; //365e6
    uint256 public magicPTAmountRedeemed = 200000000000000000000; //200e18
    uint256 public magicPTAmountCollected = 3600000000000000000000; //3600e18
    uint256 public magicPTAmountCollectAll = 6400000000000000000000; //6400e18

    ///////////////////////////////
    // Note this address is only meaningful for this test
    ///////////////////////////////
    address public constant PENDLE_AAVE_STRATEGY_ADDRESS = 0xf10b150ae0c2D2C0dF82AE181dBcF2eA71573401;
    string public constant PENDLE_AAVE_STRATEGY_NAME = "sparklex.pendle.aave.strategy";

    ///////////////////////////////
    // mainnet pendle PT pools: active
    ///////////////////////////////
    IPool aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address public constant sUSDe = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant sUSDe_FEED = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099;

    // USDe JUL31 market
    IPPrincipalToken PT_ADDR3 = IPPrincipalToken(0x917459337CaAC939D41d7493B3999f571D20D667);
    address YT_ADDR3 = 0x733Ee9Ba88f16023146EbC965b7A1Da18a322464;
    IPMarketV3 MARKET_ADDR3 = IPMarketV3(0x9Df192D13D61609D1852461c4850595e1F56E714);
    address constant PT3_Whale = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant YIELD_TOKEN_FEED3 = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    uint256 public constant USDC_TO_PT3_DUMMY_PRICE = 1010000000000000000; //1.01
    address public constant UNDERLYING_YIELD_ADDR3 = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;

    // sUSDe JUL31 market
    address public constant PT_ATOKEN_ADDR1 = 0xDE6eF6CB4aBd3A473ffC2942eEf5D84536F8E864;
    // USDe JUL31 market
    address public constant PT_ATOKEN_ADDR3 = 0x312ffC57778CEfa11989733e6E08143E7E229c1c;

    function setUp() public {
        stkVault = new SparkleXVault(ERC20(usdc), "SparkleXVault", "SPXV");
        stkVOwner = stkVault.owner();
        _changeWithdrawFee(stkVOwner, address(stkVault), 0);

        vm.startPrank(stkVOwner);
        stkVault.setEarnRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        swapper = new TokenSwapper();
        mockRouter = new DummyDEXRouter();
        swapperOwner = swapper.owner();
    }

    function test_GetMaxLTV() public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        uint256 _ltv = aaveHelper.getMaxLTV();
        assertTrue(_ltv >= 9000 && _ltv <= 9060);
    }

    function test_Basic_Flow_PendleAAVE(uint256 _testVal) public {
        string memory MAINNET_RPC = vm.envString("TESTNET_RPC");
        uint256 forkId = vm.createFork(MAINNET_RPC, 22727695);
        vm.selectFork(forkId);
        console.log("_block:%d,_rpc:%s", block.number, MAINNET_RPC);

        setUp();

        (myStrategy, strategist) = _createPendleStrategy(false);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        uint256 _initSupply = magicUSDCAmount;
        uint256 _initDebt = magicUSDCAmountLeveraged; //aaveHelper.previewLeverageForInvest(_initSupply, _initDebt);

        bytes memory _prepareCALLDATA = _getZapInCalldataFromSDK(address(PT_ADDR1), magicUSDCAmount);
        bytes memory _flCALLDATA = _getZapInCalldataFromSDK(address(PT_ADDR1), _initDebt);

        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).invest(
            _initSupply, _initDebt, abi.encode(_prepareCALLDATA, _initDebt, _flCALLDATA)
        );
        vm.stopPrank();

        _printAAVEPosition();
        (uint256 _netSupply, uint256 _debt, uint256 _totalSupply) =
            PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(true);
        assertTrue(_assertApproximateEq(_totalSupply, (_initSupply + _initDebt), 20 * MIN_SHARE));
        _checkBasicInvariants(address(stkVault));

        (, uint256 _debtInSupply, uint256 _totalInSupply) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(false);

        uint256 _toRedeem = magicPTAmountRedeemed; //aaveHelper.getMaxRedeemableAmount();
        assertTrue(_toRedeem < type(uint256).max);
        bytes memory _redeemCALLDATA = _getStormOutCalldataFromSDK(address(PT_ADDR1), _toRedeem);

        vm.expectRevert(Constants.TOO_MUCH_SUPPLY_TO_REDEEM.selector);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).redeem(type(uint256).max, _redeemCALLDATA);
        vm.stopPrank();

        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).redeem(_toRedeem, _redeemCALLDATA);
        vm.stopPrank();

        (, uint256 _debtInSupply2, uint256 _totalInSupply2) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(false);
        assertTrue(_assertApproximateEq(_totalInSupply, (_totalInSupply2 + _toRedeem), 100 * BIGGER_TOLERANCE));
        console.log("_debtInSupply:%d,_debtInSupply2:%d", _debtInSupply, _debtInSupply2);
        assertTrue(_assertApproximateEq(_debtInSupply, (_debtInSupply2 + _toRedeem), 100 * BIGGER_TOLERANCE));

        _printAAVEPosition();
        _checkBasicInvariants(address(stkVault));

        uint256[] memory _previewPortionCollect = aaveHelper.previewCollect(magicUSDCAmountCollect);
        assertEq(5, _previewPortionCollect.length);
        console.log(
            "_previewPortionCollect[0]:%d,_previewPortionCollect[4]:%d",
            _previewPortionCollect[0],
            _previewPortionCollect[4]
        );

        bytes memory _collectCALLDATA = _getStormOutCalldataFromSDK(address(PT_ADDR1), magicPTAmountCollected);
        uint256 _vaultBalance = ERC20(usdc).balanceOf(address(stkVault));

        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(swapperOwner);
        swapper.setSlippage(Constants.TOTAL_BPS);
        vm.stopPrank();

        vm.startPrank(swapperOwner);
        swapper.setSlippage(9500);
        vm.stopPrank();
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).collect(magicUSDCAmountCollect, _collectCALLDATA);
        vm.stopPrank();
        uint256 _vaultBalanceAfter = ERC20(usdc).balanceOf(address(stkVault));
        console.log("_vaultBalance:%d,_vaultBalanceAfter:%d", _vaultBalance, _vaultBalanceAfter);
        assertTrue(_assertApproximateEq(magicUSDCAmountCollect, (_vaultBalanceAfter - _vaultBalance), 100 * MIN_SHARE));
        _checkBasicInvariants(address(stkVault));

        (,, _totalInSupply) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(false);
        console.log("_totalInSupply:%d", _totalInSupply);
        bytes memory _collectAllCALLDATA = _getStormOutCalldataFromSDK(address(PT_ADDR1), magicPTAmountCollectAll);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).collectAll(_collectAllCALLDATA);
        vm.stopPrank();
        _checkBasicInvariants(address(stkVault));

        (uint256 _netSupplyInAsset,,) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(true);
        uint256 _ptValueInAsset =
            pendleHelper._getAmountInAsset(usdc, address(PT_ADDR1), ERC20(address(PT_ADDR1)).balanceOf(myStrategy));
        assertEq(
            _netSupplyInAsset + _ptValueInAsset + ERC20(usdc).balanceOf(myStrategy),
            PendleAAVEStrategy(myStrategy).totalAssets()
        );
    }

    function test_Change_PT_Supply(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        uint256 _initSupply = magicUSDCAmount;
        uint256 _initDebt = magicUSDCAmountLeveraged; //aaveHelper.previewLeverageForInvest(_initSupply, _initDebt);

        bytes memory _prepareCALLDATA =
            _generateSwapCalldataForBuy(myStrategy, address(MARKET_ADDR1), 0, magicUSDCAmount);
        bytes memory _flCALLDATA = _generateSwapCalldataForBuy(myStrategy, address(MARKET_ADDR1), 0, _initDebt);
        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, USDC_TO_PT1_DUMMY_PRICE);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).invest(
            _initSupply, _initDebt, abi.encode(_prepareCALLDATA, _initDebt, _flCALLDATA)
        );
        vm.stopPrank();
        _checkBasicInvariants(address(stkVault));

        vm.expectRevert(Constants.POSITION_STILL_IN_USE.selector);
        vm.startPrank(aaveHelperOwner);
        aaveHelper.setTokens(ERC20(address(PT_ADDR3)), ERC20(usdc), ERC20(PT_ATOKEN_ADDR3), 0);
        vm.stopPrank();

        (,, uint256 _totalInSupply) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(false);
        bytes memory _collectAllCALLDATA =
            _generateSwapCalldataForSell(myStrategy, address(MARKET_ADDR1), 0, _totalInSupply);
        _prepareSwapForMockRouter(
            mockRouter,
            address(PT_ADDR1),
            usdc,
            usdcWhale,
            (Constants.ONE_ETHER * Constants.ONE_ETHER / USDC_TO_PT1_DUMMY_PRICE)
        );
        uint256 _vaultBalance = ERC20(usdc).balanceOf(address(stkVault));
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).collectAll(_collectAllCALLDATA);
        vm.stopPrank();
        uint256 _vaultBalanceAfter = ERC20(usdc).balanceOf(address(stkVault));
        console.log("_vaultBalance:%d,_vaultBalanceAfter:%d", _vaultBalance, _vaultBalanceAfter);
        assertTrue(_assertApproximateEq(magicUSDCAmount, (_vaultBalanceAfter - _vaultBalance), 10 * MIN_SHARE));
        _checkBasicInvariants(address(stkVault));
        (,, _totalInSupply) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(false);
        assertEq(0, _totalInSupply);
        assertEq(0, ERC20(address(PT_ADDR1)).balanceOf(myStrategy));

        // change to new PT
        _changeSettingToNewPT();

        _prepareCALLDATA = _generateSwapCalldataForBuy(myStrategy, address(MARKET_ADDR3), 0, magicUSDCAmount);
        _flCALLDATA = _generateSwapCalldataForBuy(myStrategy, address(MARKET_ADDR3), 0, _initDebt);
        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR3), PT3_Whale, USDC_TO_PT3_DUMMY_PRICE);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).invest(
            _initSupply, _initDebt, abi.encode(_prepareCALLDATA, _initDebt, _flCALLDATA)
        );
        vm.stopPrank();
        _checkBasicInvariants(address(stkVault));
        (,, uint256 _totalInAsset) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(true);
        _assertApproximateEq(_totalInAsset, (_initSupply + _initDebt), 1 * MIN_SHARE);
    }

    function test_FullDeloop_Pendle(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );
        bytes memory EMPTY_CALLDATA;

        uint256 _initDebt = magicUSDCAmountLeveraged; //aaveHelper.previewLeverageForInvest(magicUSDCAmount, _initDebt);
        bytes memory _prepareCALLDATA =
            _generateSwapCalldataForBuy(myStrategy, address(MARKET_ADDR1), 0, magicUSDCAmount);
        bytes memory _flCALLDATA = _generateSwapCalldataForBuy(myStrategy, address(MARKET_ADDR1), 0, _initDebt);
        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, USDC_TO_PT1_DUMMY_PRICE);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).invest(
            magicUSDCAmount, _initDebt, abi.encode(_prepareCALLDATA, _initDebt, _flCALLDATA)
        );
        vm.stopPrank();

        vm.expectRevert(Constants.TOO_MUCH_SUPPLY_TO_REDEEM.selector);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).redeem(type(uint256).max, EMPTY_CALLDATA);
        vm.stopPrank();

        _prepareSwapForMockRouter(
            mockRouter,
            address(PT_ADDR1),
            usdc,
            usdcWhale,
            (Constants.ONE_ETHER * Constants.ONE_ETHER / USDC_TO_PT1_DUMMY_PRICE)
        );
        (, uint256 _debtInAsset,) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(true);

        for (uint256 i = 0; i < 30; i++) {
            uint256 _toRedeem = aaveHelper.getMaxRedeemableAmount();

            bytes memory _redeemCALLDATA = _generateSwapCalldataForSell(myStrategy, address(MARKET_ADDR1), 0, _toRedeem);
            vm.startPrank(strategist);
            PendleAAVEStrategy(myStrategy).redeem(_toRedeem, _redeemCALLDATA);
            vm.stopPrank();

            (, _debtInAsset,) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(true);
            console.log("i:%d,_debtInAsset:%d", (i + 1), _debtInAsset);
            if (_debtInAsset == 0) {
                break;
            }
        }
        assertEq(_debtInAsset, 0);

        // redeem anything left from AAVE
        (uint256 _netSupply,,) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(false);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).redeem(_netSupply, EMPTY_CALLDATA);
        vm.stopPrank();
        (_netSupply,,) = PendleAAVEStrategy(myStrategy).getNetSupplyAndDebt(false);
        assertEq(_netSupply, 0);

        // sell PT for underlying yield token
        DummyDEXRouter.TokenOutput memory _sellOutput = _getDummyTokenOutput(UNDERLYING_YIELD_ADDR3, 0);
        DummyDEXRouter.LimitOrderData memory emptyLimit;
        uint256 _ptResidueAmount = ERC20(address(PT_ADDR1)).balanceOf(myStrategy);
        bytes memory _sellCALLDATA = abi.encodeWithSelector(
            DummyDEXRouter.swapExactPtForToken.selector,
            myStrategy,
            address(MARKET_ADDR1),
            _ptResidueAmount,
            _sellOutput,
            emptyLimit
        );
        _prepareSwapForMockRouter(
            mockRouter, address(PT_ADDR1), address(UNDERLYING_YIELD_ADDR3), mockRouter._usdeWhale(), 150e16
        );
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).swapPTForAsset(UNDERLYING_YIELD_ADDR3, _ptResidueAmount, false, _sellCALLDATA);
        vm.stopPrank();
        assertEq(0, ERC20(address(PT_ADDR1)).balanceOf(myStrategy));

        // change to new PT
        _changeSettingToNewPT();

        // buy new PT with underlying yield token
        uint256 _yieldTokenBalance = ERC20(UNDERLYING_YIELD_ADDR3).balanceOf(myStrategy);
        DummyDEXRouter.TokenInput memory _buyInput = _getDummyTokenInput(UNDERLYING_YIELD_ADDR3, _yieldTokenBalance);
        bytes memory _buyCALLDATA = abi.encodeWithSelector(
            DummyDEXRouter.swapExactTokenForPt.selector,
            myStrategy,
            address(MARKET_ADDR3),
            0,
            _pendleSwapApproxParams,
            _buyInput,
            emptyLimit
        );
        _prepareSwapForMockRouter(
            mockRouter, address(UNDERLYING_YIELD_ADDR3), address(PT_ADDR3), PT3_Whale, USDC_TO_PT3_DUMMY_PRICE
        );
        {
            vm.expectRevert(Constants.ONLY_FOR_STRATEGIST_OR_OWNER.selector);
            vm.startPrank(_user);
            PendleAAVEStrategy(myStrategy).buyPTWithAsset(UNDERLYING_YIELD_ADDR3, _yieldTokenBalance, _buyCALLDATA);
            vm.stopPrank();
        }
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).buyPTWithAsset(UNDERLYING_YIELD_ADDR3, _yieldTokenBalance, _buyCALLDATA);
        vm.stopPrank();
        assertEq(0, ERC20(UNDERLYING_YIELD_ADDR3).balanceOf(myStrategy));
        uint256 _newPTBalance = ERC20(address(PT_ADDR3)).balanceOf(myStrategy);
        assertTrue(_yieldTokenBalance <= _newPTBalance);
        uint256 _ptValueInAsset = pendleHelper._getAmountInAsset(usdc, address(PT_ADDR3), _newPTBalance);
        assertEq(_ptValueInAsset + ERC20(usdc).balanceOf(myStrategy), PendleAAVEStrategy(myStrategy).totalAssets());
    }

    function test_Collect_Zero_Leverage_Pendle(uint256 _testVal) public {
        (myStrategy, strategist) = _createPendleStrategy(true);
        _fundFirstDepositGenerouslyWithERC20(mockRouter, address(stkVault), usdcPerETH);
        address _user = TestUtils._getSugarUser();

        TestUtils._makeVaultDepositWithMockRouter(
            mockRouter, address(stkVault), _user, usdcPerETH, _testVal, 10 ether, 100 ether
        );

        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(aaveHelperOwner);
        aaveHelper.setLeverageRatio(Constants.TOTAL_BPS + 1);
        vm.stopPrank();

        vm.startPrank(aaveHelperOwner);
        aaveHelper.setLeverageRatio(0);
        vm.stopPrank();

        bytes memory EMPTY_CALLDATA;
        bytes memory _prepareCALLDATA =
            _generateSwapCalldataForBuy(myStrategy, address(MARKET_ADDR1), 0, magicUSDCAmount);
        _prepareSwapForMockRouter(mockRouter, usdc, address(PT_ADDR1), PT1_Whale, USDC_TO_PT1_DUMMY_PRICE);
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).allocate(magicUSDCAmount, abi.encode(_prepareCALLDATA, 0, EMPTY_CALLDATA));
        vm.stopPrank();

        _prepareSwapForMockRouter(
            mockRouter,
            address(PT_ADDR1),
            usdc,
            usdcWhale,
            (Constants.ONE_ETHER * Constants.ONE_ETHER / USDC_TO_PT1_DUMMY_PRICE)
        );

        uint256[] memory _previewCollect = aaveHelper.previewCollect(magicUSDCAmount);
        assertEq(3, _previewCollect.length);
        assertEq(2, _previewCollect[0]);

        bytes memory _collectCALLDATA =
            _generateSwapCalldataForSell(myStrategy, address(MARKET_ADDR1), 0, _previewCollect[1]);
        uint256 _assetBalance = ERC20(usdc).balanceOf(address(stkVault));
        vm.startPrank(strategist);
        PendleAAVEStrategy(myStrategy).collect(magicUSDCAmount, _collectCALLDATA);
        vm.stopPrank();
        assertTrue(
            _assertApproximateEq(
                magicUSDCAmount, (ERC20(usdc).balanceOf(address(stkVault)) - _assetBalance), 20 * MIN_SHARE
            )
        );
    }

    function test_AAVEHelper_basics() public {
        (myStrategy, strategist) = _createPendleStrategy(true);

        vm.expectRevert(Constants.INVALID_HELPER_CALLER.selector);
        aaveHelper.supplyToAAVE(magicUSDCAmount);
        vm.expectRevert(Constants.INVALID_HELPER_CALLER.selector);
        aaveHelper.borrowFromAAVE(magicUSDCAmount);
        vm.expectRevert(Constants.INVALID_HELPER_CALLER.selector);
        aaveHelper.repayDebtToAAVE(magicUSDCAmount);

        vm.startPrank(usdcWhale);
        ERC20(usdc).transfer(myStrategy, magicUSDCAmount);
        vm.stopPrank();

        uint256[] memory _previewAssets = aaveHelper.previewCollect(magicUSDCAmount);
        assertEq(2, _previewAssets.length);
        assertEq(magicUSDCAmount, _previewAssets[1]);

        vm.startPrank(PT1_Whale);
        ERC20(address(PT_ADDR1)).transfer(myStrategy, magicPTAmount);
        vm.stopPrank();
        _previewAssets = aaveHelper.previewCollect(magicUSDCAmount + magicUSDCAmount / 2);
        assertEq(3, _previewAssets.length);
        assertEq(1, _previewAssets[0]);
        assertEq(magicPTAmount, _previewAssets[2]);

        bytes memory EMPTY_CALLDATA;
        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_CALLER.selector);
        PendleAAVEStrategy(myStrategy).executeOperation(usdc, 0, 1, strategist, EMPTY_CALLDATA);

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_INITIATOR.selector);
        vm.startPrank(address(aavePool));
        PendleAAVEStrategy(myStrategy).executeOperation(usdc, 0, 1, strategist, EMPTY_CALLDATA);
        vm.stopPrank();

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_ASSET.selector);
        vm.startPrank(address(aavePool));
        PendleAAVEStrategy(myStrategy).executeOperation(address(PT_ADDR1), 0, 1, address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_PREMIUM.selector);
        vm.startPrank(address(aavePool));
        PendleAAVEStrategy(myStrategy).executeOperation(usdc, 0, 1, address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();

        vm.expectRevert(Constants.WRONG_AAVE_FLASHLOAN_AMOUNT.selector);
        vm.startPrank(address(aavePool));
        PendleAAVEStrategy(myStrategy).executeOperation(usdc, type(uint256).max, 0, address(myStrategy), EMPTY_CALLDATA);
        vm.stopPrank();
    }

    function _printAAVEPosition() internal view returns (uint256, uint256) {
        (uint256 _cBase, uint256 _dBase, uint256 _leftBase, uint256 _liqThresh, uint256 _ltv, uint256 _healthFactor) =
            aavePool.getUserAccountData(address(myStrategy));
        console.log("_ltv:%d,_liqThresh:%d,_healthFactor:%d", _ltv, _liqThresh, _healthFactor);
        console.log("_cBase:%d,_dBase:%d,_leftBase:%d", _cBase, _dBase, _leftBase);
        return (_ltv, _healthFactor);
    }

    function _getZapInCalldataFromSDK(address _pendlePT, uint256 _assetAmount) internal view returns (bytes memory) {
        bytes memory _callData;
        if (_pendlePT == address(PT_ADDR1) && _assetAmount == magicUSDCAmount) {
            // slippage 2% with aggragator enabled
            _callData =
                hex"c81f847a000000000000000000000000f10b150ae0c2d2c0df82ae181dbcf2ea715734010000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac000000000000000000000000000000000000000000000042368f8b2e7a51e494000000000000000000000000000000000000000000000021c83ec99f8cc6844c00000000000000000000000000000000000000000000004a5223bb9235b4bca7000000000000000000000000000000000000000000000043907d933f198d0898000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000cc0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000499602d20000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000d4e9b0d466789d7f6201442eeccba6a75a552db000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a24e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000007400000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000003e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d44400000000000000000000000000000000000000000000000000000000499602d2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000053e2d6238da3000000320000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d44400000000000000000000000000000000000000000000000000000000498d58220000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000346dc5d638865000000c800000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000003b9cfbb2e541a0000000000000038da01f9e7aad46a30000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f94600000000000000000000000000000000000000000000000000000000499602d2000000000000000000000000000000000000000000000037b6ed74e82769c4390000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000499602d200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002887b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22313233332e393037373139373536313435222c22416d6f756e744f7574555344223a22313233352e31393138393435363636303537222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2231303438373236373739383736333738373030333336222c2254696d657374616d70223a313735303132363531362c22526f7574654944223a2231653464613462322d333337322d346637632d613337612d3834396339326534313838373a66346561393438312d363136662d343862652d396232362d303237316434626331663763222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a22434743534f56476465486759444f4d633157325075483845735337465a487544686651664c333243674563376852466e445867645a494246577736684c374245627068676b506f3944592f454b674e72306f4a586d314d31497874496969526833536a4d493955333834576b39494748747a43474f4b4d484575705671624c5347454a584c6241782b49794c3644484555484f766b73782b3372584f7372706b5433664a7157654f2b2f77504c38684e3554716a2b697473457474414f5275695a33323069674e4b6c5841553946784451746a4844442b7a377a39506f5636546851574977594e647364474567427650746c6a78562f4d38327a4c6f727568416d32426f5754714345396a5a4263637a4c6972586333664b4d43754c786b6a6f47314b374d42573469746c3439686a46695442794a47724468485679637334594c503461706678756150436c4b583572454271785a673d3d227d7d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        } else if (_pendlePT == address(PT_ADDR1) && _assetAmount == magicUSDCAmountLeveraged) {
            // slippage 2% with aggragator enabled
            _callData =
                hex"c81f847a000000000000000000000000f10b150ae0c2d2c0df82ae181dbcf2ea715734010000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac0000000000000000000000000000000000000000000001e2c451943f838d3d4600000000000000000000000000000000000000000000000276827c4e55bff83700000000000000000000000000000000000000000000021dcf9083a847ff3581000000000000000000000000000000000000000000000004ed04f89cab7ff06f000000000000000000000000000000000000000000000000000000000000001e000000000000000000000000000000000000000000000000000009184e72a00000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000cc0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000218711a000000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000d4e9b0d466789d7f6201442eeccba6a75a552db000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a24e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000007400000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000003e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000018000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d4440000000000000000000000000000000000000000000000000000000218711a00000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000053e2d6238da30000003200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000007eb59373d63627be64b42406b108b602174b4ccc000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a349700000000000000000000000000000000000000000000000000000002184d129e000000000000000000000000fffd8963efd1fc6a506488495d951d5263988d25000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000001b2a4c052a5563000000000000019e822679d1357241ae000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f9460000000000000000000000000000000000000000000000000000000218711a0000000000000000000000000000000000000000000000019637de06bdaa232be20000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000218711a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002877b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22393033392e323730373133383838353738222c22416d6f756e744f7574555344223a22393031322e333237353038313139353139222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2237363436333330333633373239323531383131373538222c2254696d657374616d70223a313735303230373438372c22526f7574654944223a2238346535313366322d633835342d346262622d383435332d3866306337616231323134383a63383732373362342d366335642d343462622d383465382d303666303835663337373532222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a2241496930375846464f533761667931312f4c673669764b4636563044614d4163567363342b61464b32314e4777566954613842417a2f696b585a334161664c78323846762b3656674b73584c344463794d4755676977486331682b496b38537541636e6c537052644a76336f4d625a576b4249676364566b56334b3351553439736f585641757156486f4a2b6642337671524431664d4b333874627748324661655351475975526c464745585278595130516c43524968566a31536e4e5356597874705056793537477077643056654f346c643363494775445668436c6252747a6c5757363534727a7731516c49434d4379784f4d726555584a2b4a56656b31487973584a695055353873336e62775846347a4d6f645a6d5339426a6d395758767477566678446c6434584665613872315759584334686b705759644467776a7566724a624448703739534e334b36347141755345773d3d227d7d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c9b3e2c3ec88b1b4c0cd853f4321000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000038000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000003a7a9596e94a5fee621924caab7fe5e6ac5932e750201539aba84f278d5b2855ae768361ad2afc7250000000000000000000000000000000000000000000000000000000068549fa1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000b7e51d15161c49c823f3951d579ded61cd27272b0000000000000000000000006ed3c871ac6aae698a9d6e547a5f54873b091e180000000000000000000000006ed3c871ac6aae698a9d6e547a5f54873b091e1800000000000000000000000000000000000000000000047f047fa7e3a67cccd1000000000000000000000000000000000000000000000000010ba04f875f36d60000000000000000000000000000000000000000000000000c7d713b49da000000000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004153d2eddb95838d8d474e464e6cb0da8c42bb11dde3737b0d1dde8699af29cb152938aa7f791c42514badab2ba4fe920bc638816d67b46d521fef05c45b598c5f1b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        }
        return _callData;
    }

    function _getStormOutCalldataFromSDK(address _pendlePT, uint256 _ptAmount) internal view returns (bytes memory) {
        bytes memory _callData;
        if (_pendlePT == address(PT_ADDR1) && _ptAmount == magicPTAmountRedeemed) {
            // slippage 2% with aggragator enabled
            _callData =
                hex"594a88cc000000000000000000000000f10b150ae0c2d2c0df82ae181dbcf2ea715734010000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac00000000000000000000000000000000000000000000000ad78ebc5ac620000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000f60000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000b9214060000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000d4e9b0d466789d7f6201442eeccba6a75a552db000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000d64e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000008600000000000000000000000000000000000000000000000000000000000000aa000000000000000000000000000000000000000000000000000000000000007a0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff0000000000000000000000000000000000000000000000000000000000000740000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d4440000000000000000000000000000000000000000000000094db4a86bbf0f81920000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000346dc5d638865000000c800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec600000000000000000000000011b815efb8f581194ae79006d24e0d814b7697f6000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000000000000000000000000000000000000c091de9000000000000000000000000fff6fbe64b68d618d47c209fe40b0d8ee6e23c90000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000408bf36a3b0000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000002e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000004444c5dc75cb358380d2e3de08a90000000000000000000000000000000000000000000000000011d025773096a6e000000000000000000000000000000000022d473030f116ddee9f6b43ac78ba30000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000010000000000000000000000004440854b2d02c57a0dc5c58b7a884562d875c0c4000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000001000276a40000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000000000000000000000000015602cf56d819500000000000000000000000000000000000000000000000000000000ad127f897000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068520d8400000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000041993c05133db08eb41833923534e825bd4990f0ba141ac4d20cd37521338c567545c4c250da09eeee2370a9b5121209893f02a8a2359071bfadeafd48cedb48e01b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000ca0000000000000000000000000c0af2d40000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f9460000000000000000000000000000000000000000000000094db4a86bbf0f8192000000000000000000000000000000000000000000000000000000000bcd51dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000094db4a86bbf0f8192000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000027b7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a223230332e31373939303131353537313937222c22416d6f756e744f7574555344223a223230322e3132313632363831303634303735222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a22323032303436313336222c2254696d657374616d70223a313735303230373639362c22526f7574654944223a2263626535396663382d363030612d346535662d616232362d6565393936306631303163663a65323635333539362d373732372d343465612d383563382d336661376634623137316537222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a224c3675536f57417277485a416670306837365a496450647249617a354e7569413448685073634f3552486633546b68562f576d32427a74315561686d3279597059713771333530576961323672517571427a4f77576930354a30696b7a6d73616878626f32567a4752747248634d457878485062516274744a2b355678726232766a4b732b5770333232377250365444395a456254636a4b48713361755656706e6c676c38476d59326b5070577a393135675234344c63716e7a2b7455424e302f6d68377048584f4930494f3150617a39623179742f684b6670563238415969345432686c656d4e3573643849413261624553476f62425761517449644b48415332464132436a6b356d5a534856465966686c523969364e6f4442624d455367564458587a74356446573534414a656e797a712b6b5765537362707a3130714173646d68314f775279594e41736c33577577674949773d3d227d7d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        } else if (_pendlePT == address(PT_ADDR1) && _ptAmount == magicPTAmountCollected) {
            // slippage 2% with aggragator enabled
            _callData =
                hex"594a88cc000000000000000000000000f10b150ae0c2d2c0df82ae181dbcf2ea715734010000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac0000000000000000000000000000000000000000000000c328093e61ee40000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000d03166db0000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000d4e9b0d466789d7f6201442eeccba6a75a552db000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000a04e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000007400000000000000000000000000000000000000000000000000000000000000440000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000003e000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000007eb59373d63627be64b42406b108b602174b4ccc0000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000000a771e8d5e5d9126c4e00000000000000000000000000000000000000000000000000000001000276a4000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000404c134a970000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e0e0e08a6a4b9dc7bd67bcb7aade5cf48157d44400000000000000000000000000000000000000000000000000000000d897bb9c000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec70000000000000000000000000000000000000000000053e2d6238da30000003200000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000e33000000000000000000000000d8b0ce520000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f9460000000000000000000000000000000000000000000000a771e8d5e5d9126c4e00000000000000000000000000000000000000000000000000000000d45b598d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec600000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000a771e8d5e5d9126c4e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002797b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22333633392e3639333936373330353534222c22416d6f756e744f7574555344223a22333634302e3535383230383235393438222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2233363335343635383130222c2254696d657374616d70223a313735303132363339372c22526f7574654944223a2234383330356437632d336435362d346133392d616631392d3538623433376166383838623a39613131613765382d343634342d346336652d383836662d396430323433356432336639222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a2258367848446c535a4d6d695576716a58505a77504b696c7062787942553476546c7462365a726d6d65724476312b53494442386e4d4641694574654c6b4c776973746a68563763787643415257574e474f4468652b39714a7365714b6a67384c674a4e4f4f764c4356454a4971596a6c61555a726c73707662414f56553551305951637365785a757732674b572f3559577358324253715164675252554b326b77457931313131667772736866626445516239534e64747747426c6444303571576736764e557849725343464b5a545a59337552466d7867663374456170394d59316f6c4f4c6265745a376e432f716b2f77367564592b6e36703833494e773230465153385a4561726c7053337469745172513763532b61735a32515155456a573357595867786958636a36746f574858704175446551367475445650776c422b4b4267633775365455366f6a356d50596e4f4945413d3d227d7d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        } else if (_pendlePT == address(PT_ADDR1) && _ptAmount == magicPTAmountCollectAll) {
            // slippage 2% with aggragator enabled
            _callData =
                hex"594a88cc000000000000000000000000f10b150ae0c2d2c0df82ae181dbcf2ea715734010000000000000000000000004339ffe2b7592dc783ed13cce310531ab366deac00000000000000000000000000000000000000000000015af1d78b58c400000000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000001721a55ce0000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000d4e9b0d466789d7f6201442eeccba6a75a552db000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006131b5fae19ea4f9d964eac0408e4408b66337b5000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000c04e21fd0e900000000000000000000000000000000000000000000000000000000000000200000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000009400000000000000000000000000000000000000000000000000000000000000640000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000c00000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000000000000007fffffff00000000000000000000000000000000000000000000000000000000000005e000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000004063407a490000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000e00000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000007eb59373d63627be64b42406b108b602174b4ccc0000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7000000000000000000000000000000000000000000000129b68769c17b3cdf8d00000000000000000000000000000000000000000000000000000001000276a4000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000408bf36a3b0000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000002e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000004444c5dc75cb358380d2e3de08a9000000000000000000000000000000000000000000000000000000001811df80c000000000000000000000000000000000022d473030f116ddee9f6b43ac78ba3000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000004440854b2d02c57a0dc5c58b7a884562d875c0c400000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000ffffffffffffffffffffffff0000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec6000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000001ce23f674000000000000000000000000000000000000000000000001000fa9db267e9657000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000068520f9c00000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000004194bf8a646124c7f026464a3e0b696802843656ae7d12c15a8055d292312f4a25782f1c07185caa728a64ed7b8a64d79f2a207561f4796749e56925b2880c510c1c0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000193e000000000000000000000001813588540000000000000000000000009d39a5de30e57443bff2a8307a4256c8797a3497000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000001e00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000888888888889758f76e7103c6cbf23abbf58f946000000000000000000000000000000000000000000000129b68769c17b3cdf8d000000000000000000000000000000000000000000000000000000017981430a0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000010000000000000000000000006e4141d33021b52c91c28608403db4a0ffb50ec60000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000129b68769c17b3cdf8d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000027b7b22536f75726365223a2250656e646c65222c22416d6f756e74496e555344223a22363437382e393532343030323039373737222c22416d6f756e744f7574555344223a22363435382e393538323232383830303236222c22526566657272616c223a22222c22466c616773223a302c22416d6f756e744f7574223a2236343632373336343638222c2254696d657374616d70223a313735303230383233322c22526f7574654944223a2232616161636438662d643839622d346133652d393939312d3262333434343666663961383a31313264633963362d633734662d343139352d386537382d386538353761303335313636222c22496e74656772697479496e666f223a7b224b65794944223a2231222c225369676e6174757265223a2244426b6a5366644f66495945366f43636e666c686a6b36693752684d48335566707751655533426a67716576736c776d64334d333944646d495a346930614b76696b33727a4d342b5236634c744c696865693561375a595145446f6f31386868536f72347937593657634e67474e32367945536d2f37732b704a4230484464465930497956627537385170704e75752f6143333430416d796e6d434963755a314a76475658624d69486d5172526a5a5a636435535565544d4d46506a7a41587248454c54594a6f6371356976596f754d2f685265672f5a38383353582b4c4f2f69564a55304738734d4e5a583048526969743137654961396534492f4c2b54776939513451533951733569494b3038797756786e333679704c696c487438756f41485561764d505a50364c4d4b444c6b333777423833627a2f6e61685138624f7866424265446c4672687758794e36307177744e59513d3d227d7d0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        }
        return _callData;
    }

    function _createPendleStrategy(bool _useMockRouter) internal returns (address, address) {
        bytes memory _constructorArgs = abi.encode(usdc, address(stkVault));
        address _deployedStrategy = deployWithCreationCodeAndConstructorArgs(
            PENDLE_AAVE_STRATEGY_NAME, type(PendleAAVEStrategy).creationCode, _constructorArgs
        );

        assertEq(_deployedStrategy, PENDLE_AAVE_STRATEGY_ADDRESS);

        aaveHelper = new AAVEHelper(_deployedStrategy, ERC20(address(PT_ADDR1)), ERC20(usdc), ERC20(PT_ATOKEN_ADDR1), 8);
        aaveHelperOwner = aaveHelper.owner();

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(_deployedStrategy, 100);
        vm.stopPrank();

        strategyOwner = PendleAAVEStrategy(_deployedStrategy).owner();

        address _routerAddr = (_useMockRouter ? address(mockRouter) : pendleRouterV4);
        pendleHelper = new PendleHelper(_deployedStrategy, _routerAddr, address(swapper));

        vm.startPrank(strategyOwner);
        PendleAAVEStrategy(_deployedStrategy).setSwapper(address(swapper));
        PendleAAVEStrategy(_deployedStrategy).setAAVEHelper(address(aaveHelper));
        PendleAAVEStrategy(_deployedStrategy).setPendleHelper(address(pendleHelper));
        PendleAAVEStrategy(_deployedStrategy).setPendleMarket(address(MARKET_ADDR1));
        vm.stopPrank();

        return (_deployedStrategy, PendleAAVEStrategy(_deployedStrategy).strategist());
    }

    function _changeSettingToNewPT() internal {
        vm.expectRevert(Constants.WRONG_EMODE.selector);
        vm.startPrank(aaveHelperOwner);
        aaveHelper.setTokens(ERC20(address(PT_ADDR3)), ERC20(usdc), ERC20(PT_ATOKEN_ADDR3), 0);
        vm.stopPrank();

        vm.startPrank(aaveHelperOwner);
        aaveHelper.setTokens(ERC20(address(PT_ADDR3)), ERC20(usdc), ERC20(PT_ATOKEN_ADDR3), 10);
        vm.stopPrank();

        address _strategyOwner = PendleAAVEStrategy(myStrategy).owner();
        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        vm.startPrank(_strategyOwner);
        PendleAAVEStrategy(myStrategy).setPendleMarket(Constants.ZRO_ADDR);
        vm.stopPrank();

        vm.expectRevert(Constants.DIFFERENT_TOKEN_IN_AAVE_HELPER.selector);
        vm.startPrank(_strategyOwner);
        PendleAAVEStrategy(myStrategy).setPendleMarket(address(MARKET_ADDR2));
        vm.stopPrank();

        vm.startPrank(_strategyOwner);
        PendleAAVEStrategy(myStrategy).setPendleMarket(address(MARKET_ADDR3));
        vm.stopPrank();

        uint256 _ltv = aaveHelper.getMaxLTV();
        assertTrue(_ltv >= 9000 && _ltv <= 9060);
    }
}
