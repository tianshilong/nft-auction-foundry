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
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";




contract MyNFT is ERC721, ERC721URIStorage, Ownable,ReentrancyGuard {

    using Address for address payable;
    
    // tokenId 计数器
    uint256 public _tokenIdCounter;

    // 最大供应量
    uint256 public constant MAX_SUPPLY = 10000;

    // 铸造价格
    uint256 public mintPrice = 0.01 ether;

    // 记录领取测试 NFT 的地址
    mapping (address => bool) public hasClaimedTestNFT;

    // 记录用户超额支付的 ETH 
    mapping(address => uint256) public pendingReturns;
    // 全部待退款总额
    uint256 public totalPendingReturns;

    // 记录NTF的所有者
    // mapping (uint256 => address) public tokenOwners; 
    // ERC721 已经内置了所有者记录，所以不需要额外的 mapping 来存储 tokenId 和 owner 的关系，可以直接使用 ERC721 提供的 ownerOf() 函数来查询 NFT 的所有者。   

    // 事件
    event Minted(
        address indexed minter, 
        uint256 indexed tokenId,
         string tokenURI
         );


    event ExcessPending(address indexed user, uint256 amount);
    event ExcessWithdrawn(address indexed user, uint256 amount);

    // 构造函数，设置 NFT 名称和符号
    constructor() ERC721("MyNFT", "MNFT") Ownable(msg.sender){}

    // 铸造函数，用户可以调用这个函数来铸造新的 NFT
    function mint(string memory _tokenURI) public payable nonReentrant returns (uint256) {
        require(_tokenIdCounter < MAX_SUPPLY, "Max supply reached");
        require(msg.value >= mintPrice, "Insufficient payment");
        require(bytes(_tokenURI).length > 0, "URI empty");

        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, _tokenURI);

        // 处理超额支付：将多余金额存入待退款池，用户稍后主动提取
        if (msg.value > mintPrice) {
            uint256 excess = msg.value - mintPrice;
            pendingReturns[msg.sender] += excess;
            totalPendingReturns += excess;
            emit ExcessPending(msg.sender, excess);
        }

        emit Minted(msg.sender, tokenId, _tokenURI);

        return tokenId;
    }

    function withdrawExcess() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        pendingReturns[msg.sender] = 0;
        totalPendingReturns -= amount;

        // 使用 sendValue，如果接收者合约拒绝接收 ETH 会导致交易回滚
        // 但此时其待退款记录已清零，用户需自行解决收款问题（例如更换地址）。
        // 这是 pull 模式的正常取舍，且不影响其他用户。
        payable(msg.sender).sendValue(amount);
        emit ExcessWithdrawn(msg.sender, amount);
    }

    // 给每个用户 mint 一个测试 NFT
    function claimTestNFT() external nonReentrant {
        require(!hasClaimedTestNFT[msg.sender], "Already claimed test NFT");
        require(_tokenIdCounter < MAX_SUPPLY, "Max supply reached");

        uint256 tokenId = _tokenIdCounter;
        _tokenIdCounter++;

        _safeMint(msg.sender, tokenId);
        _setTokenURI(tokenId, "https://example.com/test-nft.json");

        hasClaimedTestNFT[msg.sender] = true;

        emit Minted(msg.sender, tokenId, "https://example.com/test-nft.json");
    }

     function withdraw() external onlyOwner {
        // 合约余额中扣除所有用户待退款，剩余部分才是平台可提取的
        uint256 available = address(this).balance - totalPendingReturns;
        if (available > 0) {
            payable(owner()).sendValue(available);
        }
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
}