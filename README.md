# aria2_build_new

![Build and Release](https://github.com/lisrain/aria2_build_new/actions/workflows/build_and_release.yml/badge.svg)

Custom aria2 static build with enhanced features and patches.

**[中文文档](README_CN.md)**

## Features

- ✅ Static build using musl (Linux) and MinGW (Windows)
- ✅ 6 custom patches for enhanced functionality
- ✅ Latest dependencies (OpenSSL, zlib-ng, c-ares, libssh2, etc.)
- ✅ Supports multiple platforms: Linux (arm, aarch64, x86_64, i686, loongarch64) and Windows (x86_64, i686)

## Custom Patches

This build includes the following patches:

1. **Change default path to current directory** - aria2 loads config files from current dir
2. **Unlock connection-per-server limit** - Remove 16 connection limit, allow unlimited connections
3. **Download retry on slow speed and reset** - Auto retry when download speed is too slow
4. **Windows daemon support** - Better support for MinGW builds
5. **Retry on HTTP 4xx errors** - Configurable retry on HTTP 400, 403, 406 errors
6. **Windows OS info for newer versions** - Better Windows version detection

## Download

Download from [Latest Release](https://github.com/lisrain/aria2_build_new/releases/latest).

## Build Configuration

- **Trigger**: Only builds when `build.sh`, workflow, or patches change
- **Schedule**: Weekly build every Saturday
- **Manual**: Can trigger manually from GitHub Actions

## Build Locally

Requirements: Docker

```bash
# Linux builds
docker run --rm -v $(pwd):/build ghcr.io/abcfy2/musl-cross-toolchain-ubuntu:${CROSS_HOST} /build/build.sh

# Windows builds
docker run --rm -v $(pwd):/build ghcr.io/abcfy2/mingw-cross-toolchain-ubuntu:${CROSS_HOST} /build/build.sh
```

Supported platforms:
- `arm-unknown-linux-musleabi`
- `aarch64-unknown-linux-musl`
- `x86_64-unknown-linux-musl`
- `i686-unknown-linux-musl`
- `loongarch64-unknown-linux-musl`
- `x86_64-w64-mingw32`
- `i686-w64-mingw32`

## Environment Variables

- `ARIA2_VER`: Build specific version (default: master)
- `USE_ZLIB_NG`: Use zlib-ng instead of zlib (default: 1)
- `USE_CHINA_MIRROR`: Use China mirrors (default: 0)

## Credits

Based on [aria2-static-build](https://github.com/abcfy2/aria2-static-build) with additional customizations.
