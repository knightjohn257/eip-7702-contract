package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// loadDotEnv 读取一个极简的 KEY=value 文件并把里面的变量塞进 os.Environ。
//
// 已经存在的同名环境变量优先（与 dotenv 约定一致），所以你可以临时用
// 命令行 KEY=value go run ... 覆盖文件里的值。
//
// 支持的语法：
//   - # 开头的行视为注释
//   - 空行忽略
//   - KEY=value，等号两侧自动 trim 空白
//   - value 两端的双引号 / 单引号自动剥掉
//
// 不支持（demo 用不上，避免引入复杂度）：
//   - export KEY=value
//   - 变量插值 ${OTHER}
//   - 多行 value
//
// path 文件不存在时不报错，返回 nil（让脚本可以"完全靠系统环境变量"运行）。
func loadDotEnv(path string) error {
	abs, _ := filepath.Abs(path)
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "[env] %s 不存在，跳过 .env 加载\n", abs)
			return nil
		}
		return fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	fmt.Fprintf(os.Stderr, "[env] 从 %s 加载\n", abs)

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		// 去掉成对引号
		if n := len(val); n >= 2 {
			if (val[0] == '"' && val[n-1] == '"') ||
				(val[0] == '\'' && val[n-1] == '\'') {
				val = val[1 : n-1]
			}
		}
		// 已有环境变量优先 — 命令行可临时覆盖
		if _, exists := os.LookupEnv(key); !exists {
			os.Setenv(key, val)
		}
	}
	return scanner.Err()
}
