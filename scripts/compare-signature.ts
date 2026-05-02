/**
 * TS 端 EIP-712 签名比对工具，与 go-demo/cmd/compare 配套。
 *
 * 用同一份 fixture（与 go-demo/cmd/compare/fixture.go 中常量一一对应）
 * 计算 Execute typed data 的 digest 与签名，输出与 Go 端可 diff 的两行。
 *
 *   npx tsx scripts/compare-signature.ts > /tmp/sig-ts.txt
 *   (cd go-demo && go run ./cmd/compare) > /tmp/sig-go.txt
 *   diff /tmp/sig-ts.txt /tmp/sig-go.txt    # 应无差异
 */

import { encodeFunctionData, hashTypedData } from "viem";
import { privateKeyToAccount, sign, serializeSignature } from "viem/accounts";

import { erc20Abi, eip712Domain, eip712Types } from "../src/abis.js";

// ─── Fixture（必须与 go-demo/cmd/compare/fixture.go 完全一致） ────────────
const CHAIN_ID = 97;
const NONCE = 0n;
const DEADLINE = 1745000000n;
const AMOUNT_WEI = 1230000000000000000n; // 1.23 ether
const A_PK =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const; // anvil #0
const B_ADDRESS = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" as const; // anvil #1
const TOKEN_ADDRESS = "0x20c6aD67776725515F1b68b06865c865F62833FF" as const;
const C_ADDRESS = "0xCcAD84d0772262AeDe15B1B702d1Bd69D02f177D" as const;

async function main() {
  const A = privateKeyToAccount(A_PK);

  const transferData = encodeFunctionData({
    abi: erc20Abi,
    functionName: "transfer",
    args: [C_ADDRESS, AMOUNT_WEI],
  });

  const calls = [
    {
      to: TOKEN_ADDRESS,
      value: 0n,
      data: transferData,
    },
  ];

  const message = {
    calls,
    nonce: NONCE,
    deadline: DEADLINE,
    executor: B_ADDRESS,
  };

  // verifyingContract = A 的 EOA 地址（与合约 7702 委托后 address(this) 一致）
  const domain = eip712Domain(CHAIN_ID, A.address);

  // 1) digest = keccak256("\x19\x01" || domainSep || hashStruct(Execute, msg))
  const digest = hashTypedData({
    domain,
    types: eip712Types,
    primaryType: "Execute",
    message,
  });

  // 2) 用 A 的私钥对 digest 做 raw secp256k1 签名（与 Go 端 crypto.Sign 同一路径）
  const sigObj = await sign({
    hash: digest,
    privateKey: A_PK,
  });
  const signature = serializeSignature(sigObj); // 65-byte hex r||s||v

  console.log(`digest=${digest}`);
  console.log(`signature=${signature}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
