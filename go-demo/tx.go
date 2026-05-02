package eip7702demo

import (
	"context"
	"crypto/ecdsa"
	"fmt"
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/ethclient"
	"github.com/holiman/uint256"
)

// BuildSetCodeTxInput 构造并签 0x04 SetCodeTx。
//
// 角色映射：
//   - From    = B（在 SignSetCodeTx 通过 PrivateKey 体现，外层 sender 由签名 recover）
//   - To      = A 的 EOA 地址（7702 委托后调用 A 等于调用 implementation 的 code）
//   - Data    = execute(calls, deadline, executor, signature) 的 calldata
//   - AuthList = [A 的 7702 授权]
type BuildSetCodeTxInput struct {
	ChainID    *big.Int
	BNonce     uint64           // B 的 tx nonce（PendingNonceAt）
	A          common.Address   // = tx.To
	GasTipCap  *big.Int
	GasFeeCap  *big.Int
	Gas        uint64
	Data       []byte
	AuthList   []types.SetCodeAuthorization
	BPrivateKey *ecdsa.PrivateKey // B 的私钥（外层 tx 签名）
}

// SignSetCodeTx 用 B 的私钥对 SetCodeTx 签名（PragueSigner 自动支持 0x04）。
func SignSetCodeTx(in BuildSetCodeTxInput) (*types.Transaction, error) {
	cid, overflow := uint256.FromBig(in.ChainID)
	if overflow {
		return nil, fmt.Errorf("chainID overflows")
	}
	tip, overflow := uint256.FromBig(in.GasTipCap)
	if overflow {
		return nil, fmt.Errorf("gasTipCap overflows")
	}
	cap_, overflow := uint256.FromBig(in.GasFeeCap)
	if overflow {
		return nil, fmt.Errorf("gasFeeCap overflows")
	}

	inner := &types.SetCodeTx{
		ChainID:   cid,
		Nonce:     in.BNonce,
		GasTipCap: tip,
		GasFeeCap: cap_,
		Gas:       in.Gas,
		To:        in.A,
		Value:     uint256.NewInt(0),
		Data:      in.Data,
		AuthList:  in.AuthList,
	}
	tx := types.NewTx(inner)

	signer := types.LatestSignerForChainID(in.ChainID)
	signed, err := types.SignTx(tx, signer, in.BPrivateKey)
	if err != nil {
		return nil, fmt.Errorf("sign tx: %w", err)
	}
	return signed, nil
}

// SendAndWait 广播并等待 receipt。
func SendAndWait(ctx context.Context, client *ethclient.Client, tx *types.Transaction) (*types.Receipt, error) {
	if err := client.SendTransaction(ctx, tx); err != nil {
		return nil, fmt.Errorf("send tx: %w", err)
	}
	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		r, err := client.TransactionReceipt(ctx, tx.Hash())
		if err == nil && r != nil {
			return r, nil
		}
	}
}
