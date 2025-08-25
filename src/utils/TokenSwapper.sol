// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICurveRouter} from "../../interfaces/curve/ICurveRouter.sol";
import {ICurvePool} from "../../interfaces/curve/ICurvePool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Constants} from "./Constants.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IOracleAggregatorV3} from "../../interfaces/chainlink/IOracleAggregatorV3.sol";
import {IPMarketV3} from "@pendle/contracts/interfaces/IPMarketV3.sol";
import {ISwapRouter} from "../../interfaces/uniswap/ISwapRouter.sol";
import {IUniswapV3PoolImmutables} from "../../interfaces/uniswap/IUniswapV3PoolImmutables.sol";
import {IFluidDex} from "../../interfaces/fluid/IFluidDex.sol";

interface PendleOracleInterface {
    function getPtToSyRate(address market, uint32 duration) external view returns (uint256);
}

interface IPendleStrategy {
    function _pendleHelper() external view returns (address);
}

interface IPendleHelper {
    function _strategy() external view returns (address);
}

interface IERC4626Vault {
    function convertToAssets(uint256 _share) external view returns (uint256);
    function decimals() external view returns (uint256);
}

contract TokenSwapper is Ownable {
    using Math for uint256;
    using Address for address;

    ///////////////////////////////
    // member storage
    ///////////////////////////////

    /**
     * @dev smaller SWAP_SLIPPAGE_BPS setting means more relax on the minimum expect output
     * @dev also possibly more input amount (via applySlippageMargin()) to complete the swap
     */
    uint256 public SWAP_SLIPPAGE_BPS = 9920;
    uint32 public constant PENDLE_ORACLE_TWAP = 900;
    uint32 public constant DEFAULT_Heartbeat = 86400;
    mapping(address => address) public _tokenOracles;
    mapping(address => bool) public whitelistCaller;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    ICurveRouter curveRouter = ICurveRouter(0x16C6521Dff6baB339122a0FE25a9116693265353);
    ISwapRouter uniswapV3Router = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    address pendleRouteV4 = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    PendleOracleInterface pendleOracle = PendleOracleInterface(0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2);
    bytes4 public constant TARGET_SELECTOR_BUY = hex"c81f847a"; //swapExactTokenForPt()
    bytes4 public constant TARGET_SELECTOR_SELL = hex"594a88cc"; //swapExactPtForToken()
    bytes4 public constant TARGET_SELECTOR_REDEEM = hex"47f1de22"; //redeemPyToToken()
    bytes4 public constant TARGET_SELECTOR_REFLECT = hex"9fa02c86"; //callAndReflect()

    ///////////////////////////////
    // stalecoins and related chainlink oracles - Ethereum mainnet
    ///////////////////////////////
    address public constant usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant usds = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant usde = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant USR = 0x66a1E37c9b0eAddca17d3662D6c05F4DECf3e110;
    address public constant USDf = 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2;
    address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
    address public constant USDT_USD_Feed = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address public constant USDC_USD_Feed = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant USDS_USD_Feed = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;
    address public constant USDe_USD_FEED = 0xa569d910839Ae8865Da8F8e70FfFb0cBA869F961;
    address public constant USR_USD_FEED = 0x34ad75691e25A8E9b681AAA85dbeB7ef6561B42c;
    address public constant USDf_USD_FEED = 0xb177857a1799aA5F7fEb5799Fdf12CbE8fdF78B1;
    address public constant GHO_USD_FEED = 0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC;

    ///////////////////////////////
    // stalecoins and related chainlink oracles - BNB Chain
    ///////////////////////////////
    address public constant USDC_BNB = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address public constant USDC_USD_Feed_BNB = 0x51597f405303C4377E36123cBc172b13269EA163;
    address public constant USDT_BNB = 0x55d398326f99059fF775485246999027B3197955;
    address public constant USDT_USD_Feed_BNB = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address public constant USD1_BNB = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address public constant USD1_USD_Feed_BNB = 0xaD8b4e59A7f25B68945fAf0f3a3EAF027832FFB0;
    address public constant FDUSD_BNB = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;
    address public constant FDUSD_USD_Feed_BNB = 0x390180e80058A8499930F0c13963AD3E0d86Bfc9;
    address public constant USDX = 0xf3527ef8dE265eAa3716FB312c12847bFBA66Cef;
    address public constant USDe_BNB = 0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34;
    address public constant USR_BNB = 0x2492D0006411Af6C8bbb1c8afc1B0197350a79e9;
    address public constant USDX_USD_Feed = 0x4BAD96DD1C7D541270a0C92e1D4e5f12EEEA7a57; //redstone
    address public constant USDe_USD_Feed_BNB = 0x10402B01cD2E6A9ed6DBe683CbC68f78Ff02f8FC;
    address public constant USR_USD_Feed_BNB = 0xE8ed18E29402CD223bC5B73D30e40CCdf7b72986;
    address public constant XAUM_BNB = 0x23AE4fd8E7844cdBc97775496eBd0E8248656028;
    address public constant XAUM_USD_Feed_BNB = 0x86896fEB19D8A607c3b11f2aF50A0f239Bd71CD0;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event SwapInCurve(address indexed inToken, address indexed outToken, address _receiver, uint256 _in, uint256 _out);
    event SwapInUniswap(
        address indexed inToken, address indexed outToken, address _receiver, uint256 _in, uint256 _out
    );
    event SwapInFluid(address indexed inToken, address indexed outToken, address _receiver, uint256 _in, uint256 _out);
    event CallerWhitelisted(address indexed _caller, bool _whitelisted);
    event TokenOracleChanged(address indexed _token, address _oldOracle, address _newOracle);

    constructor() Ownable(msg.sender) {
        if (block.chainid == 1) {
            _addOraclesForEthereum();
        } else if (block.chainid == 56) {
            _addOraclesForBNBChain();
            // https://developer.pancakeswap.finance/contracts/v3/addresses
            uniswapV3Router = ISwapRouter(0x1b81D678ffb9C0263b24A97847620C99d213eB14);
        }
    }

    function _approveTokenToDex(address _token, address _dex) internal {
        if (ERC20(_token).allowance(address(this), _dex) == 0) {
            SafeERC20.forceApprove(ERC20(_token), _dex, type(uint256).max);
        }
    }

    function _revokeTokenApproval(address _token, address _spender) internal {
        SafeERC20.forceApprove(ERC20(_token), _spender, 0);
    }

    function setTokenOracle(address _token, address _oracle) external onlyOwner {
        emit TokenOracleChanged(_token, _tokenOracles[_token], _oracle);
        _tokenOracles[_token] = _oracle;
    }

    function setSlippage(uint256 _slippage) external onlyOwner {
        if (_slippage == 0 || _slippage >= Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        SWAP_SLIPPAGE_BPS = _slippage;
    }

    function setWhitelist(address _caller, bool _whitelisted) external onlyOwner {
        if (_caller == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        whitelistCaller[_caller] = _whitelisted;
        emit CallerWhitelisted(_caller, _whitelisted);
    }

    /**
     * @dev allow only called by whitelisted caller.
     */
    modifier onlyWhitelistedCaller() {
        if (!whitelistCaller[msg.sender]) {
            revert Constants.ONLY_FOR_WHITELISTED_CALLER();
        }
        _;
    }

    ///////////////////////////////
    // Fluid swap related: currently support multi-hop swap
    // https://docs.fluid.instadapp.io/autogenerated-docs/protocols/dex/poolT1/coreModule/core/main.sol/contract.FluidDexT1.html#swapin-1
    ///////////////////////////////

    function singleSwapViaFluid(
        address inToken,
        address outToken,
        bool _swap0To1,
        address _pool,
        uint256 _inAmount,
        uint256 _minOut
    ) external onlyWhitelistedCaller returns (uint256) {
        // Swap inToken → outToken through one direct pool
        SafeERC20.safeTransferFrom(ERC20(inToken), msg.sender, address(this), _inAmount);
        _approveTokenToDex(inToken, _pool);
        uint256 _outActual = IFluidDex(_pool).swapIn(_swap0To1, _inAmount, applySlippageRelax(_minOut), msg.sender);
        emit SwapInFluid(inToken, outToken, msg.sender, _inAmount, _outActual);
        _revokeTokenApproval(inToken, _pool);
        return _outActual;
    }

    ///////////////////////////////
    // Uniswap V3 related:
    // https://docs.uniswap.org/contracts/v3/guides/swaps/single-swaps
    ///////////////////////////////

    function getOutTokenForUniPool(address _tokenIn, address _pool) public view returns (address) {
        address token0 = IUniswapV3PoolImmutables(_pool).token0();
        if (token0 == _tokenIn) {
            return IUniswapV3PoolImmutables(_pool).token1();
        } else {
            return token0;
        }
    }

    function swapExactInWithUniswap(
        address inToken,
        address outToken,
        address singlePool,
        uint256 _inAmount,
        uint256 _minOut
    ) external onlyWhitelistedCaller returns (uint256) {
        ISwapRouter.ExactInputSingleParams memory _inputSingle = ISwapRouter.ExactInputSingleParams({
            tokenIn: inToken,
            tokenOut: outToken,
            fee: IUniswapV3PoolImmutables(singlePool).fee(),
            recipient: msg.sender,
            deadline: (block.timestamp + PENDLE_ORACLE_TWAP),
            amountIn: _inAmount,
            amountOutMinimum: _minOut,
            sqrtPriceLimitX96: 0
        });
        SafeERC20.safeTransferFrom(ERC20(inToken), msg.sender, address(this), _inAmount);
        _approveTokenToDex(inToken, address(uniswapV3Router));
        uint256 _outActual = uniswapV3Router.exactInputSingle(_inputSingle);
        emit SwapInUniswap(inToken, outToken, msg.sender, _inAmount, _outActual);
        _revokeTokenApproval(inToken, address(uniswapV3Router));
        return _outActual;
    }

    ///////////////////////////////
    // Curve swap related: currently support typical 2-token stable pool like weeth<->weth
    // https://docs.curve.fi/router/CurveRouterNG/#_swap_params
    ///////////////////////////////

    /**
     * @dev swap in a curve 2-token pool with expected minimum and best-in-theory output for a given input-output pair.
     */
    function swapInCurveTwoTokenPool(
        address inToken,
        address outToken,
        address singlePool,
        uint256 _inAmount,
        uint256 _minOut
    ) external onlyWhitelistedCaller returns (uint256) {
        address[11] memory _route = [
            inToken,
            singlePool,
            outToken,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR,
            Constants.ZRO_ADDR
        ];
        // swap_type = 1 (exchange), pool_type = 1 (stable)
        uint256[5] memory _swapParams = [
            _getCurvePoolIndex(singlePool, inToken),
            _getCurvePoolIndex(singlePool, outToken),
            uint256(1),
            uint256(1),
            uint256(2)
        ];
        uint256[5] memory _dummy = [uint256(0), uint256(0), uint256(0), uint256(0), uint256(0)];
        uint256[5][5] memory _params = [_swapParams, _dummy, _dummy, _dummy, _dummy];
        address[5] memory _pools =
            [singlePool, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR, Constants.ZRO_ADDR];

        SafeERC20.safeTransferFrom(ERC20(inToken), msg.sender, address(this), _inAmount);
        _approveTokenToDex(inToken, address(curveRouter));
        uint256 _out = curveRouter.exchange(_route, _params, _inAmount, _minOut, _pools, msg.sender);
        emit SwapInCurve(inToken, outToken, msg.sender, _inAmount, _out);
        _revokeTokenApproval(inToken, address(curveRouter));
        return _out;
    }

    function applySlippageMargin(uint256 _theory) public view returns (uint256) {
        return _theory * Constants.TOTAL_BPS / SWAP_SLIPPAGE_BPS;
    }

    function applySlippageRelax(uint256 _theory) public view returns (uint256) {
        return _theory * SWAP_SLIPPAGE_BPS / Constants.TOTAL_BPS;
    }

    function _getCurvePoolIndex(address _twoTokenPool, address _token) internal view returns (uint256) {
        if (ICurvePool(_twoTokenPool).coins(0) == _token) {
            return 0;
        } else {
            if (ICurvePool(_twoTokenPool).coins(1) != _token) {
                revert Constants.INVALID_TOKEN_INDEX_IN_CURVE();
            }
            return 1;
        }
    }

    ///////////////////////////////
    // Pendle swap related
    // check https://docs.pendle.finance/Developers/Contracts/PendleRouter#important-structs-in-pendlerouter
    // MUST have off-chain to supply calldata bytes via https://api-v2.pendle.finance/core/docs#/SDK/SdkController_swap
    // Ensure the receiver of the swap is the calling strategy
    ///////////////////////////////

    /**
     * @dev ensure the receiver of this swap is the same as msg.sender(strategy)
     * @dev and correctly encoded in given _swapCallData as the first argument
     */
    function swapWithPendleRouter(
        address _pendleRouter,
        address _inputToken,
        address _outputToken,
        uint256 _inAmount,
        uint256 _minOut,
        bytes calldata _swapCallData
    ) external onlyWhitelistedCaller returns (uint256) {
        address _receiverDecoded = _getReceiverFromPendleCalldata(_swapCallData);
        if (_receiverDecoded != msg.sender && _receiverDecoded != IPendleHelper(msg.sender)._strategy()) {
            revert Constants.WRONG_SWAP_RECEIVER();
        }
        return _callPendleRouter(
            _pendleRouter, _inputToken, _outputToken, _inAmount, _minOut, _swapCallData, _receiverDecoded
        );
    }

    /**
     * @dev typically used with https://api-v2.pendle.finance/core/docs#/SDK/SdkController_rollOverPt
     */
    function chainSwapWithPendleRouter(
        address _pendleRouter,
        address _inputToken,
        address _outputToken,
        uint256 _inAmount,
        uint256 _minOut,
        bytes calldata _swapCallData
    ) external onlyWhitelistedCaller returns (uint256) {
        (,,, bytes memory _reflectCall) = abi.decode(_swapCallData[4:], (address, bytes, bytes, bytes));
        address _receiverDecoded = this._getReceiverFromPendleCalldata(_reflectCall);
        if (_receiverDecoded != msg.sender && _receiverDecoded != IPendleHelper(msg.sender)._strategy()) {
            revert Constants.WRONG_SWAP_RECEIVER();
        }
        return _callPendleRouter(
            _pendleRouter,
            _inputToken,
            _outputToken,
            _inAmount,
            applySlippageRelax(_minOut),
            _swapCallData,
            _receiverDecoded
        );
    }

    function _callPendleRouter(
        address _pendleRouter,
        address _inputToken,
        address _outputToken,
        uint256 _inAmount,
        uint256 _minOut,
        bytes calldata _swapCallData,
        address _receiverDecoded
    ) internal returns (uint256) {
        address _router = _pendleRouter == Constants.ZRO_ADDR ? pendleRouteV4 : _pendleRouter;
        SafeERC20.safeTransferFrom(ERC20(_inputToken), msg.sender, address(this), _inAmount);
        _approveTokenToDex(_inputToken, _router);
        uint256 _outputBalBefore = ERC20(_outputToken).balanceOf(_receiverDecoded);
        address(_router).functionCall(_swapCallData);
        uint256 _actualOut = ERC20(_outputToken).balanceOf(_receiverDecoded) - _outputBalBefore;
        if (applySlippageMargin(_actualOut) < _minOut) {
            revert Constants.SWAP_OUT_TOO_SMALL();
        }
        _revokeTokenApproval(_inputToken, _router);
        return _actualOut;
    }

    function getPriceFromChainLink(address _aggregator) public view returns (int256, uint256, uint8) {
        return getPriceFromChainLinkWithHeartbeat(_aggregator, DEFAULT_Heartbeat);
    }

    function getPriceFromChainLinkWithHeartbeat(address _aggregator, uint32 _heartbeat)
        public
        view
        returns (int256, uint256, uint8)
    {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = IOracleAggregatorV3(_aggregator).latestRoundData();
        if (roundId == 0 || answer <= 0 || (block.timestamp - updatedAt) > _heartbeat) {
            revert Constants.WRONG_PRICE_FROM_ORACLE();
        }
        return (answer, updatedAt, IOracleAggregatorV3(_aggregator).decimals());
    }

    function getPTPriceInSYFromPendle(address _pendleMarket, uint32 twapDurationInSeconds)
        public
        view
        returns (uint256)
    {
        return pendleOracle.getPtToSyRate(
            _pendleMarket,
            twapDurationInSeconds //> PENDLE_ORACLE_TWAP ? twapDurationInSeconds : PENDLE_ORACLE_TWAP
        );
    }

    /**
     * @dev https://docs.pendle.finance/Developers/Oracles/HowToIntegratePtAndLpOracle#optional-convert-the-price-to-a-different-asset
     * @dev convert from PT to SY then to other asset using on-chain oracle feed
     */
    function getPTPriceInAsset(
        address _assetToken,
        address _assetOracle,
        address _ptMarket,
        uint32 _twapSeconds,
        uint32 _heartbeat,
        address _underlyingYield,
        address _underlyingYieldOracle,
        address _intermediateOracle,
        uint256 _syToUnderlyingRate
    ) public view returns (uint256) {
        // 1:1 value at maturity
        uint256 _pt2UnderlyingRateScaled = (
            IPMarketV3(_ptMarket).isExpired() ? Constants.ONE_ETHER : getPTPriceInSYFromPendle(_ptMarket, _twapSeconds)
        ) * _syToUnderlyingRate / Constants.ONE_ETHER;

        if (_underlyingYield == _assetToken) {
            return _pt2UnderlyingRateScaled;
        }

        // ensure asset and underlying oracles return prices in same base unit like USD
        (uint256 _uP, uint256 _uD) = _getUnderlyingPrice(
            _underlyingYield, _underlyingYieldOracle, _intermediateOracle, _heartbeat, IPMarketV3(_ptMarket).isExpired()
        );
        (int256 _assetPrice,, uint8 _assetPriceDecimal) = getPriceFromChainLinkWithHeartbeat(_assetOracle, _heartbeat);
        return _pt2UnderlyingRateScaled * Constants.convertDecimalToUnit(_assetPriceDecimal) * _uP
            / (_uD * uint256(_assetPrice));
    }

    function _getUnderlyingPrice(
        address _underlyingYield,
        address _underlyingYieldOracle,
        address _intermediateOracle,
        uint32 _heartbeat,
        bool _expired
    ) internal view returns (uint256, uint256) {
        uint256 _uP;
        uint256 _uD;

        if (_underlyingYield != _underlyingYieldOracle) {
            (int256 _underlyingPrice,, uint8 _decimal) =
                getPriceFromChainLinkWithHeartbeat(_underlyingYieldOracle, _heartbeat);
            _uP = uint256(_underlyingPrice);
            _uD = Constants.convertDecimalToUnit(_decimal);
        } else {
            // assume _underlyingYield is an ERC4626 vault
            _uD = Constants.convertDecimalToUnit(IERC4626Vault(_underlyingYield).decimals());
            _uP = _expired ? _uD : IERC4626Vault(_underlyingYield).convertToAssets(_uD);
        }

        if (_intermediateOracle != Constants.ZRO_ADDR) {
            (int256 _intermediatePrice,, uint8 _decimalIntermediate) =
                getPriceFromChainLinkWithHeartbeat(_intermediateOracle, _heartbeat);
            _uP = _uP * uint256(_intermediatePrice) / _uD;
            _uD = Constants.convertDecimalToUnit(_decimalIntermediate);
        }
        return (_uP, _uD);
    }

    function getPTAmountInAsset(address _assetToken, address ptToken, uint256 ptAmount, uint256 _ptPrice)
        external
        view
        returns (uint256)
    {
        return ptAmount * _ptPrice * Constants.convertDecimalToUnit(ERC20(_assetToken).decimals())
            / (Constants.convertDecimalToUnit(ERC20(ptToken).decimals()) * Constants.ONE_ETHER);
    }

    function getAssetAmountInPT(address _assetToken, address ptToken, uint256 assetAmount, uint256 _ptPrice)
        external
        view
        returns (uint256)
    {
        return assetAmount * Constants.ONE_ETHER * Constants.convertDecimalToUnit(ERC20(ptToken).decimals())
            / (Constants.convertDecimalToUnit(ERC20(_assetToken).decimals()) * _ptPrice);
    }

    function convertAmountWithFeeds(
        ERC20 _tokenFrom,
        uint256 _fromAmount,
        address _fromFeed,
        ERC20 _tokenTo,
        address _toFeed,
        uint32 _fromHeartbeat,
        uint32 _toHeartbeat
    ) public view returns (uint256) {
        (int256 _toP,, uint8 _toPDecimal) = getPriceFromChainLinkWithHeartbeat(_toFeed, _toHeartbeat);
        (int256 _fromP,, uint8 _fromPDecimal) = getPriceFromChainLinkWithHeartbeat(_fromFeed, _fromHeartbeat);

        return _fromAmount * uint256(_fromP) * Constants.convertDecimalToUnit(_toPDecimal)
            * Constants.convertDecimalToUnit(ERC20(_tokenTo).decimals())
            / (
                Constants.convertDecimalToUnit(_tokenFrom.decimals()) * uint256(_toP)
                    * Constants.convertDecimalToUnit(_fromPDecimal)
            );
    }

    function convertAmountWithPriceFeed(
        address _oracle,
        uint32 _heartbeat,
        uint256 _amount,
        ERC20 _fromToken,
        ERC20 _toToken
    ) public view returns (uint256) {
        (int256 _p,, uint8 _pDecimal) = getPriceFromChainLinkWithHeartbeat(_oracle, _heartbeat);
        return _amount * uint256(_p) * Constants.convertDecimalToUnit(_toToken.decimals())
            / (Constants.convertDecimalToUnit(_pDecimal) * Constants.convertDecimalToUnit(_fromToken.decimals()));
    }

    function _getReceiverFromPendleCalldata(bytes calldata _data) public pure returns (address) {
        return abi.decode(_data[4:36], (address));
    }

    function _getFunctionSelector(bytes calldata _data) external pure returns (bytes4) {
        bytes4 selector = bytes4(_data[:4]);
        return selector;
    }

    function getAssetOracle(address _token) external view returns (address) {
        return _tokenOracles[_token];
    }

    function _addOraclesForBNBChain() internal {
        _tokenOracles[USDC_BNB] = USDC_USD_Feed_BNB;
        _tokenOracles[USDX] = USDX_USD_Feed;
        _tokenOracles[USDe_BNB] = USDe_USD_Feed_BNB;
        _tokenOracles[USR_BNB] = USR_USD_Feed_BNB;
        _tokenOracles[XAUM_BNB] = XAUM_USD_Feed_BNB;
        _tokenOracles[USDT_BNB] = USDT_USD_Feed_BNB;
    }

    function _addOraclesForEthereum() internal {
        _tokenOracles[usdt] = USDT_USD_Feed;
        _tokenOracles[usdc] = USDC_USD_Feed;
        _tokenOracles[usds] = USDS_USD_Feed;
        _tokenOracles[usde] = USDe_USD_FEED;
        _tokenOracles[USR] = USR_USD_FEED;
        _tokenOracles[USDf] = USDf_USD_FEED;
        _tokenOracles[GHO] = GHO_USD_FEED;
    }
}
