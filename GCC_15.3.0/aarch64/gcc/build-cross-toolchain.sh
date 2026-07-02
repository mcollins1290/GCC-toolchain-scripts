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

# Production linker/tool defaults. Keep these configurable because older host
# distros may not have optional development libraries such as libzstd.
BINUTILS_ZSTD="${BINUTILS_ZSTD:-auto}"
GCC_ZSTD="${GCC_ZSTD:-auto}"
DEFAULT_HASH_STYLE="${DEFAULT_HASH_STYLE:-gnu}"
GCC_PKGVERSION="${GCC_PKGVERSION:-GCC ${GCC_VER} Raspberry Pi 4B cross toolchain}"

# Optional production packaging mode: copy the input sysroot into PREFIX and
# configure the compiler against that installed copy.
INSTALL_SYSROOT="${INSTALL_SYSROOT:-1}"
INSTALLED_SYSROOT_REL="${INSTALLED_SYSROOT_REL:-${TARGET}/sysroot}"
MANIFEST_FILE="${MANIFEST_FILE:-${PREFIX}/toolchain-manifest.txt}"

# Optional source authenticity check. Enable only after importing and trusting
# the expected upstream release keys in your local GnuPG keyring.
VERIFY_GPG="${VERIFY_GPG:-1}"

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
SYSROOT_INSTALLED=0

# ------------------------------ Versions / URLs -------------------------------
# GCC
GCC_TARBALL="${GCC_TARBALL:-gcc-${GCC_VER}.tar.xz}"
GCC_URL="${GCC_URL:-https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/${GCC_TARBALL}}"
GCC_SIG_URL="${GCC_SIG_URL:-${GCC_URL}.sig}"
GCC_SHA256="${GCC_SHA256:-fa59c1beef8995f27c4d71c1df227587189315d3e6faff1bb4306e61b0c530eb}"
GCC_SRC_DIR="${GCC_SRC_DIR:-${SRC_ROOT}/gcc-${GCC_VER}}"

# Binutils
BINUTILS_VER="${BINUTILS_VER:-2.46.1}"
BINUTILS_TARBALL="${BINUTILS_TARBALL:-binutils-${BINUTILS_VER}.tar.xz}"
BINUTILS_URL="${BINUTILS_URL:-https://ftp.gnu.org/gnu/binutils/${BINUTILS_TARBALL}}"
BINUTILS_SIG_URL="${BINUTILS_SIG_URL:-${BINUTILS_URL}.sig}"
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

validate_core_settings() {
  [[ -n "${TARGET}" ]] || die "TARGET must not be empty"
  [[ -n "${PREFIX}" && "${PREFIX}" != "/" ]] || die "refusing dangerous PREFIX='${PREFIX}'"
  [[ -n "${SYSROOT}" && "${SYSROOT}" != "/" ]] || die "refusing dangerous SYSROOT='${SYSROOT}'"
}

distclean_remove_path() {
  local label="$1"
  local path="$2"
  local path_abs root_abs prefix_abs sysroot_abs

  [[ -n "${path}" ]] || die "distclean ${label} path must not be empty"
  have_cmd realpath || die "distclean requires realpath"

  path_abs="$(realpath -m "${path}")"
  root_abs="$(realpath -m "${ROOT_DIR}")"
  prefix_abs="$(realpath -m "${PREFIX}")"
  sysroot_abs="$(realpath -m "${SYSROOT}")"

  [[ "${path_abs}" != "/" ]] || die "refusing to distclean ${label}: resolved to /"
  [[ "${path_abs}" != "${root_abs}" ]] || die "refusing to distclean ${label}: resolved to ROOT_DIR (${root_abs})"

  case "${path_abs}" in
    "${root_abs}"/*) ;;
    *) die "refusing to distclean ${label}: ${path_abs} is outside ROOT_DIR (${root_abs})" ;;
  esac

  case "${path_abs}" in
    "${prefix_abs}"|"${prefix_abs}"/*)
      die "refusing to distclean ${label}: ${path_abs} is inside PREFIX (${prefix_abs})"
      ;;
  esac
  case "${prefix_abs}" in
    "${path_abs}"/*)
      die "refusing to distclean ${label}: ${path_abs} contains PREFIX (${prefix_abs})"
      ;;
  esac
  case "${path_abs}" in
    "${sysroot_abs}"|"${sysroot_abs}"/*)
      die "refusing to distclean ${label}: ${path_abs} is inside SYSROOT (${sysroot_abs})"
      ;;
  esac
  case "${sysroot_abs}" in
    "${path_abs}"/*)
      die "refusing to distclean ${label}: ${path_abs} contains SYSROOT (${sysroot_abs})"
      ;;
  esac

  if [[ -e "${path_abs}" ]]; then
    echo "==> distclean: removing ${label}: ${path_abs}"
    rm -rf -- "${path_abs}"
  else
    echo "==> distclean: already clean ${label}: ${path_abs}"
  fi
}

distclean() {
  validate_core_settings

  echo "==> distclean: preserving installed toolchain PREFIX: ${PREFIX}"
  echo "==> distclean: preserving SYSROOT: ${SYSROOT}"

  distclean_remove_path "build directory" "${BUILD_DIR}"
  distclean_remove_path "source directory" "${SRC_ROOT}"
  distclean_remove_path "tarball directory" "${TARBALL_DIR}"
  distclean_remove_path "build log directory" "${LOG_DIR}"
  distclean_remove_path "build GPG cache" "${ROOT_DIR}/.gnupg-build-verify"
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

verify_gpg_signature() {
  local file="$1"
  local sig_url="$2"
  local sig="${file}.sig"

  [[ "${VERIFY_GPG}" == "1" ]] || return 0
  have_cmd gpg || die "VERIFY_GPG=1 requires gpg"

  download_file "${sig_url}" "${sig}"
  gpg --verify "${sig}" "${file}"
  echo "==> gpg signature ok: $(basename "$file")"
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
    verify_gpg_signature "${tb}" "${GCC_SIG_URL}"
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
  verify_gpg_signature "${tb}" "${BINUTILS_SIG_URL}"
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

verify_host() {
  export_basic_env

  local required=(
    bash
    make
    gcc
    g++
    tar
    find
    realpath
    awk
    sed
    grep
    sha256sum
    strings
  )
  local recommended=(
    curl
    wget
    bison
    flex
    makeinfo
    rsync
    gpg
    pkg-config
    qemu-aarch64
    patchelf
    ssh
    scp
  )

  local missing=0 cmd
  echo "==> host required tools"
  for cmd in "${required[@]}"; do
    if have_cmd "${cmd}"; then
      printf '  ok   %s -> %s\n' "${cmd}" "$(command -v "${cmd}")"
    else
      printf '  MISS %s\n' "${cmd}"
      missing=1
    fi
  done

  if ! have_cmd curl && ! have_cmd wget; then
    echo "  MISS curl or wget (one is required for downloads)"
    missing=1
  fi
  if [[ "${INSTALL_SYSROOT}" == "1" ]] && ! have_cmd rsync; then
    echo "  MISS rsync (required because INSTALL_SYSROOT=1)"
    missing=1
  fi
  if [[ "${VERIFY_GPG}" == "1" ]] && ! have_cmd gpg; then
    echo "  MISS gpg (required because VERIFY_GPG=1)"
    missing=1
  fi

  echo
  echo "==> host recommended tools"
  for cmd in "${recommended[@]}"; do
    if have_cmd "${cmd}"; then
      printf '  ok   %s -> %s\n' "${cmd}" "$(command -v "${cmd}")"
    else
      printf '  WARN %s not found\n' "${cmd}"
    fi
  done

  echo
  echo "==> host development headers"
  if printf '#include <zlib.h>\nint main(void){return 0;}\n' | gcc -x c - -lz -o /tmp/gcc-toolchain-zlib-check.$$ >/dev/null 2>&1; then
    echo "  ok   zlib headers/library"
    rm -f /tmp/gcc-toolchain-zlib-check.$$
  else
    echo "  MISS zlib headers/library (needed for --with-system-zlib)"
    missing=1
  fi

  if printf '#include <zstd.h>\nint main(void){return 0;}\n' | gcc -x c - -lzstd -o /tmp/gcc-toolchain-zstd-check.$$ >/dev/null 2>&1; then
    echo "  ok   zstd headers/library"
    rm -f /tmp/gcc-toolchain-zstd-check.$$
  else
    echo "  WARN zstd headers/library not found; zstd support may be disabled or configure may fail if forced"
  fi

  echo
  echo "==> host summary"
  echo "  TARGET=${TARGET}"
  echo "  PREFIX=${PREFIX}"
  echo "  SYSROOT=${SYSROOT}"
  echo "  INSTALL_SYSROOT=${INSTALL_SYSROOT}"
  echo "  VERIFY_GPG=${VERIFY_GPG}"
  echo "  BUILD_TRIPLET=${BUILD_TRIPLET:-$(build_triplet)}"

  require_sysroot
  echo "  sysroot ok: ${SYSROOT}"
  [[ "${missing}" == "0" ]] || die "host verification failed"
  echo "==> verify-host: PASS"
}

build_triplet() {
  if have_cmd gcc; then
    gcc -dumpmachine
  elif [[ -x "${BINUTILS_SRC_DIR}/config.guess" ]]; then
    "${BINUTILS_SRC_DIR}/config.guess"
  elif [[ -x "${GCC_SRC_DIR}/config.guess" ]]; then
    "${GCC_SRC_DIR}/config.guess"
  else
    die "cannot determine build triplet; install host gcc or set BUILD_TRIPLET"
  fi
}

effective_sysroot() {
  if [[ "${INSTALL_SYSROOT}" == "1" ]]; then
    printf '%s/%s\n' "${PREFIX}" "${INSTALLED_SYSROOT_REL}"
  else
    printf '%s\n' "${SYSROOT}"
  fi
}

install_sysroot_if_requested() {
  [[ "${INSTALL_SYSROOT}" == "1" ]] || return 0
  [[ "${SYSROOT_INSTALLED}" == "0" ]] || return 0
  require_sysroot
  have_cmd rsync || die "INSTALL_SYSROOT=1 requires rsync"

  local dest
  dest="$(effective_sysroot)"
  [[ -n "${dest}" && "${dest}" != "/" ]] || die "refusing dangerous installed sysroot path: ${dest}"
  mkdirp "${dest}"

  log_step "install-sysroot" rsync -a --delete \
    --exclude='/dev/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/tmp/*' \
    "${SYSROOT}/" "${dest}/"
  SYSROOT_INSTALLED=1
}

libc_version_from_sysroot() {
  local libc
  libc="$(find "${SYSROOT}" -type f -name 'libc.so.6' -print -quit 2>/dev/null || true)"
  if [[ -n "${libc}" ]]; then
    strings "${libc}" 2>/dev/null | grep -E '^GNU C Library|^glibc ' | head -n 1 || true
  fi
}

write_manifest() {
  export_basic_env
  mkdirp "$(dirname "${MANIFEST_FILE}")"

  local effective build host
  effective="$(effective_sysroot)"
  build="${BUILD_TRIPLET:-$(build_triplet)}"
  host="${HOST_TRIPLET:-${build}}"

  {
    echo "toolchain_manifest_version=1"
    echo "script_version=${SCRIPT_VERSION}"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "target=${TARGET}"
    echo "build_triplet=${build}"
    echo "host_triplet=${host}"
    echo "prefix=${PREFIX}"
    echo "source_sysroot=${SYSROOT}"
    echo "effective_sysroot=${effective}"
    echo "install_sysroot=${INSTALL_SYSROOT}"
    echo "gcc_version=${GCC_VER}"
    echo "gcc_tarball=${GCC_TARBALL}"
    echo "gcc_sha256=${GCC_SHA256}"
    echo "binutils_version=${BINUTILS_VER}"
    echo "binutils_tarball=${BINUTILS_TARBALL}"
    echo "binutils_sha256=${BINUTILS_SHA256}"
    echo "target_arch_base=${TARGET_ARCH_BASE}"
    echo "target_tune=${TARGET_TUNE}"
    echo "default_hash_style=${DEFAULT_HASH_STYLE}"
    echo "binutils_zstd=${BINUTILS_ZSTD}"
    echo "gcc_zstd=${GCC_ZSTD}"
    echo "gcc_pkgversion=${GCC_PKGVERSION}"
    echo "libc_version=$(libc_version_from_sysroot)"
    echo
    echo "[configure.binutils]"
    echo "--build=${build} --host=${host} --target=${TARGET} --prefix=${PREFIX} --with-sysroot=${effective} --disable-multilib --disable-werror --disable-nls --enable-plugins --enable-lto --enable-ld=default --enable-relro --enable-default-hash-style=${DEFAULT_HASH_STYLE} --with-zstd=${BINUTILS_ZSTD} --with-system-zlib"
    echo
    echo "[configure.gcc]"
    echo "--build=${build} --host=${host} --target=${TARGET} --prefix=${PREFIX} --with-sysroot=${effective} --with-build-sysroot=${effective} --with-native-system-header-dir=/usr/include --enable-multiarch --disable-multilib --enable-languages=c,c++ --enable-shared --enable-threads=posix --enable-linker-build-id --enable-plugin --enable-lto --with-system-zlib --with-arch=${TARGET_ARCH_BASE} --with-tune=${TARGET_TUNE} --disable-bootstrap --enable-host-pie --enable-host-bind-now --enable-default-pie --enable-default-ssp --with-pkgversion='${GCC_PKGVERSION}'"
  } > "${MANIFEST_FILE}"

  echo "==> manifest written: ${MANIFEST_FILE}"
}

# ----------------------------- Build: binutils --------------------------------
build_binutils() {
  export_basic_env
  require_sysroot
  ensure_binutils_source

  have_cmd make || die "missing make"
  have_cmd gcc || die "missing host gcc"

  clean_prefix_once
  install_sysroot_if_requested
  mkdirp "${BINUTILS_BUILD_DIR}"

  local build host sysroot_for_build
  build="${BUILD_TRIPLET:-$(build_triplet)}"
  host="${HOST_TRIPLET:-${build}}"
  sysroot_for_build="$(effective_sysroot)"

  log_step "configure-binutils" bash -lc "
    cd '${BINUTILS_BUILD_DIR}'
    '${BINUTILS_SRC_DIR}/configure' \
      --build='${build}' \
      --host='${host}' \
      --target='${TARGET}' \
      --prefix='${PREFIX}' \
      --with-sysroot='${sysroot_for_build}' \
      --disable-multilib \
      --disable-werror \
      --disable-nls \
      --enable-plugins \
      --enable-lto \
      --enable-ld=default \
      --enable-relro \
      --enable-default-hash-style='${DEFAULT_HASH_STYLE}' \
      --with-zstd='${BINUTILS_ZSTD}' \
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
  if [[ "${CLEAN_PREFIX}" == "1" && "${PREFIX_CLEANED}" == "0" ]]; then
    die "CLEAN_PREFIX=1 with command 'gcc' would remove installed binutils. Run '$0 build' or '$0 binutils' first."
  fi
  clean_prefix_once
  install_sysroot_if_requested

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
  local with_zstd=""
  if [[ -x "${PREFIX}/bin/${TARGET}-as" ]]; then
    with_as="--with-as=${PREFIX}/bin/${TARGET}-as"
  fi
  if [[ -x "${PREFIX}/bin/${TARGET}-ld" ]]; then
    with_ld="--with-ld=${PREFIX}/bin/${TARGET}-ld"
  fi
  case "${GCC_ZSTD}" in
    auto) with_zstd="" ;;
    yes|system) with_zstd="--with-zstd" ;;
    no) with_zstd="--without-zstd" ;;
    *) with_zstd="--with-zstd=${GCC_ZSTD}" ;;
  esac

  local build host sysroot_for_build
  build="${BUILD_TRIPLET:-$(build_triplet)}"
  host="${HOST_TRIPLET:-${build}}"
  sysroot_for_build="$(effective_sysroot)"

  log_step "configure-gcc-final" bash -lc "
    cd '${gcc_build}'
    '${GCC_SRC_DIR}/configure' \
      --build='${build}' \
      --host='${host}' \
      --target='${TARGET}' \
      --prefix='${PREFIX}' \
      --with-sysroot='${sysroot_for_build}' \
      --with-build-sysroot='${sysroot_for_build}' \
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
      ${with_zstd} \
      --without-included-gettext \
      --enable-checking=release \
      --disable-werror \
      --with-arch='${TARGET_ARCH_BASE}' \
      --with-tune='${TARGET_TUNE}' \
      --disable-bootstrap \
      --enable-host-pie \
      --enable-host-bind-now \
      --enable-default-pie \
      --enable-default-ssp \
      --with-pkgversion='${GCC_PKGVERSION}' \
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
  write_manifest
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
  verify-host  Check host tools, libraries, GPG/download tools, and SYSROOT
  fetch-hashes Download source archives and print candidate SHA256 values
  binutils   Download/extract (if needed) + build+install cross binutils into PREFIX
  gcc        Download/extract (if needed) + build+install final GCC (C,C++) into PREFIX
  build      Build binutils then GCC
  distclean  Remove workspace build artifacts, sources, tarballs, logs, and build GPG cache; keep PREFIX

Env toggles:
  CLEAN_PREFIX=1      Remove PREFIX before install (dangerous, now only happens once per run)
  RECONFIGURE=0       Reuse existing gcc build dir (not recommended)
  TARGET_ARCH_BASE=   Default arch for GCC (default: armv8-a)
  TARGET_TUNE=        Default tune for GCC (default: cortex-a72)
  BINUTILS_ZSTD=      zstd support mode for binutils (default: auto)
  GCC_ZSTD=           GCC zstd mode: auto, yes/system, no, or prefix path (default: auto)
  DEFAULT_HASH_STYLE= GNU ld default hash style (default: gnu)
  GCC_PKGVERSION=     GCC package identity string (default: ${GCC_PKGVERSION})
  INSTALL_SYSROOT=    Copy SYSROOT into PREFIX/${INSTALLED_SYSROOT_REL} (default: ${INSTALL_SYSROOT})
  INSTALLED_SYSROOT_REL= Relative installed sysroot path (default: ${TARGET}/sysroot)
  MANIFEST_FILE=      Build manifest output (default: ${MANIFEST_FILE})
  VERIFY_GPG=         Verify source .sig files with local trusted GnuPG keys (default: ${VERIFY_GPG})
  BUILD_TRIPLET=      Override detected build triplet
  HOST_TRIPLET=       Override host triplet for generated tools

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
    verify-host)  verify_host ;;
    fetch-hashes) print_source_hashes ;;
    binutils) build_binutils ;;
    gcc)      build_toolchain ;;
    build)    build_all ;;
    distclean) distclean ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
