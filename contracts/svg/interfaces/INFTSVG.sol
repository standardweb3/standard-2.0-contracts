

pragma solidity ^0.8.17;

interface INFTSVG {
   function tokenURI(uint256 tokenId) external view returns (string memory);
}