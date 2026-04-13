// 作用：标准 ERC721 NFT，用于拍卖
    // 你需要实现：
    // 继承 ERC721
    // 实现 mint() 铸造函数
    // 给每个用户 mint 一个测试 NFT
// 核心功能：
    // 铸造 NFT
    // 转移 NFT
    // 查询所有者

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";



contract MyNFT is ERC721, ERC721URIStorage, Ownable {

    using Address for address payable;
    
    // tokenId 计数器
    uint256 public _tokenIdCounter;

    // 最大供应量
    uint256 public constant MAX_SUPPLY = 10000;

    // 铸造价格
    uint256 public mintPrice = 0.01 ether;

    // 记录领取测试 NFT 的地址
    mapping (address => bool) public hasClaimedTestNFT;

    // 记录NTF的所有者
    // mapping (uint256 => address) public tokenOwners; 
    // ERC721 已经内置了所有者记录，所以不需要额外的 mapping 来存储 tokenId 和 owner 的关系，可以直接使用 ERC721 提供的 ownerOf() 函数来查询 NFT 的所有者。   

    // 事件
    event Minted(
        address indexed minter, 
        uint256 indexed tokenId,
         string tokenURI
         );

    // 构造函数，设置 NFT 名称和符号
    constructor() ERC721("MyNFT", "MNFT") Ownable(msg.sender){}

    // 铸造函数，用户可以调用这个函数来铸造新的 NFT
    function mint(string memory _tokenURI) public payable returns (uint256) {
        require(_tokenIdCounter < MAX_SUPPLY, "Max supply reached");
        require(msg.value >= mintPrice, "Insufficient payment");
        require(bytes(_tokenURI).length > 0, "URI empty");

        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, _tokenURI);

        if (msg.value > mintPrice) {
            payable(msg.sender).sendValue(msg.value - mintPrice);
        }

        emit Minted(msg.sender, tokenId, _tokenURI);

        return tokenId;
    }

    // 给每个用户 mint 一个测试 NFT
    function claimTestNFT() public {
        require(!hasClaimedTestNFT[msg.sender], "Already claimed test NFT");
        require(_tokenIdCounter < MAX_SUPPLY, "Max supply reached");


        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, "https://example.com/test-nft.json");

        hasClaimedTestNFT[msg.sender] = true;

        emit Minted(msg.sender, tokenId, "https://example.com/test-nft.json");
    }

    // 检查接口支持
    function supportsInterface(bytes4 interfaceId) public view override(ERC721,ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // 重写 tokenURI 函数，返回存储的 URI
    function tokenURI(uint256 tokenId) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    

    // 返回总的供应量
    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter;
    }


    function withdraw() external onlyOwner {
        payable(owner()).sendValue(address(this).balance);
    }
}