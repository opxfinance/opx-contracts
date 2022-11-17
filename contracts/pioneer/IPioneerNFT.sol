// SPDX-License-Identifier: MIT

pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

interface IPioneerNFT is IERC721, IERC721Enumerable {

    function getPower(uint256 tokenId) external view returns (uint256);

}
