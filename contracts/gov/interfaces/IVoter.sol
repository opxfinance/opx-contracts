// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface IVoter {
    /**
     * @dev When a token weight is updated, this function is called if the contract is registered as observer.
     */
    function onTokenWeightReset(uint256 _tokenId) external;

    function onRewardUpdated() external;
}
