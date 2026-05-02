#!/usr/bin/env bash
# 跨语言 EIP-712 签名一致性自动验证。
#   - 用 go-demo/cmd/compare/fixture.go + scripts/compare-signature.ts 中的同一份 fixture
#   - 分别让 Go 端和 TS 端计算 digest + 签名
#   - diff 二者，应字节级一致
set -euo pipefail
cd "$(dirname "$0")"

GO_OUT=$(mktemp)
TS_OUT=$(mktemp)
trap 'rm -f "$GO_OUT" "$TS_OUT"' EXIT

go run ./cmd/compare > "$GO_OUT"
( cd .. && npx tsx scripts/compare-signature.ts ) > "$TS_OUT"

echo "=== GO ==="; cat "$GO_OUT"
echo "=== TS ==="; cat "$TS_OUT"
echo "=== DIFF ==="

if diff -u "$GO_OUT" "$TS_OUT"; then
  echo "✅ Go 与 TS 端 EIP-712 签名字节级一致"
  exit 0
else
  echo "❌ 不一致 — 检查 typehash 字符串、fixture 数值、或 EIP-712 编码"
  exit 1
fi
