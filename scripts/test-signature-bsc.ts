// 验证问题根源：signMessage({ raw }) 是否自动加前缀
// 在 BSC Testnet 上通过 eth_call 验证合约验签
import "dotenv/config";
import { createWalletClient, http, encodeFunctionData, concatHex, encodeAbiParameters, parseAbiParameters, publicActions } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { bscTestnet } from "viem/chains";
import { batchCallAbi, erc20Abi } from "../src/abis.js";

const A_PRIVATE_KEY = process.env.PRIVATE_KEY_A!;
const RPC_URL = process.env.RPC_URL!;
const implAddr = process.env.IMPLEMENTATION_ADDRESS!;
const tokenAddr = process.env.TOKEN_ADDRESS!;

if (!A_PRIVATE_KEY || !RPC_URL || !implAddr || !tokenAddr) {
  console.error("Missing env vars"); process.exit(1);
}

const A_ACCOUNT = privateKeyToAccount(A_PRIVATE_KEY as `0x${string}`);
const C_ADDRESS = "0xCcAD84d0772262AeDe15B1B702d1Bd69D02f177D";
const TRANSFER_AMOUNT = 3330000000000000000n;

async function main() {
  const walletClient = createWalletClient({ account: A_ACCOUNT, chain: bscTestnet, transport: http(RPC_URL) });
  const publicClient = walletClient.extend(publicActions);

  console.log("A:", A_ACCOUNT.address);
  console.log("Implementation:", implAddr);
  console.log("Token:", tokenAddr);

  // Step 1: 读取 A 在 impl 上的 nonce
  const nonce = await publicClient.readContract({
    address: implAddr as `0x${string}`,
    abi: batchCallAbi,
    functionName: "nonces",
    args: [A_ACCOUNT.address]
  }) as bigint;
  console.log("\n[1] A 的 nonce:", nonce);

  // Step 2: 构造 calls
  const calls = [{
    to: tokenAddr as `0x${string}`,
    value: 0n,
    data: encodeFunctionData({ abi: erc20Abi, functionName: "transfer", args: [C_ADDRESS, TRANSFER_AMOUNT] }),
  }];

  // Step 3: 构造 digest（与合约内部一致）
  const encodeCallsForDigest = (calls: typeof calls): `0x${string}` => {
    const parts: `0x${string}`[] = [];
    for (const call of calls) {
      parts.push(call.to);
      parts.push(encodeAbiParameters(parseAbiParameters("uint256"), [call.value]));
      parts.push(call.data);
    }
    return concatHex(parts);
  };

  const encodedCalls = encodeCallsForDigest(calls);
  const callDigest = concatHex([
    encodeAbiParameters(parseAbiParameters("uint256"), [nonce]),
    encodedCalls,
  ]);
  console.log("[2] callDigest:", callDigest);
  console.log("    encodedCalls:", encodedCalls);

  // Step 4: 用两种方式签名，看哪种在合约里能通过
  // 方式 1：直接签原始 digest（signMessage 会加前缀）
  const sig1 = await A_ACCOUNT.signMessage({ message: { raw: callDigest } });
  console.log("\n[3a] 方式1 - signMessage({ raw: callDigest }):");
  console.log("    sig1:", sig1);

  // 方式 2：先 hashMessage，再签 hash
  const { hashMessage } = await import("viem");
  const sig2 = await A_ACCOUNT.signMessage({ message: { raw: hashMessage(callDigest) } });
  console.log("\n[3b] 方式2 - signMessage({ raw: hashMessage(callDigest) }):");
  console.log("    sig2:", sig2);

  // 方式 3：用 viem recoverMessageAddress 验证 sig1
  const { recoverMessageAddress } = await import("viem");
  try {
    const recovered1 = await recoverMessageAddress({ message: { raw: callDigest }, signature: sig1 });
    console.log("\n[4a] recoverMessageAddress(raw callDigest, sig1):", recovered1);
    console.log("    匹配 A:", recovered1.toLowerCase() === A_ACCOUNT.address.toLowerCase());
  } catch(e) { console.log("[4a] FAILED:", e); }

  try {
    const recovered2 = await recoverMessageAddress({ message: { raw: hashMessage(callDigest) }, signature: sig2 });
    console.log("\n[4b] recoverMessageAddress(raw hashMessage(callDigest), sig2):", recovered2);
    console.log("    匹配 A:", recovered2.toLowerCase() === A_ACCOUNT.address.toLowerCase());
  } catch(e) { console.log("[4b] FAILED:", e); }

  // Step 5: 通过 eth_call 测试合约验签（sig1）
  console.log("\n[5] 通过 eth_call 测试合约验签...");
  const callData = encodeFunctionData({ abi: batchCallAbi, functionName: "execute", args: [calls, sig1] });

  try {
    await publicClient.call({
      to: A_ACCOUNT.address,  // 如果 A 有代码，会调用 A 上的代码
      data: callData,
    });
    console.log("    eth_call SUCCESS - sig1 在合约里通过！");
  } catch(e: any) {
    console.log("    eth_call FAILED - sig1 不通过");
    console.log("    Error:", e.shortMessage || String(e).split("\n")[0]);

    // 提取 revert reason
    const raw = JSON.stringify(e);
    const match = raw.match(/0x08c379a0([0-9a-f]+)/i);
    if (match) {
      try {
        const data = "0x" + match[1];
        const hex = data.slice(10); // 跳过 selector
        const len = parseInt(hex.slice(0, 64), 16);
        const strHex = hex.slice(64, 64 + len * 2);
        let result = "";
        for (let i = 0; i < strHex.length; i += 2) {
          const code = parseInt(strHex.slice(i, i+2), 16);
          if (code >= 32 && code < 127) result += String.fromCharCode(code);
        }
        console.log("    Revert reason:", result);
      } catch {}
    }
  }
}

main().catch(console.error);
