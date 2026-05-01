// 作用：用于测试合约升级（V2 版本）
// 你只需要加一个新功能，例如：
    // 新增 setFee() 设置手续费
    // 或新增 auctionCount 统计拍卖数量
// 目的：证明合约可以升级


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./NFTMarketAuction.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title NFTMarketAuctionV2
 * @notice 在 V1 基础上添加平台手续费功能，并沿用 V1 的 Pull 模式提取 NFT
 * @dev V2 新增功能：
 *      - 可设置手续费（基点，例如 100 = 1%）
 *      - 手续费自动累积到合约，owner 可随时提取
 *      - 拍卖结束时从卖家收款中扣除手续费
 *      - NFT 转移完全沿用 V1 的提取模式（买方调用 claimNFT，卖方调用 sellerRetrieveNFT）
 */
contract NFTMarketAuctionV2 is NFTMarketAuction {

    using Address for address payable;

    /// @notice 手续费基数，例如 100 表示 1%，250 表示 2.5%
    uint256 public feeBasisPoints; // 手续费基点，例如 100 = 1%
    /// @notice 待提取的手续费：代币地址 => 金额（address(0) 为 ETH）
    mapping(address => uint256) public pendingFees;
    /// @notice 标记 V2 是否已完成初始化
    bool private _v2Initialized = false;

    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeExtracted(address indexed token, uint256 amount, address indexed to);

    /**
     * @notice V2 初始化（仅限 owner 调用一次）
     * @param _feeBasisPoints 手续费基点，范围 0 ~ 10000（即 0% ~ 100%）
     */
    function initializeV2(uint256 _feeBasisPoints) external onlyOwner {
        require(!_v2Initialized, "V2 already initialized");
        require(_feeBasisPoints <= 10000, "Fee cannot exceed 100%"); // 限制手续费上限

        feeBasisPoints = _feeBasisPoints;
        _v2Initialized = true;

        emit FeeUpdated(0, _feeBasisPoints);
    }

    /**
     * @notice 重新设置手续费（owner 随时修改）
     * @param _feeBasisPoints 新的基点
     */
    function setFee(uint256 _feeBasisPoints) external onlyOwner {
        require(_feeBasisPoints <= 10000, "Fee cannot exceed 100%");
        uint256 oldFee = feeBasisPoints;
        feeBasisPoints = _feeBasisPoints;
        emit FeeUpdated(oldFee, _feeBasisPoints);
    }

    /**
     * @notice 覆盖 V1 的 endAuction，添加手续费扣除，并遵循 Pull 模式转移 NFT
     * @dev 成功拍卖：卖家收款 = (最高出价 - 手续费)，手续费累积到 pendingFees。
     *      失败拍卖：仅改变状态，不产生手续费。
     *      本函数不转移 NFT，买家或卖家需分别调用 claimNFT / sellerRetrieveNFT。
     */
    function endAuction(uint256 _auctionId) external override auctionExists(_auctionId) {
        Auction storage auction = auctions[_auctionId];
        require(block.timestamp >= auction.endTime, "Auction not ended");
        require(auction.state == State.Active, "Auction not active");


        if (auction.highestBidder != address(0)) {
            auction.state = State.Successful;

            uint256 totalBid = auction.highestBid;
            uint256 fee = 0;
            uint256 sellerAmount = totalBid;

            if (feeBasisPoints > 0) {
                fee = (totalBid * feeBasisPoints) / 10000;
                sellerAmount = totalBid - fee;
                require(sellerAmount > 0, "Fee exceeds bid amount");

                // 将手续费累积到 pendingFees（Pull 模式），避免直接转账给 owner 卡死
                pendingFees[auction.bidToken] += fee;
                emit FeeExtracted(auction.bidToken, fee, address(0)); // 记录手续费
            }

            // 将卖家的收入转入（直接转账，若卖家合约无法接收仍可能卡死，但可后续用 pull 改进）
            // 此处保持与 V1 相同的转账方式，风险同 V1
            if (auction.bidToken == address(0)) {
                payable(auction.seller).sendValue(sellerAmount);
            } else {
                require(IERC20(auction.bidToken).transfer(auction.seller, sellerAmount), "Seller payment failed");
            }

            // NFT 不在此转移，由中标者调用 claimNFT 提取（沿用 V1 Pull 模式）
            emit AuctionEnded(_auctionId, auction.highestBidder, State.Successful, totalBid);
        } else {
            // ---- 拍卖失败，无出价 ----
            auction.state = State.Failed;
            // NFT 由卖家调用 sellerRetrieveNFT 取回（沿用 V1 Pull 模式）
            emit AuctionEnded(_auctionId, address(0), State.Failed, 0);
        }
    }

    /**
     * @notice Owner 提取累积的手续费（Pull 模式）
     * @param _token 代币地址，address(0) 为 ETH
     */
    function extractFees(address _token) external onlyOwner {
        uint256 amount = pendingFees[_token];
        require(amount > 0, "No fees to extract");
        pendingFees[_token] = 0;

        if (_token == address(0)) {
            payable(owner()).sendValue(amount);
        } else {
            require(IERC20(_token).transfer(owner(), amount), "Fee transfer failed");
        }
        emit FeeExtracted(_token, amount, owner());
    }

    /**
     * @notice 查看当前手续费率（返回基点，避免精度丢失）
     */
    function getFeeBasisPoints() external view returns (uint256) {
        return feeBasisPoints;
    }
}
