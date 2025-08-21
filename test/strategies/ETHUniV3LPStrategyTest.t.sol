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
import {TickMath} from "../../src/strategies/uniswap/TickMath.sol";
import {FullMath} from "../../src/strategies/uniswap/FullMath.sol";
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
    int24 public constant _tickSpacing0 = 1000;
    int24 public constant _tickSpacing1 = 1100;

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
        strategist = myStrategy.strategist();
        farmingHelper = new LPFarmingHelper(address(myStrategy), _univ3PosMgr);

        vm.startPrank(stkVOwner);
        stkVault.addStrategy(address(myStrategy), MAX_ETH_ALLOWED);
        vm.stopPrank();

        vm.startPrank(myStrategy.owner());
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
        myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal, _tickL, _tickH);
        vm.stopPrank();
        {
            (address[] memory _allPositions, bool[] memory _positionsActive) = myStrategy.getAllPositions();
            assertEq(_allPositions.length, 1);
            assertEq(_positionsActive.length, 1);
            assertEq(_allPositions[0], _univ3ETHwstETHPool);
            assertEq(_positionsActive[0], true);
            assertTrue(_assertApproximateEq(_testVal, myStrategy.totalAssets(), BIGGER_TOLERANCE));
        }

        (, uint256 tokenId, uint256 userVaultIdx,,,,,, bool active) = myStrategy._positionInfos(_univ3ETHwstETHPool);
        assertTrue(active);
        assertTrue(tokenId > 0 && userVaultIdx > 0);

        (uint256 _token0Amount, uint256 _token1Amount) =
            UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentPX96);
        assertTrue(_token0Amount > 0 && _token1Amount > 0);
        {
            LPPositionInfo memory _positionInfo =
                _getPositionInfoStruct(_univ3ETHwstETHPool, tokenId, userVaultIdx, true);
            _checkPairTokenValue(_positionInfo, _token0Amount, _token1Amount, _testVal);
        }

        vm.startPrank(strategist);
        myStrategy.closePosition(_univ3ETHwstETHPool);
        vm.stopPrank();

        (,,,,,,,, active) = myStrategy._positionInfos(_univ3ETHwstETHPool);
        assertFalse(active);
        assertTrue(_assertApproximateEq(_testVal, ERC20(wETH).balanceOf(address(myStrategy)), BIGGER_TOLERANCE));
        {
            (address[] memory _allPositionsNew, bool[] memory _positionsActiveNew) = myStrategy.getAllPositions();
            assertEq(_allPositionsNew[0], _univ3ETHwstETHPool);
            assertEq(_positionsActiveNew[0], false);
        }
    }

    function test_UniV3_Add_Remove_Liquidity(uint256 _testVal) public {
        _fundFirstDepositGenerously(address(stkVault));

        address _user = TestUtils._getSugarUser();

        (_testVal,) = TestUtils._makeVaultDeposit(address(stkVault), _user, _testVal, 5 ether, 10 ether);
        bytes memory EMPTY_CALLDATA;

        uint256 _half = _testVal / 2;
        (uint160 _currentPX96, int24 _tickL, int24 _tickH) = _getCurrentTicks(_univ3ETHwstETHPool);
        vm.startPrank(strategist);
        myStrategy.allocate(_testVal, EMPTY_CALLDATA);
        myStrategy.zapInPosition(_univ3ETHwstETHPool, _half, _tickL, _tickH);
        myStrategy.addLiquidityToPosition(_univ3ETHwstETHPool, _half);
        vm.stopPrank();

        (, uint256 tokenId, uint256 userVaultIdx,,,,,,) = myStrategy._positionInfos(_univ3ETHwstETHPool);

        (uint256 _token0Amount, uint256 _token1Amount) =
            UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentPX96);
        assertTrue(_token0Amount > 0 && _token1Amount > 0);
        {
            LPPositionInfo memory _positionInfo =
                _getPositionInfoStruct(_univ3ETHwstETHPool, tokenId, userVaultIdx, true);
            _checkPairTokenValue(_positionInfo, _token0Amount, _token1Amount, _testVal);
        }

        vm.startPrank(strategist);
        myStrategy.removeLiquidityFromPosition(_univ3ETHwstETHPool, (Constants.TOTAL_BPS * _half / _testVal));
        vm.stopPrank();
        (_token0Amount, _token1Amount) = UniV3PositionMath.getAmountsForPosition(_univ3PosMgr, tokenId, _currentPX96);
        {
            LPPositionInfo memory _positionInfoLeft =
                _getPositionInfoStruct(_univ3ETHwstETHPool, tokenId, userVaultIdx, true);
            _checkPairTokenValue(_positionInfoLeft, _token0Amount, _token1Amount, _half);
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

        (, int24 _tickL, int24 _tickH) = _getCurrentTicks(_univ3ETHwstETHPool);
        vm.startPrank(strategist);
        myStrategy.allocate(_testVal, EMPTY_CALLDATA);
        myStrategy.zapInPosition(_univ3ETHwstETHPool, _testVal, _tickL, _tickH);
        vm.stopPrank();
        (, uint256 tokenId,,,,,,,) = myStrategy._positionInfos(_univ3ETHwstETHPool);

        _washTradingToGenerateFees(tokenId);
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

    function _getCurrentTicks(address _pool) internal view returns (uint160, int24, int24) {
        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3PoolImmutables(_pool).slot0();
        return (sqrtPriceX96, tick - 66, tick + 66);
    }

    function _getPositionInfoStruct(address _pool, uint256 _tokenId, uint256 _userVaultIdx, bool _active)
        internal
        view
        returns (LPPositionInfo memory)
    {
        LPPositionInfo memory _positionInfo = LPPositionInfo({
            pool: _pool,
            tokenId: _tokenId,
            userVaultIdx: _userVaultIdx,
            twapObserveInterval: 900,
            assetOracle: (_pool == _univ3ETHwstETHPool ? Constants.ZRO_ADDR : Constants.ZRO_ADDR),
            otherOracle: (_pool == _univ3ETHwstETHPool ? stETH_ETH_FEED : stETH_ETH_FEED),
            assetOracleHeartbeat: (_pool == _univ3ETHwstETHPool ? 0 : 0),
            otherOracleHeartbeat: (_pool == _univ3ETHwstETHPool ? stETH_ETH_FEED_HEARTBEAT : stETH_ETH_FEED_HEARTBEAT),
            active: _active
        });
        return _positionInfo;
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
}
