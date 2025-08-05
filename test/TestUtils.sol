// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH} from "../interfaces/IWETH.sol";
import {SparkleXVault} from "../src/SparkleXVault.sol";
import {Constants} from "../src/utils/Constants.sol";
import {TokenSwapper} from "../src/utils/TokenSwapper.sol";
import {DummyDEXRouter} from "./mock/DummyDEXRouter.sol";
import {Create3} from "./Create3.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {AAVEHelper} from "../src/strategies/aave/AAVEHelper.sol";

contract TestUtils is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    address payable wETH = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    bytes32 internal nextUser = keccak256(abi.encodePacked("user address"));
    uint256 constant wETHVal = 10000 ether;
    uint256 constant COMP_TOLERANCE = 10000;
    uint256 constant BIGGER_TOLERANCE = 3 * 1e16;
    uint256 constant MIN_SHARE = 10 ** 6;
    uint256 constant MAX_STRATEGIES_NUM = 8;
    EnumerableSet.AddressSet private _testUsers;
    uint256 constant MAX_ETH_ALLOWED = 1000000 * Constants.ONE_ETHER;
    uint256 MAX_USDC_ALLOWED = Constants.ONE_ETHER;
    uint32 constant ONE_DAY_HEARTBEAT = 86400;
    uint32 constant BNB_HEARTBEAT = 900;

    function _getSugarUser() internal returns (address payable) {
        address payable _user = _getNextUserAddress();
        vm.deal(_user, 1000000 ether);

        vm.startPrank(_user);
        WETH(wETH).deposit{value: wETHVal}();
        vm.stopPrank();

        uint256 _asset = ERC20(wETH).balanceOf(_user);
        assertEq(_asset, wETHVal);

        _testUsers.add(_user);

        return _user;
    }

    function _getSugarUserWithERC20(
        DummyDEXRouter mockRouter,
        address user,
        address token,
        uint256 amount,
        uint256 _pricePerETH
    ) internal returns (uint256) {
        vm.startPrank(user);
        ERC20(wETH).approve(address(mockRouter), type(uint256).max);
        vm.stopPrank();

        mockRouter.setPrices(wETH, token, _pricePerETH);
        uint256 _out = mockRouter.dummySwapExactIn(user, user, wETH, token, amount);

        return _out;
    }

    function _getNextUserAddress() internal returns (address payable) {
        address payable _user = payable(address(uint160(uint256(nextUser))));
        nextUser = keccak256(abi.encodePacked(nextUser));
        return _user;
    }

    function _assertApproximateEq(uint256 _num1, uint256 _num2, uint256 _tolerance) internal pure returns (bool) {
        if (_num1 > _num2) {
            return _tolerance >= (_num1 - _num2);
        } else {
            return _tolerance >= (_num2 - _num1);
        }
    }

    function _applyFlashLoanFee(AAVEHelper _aaveHelper, uint256 _amt) internal view returns (uint256) {
        (,, uint256 _flFee) = _aaveHelper.useSparkFlashloan();
        return _amt * _flFee / Constants.TOTAL_BPS;
    }

    function _makeRedemptionRequest(address _user, uint256 _share, address _vault) internal returns (uint256) {
        uint256 _ppsBefore =
            SparkleXVault(_vault).previewMint(Constants.convertDecimalToUnit(SparkleXVault(_vault).decimals()));

        vm.startPrank(_user);
        ERC20(_vault).approve(_vault, type(uint256).max);
        uint256 _asset = SparkleXVault(_vault).requestRedemption(_share);
        vm.stopPrank();

        uint256 _ppsAfter =
            SparkleXVault(_vault).previewMint(Constants.convertDecimalToUnit(SparkleXVault(_vault).decimals()));
        assertTrue(_assertApproximateEq(_ppsBefore, _ppsAfter, BIGGER_TOLERANCE / COMP_TOLERANCE));

        return _asset;
    }

    function _claimRedemptionRequest(address _user, uint256 _share, address _vault, uint256 _tolerance)
        internal
        returns (uint256 _actualRedeemed)
    {
        uint256 _worthForRequestedShare =
            SparkleXVault(_vault).previewRedeem(SparkleXVault(_vault).userRedemptionRequestShares(_user));
        console.log(
            "_currentWorthForRequested:%d,_totalAssets:%d", _worthForRequestedShare, SparkleXVault(_vault).totalAssets()
        );

        uint256 _currentWorth = SparkleXVault(_vault).previewRedeem(_share);
        uint256 _requestedAsset = SparkleXVault(_vault).userRedemptionRequestAssets(_user);
        uint256 _less = _requestedAsset > _currentWorth ? _currentWorth : _requestedAsset;
        uint256 _currentTime = block.timestamp;
        vm.startPrank(_user);
        _actualRedeemed = SparkleXVault(_vault).claimRedemptionRequest();
        vm.stopPrank();
        (, uint256 _lastUpdateTA, uint256 _lastUpdateTime) = SparkleXVault(_vault).mgmtFee();
        assertEq(_lastUpdateTime, _currentTime);
        assertTrue(_lastUpdateTA >= SparkleXVault(_vault)._rawTotalAssets());

        assertTrue(_assertApproximateEq(_less, _actualRedeemed, _tolerance));
    }

    function _batchClaimRedemptionRequest(
        address _claimer,
        address[] memory _users,
        uint256[] memory _shares,
        address _vault,
        uint256 _tolerance
    ) internal returns (uint256 _actualRedeemed) {
        uint256 _currentWorth;
        uint256 _requestedAsset;
        uint256[] memory _beforeValues = new uint256[](_users.length);
        for (uint256 i = 0; i < _users.length; i++) {
            _beforeValues[i] = ERC20(SparkleXVault(_vault).asset()).balanceOf(_users[i]);
            _currentWorth = _currentWorth + SparkleXVault(_vault).previewRedeem(_shares[i]);
            _requestedAsset = _requestedAsset + SparkleXVault(_vault).userRedemptionRequestAssets(_users[i]);
            console.log("_beforeValue=%d,shares=%d", _beforeValues[i], _shares[i]);
        }

        uint256 _less = _requestedAsset > _currentWorth ? _currentWorth : _requestedAsset;
        uint256 _oneShare = Constants.convertDecimalToUnit(SparkleXVault(_vault).decimals());
        uint256 _exchangeRate = SparkleXVault(_vault).convertToAssets(_oneShare);
        console.log("_exchangeRate:%d", _exchangeRate);

        vm.startPrank(_claimer);
        _actualRedeemed = SparkleXVault(_vault).batchClaimRedemptionRequestsFor(_users);
        vm.stopPrank();
        {
            (, uint256 _lastUpdateTA,) = SparkleXVault(_vault).mgmtFee();
            assertTrue(_lastUpdateTA > SparkleXVault(_vault)._rawTotalAssets());
        }

        for (uint256 i = 0; i < _users.length; i++) {
            uint256 _diff = ERC20(SparkleXVault(_vault).asset()).balanceOf(_users[i]) - _beforeValues[i];
            uint256 _diffRate = (_diff * _oneShare) / _shares[i];
            console.log("_diff:%d,_diffRate:%d", _diff, _diffRate);
            assertTrue(_assertApproximateEq(_diffRate, _exchangeRate, _oneShare / Constants.TOTAL_BPS));
        }

        assertTrue(_assertApproximateEq(_less, _actualRedeemed, _tolerance));
    }

    function _fundFirstDepositGenerously(address _vault) internal returns (uint256) {
        address _generousUser = _getSugarUser();
        uint256 _generousAsset = MIN_SHARE + 1;
        vm.startPrank(_generousUser);
        ERC20(wETH).approve(_vault, type(uint256).max);
        SparkleXVault(_vault).deposit(_generousAsset, _generousUser);
        vm.stopPrank();
        return _generousAsset;
    }

    function _fundFirstDepositGenerouslyWithERC20(DummyDEXRouter _mockRouter, address _vault, uint256 _pricePerETH)
        internal
        returns (uint256)
    {
        address _generousUser = _getSugarUser();
        uint256 _generousAsset = MIN_SHARE + 1;
        address _asset = SparkleXVault(_vault).asset();
        uint256 _asset2ETH =
            _generousAsset * 1e18 * 1e18 / (_pricePerETH * Constants.convertDecimalToUnit(ERC20(_asset).decimals()));

        _getSugarUserWithERC20(_mockRouter, _generousUser, _asset, _asset2ETH * 2, _pricePerETH);

        vm.startPrank(_generousUser);
        ERC20(_asset).approve(_vault, type(uint256).max);
        SparkleXVault(_vault).deposit(_generousAsset, _generousUser);
        vm.stopPrank();
        return _generousAsset;
    }

    function _changeWithdrawFee(address _vaultOwner, address _vault, uint256 _bps) internal {
        vm.expectRevert(Constants.INVALID_BPS_TO_SET.selector);
        vm.startPrank(_vaultOwner);
        SparkleXVault(_vault).setWithdrawFeeRatio(Constants.TOTAL_BPS);
        vm.stopPrank();

        vm.startPrank(_vaultOwner);
        SparkleXVault(_vault).setWithdrawFeeRatio(_bps);
        vm.stopPrank();
    }

    function _checkBasicInvariants(address _vault) internal {
        _checkConvertToSharesFull(_vault);
        _checkConvertToAssetsFull(_vault);
        _checkTotalShare(_vault);
        _checkStrategyAllocations(_vault);
        _checkManagementFee(_vault);
    }

    function _checkConvertToSharesFull(address _vault) internal {
        uint256 _supply = SparkleXVault(_vault).totalSupply();
        uint256 _asset = SparkleXVault(_vault).totalAssets();
        uint256 _supplyConverted = SparkleXVault(_vault).convertToShares(_asset);
        console.log("_supply:%d,_supplyConverted:%d,_asset:%d", _supply, _supplyConverted, _asset);
        assertTrue(_assertApproximateEq(_supply, _supplyConverted, BIGGER_TOLERANCE));
    }

    function _checkConvertToAssetsFull(address _vault) internal {
        uint256 _supply = SparkleXVault(_vault).totalSupply();
        uint256 _asset = SparkleXVault(_vault).totalAssets();
        uint256 _assetConverted = SparkleXVault(_vault).convertToAssets(_supply);
        console.log("_supply:%d,_asset:%d,_assetConverted:%d", _supply, _asset, _assetConverted);
        assertTrue(_assertApproximateEq(_asset, _assetConverted, BIGGER_TOLERANCE));
    }

    function _checkTotalShare(address _vault) internal {
        uint256 _totalSupply = SparkleXVault(_vault).totalSupply();
        assertTrue(_totalSupply >= MIN_SHARE);

        uint256 _vaultShare = ERC20(_vault).balanceOf(_vault);
        assertTrue(_vaultShare >= MIN_SHARE);

        uint256 usrLength = _testUsers.length();
        uint256 _usrShares;
        for (uint256 i = 0; i < usrLength; i++) {
            _usrShares += ERC20(_vault).balanceOf(_testUsers.at(i));
        }
        assertEq(_totalSupply, _usrShares + _vaultShare);
    }

    function _checkStrategyAllocations(address _vault) internal {
        uint256 _activeCount;
        for (uint256 i = 0; i < MAX_STRATEGIES_NUM; i++) {
            address _strategy = SparkleXVault(_vault).allStrategies(i);
            if (_strategy != Constants.ZRO_ADDR) {
                _activeCount++;
                assertTrue(IStrategy(_strategy).totalAssets() >= IStrategy(_strategy).assetsInCollection());
                assertTrue(IStrategy(_strategy).totalAssets() <= SparkleXVault(_vault).strategyAllocations(_strategy));
            }
        }
        assertEq(_activeCount, SparkleXVault(_vault).activeStrategies());
    }

    function _checkManagementFee(address _vault) internal {
        (uint256 _accumulatedFee, uint256 _lastUpdateTA, uint256 _lastUpdateTime) = SparkleXVault(_vault).mgmtFee();
        assertTrue(block.timestamp >= _lastUpdateTime);
        uint256 _totalAssets = SparkleXVault(_vault).totalAssets();
        uint256 _rawTA = SparkleXVault(_vault)._rawTotalAssets();
        (uint256 _newFee2,) = SparkleXVault(_vault).previewManagementFeeAccumulated(_rawTA, block.timestamp);
        assertEq(_totalAssets + _newFee2 + _accumulatedFee, _rawTA);
        (uint256 _newFee1,) = SparkleXVault(_vault).previewManagementFeeAccumulated(_lastUpdateTA, block.timestamp);
        assertEq(_newFee1, _newFee2);
    }

    function _makeVaultDeposit(address _vault, address _user, uint256 _amount, uint256 _low, uint256 _high)
        internal
        returns (uint256, uint256)
    {
        uint256 _assetAmount = bound(_amount, _low, _high);
        uint256 _currentTime = block.timestamp;
        vm.startPrank(_user);
        ERC20(SparkleXVault(_vault).asset()).approve(_vault, type(uint256).max);
        uint256 _share = SparkleXVault(_vault).deposit(_assetAmount, _user);
        vm.stopPrank();
        (,, uint256 _lastUpdateTime) = SparkleXVault(_vault).mgmtFee();
        assertEq(_lastUpdateTime, _currentTime);
        return (_assetAmount, _share);
    }

    function _makeVaultDepositWithMockRouter(
        DummyDEXRouter _mockRouter,
        address _vault,
        address _user,
        uint256 _pricePerETH,
        uint256 _amountInETH,
        uint256 _low,
        uint256 _high
    ) internal returns (uint256, uint256) {
        uint256 _assetAmountInETH = bound(_amountInETH, _low, _high);
        address _asset = SparkleXVault(_vault).asset();

        uint256 _assetAmount = _getSugarUserWithERC20(_mockRouter, _user, _asset, _assetAmountInETH, _pricePerETH);
        uint256 _currentTime = block.timestamp;
        vm.startPrank(_user);
        ERC20(_asset).approve(_vault, type(uint256).max);
        uint256 _share = SparkleXVault(_vault).deposit(_assetAmount, _user);
        vm.stopPrank();
        (,, uint256 _lastUpdateTime) = SparkleXVault(_vault).mgmtFee();
        assertEq(_lastUpdateTime, _currentTime);
        return (_assetAmount, _share);
    }

    function deployWithCreationCode(string memory _saltString, bytes memory _creationCode)
        public
        returns (address deployedAddress)
    {
        bytes32 _salt = keccak256(abi.encodePacked(_saltString));
        deployedAddress = Create3.create3(_salt, _creationCode);
    }

    function deployWithCreationCodeAndConstructorArgs(
        string memory _saltString,
        bytes memory creationCode,
        bytes memory constructionArgs
    ) public returns (address) {
        bytes memory _data = abi.encodePacked(creationCode, constructionArgs);
        return deployWithCreationCode(_saltString, _data);
    }

    function addressOf(string memory _saltString) external view returns (address) {
        bytes32 _salt = keccak256(abi.encodePacked(_saltString));
        return Create3.addressOf(_salt);
    }

    function _prepareSwapForMockRouter(
        DummyDEXRouter _mockRouter,
        address _inToken,
        address _outToken,
        address _outTokenWhale,
        uint256 _priceInE18
    ) internal {
        _mockRouter.setWhales(_outToken, _outTokenWhale);
        _mockRouter.setPrices(_inToken, _outToken, _priceInE18);
    }

    function _createForkMainnet(uint256 _blockHight) internal {
        string memory MAINNET_RPC = vm.envString("TESTNET_RPC");
        uint256 forkId = vm.createFork(MAINNET_RPC, _blockHight);
        vm.selectFork(forkId);
        assertEq(_blockHight, block.number);
        assertEq(block.chainid, 1);
    }

    function _createForkBNBChain(uint256 _blockHight) internal {
        string memory BNB_RPC = vm.envString("TESTNET_RPC_BNB");
        uint256 forkId = vm.createFork(BNB_RPC, _blockHight);
        vm.selectFork(forkId);
        assertEq(_blockHight, block.number);
        assertEq(block.chainid, 56);
    }

    function _findTargetEvent(Vm.Log[] memory logs, bytes32 _targetEvent) internal view returns (bool) {
        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (log.topics[0] == _targetEvent) {
                eventFound = true;
                break;
            }
        }
        return eventFound;
    }

    function _toggleVaultPause(address _vault, bool _expected) internal returns (bool) {
        vm.expectRevert(Constants.ONLY_FOR_PAUSE_COMMANDER.selector);
        vm.startPrank(wETH);
        SparkleXVault(_vault).togglePauseState();
        vm.stopPrank();

        vm.startPrank(SparkleXVault(_vault)._pauseCommander());
        bool _paused = SparkleXVault(_vault).togglePauseState();
        vm.stopPrank();
        assertEq(_expected, _paused);
        return _paused;
    }

    function _setTokenSwapperWhitelist(address _tokenSwapper, address _caller, bool _whitelisted) internal {
        vm.startPrank(TokenSwapper(_tokenSwapper).owner());
        TokenSwapper(_tokenSwapper).setWhitelist(_caller, _whitelisted);
        vm.stopPrank();
    }
}
