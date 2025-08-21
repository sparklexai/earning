// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {BaseSparkleXStrategy} from "../BaseSparkleXStrategy.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {Constants} from "../../utils/Constants.sol";
import {LPFarmingHelper} from "./LPFarmingHelper.sol";
import {UniV3PositionMath} from "./UniV3PositionMath.sol";
import {IUniswapV3PoolImmutables} from "../../../interfaces/uniswap/IUniswapV3PoolImmutables.sol";
import {IManager} from "../../../interfaces/sparklex-farming/IManager.sol";
import {IUserVault} from "../../../interfaces/sparklex-farming/IUserVault.sol";

// Structs for multi-Position management
struct LPPositionInfo {
    address pool; // pool address
    uint256 tokenId; // position token ID
    uint256 userVaultIdx; // index of SparkleX UserVault position array
    uint32 twapObserveInterval;
    address assetOracle; // asset token oracle
    address otherOracle; // paired token (other) oracle
    uint32 assetOracleHeartbeat; // asset token oracle heartbeat
    uint32 otherOracleHeartbeat; // paired token (other) oracle heartbeat
    bool active;
}

// Structs for SparkleX farming integration
struct SparkleXFarmingSetting {
    address farmingMgr; // SparkleX IManager address
    address farmingStrategyBaseZapIn; // farming strategy for zap-in with single base token
    address farmingStrategyCollectFee; // farming strategy for accumulated fee collection
    address farmingStrategyLiqRemoval; // farming strategy for liquidity removal
    address farmingStrategyLiqAddition; // farming strategy for liquidity addition
    address farmingUserVault;
}

contract UniV3LPFarmingStrategy is BaseSparkleXStrategy {
    using Math for uint256;
    using SafeERC20 for ERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    ///////////////////////////////
    // Constants and State Variables
    ///////////////////////////////
    address public _farmingHelper;
    uint32 public constant DEFAULT_TWAP_INTERVAL = 1800;

    /*
     * @dev mapping from position pool to LPPositionInfo
     */
    mapping(address => LPPositionInfo) public _positionInfos;
    SparkleXFarmingSetting public _sparkleXFarmingSetting;
    EnumerableSet.AddressSet private allPositions;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    address public constant uniV3PositionMgr = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;

    ///////////////////////////////
    // Events
    ///////////////////////////////
    event LPFarmingHelperChanged(address indexed _old, address indexed _new);
    event TwapObserveIntervalChanged(address indexed _pool, uint32 _old, uint32 _new);
    event PairOracleSet(
        address indexed _newAssetOracle, address indexed _otherOracle, uint32 _heartbeat, uint32 _otherHeartbeat
    );
    event SparkleXFarmingAddressesSet(
        address indexed _farmingMgr,
        address _baseZapInStrategy,
        address _feeCollectStrategy,
        address _liqRemoveStrategy,
        address _liqAddStrategy,
        address farmingUserVault
    );
    event LPPositionCreated(
        address indexed _targetPool,
        int24 _lowerT,
        int24 _upperT,
        uint256 _assetAmount,
        uint256 _tokenId,
        uint256 _posIdx
    );
    event LPPositionClosed(address indexed _targetPool, uint256 _tokenId, uint256 _posIdx);
    event LPPositionLiquidityAdded(
        address indexed _targetPool, uint256 _assetAmount, uint256 _tokenId, uint256 _posIdx
    );
    event LPPositionLiquidityRemoved(
        address indexed _targetPool, uint256 _liquidityRatio, uint256 _tokenId, uint256 _posIdx
    );

    constructor(ERC20 token, address vault) BaseSparkleXStrategy(token, vault) {}

    function setFarmingHelper(address _newHelper) external onlyOwner {
        if (_newHelper == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _revokeTokenApproval(address(_asset), _farmingHelper);
        emit LPFarmingHelperChanged(_farmingHelper, _newHelper);
        _farmingHelper = _newHelper;
        _approveToken(address(_asset), _newHelper);
    }

    function setTwapObserveInterval(address _pool, uint32 _newInterval) external onlyOwner {
        uint32 _oldInterval = _positionInfos[_pool].twapObserveInterval;
        if (_newInterval == 0) {
            _newInterval = DEFAULT_TWAP_INTERVAL;
        }
        _positionInfos[_pool].pool = _pool;
        emit TwapObserveIntervalChanged(_pool, _oldInterval, _newInterval);
        _positionInfos[_pool].twapObserveInterval = _newInterval;
    }

    function setPairOracles(
        address _pool,
        address _assetOracle,
        address _otherOracle,
        uint32 _assetOracleHeartbeat,
        uint32 _otherOracleHeartbeat
    ) external onlyOwner {
        _positionInfos[_pool].pool = _pool;

        if (_assetOracle == Constants.ZRO_ADDR && _otherOracle == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        if (_assetOracleHeartbeat == 0) {
            _assetOracleHeartbeat = DEFAULT_TWAP_INTERVAL;
        }
        if (_otherOracleHeartbeat == 0) {
            _otherOracleHeartbeat = DEFAULT_TWAP_INTERVAL;
        }

        _positionInfos[_pool].assetOracle = _assetOracle;
        _positionInfos[_pool].otherOracle = _otherOracle;
        _positionInfos[_pool].assetOracleHeartbeat = _assetOracleHeartbeat;
        _positionInfos[_pool].otherOracleHeartbeat = _otherOracleHeartbeat;

        emit PairOracleSet(_assetOracle, _otherOracle, _assetOracleHeartbeat, _otherOracleHeartbeat);
    }

    function setSparkleXFarmingAddresses(
        address _farmingMgr,
        address _baseZapInStrategy,
        address _feeCollectStrategy,
        address _liqRemoveStrategy,
        address _liqAddStrategy
    ) external onlyOwner {
        if (
            _farmingMgr == Constants.ZRO_ADDR || _baseZapInStrategy == Constants.ZRO_ADDR
                || _feeCollectStrategy == Constants.ZRO_ADDR || _liqRemoveStrategy == Constants.ZRO_ADDR
                || _liqAddStrategy == Constants.ZRO_ADDR
        ) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        address _farmingUserVault = _instantiateFarmingVault(_farmingMgr);
        _sparkleXFarmingSetting = SparkleXFarmingSetting({
            farmingMgr: _farmingMgr,
            farmingStrategyBaseZapIn: _baseZapInStrategy,
            farmingStrategyCollectFee: _feeCollectStrategy,
            farmingStrategyLiqRemoval: _liqRemoveStrategy,
            farmingStrategyLiqAddition: _liqAddStrategy,
            farmingUserVault: _farmingUserVault
        });
        emit SparkleXFarmingAddressesSet(
            _farmingMgr, _baseZapInStrategy, _feeCollectStrategy, _liqRemoveStrategy, _liqAddStrategy, _farmingUserVault
        );
    }

    /**
     * @dev deposit asset (single token zap-in) into SparkleX farming UserVault
     */
    function allocate(uint256 amount, bytes calldata _extraAction) external virtual onlyStrategist onlyVaultNotPaused {
        amount = _capAllocationAmount(amount);
        if (amount == 0) {
            return;
        }
        SafeERC20.safeTransferFrom(_asset, _vault, address(this), amount);
        emit AllocateInvestment(msg.sender, amount);
    }

    /**
     * @dev withdraw some liquidity to return asset back to vault
     */
    function collect(uint256 amount, bytes calldata _extraAction) public virtual onlyStrategistOrVault {
        if (amount == 0) {
            return;
        }
        amount = _returnAssetToVault(amount);
        emit CollectInvestment(msg.sender, amount);
    }

    /**
     * @dev ensure PT in all pendle market has been swapped back to asset
     */
    function collectAll(bytes calldata _extraAction) public virtual onlyStrategistOrVault {
        if (getAllPositionValuesInAsset() > 0) {
            revert Constants.LP_FARMING_STILL_IN_USE();
        }
        uint256 _assetBalance = _returnAssetToVault(type(uint256).max);
        emit CollectInvestment(msg.sender, _assetBalance);
    }

    /*
     * @dev open position in given pool with asset
     */
    function zapInPosition(address _targetPool, uint256 _assetAmount, int24 _lowerT, int24 _upperT)
        external
        onlyStrategistOrOwner
        onlyVaultNotPaused
        returns (uint256)
    {
        LPPositionInfo memory _positionInfo = _positionInfos[_targetPool];
        if (_positionInfo.active) {
            revert Constants.LP_POSITION_EXIST();
        }

        SparkleXFarmingSetting memory _farmingSetting = _sparkleXFarmingSetting;

        uint160 _currentX96 =
            LPFarmingHelper(_farmingHelper).getTwapPriceInSqrtX96(_targetPool, _positionInfo.twapObserveInterval);
        (address _pairedToken, bool _assetIsToken0) = getPairedTokenAddress(_targetPool);
        _assetAmount = _capAmountByBalance(_asset, _assetAmount, false);

        LPFarmingHelper.ZapInPositionParams memory _params = LPFarmingHelper.ZapInPositionParams({
            _pool: _targetPool,
            _userVault: _farmingSetting.farmingUserVault,
            _farmingMgr: _farmingSetting.farmingMgr,
            _farmingStrategy: _farmingSetting.farmingStrategyBaseZapIn,
            _amount0: (_assetIsToken0 ? _assetAmount : 0),
            _amount1: (_assetIsToken0 ? 0 : _assetAmount),
            _tickLower: _lowerT,
            _tickUpper: _upperT,
            _currentSqrtPX96: uint256(_currentX96)
        });
        uint256 _positionId = LPFarmingHelper(_farmingHelper).openV3PositionWithAmounts(_params);
        _positionInfos[_targetPool].tokenId = _positionId;
        uint256 _positionIdx = IUserVault(_farmingSetting.farmingUserVault).nextPositionId() - 1;
        _positionInfos[_targetPool].userVaultIdx = _positionIdx;
        _positionInfos[_targetPool].active = true;
        allPositions.add(_targetPool);
        emit LPPositionCreated(_targetPool, _lowerT, _upperT, _assetAmount, _positionId, _positionIdx);
        return _positionId;
    }

    /*
     * @dev close position in given pool
     */
    function closePosition(address _targetPool) external onlyStrategistOrOwner {
        SparkleXFarmingSetting memory _farmingSetting = _sparkleXFarmingSetting;

        LPPositionInfo memory _positionInfo = _positionInfos[_targetPool];
        (address _pairedToken,) = getPairedTokenAddress(_targetPool);

        // collect all fees before close position
        (,, LPFarmingHelper.ZapInPositionParams memory _params) = _collectPositionFees(_farmingSetting, _positionInfo);
        (uint256 amount0Min, uint256 amount1Min) = this.getPositionAmount(_positionInfo);

        // close position completely
        _params._amount0 = TokenSwapper(_swapper).applySlippageRelax(amount0Min);
        _params._amount1 = TokenSwapper(_swapper).applySlippageRelax(amount1Min);
        _params._farmingStrategy = _farmingSetting.farmingStrategyLiqRemoval;
        LPFarmingHelper(_farmingHelper).closeV3Position(_params, _positionInfo.tokenId, _positionInfo.userVaultIdx);

        // swap paired token to asset
        _swapPairedTokenToAsset(_targetPool, _pairedToken, _positionInfo);
        _positionInfos[_targetPool].active = false;
        emit LPPositionClosed(_targetPool, _positionInfo.tokenId, _positionInfo.userVaultIdx);
    }

    /*
     * @dev add liqudity to position in given pool
     */
    function addLiquidityToPosition(address _targetPool, uint256 _assetAmount)
        external
        onlyStrategistOrOwner
        onlyVaultNotPaused
    {
        SparkleXFarmingSetting memory _farmingSetting = _sparkleXFarmingSetting;

        LPPositionInfo memory _positionInfo = _positionInfos[_targetPool];
        uint160 _currentX96 =
            LPFarmingHelper(_farmingHelper).getTwapPriceInSqrtX96(_targetPool, _positionInfo.twapObserveInterval);
        (address _pairedToken, bool _assetIsToken0) = getPairedTokenAddress(_targetPool);
        _assetAmount = _capAmountByBalance(_asset, _assetAmount, false);

        LPFarmingHelper.ZapInPositionParams memory _params = LPFarmingHelper.ZapInPositionParams({
            _pool: _targetPool,
            _userVault: _farmingSetting.farmingUserVault,
            _farmingMgr: _farmingSetting.farmingMgr,
            _farmingStrategy: _farmingSetting.farmingStrategyLiqAddition,
            _amount0: (_assetIsToken0 ? _assetAmount : 0),
            _amount1: (_assetIsToken0 ? 0 : _assetAmount),
            _tickLower: 0,
            _tickUpper: 0,
            _currentSqrtPX96: uint256(_currentX96)
        });
        LPFarmingHelper(_farmingHelper).addLiquidityV3(_params, _positionInfo.userVaultIdx);
        emit LPPositionLiquidityAdded(_targetPool, _assetAmount, _positionInfo.tokenId, _positionInfo.userVaultIdx);
    }

    /*
     * @dev remove liqudity from position in given pool
     */
    function removeLiquidityFromPosition(address _targetPool, uint256 _liquidityRatio) external onlyStrategistOrOwner {
        if (_liquidityRatio == 0 || _liquidityRatio >= Constants.TOTAL_BPS) {
            revert Constants.WRONG_LP_REMOVAL_RATIO();
        }
        SparkleXFarmingSetting memory _farmingSetting = _sparkleXFarmingSetting;

        LPPositionInfo memory _positionInfo = _positionInfos[_targetPool];
        (address _pairedToken, bool _assetIsToken0) = getPairedTokenAddress(_targetPool);

        // collect all fees before remove liquidity position
        (,, LPFarmingHelper.ZapInPositionParams memory _params) = _collectPositionFees(_farmingSetting, _positionInfo);

        // remove specified liquidity from position
        (uint256 amount0Min, uint256 amount1Min) = this.getPositionAmount(_positionInfo);
        _params._amount0 = TokenSwapper(_swapper).applySlippageRelax(amount0Min * _liquidityRatio / Constants.TOTAL_BPS);
        _params._amount1 = TokenSwapper(_swapper).applySlippageRelax(amount1Min * _liquidityRatio / Constants.TOTAL_BPS);
        _params._farmingStrategy = _farmingSetting.farmingStrategyLiqRemoval;
        LPFarmingHelper(_farmingHelper).removeLiquidityV3(
            _params, _liquidityRatio, _positionInfo.tokenId, _positionInfo.userVaultIdx
        );

        // swap paired token to asset
        _swapPairedTokenToAsset(_targetPool, _pairedToken, _positionInfo);
        emit LPPositionLiquidityRemoved(_targetPool, _liquidityRatio, _positionInfo.tokenId, _positionInfo.userVaultIdx);
    }

    /*
     * @dev off-chain query could use callStatic method to get up-to-date fee in the position
     * @dev strategist script should use this method to collect position fees periodically
     */
    function collectPositionFee(address _pool) public onlyStrategistOrOwner returns (uint256, uint256) {
        LPPositionInfo memory _positionInfo = _positionInfos[_pool];
        if (!_positionInfo.active) {
            return (0, 0);
        } else {
            SparkleXFarmingSetting memory _farmingSetting = _sparkleXFarmingSetting;
            (uint256 _feeToken0, uint256 _feeToken1,) = _collectPositionFees(_farmingSetting, _positionInfo);
            (address _pairedToken,) = getPairedTokenAddress(_pool);
            _swapPairedTokenToAsset(_pool, _pairedToken, _positionInfo);
            return (_feeToken0, _feeToken1);
        }
    }

    function totalAssets() public view virtual returns (uint256) {
        return _asset.balanceOf(address(this)) + getAllPositionValuesInAsset();
    }

    function assetsInCollection() external pure override returns (uint256 inCollectionAssets) {
        return 0;
    }

    /**
     * @return positions managed by this strategy's SparkleX farming UserVault
     */
    function getAllPositions() external view returns (address[] memory, bool[] memory) {
        address[] memory _allPositions = allPositions.values();
        uint256 length = allPositions.length();
        bool[] memory _positionsActive = new bool[](length);
        for (uint256 i = 0; i < length; i++) {
            _positionsActive[i] = _positionInfos[_allPositions[i]].active;
        }
        return (_allPositions, _positionsActive);
    }

    /* 
     * @dev calculate the position LP value of given pool in asset deomination
     */
    function getPositionValueInAsset(address _pool) public view returns (uint256) {
        LPPositionInfo memory _positionInfo = _positionInfos[_pool];
        if (!_positionInfo.active) {
            return 0;
        } else {
            (uint256 _token0Amount, uint256 _token1Amount) = this.getPositionAmount(_positionInfo);
            uint256 _assetTokenAmount = _token0Amount;
            uint256 _pairedTokenAmount = _token1Amount;
            (address _pairedToken, bool _assetIsToken0) = getPairedTokenAddress(_positionInfo.pool);
            if (!_assetIsToken0) {
                _assetTokenAmount = _token1Amount;
                _pairedTokenAmount = _token0Amount;
            }
            return _assetTokenAmount + this.getPairedTokenValueInAsset(_positionInfo, _pairedTokenAmount);
        }
    }

    /* 
     * @dev calculate the token amounts (including uncollected fee) of given pool position
     */
    function getPositionAmount(LPPositionInfo calldata _positionInfo) public view returns (uint256, uint256) {
        if (!_positionInfo.active) {
            return (0, 0);
        } else {
            uint160 _currentSqrtPX96 = LPFarmingHelper(_farmingHelper).getTwapPriceInSqrtX96(
                _positionInfo.pool, _positionInfo.twapObserveInterval
            );
            address _posMgr = getDexPositionManager();
            (uint256 _token0Fee, uint256 _token1Fee) =
                UniV3PositionMath.getLastComputedFees(_posMgr, _positionInfo.tokenId);
            (uint256 _token0InLp, uint256 _token1InLp) =
                UniV3PositionMath.getAmountsForPosition(_posMgr, _positionInfo.tokenId, _currentSqrtPX96);
            return (_token0Fee + _token0InLp, _token1Fee + _token1InLp);
        }
    }

    /**
     * @dev Sum all positions value currently managed by this strategy's SparkleX farming UserVault
     */
    function getAllPositionValuesInAsset() public view returns (uint256) {
        uint256 totalPositionValueInAsset;
        uint256 length = allPositions.length();
        for (uint256 i = 0; i < length; i++) {
            totalPositionValueInAsset += getPositionValueInAsset(allPositions.at(i));
        }
        return totalPositionValueInAsset;
    }

    function getDexPositionManager() public view returns (address) {
        if (block.chainid == 1) {
            return uniV3PositionMgr;
        }
    }

    /*
     * @dev check if asset token is token0 or token1 in given pool
     */
    function getPairedTokenAddress(address _pool) public view returns (address, bool) {
        address _token0 = IUniswapV3PoolImmutables(_pool).token0();
        address _token1 = IUniswapV3PoolImmutables(_pool).token1();

        return _token0 == address(_asset) ? (_token1, true) : (_token0, false);
    }

    function getPairedTokenValueInAsset(LPPositionInfo calldata _positionInfo, uint256 _pairedTokenAmount)
        public
        view
        returns (uint256)
    {
        return _valuePairedTokenInAsset(_positionInfo, _pairedTokenAmount);
    }

    function _valuePairedTokenInAsset(LPPositionInfo calldata _positionInfo, uint256 _pairedTokenAmount)
        internal
        view
        virtual
        returns (uint256)
    {
        (address _pairedToken, bool _assetIsToken0) = getPairedTokenAddress(_positionInfo.pool);
        if (_positionInfo.assetOracle == Constants.ZRO_ADDR) {
            // use otherOracle directly
            return TokenSwapper(_swapper).convertAmountWithPriceFeed(
                _positionInfo.otherOracle,
                _positionInfo.otherOracleHeartbeat,
                _pairedTokenAmount,
                ERC20(_pairedToken),
                _asset
            );
        } else {
            // use both assetOracle and otherOracle
            return TokenSwapper(_swapper).convertAmountWithFeeds(
                ERC20(_pairedToken),
                _pairedTokenAmount,
                _positionInfo.otherOracle,
                _asset,
                _positionInfo.assetOracle,
                _positionInfo.otherOracleHeartbeat,
                _positionInfo.assetOracleHeartbeat
            );
        }
    }

    function _instantiateFarmingVault(address _farmingMgr) internal returns (address) {
        return LPFarmingHelper(_farmingHelper).createSparkleXFarmingVault(_farmingMgr);
    }

    // swap paired token to asset
    function _swapPairedTokenToAsset(address _targetPool, address _pairedToken, LPPositionInfo memory _positionInfo)
        internal
    {
        uint256 _pairedTokenBal = ERC20(_pairedToken).balanceOf(address(this));
        if (_pairedTokenBal == 0) {
            return;
        }
        _approveToken(_pairedToken, _swapper);
        TokenSwapper(_swapper).swapExactInWithUniswap(
            _pairedToken,
            address(_asset),
            _targetPool,
            _pairedTokenBal,
            TokenSwapper(_swapper).applySlippageRelax(this.getPairedTokenValueInAsset(_positionInfo, _pairedTokenBal))
        );
    }

    function _collectPositionFees(SparkleXFarmingSetting memory _farmingSetting, LPPositionInfo memory _positionInfo)
        internal
        returns (uint256, uint256, LPFarmingHelper.ZapInPositionParams memory)
    {
        LPFarmingHelper.ZapInPositionParams memory _params = LPFarmingHelper.ZapInPositionParams({
            _pool: _positionInfo.pool,
            _userVault: _farmingSetting.farmingUserVault,
            _farmingMgr: _farmingSetting.farmingMgr,
            _farmingStrategy: _farmingSetting.farmingStrategyCollectFee,
            _amount0: 0,
            _amount1: 0,
            _tickLower: 0,
            _tickUpper: 0,
            _currentSqrtPX96: 0
        });
        (uint256 _feeToken0, uint256 _feeToken1) =
            LPFarmingHelper(_farmingHelper).collectFeeV3(_params, _positionInfo.userVaultIdx);
        return (_feeToken0, _feeToken1, _params);
    }
}
