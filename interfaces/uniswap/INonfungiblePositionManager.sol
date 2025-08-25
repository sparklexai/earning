pragma solidity 0.8.29;

/// @title interface for INonfungiblePositionManager
interface INonfungiblePositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct NFTPositionData {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function positions(uint256 tokenId) external view returns (NFTPositionData memory _positionData);

    function collect(CollectParams calldata _params) external returns (uint256 amount0, uint256 amount1);
    function balanceOf(address _owner) external returns (uint256);
    function tokenOfOwnerByIndex(address _owner, uint256 _index) external returns (uint256);
    function approve(address _spender, uint256 _tokenId) external;
}
