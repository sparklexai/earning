// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IManager} from "../../../interfaces/sparklex-farming/IManager.sol";
import {IUserVault} from "../../../interfaces/sparklex-farming/IUserVault.sol";
import {Constants} from "../../utils/Constants.sol";
import {IUniswapV3PoolImmutables} from "../../../interfaces/uniswap/IUniswapV3PoolImmutables.sol";
import {INonfungiblePositionManager} from "../../../interfaces/uniswap/INonfungiblePositionManager.sol";
import {BaseSparkleXStrategy} from "../../strategies/BaseSparkleXStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "./TickMath.sol";

contract LPFarmingHelper is Ownable {
    struct ZapInPositionParams {
        address _pool;
        address _userVault;
        address _farmingMgr;
        address _farmingStrategy;
        uint256 _amount0;
        uint256 _amount1;
        int24 _tickLower;
        int24 _tickUpper;
        uint256 _currentSqrtPX96;
    }

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    address public _strategy;
    address public _nftPositionMgr;

    /**
     * @dev smaller SLIPPAGE_TOLERANCE setting means more strict on the minimum expect output
     */
    uint256 public SLIPPAGE_TOLERANCE = 990000;
    uint256 public constant FULL_SLIPPAGE = 1000000;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event LPFarmingHelperCreated(address indexed _lpFarmingStrategy, address indexed _nonfungiblePositionMgr);

    constructor(address lpFarmingStrategy, address nonfungiblePositionMgr) Ownable(msg.sender) {
        if (lpFarmingStrategy == Constants.ZRO_ADDR || nonfungiblePositionMgr == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _strategy = lpFarmingStrategy;
        _nftPositionMgr = nonfungiblePositionMgr;
        emit LPFarmingHelperCreated(_strategy, _nftPositionMgr);
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        if (_slippage == 0 || _slippage >= Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        SLIPPAGE_TOLERANCE = _slippage;
    }

    function createSparkleXFarmingVault(address _farmingMgr) external returns (address) {
        if (_strategy != msg.sender) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        IManager(_farmingMgr).createUserVault(Constants.ZRO_ADDR);
        address _createdUserVault = IManager(_farmingMgr).userVaults(address(this));
        if (_createdUserVault == Constants.ZRO_ADDR) {
            revert Constants.FAILED_TO_CREATE_USER_VAULT();
        }
        return _createdUserVault;
    }

    /*
     * @dev create LP position using SparkleX farming UserVault
     */
    function openV3PositionWithAmounts(ZapInPositionParams calldata _zapInParams)
        external
        returns (uint256 _positionId)
    {
        if (_strategy != msg.sender) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        address _token0 = IUniswapV3PoolImmutables(_zapInParams._pool).token0();
        address _token1 = IUniswapV3PoolImmutables(_zapInParams._pool).token1();

        if (_zapInParams._amount0 > 0) {
            SafeERC20.safeTransferFrom(ERC20(_token0), msg.sender, address(this), _zapInParams._amount0);
            _approveTokenToSparkleXUserVault(_token0, _zapInParams._userVault);
        }
        if (_zapInParams._amount1 > 0) {
            SafeERC20.safeTransferFrom(ERC20(_token1), msg.sender, address(this), _zapInParams._amount1);
            _approveTokenToSparkleXUserVault(_token1, _zapInParams._userVault);
        }

        uint256 _positionCountBefore = INonfungiblePositionManager(_nftPositionMgr).balanceOf(_zapInParams._userVault);

        if (_zapInParams._amount0 == 0 || _zapInParams._amount1 == 0) {
            _zapInWithSingleToken(_zapInParams, _token0, _token1);
        } else {
            revert Constants.SINGLE_TOKEN_ZAPIN_ONLY();
        }

        uint256 _positionCount = INonfungiblePositionManager(_nftPositionMgr).balanceOf(_zapInParams._userVault);
        if (_positionCount != _positionCountBefore + 1) {
            revert Constants.WRONG_LP_POSITION_COUNT();
        }
        _returnResidueTokens(_token0, _token1);

        if (_zapInParams._amount0 > 0) {
            _revokeTokenApproval(_token0, _zapInParams._userVault);
        }
        if (_zapInParams._amount1 > 0) {
            _revokeTokenApproval(_token1, _zapInParams._userVault);
        }
        uint256 _nftTokenId = INonfungiblePositionManager(_nftPositionMgr).tokenOfOwnerByIndex(
            _zapInParams._userVault, _positionCount - 1
        );
        return _nftTokenId;
    }

    /*
     * @dev close LP position using SparkleX farming UserVault
     */
    function closeV3Position(ZapInPositionParams calldata _zapInParams, uint256 _nftPositionId, uint256 _positionIdx)
        external
    {
        if (_strategy != msg.sender) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        if (_positionIdx == 0) {
            revert Constants.WRONG_LP_POSITION_INDEX();
        }
        INonfungiblePositionManager.NFTPositionData memory _positionData =
            INonfungiblePositionManager(_nftPositionMgr).positions(_nftPositionId);
        if (_positionData.liquidity == 0) {
            revert Constants.LP_POSITION_ZERO_LIQUIDITY();
        }
        uint256 _positionCount = INonfungiblePositionManager(_nftPositionMgr).balanceOf(_zapInParams._userVault);
        _removeLiquidity(_zapInParams, _positionData.liquidity, _positionIdx);
        _returnResidueTokensForPool(_zapInParams._pool);
    }

    /*
     * @dev remove liquidity from LP position using SparkleX farming UserVault
     * @dev use closeV3Position() instead to close the entire position (remove all liquidity)
     */
    function removeLiquidityV3(
        ZapInPositionParams calldata _zapInParams,
        uint256 _liquidityRatio,
        uint256 _nftPositionId,
        uint256 _positionIdx
    ) external {
        if (_strategy != msg.sender) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        if (_positionIdx == 0) {
            revert Constants.WRONG_LP_POSITION_INDEX();
        }
        INonfungiblePositionManager.NFTPositionData memory _positionData =
            INonfungiblePositionManager(_nftPositionMgr).positions(_nftPositionId);
        _removeLiquidity(
            _zapInParams, uint128(_positionData.liquidity * _liquidityRatio / Constants.TOTAL_BPS), _positionIdx
        );
        INonfungiblePositionManager.NFTPositionData memory _positionDataNew =
            INonfungiblePositionManager(_nftPositionMgr).positions(_nftPositionId);
        if (_positionDataNew.liquidity == 0) {
            revert Constants.LP_POSITION_ZERO_LIQUIDITY();
        }
        _returnResidueTokensForPool(_zapInParams._pool);
    }

    /*
     * @dev remove liquidity from LP position using SparkleX farming UserVault
     */
    function addLiquidityV3(ZapInPositionParams calldata _zapInParams, uint256 _positionIdx) external {
        if (_strategy != msg.sender) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        if (_positionIdx == 0) {
            revert Constants.WRONG_LP_POSITION_INDEX();
        }
        address _token0 = IUniswapV3PoolImmutables(_zapInParams._pool).token0();
        address _token1 = IUniswapV3PoolImmutables(_zapInParams._pool).token1();

        if (_zapInParams._amount0 > 0) {
            SafeERC20.safeTransferFrom(ERC20(_token0), msg.sender, address(this), _zapInParams._amount0);
            _approveTokenToSparkleXUserVault(_token0, _zapInParams._userVault);
        }
        if (_zapInParams._amount1 > 0) {
            SafeERC20.safeTransferFrom(ERC20(_token1), msg.sender, address(this), _zapInParams._amount1);
            _approveTokenToSparkleXUserVault(_token1, _zapInParams._userVault);
        }

        _addLiquidity(_zapInParams, _positionIdx, _token0, _token1);

        _returnResidueTokens(_token0, _token1);

        if (_zapInParams._amount0 > 0) {
            _revokeTokenApproval(_token0, _zapInParams._userVault);
        }
        if (_zapInParams._amount1 > 0) {
            _revokeTokenApproval(_token1, _zapInParams._userVault);
        }
    }

    /*
     * @dev collect accumulated fee from LP position using SparkleX farming UserVault
     */
    function collectFeeV3(ZapInPositionParams calldata _zapInParams, uint256 _positionIdx)
        external
        returns (uint256, uint256)
    {
        if (_strategy != msg.sender) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        address _token0 = IUniswapV3PoolImmutables(_zapInParams._pool).token0();
        address _token1 = IUniswapV3PoolImmutables(_zapInParams._pool).token1();
        uint256 _token0BalBefore = ERC20(_token0).balanceOf(address(this));
        uint256 _token1BalBefore = ERC20(_token1).balanceOf(address(this));
        IManager(_zapInParams._farmingMgr).work(
            _zapInParams._userVault, _positionIdx, _zapInParams._farmingStrategy, abi.encode(true)
        );
        uint256 _token0BalAfter = ERC20(_token0).balanceOf(address(this));
        uint256 _token1BalAfter = ERC20(_token1).balanceOf(address(this));
        _returnResidueTokens(_token0, _token1);
        return (_token0BalAfter - _token0BalBefore, _token1BalAfter - _token1BalBefore);
    }

    /*
     * @dev transform price from pool TWAP oracle to SqrtX96-compatible number 
     */
    function getTwapPriceInSqrtX96(address _pool, uint32 _twapInterval) public view returns (uint160) {
        if (_twapInterval == 0) {
            revert Constants.WRONG_TWAP_OBSERVE_INTERVAL();
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = _twapInterval; // from (before)
        secondsAgos[1] = 0; // to (now)

        (int56[] memory tickCumulatives,) = IUniswapV3PoolImmutables(_pool).observe(secondsAgos);
        return
            TickMath.getSqrtRatioAtTick(int24((tickCumulatives[1] - tickCumulatives[0]) / int56(int32(_twapInterval))));
    }

    function _zapInWithSingleToken(ZapInPositionParams calldata _zapInParams, address _token0, address _token1)
        internal
    {
        IUserVault.StrategyAddBaseTokenOnlyWithCalculateParam memory _params = IUserVault
            .StrategyAddBaseTokenOnlyWithCalculateParam({
            baseToken: (_token0 == BaseSparkleXStrategy(_strategy).asset() ? _token0 : _token1),
            farmingToken: (_token0 == BaseSparkleXStrategy(_strategy).asset() ? _token1 : _token0),
            totalAmount: (_zapInParams._amount0 > 0 ? _zapInParams._amount0 : _zapInParams._amount1),
            sqrtPriceX96: _zapInParams._currentSqrtPX96,
            slippage: SLIPPAGE_TOLERANCE,
            priceSlippage: SLIPPAGE_TOLERANCE,
            fee: IUniswapV3PoolImmutables(_zapInParams._pool).fee(),
            tickLower: _zapInParams._tickLower,
            tickUpper: _zapInParams._tickUpper,
            swapPath: abi.encodePacked(
                (_token0 == BaseSparkleXStrategy(_strategy).asset() ? _token0 : _token1),
                IUniswapV3PoolImmutables(_zapInParams._pool).fee(),
                (_token0 == BaseSparkleXStrategy(_strategy).asset() ? _token1 : _token0)
            )
        });
        IManager(_zapInParams._farmingMgr).work(
            _zapInParams._userVault, 0, _zapInParams._farmingStrategy, abi.encode(true, _params)
        );
    }

    function _removeLiquidity(ZapInPositionParams calldata _zapInParams, uint128 _liquidity, uint256 _positionIdx)
        internal
    {
        IUserVault.StrategyRemoveLiquidityParams memory _params = IUserVault.StrategyRemoveLiquidityParams({
            liquidity: _liquidity,
            amount0Min: _applySlippageRelax(_zapInParams._amount0, SLIPPAGE_TOLERANCE),
            amount1Min: _applySlippageRelax(_zapInParams._amount1, SLIPPAGE_TOLERANCE),
            recipient: 0
        });
        IManager(_zapInParams._farmingMgr).work(
            _zapInParams._userVault, _positionIdx, _zapInParams._farmingStrategy, abi.encode(_params)
        );
    }

    function _addLiquidity(
        ZapInPositionParams calldata _zapInParams,
        uint256 _positionIdx,
        address _token0,
        address _token1
    ) internal {
        IUserVault.StrategyAddLiquidityParams memory _params = IUserVault.StrategyAddLiquidityParams({
            amount0Desired: _zapInParams._amount0,
            amount1Desired: _zapInParams._amount1,
            sqrtPriceX96: _zapInParams._currentSqrtPX96,
            slippage: SLIPPAGE_TOLERANCE,
            priceSlippage: SLIPPAGE_TOLERANCE,
            userFund: true,
            token0SwapPath: abi.encodePacked(_token0, IUniswapV3PoolImmutables(_zapInParams._pool).fee(), _token1),
            token1SwapPath: abi.encodePacked(_token1, IUniswapV3PoolImmutables(_zapInParams._pool).fee(), _token0)
        });
        IManager(_zapInParams._farmingMgr).work(
            _zapInParams._userVault, _positionIdx, _zapInParams._farmingStrategy, abi.encode(_params)
        );
    }

    function _returnResidueTokensForPool(address _pool) internal {
        _returnResidueTokens(IUniswapV3PoolImmutables(_pool).token0(), IUniswapV3PoolImmutables(_pool).token1());
    }

    function _returnResidueTokens(address _token0, address _token1) internal {
        uint256 _residue0 = ERC20(_token0).balanceOf(address(this));
        uint256 _residue1 = ERC20(_token1).balanceOf(address(this));
        if (_residue0 > 0) {
            SafeERC20.safeTransfer(ERC20(_token0), msg.sender, _residue0);
        }
        if (_residue1 > 0) {
            SafeERC20.safeTransfer(ERC20(_token1), msg.sender, _residue1);
        }
    }

    function _applySlippageRelax(uint256 _theory, uint256 _slippage) internal view returns (uint256) {
        return _theory * _slippage / FULL_SLIPPAGE;
    }

    function _approveTokenToSparkleXUserVault(address _token, address _userVault) internal {
        if (ERC20(_token).allowance(address(this), _userVault) == 0) {
            SafeERC20.forceApprove(ERC20(_token), _userVault, type(uint256).max);
        }
    }

    function _revokeTokenApproval(address _token, address _spender) internal {
        SafeERC20.forceApprove(ERC20(_token), _spender, 0);
    }
}
