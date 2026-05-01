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

    /** 
     * @notice 拍卖状态枚举
     */
    enum State { Pending, Active, Failed, Successful, Cancelled }

    /**
     * @notice 单次拍卖的完整信息
     * @dev 所有金额均以出价代币的最小单位表示，美元价值为 8 位小数（Chainlink 预言机精度）
     */
    struct Auction {
        address seller;              // 拍卖发起者（卖家）
        address nftContract;         // 待拍卖 NFT 的合约地址
        uint256 tokenId;             // 待拍卖 NFT 的编号
        uint256 startPrice;          // 起拍价（以 bidToken 计）
        uint256 duration;            // 拍卖持续时间（秒）
        uint256 endTime;             // 拍卖结束时刻（Unix 时间戳）
        address highestBidder;       // 当前最高出价者地址
        uint256 highestBid;          // 当前最高出价金额（代币数量）
        uint256 highestBidValueUsd;  // 最高出价对应的美元价值（仅记录，不作为比较依据）
        State state;                 // 拍卖当前状态
        address bidToken;            // 出价代币地址，address(0) 表示 ETH
        address erc20PriceFeed;      // 该拍卖专用的 ERC20/USD 价格预言机地址，若为 address(0) 则使用全局默认
        bool nftClaimed;             // NFT 是否已被提取（用于提取模式）
    }

    /// @notice 拍卖列表，通过拍卖 ID 查询
    mapping(uint256 => Auction) public auctions;
     /// @notice 拍卖计数器，每创建一个新拍卖加 1
    uint256 public auctionCount;

    /// @notice 待提取的被超过出价退款：用户地址 => 代币地址 => 金额
    mapping(address => mapping(address => uint256)) public pendingRefunds;

    /// @notice ETH/USD 价格预言机接口
    AggregatorV3Interface public ethUsdPriceFeed;
    /// @notice 全局默认 ERC20/USD 价格预言机接口
    AggregatorV3Interface public erc20UsdPriceFeed;
    // ETH/USD	0x694AA1769357215DE4FAC081bf1f309aDC325306
    // USDC/USD	0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E

    // 事件
    /** 
     * @notice 合约接收到 ERC721 代币时触发
     */
    event Received(address operator, address from, uint256 tokenId, bytes data);

     /**
     * @notice 新拍卖创建
     */
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 startPrice,
        uint256 duration,
        uint256 endTime,
        State state
    );

    /**
     * @notice NFT 被提取（最高出价者或卖家）
     */
    event NFTClaimed(uint256 indexed auctionId, address indexed claimer);


    /**
     * @notice 拍卖正式开始
     */
    event AuctionStarted(uint256 indexed auctionId, uint256 endTime);

    /**
     * @notice 有人出价
     */
    event BidPlaced(
        uint256 indexed auctionId,
        address indexed bidder,
        uint256 amount,
        uint256 usdValue
    );

    /**
     * @notice 拍卖结束（成功或失败）
     */
    event AuctionEnded(
        uint256 indexed auctionId,
        address indexed winner,
        State state,
        uint256 winningBid
    );

     /**
     * @notice 拍卖被卖家取消（仅在 Pending 状态可取消）
     */
    event AuctionCancelled(uint256 indexed auctionId,uint256 cancelTime);

    // 修饰器
    /** 
     * @dev 检查调用者是给定拍卖的卖家
     */
    modifier onlySeller(uint256 _auctionId) {
        require(auctions[_auctionId].seller == msg.sender, "Not seller");
        _;
    }

    /** 
     * @dev 检查拍卖处于特定状态
     */
    modifier auctionState(uint256 _auctionId, State _state) {
        require(auctions[_auctionId].state == _state, "Invalid state");
        _;
    }

    /** 
     * @dev 检查拍卖尚未结束
     */
    modifier auctionTime(uint256 _auctionId) {
        require(block.timestamp < auctions[_auctionId].endTime, "Auction ended");
        _;
    }

    /** 
     * @dev 检查拍卖 ID 有效
     */
    modifier auctionExists(uint256 _auctionId) {
        require(_auctionId > 0 && _auctionId <= auctionCount, "Invalid auctionId");
        _;
    }

    constructor() {
        // 禁止通过合约逻辑初始化，必须通过 initialize 函数初始化
       _disableInitializers();
    }

     /**
     * @notice 合约初始化（代替构造函数，用于 UUPS 代理模式）
     * @param _ethUsdFeed  ETH/USD Chainlink 价格聚合器地址
     * @param _erc20UsdFeed 全局默认 ERC20/USD 价格聚合器地址
     */
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


    /**
     * @notice 创建一个新的拍卖，并将 NFT 转入本合约托管
     * @param _nftContract    待拍卖 NFT 的合约地址
     * @param _tokenId        待拍卖 NFT 的 tokenId
     * @param _startPrice     起拍价（以 bidToken 的最小单位表示）
     * @param _duration       拍卖持续时间（秒），范围 [1小时, 3天]
     * @param _bidToken       出价代币地址，address(0) 表示 ETH
     * @param _erc20PriceFeed 该拍卖专用的 ERC20/USD 价格聚合器地址，若为 address(0) 则使用全局默认
     */
    function createAuction(
        address _nftContract,
        uint256 _tokenId,
        uint256 _startPrice,
        uint256 _duration,
        address _bidToken,
        address _erc20PriceFeed
        ) external {
            
            // 起拍价必须大于 0
            require(_startPrice > 0, "Start price > 0");
            // 持续时间必须在 1 小时到 3 天之间
            require(_duration >= 1 hours && _duration <= 3 days, "Duration 1h~3d");

            // 如果指定了 ERC20 代币，验证其是否合法（能否调用 decimals）
            if (_bidToken != address(0)) {
                try IERC20Metadata(_bidToken).decimals() returns (uint8) {
                    // 如果能成功调用 decimals()，说明是一个有效的 ERC20 代币
                } catch {
                    revert("Invalid ERC20 token");
                }
            }

            // 获取 NFT 合约接口
            IERC721 nft = IERC721(_nftContract);
            // 确保卖家是 NFT 的拥有者
            require(nft.ownerOf(_tokenId) == msg.sender, "Not owner");
            // 确保 NFT 已经授权给本合约（approve 或 setApprovalForAll）   
            require(nft.getApproved(_tokenId) == address(this) || 
                    nft.isApprovedForAll(msg.sender, address(this)), 
            "NFT not approved for this contract");

            // 将 NFT 转移到合约地址 , 防止多次拍卖
            nft.safeTransferFrom(msg.sender, address(this), _tokenId);

            auctionCount++;
            auctions[auctionCount] = Auction({
                seller: msg.sender,
                nftContract: _nftContract,
                tokenId: _tokenId,
                startPrice: _startPrice,
                duration: _duration,
                endTime: 0,                                    // 由 startAuction 设置
                highestBidder: address(0),
                highestBid: 0,
                highestBidValueUsd: 0,
                state: State.Pending,
                bidToken: _bidToken,
                erc20PriceFeed: _erc20PriceFeed,               // 记录该拍卖的独立价格源
                nftClaimed: false                              // 初始未提取
            });

            // 发送创建事件
            emit AuctionCreated(auctionCount, msg.sender, _tokenId, _startPrice, _duration, 0, State.Pending);
        }


    /**
     * @notice 卖家启动拍卖（从 Pending 状态进入 Active 状态）
     * @param _auctionId 拍卖 ID
     */
    function startAuction(uint256 _auctionId) 
        external 
        onlySeller(_auctionId)
        auctionState(_auctionId, State.Pending) 
        auctionExists(_auctionId) {
        Auction storage auction = auctions[_auctionId];

        auction.endTime = block.timestamp + auction.duration;
        auction.state = State.Active;

        emit AuctionStarted(_auctionId, auction.endTime);
    }

     /**
     * @notice 参与竞拍，支持 ETH 和 ERC20 代币出价
     * @dev 美元价值比较采用当前价格统一计算，避免价格波动导致比较不公
     * @param _auctionId 拍卖 ID
     * @param _amount    出价金额（代币最小单位），ETH 出价时必须与 msg.value 一致
     */
    function placeBid (uint256 _auctionId,uint256 _amount) 
        external 
        auctionState(_auctionId, State.Active)
        auctionTime(_auctionId)
        auctionExists(_auctionId) 
        payable {
            Auction storage auction = auctions[_auctionId];
            // 卖家不能给自己的拍卖出价
            require(msg.sender != auction.seller, "Seller cannot bid");

            address bidToken = auction.bidToken;
            uint256 receivedAmount;

            if (bidToken == address(0)) {
                // ETH 出价
                // 发送的 ETH 必须与 _amount 参数一致
                 require(msg.value == _amount, "ETH amount mismatch");
                require(msg.value > 0, "Bid must be > 0");
                receivedAmount = msg.value;
            } else {
                // ERC20 出价
                require(msg.value == 0, "No ETH");
                require(_amount > 0, "Bid amount must be > 0");
                IERC20Metadata token = IERC20Metadata(bidToken);
                require(token.allowance(msg.sender, address(this)) >= _amount, "Allowance too low");
                require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
                receivedAmount = _amount;
            }

           (uint256 usdValue, address previousBidder, uint256 previousAmount) = _evaluateBid(auction, receivedAmount);

            // 更新最高出价信息
            auction.highestBidder = msg.sender;
            auction.highestBid = receivedAmount;
            auction.highestBidValueUsd = usdValue;    // 记录

            // 如果之前有出价者，将其出价金额加入待退款池
            if (previousBidder != address(0)) {
                pendingRefunds[previousBidder][bidToken] += previousAmount;
            }

            // 发出出价事件
            emit BidPlaced(_auctionId, msg.sender, receivedAmount, usdValue);
    }

    function _evaluateBid(Auction storage auction, uint256 receivedAmount) private view returns (uint256 usdValue, address previousBidder, uint256 previousAmount) {
        address bidToken = auction.bidToken;

        // 获取当前价格
        uint256 currentPrice;
        if (bidToken == address(0)) {
            currentPrice = getPriceInUsd(address(ethUsdPriceFeed));
        } else {
            address priceFeed = auction.erc20PriceFeed != address(0) ? auction.erc20PriceFeed : address(erc20UsdPriceFeed);
            currentPrice = getPriceInUsd(priceFeed);
        }

        // 代币小数位数
        uint256 decimals = bidToken == address(0) ? 18 : IERC20Metadata(bidToken).decimals();

        // 计算本次出价的美元价值
        usdValue = convertToUsdValue(receivedAmount, decimals, currentPrice);

        // 起拍价门槛
        uint256 startPriceUsd = convertToUsdValue(auction.startPrice, decimals, currentPrice);
        require(usdValue >= startPriceUsd, "Bid below start price");

        // 与当前最高出价比较（用统一价格重算）
        uint256 currentHighestUsd = 0;
        if (auction.highestBidder != address(0)) {
            currentHighestUsd = convertToUsdValue(auction.highestBid, decimals, currentPrice);
        }
        require(usdValue > currentHighestUsd, "Bid too low in USD value");

        // 返回旧最高出价者及其出价额，以便外部处理退款
        previousBidder = auction.highestBidder;
        previousAmount = auction.highestBid;
    }

    /**
     * @notice 结束拍卖（任何人都可调用），仅在拍卖时间截止后有效
     * @dev 成功拍卖：将资金转给卖家，NFT 仍保留在合约中，等待中标者调用 claimNFT 提取。
     *      失败拍卖（无出价）：NFT 仍然保留，由卖家调用 sellerRetrieveNFT 取回。
     *      本函数不再直接转移 NFT，避免因接收方合约问题导致交易回滚。
     * @param _auctionId 拍卖 ID
     */
    function endAuction(uint256 _auctionId) external virtual auctionExists(_auctionId) {
        Auction storage auction = auctions[_auctionId];
        // 确保拍卖已到结束时间
        require(block.timestamp >= auction.endTime, "Auction not ended");
        // 确保拍卖当前为 Active 状态
        require(auction.state == State.Active, "Auction not active");

        // 判断拍卖是否成功
        // 拍卖成功
        if (auction.highestBidder != address(0)) {
            // ---- 拍卖成功：转移资金给卖家 ----
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

            emit AuctionEnded(_auctionId, auction.highestBidder, State.Successful, auction.highestBid);
        } else {
            // ---- 拍卖失败：无任何出价，标记为 Failed ----
            auction.state = State.Failed;
            // NFT 仍归卖家，由卖家调用 sellerRetrieveNFT 取回
            emit AuctionEnded(_auctionId, address(0), State.Failed, 0);
        }
    }

    /**
     * @notice 卖家取消拍卖（仅限 Pending 状态）
     * @dev NFT 会返回给卖家，无需额外提取步骤
     * @param _auctionId 拍卖 ID
     */
    function cancelAuction(uint256 _auctionId) external 
        onlySeller(_auctionId) 
        auctionExists(_auctionId) 
        auctionState(_auctionId, State.Pending) {
            Auction storage auction = auctions[_auctionId];
            auction.state = State.Cancelled;

            // 标记为已提取
            auction.nftClaimed = true;

            // 退还 NFT 给卖家
            IERC721(auction.nftContract).safeTransferFrom(address(this), auction.seller, auction.tokenId);
            
            emit AuctionCancelled(_auctionId, block.timestamp);
            emit NFTClaimed(_auctionId, auction.seller);
        }

    /**
     * @notice 拍卖成功后，最高出价者提取 NFT
     * @dev 拍卖状态必须为 Successful 且 NFT 尚未被提取
     * @param _auctionId 拍卖 ID
     */
    function claimNFT(uint256 _auctionId) 
        external 
        auctionExists(_auctionId) 
    {
        Auction storage auction = auctions[_auctionId];
        // 拍卖必须成功结束
        require(auction.state == State.Successful, "Auction not successful");
        // 只有最高出价者可以提取
        require(msg.sender == auction.highestBidder, "Not highest bidder");
        // 防止重复提取
        require(!auction.nftClaimed, "NFT already claimed");

        // 标记为已提取
        auction.nftClaimed = true;

        // 安全转移 NFT 给中标者
        // 此时如果接收方合约无法接收 NFT，只会导致该提取交易失败，不影响其他状态
        IERC721(auction.nftContract).safeTransferFrom(address(this), msg.sender, auction.tokenId);

        emit NFTClaimed(_auctionId, msg.sender);
    }

    /**
     * @notice 拍卖失败或取消后，卖家取回 NFT
     * @dev 拍卖状态必须为 Failed 或 Cancelled 且 NFT 尚未被提取
     * @param _auctionId 拍卖 ID
     */
    function sellerRetrieveNFT(uint256 _auctionId) 
        external 
        auctionExists(_auctionId) 
    {
        Auction storage auction = auctions[_auctionId];
        // 只有拍卖失败或取消时卖家才能取回
        require(
            auction.state == State.Failed || auction.state == State.Cancelled,
            "Auction not failed or cancelled"
        );
        // 只有卖家可以调用
        require(msg.sender == auction.seller, "Not seller");
        // 防止重复提取
        require(!auction.nftClaimed, "NFT already retrieved");

        auction.nftClaimed = true;
        // 安全转移 NFT 给卖家
        IERC721(auction.nftContract).safeTransferFrom(address(this), msg.sender, auction.tokenId);

        emit NFTClaimed(_auctionId, msg.sender);
    }

    /**
     * @notice 用户提取被超过的出价退款（ETH 或 ERC20）
     * @param _bidToken 退款代币地址，address(0) 为 ETH
     */
    function claimRefund(address _bidToken) external {
        uint256 amount = pendingRefunds[msg.sender][_bidToken];
        require(amount > 0, "No refund");
        // 清零待退款，防止重入
        pendingRefunds[msg.sender][_bidToken] = 0;

        if (_bidToken == address(0)) {
            // 退还 ETH
            payable(msg.sender).sendValue(amount);
        } else {
            // 退还 ERC20
            require(IERC20(_bidToken).transfer(msg.sender, amount), "ERC20 refund failed");
        }
    }

    /**
     * @notice 从指定 Chainlink 价格聚合器获取最新价格
     * @param feed 价格聚合器地址
     * @return 价格（USD，8 位小数）
     */
    function getPriceInUsd(address feed) internal view returns (uint256) {
        // 获取最新轮次数据
        (, int price, , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        require(price > 0, "Invalid price");
        // 价格数据不能太旧（超过 1 小时视为无效）
        require(updatedAt + 1 hours > block.timestamp, "Stale price");
        return uint256(price);
    }


    /**
     * @notice 将代币数量换算为美元价值
     * @param amount         代币数量（最小单位）
     * @param tokenDecimals  代币小数位数
     * @param priceInUsd     代币的 USD 价格（8 位小数）
     * @return 美元价值（8 位小数）
     */
    function convertToUsdValue(uint256 amount, uint256 tokenDecimals, uint256 priceInUsd) internal pure returns (uint256) {
        // 公式：(amount * price) / (10^decimals)
        return (amount * priceInUsd) / (10 ** tokenDecimals);
    }
}