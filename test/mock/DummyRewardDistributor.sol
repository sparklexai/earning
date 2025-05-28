// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

contract DummyRewardDistributor {
    event DummyRewardClaimed(uint256 index, address account, uint256 amount);

    function generateClaimCallData(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof)
        external
        view
        returns (bytes memory)
    {
        bytes memory _data = abi.encodeWithSelector(this.claim.selector, index, account, amount, merkleProof);
        return _data;
    }

    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof)
        external
        returns (bool)
    {
        emit DummyRewardClaimed(index, account, amount);
        return true;
    }
}
