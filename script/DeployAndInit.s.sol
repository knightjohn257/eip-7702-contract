// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "src/BatchCallAndSponsor.sol";

/// @notice 部署 BatchCallAndSponsor implementation。
///
/// 默认 BSC Testnet（Pascal 硬分叉，BEP-441 / EIP-7702 已激活）：Chain ID = 97。
/// 走 CREATE2 + 固定 salt，相同源码在所有支持 prague EVM 的链上得到同一地址，
/// 让 7702 授权的 contractAddress 字段可以跨链统一。
///
/// 用法：
///   cp .env.example .env  # 填 PRIVATE_KEY_DEPLOYER + EXPECTED_CHAIN_ID + DEPLOY_SALT
///   forge script script/DeployAndInit.s.sol \
///     --rpc-url bsc_testnet \
///     --broadcast
contract DeployAndInitScript is Script {
    /// @dev 通过 env 校验当前 RPC 是否对得上预期链；防止误把 implementation 推到主网
    function _assertChainId() internal view {
        // 缺省 = 97（BSC testnet）；显式 0 = 跳过校验
        uint256 expected = vm.envOr("EXPECTED_CHAIN_ID", uint256(97));
        if (expected != 0) {
            require(block.chainid == expected, "Wrong chainId for this RPC");
        }
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY_DEPLOYER");
        address deployer = vm.addr(deployerKey);

        _assertChainId();

        // 默认 salt = keccak256("BatchCallAndSponsor.v1")，可由 env 覆盖
        bytes32 salt = vm.envOr(
            "DEPLOY_SALT",
            keccak256("BatchCallAndSponsor.v1")
        );

        console2.log(unicode"=== BatchCallAndSponsor 部署 ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.logBytes32(salt);

        vm.startBroadcast(deployerKey);
        BatchCallAndSponsor impl = new BatchCallAndSponsor{salt: salt}();
        vm.stopBroadcast();

        // sanity check：implementation 直接调用 nonce()，应该返回 0
        require(impl.nonce() == 0, "post-deploy: nonce() should be 0");

        console2.log("BatchCallAndSponsor deployed at:", address(impl));
        console2.log(unicode"\n==========================================");
        console2.log(unicode"  部署完成！请将以下地址填入 .env：");
        console2.log("==========================================");
        console2.log("IMPLEMENTATION_ADDRESS=", address(impl));
    }
}
