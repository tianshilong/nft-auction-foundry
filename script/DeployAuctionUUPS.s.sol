// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {NFTMarketAuction} from "../src/NFTMarketAuction.sol";
import {NFTMarketAuctionV2} from "../src/NFTMarketAuctionV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

contract DeployAuctionUUPS is Script {
    // Sepolia 真实预言机地址
    address constant ETH_USD_SEPOLIA = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant USDC_USD_SEPOLIA = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    address public proxy;

    function setUp() public {}

    function run() external returns (address) {
        // 确定预言机地址
        (address ethFeed, address erc20Feed) = getPriceFeeds();

        vm.startBroadcast();

        // 1. 部署 V1
        NFTMarketAuction v1 = new NFTMarketAuction();

        // 2. 初始化数据
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address)", ethFeed, erc20Feed
        );

        // 3. 代理
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(v1), initData);
        proxy = address(proxyContract);
        console.log("Proxy deployed:", proxy);

        // 4. 部署 V2 并升级
        NFTMarketAuctionV2 v2 = new NFTMarketAuctionV2();
        NFTMarketAuction(proxy).upgradeToAndCall(address(v2), "");
        console.log("Upgraded to V2");

        // 5. 初始化 V2
        NFTMarketAuctionV2(proxy).initializeV2(100);

        vm.stopBroadcast();

        console.log("EthFeed used:", ethFeed);
        console.log("Erc20Feed used:", erc20Feed);
        return proxy;
    }

    // ---------- 根据链 ID 自动选择预言机 ----------
    function getPriceFeeds() internal returns (address ethFeed, address erc20Feed) {
        uint256 chainId = block.chainid;

        if (chainId == 31337) {
            // 本地 Anvil 网络 → 部署 Mock
            vm.startBroadcast(); // Mock 部署需要广播
            MockV3Aggregator ethMock = new MockV3Aggregator(8, 2000e8); // ETH = $2000
            MockV3Aggregator erc20Mock = new MockV3Aggregator(8, 1e8);  // USDC = $1
            vm.stopBroadcast();

            ethFeed = address(ethMock);
            erc20Feed = address(erc20Mock);
            console.log("Mock EthFeed deployed:", ethFeed);
            console.log("Mock Erc20Feed deployed:", erc20Feed);
        } else if (chainId == 11155111) {
            // Sepolia 测试网
            ethFeed = ETH_USD_SEPOLIA;
            erc20Feed = USDC_USD_SEPOLIA;
        } else {
            revert("Unsupported chain, deploy on Sepolia or local anvil");
        }
    }
}