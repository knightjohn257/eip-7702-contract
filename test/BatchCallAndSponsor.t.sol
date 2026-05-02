// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "src/BatchCallAndSponsor.sol";
import "src/MockERC20.sol";

/// @notice 一个故意返回 false 的非标 ERC20，用于校验合约的 SafeERC20 风格检查
contract FalseReturningToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice revert 时带自定义 reason 的 mock，用于校验 revert 透传
contract RevertingTarget {
    error CustomBoom(uint256 code);

    function boom(uint256 code) external pure {
        revert CustomBoom(code);
    }
}

/// @title BatchCallAndSponsor v2 测试
/// @notice 覆盖 EIP-712 签名、deadline、executor、replay、revert 透传、return-value 等所有安全分支
contract BatchCallAndSponsorTest is Test {
    BatchCallAndSponsor public implementation;
    MockERC20 public token;

    // PK 由测试自己生成，地址由 vm.addr 派生 — 杜绝 PK / 地址不匹配的脏数据
    uint256 internal A_PK = uint256(keccak256("BatchCallAndSponsor.test.A"));
    uint256 internal B_PK = uint256(keccak256("BatchCallAndSponsor.test.B"));
    address payable internal A;
    address internal B;
    address internal C = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    bytes32 private constant CALL_TYPEHASH =
        keccak256("Call(address to,uint256 value,bytes data)");
    bytes32 private constant EXECUTE_TYPEHASH = keccak256(
        "Execute(Call[] calls,uint256 nonce,uint256 deadline,address executor)Call(address to,uint256 value,bytes data)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function setUp() external {
        implementation = new BatchCallAndSponsor();
        token = new MockERC20(18);

        A = payable(vm.addr(A_PK));
        B = vm.addr(B_PK);

        vm.deal(A, 100 ether);
        vm.deal(B, 10 ether);
        token.mint(A, 1000e18);
    }

    // ───────────────────────────────────────────────────────────────────
    // 辅助：手动算 EIP-712 digest（domain.verifyingContract = A）
    // ───────────────────────────────────────────────────────────────────

    function _hashCall(BatchCallAndSponsor.Call memory c) internal pure returns (bytes32) {
        return keccak256(abi.encode(CALL_TYPEHASH, c.to, c.value, keccak256(c.data)));
    }

    function _hashCalls(BatchCallAndSponsor.Call[] memory calls) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; ++i) {
            hashes[i] = _hashCall(calls[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("BatchCallAndSponsor")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
    }

    function _digest(
        address verifyingContract,
        BatchCallAndSponsor.Call[] memory calls,
        uint256 nonce_,
        uint256 deadline,
        address executor
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_TYPEHASH, _hashCalls(calls), nonce_, deadline, executor)
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(verifyingContract), structHash));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _readNonce(address a) internal view returns (uint256) {
        if (a.code.length == 0) return 0;
        return BatchCallAndSponsor(payable(a)).nonce();
    }

    /// @dev 把 implementation 的运行时代码注入 A 的地址，等价于 A 已被 7702 委托。
    ///      forge 1.6 test 模式下 signAndAttachDelegation 仅对下一笔 broadcast tx 生效，
    ///      故此处用 vm.etch；immutable 烘焙在 code 里，_IMPLEMENTATION 仍指向真正的 impl。
    function _delegateA() internal {
        vm.etch(A, address(implementation).code);
    }

    // ───────────────────────────────────────────────────────────────────
    // 场景 1：B 代付，转 ERC20 给 C
    // ───────────────────────────────────────────────────────────────────

    function test_SponsoredExecution_TransferERC20() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 200e18))
        });

        _delegateA();

        uint256 nonce_ = _readNonce(A);
        uint256 deadline = block.timestamp + 1 hours;
        address executor = B;
        bytes memory sig = _sign(A_PK, _digest(A, calls, nonce_, deadline, executor));

        vm.prank(B);
        BatchCallAndSponsor(A).execute(calls, deadline, executor, sig);

        assertEq(token.balanceOf(C), 200e18, "C should receive 200 tokens");
        assertEq(token.balanceOf(A), 800e18, "A should have 800 left");
        assertEq(_readNonce(A), 1, "nonce++");
    }

    // ───────────────────────────────────────────────────────────────────
    // 场景 2：批量转 ETH + ERC20
    // ───────────────────────────────────────────────────────────────────

    function test_SponsoredExecution_BatchETHAndERC20() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](2);
        calls[0] = BatchCallAndSponsor.Call({to: C, value: 0.5 ether, data: ""});
        calls[1] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 50e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, B));

        vm.prank(B);
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);

        assertEq(C.balance, 0.5 ether, "C ETH");
        assertEq(token.balanceOf(C), 50e18, "C token");
    }

    // ───────────────────────────────────────────────────────────────────
    // 场景 3：A 自调用版本（msg.sender == address(this)）
    // ───────────────────────────────────────────────────────────────────

    function test_DirectExecution_BySelf() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 100e18))
        });

        _delegateA();
        vm.prank(A);
        BatchCallAndSponsor(A).execute(calls);

        assertEq(token.balanceOf(C), 100e18);
        assertEq(_readNonce(A), 1);
    }

    function test_DirectExecution_Revert_NotSelf() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](0);
        _delegateA();

        vm.prank(B);
        vm.expectRevert(BatchCallAndSponsor.UnauthorizedSelfCall.selector);
        BatchCallAndSponsor(A).execute(calls);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 1：replay 保护（nonce 已增）
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_ReplayAttack() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 10e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, B));

        vm.prank(B);
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);

        // 第二次：nonce 已涨为 1，旧签名失效
        vm.prank(B);
        vm.expectRevert(BatchCallAndSponsor.InvalidSignature.selector);
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 2：deadline 过期
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_DeadlineExpired() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 1e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 60;
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, B));

        vm.warp(deadline + 1);

        vm.prank(B);
        vm.expectRevert(
            abi.encodeWithSelector(BatchCallAndSponsor.DeadlineExpired.selector, deadline)
        );
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 3：executor 不匹配
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_WrongExecutor() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 1e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        // 签名指定 executor = B
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, B));

        // 用 C 提交（不是 B）
        vm.prank(C);
        vm.expectRevert(
            abi.encodeWithSelector(BatchCallAndSponsor.WrongExecutor.selector, B, C)
        );
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 4：executor=0 表示任意 relayer
    // ───────────────────────────────────────────────────────────────────

    function test_Executor_Zero_AllowsAnyone() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 5e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, address(0)));

        // 用任意账户提交都应通过
        address randomRelayer = address(0xBEEF);
        vm.deal(randomRelayer, 1 ether);
        vm.prank(randomRelayer);
        BatchCallAndSponsor(A).execute(calls, deadline, address(0), sig);

        assertEq(token.balanceOf(C), 5e18);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 5：错误签名（非 A 私钥）
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_WrongSignature() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 1e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(B_PK, _digest(A, calls, 0, deadline, B));

        vm.prank(B);
        vm.expectRevert(BatchCallAndSponsor.InvalidSignature.selector);
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 6：跨链重放无效（在虚构 chainId 下签）
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_CrossChainReplay() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 1e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 fakeDomain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("BatchCallAndSponsor")),
                keccak256(bytes("1")),
                uint256(999), // 不同 chainId
                A
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_TYPEHASH, _hashCalls(calls), uint256(0), deadline, B)
        );
        bytes32 fakeDigest = keccak256(abi.encodePacked("\x19\x01", fakeDomain, structHash));
        bytes memory sig = _sign(A_PK, fakeDigest);

        vm.prank(B);
        vm.expectRevert(BatchCallAndSponsor.InvalidSignature.selector);
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 7：透传内部 revert reason
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_BubblesUpReason() external {
        RevertingTarget target = new RevertingTarget();

        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(target),
            value: 0,
            data: abi.encodeCall(RevertingTarget.boom, (42))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, B));

        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(RevertingTarget.CustomBoom.selector, uint256(42)));
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 8：ERC20 风格返回 false → CallReturnedFalse
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_ERC20ReturnFalse() external {
        FalseReturningToken bad = new FalseReturningToken();

        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(bad),
            value: 0,
            data: abi.encodeWithSignature("transfer(address,uint256)", C, 1e18)
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, B));

        vm.prank(B);
        vm.expectRevert(abi.encodeWithSelector(BatchCallAndSponsor.CallReturnedFalse.selector, uint256(0)));
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 9：直接打 ETH 给 implementation 应失败
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_DirectETHToImplementation() external {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory ret) = address(implementation).call{value: 0.1 ether}("");
        assertFalse(ok, "should revert");
        // 4 字节 selector 应等于 DirectImplementationCall
        bytes4 expected = BatchCallAndSponsor.DirectImplementationCall.selector;
        bytes4 got;
        // forge-lint: disable-next-line(unsafe-typecast)
        got = bytes4(ret);
        assertEq(got, expected, "should revert with DirectImplementationCall");
    }

    // ───────────────────────────────────────────────────────────────────
    // 安全 10：直接调 impl.execute(calls,...) — 无私钥能签出 verifyingContract = impl
    //          的有效签名；executor=0 让 executor 检查不阻断、考察签名校验本身
    // ───────────────────────────────────────────────────────────────────

    function test_Revert_DirectImplementationExecute() external {
        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 1e18))
        });

        uint256 deadline = block.timestamp + 1 hours;
        // 用 A 的私钥按 verifyingContract = impl 来签 — 但合约 require recovered == address(this) = impl
        // impl 没私钥 → 永远不可能恢复到 impl → InvalidSignature
        bytes memory sig = _sign(A_PK, _digest(address(implementation), calls, 0, deadline, address(0)));

        vm.expectRevert(BatchCallAndSponsor.InvalidSignature.selector);
        implementation.execute(calls, deadline, address(0), sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // Fuzz：任意 amount + 任意 nonce 偏移
    // ───────────────────────────────────────────────────────────────────

    function testFuzz_SponsoredTransfer(uint96 amount) external {
        amount = uint96(bound(uint256(amount), 1, 1000e18));

        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, uint256(amount)))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, deadline, B));

        uint256 cBefore = token.balanceOf(C);

        vm.prank(B);
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);

        assertEq(token.balanceOf(C), cBefore + amount, "C balance");
        assertEq(_readNonce(A), 1);
    }

    function testFuzz_WrongNonceFails(uint64 wrongNonce) external {
        vm.assume(wrongNonce != 0);

        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 1e18))
        });

        _delegateA();
        uint256 deadline = block.timestamp + 1 hours;
        // 用错误 nonce 签
        bytes memory sig = _sign(A_PK, _digest(A, calls, uint256(wrongNonce), deadline, B));

        vm.prank(B);
        vm.expectRevert(BatchCallAndSponsor.InvalidSignature.selector);
        BatchCallAndSponsor(A).execute(calls, deadline, B, sig);
    }

    function testFuzz_WrongDeadlineInDigest(uint256 signedDeadline) external {
        signedDeadline = bound(signedDeadline, block.timestamp + 1, type(uint64).max);
        uint256 callDeadline = block.timestamp + 1 hours;
        vm.assume(signedDeadline != callDeadline);

        BatchCallAndSponsor.Call[] memory calls = new BatchCallAndSponsor.Call[](1);
        calls[0] = BatchCallAndSponsor.Call({
            to: address(token),
            value: 0,
            data: abi.encodeCall(IERC20.transfer, (C, 1e18))
        });

        _delegateA();
        bytes memory sig = _sign(A_PK, _digest(A, calls, 0, signedDeadline, B));

        vm.prank(B);
        vm.expectRevert(BatchCallAndSponsor.InvalidSignature.selector);
        BatchCallAndSponsor(A).execute(calls, callDeadline, B, sig);
    }

    // ───────────────────────────────────────────────────────────────────
    // domain separator 一致性：合约 view 与手算应相等，且对 caller 敏感
    // ───────────────────────────────────────────────────────────────────

    function test_DomainSeparator_BoundToCaller() external {
        bytes32 onImpl = implementation.domainSeparator();
        assertEq(onImpl, _domainSeparator(address(implementation)));

        _delegateA();
        bytes32 onA = BatchCallAndSponsor(A).domainSeparator();
        assertEq(onA, _domainSeparator(A));

        assertTrue(onImpl != onA, "should differ across address(this)");
    }
}
