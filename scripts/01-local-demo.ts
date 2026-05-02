/**
 * 场景一：A 自己执行 EIP-7702 交易（无 B 代付）
 *
 * v2 — EIP-712 签名 + deadline + executor
 *
 * 流程：
 * 1. A 用私钥签 7702 授权（executor = "self"）
 * 2. A 按 EIP-712 typed data 签 (calls, nonce, deadline, executor=A) 的 Execute 请求
 * 3. A 自己发交易：to = A 的地址，data = execute(calls, deadline, executor, signature)
 *    msg.sender = A，A 自己付 gas
 *
 * 也可直接调 execute(calls)（无签名版），合约校验 msg.sender == address(this) 即可。
 * 这里特意走"带签名"版本，与 02-sponsored-demo.ts 保持同一签名流程，便于对比。
 */

import "dotenv/config";
import {
  createWalletClient,
  http,
  encodeFunctionData,
  parseEther,
  publicActions,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";
import { batchCallAbi, erc20Abi, eip712Domain, eip712Types } from "../src/abis.js";

const chain = bscTestnet;
const RPC_URL = process.env.RPC_URL!;
if (!RPC_URL) {
  console.error("❌ 请设置 RPC_URL"); process.exit(1);
}

const A_PRIVATE_KEY = process.env.PRIVATE_KEY_A;
if (!A_PRIVATE_KEY) { console.error("❌ 请设置 PRIVATE_KEY_A"); process.exit(1); }

const implAddr = process.env.IMPLEMENTATION_ADDRESS;
if (!implAddr) { console.error("❌ 请设置 IMPLEMENTATION_ADDRESS"); process.exit(1); }
const IMPLEMENTATION_ADDRESS: `0x${string}` = implAddr as `0x${string}`;

const tokenAddr = process.env.TOKEN_ADDRESS;
if (!tokenAddr) { console.error("❌ 请设置 TOKEN_ADDRESS"); process.exit(1); }
const TOKEN_ADDRESS: `0x${string}` = tokenAddr as `0x${string}`;

const C_ADDRESS =
  (process.env.C_ADDRESS as `0x${string}`) ||
  "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

const TRANSFER_AMOUNT = parseEther("100");

type Call = { to: `0x${string}`; value: bigint; data: `0x${string}` };

async function readNonceFromA(
  publicClient: ReturnType<typeof createWalletClient>,
  a: `0x${string}`,
): Promise<bigint> {
  const pc = publicClient.extend(publicActions);
  try {
    const code = await pc.getCode({ address: a });
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

async function main() {
  console.log(
    "\n═══════════════════════════════════════════════════════\n" +
    "  EIP-7702 / BEP-441 场景一：A 自己执行 (v2)\n" +
    "  网络：BSC Testnet（Pascal 硬分叉）\n" +
    "═══════════════════════════════════════════════════════\n"
  );

  const A_ACCOUNT = privateKeyToAccount(A_PRIVATE_KEY as `0x${string}`);

  const walletClient = createWalletClient({
    account: A_ACCOUNT,
    chain,
    transport: http(RPC_URL),
  });

  const publicClient = createWalletClient({
    account: A_ACCOUNT,
    chain,
    transport: http(RPC_URL),
  }).extend(publicActions);

  // 自执行场景：executor 必须 = A（msg.sender 也是 A）
  const EXECUTOR = A_ACCOUNT.address;
  const deadlineOffset = BigInt(process.env.DEMO_DEADLINE_OFFSET ?? "600");
  const deadline = BigInt(Math.floor(Date.now() / 1000)) + deadlineOffset;

  console.log("角色信息：");
  console.log(`  网络:           ${chain.name} (Chain ID: ${chain.id})`);
  console.log(`  A 地址:         ${A_ACCOUNT.address}  ← 持币者 + 签名者 + 交易发送者`);
  console.log(`  C 地址:         ${C_ADDRESS}`);
  console.log(`  Implementation: ${IMPLEMENTATION_ADDRESS}`);
  console.log(`  Token:          ${TOKEN_ADDRESS}`);
  console.log(`  转账金额:       ${TRANSFER_AMOUNT}`);
  console.log(`  Executor:       ${EXECUTOR}`);
  console.log(`  Deadline:       ${deadline} (now + ${deadlineOffset}s)\n`);

  // Step 1：A 当前 token 余额
  const aTokenBalanceBefore = (await publicClient.readContract({
    address: TOKEN_ADDRESS,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [A_ACCOUNT.address],
  })) as bigint;
  console.log(`[Step 1] A 当前 token 余额: ${aTokenBalanceBefore}`);

  // Step 2：读 nonce（从 A 自己的地址，回退 0）
  const nonce = await readNonceFromA(publicClient, A_ACCOUNT.address);
  console.log(`[Step 2] 当前 nonce: ${nonce}`);

  // Step 3：构造 calls
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
  console.log(`[Step 3] 构造 calls: 转 ${TRANSFER_AMOUNT} tokens 给 C`);

  // Step 4：A 签 7702 授权（executor = self → A 自己付 gas）
  console.log("[Step 4] A 正在签署 EIP-7702 授权（executor = self）...");
  const authorization = await walletClient.signAuthorization({
    account: A_ACCOUNT,
    contractAddress: IMPLEMENTATION_ADDRESS,
    executor: "self",
  });
  console.log(`✅ 7702 授权已签署`);

  // Step 5：A 按 EIP-712 签 Execute 请求
  const signature = await A_ACCOUNT.signTypedData({
    domain: eip712Domain(chain.id, A_ACCOUNT.address),
    types: eip712Types,
    primaryType: "Execute",
    message: {
      calls,
      nonce,
      deadline,
      executor: EXECUTOR,
    },
  });
  console.log(`[Step 5] A 已签署 Execute typed data`);

  // Step 6：A 发 7702 交易
  console.log("\n[Step 6] A 正在发送 EIP-7702 交易...");
  const callData = encodeFunctionData({
    abi: batchCallAbi,
    functionName: "execute",
    args: [calls, deadline, EXECUTOR, signature],
  });
  const estimatedGas = await publicClient.estimateGas({
    account: A_ACCOUNT.address,
    to: A_ACCOUNT.address,
    data: callData,
    authorizationList: [authorization],
  });
  const safeGas = (estimatedGas * 150n) / 100n;
  console.log(`         估算 gas: ${estimatedGas}，安全上限: ${safeGas}`);

  const hash = await walletClient.sendTransaction({
    authorizationList: [authorization],
    to: A_ACCOUNT.address,
    data: callData,
    gas: safeGas,
  });
  console.log(`✅ 交易已广播`);
  console.log(`   tx hash:  ${hash}`);
  console.log(`   浏览器:   ${chain.blockExplorers?.default.url}/tx/${hash}`);

  // Step 7：等待
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(
    `\n[Step 7] 交易状态: ${receipt.status === "success" ? "✅ 成功" : "❌ 失败"} (区块 #${receipt.blockNumber})`
  );

  // Step 8：验证
  const cTokenBalance = (await publicClient.readContract({
    address: TOKEN_ADDRESS,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [C_ADDRESS],
  })) as bigint;
  const newNonce = await readNonceFromA(publicClient, A_ACCOUNT.address);

  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  验证结果");
  console.log("═══════════════════════════════════════════════════════");
  console.log(`C 当前 token 余额: ${cTokenBalance}`);
  console.log(
    `预期收到: ${TRANSFER_AMOUNT}  → ${
      cTokenBalance >= TRANSFER_AMOUNT ? "✅ 正确" : "❌ 错误"
    }`
  );
  console.log(`A 新 nonce: ${newNonce}（应为 ${nonce + 1n}）`);
}

main().catch((err) => {
  console.error("\n❌ 执行失败:", err);
  process.exit(1);
});
