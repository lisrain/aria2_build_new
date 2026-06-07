#!/bin/bash -e

# 本地验证脚本 - 在推送前运行，检查所有 GitHub 依赖版本
# 用法: ./verify_versions.sh

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  验证所有 GitHub 依赖版本${NC}"
echo -e "${YELLOW}========================================${NC}"
echo

check_version() {
    local name=$1
    local url=$2
    local expected_tag=$3

    echo -n "检查 ${name}... "

    # 尝试下载（只下载头部）
    if wget -q --spider "${url}" 2>/dev/null; then
        echo -e "${GREEN}✓ 可用${NC} (${expected_tag})"
        return 0
    else
        echo -e "${RED}✗ 不可用${NC} (${expected_tag})"
        echo "  URL: ${url}"
        return 1
    fi
}

errors=0

# cmake
check_version "cmake" \
    "https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-linux-x86_64.tar.gz" \
    "v4.3.3" || ((errors++))

# ninja
check_version "ninja" \
    "https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-linux.zip" \
    "v1.13.2" || ((errors++))

# zlib-ng
check_version "zlib-ng" \
    "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/2.3.3.tar.gz" \
    "2.3.3" || ((errors++))

# openssl
check_version "openssl" \
    "https://github.com/openssl/openssl/releases/download/openssl-4.0.0/openssl-4.0.0.tar.gz" \
    "openssl-4.0.0" || ((errors++))

# libxml2
check_version "libxml2" \
    "https://github.com/GNOME/libxml2/archive/refs/tags/v2.15.3.tar.gz" \
    "v2.15.3" || ((errors++))

# sqlite
check_version "sqlite" \
    "https://github.com/sqlite/sqlite/archive/refs/tags/version-3.53.2.tar.gz" \
    "version-3.53.2" || ((errors++))

# c-ares
check_version "c-ares" \
    "https://github.com/c-ares/c-ares/releases/download/v1.34.6/c-ares-1.34.6.tar.gz" \
    "v1.34.6" || ((errors++))

echo
echo -e "${YELLOW}========================================${NC}"
if [ ${errors} -eq 0 ]; then
    echo -e "${GREEN}  ✓ 所有版本验证通过！可以安全推送${NC}"
    echo -e "${YELLOW}========================================${NC}"
    exit 0
else
    echo -e "${RED}  ✗ 发现 ${errors} 个问题，请修复后再推送${NC}"
    echo -e "${YELLOW}========================================${NC}"
    exit 1
fi
