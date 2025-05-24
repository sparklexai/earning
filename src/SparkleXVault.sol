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
    uint256 EARN_RATIO_BPS = 9900;
    uint256 strategiesAllocationSum;

    mapping(address => uint256) public strategyAllocations;
    address[MAX_ACTIVE_STRATEGY] allStrategies;
    address _redemptionClaimer;

    /**
     * @dev active strategy number
     */
    uint256 public activeStrategies;

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

    constructor(ERC20 _asset, string memory name_, string memory symbol_)
        ERC4626(_asset)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        require(address(_asset) != Constants.ZRO_ADDR, "!invalid asset");
        _redemptionClaimer = msg.sender;
    }

    /**
     * @dev allow only called by redemption claimer.
     */
    modifier onlyRedemptionClaimer() {
        require(msg.sender == _redemptionClaimer, "!not redemption claimer");
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

    function setRedemptionClaimer(address _newClaimer) external onlyOwner {
        require(_newClaimer != Constants.ZRO_ADDR, "!invalid redemption claimer");
        _redemptionClaimer = _newClaimer;
    }

    function setEarnRatio(uint256 _ratio) external onlyOwner {
        require(_ratio >= 0 && _ratio <= Constants.TOTAL_BPS, "invalid earn ratio!");
        EARN_RATIO_BPS = _ratio;
    }

    function addStrategy(address _strategyAddr, uint256 _allocation) external onlyOwner {
        require(
            _strategyAddr != Constants.ZRO_ADDR && IStrategy(_strategyAddr).asset() == asset()
                && IStrategy(_strategyAddr).vault() == address(this),
            "!invalid strategy to add"
        );
        require(activeStrategies < MAX_ACTIVE_STRATEGY, "!too many strategies");
        require(_allocation > 0, "!invalid startegy allocation");

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
        require(_strategyAlloc > 0 && IStrategy(_strategyAddr).vault() == address(this), "!invalid strategy to remove");

        require(IStrategy(_strategyAddr).assetsInCollection() == 0, "!pending collection still in strategy");
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
        require(shares > 0, "!deposit mint zero share");

        SafeERC20.safeTransferFrom(ERC20(asset()), caller, address(this), assets);

        if (totalSupply() == 0) {
            require(shares > MIN_SHARE, "!too small first share");
            _mint(address(this), MIN_SHARE);
            shares = shares - MIN_SHARE;
        }

        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 _residue = ERC20(asset()).balanceOf(address(this));
        uint256 _allocation;
        for (uint256 i = 0; i < MAX_ACTIVE_STRATEGY; i++) {
            if (allStrategies[i] != Constants.ZRO_ADDR) {
                _allocation = _allocation + IStrategy(allStrategies[i]).totalAssets();
            } else {
                break;
            }
        }
        return _residue + _allocation;
    }

    function depositWithReferral(uint256 assets, address receiver, address referralCode) external returns (uint256) {
        uint256 shares = deposit(assets, receiver);
        emit AssetAdded(msg.sender, referralCode, assets);
        return shares;
    }

    /**
     * @dev user should use this method to request redemption.
     */
    function requestRedemption(uint256 shares) external returns (uint256) {
        uint256 _shareBalance = balanceOf(msg.sender);
        if (shares > _shareBalance) {
            shares = _shareBalance;
        }

        uint256 _asset = previewRedeem(shares);
        require(shares > 0 && _asset > 0, "zero to redeem!");

        (uint256 _residue, bool _notEnough) = _checkAssetResidue(_asset);
        if (!_notEnough) {
            // direct redemption immediately
            return redeem(shares, msg.sender, msg.sender);
        } else {
            // need to request withdraw from strategies by monitoring bot
            require(
                userRedemptionRequestShares[msg.sender] == 0 && userRedemptionRequestAssets[msg.sender] == 0,
                "redemption exist!"
            );
            _burn(msg.sender, shares);
            _mint(address(this), shares);
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
        require(_share > 0, "redemption not exist!");

        uint256 _asset = userRedemptionRequestAssets[_user];
        uint256 _currentWorth = previewRedeem(_share);
        uint256 _toUsr = _asset > _currentWorth ? _currentWorth : _asset;
        require(_toUsr > 0, "zero asset to send!");

        (uint256 _residue,) = _checkAssetResidue(_toUsr);
        _toUsr = _toUsr > _residue ? _residue : _toUsr;

        delete userRedemptionRequestShares[_user];
        delete userRedemptionRequestAssets[_user];

        _burn(address(this), _share);
        emit RedemptionRequestClaimed(_user, _share, _toUsr);

        ERC20(asset()).transfer(_user, _toUsr);
        return _toUsr;
    }

    function batchClaimRedemptionRequestsFor(address[] calldata _users)
        public
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
