// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface IStrategy {
    /**
     * @dev Returns the address of the underlying token used by the strategy, should be same as Vault's.
     */
    function asset() external view returns (address assetTokenAddress);

    /**
     * @dev Returns the address of associated Vault.
     */
    function vault() external view returns (address vaultAddress);

    /**
     * @dev Returns the total amount of the underlying asset (plus earnings or loss) that is managed by this strategy.
     */
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /**
     * @dev Returns the total amount of the underlying asset (plus earnings or loss) that is in the process of collection.
     */
    function assetsInCollection() external view returns (uint256 inCollectionAssets);

    /**
     * @dev make investment of underlying asset with given amount from Vault into this strategy
     * @param _extraAction extra bytes data, which is used for any followup action required.
     */
    function allocate(uint256 amount, bytes calldata _extraAction) external;

    /**
     * @dev recycle investment with given amount from this strategy back to Vault
     * @param _extraAction extra bytes data, which is used for any followup action required.
     */
    function collect(uint256 amount, bytes calldata _extraAction) external;

    /**
     * @dev recycle all remaining investment from this strategy back to Vault
     * @param _extraAction extra bytes data, which is used for any followup action required.
     */
    function collectAll(bytes calldata _extraAction) external;

    /**
     * @dev Returns the address of the strategist who could handle some critical missions for this strategy.
     */
    function strategist() external view returns (address strategist);

    /**
     * @dev issue this event when investment allocation triggered by strategist.
     */
    event AllocateInvestment(address indexed _strategist, uint256 _allocationAmount);

    /**
     * @dev issue this event when investment collection triggered by strategist or vault.
     */
    event CollectInvestment(address indexed _caller, uint256 _collectionAmount);
}
