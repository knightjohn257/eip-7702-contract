// 命令：用固定 fixture 算 Go 端的 EIP-712 签名并打印（hex），
// 与 scripts/compare-signature.ts 输出做字节级比对。
//
//   go run ./cmd/compare > /tmp/sig-go.txt
//   npx tsx ../scripts/compare-signature.ts > /tmp/sig-ts.txt
//   diff /tmp/sig-go.txt /tmp/sig-ts.txt   # 应无差异
package main

import (
	"encoding/hex"
	"fmt"
	"os"

	demo "github.com/oddfi/eip7702-go-demo"
)

func main() {
	in := BuildFixtureInput()

	digest, err := demo.ExecuteRequestDigest(in)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	sig, err := demo.SignExecute(in)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	// 输出格式与 TS 端保持一致：两行
	//   digest=0x...
	//   signature=0x...
	fmt.Printf("digest=0x%s\n", hex.EncodeToString(digest))
	fmt.Printf("signature=0x%s\n", hex.EncodeToString(sig))
}
