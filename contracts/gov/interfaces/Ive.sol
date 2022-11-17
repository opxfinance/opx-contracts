// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

interface Ive {
    function token() external view returns (address);

    function balanceOfNFT(uint256) external view returns (uint256);

    function depositedNFT(address) external view returns (uint256);

    function transferFrom(address, address, uint256) external;

    function attach(uint256 tokenId) external;

    function detach(uint256 tokenId) external;

    function voting(uint256 tokenId) external;

    function abstain(uint256 tokenId) external;

    function increase_amount(uint256 _tokenId, uint256 _value) external;

    function increase_unlock_time(uint256 _tokenId, uint256 _lock_duration) external;

    function emergencyWithdraw(uint256 _tokenId) external;
}
