// 这是整个作业的核心：拍卖主合约
// 必须实现的功能

// 创建拍卖
    // 卖家批准 NFT 给合约
    // 创建拍卖：设置 NFT、起拍价、结束时间

// 出价功能
    // 支持 ETH 出价
    // 支持 ERC20 出价

// Chainlink 价格换算
    // 获取 ETH/USD 价格
    // 获取 ERC20/USD 价格
    // 把出价金额 → 自动换算成美元

// 结束拍卖
    // 最高出价者获得 NFT
    // 卖家收到资金

// UUPS 可升级
    // 继承 UUPSUpgradeable
    // 实现 _authorizeUpgrade ()
    
// 内部必须有的结构
    // 拍卖结构体 struct Auction
    // 拍卖列表 mapping
    // 最高出价记录
    // Chainlink Price Feed 地址

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";


import "@chainlink/contracts/v0.8/interfaces/AggregatorV3Interface.sol";



contract NFTMarketAuction is Initializable, UUPSUpgradeable, OwnableUpgradeable, IERC721Receiver {

    using Address for address payable;

    enum State { Pending, Active, Failed, Successful, Cancelled }

    struct Auction {
        address seller;             // 卖家地址
        address nftContract;        // NFT 合约地址
        uint256 tokenId;            // NFT 编号
        uint256 startPrice;         // 起拍价
        uint256 duration;           // 拍卖持续时间
        uint256 endTime;            // 结束时间
        address highestBidder;      // 最高出价者
        uint256 highestBid;         // 最高出价金额
        uint256 highestBidValueUsd; // 最高出价的美元价值
        State state;                // 拍卖的状态
        address bidToken;           // address(0) 表示 ETH，否则为 ERC20 地址
    }

    // 拍卖列表
    mapping(uint256 => Auction) public auctions;
    // 拍卖计数器
    uint256 public auctionCount;

    // 记录待退款金额，bidder => token => amount
    mapping(address => mapping(address => uint256)) public pendingRefunds;

    // 事件
    event Received(address operator, address from, uint256 tokenId, bytes data);

    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 startPrice,
        uint256 duration,
        uint256 endTime,
        State state
    );

    event AuctionStarted(
        uint256 indexed auctionId, 
        uint256 endTime
    );

    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint256 usdValue
    );

    event AuctionEnded(
        uint256 indexed auctionId,
        address indexed winner,
        State state,
        uint256 winningBid
    );

    event AuctionCancelled(
        uint256 indexed auctionId,
        uint256 cancelTime
    );

    modifier onlySeller(uint256 _auctionId) {
        require(auctions[_auctionId].seller == msg.sender, "Not seller");
        _;
    }

    modifier auctionState(uint256 _auctionId, State _state) {
        require(auctions[_auctionId].state == _state, "Invalid state");
        _;
    }

    modifier auctionTime(uint256 _auctionId) {
        require(block.timestamp < auctions[_auctionId].endTime, "Auction ended");
        _;
    }

    modifier auctionExists(uint256 _auctionId) {
        require(_auctionId > 0 && _auctionId <= auctionCount, "Invalid auctionId");
        _;
    }

    AggregatorV3Interface public ethUsdPriceFeed;
    AggregatorV3Interface public erc20UsdPriceFeed; 

    // ETH/USD	0x694AA1769357215DE4FAC081bf1f309aDC325306
    // USDC/USD	0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E
    constructor() {
       _disableInitializers();
    }

    function initialize(address _ethUsdFeed, address _erc20UsdFeed) external initializer {
        __Ownable_init(msg.sender);
        // __UUPSUpgradeable_init(); // UUPS 逻辑改为「无状态」，无需初始化，继承后直接用

        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdFeed);
        erc20UsdPriceFeed = AggregatorV3Interface(_erc20UsdFeed);
    }

    // UUPS 授权升级函数，仅 owner 可升级
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // 必须实现的函数：标记合约能接收 NFT
    function onERC721Received(address operator,address from,uint256 tokenId,bytes calldata data) external override returns (bytes4) {
        emit Received(operator, from, tokenId, data);
        return this.onERC721Received.selector;
    }


    // 创建拍卖
    function createAuction(address _nftContract,uint256 _tokenId,uint256 _startPrice,uint256 _duration,address _bidToken) external {
        require(_startPrice > 0, "Start price > 0");
        require(_duration >= 1 hours && _duration <= 3 days, "Duration 1h~3d");

         if (_bidToken != address(0)) {
            try IERC20Metadata(_bidToken).decimals() returns (uint8) {
                // 如果能成功调用 decimals()，说明是一个有效的 ERC20 代币
            } catch {
                revert("Invalid ERC20 token");
            }
        }

        IERC721 nft = IERC721(_nftContract);
        // 确保卖家是 NFT 的拥有者
        require(nft.ownerOf(_tokenId) == msg.sender, "Not owner");        
        require(nft.getApproved(_tokenId) == address(this) || 
                nft.isApprovedForAll(msg.sender, address(this)), 
        "NFT not approved for this contract");

        // 将 NFT 转移到合约地址 , 防止多次拍卖
        IERC721(_nftContract).safeTransferFrom(msg.sender, address(this), _tokenId);

        auctionCount++;
        auctions[auctionCount] = Auction({
            seller: msg.sender,
            nftContract: _nftContract,
            tokenId: _tokenId,
            startPrice: _startPrice,
            duration: _duration,
            endTime: 0,
            highestBidder: address(0),
            highestBid: 0,
            highestBidValueUsd: 0,
            state: State.Pending,
            bidToken: _bidToken
        });

        emit AuctionCreated(auctionCount,msg.sender, _tokenId, _startPrice, _duration, 0, State.Pending);
    }


    // 开始拍卖
    function startAuction(uint256 _auctionId) external 
    onlySeller(_auctionId)
    auctionState(_auctionId, State.Pending) 
    auctionExists(_auctionId) {
        Auction storage auction = auctions[_auctionId];

        auction.endTime = block.timestamp + auction.duration;
        auction.state = State.Active;

        emit AuctionStarted(_auctionId, auction.endTime);
    }

    //  出价功能
    function placeBid (uint256 _auctionId,uint256 _amount) 
    external 
    auctionState(_auctionId, State.Active)
    auctionTime(_auctionId)
    auctionExists(_auctionId) 
    payable {
        Auction storage auction = auctions[_auctionId];
        require(msg.sender != auction.seller, "Seller cannot bid");

        address bidToken = auction.bidToken;
        uint256 receivedAmount;
        uint256 usdValue;

        if (bidToken == address(0)) {
            // ETH 出价
            require(msg.value == _amount, "ETH amount mismatch");
            require(msg.value > 0, "Bid must be > 0");
            receivedAmount = msg.value;
            uint256 ethPrice = getEthPriceInUsd();
            usdValue = convertToUsdValue(receivedAmount, 18, ethPrice);

            uint256 startPriceUsd = convertToUsdValue(auction.startPrice, 18, ethPrice);
            require(usdValue >= startPriceUsd, "Bid below start price");
        } else {
            // ERC20 出价
            require(msg.value == 0, "No ETH");
            require(_amount > 0, "Bid amount must be > 0");
            IERC20Metadata token = IERC20Metadata(bidToken);
            require(token.allowance(msg.sender, address(this)) >= _amount, "Allowance too low");
            require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");

            receivedAmount = _amount;
            uint256 erc20Price = getErc20PriceInUsd();
            uint8 tokenDecimals = token.decimals();
            usdValue = convertToUsdValue(receivedAmount, tokenDecimals, erc20Price);
            uint256 startPriceUsd = convertToUsdValue(auction.startPrice, tokenDecimals, erc20Price);
            require(usdValue >= startPriceUsd, "Bid below start price");
        }

        require(usdValue > auction.highestBidValueUsd, "Bid too low in USD value");

        // 退还之前的最高出价
        address previousBidder = auction.highestBidder;
        uint256 previousAmount = auction.highestBid;

        auction.highestBidder = msg.sender;
        auction.highestBid = receivedAmount;
        auction.highestBidValueUsd = usdValue;

        if (previousBidder != address(0)) {
            pendingRefunds[previousBidder][bidToken] += previousAmount;
        }

        emit BidPlaced(_auctionId, msg.sender, receivedAmount,usdValue);

    }

    // 结束拍卖
    function endAuction(uint256 _auctionId) external virtual auctionExists(_auctionId) {
        Auction storage auction = auctions[_auctionId];
        require(block.timestamp >= auction.endTime,"Auction not ended");
        require(auction.state == State.Active,"auction not active");

        // 判断拍卖是否成功
        // 拍卖成功
        if (auction.highestBidder != address(0)) {
            auction.state = State.Successful;

            // 转移资金给卖家
            // 判断转移eth 还是 erc20
            if (auction.bidToken == address(0)){
                // 转移ETH
                payable(auction.seller).sendValue(auction.highestBid);
            } else {
                // 转移ERC20
                require(IERC20(auction.bidToken).transfer(auction.seller,auction.highestBid),"ERC20 payment failed");
            }

            // 转移nft 给 最高出价者
            IERC721(auction.nftContract).safeTransferFrom(address(this),auction.highestBidder,auction.tokenId);

            emit AuctionEnded(_auctionId, auction.highestBidder, State.Successful, auction.highestBid);
        } else {
            // 拍卖失败，退还 NFT 给卖家
            IERC721(auction.nftContract).safeTransferFrom(address(this), auction.seller, auction.tokenId);
            auction.state = State.Failed;
            emit AuctionEnded(_auctionId, address(0), State.Failed, 0);
        }
    }

    // 取消拍卖, 智能在pending状态中取消
    function cancelAuction(uint256 _auctionId) external 
    onlySeller(_auctionId) 
    auctionExists(_auctionId) 
    auctionState(_auctionId, State.Pending) {
        Auction storage auction = auctions[_auctionId];
        auction.state = State.Cancelled;

        // 退还 NFT 给卖家
        IERC721(auction.nftContract).safeTransferFrom(address(this), auction.seller, auction.tokenId);
        
        emit AuctionCancelled(_auctionId, block.timestamp);
    }

    // 用户自己来领取退款
    function claimRefund(address _bidToken) external {
    uint256 amount = pendingRefunds[msg.sender][_bidToken];
    require(amount > 0, "No refund");
    pendingRefunds[msg.sender][_bidToken] = 0;

    if (_bidToken == address(0)) {
        payable(msg.sender).sendValue(amount);
    } else {
        require(IERC20(_bidToken).transfer(msg.sender, amount), "ERC20 refund failed");
    }
}

    // 辅助函数
    // 获取ETH 美元价格
    function getEthPriceInUsd() internal view returns (uint256) {
        (, int price, , uint256 updatedAt, ) = ethUsdPriceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        require(updatedAt + 1 hours > block.timestamp, "Stale price");
        return uint256(price);
    }

    // 获取ERC20 美元价格
    function getErc20PriceInUsd() internal view returns (uint256) {
        (, int price, , uint256 updatedAt, ) = erc20UsdPriceFeed.latestRoundData();
        require(price > 0, "Invalid ERC20 price");
        require(updatedAt + 1 hours > block.timestamp, "Stale price");
        return uint256(price);
    }

    // 把出价金额 → 自动换算成美元
    // 将出价金额（带代币自身 decimals）换算成美元价值（统一用 8 位小数表示）
    function convertToUsdValue(uint256 amount, uint256 tokenDecimals, uint256 priceInUsd) internal pure returns (uint256) {
        // amount * priceInUsd / (10 ** tokenDecimals)
        // 结果会保留 8 位小数（因为 priceInUsd 是 8 位）
        return (amount * priceInUsd) / (10 ** tokenDecimals);
    }
    

}