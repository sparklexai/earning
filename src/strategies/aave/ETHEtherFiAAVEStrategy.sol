// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BaseAAVEStrategy} from "./BaseAAVEStrategy.sol";
import {WETH} from "../../../interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IeETH} from "../../../interfaces/etherfi/IeETH.sol";
import {IWeETH} from "../../../interfaces/etherfi/IWeETH.sol";
import {ILiquidityPool} from "../../../interfaces/etherfi/ILiquidityPool.sol";
import {IWithdrawRequestNFT} from "../../../interfaces/etherfi/IWithdrawRequestNFT.sol";
import {IPool} from "../../../interfaces/aave/IPool.sol";
import {IAaveOracle} from "../../../interfaces/aave/IAaveOracle.sol";
import {DataTypes} from "../../../interfaces/aave/DataTypes.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Constants} from "../../utils/Constants.sol";

/**
 * @dev deposit into Ether.Fi and then supply in AAVE and looping borrow wETH to get leveraged position.
 */
contract ETHEtherFiAAVEStrategy is BaseAAVEStrategy, IERC721Receiver {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////
    uint8 constant MAX_ACTIVE_WITHDRAW = 30;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    ILiquidityPool etherfiLP = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
    IWithdrawRequestNFT etherfiWithdrawNFT = IWithdrawRequestNFT(0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c);
    IWeETH weETH = IWeETH(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
    IeETH eETH = IeETH(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
    address payable constant wETH = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ERC20 aWeETH = ERC20(0xBdfa7b7893081B35Fb54027489e2Bc7A38275129);
    ERC20 variableDebtWETH = ERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);
    address constant weETHPool = 0xDB74dfDD3BB46bE8Ce6C33dC9D82777BCFc3dEd5;

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    mapping(uint256 => uint256) public withdrawReqToSwapLoss;
    uint256[MAX_ACTIVE_WITHDRAW] withdrawRequestIDs;
    uint256 public activeWithdrawRequests;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event DepositToEtherFi(uint256 _asset, uint256 _mintedeETH, uint256 _mintedWeETH);
    event WithdrawRequestFromEtherFi(uint256 indexed _requestId, uint256 _amount);
    event WithdrawClaimFromEtherFi(uint256 indexed _requestId, uint256 _amount);
    event WithdrawRequestNeededForEtherFi(address indexed _user, uint256 _toWithdraw, uint256 _share, uint256 _residue);
    event RequestWithdrawNFTReceived(uint256 indexed _requestId);

    constructor(address vault)
        BaseAAVEStrategy(ERC20(wETH), vault, ERC20(address(weETH)), ERC20(wETH), aWeETH, ETH_CATEGORY_AAVE)
    {
        // ether.fi related approvals
        ERC20(address(eETH)).approve(address(weETH), type(uint256).max);
        ERC20(address(eETH)).approve(address(etherfiLP), type(uint256).max);
        ERC20(address(weETH)).approve(address(weETH), type(uint256).max);

        // swap related approvals
        ERC20(address(weETH)).approve(address(curveRouter), type(uint256).max);
    }

    ///////////////////////////////
    // earn with ether.fi
    ///////////////////////////////

    /**
     * @dev deposit into Ether.Fi by unwrapping wETH back to ETH then wrap eETH into weETH.
     */
    function _depositToEtherFi(uint256 _toDeposit) internal returns (uint256) {
        require(_toDeposit > 0, "0 asset!");
        require(_asset.balanceOf(address(this)) >= _toDeposit, "!too many deposit to EtherFi");

        WETH(wETH).withdraw(_toDeposit);

        uint256 _eETHBefore = eETH.balanceOf(address(this));
        etherfiLP.deposit{value: _toDeposit}();
        uint256 _eETHAfter = eETH.balanceOf(address(this));
        uint256 _mintedeETH = _eETHAfter - _eETHBefore;

        uint256 _WeETHBefore;
        uint256 _WeETHAfter;
        if (_mintedeETH > 0) {
            _WeETHBefore = _supplyToken.balanceOf(address(this));
            weETH.wrap(_mintedeETH);
            _WeETHAfter = _supplyToken.balanceOf(address(this));
        }

        uint256 _mintedSupply = _WeETHAfter - _WeETHBefore;
        emit DepositToEtherFi(_toDeposit, _mintedeETH, _mintedSupply);
        return _mintedSupply;
    }

    /**
     * @dev make a withdraw request to ether.fi with given weETH amount and record any swap loss during flashloan to prepare this request.
     */
    function _requestWithdrawFromEtherFi(uint256 _toWithdrawWeETH, uint256 _swapLoss) internal returns (uint256) {
        require(activeWithdrawRequests < MAX_ACTIVE_WITHDRAW, "too many withdraw requests for EtherFi!");

        _toWithdrawWeETH = _capAmountByBalance(ERC20(address(weETH)), _toWithdrawWeETH, false);
        uint256 _toWithdraw = weETH.unwrap(_toWithdrawWeETH);

        uint256 _reqID = etherfiLP.requestWithdraw(address(this), _toWithdraw);
        emit WithdrawRequestFromEtherFi(_reqID, _toWithdraw);

        IWithdrawRequestNFT.WithdrawRequest memory _request = etherfiWithdrawNFT.getRequest(_reqID);
        require(_request.isValid, "withdraw invalid!");
        require(etherfiWithdrawNFT.ownerOf(_reqID) == address(this), "withdraw NFT owner!");

        _updateWithdrawReqAccounting(_reqID, _swapLoss, false);
        return _reqID;
    }

    function claimWithdrawFromEtherFi(uint256 _reqID) external onlyStrategist returns (uint256) {
        require(etherfiWithdrawNFT.isFinalized(_reqID), "withdraw not finish in EtherFi!");

        uint256 _wETHBefore = _asset.balanceOf(address(this));

        _updateWithdrawReqAccounting(_reqID, 0, true);
        etherfiWithdrawNFT.claimWithdraw(_reqID);

        uint256 _wETHAfter = _asset.balanceOf(address(this));
        uint256 _claimed = _wETHAfter - _wETHBefore;

        emit WithdrawClaimFromEtherFi(_reqID, _claimed);

        _returnAssetToVault(_claimed);
        return _claimed;
    }

    ///////////////////////////////
    // core external methods
    ///////////////////////////////

    function redeem(uint256 _supplyAmount) external override onlyStrategist returns (uint256) {
        uint256 _margin = getAvailableBorrowAmount();

        if (_margin == 0) {
            return _margin;
        } else {
            _margin = _convertBorrowToSupply(_margin);
        }

        _supplyAmount = _supplyAmount > _margin ? _margin : _supplyAmount;
        _supplyAmount = _withdrawCollateralFromAAVE(_supplyAmount);
        uint256 _reqWithdraw = _capAmountByBalance(_supplyToken, _supplyAmount, false);
        _requestWithdrawFromEtherFi(_reqWithdraw, 0);
        return _reqWithdraw;
    }

    function _leveragePosition(uint256 _assetAmount, uint256 _borrowAmount) internal override {
        require(_borrowAmount > 0, "!invalid borrow amount to leverage in AAVE");

        _prepareSupplyFromAsset(_assetAmount);

        (uint256 _netSupply,,) = getNetSupplyAndDebt(false);
        uint256 _initSupply = _supplyToken.balanceOf(address(this)) + _netSupply;
        require(_initSupply > 0, "!zero supply amount to leverage in AAVE");

        uint256 _safeLeveraged = getSafeLeveragedSupply(_initSupply);
        uint256 _toBorrow = _safeLeveraged == _initSupply ? 0 : _convertSupplyToBorrow(_safeLeveraged - _initSupply);
        _toBorrow = _toBorrow > _borrowAmount ? _borrowAmount : _toBorrow;

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory interestRateModes = new uint256[](1);

        assets[0] = address(_borrowToken);
        amounts[0] = _toBorrow;
        interestRateModes[0] = 0;

        aavePool.flashLoan(address(this), assets, amounts, interestRateModes, address(this), abi.encode(true, 0), 0);
    }

    /**
     * @dev by default, this method will try to maximize the leverage
     */
    function allocate(uint256 amount) external override onlyStrategist {
        uint256 _assetAmount = _prepareSupplyFromAsset(amount);
        if (_assetAmount == 0) {
            return;
        }

        (uint256 _netSupply,,) = getNetSupplyAndDebt(false);
        uint256 _initSupply = _supplyToken.balanceOf(address(this)) + _netSupply;
        require(_initSupply > 0, "zero supply to leverage in AAVE!");

        uint256 _safeLeveraged = getSafeLeveragedSupply(_initSupply);
        uint256 _toBorrow = _safeLeveraged == _initSupply ? 0 : _convertSupplyToBorrow(_safeLeveraged - _initSupply);

        if (_toBorrow > 0) {
            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            uint256[] memory interestRateModes = new uint256[](1);

            assets[0] = address(_borrowToken);
            amounts[0] = _toBorrow;

            //Don't open any debt here
            interestRateModes[0] = 0;

            aavePool.flashLoan(address(this), assets, amounts, interestRateModes, address(this), abi.encode(true, 0), 0);
        } else {
            _supplyToAAVE(_supplyToken.balanceOf(address(this)));
        }
        emit AllocateInvestment(msg.sender, _assetAmount);
    }

    function collect(uint256 amount) external override onlyStrategistOrVault {
        if (amount == 0) {
            return;
        }
        _collectAsset(amount);
        emit CollectInvestment(msg.sender, amount);
        _returnAssetToVault(amount);
    }

    function collectAll() external override onlyStrategistOrVault {
        uint256 _fullAmount = totalAssets();
        if (_fullAmount == 0) {
            return;
        }
        _collectAsset(_applySlippageMargin(_fullAmount));
        emit CollectInvestment(msg.sender, _fullAmount);
        _returnAssetToVault(_asset.balanceOf(address(this)));
    }

    function _collectAsset(uint256 _expectedAsset) internal {
        uint256 _residue = _asset.balanceOf(address(this));
        if (_residue >= _expectedAsset) {
            return;
        }

        uint256 _supplyResidue = _supplyToken.balanceOf(address(this));
        uint256 _supplyRequired = _convertAssetToSupply(_expectedAsset - _residue);
        (uint256 _netSupplyAsset, uint256 _debtAsset,) = getNetSupplyAndDebt(true);

        // simply create withdraw request within ether.fi if no need to interact with AAVE
        if (_supplyRequired <= _supplyResidue || _netSupplyAsset == 0) {
            _requestWithdrawFromEtherFi(_applySlippageMargin(_supplyRequired), 0);
            return;
        }

        // withdraw supply from AAVE if no debt taken, i.e., no leverage
        if (_debtAsset == 0) {
            _withdrawCollateralFromAAVE(_applySlippageMargin(_supplyRequired));
            _requestWithdrawFromEtherFi(_supplyToken.balanceOf(address(this)), 0);
            return;
        }

        _deleverageByFlashloan(_netSupplyAsset, _debtAsset, _expectedAsset);
    }

    function _deleverageByFlashloan(uint256 _netSupplyAsset, uint256 _debtAsset, uint256 _expectedAsset) internal {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory interestRateModes = new uint256[](1);

        assets[0] = address(_borrowToken);
        interestRateModes[0] = 0;

        if (_expectedAsset > 0 && _expectedAsset < _applyLeverageMargin(_netSupplyAsset)) {
            // deleverage a portion if possible
            amounts[0] = getMaxLeverage(_expectedAsset);
            aavePool.flashLoan(
                address(this), assets, amounts, interestRateModes, address(this), abi.encode(false, _expectedAsset), 0
            );
        } else {
            // deleverage everything
            amounts[0] = _applySlippageMargin(_debtAsset);
            aavePool.flashLoan(
                address(this), assets, amounts, interestRateModes, address(this), abi.encode(false, 0), 0
            );
        }
    }

    function _prepareAssetFromBorrow(uint256 _borrowAmount) internal override returns (uint256) {
        return _returnAssetToVault(_borrowAmount);
    }

    function _prepareSupplyFromAsset(uint256 _assetAmount) internal override returns (uint256) {
        uint256 amount = _capAllocationAmount(_assetAmount);
        if (amount > 0) {
            _asset.transferFrom(_vault, address(this), amount);
            amount = _depositToEtherFi(amount);
        }
        return amount;
    }

    function _convertAssetToSupply(uint256 _assetAmount) internal view override returns (uint256) {
        return weETH.getWeETHByeETH(_assetAmount);
    }

    function _convertSupplyToAsset(uint256 _supplyAmount) internal view override returns (uint256) {
        return weETH.getEETHByWeETH(_supplyAmount);
    }

    function _convertBorrowToSupply(uint256 _borrowAmount) internal view override returns (uint256) {
        return weETH.getWeETHByeETH(_borrowAmount);
    }

    function _convertSupplyToBorrow(uint256 _supplyAmount) internal view override returns (uint256) {
        return weETH.getEETHByWeETH(_supplyAmount);
    }

    /**
     * @dev return all pending withdraw request in EtherFi: [requestID, amountOfEEth, anyLossDuringRequest, fee]
     */
    function getAllWithdrawRequests() public view returns (uint256[][] memory) {
        if (activeWithdrawRequests == 0) {
            return (new uint256[][](0));
        }

        uint256[][] memory _allReqs = new uint256[][](activeWithdrawRequests);
        uint256 cnt;
        for (uint256 i = 0; i < MAX_ACTIVE_WITHDRAW; i++) {
            if (withdrawRequestIDs[i] != 0) {
                uint256[] memory _activeReq = new uint256[](4);
                _allReqs[cnt] = _activeReq;

                _activeReq[0] = withdrawRequestIDs[i];
                IWithdrawRequestNFT.WithdrawRequest memory _request = etherfiWithdrawNFT.getRequest(_activeReq[0]);
                _activeReq[1] = _request.amountOfEEth;
                _activeReq[2] = withdrawReqToSwapLoss[_activeReq[0]];
                _activeReq[3] = _request.feeGwei * Constants.ONE_GWEI;
                cnt = cnt + 1;
                if (cnt == activeWithdrawRequests) {
                    break;
                }
            }
        }
        return _allReqs;
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _updateWithdrawReqAccounting(uint256 _req, uint256 _swapLoss, bool _claim) internal {
        if (_claim) {
            activeWithdrawRequests = activeWithdrawRequests > 0 ? activeWithdrawRequests - 1 : 0;
            for (uint256 i = 0; i < MAX_ACTIVE_WITHDRAW; i++) {
                if (withdrawRequestIDs[i] == _req) {
                    delete withdrawReqToSwapLoss[_req];
                    withdrawRequestIDs[i] = 0;
                    break;
                }
            }
        } else {
            activeWithdrawRequests = activeWithdrawRequests + 1;
            for (uint256 i = 0; i < MAX_ACTIVE_WITHDRAW; i++) {
                if (withdrawRequestIDs[i] == 0) {
                    withdrawReqToSwapLoss[_req] = _swapLoss;
                    withdrawRequestIDs[i] = _req;
                    break;
                }
            }
        }
    }

    ///////////////////////////////
    // strategy customized methods
    ///////////////////////////////
    function totalAssets() public view override returns (uint256) {
        uint256 _residue = _asset.balanceOf(address(this));

        // Check how much we can claim from ether.fi
        uint256 _weETHBalance = ERC20(address(weETH)).balanceOf(address(this));
        uint256 _claimable = etherfiLP.getTotalEtherClaimOf(address(this)) + weETH.getEETHByWeETH(_weETHBalance);
        uint256 _toWithdraw = assetsInCollection();

        // Check supply in AAVE if any
        (uint256 _netSupply,,) = getNetSupplyAndDebt(true);

        return _residue + _claimable + _toWithdraw + _netSupply;
    }

    function assetsInCollection() public view override returns (uint256) {
        uint256 _toWithdraw;
        if (activeWithdrawRequests > 0) {
            uint256[][] memory _allWithdrawReqs = getAllWithdrawRequests();
            for (uint256 i = 0; i < activeWithdrawRequests; i++) {
                uint256[] memory _reqData = _allWithdrawReqs[i];
                _toWithdraw = _toWithdraw + _reqData[1] - _reqData[3];
            }
        }
        return _toWithdraw;
    }

    ///////////////////////////////
    // handle native Ether payment and NFT
    ///////////////////////////////
    receive() external payable {
        if (msg.sender == address(etherfiLP)) {
            WETH(wETH).deposit{value: msg.value}();
        }
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        require(msg.sender == address(etherfiWithdrawNFT), "wrong NFT received!");
        emit RequestWithdrawNFTReceived(tokenId);
        return this.onERC721Received.selector;
    }

    ///////////////////////////////
    // handle flashloan callback from AAVE
    // https://aave.com/docs/developers/flash-loans
    ///////////////////////////////
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        address asset = assets[0];
        uint256 amount = amounts[0];
        uint256 premium = premiums[0];

        require(msg.sender == address(aavePool), "wrong flashloan caller!");
        require(initiator == address(this), "wrong flashloan initiator!");
        require(asset == address(_borrowToken), "wrong flashloan asset!");
        require(amount > premium, "invalid flashloan premium!");

        require(_borrowToken.balanceOf(address(this)) >= amount, "wrong flashloan amount!");

        (bool _lev, uint256 _expected) = abi.decode(params, (bool, uint256));
        uint256 _toRepay = amount + premium;

        if (_lev) {
            // Leverage: use flashloan to deposit borrowed wETH into ether.fi and then supply weETH to AAVE
            uint256 _supplyAmount =
                _depositToEtherFi(_capAmountByBalance(_asset, amount, false)) + _supplyToken.balanceOf(address(this));

            _supplyToAAVE(_supplyAmount);
            _borrowFromAAVE(_toRepay);

            uint256 _borrowResidue = _borrowToken.balanceOf(address(this));
            require(_borrowResidue >= _toRepay, "can't repay flashloan during leverage!");
            _borrowResidue = _borrowResidue > _toRepay ? (_borrowResidue - _toRepay) : 0;

            // return any remaining to vault
            if (_borrowResidue > 0) {
                _prepareAssetFromBorrow(_borrowResidue);
            }
        } else {
            // Deleverage: use flashloan to clear debt in AAVE and then withdraw weETH from AAVE to swap for wETH
            // and lastly repay wETH flashloan
            if (_expected == 0) {
                // redeem everything
                _repayDebtToAAVE(type(uint256).max);
                _withdrawCollateralFromAAVE(type(uint256).max);
            } else {
                // redeem some collateral
                _repayDebtToAAVE(amount);
                _withdrawCollateralFromAAVE(_convertBorrowToSupply(_expected + _toRepay));
            }

            // NOTE!!! this flow might incur some slippage loss, please use at careful discretion
            uint256 _expectedIn = _queryXWithYInCurve(address(_supplyToken), address(_borrowToken), weETHPool, _toRepay);
            uint256 _cappedIn = _capAmountByBalance(_supplyToken, _expectedIn, true);
            uint256 _actualOut =
                _swapInCurveTwoTokenPool(address(_supplyToken), address(_borrowToken), weETHPool, _cappedIn, _toRepay);

            uint256 _bestInTheory = _convertSupplyToAsset(_cappedIn);
            _requestWithdrawFromEtherFi(
                _supplyToken.balanceOf(address(this)), (_bestInTheory > _actualOut ? _bestInTheory - _actualOut : 0)
            );

            require(_borrowToken.balanceOf(address(this)) >= _toRepay, "can't repay flashloan!");
        }

        return true;
    }
}
