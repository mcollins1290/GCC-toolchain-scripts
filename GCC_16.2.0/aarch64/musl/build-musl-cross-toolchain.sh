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
SCRIPT_VERSION="v0.1.0-musl"

# ------------------------------ User config -----------------------------------
TARGET="${TARGET:-aarch64-linux-musl}"
GCC_VER="${GCC_VER:-16.2.0}"
PREFIX="${PREFIX:-/opt/gcc-${GCC_VER}-musl-cross}"

# For musl toolchains, a self-contained sysroot is typical.
SYSROOT="${SYSROOT:-${PREFIX}/${TARGET}/sysroot}"

# These are *defaults for GCC*, not required build flags for your projects.
TARGET_ARCH_BASE="${TARGET_ARCH_BASE:-armv8-a}"
TARGET_TUNE="${TARGET_TUNE:-cortex-a72}"

# Final GCC: enable shared runtimes (dynamic-capable toolchain)
ENABLE_DYNAMIC="${ENABLE_DYNAMIC:-1}"                 # 1 => build shared+static (recommended), 0 => static-only
INSTALL_RUNTIME_TO_SYSROOT="${INSTALL_RUNTIME_TO_SYSROOT:-1}"  # 1 => copy libstdc++.so, libgcc_s.so, etc into sysroot

# Production linker/tool defaults. Keep zstd configurable because older host
# distros may not have the development libraries installed.
BINUTILS_ZSTD="${BINUTILS_ZSTD:-auto}"
GCC_ZSTD="${GCC_ZSTD:-auto}"
DEFAULT_HASH_STYLE="${DEFAULT_HASH_STYLE:-gnu}"
GCC_PKGVERSION="${GCC_PKGVERSION:-GCC ${GCC_VER} Raspberry Pi 4B musl cross toolchain}"
MANIFEST_FILE="${MANIFEST_FILE:-${PREFIX}/toolchain-manifest.txt}"

# Optional source authenticity check. Enable after importing and trusting the
# expected upstream release keys in your local GnuPG keyring.
VERIFY_GPG="${VERIFY_GPG:-1}"

# Expected upstream source-signing primary fingerprints. GPG trust is still a
# local policy decision, but these assertions prevent accepting the wrong key.
GCC_GPG_PRIMARY_FPR="${GCC_GPG_PRIMARY_FPR:-13975A70E63C361C73AE69EF6EEB81F8981C74C7}"
BINUTILS_GPG_PRIMARY_FPR="${BINUTILS_GPG_PRIMARY_FPR:-5EF3A41171BB77E6110ED2D01F3D03348DB1A3E2}"
MUSL_GPG_PRIMARY_FPR="${MUSL_GPG_PRIMARY_FPR:-836489290BB6B70F99FFDA0556BCDB593020450F}"

# Layout
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="${SRC_ROOT:-${ROOT_DIR}/src}"
TARBALL_DIR="${TARBALL_DIR:-${ROOT_DIR}/tarballs}"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
FRESH_LOGS="${FRESH_LOGS:-1}"
SOURCE_REFRESH="${SOURCE_REFRESH:-1}"

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
GCC_TARBALL="${GCC_TARBALL:-gcc-${GCC_VER}.tar.xz}"
GCC_URL="${GCC_URL:-https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VER}/${GCC_TARBALL}}"
GCC_SIG_URL="${GCC_SIG_URL:-${GCC_URL}.sig}"
GCC_SHA256="${GCC_SHA256:-e6738e29597f733270731aa90600f37ffdc045079dfc27ec7e8192cc81085c3e}"
GCC_SRC_DIR="${GCC_SRC_DIR:-${SRC_ROOT}/gcc-${GCC_VER}}"

# Binutils
BINUTILS_VER="${BINUTILS_VER:-2.46.1}"
BINUTILS_TARBALL="${BINUTILS_TARBALL:-binutils-${BINUTILS_VER}.tar.xz}"
BINUTILS_URL="${BINUTILS_URL:-https://ftp.gnu.org/gnu/binutils/${BINUTILS_TARBALL}}"
BINUTILS_SIG_URL="${BINUTILS_SIG_URL:-${BINUTILS_URL}.sig}"
BINUTILS_SHA256="${BINUTILS_SHA256:-e127a709cba24c76de8936cb7083dd768f28cd37eb010492e2f19b71eb1294e4}"
BINUTILS_SRC_DIR="${BINUTILS_SRC_DIR:-${SRC_ROOT}/binutils-${BINUTILS_VER}}"
BINUTILS_BUILD_DIR="${BINUTILS_BUILD_DIR:-${BUILD_DIR}/binutils}"

# Linux kernel headers (needed for libc)
LINUX_VER="${LINUX_VER:-6.18.37}"
LINUX_TARBALL="${LINUX_TARBALL:-linux-${LINUX_VER}.tar.xz}"
LINUX_URL="${LINUX_URL:-https://cdn.kernel.org/pub/linux/kernel/v6.x/${LINUX_TARBALL}}"
LINUX_SHA256="${LINUX_SHA256:-a83cd200e6646db52866b8309e9137b9e9048b613cbda10ced2b811aae125255}"
LINUX_SRC_DIR="${LINUX_SRC_DIR:-${SRC_ROOT}/linux-${LINUX_VER}}"
LINUX_BUILD_DIR="${LINUX_BUILD_DIR:-${BUILD_DIR}/linux-headers}"

# musl
MUSL_VER="${MUSL_VER:-1.2.6}"
MUSL_TARBALL="${MUSL_TARBALL:-musl-${MUSL_VER}.tar.gz}"
MUSL_URL="${MUSL_URL:-https://musl.libc.org/releases/${MUSL_TARBALL}}"
MUSL_SIG_URL="${MUSL_SIG_URL:-${MUSL_URL}.asc}"
MUSL_SHA256="${MUSL_SHA256:-d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a}"
MUSL_SRC_DIR="${MUSL_SRC_DIR:-${SRC_ROOT}/musl-${MUSL_VER}}"
MUSL_BUILD_DIR="${MUSL_BUILD_DIR:-${BUILD_DIR}/musl}"
MUSL_RELEASES_URL="${MUSL_RELEASES_URL:-https://musl.libc.org/releases.html}"

# Upstream fix for CVE-2026-6042. The qsort fix for CVE-2026-40200 is
# 32-bit-only and does not affect this aarch64 toolchain.
MUSL_ICONV_PATCH_COMMIT="${MUSL_ICONV_PATCH_COMMIT:-67219f0130ec7c876ac0b299046460fad31caabf}"
MUSL_ICONV_PATCH_URL="${MUSL_ICONV_PATCH_URL:-https://git.musl-libc.org/cgit/musl/patch/?id=${MUSL_ICONV_PATCH_COMMIT}}"
MUSL_ICONV_PATCH_FILE="${MUSL_ICONV_PATCH_FILE:-${TARBALL_DIR}/musl-${MUSL_ICONV_PATCH_COMMIT}.patch}"
MUSL_ICONV_PATCH_SHA256="${MUSL_ICONV_PATCH_SHA256:-1d0be2e72b9d5bd16546b923aa8af861d271322f01644716a81823bec4065c99}"

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

reset_logs_for_run() {
  [[ "${FRESH_LOGS}" == "1" ]] || return 0

  mkdirp "${LOG_DIR}"
  rm -f "${LOG_DIR}"/*.log
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

validate_settings() {
  validate_core_settings

  case "${FRESH_LOGS}" in
    0|1) ;;
    *) die "FRESH_LOGS must be 0 or 1" ;;
  esac
  case "${SOURCE_REFRESH}" in
    0|1) ;;
    *) die "SOURCE_REFRESH must be 0 or 1" ;;
  esac
  case "${RECONFIGURE}" in
    0|1) ;;
    *) die "RECONFIGURE must be 0 or 1" ;;
  esac
  case "${VERIFY_GPG}" in
    0|1) ;;
    *) die "VERIFY_GPG must be 0 or 1" ;;
  esac
  case "${CLEAN_PREFIX}" in
    0|1) ;;
    *) die "CLEAN_PREFIX must be 0 or 1" ;;
  esac
  case "${ENABLE_DYNAMIC}" in
    0|1) ;;
    *) die "ENABLE_DYNAMIC must be 0 or 1" ;;
  esac
  case "${INSTALL_RUNTIME_TO_SYSROOT}" in
    0|1) ;;
    *) die "INSTALL_RUNTIME_TO_SYSROOT must be 0 or 1" ;;
  esac
  case "${DEFAULT_HASH_STYLE}" in
    sysv|gnu|both) ;;
    *) die "DEFAULT_HASH_STYLE must be sysv, gnu, or both" ;;
  esac
  case "${BINUTILS_ZSTD}" in
    auto|yes|no) ;;
    *) die "BINUTILS_ZSTD must be auto, yes, or no" ;;
  esac
  case "${GCC_ZSTD}" in
    auto|yes|system|no|/*) ;;
    *) die "GCC_ZSTD must be auto, yes/system, no, or an absolute prefix path" ;;
  esac

  if [[ "${SOURCE_REFRESH}" == "1" && "${RECONFIGURE}" == "0" ]]; then
    die "SOURCE_REFRESH=1 requires RECONFIGURE=1 so build directories cannot point at stale source trees"
  fi
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
  echo "==> distclean: preserving SYSROOT under PREFIX: ${SYSROOT}"

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

fetch_url_stdout() {
  local url="$1"

  if have_cmd curl; then
    curl -fsSL "${url}"
  elif have_cmd wget; then
    wget -qO- "${url}"
  else
    return 127
  fi
}

latest_musl_release() {
  local release_index latest

  release_index="$(fetch_url_stdout "${MUSL_RELEASES_URL}")" || return 1
  latest="$(
    printf '%s\n' "${release_index}" |
      grep -Eo 'musl-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' |
      sed -E 's/^musl-//; s/\.tar\.gz$//' |
      sort -Vu |
      tail -n 1
  )"

  [[ -n "${latest}" ]] || return 1
  printf '%s\n' "${latest}"
}

version_compare() {
  local lhs="$1" rhs="$2"

  if [[ "${lhs}" == "${rhs}" ]]; then
    printf '= '
  elif [[ "$(printf '%s\n%s\n' "${lhs}" "${rhs}" | sort -V | tail -n 1)" == "${lhs}" ]]; then
    printf '> '
  else
    printf '< '
  fi
}

check_musl_updates() {
  local latest relation

  latest="$(latest_musl_release)" || {
    echo "could not determine latest musl release from ${MUSL_RELEASES_URL}" >&2
    return 1
  }
  relation="$(version_compare "${MUSL_VER}" "${latest}")"

  echo "configured musl: ${MUSL_VER}"
  echo "latest musl:     ${latest}"
  case "${relation}" in
    "= ") echo "status:          current" ;;
    "< ") echo "status:          update available" ;;
    "> ") echo "status:          configured version is newer than latest official release" ;;
  esac
  echo
  echo "note: this check is advisory only; builds remain pinned to MUSL_VER and MUSL_SHA256."
}

check_musl_updates_command() {
  check_musl_updates || die "musl update check failed"
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

normalize_fpr() {
  tr '[:lower:]' '[:upper:]' <<< "${1//[[:space:]]/}"
}

verify_gpg_signature() {
  local file="$1"
  local sig_url="$2"
  local expected_fpr="$3"
  local sig="${file}.sig"

  [[ "${VERIFY_GPG}" == "1" ]] || return 0
  have_cmd gpg || die "VERIFY_GPG=1 requires gpg"

  download_file "${sig_url}" "${sig}"

  local status expected gpg_status
  expected="$(normalize_fpr "${expected_fpr}")"
  gpg_status=0
  status="$(gpg --status-fd 1 --verify "${sig}" "${file}" 2>&1)" || gpg_status=$?
  printf '%s\n' "${status}"

  [[ "${gpg_status}" == "0" ]] || die "GPG verification failed for $(basename "$file")"

  if ! awk -v expect="${expected}" '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      if (toupper($3) == expect || toupper($NF) == expect) ok = 1
    }
    END { exit ok ? 0 : 1 }
  ' <<< "${status}"; then
    die "GPG signature for $(basename "$file") was not made by expected key ${expected}"
  fi

  echo "==> gpg signature ok: $(basename "$file") (expected key ${expected})"
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

refresh_source_tree() {
  local dest="$1"

  [[ "${SOURCE_REFRESH}" == "1" ]] || return 0
  if [[ -d "${dest}" ]]; then
    echo "==> source refresh: removing existing ${dest}"
    rm -rf "${dest}"
  fi
}

ensure_gcc_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  local tb="${TARBALL_DIR}/${GCC_TARBALL}"
  download_file "${GCC_URL}" "${tb}"
  verify_sha256 "${tb}" "${GCC_SHA256}"
  verify_gpg_signature "${tb}" "${GCC_SIG_URL}" "${GCC_GPG_PRIMARY_FPR}"
  refresh_source_tree "${GCC_SRC_DIR}"
  extract_tarball "${tb}" "${GCC_SRC_DIR}"

  if [[ ! -f "${GCC_SRC_DIR}/gmp/README" ]]; then
    echo "==> gcc: fetching prerequisites (gmp/mpfr/mpc/isl)"
    ( cd "${GCC_SRC_DIR}" && TAR_OPTIONS="${TAR_OPTIONS:+${TAR_OPTIONS} }--no-same-owner" ./contrib/download_prerequisites )
  fi
}

ensure_binutils_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  local tb="${TARBALL_DIR}/${BINUTILS_TARBALL}"
  download_file "${BINUTILS_URL}" "${tb}"
  verify_sha256 "${tb}" "${BINUTILS_SHA256}"
  verify_gpg_signature "${tb}" "${BINUTILS_SIG_URL}" "${BINUTILS_GPG_PRIMARY_FPR}"
  refresh_source_tree "${BINUTILS_SRC_DIR}"
  extract_tarball "${tb}" "${BINUTILS_SRC_DIR}"
}

ensure_linux_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  local tb="${TARBALL_DIR}/${LINUX_TARBALL}"
  download_file "${LINUX_URL}" "${tb}"
  verify_sha256 "${tb}" "${LINUX_SHA256}"
  refresh_source_tree "${LINUX_SRC_DIR}"
  if [[ -d "${LINUX_SRC_DIR}" && -f "${LINUX_SRC_DIR}/Makefile" ]]; then
    echo "==> extract: already extracted: ${LINUX_SRC_DIR}"
    return 0
  fi
  echo "==> extract: $tb -> ${LINUX_SRC_DIR}"
  rm -rf "${LINUX_SRC_DIR}"
  mkdirp "$(dirname "${LINUX_SRC_DIR}")"
  tar --no-same-owner -xf "$tb" -C "$(dirname "${LINUX_SRC_DIR}")"
  [[ -f "${LINUX_SRC_DIR}/Makefile" ]] || die "linux extract missing Makefile: ${LINUX_SRC_DIR}"
}

ensure_musl_source() {
  mkdirp "${SRC_ROOT}" "${TARBALL_DIR}"
  local tb="${TARBALL_DIR}/${MUSL_TARBALL}"
  download_file "${MUSL_URL}" "${tb}"
  verify_sha256 "${tb}" "${MUSL_SHA256}"
  verify_gpg_signature "${tb}" "${MUSL_SIG_URL}" "${MUSL_GPG_PRIMARY_FPR}"
  refresh_source_tree "${MUSL_SRC_DIR}"
  extract_tarball "${tb}" "${MUSL_SRC_DIR}"

  local marker="${MUSL_SRC_DIR}/.patched-${MUSL_ICONV_PATCH_COMMIT}"
  if [[ ! -f "${marker}" ]]; then
    have_cmd patch || die "missing patch utility"
    download_file "${MUSL_ICONV_PATCH_URL}" "${MUSL_ICONV_PATCH_FILE}"
    verify_sha256 "${MUSL_ICONV_PATCH_FILE}" "${MUSL_ICONV_PATCH_SHA256}"
    grep -q "From ${MUSL_ICONV_PATCH_COMMIT} " "${MUSL_ICONV_PATCH_FILE}" \
      || die "musl patch does not identify expected commit ${MUSL_ICONV_PATCH_COMMIT}"
    echo "==> musl: applying CVE-2026-6042 fix ${MUSL_ICONV_PATCH_COMMIT}"
    ( cd "${MUSL_SRC_DIR}" && patch -p1 < "${MUSL_ICONV_PATCH_FILE}" )
    touch "${marker}"
  fi
}

print_source_hashes() {
  have_cmd sha256sum || die "sha256sum not found"
  mkdirp "${TARBALL_DIR}"

  local gcc_tb="${TARBALL_DIR}/${GCC_TARBALL}"
  local binutils_tb="${TARBALL_DIR}/${BINUTILS_TARBALL}"
  local linux_tb="${TARBALL_DIR}/${LINUX_TARBALL}"
  local musl_tb="${TARBALL_DIR}/${MUSL_TARBALL}"
  download_file "${GCC_URL}" "${gcc_tb}"
  download_file "${BINUTILS_URL}" "${binutils_tb}"
  download_file "${LINUX_URL}" "${linux_tb}"
  download_file "${MUSL_URL}" "${musl_tb}"
  download_file "${MUSL_ICONV_PATCH_URL}" "${MUSL_ICONV_PATCH_FILE}"

  echo
  echo "Candidate hashes; verify these against upstream signatures before pinning:"
  sha256sum \
    "${gcc_tb}" \
    "${binutils_tb}" \
    "${linux_tb}" \
    "${musl_tb}" \
    "${MUSL_ICONV_PATCH_FILE}"
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

gcc_zstd_configure_arg() {
  case "${GCC_ZSTD}" in
    auto) echo "" ;;
    yes|system) echo "--with-zstd" ;;
    no) echo "--without-zstd" ;;
    *) echo "--with-zstd=${GCC_ZSTD}" ;;
  esac
}

verify_gpg_key_available() {
  local label="$1"
  local fpr="$2"
  local normalized
  normalized="$(normalize_fpr "${fpr}")"

  if gpg --list-keys "${normalized}" >/dev/null 2>&1; then
    printf '  ok   %-8s %s\n' "${label}" "${normalized}"
  else
    printf '  MISS %-8s %s\n' "${label}" "${normalized}"
    return 1
  fi
}

verify_host() {
  export_basic_env
  validate_settings

  local required=(
    bash
    make
    gcc
    g++
    tar
    xz
    find
    realpath
    awk
    sed
    grep
    sha256sum
    strings
    patch
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
  if [[ "${VERIFY_GPG}" == "1" ]] && ! have_cmd gpg; then
    echo "  MISS gpg (required because VERIFY_GPG=1)"
    missing=1
  fi

  if [[ "${VERIFY_GPG}" == "1" ]] && have_cmd gpg; then
    echo
    echo "==> source-signing keys"
    verify_gpg_key_available "gcc" "${GCC_GPG_PRIMARY_FPR}" || missing=1
    verify_gpg_key_available "binutils" "${BINUTILS_GPG_PRIMARY_FPR}" || missing=1
    verify_gpg_key_available "musl" "${MUSL_GPG_PRIMARY_FPR}" || missing=1
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
  if printf '#include <zlib.h>\nint main(void){return 0;}\n' | gcc -x c - -lz -o /tmp/musl-toolchain-zlib-check.$$ >/dev/null 2>&1; then
    echo "  ok   zlib headers/library"
    rm -f /tmp/musl-toolchain-zlib-check.$$
  else
    echo "  MISS zlib headers/library (needed for --with-system-zlib)"
    missing=1
  fi

  if printf '#include <zstd.h>\nint main(void){return 0;}\n' | gcc -x c - -lzstd -o /tmp/musl-toolchain-zstd-check.$$ >/dev/null 2>&1; then
    echo "  ok   zstd headers/library"
    rm -f /tmp/musl-toolchain-zstd-check.$$
  else
    echo "  WARN zstd headers/library not found; zstd support may be disabled or configure may fail if forced"
  fi

  echo
  echo "==> host summary"
  echo "  TARGET=${TARGET}"
  echo "  PREFIX=${PREFIX}"
  echo "  SYSROOT=${SYSROOT}"
  echo "  ENABLE_DYNAMIC=${ENABLE_DYNAMIC}"
  echo "  INSTALL_RUNTIME_TO_SYSROOT=${INSTALL_RUNTIME_TO_SYSROOT}"
  echo "  FRESH_LOGS=${FRESH_LOGS}"
  echo "  SOURCE_REFRESH=${SOURCE_REFRESH}"
  echo "  VERIFY_GPG=${VERIFY_GPG}"
  echo "  BUILD_TRIPLET=${BUILD_TRIPLET:-$(build_triplet)}"

  echo
  echo "==> musl release check"
  if check_musl_updates; then
    :
  else
    echo "  WARN musl update check failed; continuing because verify-host treats it as advisory"
  fi

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

install_pkg_config_wrapper() {
  local wrapper
  wrapper="${PREFIX}/bin/${TARGET}-pkg-config"

  mkdirp "$(dirname "${wrapper}")"
  cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

sysroot="\${TARGET_PKG_CONFIG_SYSROOT_DIR:-${SYSROOT}}"
pkg_config_bin="\${PKG_CONFIG_BIN:-pkg-config}"

export PKG_CONFIG_SYSROOT_DIR="\${sysroot}"
export PKG_CONFIG_LIBDIR="\${sysroot}/usr/lib/pkgconfig:\${sysroot}/lib/pkgconfig:\${sysroot}/usr/share/pkgconfig"

if [[ -n "\${TARGET_PKG_CONFIG_PATH:-}" ]]; then
  export PKG_CONFIG_PATH="\${TARGET_PKG_CONFIG_PATH}"
else
  unset PKG_CONFIG_PATH
fi

exec "\${pkg_config_bin}" "\$@"
EOF
  chmod 0755 "${wrapper}"
  echo "==> installed pkg-config wrapper: ${wrapper}"
}

write_manifest() {
  export_basic_env
  mkdirp "$(dirname "${MANIFEST_FILE}")"

  local build host loader shared_flags gcc_zstd_arg with_as with_ld
  build="${BUILD_TRIPLET:-$(build_triplet)}"
  host="${HOST_TRIPLET:-${build}}"
  loader="$(musl_loader_name)"
  gcc_zstd_arg="$(gcc_zstd_configure_arg)"
  with_as=""
  with_ld=""
  if [[ -x "${PREFIX}/bin/${TARGET}-as" ]]; then
    with_as="--with-as=${PREFIX}/bin/${TARGET}-as"
  fi
  if [[ -x "${PREFIX}/bin/${TARGET}-ld" ]]; then
    with_ld="--with-ld=${PREFIX}/bin/${TARGET}-ld"
  fi
  shared_flags="--disable-shared"
  if [[ "${ENABLE_DYNAMIC}" == "1" ]]; then
    shared_flags="--enable-shared --enable-static"
  fi

  {
    echo "toolchain_manifest_version=1"
    echo "script_version=${SCRIPT_VERSION}"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "target=${TARGET}"
    echo "build_triplet=${build}"
    echo "host_triplet=${host}"
    echo "prefix=${PREFIX}"
    echo "sysroot=${SYSROOT}"
    echo "gcc_version=${GCC_VER}"
    echo "gcc_tarball=${GCC_TARBALL}"
    echo "gcc_sha256=${GCC_SHA256}"
    echo "binutils_version=${BINUTILS_VER}"
    echo "binutils_tarball=${BINUTILS_TARBALL}"
    echo "binutils_sha256=${BINUTILS_SHA256}"
    echo "linux_version=${LINUX_VER}"
    echo "linux_tarball=${LINUX_TARBALL}"
    echo "linux_sha256=${LINUX_SHA256}"
    echo "musl_version=${MUSL_VER}"
    echo "musl_tarball=${MUSL_TARBALL}"
    echo "musl_sha256=${MUSL_SHA256}"
    echo "musl_patch_commit=${MUSL_ICONV_PATCH_COMMIT}"
    echo "musl_patch_sha256=${MUSL_ICONV_PATCH_SHA256}"
    echo "target_arch_base=${TARGET_ARCH_BASE}"
    echo "target_tune=${TARGET_TUNE}"
    echo "enable_dynamic=${ENABLE_DYNAMIC}"
    echo "install_runtime_to_sysroot=${INSTALL_RUNTIME_TO_SYSROOT}"
    echo "default_hash_style=${DEFAULT_HASH_STYLE}"
    echo "binutils_zstd=${BINUTILS_ZSTD}"
    echo "gcc_zstd=${GCC_ZSTD}"
    echo "gcc_zstd_configure_arg=${gcc_zstd_arg:-omitted-auto}"
    echo "gcc_pkgversion=${GCC_PKGVERSION}"
    echo "gcc_with_as=${with_as:-auto}"
    echo "gcc_with_ld=${with_ld:-auto}"
    echo "musl_loader=${SYSROOT}/lib/${loader}"
    echo "libc_name=musl"
    echo "libc_version=${MUSL_VER}"
    echo "pkg_config_wrapper=${PREFIX}/bin/${TARGET}-pkg-config"
    echo
    echo "[configure.binutils]"
    echo "--build=${build} --host=${host} --target=${TARGET} --prefix=${PREFIX} --with-sysroot=${SYSROOT} --disable-multilib --disable-werror --disable-nls --enable-plugins --enable-lto --enable-ld=default --enable-relro --enable-default-hash-style=${DEFAULT_HASH_STYLE} --with-zstd=${BINUTILS_ZSTD} --with-system-zlib"
    echo
    echo "[configure.gcc.stage1]"
    echo "--build=${build} --host=${host} --target=${TARGET} --prefix=${PREFIX} --with-sysroot=${SYSROOT} --with-build-sysroot=${SYSROOT} --disable-multilib --disable-nls --disable-bootstrap --disable-werror --enable-languages=c --without-headers --with-newlib --disable-shared --disable-threads --disable-libatomic --disable-libgomp --disable-libquadmath --disable-libssp --disable-libvtv --disable-libstdcxx --enable-checking=release --with-system-zlib --with-arch=${TARGET_ARCH_BASE} --with-tune=${TARGET_TUNE} --enable-host-pie --enable-host-bind-now --with-pkgversion='${GCC_PKGVERSION}'"
    echo
    echo "[configure.musl]"
    echo "--target=${TARGET} --prefix=/usr --syslibdir=/lib"
    echo
    echo "[configure.gcc.final]"
    echo "--build=${build} --host=${host} --target=${TARGET} --prefix=${PREFIX} --with-sysroot=${SYSROOT} --with-build-sysroot=${SYSROOT} --with-native-system-header-dir=/usr/include --disable-multilib --disable-nls --disable-bootstrap --disable-werror --enable-languages=c,c++ ${shared_flags} --enable-threads=posix --enable-linker-build-id --enable-plugin --enable-lto --with-system-zlib ${gcc_zstd_arg} --without-included-gettext --enable-checking=release --with-arch=${TARGET_ARCH_BASE} --with-tune=${TARGET_TUNE} --enable-host-pie --enable-host-bind-now --enable-default-pie --enable-default-ssp --with-pkgversion='${GCC_PKGVERSION}' ${with_as} ${with_ld}"
  } > "${MANIFEST_FILE}"

  echo "==> manifest written: ${MANIFEST_FILE}"
}

# ----------------------------- Build: binutils --------------------------------
build_binutils() {
  export_basic_env
  require_host_build_tools
  ensure_binutils_source

  clean_prefix_once
  mkdirp "${BINUTILS_BUILD_DIR}"

  local build host
  build="${BUILD_TRIPLET:-$(build_triplet)}"
  host="${HOST_TRIPLET:-${build}}"

  log_step "configure-binutils" bash -c "
    cd '${BINUTILS_BUILD_DIR}'
    '${BINUTILS_SRC_DIR}/configure' \
      --build='${build}' \
      --host='${host}' \
      --target='${TARGET}' \
      --prefix='${PREFIX}' \
      --with-sysroot='${SYSROOT}' \
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

  local build host
  build="${BUILD_TRIPLET:-$(build_triplet)}"
  host="${HOST_TRIPLET:-${build}}"

  log_step "configure-gcc-stage1" bash -c "
    cd '${gcc_build}'
    '${GCC_SRC_DIR}/configure' \
      --build='${build}' \
      --host='${host}' \
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
      --with-tune='${TARGET_TUNE}' \
      --enable-host-pie \
      --enable-host-bind-now \
      --with-pkgversion='${GCC_PKGVERSION}'
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
      local matches=()
      mapfile -t matches < <(compgen -G "${d}/${p}" || true)
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
  local with_zstd=""
  if [[ -x "${PREFIX}/bin/${TARGET}-as" ]]; then
    with_as="--with-as=${PREFIX}/bin/${TARGET}-as"
  fi
  if [[ -x "${PREFIX}/bin/${TARGET}-ld" ]]; then
    with_ld="--with-ld=${PREFIX}/bin/${TARGET}-ld"
  fi
  with_zstd="$(gcc_zstd_configure_arg)"

  # Dynamic-capable fix:
  # - If ENABLE_DYNAMIC=1, build shared runtimes (libstdc++.so, libgcc_s.so, etc) AND static ones.
  # - If ENABLE_DYNAMIC=0, keep static-only behavior.
  local shared_flags="--disable-shared"
  if [[ "${ENABLE_DYNAMIC}" == "1" ]]; then
    shared_flags="--enable-shared --enable-static"
  fi

  local build host
  build="${BUILD_TRIPLET:-$(build_triplet)}"
  host="${HOST_TRIPLET:-${build}}"

  log_step "configure-gcc-final" bash -c "
    cd '${gcc_build}'
    '${GCC_SRC_DIR}/configure' \
      --build='${build}' \
      --host='${host}' \
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
      ${with_zstd} \
      --without-included-gettext \
      --enable-checking=release \
      --with-arch='${TARGET_ARCH_BASE}' \
      --with-tune='${TARGET_TUNE}' \
      --enable-host-pie \
      --enable-host-bind-now \
      --enable-default-pie \
      --enable-default-ssp \
      --with-pkgversion='${GCC_PKGVERSION}' \
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

  install_pkg_config_wrapper

  echo
  echo "==> GCC final installed to ${PREFIX}"
  echo "==> SYSROOT: ${SYSROOT}"
  echo "==> ENABLE_DYNAMIC=${ENABLE_DYNAMIC} (shared runtimes: $([[ "${ENABLE_DYNAMIC}" == "1" ]] && echo enabled || echo disabled))"
  write_manifest
}

build_all() {
  build_binutils
  install_linux_headers
  build_gcc_stage1
  build_musl
  build_gcc_final
}

install_pkg_config_wrapper_command() {
  validate_settings
  install_pkg_config_wrapper
  write_manifest
}

# ------------------------------ Main ------------------------------------------
usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  verify-host  Check host tools, libraries, GPG/download tools, and settings
  check-updates Check official musl releases and report whether MUSL_VER is current
  fetch-hashes Download source archives and print candidate SHA256 values
  binutils   Download/extract (if needed) + build+install cross binutils into PREFIX
  headers    Download/extract (if needed) + install linux headers into SYSROOT
  stage1     Build+install GCC stage1 (C + libgcc) into PREFIX (no libc)
  musl       Build+install musl into SYSROOT (requires headers + stage1)
  gcc        Build+install final GCC (C,C++) into PREFIX (requires musl)
  build      Build binutils + headers + stage1 + musl + gcc
  pkg-config-wrapper Install/update ${TARGET}-pkg-config in PREFIX/bin
  distclean  Remove workspace build artifacts, sources, tarballs, logs, and build GPG cache; keep PREFIX

Env toggles:
  CLEAN_PREFIX=1               Remove PREFIX before install (dangerous, now only once per run)
  RECONFIGURE=0                Reuse existing build dirs (not recommended)
  FRESH_LOGS=1                 Clear build logs at the start of build commands (default: 1)
  SOURCE_REFRESH=1             Re-extract verified source archives before building (default: 1)
  ENABLE_DYNAMIC=1|0           Build shared+static (1, default) or static-only (0)
  INSTALL_RUNTIME_TO_SYSROOT=1 Copy libstdc++.so/libgcc_s.so/etc into sysroot (default: 1)
  TARGET_ARCH_BASE=            Default arch for GCC (default: armv8-a)
  TARGET_TUNE=                 Default tune for GCC (default: cortex-a72)
  BINUTILS_ZSTD=               zstd support mode for binutils (default: auto)
  GCC_ZSTD=                    GCC zstd mode: auto, yes/system, no, or prefix path (default: auto)
  DEFAULT_HASH_STYLE=          GNU ld default hash style (default: gnu)
  GCC_PKGVERSION=              GCC package identity string (default: ${GCC_PKGVERSION})
  MANIFEST_FILE=               Build manifest output (default: ${MANIFEST_FILE})
  VERIFY_GPG=                  Verify GNU/musl source signatures with trusted GPG keys (default: ${VERIFY_GPG})
  GCC_GPG_PRIMARY_FPR=         Expected GCC signing primary fingerprint
  BINUTILS_GPG_PRIMARY_FPR=    Expected binutils signing primary fingerprint
  MUSL_GPG_PRIMARY_FPR=        Expected musl signing primary fingerprint
  MUSL_RELEASES_URL=           Official musl release index (default: ${MUSL_RELEASES_URL})
  BUILD_TRIPLET=               Override detected build triplet
  HOST_TRIPLET=                Override host triplet for generated tools

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
    verify-host) verify_host ;;
    check-updates) check_musl_updates_command ;;
    fetch-hashes) print_source_hashes ;;
    binutils) validate_settings; reset_logs_for_run; build_binutils ;;
    headers)  validate_settings; reset_logs_for_run; install_linux_headers ;;
    stage1)   validate_settings; reset_logs_for_run; build_gcc_stage1 ;;
    musl)     validate_settings; reset_logs_for_run; build_musl ;;
    gcc)      validate_settings; reset_logs_for_run; build_gcc_final ;;
    build)    validate_settings; reset_logs_for_run; build_all ;;
    pkg-config-wrapper) install_pkg_config_wrapper_command ;;
    distclean) distclean ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
