// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WETH} from "../../../interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "../../utils/Constants.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {IPMarketV3} from "@pendle/contracts/interfaces/IPMarketV3.sol";
import {IPPrincipalToken} from "@pendle/contracts/interfaces/IPPrincipalToken.sol";
import {IStandardizedYield} from "@pendle/contracts/interfaces/IStandardizedYield.sol";

interface IPendleStrategy {
    function getPTPriceInAsset(address _assetToken, address ptToken) external view returns (uint256);
    function _capAmountByBalance(ERC20 _token, uint256 _amount, bool _applyMargin) external view returns (uint256);
}

contract PendleHelper {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    address public _pendleRouter;
    address public immutable _strategy;
    address public _swapper;

    ///////////////////////////////
    // events
    ///////////////////////////////

    constructor(address strategy, address pendleRouter, address swapper) {
        if (strategy == Constants.ZRO_ADDR || pendleRouter == Constants.ZRO_ADDR || swapper == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _strategy = strategy;
        _pendleRouter = pendleRouter;
        _swapper = swapper;
    }

    ///////////////////////////////
    // earn with Pendle: Trading Functions
    ///////////////////////////////

    function _checkValidityWithMarket(address _ptAddress, address _ptMarket, bool _beforeExpire) external view {
        if (_ptAddress == Constants.ZRO_ADDR || _ptMarket == Constants.ZRO_ADDR) {
            revert Constants.PT_NOT_FOUND();
        }
        if (_beforeExpire && IPMarketV3(_ptMarket).isExpired()) {
            revert Constants.PT_ALREADY_MATURED();
        } else if (!_beforeExpire && !IPMarketV3(_ptMarket).isExpired()) {
            revert Constants.PT_NOT_MATURED();
        }
        (, IPPrincipalToken _ptFromMarket,) = IPMarketV3(_ptMarket).readTokens();
        if (address(_ptFromMarket) != _ptAddress) {
            revert Constants.PT_NOT_MATCH_MARKET();
        }
    }

    /**
     * @notice Switch to ptTokenTo from ptTokenFrom
     * @param ptTokenFrom the PT market to exit
     * @param ptTokenTo the PT market to rollover (must be active)
     * @param ptFromAmount Amount of current PT amount to rollover
     * @param _swapData calldata from pendle SDK
     * @param _asset the intermediate token for pricing
     */
    function _swapPTForRollOver(
        address ptTokenFrom,
        address ptTokenTo,
        uint256 ptFromAmount,
        bytes calldata _swapData,
        bytes4 _targetSelector,
        address _asset
    ) external returns (uint256) {
        if (msg.sender != _strategy) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        ptFromAmount = IPendleStrategy(_strategy)._capAmountByBalance(ERC20(ptTokenFrom), ptFromAmount, false);
        if (ptFromAmount == 0) {
            revert Constants.ZERO_TO_SWAP_IN_PENDLE();
        }
        if (TokenSwapper(_swapper)._getFunctionSelector(_swapData) != _targetSelector) {
            revert Constants.INVALID_SWAP_CALLDATA();
        }
        SafeERC20.safeTransferFrom(ERC20(ptTokenFrom), msg.sender, address(this), ptFromAmount);
        uint256 _minOut = _getMinExpectedPTForRollover(ptTokenFrom, ptTokenTo, _asset, ptFromAmount);
        _approveToken(ptTokenFrom, _swapper);
        uint256 ptReceived = TokenSwapper(_swapper).chainSwapWithPendleRouter(
            _pendleRouter, ptTokenFrom, ptTokenTo, ptFromAmount, _minOut, _swapData
        );
        return ptReceived;
    }

    /**
     * @notice Buy PT tokens with given asset token
     * @param _assetToken purchase PT with this asset
     * @param assetAmount Amount of asset token to spend
     * @param _swapData calldata from pendle SDK
     */
    function _swapAssetForPT(
        address _assetToken,
        address ptToken,
        uint256 assetAmount,
        bytes calldata _swapData,
        bytes4 _targetSelector
    ) external returns (uint256) {
        if (msg.sender != _strategy) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        assetAmount = IPendleStrategy(_strategy)._capAmountByBalance(ERC20(_assetToken), assetAmount, false);
        if (assetAmount == 0) {
            revert Constants.ZERO_TO_SWAP_IN_PENDLE();
        }
        if (TokenSwapper(_swapper)._getFunctionSelector(_swapData) != _targetSelector) {
            revert Constants.INVALID_SWAP_CALLDATA();
        }
        SafeERC20.safeTransferFrom(ERC20(_assetToken), msg.sender, address(this), assetAmount);
        uint256 _minOut = _getMinExpectedPT(_assetToken, ptToken, assetAmount);
        _approveToken(_assetToken, _swapper);
        uint256 ptReceived = TokenSwapper(_swapper).swapWithPendleRouter(
            _pendleRouter, _assetToken, ptToken, assetAmount, _minOut, _swapData
        );
        return ptReceived;
    }

    function _swapPTForAsset(
        address _assetToken,
        address ptToken,
        uint256 ptAmount,
        bytes calldata _swapData,
        bytes4 _targetSelector
    ) external returns (uint256) {
        if (msg.sender != _strategy) {
            revert Constants.INVALID_HELPER_CALLER();
        }
        ptAmount = IPendleStrategy(_strategy)._capAmountByBalance(ERC20(ptToken), ptAmount, false);
        if (ptAmount == 0) {
            revert Constants.ZERO_TO_SWAP_IN_PENDLE();
        }
        if (TokenSwapper(_swapper)._getFunctionSelector(_swapData) != _targetSelector) {
            revert Constants.INVALID_SWAP_CALLDATA();
        }
        SafeERC20.safeTransferFrom(ERC20(ptToken), msg.sender, address(this), ptAmount);
        uint256 _minOut = _getMinExpectedAsset(_assetToken, ptToken, ptAmount);
        _approveToken(ptToken, _swapper);
        return TokenSwapper(_swapper).swapWithPendleRouter(
            _pendleRouter, ptToken, _assetToken, ptAmount, _minOut, _swapData
        );
    }

    function _getMinExpectedPTForRollover(
        address _ptTokenFrom,
        address _ptTokenTo,
        address _asset,
        uint256 _ptAmountFrom
    ) public view returns (uint256) {
        uint256 _fromInAsset = _getAmountInAsset(_asset, _ptTokenFrom, _ptAmountFrom);
        uint256 _outInTheory = _getAmountInPT(_asset, _ptTokenTo, _fromInAsset);
        return _outInTheory;
    }

    function _getMinExpectedPT(address _assetToken, address _ptToken, uint256 _assetIn) public view returns (uint256) {
        uint256 _outInTheory = _getAmountInPT(_assetToken, _ptToken, _assetIn);
        return _outInTheory;
    }

    function _getMinExpectedAsset(address _assetToken, address _ptToken, uint256 _ptIn) public view returns (uint256) {
        uint256 _outInTheory = _getAmountInAsset(_assetToken, _ptToken, _ptIn);
        return _outInTheory;
    }

    function _getAmountInAsset(address _assetToken, address ptToken, uint256 ptAmount) public view returns (uint256) {
        if (ptAmount == 0) {
            return ptAmount;
        }
        return TokenSwapper(_swapper).getPTAmountInAsset(
            _assetToken, ptToken, ptAmount, IPendleStrategy(_strategy).getPTPriceInAsset(_assetToken, ptToken)
        );
    }

    function _getAmountInPT(address _assetToken, address ptToken, uint256 assetAmount) public view returns (uint256) {
        if (assetAmount == 0) {
            return assetAmount;
        }
        return TokenSwapper(_swapper).getAssetAmountInPT(
            _assetToken, ptToken, assetAmount, IPendleStrategy(_strategy).getPTPriceInAsset(_assetToken, ptToken)
        );
    }

    function _approveToken(address _token, address _spender) internal {
        if (ERC20(_token).allowance(address(this), _spender) == 0) {
            SafeERC20.forceApprove(ERC20(_token), _spender, type(uint256).max);
        }
    }
}
