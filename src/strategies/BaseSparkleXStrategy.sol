// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../../interfaces/IStrategy.sol";
import {Constants} from "../utils/Constants.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TokenSwapper} from "../utils/TokenSwapper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface ISparkleXVault {
    function getAllocationAvailableForStrategy(address _strategyAddr) external view returns (uint256);
    function asset() external view returns (address);
}

abstract contract BaseSparkleXStrategy is IStrategy, Ownable {
    using Math for uint256;
    using Address for address;

    ///////////////////////////////
    // constants
    ///////////////////////////////

    ///////////////////////////////
    // integrations - Ethereum mainnet
    ///////////////////////////////

    ///////////////////////////////
    // member storage
    ///////////////////////////////
    ERC20 immutable _asset;
    address immutable _vault;
    address _strategist;
    address public _swapper;

    ///////////////////////////////
    // events
    ///////////////////////////////
    event StrategyCreated(address indexed owner, address indexed vault, address indexed token);
    event StrategistChanged(address indexed _old, address indexed _new);
    event SwapperChanged(address indexed _old, address indexed _new);

    constructor(ERC20 token, address vaultAddr) Ownable(msg.sender) {
        if (address(token) == Constants.ZRO_ADDR || vaultAddr == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }

        _asset = token;
        _vault = vaultAddr;
        _strategist = msg.sender;

        if (ISparkleXVault(_vault).asset() != address(token)) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }

        emit StrategyCreated(msg.sender, _vault, address(token));
    }

    /**
     * @dev allow only called by strategist.
     */
    modifier onlyStrategist() {
        if (msg.sender != _strategist) {
            revert Constants.ONLY_FOR_STRATEGIST();
        }
        _;
    }

    /**
     * @dev allow only called when Vault is not paused.
     */
    modifier onlyVaultNotPaused() {
        if (vaultPaused()) {
            revert Constants.VAULT_ALREADY_PAUSED();
        }
        _;
    }

    /**
     * @dev allow only called by strategist or owner.
     */
    modifier onlyStrategistOrOwner() {
        if (msg.sender != _strategist && msg.sender != owner()) {
            revert Constants.ONLY_FOR_STRATEGIST_OR_OWNER();
        }
        _;
    }

    /**
     * @dev allow only called by strategist.
     */
    modifier onlyStrategistOrVault() {
        if (msg.sender != _strategist && msg.sender != _vault) {
            revert Constants.ONLY_FOR_STRATEGIST_OR_VAULT();
        }
        _;
    }

    ///////////////////////////////
    // base methods
    ///////////////////////////////

    function vaultPaused() public view returns (bool) {
        return Pausable(_vault).paused();
    }

    function setStrategist(address _newStrategist) external onlyOwner {
        if (_newStrategist == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        emit StrategistChanged(_strategist, _newStrategist);
        _strategist = _newStrategist;
    }

    function setSwapper(address _newSwapper) external onlyOwner {
        if (_newSwapper == Constants.ZRO_ADDR) {
            revert Constants.INVALID_ADDRESS_TO_SET();
        }
        emit SwapperChanged(_swapper, _newSwapper);
        _swapper = _newSwapper;
    }

    function strategist() external view virtual returns (address) {
        return _strategist;
    }

    function asset() external view virtual returns (address) {
        return address(_asset);
    }

    function vault() external view virtual returns (address) {
        return _vault;
    }

    ///////////////////////////////
    // convenient helper methods
    ///////////////////////////////

    function _returnAssetToVault(uint256 amount) internal returns (uint256) {
        uint256 _returned = _capAmountByBalance(_asset, amount, false);
        if (_returned > 0) {
            SafeERC20.safeTransfer(_asset, _vault, _returned);
        }
        return _returned;
    }

    function _capAllocationAmount(uint256 _amount) internal view returns (uint256) {
        uint256 _maxAllocation = ISparkleXVault(_vault).getAllocationAvailableForStrategy(address(this));
        return _amount > _maxAllocation ? _maxAllocation : _amount;
    }

    /**
     * @dev set _applyMargin to true if a bit more needed which typically is useful in swap
     */
    function _capAmountByBalance(ERC20 _token, uint256 _amount, bool _applyMargin) public view returns (uint256) {
        uint256 _expected = (_applyMargin && _swapper != Constants.ZRO_ADDR)
            ? TokenSwapper(_swapper).applySlippageMargin(_amount)
            : _amount;
        uint256 _balance = _token.balanceOf(address(this));
        return _balance > _expected ? _expected : _balance;
    }

    function _approveToken(address _token, address _spender) internal {
        if (ERC20(_token).allowance(address(this), _spender) == 0) {
            SafeERC20.forceApprove(ERC20(_token), _spender, type(uint256).max);
        }
    }

    function _revokeTokenApproval(address _token, address _spender) internal {
        SafeERC20.forceApprove(ERC20(_token), _spender, 0);
    }

    function manageCall(address target, bytes calldata data, uint256 value)
        external
        onlyOwner
        onlyVaultNotPaused
        returns (bytes memory result)
    {
        result = target.functionCallWithValue(data, value);
    }
}
