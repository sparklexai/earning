// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WETH} from "../../../interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IeETH} from "../../../interfaces/etherfi/IeETH.sol";
import {IWeETH} from "../../../interfaces/etherfi/IWeETH.sol";
import {ILiquidityPool} from "../../../interfaces/etherfi/ILiquidityPool.sol";
import {IWithdrawRequestNFT} from "../../../interfaces/etherfi/IWithdrawRequestNFT.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Constants} from "../../utils/Constants.sol";

contract EtherFiHelper is IERC721Receiver {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////
    uint8 public constant MAX_ACTIVE_WITHDRAW = 30;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////
    ILiquidityPool etherfiLP = ILiquidityPool(0x308861A430be4cce5502d0A12724771Fc6DaF216);
    IWithdrawRequestNFT etherfiWithdrawNFT = IWithdrawRequestNFT(0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c);
    IWeETH weETH = IWeETH(0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee);
    IeETH eETH = IeETH(0x35fA164735182de50811E8e2E824cFb9B6118ac2);
    address payable constant wETH = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    mapping(uint256 => uint256) public withdrawReqToSwapLoss;
    uint256[MAX_ACTIVE_WITHDRAW] public withdrawRequestIDs;
    mapping(uint256 => address) public withdrawRequsters;
    mapping(address => uint256) public withdrawCountsForRequster;
    uint256 public activeWithdrawRequests;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event DepositToEtherFi(address indexed _requster, uint256 _asset, uint256 _mintedeETH, uint256 _mintedWeETH);
    event WithdrawRequestFromEtherFi(address indexed _requster, uint256 indexed _requestId, uint256 _amount);
    event WithdrawClaimFromEtherFi(address indexed _requster, uint256 indexed _requestId, uint256 _amount);
    event ReceiveFromEtherFi(uint256 _amount);
    event RequestWithdrawNFTReceived(uint256 indexed _requestId);

    constructor() {
        // ether.fi related approvals
        ERC20(address(eETH)).approve(address(weETH), type(uint256).max);
        ERC20(address(eETH)).approve(address(etherfiLP), type(uint256).max);
        ERC20(address(weETH)).approve(address(weETH), type(uint256).max);
    }

    ///////////////////////////////
    // earn with ether.fi
    ///////////////////////////////

    /**
     * @dev deposit into Ether.Fi by unwrapping wETH back to ETH then wrap eETH into weETH.
     */
    function depositToEtherFi(uint256 _toDeposit) external returns (uint256) {
        require(_toDeposit > 0, "0 to deposit in etherfi!");

        SafeERC20.safeTransferFrom(ERC20(wETH), msg.sender, address(this), _toDeposit);
        require(ERC20(wETH).balanceOf(address(this)) >= _toDeposit, "!not enough deposit to EtherFi");

        WETH(wETH).withdraw(_toDeposit);

        uint256 _eETHBefore = eETH.balanceOf(address(this));
        etherfiLP.deposit{value: _toDeposit}();
        uint256 _eETHAfter = eETH.balanceOf(address(this));
        uint256 _mintedeETH = _eETHAfter - _eETHBefore;

        uint256 _WeETHBefore;
        uint256 _WeETHAfter;
        if (_mintedeETH > 0) {
            _WeETHBefore = ERC20(address(weETH)).balanceOf(address(this));
            weETH.wrap(_mintedeETH);
            _WeETHAfter = ERC20(address(weETH)).balanceOf(address(this));
        }

        uint256 _mintedSupply = _WeETHAfter - _WeETHBefore;
        emit DepositToEtherFi(msg.sender, _toDeposit, _mintedeETH, _mintedSupply);
        SafeERC20.safeTransfer(ERC20(address(weETH)), msg.sender, _mintedSupply);
        return _mintedSupply;
    }

    /**
     * @dev make a withdraw request to ether.fi with given weETH amount and record any swap loss during flashloan to prepare this request.
     */
    function requestWithdrawFromEtherFi(uint256 _toWithdrawWeETH, uint256 _swapLoss) external returns (uint256) {
        if (activeWithdrawRequests >= MAX_ACTIVE_WITHDRAW) {
            revert Constants.TOO_MANY_WITHDRAW_FOR_ETHERFI();
        }

        SafeERC20.safeTransferFrom(ERC20(address(weETH)), msg.sender, address(this), _toWithdrawWeETH);
        uint256 _toWithdraw = weETH.unwrap(_toWithdrawWeETH);

        uint256 _reqID = etherfiLP.requestWithdraw(address(this), _toWithdraw);
        emit WithdrawRequestFromEtherFi(msg.sender, _reqID, _toWithdraw);

        IWithdrawRequestNFT.WithdrawRequest memory _request = etherfiWithdrawNFT.getRequest(_reqID);
        require(_request.isValid, "withdraw invalid!");
        require(etherfiWithdrawNFT.ownerOf(_reqID) == address(this), "withdraw NFT owner!");

        _updateWithdrawReqAccounting(msg.sender, _reqID, _swapLoss, false);
        return _reqID;
    }

    function claimWithdrawFromEtherFi(uint256 _reqID) external returns (uint256) {
        require(etherfiWithdrawNFT.isFinalized(_reqID), "withdraw not finish in EtherFi!");
        address _requester = withdrawRequsters[_reqID];

        uint256 _wETHBefore = ERC20(wETH).balanceOf(address(this));
        _updateWithdrawReqAccounting(_requester, _reqID, 0, true);
        etherfiWithdrawNFT.claimWithdraw(_reqID);

        uint256 _wETHAfter = ERC20(wETH).balanceOf(address(this));
        uint256 _claimed = _wETHAfter - _wETHBefore;

        emit WithdrawClaimFromEtherFi(_requester, _reqID, _claimed);

        SafeERC20.safeTransfer(ERC20(wETH), _requester, _claimed);
        return _claimed;
    }

    function _updateWithdrawReqAccounting(address _requester, uint256 _req, uint256 _swapLoss, bool _claim) internal {
        uint256 _count = withdrawCountsForRequster[_requester];
        if (_claim) {
            require(
                withdrawRequsters[_req] != Constants.ZRO_ADDR && _requester == msg.sender,
                "!invalid requester for withdraw claim"
            );
            activeWithdrawRequests = activeWithdrawRequests > 0 ? activeWithdrawRequests - 1 : 0;
            for (uint256 i = 0; i < MAX_ACTIVE_WITHDRAW; i++) {
                if (withdrawRequestIDs[i] == _req) {
                    delete withdrawReqToSwapLoss[_req];
                    delete withdrawRequsters[_req];
                    withdrawRequestIDs[i] = 0;
                    withdrawCountsForRequster[_requester] = _count - 1;
                    break;
                }
            }
        } else {
            activeWithdrawRequests = activeWithdrawRequests + 1;
            for (uint256 i = 0; i < MAX_ACTIVE_WITHDRAW; i++) {
                if (withdrawRequestIDs[i] == 0) {
                    withdrawReqToSwapLoss[_req] = _swapLoss;
                    withdrawRequsters[_req] = _requester;
                    withdrawRequestIDs[i] = _req;
                    withdrawCountsForRequster[_requester] = _count + 1;
                    break;
                }
            }
        }
    }

    /**
     * @dev return all pending withdraw request in EtherFi for given requester: [requestID, amountOfEEth, anyLossDuringRequest, fee]
     */
    function getAllWithdrawRequests(address _requester) public view returns (uint256[][] memory) {
        uint256 _count = withdrawCountsForRequster[_requester];
        if (_count == 0 || activeWithdrawRequests == 0) {
            return (new uint256[][](0));
        }

        uint256[][] memory _allReqs = new uint256[][](_count);
        uint256 cnt;
        for (uint256 i = 0; i < MAX_ACTIVE_WITHDRAW; i++) {
            uint256 _reqId = withdrawRequestIDs[i];
            if (_reqId != 0 && withdrawRequsters[_reqId] == _requester) {
                uint256[] memory _activeReq = new uint256[](4);
                _allReqs[cnt] = _activeReq;

                _activeReq[0] = _reqId;
                IWithdrawRequestNFT.WithdrawRequest memory _request = etherfiWithdrawNFT.getRequest(_activeReq[0]);
                _activeReq[1] = _request.amountOfEEth;
                _activeReq[2] = withdrawReqToSwapLoss[_activeReq[0]];
                _activeReq[3] = _request.feeGwei * Constants.ONE_GWEI;
                cnt = cnt + 1;
                if (cnt == _count) {
                    break;
                }
            }
        }
        return _allReqs;
    }

    /**
     * @dev return accumulated pending withdraw value in EtherFi for given requester
     */
    function getAllPendingValue(address _requester) external view returns (uint256) {
        uint256 _toWithdraw;
        uint256[][] memory _allWithdrawReqs = getAllWithdrawRequests(_requester);
        uint256 _len = _allWithdrawReqs.length;
        if (_len > 0) {
            for (uint256 i = 0; i < _len; i++) {
                uint256[] memory _reqData = _allWithdrawReqs[i];
                _toWithdraw = _toWithdraw + _reqData[1] - _reqData[3];
            }
        }
        return _toWithdraw;
    }

    ///////////////////////////////
    // handle native Ether payment and withdrawal NFT
    ///////////////////////////////
    receive() external payable {
        if (msg.sender == address(etherfiLP)) {
            WETH(wETH).deposit{value: msg.value}();
            emit ReceiveFromEtherFi(msg.value);
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
}
