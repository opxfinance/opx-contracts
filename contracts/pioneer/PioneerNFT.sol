// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

/*
 * ApeSwap Finance
 * App:             https://apeswap.finance
 * Medium:          https://ape-swap.medium.com
 * Twitter:         https://twitter.com/ape_swap
 * Telegram:        https://t.me/ape_swap
 * Announcements:   https://t.me/ape_swap_news
 * GitHub:          https://github.com/ApeSwapFinance
 */

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract PioneerNFT is Context, AccessControlEnumerable, ERC721Enumerable {
    using Counters for Counters.Counter;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    Counters.Counter private _tokenIdTracker;

    string private _baseTokenURI;
    /// @notice Collection of NFA details to describe each NFA
    struct NFADetails {
        string name;
        uint256 power;
    }
    /// @notice Use the NFA tokenId to read NFA details
    mapping(uint256 => NFADetails) public getNFADetailsById;

    event UpdateBaseURI(string indexed previousBaseUri, string indexed newBaseUri);

    constructor(string memory name, string memory symbol, string memory baseTokenURI) ERC721(name, symbol) {
        _baseTokenURI = baseTokenURI;

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(MINTER_ROLE, _msgSender());
    }

    /// @notice Get power of a specific ID
    /// @param tokenId The ID of the NFA to check
    /// @return (uint)
    function getPower(uint256 tokenId) external view returns (uint256) {
        NFADetails memory currentNFADetails = getNFADetailsById[tokenId];
        return currentNFADetails.power;
    }

    /// @notice Update the baseTokenURI of the NFT
    /// @dev The admin of this function is expected to renounce ownership once the base url has been tested and is working
    /// @param baseTokenURI The new bse uri for the contract
    function updateBaseTokenURI(string memory baseTokenURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit UpdateBaseURI(_baseTokenURI, baseTokenURI);
        _baseTokenURI = baseTokenURI;
    }

    /// @notice mint a new NFA to an address
    /// @dev must be called by an account with MINTER_ROLE
    /// @param to Address to mint the NFA to
    /// @param name Name of the NFA
    /// @param power Level of the NFA
    /// @param power Level of the NFA
    function mint(
        address to,
        string memory name,
        uint256 power
    ) public virtual onlyRole(MINTER_ROLE) {
        _tokenIdTracker.increment();
        uint256 currentTokenId = _tokenIdTracker.current();
        _mint(to, currentTokenId);
        getNFADetailsById[currentTokenId] = NFADetails(
            name,
            power
        );

    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual override(ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControlEnumerable, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
