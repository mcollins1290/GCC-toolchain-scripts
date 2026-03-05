#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# GCC cross toolchain builder (musl)
# Target: aarch64-linux-musl
# Sysroot: built by this script (linux headers + musl)
# Dynamic-capable final toolchain: builds shared runtimes + installs them into sysroot
# ==============================================================================

###############################################################################
# Script Metadata
###############################################################################
SCRIPT_VERSION="v0.0.3-musl"

# ------------------------------ User config -----------------------------------
TARGET="${TARGET:-aarch64-linux-musl}"
PREFIX="${PREFIX:-/opt/gcc-14.2.0-musl-cross}"

# For musl toolchains, a self-contained sysroot is typical.
SYSROOT="${SYSROOT:-${PREFIX}/${TARGET}/sysroot}"

# These are *defaults for GCC*, not required build flags for your projects.
TARGET_ARCH_BASE="${TARGET_ARCH_BASE:-armv8-a}"
TARGET_TUNE="${TARGET_TUNE:-cortex-a72}"

# Final GCC: enable shared runtimes (dynamic-capable toolchain)
ENABLE_DYNAMIC="${ENABLE_DYNAMIC:-1}"                 # 1 => build shared+static (recommended), 0 => static-only
INSTALL_RUNTIME_TO_SYSROOT="${INSTALL_RUNTIME_TO_SYSROOT:-1}"  # 1 => copy libstdc++.so, libgcc_s.so, etc into sysroot

# Layout
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="${SRC_ROOT:-${ROOT_DIR}/src}"
TARBALL_DIR="${TARBALL_DIR:-${ROOT_DIR}/tarballs}"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"

# Parallelism
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Optional: when you have multiple prefixes and want to test/execute with another
ACTIVE_PREFIX="${ACTIVE_PREFIX:-${PREFIX}}"

# Safety: to wipe PREFIX before installs, set CLEAN_PREFIX=1 (DANGEROUS)
CLEAN_PREFIX="${CLEAN_PREFIX:-0}"

# Reconfigure behavior (gcc configure results can become sticky)
RECONFIGURE="${RECONFIGURE:-1}"

# Internal guard: ensure we only clean PREFIX once per script invocation
PREFIX_CLEANED=0

# ------------------------------ Versions / URLs -------------------------------
# GCC
GCC_VER="${GCC_VER:-14.2.0}"
GCC_TARBALL="${GCC_TARBALL:-gcc-${GCC_VER}.tar.xz}"
GCC_URL="${GCC_URL:-https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/${GCC_TARBALL}}"
GCC_SHA256="${GCC_SHA256:-a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9}"
GCC_SRC_DIR="${GCC_SRC_DIR:-${SRC_ROOT}/gcc-${GCC_VER}}"

# Binutils
BINUTILS_VER="${BINUTILS_VER:-2.44}"
BINUTILS_TARBALL="${BINUTILS_TARBALL:-binutils-${BINUTILS_VER}.tar.xz}"
BINUTILS_URL="${BINUTILS_URL:-https://ftp.gnu.org/gnu/binutils/${BINUTILS_TARBALL}}"
BINUTILS_SHA256="${BINUTILS_SHA256:-ce2017e059d63e67ddb9240e9d4ec49c2893605035cd60e92ad53177f4377237}"
BINUTILS_SRC_DIR="${BINUTILS_SRC_DIR:-${SRC_ROOT}/binutils-${BINUTILS_VER}}"
BINUTILS_BUILD_DIR="${BINUTILS_BUILD_DIR:-${BUILD_DIR}/binutils}"

# Linux kernel headers (needed for libc)
LINUX_VER="${LINUX_VER:-6.12.20}"
LINUX_TARBALL="${LINUX_TARBALL:-linux-${LINUX_VER}.tar.xz}"
LINUX_URL="${LINUX_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/${LINUX_TARBALL}}"
LINUX_SHA256="${LINUX_SHA256:-}"  # optional
LINUX_SRC_DIR="${LINUX_SRC_DIR:-${SRC_ROOT}/linux-${LINUX_VER}}"
LINUX_BUILD_DIR="${LINUX_BUILD_DIR:-${BUILD_DIR}/linux-headers}"

# musl
MUSL_VER="${MUSL_VER:-1.2.5}"
MUSL_TARBALL="${MUSL_TARBALL:-musl-${MUSL_VER}.tar.gz}"
MUSL_URL="${MUSL_URL:-https://musl.libc.org/releases/${MUSL_TARBALL}}"
MUSL_SHA256="${MUSL_SHA256:-}"  # optional (set it if you want hard pinning)
MUSL_SRC_DIR="${MUSL_SRC_DIR:-${SRC_ROOT}/musl-${MUSL_VER}}"
MUSL_BUILD_DIR="${MUSL_BUILD_DIR:-${BUILD_DIR}/musl}"

# ------------------------------ Helpers ---------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
mkdirp() { mkdir -p "$@"; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log_step() {
  local name="$1"; shift
  local log="${LOG_DIR}/${name}.log"
  mkdirp "${LOG_DIR}"
  echo "==> ${name}"
  echo "    log: ${log}"
  ( "$@" ) > >(tee -a "${log}") 2> >(tee -a "${log}" 1>&2)
}

clean_prefix_once() {
  [[ "${CLEAN_PREFIX}" == "1" ]] || return 0
  [[ "${PREFIX_CLEANED}" == "0" ]] || return 0
  [[ -n "${PREFIX}" && "${PREFIX}" != "/" ]] || die "refusing to clean dangerous PREFIX='${PREFIX}'"
  echo "WARNING: CLEAN_PREFIX=1, removing ${PREFIX}" >&2
  rm -rf "${PREFIX}"
  PREFIX_CLEANED=1
}

# ------------------------------ Download / Verify / Extract -------------------
download_file() {
  local url="$1"
  local out="$2"
  mkdirp "$(dirname "$out")"

  if [[ -f "$out" ]]; then
    echo "==> download: already present: $out"
    return 0
  fi

  echo "==> download: $url"
  if have_cmd curl; then
    curl -L --fail -o "$out" "$url"
  elif have_cmd wget; then
    wget -O "$out" "$url"
  else
    die "need curl or wget to download: $url"
  fi
}

verify_sha256() {
  local file="$1"
  local expect="${2:-}"

  [[ -f "$file" ]] || die "verify_sha256: missing file: $file"
  if [[ -z "$expect" ]]; then
    echo "WARNING: no SHA256 provided for $(basename "$file") — skipping verification." >&2
    return 0
  fi
  have_cmd sha256sum || die "sha256sum not found"

  local got
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$expect" ]] || die "SHA256 mismatch for $file: got $got expected $expect"
  echo "==> sha256 ok: $(basename "$file")"
}

extract_tarball() {
  local tarball="$1"
  local dest="$2"

  [[ -f "$tarball" ]] || die "extract_tarball: missing tarball: $tarball"

  if [[ -d "$dest" && -f "$dest/configure" ]]; then
    echo "==> extract: already extracted: $dest"
    return 0
  fi

  echo "==> extract: $tarball -> $dest"
  rm -rf "$dest"
  mkdirp "$(dirname "$dest")"

  local tmp
  tmp="$(mktemp -d)"
  tar -xf "$tarball" -C "$tmp"
  local top
  top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  [[ -n "$top" ]] || die "extract failed: no top-level dir in $tarball"
  mv "$top" "$dest"
  rm -rf "$tmp"

  [[ -f "$dest/configure" ]] || die "extract result missing configure: $dest"
}

ensure_gcc_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  if [[ -d "${GCC_SRC_DIR}" && -f "${GCC_SRC_DIR}/configure" ]]; then
    :
  else
    local tb="${TARBALL_DIR}/${GCC_TARBALL}"
    download_file "${GCC_URL}" "${tb}"
    verify_sha256 "${tb}" "${GCC_SHA256}"
    extract_tarball "${tb}" "${GCC_SRC_DIR}"
  fi

  if [[ ! -f "${GCC_SRC_DIR}/gmp/README" ]]; then
    echo "==> gcc: fetching prerequisites (gmp/mpfr/mpc/isl)"
    ( cd "${GCC_SRC_DIR}" && ./contrib/download_prerequisites )
  fi
}

ensure_binutils_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  if [[ -d "${BINUTILS_SRC_DIR}" && -f "${BINUTILS_SRC_DIR}/configure" ]]; then
    return 0
  fi
  local tb="${TARBALL_DIR}/${BINUTILS_TARBALL}"
  download_file "${BINUTILS_URL}" "${tb}"
  verify_sha256 "${tb}" "${BINUTILS_SHA256}"
  extract_tarball "${tb}" "${BINUTILS_SRC_DIR}"
}

ensure_linux_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  if [[ -d "${LINUX_SRC_DIR}" && -f "${LINUX_SRC_DIR}/Makefile" ]]; then
    return 0
  fi
  local tb="${TARBALL_DIR}/${LINUX_TARBALL}"
  download_file "${LINUX_URL}" "${tb}"
  verify_sha256 "${tb}" "${LINUX_SHA256}"
  echo "==> extract: $tb -> ${LINUX_SRC_DIR}"
  rm -rf "${LINUX_SRC_DIR}"
  mkdirp "$(dirname "${LINUX_SRC_DIR}")"
  tar -xf "$tb" -C "$(dirname "${LINUX_SRC_DIR}")"
  [[ -f "${LINUX_SRC_DIR}/Makefile" ]] || die "linux extract missing Makefile: ${LINUX_SRC_DIR}"
}

ensure_musl_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  if [[ -d "${MUSL_SRC_DIR}" && -f "${MUSL_SRC_DIR}/configure" ]]; then
    return 0
  fi
  local tb="${TARBALL_DIR}/${MUSL_TARBALL}"
  download_file "${MUSL_URL}" "${tb}"
  verify_sha256 "${tb}" "${MUSL_SHA256}"
  extract_tarball "${tb}" "${MUSL_SRC_DIR}"
}

# ------------------------------ Env ------------------------------------------
export_basic_env() {
  export LC_ALL=C
  umask 022

  : "${ACTIVE_PREFIX:=${PREFIX}}"
  SYSROOT="${SYSROOT%/}"
  PREFIX="${PREFIX%/}"

  export PATH="${ACTIVE_PREFIX}/bin:${PATH}"
  export CFLAGS="${CFLAGS:--O2 -pipe}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
}

# ------------------------------ Preconditions ---------------------------------
require_host_build_tools() {
  have_cmd make || die "missing make"
  have_cmd gcc  || die "missing host gcc"
  have_cmd g++  || die "missing host g++"
}

require_binutils_in_prefix() {
  [[ -x "${PREFIX}/bin/${TARGET}-as" ]] || die "missing ${PREFIX}/bin/${TARGET}-as (binutils not installed or prefix cleaned)"
  [[ -x "${PREFIX}/bin/${TARGET}-ld" ]] || die "missing ${PREFIX}/bin/${TARGET}-ld (binutils not installed or prefix cleaned)"
}

# musl sysroot sanity
require_sysroot_dirs() {
  [[ -d "${SYSROOT}" ]] || die "SYSROOT not found (expected to be created): ${SYSROOT}"
  [[ -d "${SYSROOT}/usr/include" ]] || die "SYSROOT missing usr/include: ${SYSROOT}"
}

# Derive musl dynamic loader name from TARGET (best-effort)
musl_loader_name() {
  # TARGET looks like: aarch64-linux-musl
  local arch
  arch="$(echo "${TARGET}" | awk -F- '{print $1}')"
  echo "ld-musl-${arch}.so.1"
}

require_musl_loader_present() {
  local loader
  loader="$(musl_loader_name)"
  [[ -e "${SYSROOT}/lib/${loader}" ]] || die "sysroot missing musl dynamic loader: ${SYSROOT}/lib/${loader}"
}

# ----------------------------- Build: binutils --------------------------------
build_binutils() {
  export_basic_env
  require_host_build_tools
  ensure_binutils_source

  clean_prefix_once
  mkdirp "${BINUTILS_BUILD_DIR}"

  log_step "configure-binutils" bash -c "
    cd '${BINUTILS_BUILD_DIR}'
    '${BINUTILS_SRC_DIR}/configure' \
      --target='${TARGET}' \
      --prefix='${PREFIX}' \
      --with-sysroot='${SYSROOT}' \
      --disable-multilib \
      --disable-werror \
      --disable-nls \
      --enable-plugins \
      --enable-lto \
      --enable-gold \
      --enable-ld=default \
      --with-system-zlib
  "

  log_step "build-binutils" bash -c "
    cd '${BINUTILS_BUILD_DIR}'
    make -j'${JOBS}'
  "

  log_step "install-binutils" bash -c "
    cd '${BINUTILS_BUILD_DIR}'
    make install
  "

  echo "==> binutils installed to ${PREFIX}"
}

# ------------------------- Build: Linux kernel headers -------------------------
install_linux_headers() {
  export_basic_env
  require_host_build_tools
  ensure_linux_source

  clean_prefix_once
  mkdirp "${SYSROOT}/usr"

  log_step "install-linux-headers" bash -c "
    cd '${LINUX_SRC_DIR}'
    make ARCH=arm64 INSTALL_HDR_PATH='${SYSROOT}/usr' headers_install
  "

  echo "==> linux headers installed to ${SYSROOT}/usr/include"
}

# --------------------------- Build: GCC stage1 (C) -----------------------------
build_gcc_stage1() {
  export_basic_env
  require_host_build_tools
  ensure_gcc_source
  require_binutils_in_prefix

  clean_prefix_once

  local gcc_build="${BUILD_DIR}/gcc-stage1"
  if [[ "${RECONFIGURE}" == "1" ]]; then
    echo "==> gcc: RECONFIGURE=1, removing build dir: ${gcc_build}"
    rm -rf "${gcc_build}"
  fi
  mkdirp "${gcc_build}"

  log_step "configure-gcc-stage1" bash -c "
    cd '${gcc_build}'
    '${GCC_SRC_DIR}/configure' \
      --target='${TARGET}' \
      --prefix='${PREFIX}' \
      --with-sysroot='${SYSROOT}' \
      --with-build-sysroot='${SYSROOT}' \
      --disable-multilib \
      --disable-nls \
      --disable-bootstrap \
      --disable-werror \
      --enable-languages=c \
      --without-headers \
      --with-newlib \
      --disable-shared \
      --disable-threads \
      --disable-libatomic \
      --disable-libgomp \
      --disable-libquadmath \
      --disable-libssp \
      --disable-libvtv \
      --disable-libstdcxx \
      --enable-checking=release \
      --with-system-zlib \
      --with-arch='${TARGET_ARCH_BASE}' \
      --with-tune='${TARGET_TUNE}'
  "

  log_step "build-gcc-stage1" bash -c "
    cd '${gcc_build}'
    make -j'${JOBS}' all-gcc
    make -j'${JOBS}' all-target-libgcc
  "

  log_step "install-gcc-stage1" bash -c "
    cd '${gcc_build}'
    make install-gcc
    make install-target-libgcc
  "

  echo "==> GCC stage1 installed to ${PREFIX}"
}

# ------------------------------- Build: musl -----------------------------------
build_musl() {
  export_basic_env
  require_host_build_tools
  ensure_musl_source

  [[ -x "${PREFIX}/bin/${TARGET}-gcc" ]] || die "missing stage1 compiler: ${PREFIX}/bin/${TARGET}-gcc"
  require_sysroot_dirs

  rm -rf "${MUSL_BUILD_DIR}"
  mkdirp "${MUSL_BUILD_DIR}"

  log_step "configure-musl" bash -c "
    cd '${MUSL_BUILD_DIR}'
    CC='${PREFIX}/bin/${TARGET}-gcc' \
    '${MUSL_SRC_DIR}/configure' \
      --target='${TARGET}' \
      --prefix=/usr \
      --syslibdir=/lib
  "

  log_step "build-musl" bash -c "
    cd '${MUSL_BUILD_DIR}'
    make -j'${JOBS}'
  "

  log_step "install-musl" bash -c "
    cd '${MUSL_BUILD_DIR}'
    DESTDIR='${SYSROOT}' make install
  "

  # ---------------------------------------------------------------------------
  # Dynamic-capable fix (QEMU/sysroot safety):
  # musl's install creates /lib/ld-musl-*.so.1 as a symlink to /usr/lib/libc.so.
  # Under DESTDIR sysroot installs, that symlink can become absolute (/usr/lib/...),
  # causing QEMU (-L SYSROOT) to escape the sysroot and load host files.
  # Rewrite it as a *relative* symlink that stays inside SYSROOT.
  # ---------------------------------------------------------------------------
  local loader
  loader="$(musl_loader_name)"
  mkdir -p "${SYSROOT}/lib"

  if [[ -e "${SYSROOT}/usr/lib/libc.so" ]]; then
    rm -f "${SYSROOT}/lib/${loader}"
    ln -s ../usr/lib/libc.so "${SYSROOT}/lib/${loader}"
    if have_cmd file; then
      file -L "${SYSROOT}/lib/${loader}" | grep -q 'ELF' || die "musl loader is not ELF: ${SYSROOT}/lib/${loader}"
    fi
  else
    die "musl install did not produce ${SYSROOT}/usr/lib/libc.so (unexpected); cannot create loader symlink"
  fi

  echo "==> musl installed into sysroot: ${SYSROOT}"
  echo "==> loader fixed: ${SYSROOT}/lib/${loader} -> ../usr/lib/libc.so"
}

# ----------- Install shared runtimes into sysroot (dynamic-capable fix) --------
install_runtime_libs_to_sysroot() {
  [[ "${INSTALL_RUNTIME_TO_SYSROOT}" == "1" ]] || return 0

  local troot="${PREFIX}/${TARGET}"
  local dst="${SYSROOT}/usr/lib"
  mkdir -p "${dst}"

  local found_any=0
  local d
  for d in \
    "${troot}/lib" "${troot}/lib64" "${troot}/usr/lib" "${troot}/usr/lib64" \
    "${PREFIX}/lib" "${PREFIX}/lib64" \
  ; do
    [[ -d "${d}" ]] || continue

    local patterns=(
      "libstdc++.so*"
      "libgcc_s.so*"
      "libatomic.so*"
      "libgomp.so*"
      "libssp.so*"
      "libquadmath.so*"
      "libasan.so*"
      "libubsan.so*"
      "liblsan.so*"
      "libtsan.so*"
    )

    local p
    for p in "${patterns[@]}"; do
      shopt -s nullglob
      local matches=( ${d}/${p} )
      shopt -u nullglob

      if (( ${#matches[@]} > 0 )); then
        found_any=1
        echo "==> sysroot: installing ${p} from ${d} -> ${dst}"
        cp -a "${matches[@]}" "${dst}/"
      fi
    done
  done

  if [[ "${found_any}" -eq 0 ]]; then
    echo "WARNING: did not find shared runtimes to copy into sysroot." >&2
  else
    echo "==> sysroot: shared runtimes installed under: ${dst}"
  fi
}

# ----------------------------- Build: GCC final --------------------------------
build_gcc_final() {
  export_basic_env
  require_host_build_tools
  ensure_gcc_source
  require_binutils_in_prefix
  require_sysroot_dirs

  [[ -f "${SYSROOT}/usr/include/stdio.h" ]] || die "sysroot missing musl headers (stdio.h). Did you run musl?"
  [[ -f "${SYSROOT}/lib/libc.a" || -f "${SYSROOT}/usr/lib/libc.a" ]] || die "sysroot missing musl libc.a (expected /lib or /usr/lib)"

  if [[ "${ENABLE_DYNAMIC}" == "1" ]]; then
    require_musl_loader_present
  fi

  local gcc_build="${BUILD_DIR}/gcc-final"
  if [[ "${RECONFIGURE}" == "1" ]]; then
    echo "==> gcc: RECONFIGURE=1, removing build dir: ${gcc_build}"
    rm -rf "${gcc_build}"
  fi
  mkdirp "${gcc_build}"

  local with_as=""
  local with_ld=""
  if [[ -x "${PREFIX}/bin/${TARGET}-as" ]]; then
    with_as="--with-as=${PREFIX}/bin/${TARGET}-as"
  fi
  if [[ -x "${PREFIX}/bin/${TARGET}-ld" ]]; then
    with_ld="--with-ld=${PREFIX}/bin/${TARGET}-ld"
  fi

  # Dynamic-capable fix:
  # - If ENABLE_DYNAMIC=1, build shared runtimes (libstdc++.so, libgcc_s.so, etc) AND static ones.
  # - If ENABLE_DYNAMIC=0, keep static-only behavior.
  local shared_flags="--disable-shared"
  if [[ "${ENABLE_DYNAMIC}" == "1" ]]; then
    shared_flags="--enable-shared --enable-static"
  fi

  log_step "configure-gcc-final" bash -c "
    cd '${gcc_build}'
    '${GCC_SRC_DIR}/configure' \
      --target='${TARGET}' \
      --prefix='${PREFIX}' \
      --with-sysroot='${SYSROOT}' \
      --with-build-sysroot='${SYSROOT}' \
      --with-native-system-header-dir=/usr/include \
      --disable-multilib \
      --disable-nls \
      --disable-bootstrap \
      --disable-werror \
      --enable-languages=c,c++ \
      ${shared_flags} \
      --enable-threads=posix \
      --enable-linker-build-id \
      --enable-plugin \
      --enable-lto \
      --with-system-zlib \
      --without-included-gettext \
      --enable-checking=release \
      --with-arch='${TARGET_ARCH_BASE}' \
      --with-tune='${TARGET_TUNE}' \
      ${with_as} ${with_ld}
  "

  log_step "build-gcc-final" bash -c "
    cd '${gcc_build}'
    make -j'${JOBS}'
  "

  log_step "install-gcc-final" bash -c "
    cd '${gcc_build}'
    make install
  "

  if [[ "${ENABLE_DYNAMIC}" == "1" ]]; then
    install_runtime_libs_to_sysroot
  fi

  echo
  echo "==> GCC final installed to ${PREFIX}"
  echo "==> SYSROOT: ${SYSROOT}"
  echo "==> ENABLE_DYNAMIC=${ENABLE_DYNAMIC} (shared runtimes: $([[ "${ENABLE_DYNAMIC}" == "1" ]] && echo enabled || echo disabled))"
}

build_all() {
  build_binutils
  install_linux_headers
  build_gcc_stage1
  build_musl
  build_gcc_final
}

# ------------------------------ Main ------------------------------------------
usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  binutils   Download/extract (if needed) + build+install cross binutils into PREFIX
  headers    Download/extract (if needed) + install linux headers into SYSROOT
  stage1     Build+install GCC stage1 (C + libgcc) into PREFIX (no libc)
  musl       Build+install musl into SYSROOT (requires headers + stage1)
  gcc        Build+install final GCC (C,C++) into PREFIX (requires musl)
  build      Build binutils + headers + stage1 + musl + gcc

Env toggles:
  CLEAN_PREFIX=1               Remove PREFIX before install (dangerous, now only once per run)
  RECONFIGURE=0                Reuse existing build dirs (not recommended)
  ENABLE_DYNAMIC=1|0           Build shared+static (1, default) or static-only (0)
  INSTALL_RUNTIME_TO_SYSROOT=1 Copy libstdc++.so/libgcc_s.so/etc into sysroot (default: 1)
  TARGET_ARCH_BASE=            Default arch for GCC (default: armv8-a)
  TARGET_TUNE=                 Default tune for GCC (default: cortex-a72)

Key vars:
  TARGET=${TARGET}
  PREFIX=${PREFIX}
  SYSROOT=${SYSROOT}

Dirs:
  SRC_ROOT=${SRC_ROOT}
  TARBALL_DIR=${TARBALL_DIR}
  BUILD_DIR=${BUILD_DIR}
  LOG_DIR=${LOG_DIR}
EOF
}

main() {
  echo "Version: $SCRIPT_VERSION"
  local cmd="${1:-}"
  case "${cmd}" in
    binutils) build_binutils ;;
    headers)  install_linux_headers ;;
    stage1)   build_gcc_stage1 ;;
    musl)     build_musl ;;
    gcc)      build_gcc_final ;;
    build)    build_all ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
