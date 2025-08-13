// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseAAVEStrategy} from "./BaseAAVEStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {Constants} from "../../utils/Constants.sol";
import {TokenSwapper} from "../../utils/TokenSwapper.sol";
import {AAVEHelper} from "./AAVEHelper.sol";
import {SparkleXVault} from "../../SparkleXVault.sol";

/**
 * @dev deposit collateral into AAVE-alike Lending and borrow stablecoin to deposit into spUSD.
 * @dev assuming supply token (collateral) is same as asset token
 */
contract CollYieldAAVEStrategy is BaseAAVEStrategy {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    uint32 public constant FEED_HEARTBEAT = 901;
    SparkleXVault public spUSDVault;
    address public _assetFeed;
    mapping(address => uint32) public _feedHeartbeats;
    mapping(address => bool) public _borrowSwapPools;
    /*
     * @dev pool to swap between borrowed token to spUSD assset
     */
    address public _borrowedToSPUSDPool;
    /*
     * @dev intermediate pool to swap between borrowed token to spUSD assset
     */
    address public _borrowedToSPUSDIntermediatePool;

    ///////////////////////////////
    // member storage
    ///////////////////////////////

    ///////////////////////////////
    // events
    ///////////////////////////////
    event FeedHeartBeatChanged(address indexed _token, uint32 _old, uint32 _new);
    event BorrowSwapPoolApproved(address indexed _pool, bool _approved);
    event BorrowedToSPUSDPoolChanged(address indexed _newPool, address indexed _newIntermediatePool);

    constructor(address vault, address assetFeed, address _spUSD, uint32 _assetFeedHeartbeat)
        BaseAAVEStrategy(ERC20(address(SparkleXVault(vault).asset())), vault)
    {
        if (_spUSD == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        spUSDVault = SparkleXVault(_spUSD);
        _approveToken(_spUSD, _spUSD);
        _approveToken(SparkleXVault(_spUSD).asset(), _spUSD);
        _assetFeed = assetFeed;
        setFeedHeartBeat(SparkleXVault(vault).asset(), _assetFeedHeartbeat);
        _loopingBorrow = false;
    }

    function approveAllowanceForHelper() external onlyOwner {
        if (
            _aaveHelper != Constants.ZRO_ADDR
                && AAVEHelper(_aaveHelper)._borrowToken().allowance(address(this), _aaveHelper) == 0
        ) {
            _prepareAllowanceForHelper();
        }
    }

    function setBorrowToSPUSDPool(address _newPool, address _newIntermediatePool) public onlyOwner {
        if (_borrowedToSPUSDPool != Constants.ZRO_ADDR) {
            setBorrowSwapPoolApproval(_borrowedToSPUSDPool, false);
        }
        if (_borrowedToSPUSDIntermediatePool != Constants.ZRO_ADDR) {
            setBorrowSwapPoolApproval(_borrowedToSPUSDIntermediatePool, false);
        }

        _borrowedToSPUSDPool = _newPool;
        if (_newPool != Constants.ZRO_ADDR) {
            setBorrowSwapPoolApproval(_borrowedToSPUSDPool, true);
        }

        _borrowedToSPUSDIntermediatePool = _newIntermediatePool;
        if (_newIntermediatePool != Constants.ZRO_ADDR) {
            setBorrowSwapPoolApproval(_borrowedToSPUSDIntermediatePool, true);
        }

        emit BorrowedToSPUSDPoolChanged(_newPool, _newIntermediatePool);
    }

    function setFeedHeartBeat(address _token, uint32 _heartbeat) public onlyOwner {
        emit FeedHeartBeatChanged(_token, _feedHeartbeats[_token], _heartbeat);
        _feedHeartbeats[_token] = _heartbeat;
    }

    function setBorrowSwapPoolApproval(address _pool, bool _approved) public onlyOwner {
        _borrowSwapPools[_pool] = _approved;
        emit BorrowSwapPoolApproved(_pool, _approved);
    }

    ///////////////////////////////
    // earn with spUSD
    ///////////////////////////////

    function _depositToSpUSD(uint256 _toDeposit) internal returns (uint256) {
        ERC20 _borrowToken = AAVEHelper(_aaveHelper)._borrowToken();
        address _spUSDAssetToken = spUSDVault.asset();
        _toDeposit = _capAmountByBalance(_borrowToken, _toDeposit, false);
        if (address(_borrowToken) != _spUSDAssetToken) {
            uint256 _assetBefore = ERC20(_spUSDAssetToken).balanceOf(address(this));
            if (_toDeposit > 0) {
                _toDeposit = swapViaUniswap(
                    address(_borrowToken), _toDeposit, _borrowedToSPUSDIntermediatePool, _borrowedToSPUSDPool
                );
            }
            _toDeposit += _assetBefore;
        }
        if (_toDeposit == 0) {
            return _toDeposit;
        }
        return spUSDVault.deposit(_toDeposit, address(this));
    }

    /*
     * @dev withdraw investment from spUSD
     */
    function requestWithdrawalFromSpUSD(uint256 _toWithdrawSpUSD) public onlyStrategistOrOwner returns (uint256) {
        if (getPendingWithdrawSpUSD() > 0) {
            revert Constants.SPUSD_WITHDRAW_EXISTS();
        }
        _toWithdrawSpUSD = _capAmountByBalance(ERC20(address(spUSDVault)), _toWithdrawSpUSD, false);
        uint256 _balBefore = ERC20(spUSDVault.asset()).balanceOf(address(this));
        spUSDVault.requestRedemption(_toWithdrawSpUSD);
        return ERC20(spUSDVault.asset()).balanceOf(address(this)) - _balBefore;
    }

    /**
     * @dev complete the withdrawal request with spUSD
     */
    function claimWithdrawFromSpUSD() public onlyStrategistOrOwner returns (uint256) {
        uint256 _toClaim = getPendingWithdrawSpUSD();
        if (_toClaim > 0) {
            return spUSDVault.claimRedemptionRequest();
        } else {
            return _toClaim;
        }
    }

    function _leveragePosition(uint256 _assetAmount, uint256 _borrowAmount, bytes memory _extraAction)
        internal
        override
    {
        _prepareSupplyFromAsset(_assetAmount, _extraAction);
        uint256 _safeToBorrow = AAVEHelper(_aaveHelper).previewLeverageForInvest(0, _borrowAmount);
        _supplyToAAVE(AAVEHelper(_aaveHelper)._supplyToken().balanceOf(address(this)));
        _borrowFromAAVE(_safeToBorrow);
        _depositToSpUSD(AAVEHelper(_aaveHelper)._borrowToken().balanceOf(address(this)));
    }

    ///////////////////////////////
    // core external methods
    ///////////////////////////////

    /**
     * @dev complete the withdrawal request with spUSD and repay debt in Lending Pool
     */
    function claimAndRepay(uint256 _repayAmount) external onlyStrategistOrOwner {
        ERC20 _borrowToken = AAVEHelper(_aaveHelper)._borrowToken();
        claimWithdrawFromSpUSD();
        uint256 _spUSDAsset = ERC20(spUSDVault.asset()).balanceOf(address(this));
        if (_spUSDAsset > 0 && address(_borrowToken) != spUSDVault.asset()) {
            swapViaUniswap(spUSDVault.asset(), _spUSDAsset, _borrowedToSPUSDIntermediatePool, _borrowedToSPUSDPool);
        }
        _repayAmount = _capAmountByBalance(_borrowToken, _repayAmount, false);
        if (_repayAmount > 0) {
            _repayDebtToAAVE(_repayAmount);
        }
    }

    /**
     * @dev withdraw as much as possible supply collateral from Lending Pool
     * @dev and return to vault
     */
    function redeem(uint256 _supplyAmount, bytes calldata /* _extraAction */ )
        external
        override
        onlyStrategistOrOwner
        returns (uint256)
    {
        uint256 _margin = AAVEHelper(_aaveHelper).getMaxRedeemableAmount();
        if (_margin == 0) {
            return _margin;
        }
        _supplyAmount = _supplyAmount > _margin ? _margin : _supplyAmount;
        uint256 _redeemed = _withdrawCollateralFromAAVE(_supplyAmount);

        if (_redeemed == 0) {
            return _redeemed;
        }
        return _returnAssetToVault(_redeemed);
    }

    /**
     * @dev return current pending withdraw request in spUSD if any
     */
    function getPendingWithdrawSpUSD() public view returns (uint256) {
        return spUSDVault.userRedemptionRequestShares(address(this));
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _collectAsset(uint256 _expectedAsset, bytes calldata _extraAction) internal override {
        uint256[] memory _previews = AAVEHelper(_aaveHelper).previewCollect(_expectedAsset);
        if (_previews[0] == 0 || _previews[0] == 1) {
            return;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        if (_previews[0] == 2) {
            _withdrawCollateralFromAAVE(_previews[1]);
            return;
        }

        // request redemption from spUSD
        (uint256 _netSupply, uint256 _debt, uint256 _totalInSupply) = getNetSupplyAndDebt(false);
        uint256 _equivalentBorrow = _convertSupplyToBorrow(_expectedAsset);
        uint256 _toClaimFromSpUSD;
        if (_totalInSupply <= _previews[4] || _netSupply <= _expectedAsset || _debt <= _equivalentBorrow) {
            // withdraw everything from spUSD
            _toClaimFromSpUSD = ERC20(address(spUSDVault)).balanceOf(address(this));
        } else {
            // withdraw a portion from spUSD
            ERC20 _borrowToken = AAVEHelper(_aaveHelper)._borrowToken();
            uint256 _spUSDAsset = _equivalentBorrow;
            if (address(_borrowToken) != spUSDVault.asset()) {
                _spUSDAsset = _convertAmount(address(_borrowToken), _equivalentBorrow, spUSDVault.asset());
            }
            _toClaimFromSpUSD =
                _capAmountByBalance(ERC20(address(spUSDVault)), spUSDVault.convertToShares(_spUSDAsset), true);
        }
        requestWithdrawalFromSpUSD(_toClaimFromSpUSD);
    }

    ///////////////////////////////
    // strategy customized methods
    ///////////////////////////////
    function totalAssets() public view override returns (uint256) {
        // Check supply in AAVE if any
        (uint256 _netSupply,,) = getNetSupplyAndDebt(true);
        uint256 _aTokenBalance = AAVEHelper(_aaveHelper)._supplyAToken().balanceOf(address(this));
        return _asset.balanceOf(address(this)) + (_netSupply > 0 ? _aTokenBalance : _netSupply);
    }

    function assetsInCollection() public view override returns (uint256) {
        return 0;
    }

    function _prepareSupplyFromAsset(uint256 _assetAmount, bytes memory /* _extraAction */ )
        internal
        override
        returns (uint256)
    {
        uint256 amount = _capAllocationAmount(_assetAmount);
        if (amount > 0) {
            emit AllocateInvestment(msg.sender, amount);
            SafeERC20.safeTransferFrom(_asset, _vault, address(this), amount);
        }
        return amount;
    }

    function _convertSupplyToBorrow(uint256 _supplyAmount) public view override returns (uint256) {
        return _convertAmount(
            address(AAVEHelper(_aaveHelper)._supplyToken()),
            _supplyAmount,
            address(AAVEHelper(_aaveHelper)._borrowToken())
        );
    }

    function _convertBorrowToAsset(uint256 _borrowAmount) public view override returns (uint256) {
        return _convertAmount(address(AAVEHelper(_aaveHelper)._borrowToken()), _borrowAmount, address(_asset));
    }

    function _convertAmount(address _fromToken, uint256 _fromAmount, address _toToken) public view returns (uint256) {
        uint32 _fromHeartbeat = _getHeartBeat(_fromToken);
        uint32 _toHeartbeat = _getHeartBeat(_toToken);
        return TokenSwapper(_swapper).convertAmountWithFeeds(
            ERC20(_fromToken),
            _fromAmount,
            _fromToken == address(_asset) ? _assetFeed : TokenSwapper(_swapper).getAssetOracle(_fromToken),
            ERC20(_toToken),
            _toToken == address(_asset) ? _assetFeed : TokenSwapper(_swapper).getAssetOracle(_toToken),
            _fromHeartbeat,
            _toHeartbeat
        );
    }

    function _convertBorrowToSupply(uint256 _borrowAmount) public view override returns (uint256) {
        return _convertBorrowToAsset(_borrowAmount);
    }

    function _getHeartBeat(address _token) internal view returns (uint32) {
        uint32 _heartbeat = _feedHeartbeats[_token];
        return _heartbeat > 0 ? _heartbeat : FEED_HEARTBEAT;
    }

    /*
     * @dev swap given amount of from token 
     * @dev via given uniswap pools (possibly through an intermediate pool)
     */
    function swapViaUniswap(address _fromToken, uint256 _fromTokenAmount, address _intermediatePool, address _assetPool)
        public
        onlyStrategistOrOwner
        returns (uint256)
    {
        _fromTokenAmount = _capAmountByBalance(ERC20(_fromToken), _fromTokenAmount, false);
        if (_fromTokenAmount == 0) {
            return _fromTokenAmount;
        }
        if (!_borrowSwapPools[_assetPool]) {
            revert Constants.BORROW_SWAP_POOL_INVALID();
        }

        _approveToken(_fromToken, address(_swapper));

        if (_intermediatePool == Constants.ZRO_ADDR) {
            address _outToken = TokenSwapper(_swapper).getOutTokenForUniPool(_fromToken, _assetPool);
            uint256 _outExpected =
                TokenSwapper(_swapper).applySlippageRelax(_convertAmount(_fromToken, _fromTokenAmount, _outToken));
            return TokenSwapper(_swapper).swapExactInWithUniswap(
                _fromToken, _outToken, _assetPool, _fromTokenAmount, _outExpected
            );
        } else {
            if (!_borrowSwapPools[_intermediatePool]) {
                revert Constants.BORROW_SWAP_POOL_INVALID();
            }
            // from token -> intermediate token
            address _intermediateToken = TokenSwapper(_swapper).getOutTokenForUniPool(_fromToken, _intermediatePool);
            uint256 _expectedIntermediateAmount = TokenSwapper(_swapper).applySlippageRelax(
                _convertAmount(_fromToken, _fromTokenAmount, _intermediateToken)
            );
            uint256 _intermediateAmount = TokenSwapper(_swapper).swapExactInWithUniswap(
                _fromToken, _intermediateToken, _intermediatePool, _fromTokenAmount, _expectedIntermediateAmount
            );

            // intermediate token -> asset token
            _approveToken(_intermediateToken, address(_swapper));
            address _outToken = TokenSwapper(_swapper).getOutTokenForUniPool(_intermediateToken, _assetPool);
            uint256 _outExpected = TokenSwapper(_swapper).applySlippageRelax(
                _convertAmount(_intermediateToken, _intermediateAmount, _outToken)
            );
            return TokenSwapper(_swapper).swapExactInWithUniswap(
                _intermediateToken, _outToken, _assetPool, _intermediateAmount, _outExpected
            );
        }
    }
}
