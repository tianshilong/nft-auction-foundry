// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {NFTMarketAuction} from "../src/NFTMarketAuction.sol";
import {NFTMarketAuctionV2} from "../src/NFTMarketAuctionV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title DeployAuctionUUPS
 * @notice 一键部署 UUPS 可升级的拍卖合约（V1 → V2）
 *         当前配置为 Sepolia 测试网预言机地址
 */
contract DeployAuctionUUPS is Script {

    // ---- Sepolia Chainlink 预言机地址 ----
    address public constant ETH_USD_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address public constant USDC_USD_SEPOLIA = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    address public proxy;   // 代理地址，方便外部读取

    function setUp() public {}

    function run() external returns (address) {
        vm.startBroadcast();

        // 1. 部署 V1 逻辑合约
        NFTMarketAuction v1 = new NFTMarketAuction();
        console.log("V1 Logic deployed at:", address(v1));

        // 2. 编码初始化参数（ETH/USD, ERC20/USD 预言机）
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)",
            ETH_USD_SEPOLIA,
            USDC_USD_SEPOLIA
        );

        // 3. 部署 UUPS 代理并指向 V1
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(v1), initData);
        proxy = address(proxyContract);
        console.log("Proxy deployed at:", proxy);

        // 4. 部署 V2 逻辑合约
        NFTMarketAuctionV2 v2 = new NFTMarketAuctionV2();
        console.log("V2 Logic deployed at:", address(v2));

        // 5. 升级代理到 V2
        NFTMarketAuction(proxy).upgradeToAndCall(address(v2), "");
        console.log("Proxy upgraded to V2");

        // 6. 初始化 V2（手续费设为 1%）
        NFTMarketAuctionV2(proxy).initializeV2(100);

        // 7. 验证 V2 初始化成功（手续费正确）
        uint256 fee = NFTMarketAuctionV2(proxy).getFeeBasisPoints();
        console.log("V2 fee basis points set to:", fee);
        require(fee == 100, "V2 init failed");

        vm.stopBroadcast();

        console.log("================ Deployment Summary ================");
        console.log("Proxy    :", proxy);
        console.log("V1 Logic :", address(v1));
        console.log("V2 Logic :", address(v2));
        console.log("Fee      :", fee, "basis points (1%)");

        return proxy;   // 返回代理地址，便于测试脚本捕获
    }
}