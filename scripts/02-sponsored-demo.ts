/**
 * 场景二：B 代付 gas，A 的 token 转移给 C  (v2 — EIP-712 + deadline + executor)
 *
 * BSC Testnet（Pascal 硬分叉，BEP-441 / EIP-7702 已激活）
 *
 * 完整流程：
 * 1. A 离线签 7702 授权（让 implementation 临时挂到 A 上）
 * 2. A 离线对 EIP-712 typed data (calls, nonce, deadline, executor) 做签名
 * 3. B 构造交易并广播：B 付 gas，msg.sender = B
 * 4. 合约验签 → 检查 deadline → 检查 executor → 写 nonce → 执行 calls
 *
 * 安全要点：
 * - 签名 verifyingContract = A 的地址（EIP-712 domain 强绑定）→ 跨链 / 跨地址重放被杜绝
 * - deadline：默认 10 分钟内有效，超时自动失效
 * - executor：可指定只允许 B 提交，避免别人在 mempool 抢跑
 * - nonce：从 A 自己的地址 staticcall 读取（首次 A 没 code 时回退到 0）
 *
 * 运行：
 *   cp .env.example .env
 *   # 填入 PRIVATE_KEY_A、PRIVATE_KEY_B、IMPLEMENTATION_ADDRESS、TOKEN_ADDRESS
 *   npm run dev:sponsored
 */

import "dotenv/config";
import {
  createWalletClient,
  http,
  encodeFunctionData,
  parseEther,
  publicActions,
  zeroAddress,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";
import { batchCallAbi, erc20Abi, eip712Domain, eip712Types } from "../src/abis.js";

// ── 配置 ─────────────────────────────────────────────────────────────────────

const chain = bscTestnet;
const RPC_URL = process.env.RPC_URL!;
if (!RPC_URL) {
  console.error("❌ 请设置 RPC_URL"); process.exit(1);
}

const A_PRIVATE_KEY = process.env.PRIVATE_KEY_A;
if (!A_PRIVATE_KEY) { console.error("❌ 请设置 PRIVATE_KEY_A"); process.exit(1); }

const B_PRIVATE_KEY = process.env.PRIVATE_KEY_B;
if (!B_PRIVATE_KEY) { console.error("❌ 请设置 PRIVATE_KEY_B"); process.exit(1); }

const implAddr = process.env.IMPLEMENTATION_ADDRESS;
if (!implAddr) { console.error("❌ 请设置 IMPLEMENTATION_ADDRESS"); process.exit(1); }
const IMPLEMENTATION_ADDRESS: `0x${string}` = implAddr as `0x${string}`;

const tokenAddr = process.env.TOKEN_ADDRESS;
if (!tokenAddr) { console.error("❌ 请设置 TOKEN_ADDRESS"); process.exit(1); }
const TOKEN_ADDRESS: `0x${string}` = tokenAddr as `0x${string}`;

const C_ADDRESS =
  (process.env.C_ADDRESS as `0x${string}`) ||
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

// 转账金额（BEP-20 精度 18 位）
const TRANSFER_AMOUNT = parseEther("3.33");

// ── 类型 ─────────────────────────────────────────────────────────────────────

type Call = { to: `0x${string}`; value: bigint; data: `0x${string}` };

// ── 工具：读 A 当前 nonce（A 上若无 code 或不识别 nonce()，回退 0）─────
//    - 首次代付：A 还没委托过任何合约 → 无 code → nonce=0
//    - 异常 RPC：getCode 返回 "0x"/"0x0"/undefined 都按无 code 处理
//    - A 已被委托到另一份合约：readContract 会 revert，吞掉直接当 0 用
async function readNonceFromA(
  publicClient: ReturnType<typeof createWalletClient>,
  a: `0x${string}`,
): Promise<bigint> {
  const pc = publicClient.extend(publicActions);
  try {
    const code = await pc.getCode({ address: a });
    // 任何"看起来没code"的形状都视为未委托
    if (!code || code === "0x" || code === "0x0" || code.length <= 4) {
      return 0n;
    }
    return (await pc.readContract({
      address: a,
      abi: batchCallAbi,
      functionName: "nonce",
    })) as bigint;
  } catch {
    return 0n;
  }
}

// ── 主逻辑 ──────────────────────────────────────────────────────────────────

async function main() {
  console.log(
    "\n═══════════════════════════════════════════════════════\n" +
    "  EIP-7702 / BEP-441 场景二：B 代付 gas (v2)\n" +
    "  网络：BSC Testnet（Pascal 硬分叉）\n" +
    "═══════════════════════════════════════════════════════\n"
  );

  const A_ACCOUNT = privateKeyToAccount(A_PRIVATE_KEY as `0x${string}`);
  const B_ACCOUNT = privateKeyToAccount(B_PRIVATE_KEY as `0x${string}`);

  const bWalletClient = createWalletClient({
    account: B_ACCOUNT,
    chain,
    transport: http(RPC_URL),
  });

  const publicClient = createWalletClient({
    account: B_ACCOUNT,
    chain,
    transport: http(RPC_URL),
  }).extend(publicActions);

  // executor 默认绑定到 B（防止别人抢跑代付）。env 留空 = 任意 relayer。
  const EXECUTOR: `0x${string}` =
    (process.env.DEMO_EXECUTOR as `0x${string}`) || B_ACCOUNT.address;
  const allowAnyExecutor = EXECUTOR.toLowerCase() === zeroAddress.toLowerCase();

  const deadlineOffset = BigInt(process.env.DEMO_DEADLINE_OFFSET ?? "600");
  const deadline = BigInt(Math.floor(Date.now() / 1000)) + deadlineOffset;

  console.log("角色信息：");
  console.log(`  网络:           ${chain.name} (Chain ID: ${chain.id})`);
  console.log(`  RPC:            ${RPC_URL}`);
  console.log(`  A 地址:         ${A_ACCOUNT.address}  ← 持币者`);
  console.log(`  B 地址:         ${B_ACCOUNT.address}  ← gas 代付者`);
  console.log(`  C 地址:         ${C_ADDRESS}  ← 代币接收者`);
  console.log(`  Implementation: ${IMPLEMENTATION_ADDRESS}`);
  console.log(`  Token:          ${TOKEN_ADDRESS}`);
  console.log(`  转账金额:       ${TRANSFER_AMOUNT}`);
  console.log(`  Executor:       ${allowAnyExecutor ? "ANY" : EXECUTOR}`);
  console.log(`  Deadline:       ${deadline} (now + ${deadlineOffset}s)\n`);

  // ── Step 1：读 A 当前 nonce（从 A 自己的地址 staticcall，不是 implementation）─
  const nonce = await readNonceFromA(publicClient, A_ACCOUNT.address);
  console.log(`[Step 1] 当前 nonce: ${nonce}`);

  // ── Step 2：构造 calls ──────────────────────────────────────────────
  const calls: Call[] = [
    {
      to: TOKEN_ADDRESS,
      value: 0n,
      data: encodeFunctionData({
        abi: erc20Abi,
        functionName: "transfer",
        args: [C_ADDRESS, TRANSFER_AMOUNT],
      }),
    },
  ];
  console.log(`[Step 2] 构造 calls: 转 ${TRANSFER_AMOUNT} tokens 给 C`);

  // ── Step 3：A 签 7702 授权（不指定 executor → B 代付 gas）──────
  console.log("[Step 3] A 正在签署 EIP-7702 授权...");
  const authorization = await bWalletClient.signAuthorization({
    account: A_ACCOUNT,
    contractAddress: IMPLEMENTATION_ADDRESS,
  });
  console.log(`✅ 7702 授权已签署`);
  console.log(
    `   chainId=${authorization.chainId} contract=${authorization.address} nonce=${authorization.nonce}`
  );

  // ── Step 4：A 用 EIP-712 typed data 签整个 Execute 请求 ─────────────
  // domain.verifyingContract = A 自己的地址（与合约运行时 address(this) 一致）
  console.log("[Step 4] A 正在按 EIP-712 签 Execute 请求...");
  const signature = await A_ACCOUNT.signTypedData({
    domain: eip712Domain(chain.id, A_ACCOUNT.address),
    types: eip712Types,
    primaryType: "Execute",
    message: {
      calls,
      nonce,
      deadline,
      executor: allowAnyExecutor ? zeroAddress : EXECUTOR,
    },
  });
  console.log(`✅ A 已签署 Execute typed data`);
  console.log(`   signature: ${signature}`);

  // ── Step 5：B 构造并发送 7702 交易（B 付 gas）───────────────────
  console.log("\n[Step 5] B 正在发送 EIP-7702 交易（msg.sender = B）...");
  const callData = encodeFunctionData({
    abi: batchCallAbi,
    functionName: "execute",
    args: [
      calls,
      deadline,
      allowAnyExecutor ? zeroAddress : EXECUTOR,
      signature,
    ],
  });

  // EIP-7702 交易 calldata 偏大，手动估算并加 50% 缓冲
  const estimatedGas = await publicClient.estimateGas({
    account: B_ACCOUNT.address,
    to: A_ACCOUNT.address,
    data: callData,
    authorizationList: [authorization],
  });
  const safeGas = (estimatedGas * 150n) / 100n;
  console.log(`         估算 gas: ${estimatedGas}，安全上限: ${safeGas}`);

  const hash = await bWalletClient.sendTransaction({
    authorizationList: [authorization],
    to: A_ACCOUNT.address,
    data: callData,
    gas: safeGas,
  });

  console.log(`✅ 交易已广播`);
  console.log(`   tx hash:  ${hash}`);
  console.log(`   浏览器:   ${chain.blockExplorers?.default.url}/tx/${hash}`);

  // ── Step 6：等待确认 ──────────────────────────────────────────────
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(
    `\n[Step 6] 交易状态: ${receipt.status === "success" ? "✅ 成功" : "❌ 失败"} (区块 #${receipt.blockNumber})`
  );

  // ── Step 7：验证结果 ──────────────────────────────────────────────
  const cBalance = (await publicClient.readContract({
    address: TOKEN_ADDRESS,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [C_ADDRESS],
  })) as bigint;

  const newNonce = await readNonceFromA(publicClient, A_ACCOUNT.address);

  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  验证结果");
  console.log("═══════════════════════════════════════════════════════");
  console.log(`C 当前 token 余额: ${cBalance}`);
  console.log(
    `预期收到: ${TRANSFER_AMOUNT}  → ${
      cBalance >= TRANSFER_AMOUNT ? "✅ 正确" : "❌ 不正确"
    }`
  );
  console.log(`A 新 nonce: ${newNonce}（应为 ${nonce + 1n}）`);
  console.log(
    "\nReplay 保护：当前签名已失效，下次需用新 nonce + 新 deadline 重新签。"
  );
  console.log(
    "📌 注意：7702 授权挂载本身只在该笔 tx 内生效；若想让授权常驻 A，让 A 显式发一笔 7702 tx。"
  );
}

main().catch((err) => {
  console.error("\n❌ 执行失败:", err);
  process.exit(1);
});
