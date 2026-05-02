package eip7702demo

import (
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/holiman/uint256"
)

// SignAuthorizationInput 是签 EIP-7702 授权所需输入。
//
// 关键：AuthNonce 必须 = A 的 EOA 当前 tx 计数（ethclient.NonceAt(ctx, A, nil)），
// 这是 7702 协议层规定的，跟合约里的 nonce 没关系。
//
// 自代付（A 自己发 tx）情形：A 这笔 tx 自己会消耗 NonceAt(A) → 授权签名要用 NonceAt(A) + 1
// B 代付情形：A 没发 tx → 直接用 NonceAt(A)
type SignAuthorizationInput struct {
	ChainID    *big.Int
	Implementation common.Address
	AuthNonce  uint64
	PrivateKey *ecdsa.PrivateKey // A 的私钥
}

// SignAuthorization 签出一份带 V/R/S 的 SetCodeAuthorization。
// 对应 viem 的 signAuthorization。
func SignAuthorization(in SignAuthorizationInput) (types.SetCodeAuthorization, error) {
	cid, overflow := uint256.FromBig(in.ChainID)
	if overflow {
		return types.SetCodeAuthorization{}, fmt.Errorf("chainID overflows uint256")
	}
	auth := types.SetCodeAuthorization{
		ChainID: *cid,
		Address: in.Implementation,
		Nonce:   in.AuthNonce,
	}
	signed, err := types.SignSetCode(in.PrivateKey, auth)
	if err != nil {
		return types.SetCodeAuthorization{}, fmt.Errorf("sign authorization: %w", err)
	}
	return signed, nil
}
