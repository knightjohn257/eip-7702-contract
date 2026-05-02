package eip7702demo

import (
	"context"
	"math/big"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

// ReadContractNonce staticcall A 自己的地址，读 BatchCallAndSponsor.nonce 当前值。
//
// 注意：合约里的 nonce 与 EOA tx nonce 是两件事
//   - EOA tx nonce  ← ethclient.NonceAt(ctx, A, nil) ：协议层防 tx 重放
//   - 合约 nonce    ← 本函数读到的 ：防签名重放，每次 execute() 成功 +1
//
// 三种情况：
//   - A 还从未 7702 委托过：A 上没 code → fallback 0
//   - A 委托给了"另一份"合约：staticcall 失败 → fallback 0
//   - A 委托到本合约：返回真实 nonce
//
// 与 scripts/02-sponsored-demo.ts 中的 readNonceFromA 行为一致。
func ReadContractNonce(ctx context.Context, client *ethclient.Client, a common.Address) (*big.Int, error) {
	code, err := client.CodeAt(ctx, a, nil)
	if err != nil {
		// RPC 异常时也回退 0，签名带 0 走，链上对不上自然会 revert
		return big.NewInt(0), nil
	}
	if len(code) <= 4 {
		return big.NewInt(0), nil
	}

	// nonce() 函数 selector
	data := crypto.Keccak256([]byte("nonce()"))[:4]
	out, err := client.CallContract(ctx, ethereum.CallMsg{
		To:   &a,
		Data: data,
	}, nil)
	if err != nil || len(out) < 32 {
		return big.NewInt(0), nil
	}
	return new(big.Int).SetBytes(out[:32]), nil
}
