# BatchCallAndSponsor — Go demo

`scripts/02-sponsored-demo.ts` 的 Go 移植版，行为与之一一对应：B 代付 gas，把 A 的
ERC20 代币转给 C，整个流程走 EIP-7702（type 0x04）+ EIP-712 typed-data 签名。

## 目录结构

```
go-demo/
├── go.mod
├── signer.go           # SignExecute / ExecuteRequestDigest（EIP-712 核心）
├── auth.go             # SignAuthorization（EIP-7702 authorization tuple）
├── tx.go               # SignSetCodeTx / SendAndWait（外层 0x04 交易）
├── nonce.go            # ReadContractNonce（staticcall A.nonce()，无 code 回退 0）
├── encoding.go         # ABI 拼 calldata（execute / ERC20.transfer）
├── compare.sh          # Go / TS 签名字节级一致性自动验证
└── cmd/
    ├── sponsored/      # 主 demo：B 代付，转 token 给 C
    └── compare/        # 用固定 fixture 输出 digest + signature，给 compare.sh 用
```

## 与合约的逐字节对齐

EIP-712 typehash 是签名最容易出错的地方。这里所有字符串都直接锚到合约源码：

| Go 文件 | 合约位置 |
|---|---|
| `signer.go` `domainName/Version` | `src/BatchCallAndSponsor.sol:65` `EIP712("BatchCallAndSponsor", "1")` |
| `signer.go` Types["Call"] | `src/BatchCallAndSponsor.sol:41` `_CALL_TYPEHASH` |
| `signer.go` Types["Execute"] | `src/BatchCallAndSponsor.sol:43-45` `_EXECUTE_TYPEHASH` |

`apitypes` 会按 EIP-712 规则自动拼出
`Execute(...)Call(...)` 这样的 encodeType 字符串，与合约里 `_EXECUTE_TYPEHASH` 的字面值完全一致。

## 跨语言签名一致性验证

```bash
cd go-demo
./compare.sh
```

会运行：

1. `go run ./cmd/compare` —— 用 `cmd/compare/fixture.go` 里的固定输入算签名
2. `npx tsx ../scripts/compare-signature.ts` —— TS 端用同一份 fixture 算签名
3. `diff` 两份输出

**期望**：两端 `digest` 与 `signature` 字节级完全一致（secp256k1 + RFC6979
是确定性签名，相同输入 → 相同 65 字节输出）。

实测输出（commit 时的 fixture）：
```
digest=0x8249cd6408801e430ba7d97c60cef76b24159ec110109e3ebd3f2f27cce87585
signature=0x1d69ab44af2bf4c242c68d50e0e3f363001ef4e4bc4a8c2072d23d7778710683005492d7b24852347f73cb94141da3ca29c8c000f4dc08ca77c52c55832dcb2a1c
```

任何字段（fixture 或合约 typehash）改动后再跑一次 `compare.sh`，diff 不一致就立刻定位。

## 运行主 demo

启动时自动从 **`go-demo/.env`** 读环境变量（不会去读上层目录的 `.env`，
两边可以独立配置）。命令行里已有的同名变量优先，便于临时覆盖。

```bash
cd go-demo
cp .env.example .env
# 编辑 .env，填好 RPC_URL / PRIVATE_KEY_A / PRIVATE_KEY_B
#                IMPLEMENTATION_ADDRESS / TOKEN_ADDRESS

go run ./cmd/sponsored
```

也支持完全靠系统环境变量跑，不需要 `.env`：

```bash
RPC_URL=... PRIVATE_KEY_A=0x... PRIVATE_KEY_B=0x... \
IMPLEMENTATION_ADDRESS=0x... TOKEN_ADDRESS=0x... \
go run ./cmd/sponsored
```

输出步骤镜像 TS demo：

```
[Step 1] 合约 nonce: 0
[Step 2] calls: token.transfer(C, 1230000000000000000)
[Step 3] A 的 tx nonce (用于 7702 auth): 0
[Step 3] ✅ 7702 authorization 已签
[Step 4] ✅ Execute 签名: 0x...
[Step 6] tx hash: 0x...
[Step 7] ✅ 成功，区块 #...
```

### BSC testnet 实跑 tx hash

| 时间 | tx hash | 备注 |
|---|---|---|
| 待补 | `0x________` | 首次 BSC testnet 跑通 |

> 跑通后把 tx hash 填回这一行；后续如果换 RPC / 合约重部署 / fixture 改动，再补一行即可。

## 注意事项

1. **三种 nonce，互不替代**
   - `client.PendingNonceAt(B)` —— B 这笔 0x04 tx 的网络层 nonce
   - `client.NonceAt(A)` —— 7702 authorization tuple 里那个 nonce（A 的 EOA tx 计数）
   - `ReadContractNonce(A)` —— 合约 storage 里的 nonce，防签名重放
2. **gas 估算**：`ethclient.EstimateGas` 不一定支持 AuthList（依赖 go-ethereum 版本），demo 里直接给固定 500000 gas。生产环境要么升级到含 PR #31198 的版本，要么固定值 + 监控。
3. **executor 必须等于 msg.sender**：`DEMO_EXECUTOR` 留空时，`cmd/sponsored/main.go` 自动用 B 的地址。如果你想让任意 relayer 都能代付，把 `executor` 改成 `0x0000...0000`。
4. **第一次代付**：A 还没委托过任何合约，`ReadContractNonce` 会返回 0，与合约里 `nonce` 变量的初始值无缝衔接。
