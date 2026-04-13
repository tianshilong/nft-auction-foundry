// SPDX-License-Identifier: UNLICENSEC
pragma solidity ^0.8.24;

// Foundry 核心脚本库
import "forge-std/Script.sol";
import "forge-std/console.sol";

// 导入拍卖合约
import {NFTMarketAuction} from "../src/NFTMarketAuction.sol";
import {NFTMarketAuctionV2} from "../src/NFTMarketAuctionV2.sol";
// UUPS 代理标准合约
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployAuctionUUPS is Script {

    NFTMarketAuction public auctionV1;
    NFTMarketAuctionV2 public auctionV2;

    address public proxy;

    address public constant ETH_USD = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address public constant USDC_USD = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E;

    // 官方标准格式
    function setUp() public {}

    function run() public {
        // 开启广播：上链执行
        vm.startBroadcast();

        // 1. 部署 V1 逻辑合约
        auctionV1 = new NFTMarketAuction();

        // 2. 编码初始化函数参数
        bytes memory initializeData = abi.encodeWithSignature(
            "initialize(address,address)",
            ETH_USD,
            USDC_USD
        );

        // 3. 部署 UUPS 代理合约，并初始化
        ERC1967Proxy proxyContract = new ERC1967Proxy(
            address(auctionV1),
            initializeData
        );
        proxy = address(proxyContract);

        // 4. 部署 V2 逻辑合约
        auctionV2 = new NFTMarketAuctionV2();

        // 5. 升级代理到 V2（使用 OZ5.x 官方唯一函数）
        NFTMarketAuction(proxy).upgradeToAndCall(address(auctionV2), "");

        // 6. 初始化 V2 手续费 1%
        NFTMarketAuctionV2(proxy).initializeV2(100);

        // 关闭广播
        vm.stopBroadcast();

        // ==================== 打印日志（纯英文，无报错） ====================
        console.log("================ Deploy Success ================");
        console.log("Proxy Address:", proxy);
        console.log("Auction V1 Address:", address(auctionV1));
        console.log("Auction V2 Address:", address(auctionV2));
        console.log("Platform Fee: 1%");
    }
}