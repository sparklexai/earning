// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Test, console} from "forge-std/Test.sol";
import {Constants} from "../../src/utils/Constants.sol";

interface IPendleYT {
    function PT() external view returns (address);
}

interface IPendleMarket {
    function readTokens() external view returns (address _SY, address _PT, address _YT);
}

contract DummyDEXRouter is Test {
    ///////////////////////////////
    // mainnet tokens
    ///////////////////////////////
    address public constant usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant usde = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address public constant susde = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address public constant usds = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    ///////////////////////////////
    // mainnet whales
    ///////////////////////////////
    address public constant _usdcWhale = 0x37305B1cD40574E4C5Ce33f8e8306Be057fD7341;
    address public constant _usdeWhale = 0xf89d7b9c864f589bbF53a82105107622B35EaA40;
    address public constant _susdeWhale = 0x5563CDA70F7aA8b6C00C52CB3B9f0f45831a22b1;
    address public constant _usdsWhale = 0xf8191D98ae98d2f7aBDFB63A9b0b812b93C873AA;

    mapping(address => mapping(address => uint256)) public prices;
    mapping(address => address) public whales;

    function setPrices(address _fromToken, address _toToken, uint256 _priceInE18) public {
        prices[_fromToken][_toToken] = _priceInE18;
    }

    function setWhales(address _token, address _whale) public {
        whales[_token] = _whale;
    }

    function _getTokenWhale(address _token) internal returns (address) {
        address _w = whales[_token];
        if (_w == Constants.ZRO_ADDR) {
            if (_token == usdc) {
                _w = _usdcWhale;
            } else if (_token == usde) {
                _w = _usdeWhale;
            } else if (_token == susde) {
                _w = _susdeWhale;
            } else if (_token == usds) {
                _w = _usdsWhale;
            }
        }
        require(_w != Constants.ZRO_ADDR, "no whale to fund swap!");
        return _w;
    }

    function _dummySwapExactIn(
        address _caller,
        address _receiver,
        address _inToken,
        address _outToken,
        uint256 _inTokenAmount
    ) internal returns (uint256) {
        ERC20(_inToken).transferFrom(_caller, address(this), _inTokenAmount);
        uint256 _netOut = _inTokenAmount * prices[_inToken][_outToken] * ERC20(_outToken).decimals()
            / (1e18 * ERC20(_inToken).decimals());

        address _whaleSugarDaddy = _getTokenWhale(_outToken);
        vm.startPrank(_whaleSugarDaddy);
        ERC20(_outToken).transferFrom(_whaleSugarDaddy, _receiver, _netOut);
        return _netOut;
    }

    ///////////////////////////////
    // Pendle Router mimic methods
    ///////////////////////////////
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct TokenOutput {
        address tokenOut;
        uint256 minTokenOut;
        address tokenRedeemSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct SwapData {
        SwapType swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    enum SwapType {
        NONE,
        KYBERSWAP,
        ODOS,
        // ETH_WETH not used in Aggregator
        ETH_WETH,
        OKX,
        ONE_INCH,
        PARASWAP,
        RESERVE_2,
        RESERVE_3,
        RESERVE_4,
        RESERVE_5
    }

    enum OrderType {
        SY_FOR_PT,
        PT_FOR_SY,
        SY_FOR_YT,
        YT_FOR_SY
    }

    struct Order {
        uint256 salt;
        uint256 expiry;
        uint256 nonce;
        OrderType orderType;
        address token;
        address YT;
        address maker;
        address receiver;
        uint256 makingAmount;
        uint256 lnImpliedRate;
        uint256 failSafeRate;
        bytes permit;
    }

    struct FillOrderParams {
        Order order;
        bytes signature;
        uint256 makingAmount;
    }

    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    function redeemPyToToken(address receiver, address YT, uint256 netPyIn, TokenOutput calldata output)
        external
        returns (uint256 netTokenOut, uint256 netSyInterm)
    {
        uint256 _netTokenOut = _dummySwapExactIn(msg.sender, receiver, IPendleYT(YT).PT(), output.tokenOut, netPyIn);
        return (_netTokenOut, _netTokenOut);
    }

    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm) {
        (, address _pt,) = IPendleMarket(market).readTokens();
        uint256 _netPtOut = _dummySwapExactIn(msg.sender, receiver, input.tokenIn, _pt, input.netTokenIn);
        return (_netPtOut, 0, _netPtOut);
    }

    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm) {
        (, address _pt,) = IPendleMarket(market).readTokens();
        uint256 _netTokenOut = _dummySwapExactIn(msg.sender, receiver, _pt, output.tokenOut, exactPtIn);
        return (_netTokenOut, 0, _netTokenOut);
    }
}
