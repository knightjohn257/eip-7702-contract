package eip7702demo

import (
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// ─────────────────────────────────────────────────────────────────────────────
// ABI selectors（手算，避免引入 contract bindings）
// ─────────────────────────────────────────────────────────────────────────────

func selector(sig string) []byte {
	return crypto.Keccak256([]byte(sig))[:4]
}

// EncodeERC20Transfer 拼出 transfer(address,uint256) calldata。
func EncodeERC20Transfer(to common.Address, amount *big.Int) ([]byte, error) {
	addrTy, _ := abi.NewType("address", "", nil)
	uint256Ty, _ := abi.NewType("uint256", "", nil)
	args := abi.Arguments{
		{Type: addrTy}, {Type: uint256Ty},
	}
	packed, err := args.Pack(to, amount)
	if err != nil {
		return nil, fmt.Errorf("pack erc20 transfer: %w", err)
	}
	out := make([]byte, 0, 4+len(packed))
	out = append(out, selector("transfer(address,uint256)")...)
	out = append(out, packed...)
	return out, nil
}

// abiCall 是 abi.Pack 看到的 Call 形状 — 字段必须用具体类型，
// 不能用 interface{}，否则 reflect 推断不出 uint256。字段顺序必须与
// 合约 src/BatchCallAndSponsor.sol:38-42 的 Call 结构一致。
type abiCall struct {
	To    common.Address
	Value *big.Int
	Data  []byte
}

// EncodeBatchExecute 拼出
//   execute((address to,uint256 value,bytes data)[],uint256 deadline,address executor,bytes signature)
// 的 calldata，对应合约 src/BatchCallAndSponsor.sol:79-86 的 execute()。
func EncodeBatchExecute(calls []Call, deadline *big.Int, executor common.Address, signature []byte) ([]byte, error) {
	tupleTy, err := abi.NewType("tuple[]", "Call[]", []abi.ArgumentMarshaling{
		{Name: "to", Type: "address"},
		{Name: "value", Type: "uint256"},
		{Name: "data", Type: "bytes"},
	})
	if err != nil {
		return nil, err
	}
	uint256Ty, _ := abi.NewType("uint256", "", nil)
	addrTy, _ := abi.NewType("address", "", nil)
	bytesTy, _ := abi.NewType("bytes", "", nil)

	args := abi.Arguments{
		{Type: tupleTy},
		{Type: uint256Ty},
		{Type: addrTy},
		{Type: bytesTy},
	}

	abiCalls := make([]abiCall, len(calls))
	for i, c := range calls {
		abiCalls[i] = abiCall{To: c.To, Value: c.Value, Data: c.Data}
	}

	packed, err := args.Pack(abiCalls, deadline, executor, signature)
	if err != nil {
		return nil, fmt.Errorf("pack execute: %w", err)
	}

	out := make([]byte, 0, 4+len(packed))
	out = append(out, selector("execute((address,uint256,bytes)[],uint256,address,bytes)")...)
	out = append(out, packed...)
	return out, nil
}
