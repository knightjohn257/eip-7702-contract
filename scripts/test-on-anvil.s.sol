// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "src/BatchCallAndSponsor.sol";
import "src/MockERC20.sol";

/// 在 Anvil 上测试完整的 EIP-7702 流程
contract TestOnAnvil is Script {
    using ECDSA for bytes32;
    using console2 for *;

    function run() external {
        uint256 DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        uint256 A_PK = 0x7c87602173a284daa77c025f72c3f1203745e68f2d293c4c99a6ea33140d55c9;
        uint256 B_PK = 0x1b89c295df4524e1da8c041a03e7fd5e07057be8ea05e04eb16f95f2c8e9e2c0;

        vm.startBroadcast(DEPLOYER_PK);
        BatchCallAndSponsor impl = new BatchCallAndSponsor();
        MockERC20 token = new MockERC20(18);
        vm.stopBroadcast();

        address A = vm.addr(A_PK);
        address B = vm.addr(B_PK);
        address C = address(0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC);

        vm.deal(A, 100 ether);
        token.mint(A, 1000e18);

        console2.log("nonces(A) before:", impl.nonces(A));

        // 构造 calls
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0].to = address(token);
        calls[0].value = 0;
        calls[0].data = abi.encodeCall(IERC20.transfer, (C, 200e18));

        // 构造签名（与合约内部一致）
        bytes memory encodedCalls;
        for (uint256 i = 0; i < calls.length; i++) {
            encodedCalls = abi.encodePacked(
                encodedCalls,
                calls[i].to,
                calls[i].value,
                calls[i].data
            );
        }
        uint256 nonce = impl.nonces(A);
        bytes32 digest = keccak256(abi.encodePacked(nonce, encodedCalls));
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(digest);
        console2.log("digest hash:", digest);
        console2.log("ethSigned hash:", ethSignedMessageHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(A_PK, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);
        console2.log("v:", v, "r:", r, "s:", s);

        // 验证签名（不经过 7702）
        address recovered = ECDSA.recover(ethSignedMessageHash, signature);
        console2.log("recovered == A:", recovered == A);

        // EIP-7702 执行
        vm.startBroadcast(B_PK);
        vm.signAndAttachDelegation(address(impl), A_PK);

        try BatchCallAndSponsor(payable(A)).execute(calls, signature) {
            console2.log("SUCCESS!");
            console2.log("C token balance:", token.balanceOf(C));
            console2.log("nonces(A) after:", impl.nonces(A));
        } catch (bytes memory reason) {
            console2.log("FAILED!");
            console2.log("Revert:", string(reason));
        }
        vm.stopBroadcast();
    }
}
