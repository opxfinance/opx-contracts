// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface IPioneerStaking {
    function stakerOfNFT(uint256 tokenId) external view returns (address);
    function onRewardUpdated(uint256 _epochReward, uint256 _totalWeight, uint256 _profitShareWeight) external;

}
