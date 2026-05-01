// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MyNFT.sol";

/**
 * @title DeployMyNFT
 * @notice 部署 MyNFT 合约，并可选地为部署者领取一个测试 NFT
 */
contract DeployMyNFT is Script {
    function run() external returns (MyNFT) {
        // 1. 开始广播（上链交易）
        vm.startBroadcast();

        // 2. 部署 MyNFT
        MyNFT myNFT = new MyNFT();

        // 3. 可选：部署后立即给部署者 mint 一个测试 NFT（免费）
        myNFT.claimTestNFT();
        console.log("Test NFT minted to deployer");

        // 4. 停止广播
        vm.stopBroadcast();

        console.log("MyNFT deployed at:", address(myNFT));
        return myNFT;
    }
}