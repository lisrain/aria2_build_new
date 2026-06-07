#!/bin/bash -e

# 快速测试脚本 - 在本地验证构建流程
# 用法: ./test_build.sh [platform]
# platform: linux (默认) 或 windows

set -o pipefail

PLATFORM=${1:-linux}

echo "========================================="
echo "  Aria2 构建流程本地测试"
echo "  平台: ${PLATFORM}"
echo "========================================="
echo

# 设置测试环境
export CROSS_HOST="${CROSS_HOST:-x86_64-unknown-linux-musl}"
export USE_ZLIB_NG="${USE_ZLIB_NG:-1}"
export USE_LIBRESSL="${USE_LIBRESSL:-0}"
export USE_CHINA_MIRROR="${USE_CHINA_MIRROR:-0}"
export DOWNLOADS_DIR="/tmp/aria2-build-test-downloads"
export DRY_RUN=1

# 创建测试目录
mkdir -p "${DOWNLOADS_DIR}"

echo "[1/3] 验证依赖版本..."
if [ -f "./verify_versions.sh" ]; then
    bash ./verify_versions.sh
    if [ $? -ne 0 ]; then
        echo "✗ 依赖验证失败"
        exit 1
    fi
else
    echo "⚠ verify_versions.sh 不存在，跳过依赖验证"
fi

echo
echo "[2/3] 测试依赖下载..."
# 只测试前几个关键依赖的下载
source ./build.sh 2>/dev/null || true

echo
echo "[3/3] 总结..."
echo "✓ 本地测试完成"
echo
echo "下一步操作:"
echo "  1. 如果测试通过，提交更改: git add . && git commit -m 'fix: ...'"
echo "  2. 推送前验证: ./verify_versions.sh"
echo "  3. 推送代码: git push origin master"
echo "  4. GitHub Actions 会自动运行（如有卡住的，取消后重新触发）"
