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
}
