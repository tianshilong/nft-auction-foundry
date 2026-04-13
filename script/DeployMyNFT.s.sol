// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MyNFT.sol";

contract DeployMyNFT is Script {
    // 部署入口函数：固定名称 run()
    function run() external returns (MyNFT) {
        // 1. 开启交易广播（发送链上交易）
        vm.startBroadcast();

        // 2. 部署 MyNFT 合约（无构造参数，直接部署）
        MyNFT myNFT = new MyNFT();

        // 3. 关闭广播 本地运行
        vm.stopBroadcast();

        console.log("MyNFT address:", address(myNFT));

        return myNFT;
    }
}