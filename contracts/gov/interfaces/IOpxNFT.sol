// SPDX-License-Identifier: MIT

pragma solidity >=0.6.12;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IOpxNFT {
    function getTokenLevel(uint256 tokenId) external view returns (uint256);
}
