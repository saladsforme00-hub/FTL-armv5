#!/usr/bin/env bash
# Cross-compile a fully static pihole-FTL for ARMv5TE (soft-float, EABI, musl).
#
# Runs on an x86_64 (or arm64) Ubuntu/Debian host. Nothing is built on the
# target device. The resulting binary has no runtime dependencies, so it runs
# on any ARMv5TE+ Linux userland (Alpine, Debian armel, OpenWrt, ...).
#
# Usage:
#   ./build-armv5.sh <path-to-FTL-checkout> [output-dir]
#
# Environment overrides (all optional):
#   WORK=<dir>          scratch dir (default: ./_work). The sysroot under it is
#                       reused between runs, so only FTL is rebuilt next time.
#   DL=<dir>            source tarball cache (default: $WORK/dl). Pre-place
#                       tarballs here to build offline.
#   CROSS=<prefix>      cross toolchain prefix (default: arm-linux-gnueabi-)
#   ARCH_FLAGS=...      default: -march=armv5te -mtune=xscale -mfloat-abi=soft -marm
#   GIT_TAG/GIT_VERSION/GIT_BRANCH/GIT_HASH/GIT_DATE
#                       passed through to FTL's gen_version.cmake (otherwise
#                       read from the FTL checkout's git metadata).
#   SKIP_QEMU_CHECK=1   don't run the binary under qemu-arm after building.
#
# Host packages (Ubuntu 24.04):
#   sudo apt-get install -y build-essential gcc-arm-linux-gnueabi cmake m4 \
#        xxd file curl git qemu-user binutils-arm-linux-gnueabi

set -euo pipefail

FTL_SRC="$(realpath "${1:?usage: $0 <FTL checkout> [outdir]}")"
OUT="$(realpath -m "${2:-$PWD/out}")"

# ---- versions (keep in step with pi-hole/docker-base-images ftl-build) -------
MUSL_VER="${MUSL_VER:-1.2.5}"
GMP_VER="${GMP_VER:-6.3.0}"
NETTLE_VER="${NETTLE_VER:-3.10.2}"
UNISTRING_VER="${UNISTRING_VER:-1.3}"
IDN2_VER="${IDN2_VER:-2.3.8}"
NCURSES_VER="${NCURSES_VER:-6.5}"
READLINE_VER="${READLINE_VER:-8.3}"
MBEDTLS_VER="${MBEDTLS_VER:-4.0.0}"

declare -A URL=(
  [musl]="https://musl.libc.org/releases/musl-${MUSL_VER}.tar.gz"
  [gmp]="https://ftp.gnu.org/gnu/gmp/gmp-${GMP_VER}.tar.xz"
  [nettle]="https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VER}.tar.gz"
  [libunistring]="https://ftp.gnu.org/gnu/libunistring/libunistring-${UNISTRING_VER}.tar.xz"
  [libidn2]="https://ftp.gnu.org/gnu/libidn/libidn2-${IDN2_VER}.tar.gz"
  [ncurses]="https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz"
  [readline]="https://ftp.gnu.org/gnu/readline/readline-${READLINE_VER}.tar.gz"
  [mbedtls]="https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VER}/mbedtls-${MBEDTLS_VER}.tar.bz2"
)
declare -A VER=(
  [musl]=$MUSL_VER [gmp]=$GMP_VER [nettle]=$NETTLE_VER [libunistring]=$UNISTRING_VER
  [libidn2]=$IDN2_VER [ncurses]=$NCURSES_VER [readline]=$READLINE_VER [mbedtls]=$MBEDTLS_VER
)

# ---- toolchain ---------------------------------------------------------------
CROSS="${CROSS:-arm-linux-gnueabi-}"
ARCH_FLAGS="${ARCH_FLAGS:--march=armv5te -mtune=xscale -mfloat-abi=soft -marm}"
SECTION_FLAGS="-ffunction-sections -fdata-sections"
HOST_TRIPLET="arm-linux-musleabi"
BUILD_TRIPLET="$(gcc -dumpmachine)"
JOBS="$(nproc)"

WORK="$(realpath -m "${WORK:-$PWD/_work}")"
DL="$(realpath -m "${DL:-$WORK/dl}")"
SYSROOT="$WORK/sysroot"
BLD="$WORK/build"
STAMP="$WORK/stamps"
mkdir -p "$DL" "$SYSROOT" "$BLD" "$STAMP" "$OUT"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

fetch_extract() { # name -> prints source dir
  local name=$1 url=${URL[$1]} file
  file="$DL/$(basename "$url")"
  if [[ ! -f "$file" ]]; then
    # also accept any pre-placed tarball named <name>-<ver>.tar.*
    local alt; alt="$(ls "$DL/${name}-${VER[$name]}".tar.* 2>/dev/null | head -n1 || true)"
    if [[ -n "$alt" ]]; then file="$alt"; else
      curl -fsSL --retry 5 --retry-delay 5 -o "$file.part" "$url" && mv "$file.part" "$file"
    fi
  fi
  rm -rf "${BLD:?}/${name:?}"
  mkdir -p "$BLD/$name"
  tar -xf "$file" -C "$BLD/$name" --strip-components=1
  echo "$BLD/$name"
}

step() { # name function
  local name=$1 fn=$2
  if [[ -f "$STAMP/$name-${VER[$name]}" ]]; then echo "  [cached] $name ${VER[$name]}"; return; fi
  log "Building $name ${VER[$name]}"
  local src; src="$(fetch_extract "$name")"
  ( cd "$src" || exit 1; set -e; "$fn" )
  touch "$STAMP/$name-${VER[$name]}"
}

# The compiler driver every dependency (and FTL) is built with: the distro's
# armel GCC, pointed at our musl sysroot via musl's own specs file. libgcc
# (incl. the kernel-helper based __sync/__atomic routines ARMv5 needs, and the
# unwinder) comes from the cross GCC.
CC_WRAPPER="$SYSROOT/bin/armv5-musl-gcc"

build_musl() {
  ./configure --prefix="$SYSROOT" --target="$HOST_TRIPLET" \
      CROSS_COMPILE="$CROSS" CC="${CROSS}gcc" \
      CFLAGS="-O2 $ARCH_FLAGS" --disable-shared --enable-wrapper=gcc
  make -j"$JOBS"
  make install
  # musl < 1.2.5 only declares ppoll() under _GNU_SOURCE; FTL expects the
  # POSIX-2024 / musl 1.2.5 behaviour of having it in the default profile.
  sed -i 's/^#ifdef _GNU_SOURCE$/#if defined(_GNU_SOURCE) || defined(_BSD_SOURCE)/' "$SYSROOT/include/poll.h"
  # Linux UAPI headers (FTL uses netlink, inotify, ...)
  # (Debian/Ubuntu: linux-libc-dev-armel-cross, pulled in by gcc-arm-linux-gnueabi)
  local kinc="${KERNEL_HEADERS:-/usr/${CROSS%-}/include}"
  [[ -d "$kinc/asm" ]] || { echo "ARM kernel headers not found in $kinc" >&2; exit 1; }
  for d in linux asm asm-generic mtd; do cp -a "$kinc/$d" "$SYSROOT/include/"; done
  # libgcc's ARMv5 helpers (e.g. __aeabi_ldiv0 -> raise) need libc, and libc
  # needs libgcc: resolve both in one link group.
  sed -i '/^\*libgcc:/{n;s|.*|--start-group libgcc.a%s %:if-exists(libgcc_eh.a%s) -lc --end-group|}' \
      "$SYSROOT/lib/musl-gcc.specs"
  cat > "$CC_WRAPPER" <<EOF
#!/bin/sh
exec ${CROSS}gcc $ARCH_FLAGS "\$@" -specs "$SYSROOT/lib/musl-gcc.specs"
EOF
  chmod +x "$CC_WRAPPER"
}

autotools_env() {
  export CC="$CC_WRAPPER" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" STRIP="${CROSS}strip"
  export CFLAGS="-O2 $SECTION_FLAGS" CPPFLAGS="-I$SYSROOT/include" LDFLAGS="-L$SYSROOT/lib"
  export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig" PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"
}
CONF=(--host="$HOST_TRIPLET" --build="$BUILD_TRIPLET" --prefix="$SYSROOT" --enable-static --disable-shared)

build_gmp() {
  autotools_env
  # Generic C (no ARM asm) keeps the code strictly ARMv5-safe
  ./configure "${CONF[@]}" --disable-assembly
  make -j"$JOBS"
  make install
}
build_nettle() {
  autotools_env
  ./configure "${CONF[@]}" --disable-openssl --disable-mini-gmp --disable-gcov \
      --disable-documentation --disable-assembly --disable-fat --libdir="$SYSROOT/lib"
  make -j"$JOBS"
  make install
}
build_libunistring() {
  autotools_env
  ./configure "${CONF[@]}"
  make -j"$JOBS"
  make install
}
build_libidn2() {
  autotools_env
  ./configure "${CONF[@]}" --disable-doc --disable-nls --without-libiconv-prefix \
      --with-libunistring-prefix="$SYSROOT"
  # library only (the CLI, docs and tests need host tools we don't want)
  make -j"$JOBS" -C gl
  make -j"$JOBS" -C unistring
  make -j"$JOBS" -C lib
  make -C lib install
}
build_ncurses() { # provides libtinfo (termcap API) for readline
  autotools_env
  ./configure "${CONF[@]}" --with-termlib --without-cxx --without-cxx-binding \
      --without-ada --without-progs --without-tests --without-manpages \
      --without-debug --disable-db-install --disable-stripping --enable-overwrite \
      --with-default-terminfo-dir=/usr/share/terminfo \
      --with-terminfo-dirs="/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo"
  make -j"$JOBS" libs
  make install.libs
}
build_readline() {
  autotools_env
  bash_cv_termcap_lib=libtinfo ./configure "${CONF[@]}" --disable-install-examples --with-curses
  make -j"$JOBS"
  make install-static
}
build_mbedtls() {
  # Same tweaks as upstream's ftl-build image: enable pthread threading support
  sed -i '/#define MBEDTLS_THREADING_C/s*^//**g' tf-psa-crypto/include/psa/crypto_config.h
  sed -i '/#define MBEDTLS_THREADING_PTHREAD/s*^//**g' tf-psa-crypto/include/psa/crypto_config.h
  cmake -S . -B build -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
      -DCMAKE_C_COMPILER="$CC_WRAPPER" -DCMAKE_AR="$(command -v "${CROSS}ar")" \
      -DCMAKE_C_FLAGS="-O2 -fomit-frame-pointer $SECTION_FLAGS" \
      -DCMAKE_INSTALL_PREFIX="$SYSROOT" -DCMAKE_INSTALL_LIBDIR=lib \
      -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
      -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON
  cmake --build build -j"$JOBS"
  cmake --install build
}

step musl          build_musl
step gmp           build_gmp
step nettle        build_nettle
step libunistring  build_libunistring
step libidn2       build_libidn2
step ncurses       build_ncurses
step readline      build_readline
step mbedtls       build_mbedtls

# ---- FTL -----------------------------------------------------------------------
log "Building pihole-FTL from $FTL_SRC"
# Version metadata is taken from the pristine checkout *before* patching, so
# `pihole-FTL version`/`tag`/`--hash` match upstream's release exactly (which is
# what Pi-hole's updater and web UI compare against).
gitq() { git -C "$FTL_SRC" "$@" 2>/dev/null; }
export GIT_TAG="${GIT_TAG:-$(gitq describe --tags --abbrev=0)}"
export GIT_VERSION="${GIT_VERSION:-$(gitq describe --tags --always --abbrev=8)}"
export GIT_HASH="${GIT_HASH:-$(gitq describe --always --abbrev=8)}"
export GIT_BRANCH="${GIT_BRANCH:-master}"
export GIT_DATE="${GIT_DATE:-$(gitq show --date=short --format=%ai --no-patch | head -n1)}"
echo "  tag=$GIT_TAG version=$GIT_VERSION hash=$GIT_HASH branch=$GIT_BRANCH date=$GIT_DATE"

SRC_COPY="$WORK/ftl-src"
rm -rf "$SRC_COPY"
mkdir -p "$SRC_COPY"
tar -C "$FTL_SRC" --exclude=.git --exclude=cmake --exclude=cmake_ci -cf - . | tar -C "$SRC_COPY" -xf -
PATCH_DIR="${PATCH_DIR:-$(dirname "$(realpath "$0")")/patches}"
shopt -s nullglob
for p in "$PATCH_DIR"/*.patch; do
  echo "  applying $(basename "$p")"
  patch -d "$SRC_COPY" -p1 --forward --batch < "$p"
done
shopt -u nullglob
FTL_SRC="$SRC_COPY"

FTL_BLD="$WORK/ftl-build"
rm -rf "$FTL_BLD"
export STATIC=true
# Tell gen_version.cmake which arch this is (shown by `pihole-FTL -vv`)
export CI_ARCH="${CI_ARCH:-linux/arm/v5}"
cmake -S "$FTL_SRC" -B "$FTL_BLD" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=arm \
    -DCMAKE_C_COMPILER="$CC_WRAPPER" \
    -DCMAKE_AR="$(command -v "${CROSS}ar")" -DCMAKE_RANLIB="$(command -v "${CROSS}ranlib")" \
    -DCMAKE_FIND_ROOT_PATH="$SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_C_FLAGS="$SECTION_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,--gc-sections" \
    -DSTATIC=true \
    -DLIBTERMCAP="$SYSROOT/lib/libtinfow.a" \
    -DUSE_DBUS=OFF -DUSE_CONNTRACK=OFF -DUSE_NFTSET=OFF
cmake --build "$FTL_BLD" -j"$JOBS" --target pihole-FTL

install -m755 "$FTL_BLD/pihole-FTL" "$OUT/pihole-FTL-armv5"
( cd "$OUT" && sha1sum pihole-FTL-armv5 > pihole-FTL-armv5.sha1 )

log "Result"
file "$OUT/pihole-FTL-armv5"
attrs="$("${CROSS}readelf" -A "$OUT/pihole-FTL-armv5")"
echo "$attrs" | grep -E 'Tag_CPU_arch:|Tag_FP_arch|Tag_ABI_VFP' || true
if ! echo "$attrs" | grep -qE 'Tag_CPU_arch: v5TE?J?$' || echo "$attrs" | grep -q 'Tag_FP_arch'; then
  echo "ERROR: binary is not tagged as plain ARMv5 soft-float" >&2; exit 1
fi
if "${CROSS}objdump" -d "$OUT/pihole-FTL-armv5" | grep -qE $'\t(ldrex|strex|dmb|vldr|vmov)'; then
  echo "WARNING: ARMv6+/VFP instructions found in binary!" >&2; exit 1
fi
cat "$OUT/pihole-FTL-armv5.sha1"

if [[ -z "${SKIP_QEMU_CHECK:-}" ]] && command -v qemu-arm >/dev/null; then
  log "Smoke test under qemu-arm (ARM926EJ-S = ARMv5TEJ CPU model)"
  qemu-arm -cpu arm926 "$OUT/pihole-FTL-armv5" -vv
  qemu-arm -cpu arm926 "$OUT/pihole-FTL-armv5" verify
fi
