// Package eip7702demo 是 BatchCallAndSponsor v2 合约的 Go 客户端。
// 与 scripts/02-sponsored-demo.ts 一一对应，专门用来给 A 的 EIP-7702
// 委托 + EIP-712 typed data 签名 + 让 B 代付 gas 广播 SetCode 交易。
package eip7702demo

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/hexutil"
	"github.com/ethereum/go-ethereum/common/math"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/signer/core/apitypes"
)

// Call 镜像合约 src/BatchCallAndSponsor.sol:38-42 中的 Call 结构。
type Call struct {
	To    common.Address
	Value *big.Int
	Data  []byte
}

// SignExecuteInput 是签 Execute 请求所需的全部输入。
//
// VerifyingContract 必须 = A 的 EOA 地址，因为 EIP-7702 委托后合约里的
// address(this) = A，OZ EIP712 的 _domainSeparatorV4() 会动态用 A 重算
// domain separator（参见合约 src/BatchCallAndSponsor.sol 继承的 EIP712）。
type SignExecuteInput struct {
	ChainID           *big.Int
	VerifyingContract common.Address // = A 的 EOA 地址
	Calls             []Call
	Nonce             *big.Int // BatchCallAndSponsor.nonce 当前值
	Deadline          *big.Int // unix 秒
	Executor          common.Address // 0 = 任意 relayer
	PrivateKey        *ecdsa.PrivateKey // A 的私钥
}

// 与合约保持完全一致的 EIP-712 域信息。
// 来源：src/BatchCallAndSponsor.sol:65 → constructor() EIP712("BatchCallAndSponsor", "1")
const (
	domainName    = "BatchCallAndSponsor"
	domainVersion = "1"
)

// BuildExecuteTypedData 构造 EIP-712 typed data。
//
// EIP-712 schema 与合约 typehash 必须逐字节一致。引用如下：
//
//	src/BatchCallAndSponsor.sol:41
//	  _CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)")
//
//	src/BatchCallAndSponsor.sol:43-45
//	  _EXECUTE_TYPEHASH = keccak256(
//	    "Execute(Call[] calls,uint256 nonce,uint256 deadline,address executor)Call(address to,uint256 value,bytes data)"
//	  )
//
// EIP-712 spec：encodeType = primaryType(...) ∥ 各依赖 type 按字母序拼接。
// 这里 Execute 引用 Call，所以拼接顺序为 "Execute(...)Call(...)"。
// apitypes 内部会按相同规则计算，typehash 自动对齐。
func BuildExecuteTypedData(in SignExecuteInput) apitypes.TypedData {
	callsMessage := make([]map[string]interface{}, len(in.Calls))
	for i, c := range in.Calls {
		callsMessage[i] = map[string]interface{}{
			"to":    c.To.Hex(),
			"value": (*math.HexOrDecimal256)(c.Value),
			"data":  hexutil.Bytes(c.Data),
		}
	}

	return apitypes.TypedData{
		Types: apitypes.Types{
			// EIP-712 标准 domain（apitypes 强制要求显式声明）
			"EIP712Domain": []apitypes.Type{
				{Name: "name", Type: "string"},
				{Name: "version", Type: "string"},
				{Name: "chainId", Type: "uint256"},
				{Name: "verifyingContract", Type: "address"},
			},
			// 合约 src/BatchCallAndSponsor.sol:41 _CALL_TYPEHASH
			"Call": []apitypes.Type{
				{Name: "to", Type: "address"},
				{Name: "value", Type: "uint256"},
				{Name: "data", Type: "bytes"},
			},
			// 合约 src/BatchCallAndSponsor.sol:43-45 _EXECUTE_TYPEHASH
			"Execute": []apitypes.Type{
				{Name: "calls", Type: "Call[]"},
				{Name: "nonce", Type: "uint256"},
				{Name: "deadline", Type: "uint256"},
				{Name: "executor", Type: "address"},
			},
		},
		PrimaryType: "Execute",
		Domain: apitypes.TypedDataDomain{
			Name:              domainName,
			Version:           domainVersion,
			ChainId:           (*math.HexOrDecimal256)(in.ChainID),
			VerifyingContract: in.VerifyingContract.Hex(),
		},
		Message: apitypes.TypedDataMessage{
			"calls":    callsMessage,
			"nonce":    (*math.HexOrDecimal256)(in.Nonce),
			"deadline": (*math.HexOrDecimal256)(in.Deadline),
			"executor": in.Executor.Hex(),
		},
	}
}

// ExecuteRequestDigest 计算 EIP-712 摘要（包含 0x19 0x01 前缀的最终 32 字节）。
// 与合约 BatchCallAndSponsor.executeRequestDigest(...) 返回值应完全相同。
func ExecuteRequestDigest(in SignExecuteInput) ([]byte, error) {
	td := BuildExecuteTypedData(in)
	digest, _, err := apitypes.TypedDataAndHash(td)
	if err != nil {
		return nil, fmt.Errorf("typed data hash: %w", err)
	}
	return digest, nil
}

// SignExecute 用 A 的私钥签出 65-byte (r||s||v) 签名，v ∈ {27,28}，
// 与 OZ ECDSA.recover 所期望的格式一致。
//
// 该函数是确定性的：同样的输入 → 同样的 65 字节输出（secp256k1 RFC6979）。
// 用于跨语言（Go ↔ TS）签名一致性比对，详见 cmd/compare。
func SignExecute(in SignExecuteInput) ([]byte, error) {
	digest, err := ExecuteRequestDigest(in)
	if err != nil {
		return nil, err
	}
	sig, err := crypto.Sign(digest, in.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("sign: %w", err)
	}
	if len(sig) != 65 {
		return nil, fmt.Errorf("unexpected signature length: %d", len(sig))
	}
	// crypto.Sign 返回 v ∈ {0,1}；以太坊 EIP-712 期望 v ∈ {27,28}
	sig[64] += 27
	return sig, nil
}
