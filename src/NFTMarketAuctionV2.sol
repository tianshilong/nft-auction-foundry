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

contract NFTMarketAuctionV2 is NFTMarketAuction {

    using Address for address payable;

    uint256 public feeBasisPoints; // 手续费基点，例如 100 = 1%
    bool private _v2Initialized = false;

    event FeeUpdated(uint256 newFeeBasisPoints);
    event FeeCollected(uint256 auctionId, uint256 feeAmount, address feeRecipient);

    function initializeV2(uint256 _feeBasisPoints) external onlyOwner {
        require(!_v2Initialized, "V2 already initialized");
        require(_feeBasisPoints <= 10000, "Fee cannot exceed 100%"); // 限制手续费上限

        feeBasisPoints = _feeBasisPoints;
        _v2Initialized = true;

        emit FeeUpdated(_feeBasisPoints);
    }

    function setFee(uint256 _feeBasisPoints) external onlyOwner {
        require(_feeBasisPoints <= 10000, "Fee cannot exceed 100%");
        feeBasisPoints = _feeBasisPoints;
        emit FeeUpdated(_feeBasisPoints);
    }

    function endAuction(uint256 _auctionId) external override auctionExists(_auctionId) auctionState(_auctionId, State.Active) {
        Auction storage auction = auctions[_auctionId];
        require(block.timestamp >= auction.endTime,"Auction not ended");

        if (auction.highestBidder != address(0)) {
            auction.state = State.Successful;

            uint256 totalBid = auction.highestBid;
            uint256 sellerAmount = totalBid;
            uint256 fee = 0;

            if (feeBasisPoints > 0) {
                fee = (totalBid * feeBasisPoints) / 10000;
                sellerAmount = totalBid - fee;
                require(sellerAmount > 0, "Fee exceeds bid amount");


                if (auction.bidToken == address(0)) {
                    payable(owner()).sendValue(fee);
                } else {
                    require(IERC20(auction.bidToken).transfer(owner(), fee), "Fee transfer failed");
                }
                emit FeeCollected(_auctionId, fee, owner());
            }

            if (auction.bidToken == address(0)) {
                payable(auction.seller).sendValue(sellerAmount);
            } else {
                require(IERC20(auction.bidToken).transfer(auction.seller, sellerAmount), "Seller payment failed");
            }

            IERC721(auction.nftContract).safeTransferFrom(address(this), auction.highestBidder, auction.tokenId);
            emit AuctionEnded(_auctionId, auction.highestBidder, State.Successful, totalBid);
        } else {
            IERC721(auction.nftContract).safeTransferFrom(address(this), auction.seller, auction.tokenId);
            auction.state = State.Failed;
            emit AuctionEnded(_auctionId, address(0), State.Failed, 0);
        }
    }

    function getFeePercentage() external view returns (uint256) {
        return feeBasisPoints / 100; // 转换为百分比（例如 100 → 1%）
    }
         
}