#!/bin/bash -e

# This script is for static cross compiling
# Please run this script in docker image: abcfy2/musl-cross-toolchain-ubuntu:${CROSS_HOST}
# E.g: docker run --rm -v `git rev-parse --show-toplevel`:/build abcfy2/musl-cross-toolchain-ubuntu:arm-unknown-linux-musleabi /build/build.sh
# Artifacts will copy to the same directory.

set -o pipefail

# value from: https://hub.docker.com/repository/docker/abcfy2/musl-cross-toolchain-ubuntu/tags
# export CROSS_HOST="${CROSS_HOST:-arm-unknown-linux-musleabi}"
# value from openssl source: ./Configure LIST
case "${CROSS_HOST}" in
  arm*linux*)
    export OPENSSL_COMPILER=linux-armv4
    ;;
  aarch64*linux*)
    export OPENSSL_COMPILER=linux-aarch64
    ;;
  mips64*linux*)
    export OPENSSL_COMPILER=linux64-mips64
    ;;
  mips*linux* | mipsel*linux*)
    export OPENSSL_COMPILER=linux-mips32
    ;;
  x86_64*linux*)
    export OPENSSL_COMPILER=linux-x86_64
    ;;
  i?86*linux*)
    export OPENSSL_COMPILER=linux-x86
    ;;
  s390x*linux*)
    export OPENSSL_COMPILER=linux64-s390x
    ;;
  loongarch64*linux*)
    export OPENSSL_COMPILER=linux64-loongarch64
    ;;
  x86_64*mingw*)
    export OPENSSL_COMPILER=mingw64
    ;;
  i686*mingw*)
    export OPENSSL_COMPILER=mingw
    ;;
  *)
    export OPENSSL_COMPILER=gcc
    ;;
esac

export USE_ZLIB_NG="${USE_ZLIB_NG:-1}"
export USE_OFFICIAL_MINGW="${USE_OFFICIAL_MINGW:-1}"

retry() {
  # max retry 15 times
  try=30
  # sleep 30s every retry
  sleep_time=30
  for i in $(seq ${try}); do
    echo "executing with retry: $@" >&2
    if eval "$@"; then
      return 0
    else
      echo "execute '$@' failed, tries: ${i}" >&2
      sleep ${sleep_time}
    fi
  done
  echo "execute '$@' failed" >&2
  return 1
}

source /etc/os-release
dpkg --add-architecture i386
# Ubuntu mirror for local building
if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  if [ -f "/etc/apt/sources.list.d/ubuntu.sources" ]; then
    cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://mirrors.bfsu.edu.cn/ubuntu/
Suites: ${UBUNTU_CODENAME} ${UBUNTU_CODENAME}-updates ${UBUNTU_CODENAME}-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://mirrors.bfsu.edu.cn/ubuntu/
Suites: ${UBUNTU_CODENAME}-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  else
    cat >/etc/apt/sources.list <<EOF
deb http://mirrors.bfsu.edu.cn/ubuntu/ ${UBUNTU_CODENAME} main restricted universe multiverse
deb http://mirrors.bfsu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb http://mirrors.bfsu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://mirrors.bfsu.edu.cn/ubuntu/ ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF
  fi
fi

export DEBIAN_FRONTEND=noninteractive

# keep debs in container for store cache in docker volume
rm -f /etc/apt/apt.conf.d/*
echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/01keep-debs
echo -e 'Acquire::https::Verify-Peer "false";\nAcquire::https::Verify-Host "false";' >/etc/apt/apt.conf.d/99-trust-https

apt update
apt install -y g++ \
  make \
  libtool \
  jq \
  pkgconf \
  file \
  tcl \
  autoconf \
  automake \
  autopoint \
  patch \
  wget \
  unzip \
  bzip2

BUILD_ARCH="$(gcc -dumpmachine)"
TARGET_ARCH="${CROSS_HOST%%-*}"
TARGET_HOST="${CROSS_HOST#*-}"
case "${TARGET_ARCH}" in
  "armel"*)
    TARGET_ARCH=armel
    ;;
  "arm"*)
    TARGET_ARCH=arm
    ;;
  i?86*)
    TARGET_ARCH=i386
    ;;
esac
case "${TARGET_HOST}" in
  *"mingw"*)
    TARGET_HOST=Windows
    apt update
    apt install -y wine
    export WINEPREFIX=/tmp/
    RUNNER_CHECKER="wine"
    ;;
  *)
    TARGET_HOST=Linux
    apt install -y "qemu-user"
    RUNNER_CHECKER="qemu-${TARGET_ARCH}"
    ;;
esac

export PATH="${CROSS_ROOT}/bin:${PATH}"
export CROSS_PREFIX="${CROSS_ROOT}/${CROSS_HOST}"
export PKG_CONFIG_LIBDIR="${CROSS_PREFIX}/lib64/pkgconfig:${CROSS_PREFIX}/lib/pkgconfig"
export LDFLAGS="-L${CROSS_PREFIX}/lib64 -L${CROSS_PREFIX}/lib -s -static --static"
export CFLAGS="-I${CROSS_PREFIX}/include"
if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
  export CC="${CROSS_HOST}-gcc"
  export CXX="${CROSS_HOST}-g++"
else
  export CC="${CROSS_HOST}-cc"
  export CXX="${CROSS_HOST}-c++"
fi
export CPP="${CROSS_HOST}-cpp"

SELF_DIR="$(dirname "$(realpath "${0}")")"
BUILD_INFO="${SELF_DIR}/build_info.md"

# Create download cache directory
mkdir -p "${SELF_DIR}/downloads/"
export DOWNLOADS_DIR="${SELF_DIR}/downloads"

if [ x"${USE_ZLIB_NG}" = x1 ]; then
  ZLIB=zlib-ng
else
  ZLIB=zlib
fi
if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
  USE_ZLIB_NG=0
  ZLIB=zlib
  SSL=WinTLS
elif [ x"${USE_LIBRESSL}" = x1 ]; then
  SSL=LibreSSL
else
  SSL=OpenSSL
fi

echo "## Build Info - ${CROSS_HOST} with ${SSL} and ${ZLIB}" >"${BUILD_INFO}"
echo "Building using these dependencies:" >>"${BUILD_INFO}"

prepare_cmake() {
  if ! which cmake &>/dev/null; then
    cmake_latest_ver="$(retry wget -qO- --compression=auto https://cmake.org/download/ \| grep "'Latest Release'" \| sed -r "'s/.*Latest Release\s*\((.+)\).*/\1/'" \| head -1)"
    cmake_binary_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
    cmake_sha256_url="https://github.com/Kitware/CMake/releases/download/v${cmake_latest_ver}/cmake-${cmake_latest_ver}-SHA-256.txt"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      cmake_binary_url="https://gh-proxy.com/${cmake_binary_url}"
      cmake_sha256_url="https://gh-proxy.com/${cmake_sha256_url}"
    fi
    if [ -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      cd "${DOWNLOADS_DIR}"
      cmake_sha256="$(retry wget -qO- --compression=auto "${cmake_sha256_url}")"
      if ! echo "${cmake_sha256}" | grep "cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" | sha256sum -c; then
        rm -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz"
      fi
    fi
    if [ ! -f "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" "${cmake_binary_url}"
    fi
    tar -zxf "${DOWNLOADS_DIR}/cmake-${cmake_latest_ver}-linux-x86_64.tar.gz" -C /usr/local --strip-components 1
  fi
  cmake --version
}

prepare_ninja() {
  if ! which ninja &>/dev/null; then
    ninja_ver="$(retry wget -qO- --compression=auto https://ninja-build.org/ \| grep "'The last Ninja release is'" \| sed -r "'s@.*<b>(.+)</b>.*@\1@'" \| head -1)"
    ninja_binary_url="https://github.com/ninja-build/ninja/releases/download/${ninja_ver}/ninja-linux.zip"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      ninja_binary_url="https://gh-proxy.com/${ninja_binary_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip" ]; then
      rm -f "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part"
      retry wget -cT10 -O "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${ninja_binary_url}"
      mv -fv "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip.part" "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
    fi
    unzip -d /usr/local/bin "${DOWNLOADS_DIR}/ninja-${ninja_ver}-linux.zip"
  fi
  echo "Ninja version $(ninja --version)"
}

prepare_zlib() {
  if [ x"${USE_ZLIB_NG}" = x"1" ]; then
    zlib_ng_latest_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/zlib-ng/zlib-ng/releases \| jq -r "'.[0].tag_name'")"
    zlib_ng_latest_url="https://github.com/zlib-ng/zlib-ng/archive/refs/tags/${zlib_ng_latest_tag}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      zlib_ng_latest_url="https://gh-proxy.com/${zlib_ng_latest_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${zlib_ng_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz.part" "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    tar -zxf "${DOWNLOADS_DIR}/zlib-ng-${zlib_ng_latest_tag}.tar.gz" --strip-components=1 -C "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    cd "/usr/src/zlib-ng-${zlib_ng_latest_tag}"
    rm -fr build
    cmake -B build \
      -G Ninja \
      -DBUILD_SHARED_LIBS=OFF \
      -DZLIB_COMPAT=ON \
      -DCMAKE_SYSTEM_NAME="${TARGET_HOST}" \
      -DCMAKE_INSTALL_PREFIX="${CROSS_PREFIX}" \
      -DCMAKE_C_COMPILER="${CROSS_HOST}-cc" \
      -DCMAKE_SYSTEM_PROCESSOR="${TARGET_ARCH}" \
      -DBUILD_TESTING=OFF
    cmake --build build
    cmake --install build
    zlib_ng_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    echo "- zlib-ng: ${zlib_ng_ver}, source: ${zlib_ng_latest_url:-cached zlib-ng}" >>"${BUILD_INFO}"
    # Fix mingw build sharedlibdir lost issue
    sed -i 's@^sharedlibdir=.*@sharedlibdir=${libdir}@' "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc"
  else
    if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
      zlib_tag="${MINGW_ZLIB_VER:-1.3.1}"
      zlib_archive="zlib-${zlib_tag}.tar.gz"
      zlib_latest_url="https://github.com/madler/zlib/releases/download/v${zlib_tag}/${zlib_archive}"
      zlib_tar_flags="-zxf"
    else
      zlib_tag="$(retry wget -qO- --compression=auto https://zlib.net/ \| grep -i "'<FONT.*FONT>'" \| sed -r "'s/.*zlib\s*([^<]+).*/\1/'" \| head -1)"
      zlib_archive="zlib-${zlib_tag}.tar.xz"
      zlib_latest_url="https://zlib.net/${zlib_archive}"
      zlib_tar_flags="-Jxf"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/${zlib_archive}" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/${zlib_archive}.part" "${zlib_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/${zlib_archive}.part" "${DOWNLOADS_DIR}/${zlib_archive}"
    fi
    mkdir -p "/usr/src/zlib-${zlib_tag}"
    tar ${zlib_tar_flags} "${DOWNLOADS_DIR}/${zlib_archive}" --strip-components=1 -C "/usr/src/zlib-${zlib_tag}"
    cd "/usr/src/zlib-${zlib_tag}"
    if [ x"${TARGET_HOST}" = xWindows ]; then
      make -f win32/Makefile.gcc BINARY_PATH="${CROSS_PREFIX}/bin" INCLUDE_PATH="${CROSS_PREFIX}/include" LIBRARY_PATH="${CROSS_PREFIX}/lib" SHARED_MODE=0 PREFIX="${CROSS_HOST}-" -j$(nproc) install
    else
      CHOST="${CROSS_HOST}" ./configure --prefix="${CROSS_PREFIX}" --static
      make -j$(nproc)
      make install
    fi
    zlib_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/zlib.pc")"
    echo "- zlib: ${zlib_ver}, source: ${zlib_latest_url:-cached zlib}" >>"${BUILD_INFO}"
  fi
}

prepare_gmp() {
  gmp_tag="${MINGW_GMP_VER:-6.3.0}"
  gmp_archive="gmp-${gmp_tag}.tar.xz"
  gmp_latest_url="https://ftpmirror.gnu.org/gmp/${gmp_archive}"
  if [ ! -f "${DOWNLOADS_DIR}/${gmp_archive}" ]; then
    for gmp_download_url in \
      "https://ftpmirror.gnu.org/gmp/${gmp_archive}" \
      "https://ftp.gnu.org/gnu/gmp/${gmp_archive}" \
      "https://mirrors.kernel.org/gnu/gmp/${gmp_archive}" \
      "https://gmplib.org/download/gmp/${gmp_archive}"; do
      echo "Downloading GMP from ${gmp_download_url}"
      rm -f "${DOWNLOADS_DIR}/${gmp_archive}.part"
      if wget -cT10 -t 3 -O "${DOWNLOADS_DIR}/${gmp_archive}.part" "${gmp_download_url}"; then
        mv -fv "${DOWNLOADS_DIR}/${gmp_archive}.part" "${DOWNLOADS_DIR}/${gmp_archive}"
        gmp_latest_url="${gmp_download_url}"
        break
      fi
    done
    if [ ! -f "${DOWNLOADS_DIR}/${gmp_archive}" ]; then
      echo "Failed to download ${gmp_archive} from all known mirrors" >&2
      return 1
    fi
  fi
  mkdir -p "/usr/src/gmp-${gmp_tag}"
  tar -Jxf "${DOWNLOADS_DIR}/${gmp_archive}" --strip-components=1 -C "/usr/src/gmp-${gmp_tag}"
  cd "/usr/src/gmp-${gmp_tag}"
  CC="${CROSS_HOST}-gcc" ./configure \
    --disable-shared \
    --enable-static \
    --prefix="${CROSS_PREFIX}" \
    --host="${CROSS_HOST}" \
    --build="${BUILD_ARCH}" \
    --disable-cxx \
    CFLAGS="-std=gnu17 -mtune=generic -O2 -g0" || {
      cat config.log
      return 1
    }
  make -j$(nproc)
  make install
  echo "- gmp: ${gmp_tag}, source: ${gmp_latest_url:-cached gmp}" >>"${BUILD_INFO}"
}

prepare_expat() {
  expat_tag="${MINGW_EXPAT_VER:-2.5.0}"
  expat_release_tag="R_${expat_tag//./_}"
  expat_archive="expat-${expat_tag}.tar.bz2"
  expat_latest_url="https://github.com/libexpat/libexpat/releases/download/${expat_release_tag}/${expat_archive}"
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    expat_latest_url="https://gh-proxy.com/${expat_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/${expat_archive}" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/${expat_archive}.part" "${expat_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/${expat_archive}.part" "${DOWNLOADS_DIR}/${expat_archive}"
  fi
  mkdir -p "/usr/src/expat-${expat_tag}"
  tar -jxf "${DOWNLOADS_DIR}/${expat_archive}" --strip-components=1 -C "/usr/src/expat-${expat_tag}"
  cd "/usr/src/expat-${expat_tag}"
  ./configure \
    --disable-shared \
    --enable-static \
    --prefix="${CROSS_PREFIX}" \
    --host="${CROSS_HOST}" \
    --build="${BUILD_ARCH}"
  make -j$(nproc)
  make install
  expat_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/expat.pc")"
  echo "- expat: ${expat_ver}, source: ${expat_latest_url:-cached expat}" >>"${BUILD_INFO}"
}

prepare_xz() {
  # Download from github release (now breakdown)
  # xz_release_info="$(retry wget -qO- --compression=auto https://api.github.com/repos/tukaani-project/xz/releases \| jq -r "'[.[] | select(.prerelease == false)][0]'")"
  # xz_tag="$(printf '%s' "${xz_release_info}" | jq -r '.tag_name')"
  # xz_archive_name="$(printf '%s' "${xz_release_info}" | jq -r '.assets[].name | select(endswith("tar.xz"))')"
  # xz_latest_url="https://github.com/tukaani-project/xz/releases/download/${xz_tag}/${xz_archive_name}"
  # if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
  #   xz_latest_url="https://gh-proxy.com/${xz_latest_url}"
  # fi
  # Download from sourceforge
  xz_tag="$(retry wget -qO- --compression=auto https://sourceforge.net/projects/lzmautils/files/ \| grep -i \'span class=\"sub-label\"\' \| head -1 \| sed -r "'s/.*xz-(.+)\.tar\.gz.*/\1/'")"
  xz_latest_url="https://sourceforge.net/projects/lzmautils/files/xz-${xz_tag}.tar.xz"
  if [ ! -f "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${xz_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz.part" "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz"
  fi
  mkdir -p "/usr/src/xz-${xz_tag}"
  tar -Jxf "${DOWNLOADS_DIR}/xz-${xz_tag}.tar.xz" --strip-components=1 -C "/usr/src/xz-${xz_tag}"
  cd "/usr/src/xz-${xz_tag}"
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --enable-static --disable-shared --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc
  make -j$(nproc)
  make install
  xz_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/liblzma.pc")"
  echo "- xz: ${xz_ver}, source: ${xz_latest_url:-cached xz}" >>"${BUILD_INFO}"
}

prepare_ssl() {
  if [ x"${USE_LIBRESSL}" = x1 ]; then
    # libressl
    libressl_tag="$(retry wget -qO- --compression=auto https://www.libressl.org/index.html \| grep "'release is'" \| tail -1 \| sed -r "'s/.* (.+)<.*>$/\1/'")"
    libressl_latest_url="https://cloudflare.cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-${libressl_tag}.tar.gz"
    if [ ! -f "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz.part" "${libressl_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz"
    fi
    mkdir -p "/usr/src/libressl-${libressl_tag}"
    tar -zxf "${DOWNLOADS_DIR}/libressl-${libressl_tag}.tar.gz" --strip-components=1 -C "/usr/src/libressl-${libressl_tag}"
    cd "/usr/src/libressl-${libressl_tag}"
    if [ ! -f "./configure" ]; then
      ./autogen.sh
    fi
    ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --enable-static --disable-shared --disable-tests --with-openssldir=/etc/ssl
    make -j$(nproc)
    make install_sw
    libressl_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/openssl.pc")"
    echo "- libressl: ${libressl_ver}, source: ${libressl_latest_url:-cached libressl}" >>"${BUILD_INFO}"
  else
    # openssl
    openssl_filename="$(retry wget -qO- --compression=auto https://openssl-library.org/source/ \| grep -o "'>openssl-3\(\.[0-9]*\)*tar.gz<'" \| grep -o "'[^>]*.tar.gz'" \| sort -nr \| head -1)"
    openssl_ver="$(echo "${openssl_filename}" | sed -r 's/openssl-(.+)\.tar\.gz/\1/')"
    openssl_latest_url="https://github.com/openssl/openssl/releases/download/openssl-${openssl_ver}/${openssl_filename}"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      openssl_latest_url="https://gh-proxy.com/${openssl_latest_url}"
    fi
    if [ ! -f "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" ]; then
      retry wget -cT10 -O "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${openssl_latest_url}"
      mv -fv "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz.part" "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz"
    fi
    mkdir -p "/usr/src/openssl-${openssl_ver}"
    tar -zxf "${DOWNLOADS_DIR}/openssl-${openssl_ver}.tar.gz" --strip-components=1 -C "/usr/src/openssl-${openssl_ver}"
    cd "/usr/src/openssl-${openssl_ver}"
    CC="cc" ./Configure -static --cross-compile-prefix="${CROSS_HOST}-" --prefix="${CROSS_PREFIX}" no-apps "${OPENSSL_COMPILER}" --openssldir=/etc/ssl
    make -j$(nproc)
    make install_sw
    openssl_ver="$(grep Version: "${CROSS_PREFIX}"/lib*/pkgconfig/openssl.pc)"
    echo "- openssl: ${openssl_ver}, source: ${openssl_latest_url:-cached openssl}" >>"${BUILD_INFO}"
  fi
}

prepare_libiconv() {
  libiconv_tag="$(retry wget -qO- --compression=auto https://ftpmirror.gnu.org/libiconv/ \| grep -i "'libiconv-.*\.tar\.gz'" \| sed -r "'s/.*libiconv-([^<]+)\.tar\.gz.*/\1/'" \| sort -Vr \| head -1)"
  libiconv_latest_url="https://ftpmirror.gnu.org/libiconv/libiconv-${libiconv_tag}.tar.gz"
  if [ ! -f "${DOWNLOADS_DIR}/libiconv-${libiconv_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/libiconv-${libiconv_tag}.tar.gz.part" "${libiconv_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/libiconv-${libiconv_tag}.tar.gz.part" "${DOWNLOADS_DIR}/libiconv-${libiconv_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/libiconv-${libiconv_tag}"
  tar -zxf "${DOWNLOADS_DIR}/libiconv-${libiconv_tag}.tar.gz" --strip-components=1 -C "/usr/src/libiconv-${libiconv_tag}"
  cd "/usr/src/libiconv-${libiconv_tag}"
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --enable-static --disable-shared
  make -j$(nproc)
  make install-lib
  echo "- libiconv: ${libiconv_tag}, source: ${libiconv_latest_url:-cached libiconv}" >>"${BUILD_INFO}"
}

prepare_libxml2() {
  libxml2_latest_url="$(retry wget -qO- --compression=auto 'https://gitlab.gnome.org/api/graphql' --header="'Content-Type: application/json'" --post-data="'{\"query\":\"query {project(fullPath:\\\"GNOME/libxml2\\\"){releases(sort:RELEASED_AT_DESC){nodes{assets{links{nodes{directAssetUrl}}}}}}}\"}'" \| jq -r "'.data.project.releases.nodes | map(select(.assets.links.nodes | length > 0)) | .[0].assets.links.nodes[0].directAssetUrl'")"
  libxml2_tag="$(echo "${libxml2_latest_url}" | sed -r 's/.*libxml2-(.+).tar.*/\1/')"
  libxml2_filename="$(echo "${libxml2_latest_url}" | sed -r 's/.*(libxml2-(.+).tar.*)/\1/')"
  if [ ! -f "${DOWNLOADS_DIR}/${libxml2_filename}" ]; then
    retry wget -c -O "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${libxml2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/${libxml2_filename}.part" "${DOWNLOADS_DIR}/${libxml2_filename}"
  fi
  mkdir -p "/usr/src/libxml2-${libxml2_tag}"
  tar -axf "${DOWNLOADS_DIR}/${libxml2_filename}" --strip-components=1 -C "/usr/src/libxml2-${libxml2_tag}"
  cd "/usr/src/libxml2-${libxml2_tag}"
  ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-silent-rules --without-python --without-icu --enable-static --disable-shared
  make -j$(nproc)
  make install
  libxml2_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"libxml-*.pc)"
  echo "- libxml2: ${libxml2_ver}, source: ${libxml2_latest_url:-cached libxml2}" >>"${BUILD_INFO}"
}

prepare_sqlite() {
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
    sqlite_tag="${MINGW_SQLITE_AUTOCONF_VER:-3430100}"
    sqlite_year="${MINGW_SQLITE_YEAR:-2023}"
    sqlite_archive="sqlite-autoconf-${sqlite_tag}.tar.gz"
    sqlite_src_dir="sqlite-autoconf-${sqlite_tag}"
    sqlite_latest_url="https://www.sqlite.org/${sqlite_year}/${sqlite_archive}"
  else
    sqlite_tag="$(retry wget -qO- --compression=auto https://www.sqlite.org/index.html \| sed -nr "'s/.*>Version (.+)<.*/\1/p'")"
    sqlite_archive="sqlite-${sqlite_tag}.tar.gz"
    sqlite_src_dir="sqlite-${sqlite_tag}"
    sqlite_latest_url="https://github.com/sqlite/sqlite/archive/refs/tags/version-${sqlite_tag}.tar.gz"
    if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
      sqlite_latest_url="https://gh-proxy.com/${sqlite_latest_url}"
    fi
  fi
  if [ ! -f "${DOWNLOADS_DIR}/${sqlite_archive}" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/${sqlite_archive}.part" "${sqlite_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/${sqlite_archive}.part" "${DOWNLOADS_DIR}/${sqlite_archive}"
  fi
  mkdir -p "/usr/src/${sqlite_src_dir}"
  tar -zxf "${DOWNLOADS_DIR}/${sqlite_archive}" --strip-components=1 -C "/usr/src/${sqlite_src_dir}"
  cd "/usr/src/${sqlite_src_dir}"
  if [ x"${TARGET_HOST}" = x"Windows" ] && [ x"${USE_OFFICIAL_MINGW}" != x1 ]; then
    if [ ! -f "${CROSS_PREFIX}/lib/libsqlite3.a" ]; then
      ln -sv libsqlite3.lib "${CROSS_PREFIX}/lib/libsqlite3.a"
    fi
    SQLITE_EXT_CONF="--disable-load-extension"
  fi
  ./configure --build="${BUILD_ARCH}" --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared ${SQLITE_EXT_CONF}
  make -j$(nproc)
  make install
  sqlite_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/"sqlite*.pc)"
  echo "- sqlite: ${sqlite_ver}, source: ${sqlite_latest_url:-cached sqlite}" >>"${BUILD_INFO}"
}

prepare_c_ares() {
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
    cares_ver="${MINGW_CARES_VER:-1.19.1}"
    cares_release_tag="cares-${cares_ver//./_}"
    cares_latest_url="https://github.com/c-ares/c-ares/releases/download/${cares_release_tag}/c-ares-${cares_ver}.tar.gz"
  else
    # cares_latest_tag="$(retry wget -qO- --compression=auto https://api.github.com/repos/c-ares/c-ares/releases \| jq -r "'.[0].tag_name'")"
    # waiting for new release to resolve: https://github.com/c-ares/c-ares/issues/1069
    cares_latest_tag="v1.34.5"
    cares_ver="${cares_latest_tag#v}"
    cares_latest_url="https://github.com/c-ares/c-ares/releases/download/${cares_latest_tag}/c-ares-${cares_ver}.tar.gz"
    # cares_ver="main"
    # cares_latest_url="https://github.com/c-ares/c-ares/archive/refs/heads/main.tar.gz"
  fi
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    cares_latest_url="https://gh-proxy.com/${cares_latest_url}"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz.part" "${cares_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz.part" "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz"
  fi
  mkdir -p "/usr/src/c-ares-${cares_ver}"
  tar -zxf "${DOWNLOADS_DIR}/c-ares-${cares_ver}.tar.gz" --strip-components=1 -C "/usr/src/c-ares-${cares_ver}"
  cd "/usr/src/c-ares-${cares_ver}"
  if [ ! -f "./configure" ]; then
    autoreconf -i
  fi
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
    ac_cv_func_if_indextoname=no ./configure \
      --host="${CROSS_HOST}" \
      --build="${BUILD_ARCH}" \
      --prefix="${CROSS_PREFIX}" \
      --enable-static \
      --disable-shared \
      --without-random \
      CFLAGS="-std=gnu17" \
      CPPFLAGS="-I${CROSS_PREFIX}/include" \
      LDFLAGS="-L${CROSS_PREFIX}/lib" \
      LIBS="-lws2_32"
  else
    ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules --disable-tests
  fi
  make -j$(nproc)
  make install
  cares_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libcares.pc")"
  echo "- c-ares: ${cares_ver}, source: ${cares_latest_url:-cached c-ares}" >>"${BUILD_INFO}"
}

prepare_libssh2() {
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
    libssh2_tag="${MINGW_LIBSSH2_VER:-1.11.0}"
    libssh2_archive="libssh2-${libssh2_tag}.tar.bz2"
    libssh2_latest_url="https://libssh2.org/download/${libssh2_archive}"
    libssh2_tar_flags="-jxf"
  else
    libssh2_tag="$(retry wget -qO- --compression=auto https://libssh2.org/ \| sed -nr "'s@.*libssh2 ([^<]*).*released on.*@\1@p'")"
    libssh2_archive="libssh2-${libssh2_tag}.tar.xz"
    libssh2_latest_url="https://libssh2.org/download/${libssh2_archive}"
    libssh2_tar_flags="-Jxf"
  fi
  if [ ! -f "${DOWNLOADS_DIR}/${libssh2_archive}" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/${libssh2_archive}.part" "${libssh2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/${libssh2_archive}.part" "${DOWNLOADS_DIR}/${libssh2_archive}"
  fi
  mkdir -p "/usr/src/libssh2-${libssh2_tag}"
  tar ${libssh2_tar_flags} "${DOWNLOADS_DIR}/${libssh2_archive}" --strip-components=1 -C "/usr/src/libssh2-${libssh2_tag}"
  cd "/usr/src/libssh2-${libssh2_tag}"
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
    ./configure \
      --host="${CROSS_HOST}" \
      --build="${BUILD_ARCH}" \
      --prefix="${CROSS_PREFIX}" \
      --enable-static \
      --disable-shared \
      CFLAGS="-std=gnu17" \
      CPPFLAGS="-I${CROSS_PREFIX}/include" \
      LDFLAGS="-L${CROSS_PREFIX}/lib" \
      LIBS="-lws2_32"
  else
    ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules --disable-examples-build
  fi
  make -j$(nproc)
  make install
  libssh2_ver="$(grep Version: "${CROSS_PREFIX}/lib/pkgconfig/libssh2.pc")"
  echo "- libssh2: ${libssh2_ver}, source: ${libssh2_latest_url:-cached libssh2}" >>"${BUILD_INFO}"
}

build_aria2() {
  if [ -n "${ARIA2_VER}" ]; then
    aria2_tag="${ARIA2_VER}"
  elif [ -n "${ARIA2_REF}" ]; then
    aria2_tag="${ARIA2_REF}"
  else
    aria2_tag=master
    # Check download cache whether expired
    if [ -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
      cached_file_ts="$(stat -c '%Y' "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz")"
      current_ts="$(date +%s)"
      if [ "$((current_ts - "${cached_file_ts}"))" -gt 86400 ]; then
        echo "Delete expired aria2 archive file cache..."
        rm -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
      fi
    fi
  fi

  if [ -n "${ARIA2_VER}" ]; then
    aria2_latest_url="https://github.com/aria2/aria2/releases/download/release-${ARIA2_VER}/aria2-${ARIA2_VER}.tar.gz"
  elif [ -n "${ARIA2_REF}" ]; then
    aria2_latest_url="https://github.com/aria2/aria2/archive/${ARIA2_REF}.tar.gz"
  else
    aria2_latest_url="https://github.com/aria2/aria2/archive/refs/heads/master.tar.gz"
  fi
  if [ x"${USE_CHINA_MIRROR}" = x1 ]; then
    aria2_latest_url="https://gh-proxy.com/${aria2_latest_url}"
  fi

  if [ ! -f "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" ]; then
    retry wget -cT10 -O "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${aria2_latest_url}"
    mv -fv "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz.part" "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz"
  fi
  mkdir -p "/usr/src/aria2-${aria2_tag}"
  tar -zxf "${DOWNLOADS_DIR}/aria2-${aria2_tag}.tar.gz" --strip-components=1 -C "/usr/src/aria2-${aria2_tag}"
  cd "/usr/src/aria2-${aria2_tag}"
  # Apply patches
  if [ -d "${SELF_DIR}/patch" ]; then
    for patch_file in ${SELF_DIR}/patch/*.patch; do
      echo "Applying patch: ${patch_file}"
      patch -p1 < "$patch_file" || exit 1
    done
  fi
  if [ ! -f ./configure ]; then
    autoreconf -i
  fi
  # Configure aria2.  The Windows path mirrors upstream mingw-config.
  if [ x"${TARGET_HOST}" = xWindows ]; then
    if [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
      ARIA2_EXT_CONF="--without-included-gettext --disable-nls --with-libcares --without-gnutls --without-openssl --with-sqlite3 --without-libxml2 --with-libexpat --with-libz --with-libgmp --with-libssh2 --without-libgcrypt --without-libnettle --with-cppunit-prefix=${CROSS_PREFIX}"
    else
      if [ ! -f "${DOWNLOADS_DIR}/ca-certificates.crt" ]; then
        retry wget -cT10 -O "${DOWNLOADS_DIR}/ca-certificates.crt" "https://curl.se/ca/cacert.pem"
      fi
      ARIA2_EXT_CONF="--with-openssl --without-gnutls --with-libcares --with-ca-bundle=C:/ca-certificates.crt"
    fi
  else
    ARIA2_EXT_CONF="--with-openssl --without-gnutls --with-libcares"
  fi
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
    ./configure \
      --host="${CROSS_HOST}" \
      --prefix="${CROSS_PREFIX}" \
      --enable-silent-rules \
      ARIA2_STATIC=yes \
      ${ARIA2_EXT_CONF} \
      CPPFLAGS="-I${CROSS_PREFIX}/include" \
      LDFLAGS="-L${CROSS_PREFIX}/lib" \
      PKG_CONFIG="/usr/bin/pkg-config" \
      PKG_CONFIG_PATH="${CROSS_PREFIX}/lib/pkgconfig"
  else
    ./configure --host="${CROSS_HOST}" --prefix="${CROSS_PREFIX}" --enable-static --disable-shared --enable-silent-rules ARIA2_STATIC=yes ${ARIA2_EXT_CONF}
  fi
  make -j$(nproc)
  make install
  # Strip debug symbols to reduce binary size
  if [ x"${TARGET_HOST}" = xWindows ]; then
    "${CROSS_HOST}-strip" "${CROSS_PREFIX}/bin/"aria2c* || true
  fi
  # Bundle CA certificates for Windows builds
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" != x1 ]; then
    cp -v "${DOWNLOADS_DIR}/ca-certificates.crt" "${CROSS_PREFIX}/bin/"
  fi
  echo "- aria2: source: ${aria2_latest_url:-cached aria2}" >>"${BUILD_INFO}"
  echo >>"${BUILD_INFO}"
}

get_build_info() {
  echo "============= ARIA2 VER INFO ==================="
  ARIA2_VER_INFO="$("${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* --version 2>/dev/null)"
  echo "${ARIA2_VER_INFO}"
  echo "================================================"

  echo "aria2 version info:" >>"${BUILD_INFO}"
  echo '```txt' >>"${BUILD_INFO}"
  echo "${ARIA2_VER_INFO}" >>"${BUILD_INFO}"
  echo '```' >>"${BUILD_INFO}"
}

test_build() {
  # get release
  cp -fv "${CROSS_PREFIX}/bin/"aria2* "${SELF_DIR}"
  echo "============= ARIA2 TEST DOWNLOAD =============="
  TEST_ARGS="-t 10 --console-log-level=debug --http-accept-gzip=true"
  TEST_URL="https://github.com/"
  if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
    # Wine does not reliably reflect the real Windows certificate store.
    # HTTPS certificate verification is covered by the windows-https-smoke-test job.
    TEST_URL="http://example.com/"
  fi
  "${RUNNER_CHECKER}" "${CROSS_PREFIX}/bin/aria2c"* ${TEST_ARGS} "${TEST_URL}" -d /tmp -o test
  echo "================================================"
}

if [ x"${TARGET_HOST}" != xWindows ] || [ x"${USE_OFFICIAL_MINGW}" != x1 ]; then
  prepare_cmake
  prepare_ninja
fi
prepare_zlib
if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" = x1 ]; then
  prepare_gmp
  prepare_expat
else
  prepare_xz
  prepare_ssl
  prepare_libiconv
  prepare_libxml2
fi
prepare_sqlite
prepare_c_ares
prepare_libssh2
build_aria2

get_build_info
# mips test will hang, I don't know why. So I just ignore test failures.
case "${CROSS_HOST}" in
  mips*linux* | mips64*linux*)
    echo "Skipping test_build for MIPS architecture"
    ;;
  *)
    test_build
    ;;
esac

# get release
cp -fv "${CROSS_PREFIX}/bin/"aria2* "${SELF_DIR}"
# Bundle CA certificates for Windows builds
if [ x"${TARGET_HOST}" = xWindows ] && [ x"${USE_OFFICIAL_MINGW}" != x1 ]; then
  cp -fv "${DOWNLOADS_DIR}/ca-certificates.crt" "${SELF_DIR}"
fi
