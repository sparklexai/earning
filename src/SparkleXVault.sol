// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Constants} from "./utils/Constants.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract SparkleXVault is ERC4626, Ownable {
    using Math for uint256;

    ///////////////////////////////
    // constants
    ///////////////////////////////
    uint8 constant MAX_ACTIVE_STRATEGY = 8;
    uint256 constant MIN_SHARE = 10 ** 6;

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    uint256 public EARN_RATIO_BPS = 9900;
    uint256 public WITHDRAW_FEE_BPS = 10;
    uint256 public MANAGEMENT_FEE_BPS = 200;
    uint256 public strategiesAllocationSum;
    ManagementFeeRecord public mgmtFee;

    struct ManagementFeeRecord {
        uint256 feesAccumulated;
        uint256 lastUpdateTotalAssets;
        uint256 lastUpdateTimestamp;
    }

    mapping(address => uint256) public strategyAllocations;
    address[MAX_ACTIVE_STRATEGY] public allStrategies;
    address public _redemptionClaimer;
    address public _feeRecipient;

    /**
     * @dev active strategy number
     */
    uint8 public activeStrategies;

    /**
     * @dev mapping from strategy address to recording info
     */
    mapping(address => uint256) public userRedemptionRequestShares;
    mapping(address => uint256) public userRedemptionRequestAssets;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event StrategyAdded(address indexed _strategy, uint256 _allocation);
    event StrategyRemoved(address indexed _strategy);
    event RedemptionRequested(address indexed _user, uint256 _share, uint256 _asset);
    event RedemptionRequestClaimed(address indexed _user, uint256 _share, uint256 _asset);
    event AssetAdded(address indexed _depositor, address indexed _referralCode, uint256 _amount);
    event RedemptionClaimerChanged(address indexed _old, address indexed _new);
    event FeeRecipientChanged(address indexed _old, address indexed _new);
    event WithdrawFeeCharged(address indexed _withdrawer, address indexed _recipient, uint256 _fee);
    event ManagementFeeUpdated(uint256 _addedFee, uint256 _newTotalAssets, uint256 _newTimestamp, uint256 _feeBps);
    event ManagementFeeClaimed(address indexed _recipient, uint256 _fee);
    event EarnRatioChanged(address indexed _caller, uint256 _new);
    event WithdrawFeeChanged(address indexed _caller, uint256 _new);
    event ManagementFeeChanged(address indexed _caller, uint256 _new);

    constructor(ERC20 _asset, string memory name_, string memory symbol_)
        ERC4626(_asset)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        if (address(_asset) == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        _redemptionClaimer = msg.sender;
        _feeRecipient = msg.sender;
    }

    /**
     * @dev allow only called by redemption claimer.
     */
    modifier onlyRedemptionClaimer() {
        if (msg.sender != _redemptionClaimer) {
            revert Constants.ONLY_FOR_CLAIMER();
        }
        _;
    }

    /**
     * @dev allow only called by owner or claimer.
     */
    modifier onlyRedemptionClaimerOrOwner() {
        if (msg.sender != _redemptionClaimer && msg.sender != owner()) {
            revert Constants.ONLY_FOR_CLAIMER_OR_OWNER();
        }
        _;
    }

    function getAllocationAvailable() public view returns (uint256) {
        return ERC20(asset()).balanceOf(address(this)) * EARN_RATIO_BPS / Constants.TOTAL_BPS;
    }

    function getAllocationAvailableForStrategy(address _strategyAddr) public view returns (uint256) {
        uint256 _strategyAlloc = strategyAllocations[_strategyAddr];
        if (_strategyAlloc == 0) {
            return 0;
        }
        return getAllocationAvailable() * _strategyAlloc / strategiesAllocationSum;
    }

    ///////////////////////////////
    // core external methods
    ///////////////////////////////

    function getRedemptionClaimer() external view returns (address) {
        return _redemptionClaimer;
    }

    function getFeeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    function setRedemptionClaimer(address _newClaimer) external onlyOwner {
        if (_newClaimer == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        emit RedemptionClaimerChanged(_redemptionClaimer, _newClaimer);
        _redemptionClaimer = _newClaimer;
    }

    function setFeeRecipient(address _newRecipient) external onlyOwner {
        if (_newRecipient == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        emit FeeRecipientChanged(_feeRecipient, _newRecipient);
        _feeRecipient = _newRecipient;
    }

    function setEarnRatio(uint256 _ratio) external onlyOwner {
        if (_ratio > Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        EARN_RATIO_BPS = _ratio;
        emit EarnRatioChanged(msg.sender, _ratio);
    }

    function setWithdrawFeeRatio(uint256 _ratio) external onlyOwner {
        if (_ratio >= Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        WITHDRAW_FEE_BPS = _ratio;
        emit WithdrawFeeChanged(msg.sender, _ratio);
    }

    function setManagementFeeRatio(uint256 _ratio) external onlyOwner {
        if (_ratio >= Constants.TOTAL_BPS) {
            revert Constants.INVALID_BPS_TO_SET();
        }
        _accumulateManagementFeeInternal();
        MANAGEMENT_FEE_BPS = _ratio;
        emit ManagementFeeChanged(msg.sender, _ratio);
    }

    function addStrategy(address _strategyAddr, uint256 _allocation) external onlyOwner {
        if (
            _strategyAddr == Constants.ZRO_ADDR || IStrategy(_strategyAddr).asset() != asset()
                || IStrategy(_strategyAddr).vault() != address(this) || strategyAllocations[_strategyAddr] > 0
                || _allocation == 0
        ) {
            revert Constants.WRONG_STRATEGY_TO_ADD();
        }

        if (activeStrategies >= MAX_ACTIVE_STRATEGY) {
            revert Constants.TOO_MANY_STRATEGIES();
        }

        strategiesAllocationSum = strategiesAllocationSum + _allocation;

        strategyAllocations[_strategyAddr] = _allocation;
        activeStrategies = activeStrategies + 1;

        for (uint256 i = 0; i < MAX_ACTIVE_STRATEGY; i++) {
            if (allStrategies[i] == Constants.ZRO_ADDR) {
                allStrategies[i] = _strategyAddr;
                break;
            }
        }
        ERC20(asset()).approve(_strategyAddr, type(uint256).max);
        emit StrategyAdded(_strategyAddr, _allocation);
    }

    function removeStrategy(address _strategyAddr) external onlyOwner {
        uint256 _strategyAlloc = strategyAllocations[_strategyAddr];
        if (_strategyAlloc == 0 || IStrategy(_strategyAddr).vault() != address(this)) {
            revert Constants.WRONG_STRATEGY_TO_REMOVE();
        }

        if (IStrategy(_strategyAddr).assetsInCollection() > 0) {
            revert Constants.STRATEGY_COLLECTION_IN_PROCESS();
        }
        IStrategy(_strategyAddr).collectAll();

        strategiesAllocationSum = strategiesAllocationSum - _strategyAlloc;

        delete strategyAllocations[_strategyAddr];
        activeStrategies = activeStrategies - 1;

        for (uint256 i = 0; i < MAX_ACTIVE_STRATEGY; i++) {
            if (allStrategies[i] == _strategyAddr) {
                allStrategies[i] = Constants.ZRO_ADDR;
                break;
            }
        }
        ERC20(asset()).approve(_strategyAddr, 0);
        emit StrategyRemoved(_strategyAddr);
    }

    function accumulateManagementFee() external onlyRedemptionClaimerOrOwner {
        _accumulateManagementFeeInternal();
    }

    function _accumulateManagementFeeInternal() internal {
        ManagementFeeRecord storage _feeRecord = mgmtFee;
        uint256 currentTime = block.timestamp;
        uint256 currentTotalAssets = totalAssets();
        (uint256 newFee,) = previewManagementFeeAccumulated(currentTotalAssets, currentTime);

        if (newFee > 0) {
            _feeRecord.feesAccumulated += newFee;
        }

        _feeRecord.lastUpdateTotalAssets = currentTotalAssets;
        _feeRecord.lastUpdateTimestamp = currentTime;

        emit ManagementFeeUpdated(newFee, currentTotalAssets, currentTime, MANAGEMENT_FEE_BPS);
    }

    function previewManagementFeeAccumulated(uint256 _currentTotalAssets, uint256 _currentTime)
        public
        view
        returns (uint256, uint256)
    {
        ManagementFeeRecord memory _feeRecord = mgmtFee;

        uint256 _recordedTime = _feeRecord.lastUpdateTimestamp > 0 ? _feeRecord.lastUpdateTimestamp : _currentTime;
        uint256 _timeElapsed = _currentTime > _recordedTime ? (_currentTime - _recordedTime) : 0;
        uint256 newFee;

        if (_timeElapsed > 0) {
            uint256 recordedAssets = _feeRecord.lastUpdateTotalAssets;
            uint256 assetsToCharge =
                (_currentTotalAssets > recordedAssets && recordedAssets > 0) ? recordedAssets : _currentTotalAssets;
            newFee = (assetsToCharge * MANAGEMENT_FEE_BPS * _timeElapsed) / (Constants.ONE_YEAR * Constants.TOTAL_BPS);
        }
        return (newFee, _timeElapsed);
    }

    function claimManagementFee() external onlyRedemptionClaimerOrOwner {
        ManagementFeeRecord storage _feeRecord = mgmtFee;
        uint256 _feeToClaim = _feeRecord.feesAccumulated;
        if (_feeToClaim == 0) {
            return;
        }

        _feeRecord.feesAccumulated = 0;
        SafeERC20.safeTransferFrom(ERC20(asset()), address(this), _feeRecipient, _feeToClaim);

        emit ManagementFeeClaimed(_feeRecipient, _feeToClaim);
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _checkAssetResidue(uint256 _toWithdraw) internal view returns (uint256 _residue, bool _notEnough) {
        _residue = ERC20(asset()).balanceOf(address(this));
        _notEnough = _toWithdraw > _residue;
    }

    ///////////////////////////////
    // erc4626 customized methods
    ///////////////////////////////
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (shares == 0) {
            revert Constants.ZERO_SHARE_TO_MINT();
        }

        SafeERC20.safeTransferFrom(ERC20(asset()), caller, address(this), assets);

        if (totalSupply() == 0) {
            if (shares <= MIN_SHARE) {
                revert Constants.TOO_SMALL_FIRST_SHARE();
            }
            _mint(address(this), MIN_SHARE);
            shares = shares - MIN_SHARE;
            _accumulateManagementFeeInternal();
        }

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 _residue = ERC20(asset()).balanceOf(address(this));
        uint256 _total;
        for (uint256 i = 0; i < MAX_ACTIVE_STRATEGY; i++) {
            if (allStrategies[i] != Constants.ZRO_ADDR) {
                _total = _total + IStrategy(allStrategies[i]).totalAssets();
            }
        }
        return _residue + _total;
    }

    function depositWithReferral(uint256 assets, address receiver, address referralCode) external returns (uint256) {
        uint256 shares = deposit(assets, receiver);
        emit AssetAdded(msg.sender, referralCode, assets);
        return shares;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        assets = _chargeWithdrawFee(assets, owner);
        SafeERC20.safeTransfer(ERC20(asset()), receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _chargeWithdrawFee(uint256 _assetAmount, address _shareOwner) internal returns (uint256) {
        uint256 _adjustedAssetAmount = _assetAmount;
        if (WITHDRAW_FEE_BPS > 0) {
            uint256 _fee = _assetAmount * WITHDRAW_FEE_BPS / Constants.TOTAL_BPS;
            _adjustedAssetAmount = _assetAmount - _fee;
            if (_fee > 0) {
                SafeERC20.safeTransfer(ERC20(asset()), _feeRecipient, _fee);
                emit WithdrawFeeCharged(_shareOwner, _feeRecipient, _fee);
            }
        }
        return _adjustedAssetAmount;
    }

    /**
     * @dev user should use this method to request redemption.
     */
    function requestRedemption(uint256 shares) external returns (uint256) {
        uint256 _shareBalance = balanceOf(msg.sender);
        if (shares > _shareBalance) {
            shares = _shareBalance;
        }
        if (shares == 0) {
            return shares;
        }

        uint256 _asset = previewRedeem(shares);
        if (_asset == 0) {
            revert Constants.ZERO_ASSET_TO_USER();
        }

        (, bool _notEnough) = _checkAssetResidue(_asset);
        if (!_notEnough) {
            // direct redemption immediately
            uint256 _before = ERC20(asset()).balanceOf(msg.sender);
            redeem(shares, msg.sender, msg.sender);
            return ERC20(asset()).balanceOf(msg.sender) - _before;
        } else {
            // need to request withdraw from strategies by monitoring bot
            if (userRedemptionRequestShares[msg.sender] > 0 || userRedemptionRequestAssets[msg.sender] > 0) {
                revert Constants.USER_REDEMPTION_NOT_CLAIMED();
            }
            _transfer(msg.sender, address(this), shares);
            userRedemptionRequestShares[msg.sender] = shares;
            userRedemptionRequestAssets[msg.sender] = _asset;
            emit RedemptionRequested(msg.sender, shares, _asset);
            return _asset;
        }
    }

    /**
     * @dev user should use this method to claim redemption if any.
     */
    function claimRedemptionRequest() external returns (uint256) {
        return _claimRedemptionRequestFor(msg.sender);
    }

    function _claimRedemptionRequestFor(address _user) internal returns (uint256) {
        uint256 _share = userRedemptionRequestShares[_user];
        if (_share == 0) {
            return _share;
        }

        uint256 _asset = userRedemptionRequestAssets[_user];
        uint256 _currentWorth = previewRedeem(_share);
        uint256 _toUsr = _asset > _currentWorth ? _currentWorth : _asset;
        if (_toUsr == 0) {
            revert Constants.ZERO_ASSET_TO_USER();
        }

        (uint256 _residue,) = _checkAssetResidue(_toUsr);
        if (_toUsr > _residue) {
            revert Constants.LESS_REDEMPTION_TO_USER();
        }

        delete userRedemptionRequestShares[_user];
        delete userRedemptionRequestAssets[_user];

        _burn(address(this), _share);
        emit RedemptionRequestClaimed(_user, _share, _toUsr);
        emit Withdraw(msg.sender, _user, _user, _toUsr, _share);

        _toUsr = _chargeWithdrawFee(_toUsr, _user);
        SafeERC20.safeTransfer(ERC20(asset()), _user, _toUsr);
        return _toUsr;
    }

    function batchClaimRedemptionRequestsFor(address[] calldata _users)
        external
        onlyRedemptionClaimer
        returns (uint256)
    {
        uint256 _total;
        uint256 _usersLen = _users.length;
        for (uint256 i = 0; i < _usersLen; i++) {
            _total = _total + _claimRedemptionRequestFor(_users[i]);
        }
        return _total;
    }
}
