// 命令：B 代付 gas，把 A 的 ERC20 代币转给 C
//
// 启动时优先从 go-demo/.env 加载环境变量（参见 .env.example）。
// 命令行已有的同名环境变量优先级更高，方便临时覆盖。
//
// 必填：
//   RPC_URL                 EVM RPC（推荐 BSC testnet 已开 Pascal/EIP-7702）
//   PRIVATE_KEY_A           A 的私钥（持币者，链下签 EIP-712 + 7702 授权）
//   PRIVATE_KEY_B           B 的私钥（relayer，发交易付 gas）
//   IMPLEMENTATION_ADDRESS  已部署的 BatchCallAndSponsor 地址
//   TOKEN_ADDRESS           待转的 ERC20 地址
// 可选：
//   C_ADDRESS               接收者，默认 0xCcAD84d0772262AeDe15B1B702d1Bd69D02f177D
//   DEMO_EXECUTOR           允许提交者，留空 → executor = B
//   DEMO_DEADLINE_OFFSET    deadline 距当前秒数，默认 600
//
// 跑：
//   cd eip_7702/go-demo
//   cp .env.example .env && vim .env  # 填入你的值
//   go run ./cmd/sponsored
package main

import (
	"context"
	"fmt"
	"log"
	"math/big"
	"os"
	"strconv"
	"strings"
	"time"

	demo "github.com/oddfi/eip7702-go-demo"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

func main() {
	// 启动时把 go-demo/.env 里的变量塞进 os.Environ。
	// 走相对路径："go run ./cmd/sponsored" 的 cwd 就是 go-demo 根目录。
	if err := loadDotEnv(".env"); err != nil {
		log.Fatal(err)
	}

	rpcURL := mustEnv("RPC_URL")
	aKeyHex := mustEnv("PRIVATE_KEY_A")
	bKeyHex := mustEnv("PRIVATE_KEY_B")
	implAddr := common.HexToAddress(mustEnv("IMPLEMENTATION_ADDRESS"))
	tokenAddr := common.HexToAddress(mustEnv("TOKEN_ADDRESS"))
	cAddr := common.HexToAddress(getEnv("C_ADDRESS", "0xCcAD84d0772262AeDe15B1B702d1Bd69D02f177D"))

	deadlineOffset, _ := strconv.ParseInt(getEnv("DEMO_DEADLINE_OFFSET", "600"), 10, 64)

	aKey, err := crypto.HexToECDSA(strings.TrimPrefix(aKeyHex, "0x"))
	must(err)
	bKey, err := crypto.HexToECDSA(strings.TrimPrefix(bKeyHex, "0x"))
	must(err)

	aAddr := crypto.PubkeyToAddress(aKey.PublicKey)
	bAddr := crypto.PubkeyToAddress(bKey.PublicKey)

	executorEnv := os.Getenv("DEMO_EXECUTOR")
	var executor common.Address
	if executorEnv == "" {
		executor = bAddr
	} else {
		executor = common.HexToAddress(executorEnv)
	}

	transferAmount, _ := new(big.Int).SetString("1230000000000000000", 10) // 1.23

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	client, err := ethclient.DialContext(ctx, rpcURL)
	must(err)
	defer client.Close()

	chainID, err := client.ChainID(ctx)
	must(err)

	deadline := big.NewInt(time.Now().Unix() + deadlineOffset)

	fmt.Println("═══════════════════════════════════════════════════════")
	fmt.Println("  EIP-7702 Go Demo — B 代付 gas")
	fmt.Println("═══════════════════════════════════════════════════════")
	fmt.Printf("  ChainID:        %s\n", chainID)
	fmt.Printf("  RPC:            %s\n", rpcURL)
	fmt.Printf("  A:              %s\n", aAddr.Hex())
	fmt.Printf("  B (relayer):    %s\n", bAddr.Hex())
	fmt.Printf("  C (recipient):  %s\n", cAddr.Hex())
	fmt.Printf("  Implementation: %s\n", implAddr.Hex())
	fmt.Printf("  Token:          %s\n", tokenAddr.Hex())
	fmt.Printf("  Amount:         %s\n", transferAmount)
	fmt.Printf("  Executor:       %s\n", executor.Hex())
	fmt.Printf("  Deadline:       %s\n\n", deadline)

	// Step 1：合约 nonce（防签名重放）
	contractNonce, err := demo.ReadContractNonce(ctx, client, aAddr)
	must(err)
	fmt.Printf("[Step 1] 合约 nonce: %s\n", contractNonce)

	// Step 2：calls = [token.transfer(C, amount)]
	transferCalldata, err := demo.EncodeERC20Transfer(cAddr, transferAmount)
	must(err)
	calls := []demo.Call{{To: tokenAddr, Value: big.NewInt(0), Data: transferCalldata}}
	fmt.Printf("[Step 2] calls: token.transfer(C, %s)\n", transferAmount)

	// Step 3：A 的 EOA tx nonce（用于 7702 authorization tuple）
	aTxNonce, err := client.NonceAt(ctx, aAddr, nil)
	must(err)
	fmt.Printf("[Step 3] A 的 tx nonce (用于 7702 auth): %d\n", aTxNonce)

	auth, err := demo.SignAuthorization(demo.SignAuthorizationInput{
		ChainID:        chainID,
		Implementation: implAddr,
		AuthNonce:      aTxNonce,
		PrivateKey:     aKey,
	})
	must(err)
	fmt.Println("[Step 3] ✅ 7702 authorization 已签")

	// Step 4：A 签 EIP-712 Execute
	signature, err := demo.SignExecute(demo.SignExecuteInput{
		ChainID:           chainID,
		VerifyingContract: aAddr,
		Calls:             calls,
		Nonce:             contractNonce,
		Deadline:          deadline,
		Executor:          executor,
		PrivateKey:        aKey,
	})
	must(err)
	fmt.Printf("[Step 4] ✅ Execute 签名: 0x%x\n", signature)

	// Step 5：拼 calldata
	callData, err := demo.EncodeBatchExecute(calls, deadline, executor, signature)
	must(err)

	// Step 6：B 的 tx nonce + 签 SetCodeTx
	bTxNonce, err := client.PendingNonceAt(ctx, bAddr)
	must(err)

	tipCap, err := client.SuggestGasTipCap(ctx)
	must(err)
	feeCap, err := client.SuggestGasPrice(ctx)
	must(err)
	// fee cap 给点冗余
	feeCap = new(big.Int).Add(feeCap, tipCap)

	tx, err := demo.SignSetCodeTx(demo.BuildSetCodeTxInput{
		ChainID:     chainID,
		BNonce:      bTxNonce,
		A:           aAddr,
		GasTipCap:   tipCap,
		GasFeeCap:   feeCap,
		Gas:         500_000, // EIP-7702 estimateGas 不一定支持 AuthList，给个 generous fixed
		Data:        callData,
		AuthList:    []types.SetCodeAuthorization{auth},
		BPrivateKey: bKey,
	})
	must(err)

	fmt.Printf("[Step 6] tx hash: %s\n", tx.Hash().Hex())

	receipt, err := demo.SendAndWait(ctx, client, tx)
	must(err)
	if receipt.Status == 1 {
		fmt.Printf("[Step 7] ✅ 成功，区块 #%d\n", receipt.BlockNumber)
	} else {
		fmt.Printf("[Step 7] ❌ 失败，区块 #%d\n", receipt.BlockNumber)
		os.Exit(1)
	}

	newNonce, _ := demo.ReadContractNonce(ctx, client, aAddr)
	fmt.Printf("\nA 新合约 nonce: %s（应为 %s）\n", newNonce, new(big.Int).Add(contractNonce, big.NewInt(1)))
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("环境变量未设置：%s", k)
	}
	return v
}

func getEnv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func must(err error) {
	if err != nil {
		log.Fatal(err)
	}
}
