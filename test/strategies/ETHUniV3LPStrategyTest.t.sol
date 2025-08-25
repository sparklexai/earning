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
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {IUniswapV3PoolImmutables} from "../../interfaces/uniswap/IUniswapV3PoolImmutables.sol";
import {IManager} from "../../interfaces/sparklex-farming/IManager.sol";
import {IUserVault} from "../../interfaces/sparklex-farming/IUserVault.sol";
import {UniV3PositionMath} from "../../src/strategies/uniswap/UniV3PositionMath.sol";
import {LPFarmingHelper} from "../../src/strategies/uniswap/LPFarmingHelper.sol";
import {ETHUniV3LPFarmingStrategy} from "../../src/strategies/uniswap/ethereum/ETHUniV3LPFarmingStrategy.sol";
import {LPPositionInfo} from "../../src/strategies/uniswap/UniV3LPFarmingStrategy.sol";

contract ETHUniV3LPStrategyTest is TestUtils {
    SparkleXVault public stkVault;
    address public stkVOwner;
    address public strategist;
    TokenSwapper public swapper;
    ETHUniV3LPFarmingStrategy public myStrategy;
    address public strategyOwner;
    LPFarmingHelper public farmingHelper;

    address public constant _univ3PosMgr = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant _univ3ETHwstETHPool = 0x109830a1AAaD605BbF02a9dFA7B0B92EC2FB7dAa; //token0 is wstETH
    address public constant stETH_ETH_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    uint32 public constant stETH_ETH_FEED_HEARTBEAT = 86400;
    address public constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant _univ3ETHweETHPool = 0x202A6012894Ae5c288eA824cbc8A9bfb26A49b93; //token1 is weETH
    address public constant weETH_ETH_FEED = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    uint32 public constant weETH_ETH_FEED_HEARTBEAT = 86400;
    address public constant weETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    int24 public constant _tickSpacing0 = 1000;
    int24 public constant _tickSpacing1 = 1100;
    int24 public constant _tickDiff = 66;
    int24 public constant _tickDiffTight = 16;

    address public constant _farmingMgr = 0x29528Ea9E96c25322e531DF940d81CD9Bfc40a28;
    address public constant _farmingBaseZapIn = 0x491cC5dc8b66db1458B10241350BFD1783Cb94af;
    address public constant _farmingFeeCollect = 0xEF2612De4f6AC1144841fbCA094628a4faFB30ab;
    address public constant _farmingLiqRemove = 0x85b52F9505f4aF63f541b4F9fB21779777E24b32;
    address public constant _farmingLiqAdd = 0x72C339914Ae39FB068C696230757a9022654d2Cf;

    function setUp() public {
        _createForkMainnet(uint256(vm.envInt("TESTNET_FORK_HEIGHT")));

        stkVault = new SparkleXVault(ERC20(wETH), "SparkleX ETH Vault", "spETH");
        stkVOwner = stkVault.owner();

        vm.startPrank(stkVOwner);
        stkVault.setEarnRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        swapper = new TokenSwapper();
        myStrategy = new ETHUniV3LPFarmingStrategy(address(stkVault));
        strategyOwner = myStrategy.owner();
        strategist = myStrategy.strategist();
        farmingHelper = new LPFarmingHelper(address(myStrategy), _univ3PosMgr);

        address _farmingHelperOwner = farmingHelper.owner();
        uint256 _fullSlippage = farmingHelper.FULL_SLIPPAGE();
        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(_farmingHelperOwner);
        farmingHelper.setSlippage(_fullSlippage);
        vm.stopPrank();
        vm.startPrank(_farmingHelperOwner);
        farmingHelper.setSlippage(farmingHelper.SLIPPAGE_TOLERANCE() - 1);
        vm.stopPrank();

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), MAX_ETH_ALLOWED);
        vm.stopPrank();

        vm.startPrank(strategyOwner);
        myStrategy.setSwapper(address(swapper));
        myStrategy.setFarmingHelper(address(farmingHelper));
        myStrategy.setTwapObserveInterval(_univ3ETHwstETHPool, 1200);
        myStrategy.setPairOracles(_univ3ETHwstETHPool, Constants.ZRO_ADDR, stETH_ETH_FEED, 0, stETH_ETH_FEED_HEARTBEAT);
        myStrategy.setSparkleXFarmingAddresses(
            _farmingMgr, _farmingBaseZapIn, _farmingFeeCollect, _farmingLiqRemove, _farmingLiqAdd
        );
        vm.stopPrank();

        vm.startPrank(swapper.owner());
        swapper.setWhitelist(address(myStrategy), true);
        vm.stopPrank();

        address _userVault = IManager(_farmingMgr).userVaults(address(farmingHelper));
        assertTrue(_userVault != Constants.ZRO_ADDR);
        (,,,,, address _farmingUserVault) = myStrategy._sparkleXFarmingSetting();
        assertEq(_userVault, _farmingUserVault);
        assertEq(myStrategy.getDexPositionManager(), _univ3PosMgr);
        (address _pairedToken, bool _token0Asset) = myStrategy.getPairedTokenAddress(_univ3ETHwstETHPool);
        assertEq(_pairedToken, wstETH);
        assertEq(_token0Asset, false);
    }

    function test_UniV3_PositionMath(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);
        bytes memory EMPTY_CALLDATA;

        (uint160 _currentPX96, int24 _tickL, int24 _tickH) = _getCurrentTicks(_univ3ETHwstETHPool);
        vm.startPrank(strategist);
        myStrategy.allocate(_testVal, EMPTY_CALLDATA);
        LPFarmingHelper.ZapInPositionOutput memory _zapInOutput =
            myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal, _tickL, _tickH);
        vm.stopPrank();
        {
            (address[] memory _allPositions, bool[] memory _positionsActive) = myStrategy.getAllPositions();
            assertEq(_allPositions.length, 1);
            assertEq(_positionsActive.length, 1);
            assertEq(_allPositions[0], _univ3ETHwstETHPool);
            assertEq(_positionsActive[0], true);
            assertTrue(_assertApproximateEq(_testVal, myStrategy.totalAssets(), BIGGER_TOLERANCE));
            assertEq(
                myStrategy.totalAssets(),
                (ERC20(wETH).balanceOf(address(myStrategy)) + myStrategy.getAllPositionValuesInAsset())
            );
        }

        {
            (, uint256 tokenId, uint256 userVaultIdx,,,,,,) = myStrategy._positionInfos(_univ3ETHwstETHPool);
            _checkPosValueAfterZapIn(_univ3ETHwstETHPool, tokenId, _zapInOutput);
            _checkLPValuationWithSlot0Price(_univ3ETHwstETHPool, tokenId, _testVal);
        }

        vm.expectRevert(Constants.LP_POSITION_EXIST.selector);
        vm.startPrank(strategist);
        myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal, _tickL, _tickH);
        vm.stopPrank();

        vm.expectRevert(Constants.LP_FARMING_STILL_IN_USE.selector);
        vm.startPrank(strategist);
        myStrategy.collectAll(EMPTY_CALLDATA);
        vm.stopPrank();

        vm.startPrank(strategist);
        myStrategy.closePosition(_univ3ETHwstETHPool);
        vm.stopPrank();
        {
            (,,,,,,,, bool activeAfter) = myStrategy._positionInfos(_univ3ETHwstETHPool);
            assertFalse(activeAfter);
            assertTrue(_assertApproximateEq(_testVal, ERC20(wETH).balanceOf(address(myStrategy)), BIGGER_TOLERANCE));
            (address[] memory _allPositionsNew, bool[] memory _positionsActiveNew) = myStrategy.getAllPositions();
            assertEq(_allPositionsNew[0], _univ3ETHwstETHPool);
            assertEq(_positionsActiveNew[0], false);
        }

        vm.expectRevert(Constants.LP_POSITION_CLOSED.selector);
        vm.startPrank(strategist);
        myStrategy.closePosition(_univ3ETHwstETHPool);
        vm.stopPrank();

        vm.expectRevert(Constants.LP_POSITION_CLOSED.selector);
        vm.startPrank(strategist);
        myStrategy.addLiquidityToPosition(_univ3ETHwstETHPool, _testVal / 2);
        vm.stopPrank();

        vm.expectRevert(Constants.LP_POSITION_CLOSED.selector);
        vm.startPrank(strategist);
        myStrategy.removeLiquidityFromPosition(_univ3ETHwstETHPool, 1);
        vm.stopPrank();
    }

    function test_UniV3_Add_Remove_Liquidity(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);
        bytes memory EMPTY_CALLDATA;

        (uint160 _currentPX96, int24 _tickL, int24 _tickH) = _getCurrentTicks(_univ3ETHwstETHPool);
        vm.startPrank(strategist);
        myStrategy.allocate(_testVal, EMPTY_CALLDATA);
        LPFarmingHelper.ZapInPositionOutput memory _zapInOutput1 =
            myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal / 2, _tickL, _tickH);
        LPFarmingHelper.ZapInPositionOutput memory _zapInOutput2 =
            myStrategy.addLiquidityToPosition(_univ3ETHwstETHPool, _testVal / 2);
        vm.stopPrank();

        (, uint256 tokenId, uint256 userVaultIdx,,,,,,) = myStrategy._positionInfos(_univ3ETHwstETHPool);

        {
            LPFarmingHelper.ZapInPositionOutput memory _zapInOutputTotal = LPFarmingHelper.ZapInPositionOutput({
                posTokenId: tokenId,
                inAmount: _zapInOutput1.inAmount + _zapInOutput2.inAmount,
                residue0: _zapInOutput1.residue0 + _zapInOutput2.residue0,
                residue1: _zapInOutput1.residue1 + _zapInOutput2.residue1
            });
            _checkPosValueAfterZapIn(_univ3ETHwstETHPool, tokenId, _zapInOutputTotal);
        }

        {
            _checkLPValuationWithSlot0Price(_univ3ETHwstETHPool, tokenId, _testVal);
        }

        vm.expectRevert(Constants.WRONG_LP_REMOVAL_RATIO.selector);
        vm.startPrank(strategist);
        myStrategy.removeLiquidityFromPosition(_univ3ETHwstETHPool, Constants.TOTAL_BPS);
        vm.stopPrank();

        vm.startPrank(strategist);
        myStrategy.removeLiquidityFromPosition(_univ3ETHwstETHPool, (Constants.TOTAL_BPS / 2));
        vm.stopPrank();
        {
            _checkLPValuationWithSlot0Price(_univ3ETHwstETHPool, tokenId, _testVal / 2);
        }

        uint256 _vaultAssetBefore = ERC20(wETH).balanceOf(address(stkVault));
        uint256 _assetResidue = ERC20(wETH).balanceOf(address(myStrategy));
        vm.startPrank(strategist);
        myStrategy.collect(_assetResidue, EMPTY_CALLDATA);
        vm.stopPrank();
        assertTrue(
            _assertApproximateEq(
                _assetResidue, ERC20(wETH).balanceOf(address(stkVault)) - _vaultAssetBefore, BIGGER_TOLERANCE
            )
        );
        assertEq(myStrategy.assetsInCollection(), 0);
    }

    function test_UniV3_Fee_Collect(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 100 ether, 500 ether);
        bytes memory EMPTY_CALLDATA;

        (uint160 _currentPX96, int24 _tickL, int24 _tickH) = _getCurrentTicks(_univ3ETHwstETHPool);
        vm.startPrank(strategist);
        myStrategy.allocate(_testVal, EMPTY_CALLDATA);
        myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal, _tickL, _tickH);
        vm.stopPrank();
        LPPositionInfo memory _posInfo = _getPosInfoFromStrategy(_univ3ETHwstETHPool);

        _washTradingToGenerateFees(_posInfo.tokenId);

        vm.startPrank(strategist);
        myStrategy.closePosition(_univ3ETHwstETHPool);
        (uint256 _zeroFee0, uint256 _zeroFee1) = myStrategy.collectPositionFee(_univ3ETHwstETHPool);
        vm.stopPrank();

        assertEq(_zeroFee0, 0);
        assertEq(_zeroFee1, 0);
        (_zeroFee0, _zeroFee1) = myStrategy.getPositionAmount(_posInfo);
        assertEq(_zeroFee0, 0);
        assertEq(_zeroFee1, 0);
        (_zeroFee0, _zeroFee1) = myStrategy.getPositionAmountWithCurrentX96(_currentPX96, _posInfo);
        assertEq(_zeroFee0, 0);
        assertEq(_zeroFee1, 0);
    }

    function test_UniV3_Position_AmountMath(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);
        bytes memory EMPTY_CALLDATA;

        {
            (, int24 _tickL,) = _getCurrentTicks(_univ3ETHwstETHPool);
            vm.startPrank(strategist);
            myStrategy.allocate(_testVal, EMPTY_CALLDATA);
            myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal, _tickL - _tickSpacing1, _tickL - _tickSpacing0);
            vm.stopPrank();
        }
        (, uint256 tokenId, uint256 userVaultIdx,,,,,,) = myStrategy._positionInfos(_univ3ETHwstETHPool);
        assertEq(userVaultIdx, 1);
        (uint160 _currentPX96,,) = _getCurrentTicks(_univ3ETHwstETHPool);

        {
            (uint256 _token0Amount, uint256 _token1Amount) =
                UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentPX96);
            assertEq(_token0Amount, 0);
            assertTrue(_assertApproximateEq(_token1Amount, _testVal, COMP_TOLERANCE));
        }

        vm.startPrank(strategist);
        myStrategy.closePosition(_univ3ETHwstETHPool);
        vm.stopPrank();
        (,,,,,,,, bool _active0) = myStrategy._positionInfos(_univ3ETHwstETHPool);
        assertFalse(_active0);
        assertTrue(_assertApproximateEq(ERC20(wETH).balanceOf(address(myStrategy)), _testVal, BIGGER_TOLERANCE));

        (,, int24 _tickH) = _getCurrentTicks(_univ3ETHwstETHPool);
        vm.startPrank(strategist);
        myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal, _tickH + _tickSpacing0, _tickH + _tickSpacing1);
        vm.stopPrank();

        (, uint256 tokenIdNew, uint256 userVaultIdxNew,,,,,,) = myStrategy._positionInfos(_univ3ETHwstETHPool);
        assertEq(userVaultIdxNew, 2);
        (_currentPX96,,) = _getCurrentTicks(_univ3ETHwstETHPool);
        (,,,,,,,, _active0) = myStrategy._positionInfos(_univ3ETHwstETHPool);
        assertTrue(_active0);

        {
            (uint256 _token0AmountNew, uint256 _token1AmountNew) =
                UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenIdNew, _currentPX96);
            assertEq(_token1AmountNew, 0);
            LPPositionInfo memory _positionInfoNew =
                _getPositionInfoStruct(_univ3ETHwstETHPool, tokenIdNew, userVaultIdxNew, true);
            assertTrue(
                _assertApproximateEq(
                    myStrategy.getPairedTokenValueInAsset(_positionInfoNew, _token0AmountNew),
                    _testVal,
                    BIGGER_TOLERANCE
                )
            );
        }

        vm.startPrank(strategist);
        myStrategy.closePosition(_univ3ETHwstETHPool);
        vm.stopPrank();

        {
            uint256 _vaultAssetBefore = ERC20(wETH).balanceOf(address(stkVault));
            uint256 _assetResidue = myStrategy.totalAssets();
            vm.startPrank(strategist);
            myStrategy.collectAll(EMPTY_CALLDATA);
            vm.stopPrank();
            assertTrue(
                _assertApproximateEq(
                    _assetResidue, ERC20(wETH).balanceOf(address(stkVault)) - _vaultAssetBefore, BIGGER_TOLERANCE
                )
            );
        }
    }

    function test_UniV3_Multiple_Positions(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);
        bytes memory EMPTY_CALLDATA;

        uint256 _biggerPortion = _testVal * 90 / 100;
        (uint160 _currentPX96, int24 _tickL, int24 _tickH) = _getCurrentTicks(_univ3ETHwstETHPool);
        (uint160 _currentPX96Second, int24 _tickLSecond, int24 _tickHSecond) =
            _getCurrentTicksWithDiff(_univ3ETHweETHPool, _tickDiffTight);

        vm.startPrank(strategyOwner);
        myStrategy.setTwapObserveInterval(_univ3ETHweETHPool, 1800);
        myStrategy.setPairOracles(_univ3ETHweETHPool, Constants.ZRO_ADDR, weETH_ETH_FEED, 0, weETH_ETH_FEED_HEARTBEAT);
        vm.stopPrank();

        {
            (uint160 _currentSqrtPX96Slot0,,) = _getCurrentTicks(_univ3ETHweETHPool);
            (uint160 _currentSqrtPX96Twap,) = farmingHelper.getTwapPriceInSqrtX96(_univ3ETHweETHPool, 1800);
            console.log("_currentSqrtPX96Slot0:%d,_currentSqrtPX96Twap:%d", _currentSqrtPX96Slot0, _currentSqrtPX96Twap);
        }

        vm.startPrank(strategist);
        myStrategy.allocate(_testVal, EMPTY_CALLDATA);
        myStrategy.zapInPosition(_univ3ETHwstETHPool, _biggerPortion, _tickL, _tickH);
        LPFarmingHelper.ZapInPositionOutput memory _zapInOutputSecond =
            myStrategy.zapInPosition(_univ3ETHweETHPool, (_testVal - _biggerPortion), _tickLSecond, _tickHSecond);
        vm.stopPrank();
        {
            (address[] memory _allPositions, bool[] memory _positionsActive) = myStrategy.getAllPositions();
            assertEq(_allPositions.length, 2);
            assertEq(_positionsActive.length, 2);
            assertEq(_allPositions[0], _univ3ETHwstETHPool);
            assertEq(_allPositions[1], _univ3ETHweETHPool);
            assertEq(_positionsActive[0], true);
            assertEq(_positionsActive[1], true);
        }
        {
            (, uint256 tokenId,,,,,,,) = myStrategy._positionInfos(_univ3ETHweETHPool);
            _checkPosValueAfterZapIn(_univ3ETHweETHPool, tokenId, _zapInOutputSecond);
            (uint160 _currentSqrtPX96Slot0,,) = _getCurrentTicks(_univ3ETHweETHPool);
            (uint256 _t0, uint256 _t1) =
                UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentSqrtPX96Slot0);
            console.log("_t0:%d,_t1:%d", _t0, _t1);
        }
        {
            uint256 _totalAssets = myStrategy.totalAssets();
            uint256 _assetBalIn = ERC20(wETH).balanceOf(address(myStrategy));
            assertTrue(_assertApproximateEq(_testVal, _totalAssets, BIGGER_TOLERANCE));
            assertEq(_totalAssets, (_assetBalIn + myStrategy.getAllPositionValuesInAsset()));
            assertEq(
                _totalAssets,
                (
                    _assetBalIn + myStrategy.getPositionValueInAsset(_univ3ETHwstETHPool)
                        + myStrategy.getPositionValueInAsset(_univ3ETHweETHPool)
                )
            );
        }

        vm.startPrank(strategist);
        myStrategy.closePosition(_univ3ETHweETHPool);
        vm.stopPrank();
        {
            (address[] memory _allPositions, bool[] memory _positionsActive) = myStrategy.getAllPositions();
            assertEq(_allPositions.length, 2);
            assertEq(_positionsActive.length, 2);
            assertEq(_positionsActive[0], true);
            assertEq(_positionsActive[1], false);
        }
        {
            uint256 _totalAssets = myStrategy.totalAssets();
            assertTrue(_assertApproximateEq(_testVal, _totalAssets, BIGGER_TOLERANCE));
            assertEq(
                _totalAssets,
                (ERC20(wETH).balanceOf(address(myStrategy)) + myStrategy.getPositionValueInAsset(_univ3ETHwstETHPool))
            );
        }
    }

    function test_UniV3_EdgeCases(uint256 _testVal) public {
        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        vm.startPrank(strategyOwner);
        myStrategy.setSparkleXFarmingAddresses(
            Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR
        );
        vm.stopPrank();

        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        vm.startPrank(strategyOwner);
        myStrategy.setFarmingHelper(Constants.ZRO_ADDR);
        vm.stopPrank();

        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        vm.startPrank(strategyOwner);
        myStrategy.setPairOracles(_univ3ETHwstETHPool, Constants.ZRO_ADDR, Constants.ZRO_ADDR, 0, 0);
        vm.stopPrank();
        vm.startPrank(strategyOwner);
        myStrategy.setPairOracles(_univ3ETHwstETHPool, _univ3ETHwstETHPool, _univ3ETHwstETHPool, 0, 0);
        vm.stopPrank();
        {
            LPPositionInfo memory _posInfo = _getPosInfoFromStrategy(_univ3ETHwstETHPool);
            assertEq(_posInfo.otherOracleHeartbeat, myStrategy.DEFAULT_TWAP_INTERVAL());
        }

        vm.startPrank(strategyOwner);
        myStrategy.setTwapObserveInterval(_univ3ETHwstETHPool, 0);
        vm.stopPrank();
        {
            LPPositionInfo memory _posInfo = _getPosInfoFromStrategy(_univ3ETHwstETHPool);
            assertEq(_posInfo.twapObserveInterval, myStrategy.DEFAULT_TWAP_INTERVAL());
        }

        {
            LPPositionInfo memory _newPosInfo = LPPositionInfo({
                pool: 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36,
                tokenId: 0,
                userVaultIdx: 0,
                twapObserveInterval: myStrategy.DEFAULT_TWAP_INTERVAL(),
                assetOracle: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
                otherOracle: 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
                assetOracleHeartbeat: 86400,
                otherOracleHeartbeat: 86400,
                active: false
            });
            (int256 _assetP,, uint8 _assetPDecimal) = swapper.getPriceFromChainLink(_newPosInfo.assetOracle);
            uint256 _p = uint256(_assetP) / Constants.convertDecimalToUnit(uint256(_assetPDecimal));
            assertTrue(
                _assertApproximateEq(
                    myStrategy.getPairedTokenValueInAsset(_newPosInfo, MIN_SHARE * _p), 1e18, BIGGER_TOLERANCE
                )
            );
        }

        vm.expectRevert(Constants.INVALID_ADDRESS_TO_SET.selector);
        new LPFarmingHelper(Constants.ZRO_ADDR, Constants.ZRO_ADDR);

        vm.expectRevert(Constants.INVALID_HELPER_CALLER.selector);
        farmingHelper.createSparkleXFarmingVault(Constants.ZRO_ADDR);
        vm.expectRevert(Constants.WRONG_TWAP_OBSERVE_INTERVAL.selector);
        farmingHelper.getTwapPriceInSqrtX96(_univ3ETHwstETHPool, 0);
    }

    function _getCurrentTicks(address _pool) internal view returns (uint160, int24, int24) {
        return _getCurrentTicksWithDiff(_pool, _tickDiff);
    }

    function _getCurrentTicksWithDiff(address _pool, int24 _diff) internal view returns (uint160, int24, int24) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3PoolImmutables(_pool).slot0();
        return (sqrtPriceX96, tick - _diff, tick + _diff);
    }

    function _getPositionInfoStruct(address _pool, uint256 _tokenId, uint256 _userVaultIdx, bool _active)
        internal
        view
        returns (LPPositionInfo memory)
    {
        return _getPosInfoFromStrategy(_pool);
    }

    function _checkPairTokenValue(
        LPPositionInfo memory _positionInfo,
        uint256 _pairedTokenAmount,
        uint256 _assetAmount,
        uint256 _expected
    ) internal {
        uint256 _pairedValInAsset = myStrategy.getPairedTokenValueInAsset(_positionInfo, _pairedTokenAmount);
        console.log("_pairedValInAsset:%d, _assetAmount:%d, _expected:%d", _pairedValInAsset, _assetAmount, _expected);
        assertTrue(_assertApproximateEq(_expected, (_pairedValInAsset + _assetAmount), BIGGER_TOLERANCE));
    }

    function _washTradingToGenerateFees(uint256 _nftPositionId) internal {
        address _user = TestUtils._getSugarUser();

        vm.startPrank(swapper.owner());
        swapper.setWhitelist(_user, true);
        vm.stopPrank();

        vm.startPrank(_user);
        ERC20(wstETH).approve(address(swapper), type(uint256).max);
        ERC20(wETH).approve(address(swapper), type(uint256).max);
        vm.stopPrank();

        uint256 _pairTradeCount = 10;
        uint256 _tradeAmount = ERC20(wETH).balanceOf(_user) / _pairTradeCount;

        (uint256 _token0OwedBefore, uint256 _token1OwedBefore) =
            UniV3PositionMath.getLastComputedFees(_univ3PosMgr, _nftPositionId);

        vm.startPrank(_user);
        for (uint256 i = 0; i < _pairTradeCount; i++) {
            if (i % 2 == 0) {
                uint256 _exactIn = ERC20(wETH).balanceOf(_user);
                _exactIn = _exactIn > _tradeAmount ? _tradeAmount : _exactIn;
                if (_exactIn > 0) {
                    swapper.swapExactInWithUniswap(wETH, wstETH, _univ3ETHwstETHPool, _tradeAmount, 0);
                }
            } else {
                uint256 _exactIn = ERC20(wstETH).balanceOf(_user);
                if (_exactIn > 0) {
                    swapper.swapExactInWithUniswap(wstETH, wETH, _univ3ETHwstETHPool, ERC20(wstETH).balanceOf(_user), 0);
                }
            }
        }
        vm.stopPrank();

        vm.startPrank(strategist);
        (uint256 _feeToken0, uint256 _feeToken1) = myStrategy.collectPositionFee(_univ3ETHwstETHPool);
        vm.stopPrank();

        console.log("_token0OwedBefore:%d,_token1OwedBefore:%d", _token0OwedBefore, _token1OwedBefore);
        console.log("_feeToken0:%d,_feeToken1:%d", _feeToken0, _feeToken1);
        assertTrue(_feeToken0 > _token0OwedBefore && _feeToken1 > _token1OwedBefore);
    }

    function _checkPosValueAfterZapIn(
        address _targetPool,
        uint256 tokenId,
        LPFarmingHelper.ZapInPositionOutput memory _zapInOutput
    ) internal {
        (uint160 _currentPX96Slot0,,) = _getCurrentTicks(_targetPool);
        (uint160 _currentSqrtPX96Twap,) = farmingHelper.getTwapPriceInSqrtX96(_targetPool, 1800);
        bool _assetIsToken0 = (_targetPool == _univ3ETHwstETHPool) ? false : true;

        (uint256 _t0Twap, uint256 _t1Twap) =
            UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentSqrtPX96Twap);
        console.log("_t0Twap:%d,_t1Twap:%d", _t0Twap, _t1Twap);

        (uint256 _t0, uint256 _t1) = UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentPX96Slot0);
        console.log("_t0:%d,_t1:%d", _t0, _t1);

        LPPositionInfo memory _targetPosInfo = _getPosInfoFromStrategy(_targetPool);
        assertTrue(_targetPosInfo.active);
        assertTrue(_targetPosInfo.userVaultIdx > 0);
        assertEq(_targetPosInfo.tokenId, tokenId);
        uint256 _zapInAsset = _zapInOutput.inAmount;
        uint256 _zapInAssetTwap;
        if (_assetIsToken0) {
            _zapInAsset = _zapInAsset - _zapInOutput.residue0
                - myStrategy.getPairedTokenValueInAsset(_targetPosInfo, _zapInOutput.residue1);
            _zapInAssetTwap = _t0Twap + myStrategy.getPairedTokenValueInAsset(_targetPosInfo, _t1Twap);
        } else {
            _zapInAsset = _zapInAsset - _zapInOutput.residue1
                - myStrategy.getPairedTokenValueInAsset(_targetPosInfo, _zapInOutput.residue0);
            _zapInAssetTwap = _t1Twap + myStrategy.getPairedTokenValueInAsset(_targetPosInfo, _t0Twap);
        }
        console.log("_zapInAsset:%d,_zapInAssetTwap:%d", _zapInAsset, _zapInAssetTwap);
        assertTrue(_assertApproximateEq(_zapInAsset, _zapInAssetTwap, BIGGER_TOLERANCE));
    }

    function _getPosInfoFromStrategy(address _targetPool) internal view returns (LPPositionInfo memory) {
        (
            address _pool,
            uint256 _tokenId,
            uint256 _userVaultIdx,
            uint32 _twapObserveInterval,
            address _assetOracle,
            address _otherOracle,
            uint32 _assetOracleHeartbeat,
            uint32 _otherOracleHeartbeat,
            bool _active
        ) = myStrategy._positionInfos(_targetPool);
        return LPPositionInfo({
            pool: _pool,
            tokenId: _tokenId,
            userVaultIdx: _userVaultIdx,
            twapObserveInterval: _twapObserveInterval,
            assetOracle: _assetOracle,
            otherOracle: _otherOracle,
            assetOracleHeartbeat: _assetOracleHeartbeat,
            otherOracleHeartbeat: _otherOracleHeartbeat,
            active: _active
        });
    }

    function _checkLPValuationWithSlot0Price(address _targetPool, uint256 tokenId, uint256 _expected) internal {
        (uint160 _currentPX96,,) = _getCurrentTicks(_targetPool);
        {
            (uint256 _token0Amount, uint256 _token1Amount) =
                UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentPX96);
            assertTrue(_token0Amount > 0 && _token1Amount > 0);
            _checkPairTokenValue(_getPosInfoFromStrategy(_targetPool), _token0Amount, _token1Amount, _expected);
        }
    }
}
