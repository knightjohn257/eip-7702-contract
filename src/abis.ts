// ABI exports for BatchCallAndSponsor v2 (EIP-712 + deadline + executor)

export const batchCallAbi = [
  // ── 带签名版本：B 代付 ────────────────────────────────────────────────
  {
    type: "function",
    name: "execute",
    inputs: [
      {
        name: "calls",
        type: "tuple[]",
        components: [
          { name: "to", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
      { name: "deadline", type: "uint256" },
      { name: "executor", type: "address" },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  // ── 自调用版本：A 自己执行 ─────────────────────────────────────────────
  {
    type: "function",
    name: "execute",
    inputs: [
      {
        name: "calls",
        type: "tuple[]",
        components: [
          { name: "to", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
    ],
    outputs: [],
    stateMutability: "payable",
  },
  // ── nonce 单变量（注意：必须对 A 自己的地址 staticcall，不是对 implementation）─
  {
    type: "function",
    name: "nonce",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  // ── 链下对账用 ──────────────────────────────────────────────────────────
  {
    type: "function",
    name: "executeRequestDigest",
    inputs: [
      {
        name: "calls",
        type: "tuple[]",
        components: [
          { name: "to", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
      { name: "currentNonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
      { name: "executor", type: "address" },
    ],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "domainSeparator",
    inputs: [],
    outputs: [{ name: "", type: "bytes32" }],
    stateMutability: "view",
  },
  {
    type: "event",
    name: "CallExecuted",
    inputs: [
      { name: "sender", type: "address", indexed: true },
      { name: "to", type: "address", indexed: true },
      { name: "value", type: "uint256", indexed: false },
      { name: "data", type: "bytes", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "BatchExecuted",
    inputs: [
      { name: "nonce", type: "uint256", indexed: true },
      { name: "callsCount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  // ── errors ─────────────────────────────────────────────────────────────
  { type: "error", name: "InvalidSignature", inputs: [] },
  {
    type: "error",
    name: "DeadlineExpired",
    inputs: [{ name: "deadline", type: "uint256" }],
  },
  {
    type: "error",
    name: "WrongExecutor",
    inputs: [
      { name: "expected", type: "address" },
      { name: "actual", type: "address" },
    ],
  },
  {
    type: "error",
    name: "CallReturnedFalse",
    inputs: [{ name: "index", type: "uint256" }],
  },
  { type: "error", name: "UnauthorizedSelfCall", inputs: [] },
  { type: "error", name: "DirectImplementationCall", inputs: [] },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "transfer",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
  },
  {
    type: "function",
    name: "balanceOf",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "decimals",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "symbol",
    inputs: [],
    outputs: [{ name: "", type: "string" }],
    stateMutability: "view",
  },
] as const;

// ────────────────────────────────────────────────────────────────────────────
// EIP-712 typed-data 模板（与合约中 _EXECUTE_TYPEHASH / _CALL_TYPEHASH 一致）
// 用法见 scripts/02-sponsored-demo.ts
// ────────────────────────────────────────────────────────────────────────────

export const eip712Domain = (
  chainId: number | bigint,
  verifyingContract: `0x${string}`,
) =>
  ({
    name: "BatchCallAndSponsor",
    version: "1",
    chainId,
    verifyingContract,
  }) as const;

export const eip712Types = {
  Call: [
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
  ],
  Execute: [
    { name: "calls", type: "Call[]" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "executor", type: "address" },
  ],
} as const;
