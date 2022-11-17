// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

// Support Multi Day
interface IMultiDayMerkleDistributor {
    // Returns the address of the token distributed by this contract.
    function token() external view returns (address);

    // Returns the merkle root of the merkle tree containing account balances available to claim.
    function merkleRoot(uint256 day) external view returns (bytes32);

    // Returns true if the index has been marked claimed.
    function isClaimed(uint256 day, uint256 index) external view returns (bool);

    // set merkle root for day
    function setMerkleRoot(uint256 day, uint256 amount, bytes32 _merkleRoot) external;

    // Claim the given amount of the token to the given address. Reverts if the inputs are invalid.
    function claim(uint256 day, uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external;

    function claimMultiDay(uint256[] calldata day, uint256[] calldata index, address account, uint256[] calldata amount, bytes32[][] calldata merkleProof) external;

    // This event is triggered whenever a call to #claim succeeds.
    event Claimed(uint256 day, uint256 index, address account, uint256 amount);
}
