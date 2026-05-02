package main

import (
	"math/big"

	demo "github.com/oddfi/eip7702-go-demo"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// ─────────────────────────────────────────────────────────────────────────────
// 签名一致性比对的固定 fixture
//
// Go 与 TS 两端必须使用完全相同的输入，分别签名后比对 65 字节签名是否完全一致。
// 由于 secp256k1 + RFC6979 是确定性签名，相同 digest + 相同 key → 相同签名字节。
//
// 同时 fixture 也存在 cmd/compare/fixture.json（被 scripts/compare-signature.ts 读取）。
// 任何字段改动都要双向同步！
// ─────────────────────────────────────────────────────────────────────────────

// 所有字段都用最简单的小数 / 标准 hex，避免任何格式歧义
const (
	FixtureChainID           int64  = 97
	FixtureNonce             int64  = 0
	FixtureDeadline          int64  = 1745000000
	FixtureAmountWei         string = "1230000000000000000" // 1.23 * 1e18
	FixtureAPrivateKey       string = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" // anvil #0
	FixtureBAddress          string = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"                       // anvil #1
	FixtureTokenAddress      string = "0x20c6aD67776725515F1b68b06865c865F62833FF"
	FixtureCAddress          string = "0xCcAD84d0772262AeDe15B1B702d1Bd69D02f177D"
)

// BuildFixtureInput 把上面的常量组装成 SignExecuteInput。
// VerifyingContract = vm.addr(A_PK) = anvil 0x f39Fd6e51aad88F6F4ce6aB8827279cfFFb92266。
func BuildFixtureInput() demo.SignExecuteInput {
	aKey, err := crypto.HexToECDSA("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
	if err != nil {
		panic(err)
	}
	aAddr := crypto.PubkeyToAddress(aKey.PublicKey)

	transferData, err := demo.EncodeERC20Transfer(
		common.HexToAddress(FixtureCAddress),
		mustBig(FixtureAmountWei),
	)
	if err != nil {
		panic(err)
	}

	return demo.SignExecuteInput{
		ChainID:           big.NewInt(FixtureChainID),
		VerifyingContract: aAddr,
		Calls: []demo.Call{
			{
				To:    common.HexToAddress(FixtureTokenAddress),
				Value: big.NewInt(0),
				Data:  transferData,
			},
		},
		Nonce:      big.NewInt(FixtureNonce),
		Deadline:   big.NewInt(FixtureDeadline),
		Executor:   common.HexToAddress(FixtureBAddress),
		PrivateKey: aKey,
	}
}

func mustBig(s string) *big.Int {
	b, ok := new(big.Int).SetString(s, 10)
	if !ok {
		panic("bad bigint: " + s)
	}
	return b
}
