#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# GCC cross toolchain builder
# Target: aarch64-linux-gnu
# Sysroot: external (e.g. Raspberry Pi rootfs)
# ==============================================================================

###############################################################################
# Script Metadata
###############################################################################
SCRIPT_VERSION="v0.1.0"

# ------------------------------ User config -----------------------------------
TARGET="${TARGET:-aarch64-linux-gnu}"
GCC_VER="${GCC_VER:-15.3.0}"
PREFIX="${PREFIX:-/opt/gcc-${GCC_VER}-cross}"
SYSROOT="${SYSROOT:-/build-rpi/rpi/sysroot}"

# These are *defaults for GCC*, not required build flags for your projects.
# For Debian multiarch sysroots, keep arch broad and tune for Pi4 by default.
TARGET_ARCH_BASE="${TARGET_ARCH_BASE:-armv8-a}"
TARGET_TUNE="${TARGET_TUNE:-cortex-a72}"

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

# Reconfigure behavior: gcc configure results can become "sticky".
# Default: nuke gcc build dir before configure to avoid stale multiarch/sysroot paths.
RECONFIGURE="${RECONFIGURE:-1}"

# Internal guard: ensure we only clean PREFIX once per script invocation
PREFIX_CLEANED=0

# ------------------------------ Versions / URLs -------------------------------
# GCC
GCC_TARBALL="${GCC_TARBALL:-gcc-${GCC_VER}.tar.xz}"
GCC_URL="${GCC_URL:-https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/${GCC_TARBALL}}"
GCC_SHA256="${GCC_SHA256:-fa59c1beef8995f27c4d71c1df227587189315d3e6faff1bb4306e61b0c530eb}"
GCC_SRC_DIR="${GCC_SRC_DIR:-${SRC_ROOT}/gcc-${GCC_VER}}"

# Binutils
BINUTILS_VER="${BINUTILS_VER:-2.46.1}"
BINUTILS_TARBALL="${BINUTILS_TARBALL:-binutils-${BINUTILS_VER}.tar.xz}"
BINUTILS_URL="${BINUTILS_URL:-https://ftp.gnu.org/gnu/binutils/${BINUTILS_TARBALL}}"
BINUTILS_SHA256="${BINUTILS_SHA256:-e127a709cba24c76de8936cb7083dd768f28cd37eb010492e2f19b71eb1294e4}"
BINUTILS_SRC_DIR="${BINUTILS_SRC_DIR:-${SRC_ROOT}/binutils-${BINUTILS_VER}}"
BINUTILS_BUILD_DIR="${BINUTILS_BUILD_DIR:-${BUILD_DIR}/binutils}"

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
  [[ -n "$expect" ]] || die "no SHA256 provided for $(basename "$file"); refusing unverified source"
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
  tar --no-same-owner -xf "$tarball" -C "$tmp"
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

  # Ensure GCC prerequisites are present (gmp/mpfr/mpc/isl)
  if [[ ! -f "${GCC_SRC_DIR}/gmp/README" ]]; then
    echo "==> gcc: fetching prerequisites (gmp/mpfr/mpc/isl)"
    ( cd "${GCC_SRC_DIR}" && TAR_OPTIONS="${TAR_OPTIONS:+${TAR_OPTIONS} }--no-same-owner" ./contrib/download_prerequisites )
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

print_source_hashes() {
  have_cmd sha256sum || die "sha256sum not found"
  mkdirp "${TARBALL_DIR}"

  local gcc_tb="${TARBALL_DIR}/${GCC_TARBALL}"
  local binutils_tb="${TARBALL_DIR}/${BINUTILS_TARBALL}"
  download_file "${GCC_URL}" "${gcc_tb}"
  download_file "${BINUTILS_URL}" "${binutils_tb}"

  echo
  echo "Candidate hashes; verify these against upstream signatures before pinning:"
  sha256sum "${gcc_tb}" "${binutils_tb}"
}

# ------------------------------ Env ------------------------------------------
export_basic_env() {
  export LC_ALL=C
  umask 022

  : "${ACTIVE_PREFIX:=${PREFIX}}"
  SYSROOT="${SYSROOT%/}"
  PREFIX="${PREFIX%/}"

  # Keep environment clean: do NOT export LD_LIBRARY_PATH globally.
  export PATH="${ACTIVE_PREFIX}/bin:${PATH}"

  export CFLAGS="${CFLAGS:--O2 -pipe}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe}"
}

# ------------------------------ Preconditions ---------------------------------
require_sysroot() {
  [[ -d "${SYSROOT}" ]] || die "SYSROOT not found: ${SYSROOT}"
  [[ -d "${SYSROOT}/usr/include" ]] || die "SYSROOT missing usr/include: ${SYSROOT}"

  # Debian multiarch sysroots: these typically live under /usr/lib/aarch64-linux-gnu.
  # Search with stderr suppressed so unrelated unreadable directories inside a
  # copied sysroot do not mask valid startup files.
  local crt
  for crt in crt1.o crti.o crtn.o; do
    [[ -n "$(find "${SYSROOT}" -type f -name "${crt}" -print -quit 2>/dev/null)" ]] \
      || die "SYSROOT missing ${crt} start file"
  done

  [[ -n "$(find "${SYSROOT}" -type f -name 'ld-linux-aarch64.so.1' -print -quit 2>/dev/null)" ]] \
    || die "SYSROOT missing dynamic linker ld-linux-aarch64.so.1"

  [[ -f "${SYSROOT}/usr/lib/aarch64-linux-gnu/libc.so" ]] || \
    echo "WARNING: libc.so not found at /usr/lib/aarch64-linux-gnu/libc.so (link-time libc script). Continuing..." >&2
}

require_binutils_in_prefix() {
  [[ -x "${PREFIX}/bin/${TARGET}-as" ]] || die "missing ${PREFIX}/bin/${TARGET}-as (binutils not installed or prefix cleaned)"
  [[ -x "${PREFIX}/bin/${TARGET}-ld" ]] || die "missing ${PREFIX}/bin/${TARGET}-ld (binutils not installed or prefix cleaned)"
}

# ----------------------------- Build: binutils --------------------------------
build_binutils() {
  export_basic_env
  require_sysroot
  ensure_binutils_source

  have_cmd make || die "missing make"
  have_cmd gcc || die "missing host gcc"

  clean_prefix_once
  mkdirp "${BINUTILS_BUILD_DIR}"

  log_step "configure-binutils" bash -lc "
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
      --enable-ld=default \
      --with-system-zlib
  "

  log_step "build-binutils" bash -lc "
    cd '${BINUTILS_BUILD_DIR}'
    make -j'${JOBS}'
  "

  log_step "install-binutils" bash -lc "
    cd '${BINUTILS_BUILD_DIR}'
    make install
  "

  echo "==> binutils installed to ${PREFIX}"
}

# ----------------------------- Build: GCC final -------------------------------
build_toolchain() {
  export_basic_env
  require_sysroot
  ensure_gcc_source

  have_cmd make || die "missing make"
  have_cmd gcc || die "missing host gcc"
  have_cmd g++ || die "missing host g++"

  # If CLEAN_PREFIX=1 and user ran only "gcc", this would nuke the prefix.
  # Keep behavior consistent: only clean once per invocation, but also ensure binutils exist.
  clean_prefix_once

  # Binutils must exist for target compilation tests (libgcc configure)
  require_binutils_in_prefix

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

  log_step "configure-gcc-final" bash -lc "
    cd '${gcc_build}'
    '${GCC_SRC_DIR}/configure' \
      --target='${TARGET}' \
      --prefix='${PREFIX}' \
      --with-sysroot='${SYSROOT}' \
      --with-build-sysroot='${SYSROOT}' \
      --with-native-system-header-dir=/usr/include \
      --enable-multiarch \
      --disable-multilib \
      --enable-languages=c,c++ \
      --enable-shared \
      --enable-threads=posix \
      --enable-linker-build-id \
      --enable-plugin \
      --enable-lto \
      --with-system-zlib \
      --without-included-gettext \
      --enable-checking=release \
      --disable-werror \
      --with-arch='${TARGET_ARCH_BASE}' \
      --with-tune='${TARGET_TUNE}' \
      --disable-bootstrap \
      --enable-default-pie \
      --enable-default-ssp \
      ${with_as} ${with_ld}
  "

  log_step "build-gcc-final" bash -lc "
    cd '${gcc_build}'
    make -j'${JOBS}'
  "

  log_step "install-gcc-final" bash -lc "
    cd '${gcc_build}'
    make install
  "

  echo
  echo "==> GCC installed to ${PREFIX}"
}

build_all() {
  build_binutils
  build_toolchain
}

# ------------------------------ Main ------------------------------------------
usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  fetch-hashes Download source archives and print candidate SHA256 values
  binutils   Download/extract (if needed) + build+install cross binutils into PREFIX
  gcc        Download/extract (if needed) + build+install final GCC (C,C++) into PREFIX
  build      Build binutils then GCC

Env toggles:
  CLEAN_PREFIX=1      Remove PREFIX before install (dangerous, now only happens once per run)
  RECONFIGURE=0       Reuse existing gcc build dir (not recommended)
  TARGET_ARCH_BASE=   Default arch for GCC (default: armv8-a)
  TARGET_TUNE=        Default tune for GCC (default: cortex-a72)

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
    fetch-hashes) print_source_hashes ;;
    binutils) build_binutils ;;
    gcc)      build_toolchain ;;
    build)    build_all ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
