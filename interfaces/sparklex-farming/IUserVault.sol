// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface IUserVault is IERC721Receiver {
    struct StrategyAddLiquidityParams {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 sqrtPriceX96;
        uint256 slippage;
        uint256 priceSlippage;
        bool userFund;
        bytes token0SwapPath;
        bytes token1SwapPath;
    }

    struct StrategyRemoveLiquidityParams {
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint8 recipient;
    }

    struct StrategyAddBaseTokenOnlyWithCalculateParam {
        address baseToken;
        address farmingToken;
        uint256 totalAmount;
        uint256 sqrtPriceX96;
        uint256 slippage;
        uint256 priceSlippage;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        bytes swapPath;
    }

    struct StrategyZapMintParam {
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 sqrtPriceX96;
        uint256 slippage;
        uint256 priceSlippage;
        bytes token0SwapPath;
        bytes token1SwapPath;
        bool userFund;
    }

    // View Functions
    function user() external view returns (address);
    function manager() external view returns (address);
    function agent() external view returns (address);
    function approvedAgentPools(bytes32) external view returns (bool);
    function nextPositionId() external view returns (uint256);

    // State-Changing Functions
    function work(address _caller, uint256 _positionID, address _strategy, bytes calldata _data) external;

    function setAgent(address _newAgent) external;

    function setApprovedAgentPools(bytes32[] calldata _poolKeys, bool _allowed) external;

    /// @notice Collect tokens in this contract
    function collect(address _token, address _recipient) external;

    /// @notice Collect tokens in batch
    function collectInBatch(address[] calldata _tokens, address _recipient) external;

    function requestFundsFromUser(address _token, uint256 _amount) external;

    function requestFunds(address _token, uint256 _amount) external;

    function requestERC721(address _targetedERC721, uint256 _tokenId) external;
}
