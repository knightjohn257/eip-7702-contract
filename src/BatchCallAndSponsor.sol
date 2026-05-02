// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title BatchCallAndSponsor
 * @notice EIP-7702 批量调用 + gas 代付 implementation。
 *
 * 安全模型 v2：
 *  1. EIP-712 typed data：digest 自动绑定 chainId + verifyingContract = A，杜绝跨链 / 跨地址重放。
 *  2. deadline：签名过期时间，避免老签名永久有效。
 *  3. executor：可指定唯一允许提交者，避免任意人在 mempool 抢跑代付。
 *  4. 严格 CEI：先校验 → 写 nonce → 调外部。
 *  5. nonReentrant（transient storage，EIP-1153）：禁止 batch 内回调本合约。
 *  6. 透传内部 revert reason；遇到 ERC20 风格 false 返回值时主动失败。
 *  7. implementation 自身禁止收 ETH / 接 fallback；只允许 7702 委托后的 EOA 上下文。
 *  8. _encodeCalls 用结构化 EIP-712 hash，避免 abi.encodePacked 的 bytes 拼接歧义。
 *
 * 使用方式：
 *  - A 用 EOA 私钥按 EIP-712 对 (calls, nonce, deadline, executor) 做 typed-data 签名。
 *  - B（relayer）调用 A.execute(calls, deadline, executor, signature)，B 付 gas。
 *  - 7702 委托使 address(this) = A，签名 verifyingContract 也是 A → 一一对应。
 */
contract BatchCallAndSponsor is EIP712, ReentrancyGuardTransient {
    using ECDSA for bytes32;

    /// @dev implementation 自身的部署地址，只在合约 code 里。
    ///      运行时若 address(this) == _IMPLEMENTATION 即"被直接调用"（非 7702 委托），需拒绝资产相关入口。
    address private immutable _IMPLEMENTATION;

    /// @notice 防 replay 用 nonce。EIP-7702 委托时此变量在 EOA(A) 的 storage slot 0。
    /// @dev    外部读取请直接对 A.nonce() 做 staticcall（A 必须已授权过本合约一次，否则 A 上无 code，
    ///         此时直接以 0 作为 nonce 即可）。
    uint256 public nonce;

    struct Call {
        address to;     // 目标合约
        uint256 value;  // 转 ETH wei
        bytes data;     // calldata
    }

    bytes32 private constant _CALL_TYPEHASH =
        keccak256("Call(address to,uint256 value,bytes data)");

    /// @dev EIP-712 复合类型 hash：尾部必须按 ASCII 升序追加引用类型定义
    bytes32 private constant _EXECUTE_TYPEHASH = keccak256(
        "Execute(Call[] calls,uint256 nonce,uint256 deadline,address executor)Call(address to,uint256 value,bytes data)"
    );

    event CallExecuted(address indexed sender, address indexed to, uint256 value, bytes data);
    event BatchExecuted(uint256 indexed nonce, uint256 callsCount);

    error InvalidSignature();
    error DeadlineExpired(uint256 deadline);
    error WrongExecutor(address expected, address actual);
    error CallReturnedFalse(uint256 index);
    error UnauthorizedSelfCall();
    error DirectImplementationCall();

    constructor() EIP712("BatchCallAndSponsor", "1") {
        _IMPLEMENTATION = address(this);
    }

    // ───────────────────────────────────────────────────────────────────────
    // 公开接口
    // ───────────────────────────────────────────────────────────────────────

    /**
     * @notice 带签名的批量执行（B 代付 gas）。
     * @param calls     调用列表
     * @param deadline  unix 秒，> 该时间则拒绝
     * @param executor  允许提交者（msg.sender）；address(0) 表示任意 relayer 可代付
     * @param signature A 对 EIP-712 typed data 的签名（65 bytes，r||s||v）
     */
    function execute(
        Call[] calldata calls,
        uint256 deadline,
        address executor,
        bytes calldata signature
    ) external payable nonReentrant {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        if (executor != address(0) && msg.sender != executor) {
            revert WrongExecutor(executor, msg.sender);
        }

        uint256 currentNonce = nonce;
        bytes32 digest = _executeRequestDigest(calls, currentNonce, deadline, executor);
        address recovered = ECDSA.recover(digest, signature);
        if (recovered != address(this)) revert InvalidSignature();

        // EFFECTS（先写 nonce 再 INTERACTIONS，配合 nonReentrant 双层防御）
        unchecked {
            nonce = currentNonce + 1;
        }

        _executeBatch(calls, currentNonce);
    }

    /**
     * @notice A 自己执行（无签名）。要求 msg.sender == address(this)，即 A 直接调用 A。
     *         可用于 A 主动作废所有未广播的签名（执行空 batch 即可让 nonce++）。
     */
    function execute(Call[] calldata calls) external payable nonReentrant {
        if (msg.sender != address(this)) revert UnauthorizedSelfCall();

        uint256 currentNonce = nonce;
        unchecked {
            nonce = currentNonce + 1;
        }
        _executeBatch(calls, currentNonce);
    }

    /// @notice 链下计算 digest（不消耗 gas，便于 client 对账）
    function executeRequestDigest(
        Call[] calldata calls,
        uint256 currentNonce,
        uint256 deadline,
        address executor
    ) external view returns (bytes32) {
        return _executeRequestDigest(calls, currentNonce, deadline, executor);
    }

    /// @notice 暴露 EIP-712 domain separator（在 7702 委托上下文中读到的是绑定到 A 的）
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ───────────────────────────────────────────────────────────────────────
    // 内部
    // ───────────────────────────────────────────────────────────────────────

    function _executeRequestDigest(
        Call[] calldata calls,
        uint256 currentNonce,
        uint256 deadline,
        address executor
    ) internal view returns (bytes32) {
        bytes32 callsHash = _hashCalls(calls);
        bytes32 structHash = keccak256(
            abi.encode(_EXECUTE_TYPEHASH, callsHash, currentNonce, deadline, executor)
        );
        return _hashTypedDataV4(structHash);
    }

    function _hashCall(Call calldata c) internal pure returns (bytes32) {
        return keccak256(abi.encode(_CALL_TYPEHASH, c.to, c.value, keccak256(c.data)));
    }

    function _hashCalls(Call[] calldata calls) internal pure returns (bytes32) {
        uint256 len = calls.length;
        bytes32[] memory hashes = new bytes32[](len);
        for (uint256 i = 0; i < len; ++i) {
            hashes[i] = _hashCall(calls[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _executeBatch(Call[] calldata calls, uint256 currentNonce) internal {
        uint256 len = calls.length;
        for (uint256 i = 0; i < len; ++i) {
            _executeCall(calls[i], i);
        }
        emit BatchExecuted(currentNonce, len);
    }

    function _executeCall(Call calldata c, uint256 index) internal {
        (bool success, bytes memory ret) = c.to.call{value: c.value}(c.data);

        if (!success) {
            // 透传内部 revert 数据（标准 Error(string) / 自定义 error 都能看到）
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert("Call reverted");
        }

        // SafeERC20 风格：返回恰好 32 bytes 且解码为 false → 视为失败
        // 容忍 0 字节（多数转 ETH 或不返回 bool 的合约）和长度非 32 的复杂返回（不强制约束）
        if (ret.length == 32 && !abi.decode(ret, (bool))) {
            revert CallReturnedFalse(index);
        }

        emit CallExecuted(msg.sender, c.to, c.value, c.data);
    }

    // ───────────────────────────────────────────────────────────────────────
    // 直接调用 implementation 时拒收 ETH / 拒接未知函数
    //  - 7702 委托后 address(this) = A → 条件不触发，正常运行
    //  - 直接调用 implementation → 触发 revert，避免 ETH 永久卡死
    // ───────────────────────────────────────────────────────────────────────

    receive() external payable {
        if (address(this) == _IMPLEMENTATION) revert DirectImplementationCall();
    }

    fallback() external payable {
        if (address(this) == _IMPLEMENTATION) revert DirectImplementationCall();
    }
}
