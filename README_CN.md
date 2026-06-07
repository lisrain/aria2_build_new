# aria2_build_new

![构建状态](https://github.com/lisrain/aria2_build_new/actions/workflows/build_and_release.yml/badge.svg)

自定义 aria2 静态编译版本，包含增强功能和补丁。

**[English](README.md)**

## 特性

- ✅ 使用 musl (Linux) 和 MinGW (Windows) 静态编译
- ✅ 6 个自定义补丁增强功能
- ✅ 最新依赖库 (OpenSSL, zlib-ng, c-ares, libssh2 等)
- ✅ 支持多平台：Linux (arm, aarch64, x86_64, i686, loongarch64) 和 Windows (x86_64, i686)

## 自定义补丁

本编译包含以下补丁：

1. **修改默认路径为当前目录** - aria2 从当前目录加载配置文件
2. **解锁每服务器连接数限制** - 移除 16 连接限制，允许无限连接
3. **下载速度过慢时重试** - 下载速度过慢时自动重试
4. **Windows 守护进程支持** - 更好的 MinGW 构建支持
5. **HTTP 4xx 错误重试** - 可配置在 HTTP 400, 403, 406 错误时重试
6. **Windows 新版本系统信息** - 更好的 Windows 版本检测

## 下载

从 [最新版本](https://github.com/lisrain/aria2_build_new/releases/latest) 下载。

## 构建配置

- **触发条件**：仅在 `build.sh`、workflow 或补丁文件变化时构建
- **定时构建**：每周六自动构建
- **手动触发**：可从 GitHub Actions 手动触发

## 本地构建

要求：Docker

```bash
# Linux 构建
docker run --rm -v $(pwd):/build ghcr.io/abcfy2/musl-cross-toolchain-ubuntu:${CROSS_HOST} /build/build.sh

# Windows 构建
docker run --rm -v $(pwd):/build ghcr.io/abcfy2/mingw-cross-toolchain-ubuntu:${CROSS_HOST} /build/build.sh
```

支持的平台：
- `arm-unknown-linux-musleabi`
- `aarch64-unknown-linux-musl`
- `x86_64-unknown-linux-musl`
- `i686-unknown-linux-musl`
- `loongarch64-unknown-linux-musl`
- `x86_64-w64-mingw32`
- `i686-w64-mingw32`

## 环境变量

- `ARIA2_VER`：指定编译版本（默认：master）
- `USE_ZLIB_NG`：使用 zlib-ng 替代 zlib（默认：1）
- `USE_CHINA_MIRROR`：使用中国镜像（默认：0）

## 致谢

基于 [aria2-static-build](https://github.com/abcfy2/aria2-static-build) 进行自定义修改。
