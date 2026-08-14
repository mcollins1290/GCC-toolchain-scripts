#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# test-musl-cross-toolchain.sh
# Run the following 4 tests and if all pass then toolchain is solid:
#
# 1)
# SYSROOT_LINK_AUDIT=1 A_PLUS=1 LINK_MODE=dynamic ./test-musl-cross-toolchain.sh all
#
# 2)
# LINK_MODE=static SYSROOT_LINK_AUDIT=1 STRESS_CPP=1 STRESS_LTO_MATRIX=1 ./test-musl-cross-toolchain.sh all
#
# 3)
# LINK_MODE=dynamic SYSROOT_LINK_AUDIT=1 STRESS_CPP=1 STRESS_LTO_MATRIX=1 STRESS_DLOPEN_THREADS=1 STRESS_RTLD_COLLISION=1 ./test-musl-cross-toolchain.sh smoke
#
# 4)
# LINK_MODE=dynamic INTEGRATION=1 PI_TLS_SELFCONTAINED=1 PI_NET_TEST=1 ./test-musl-cross-toolchain.sh nightly
#
# ==============================================================================
SCRIPT_VERSION="v0.1.0"

# ------------------------------ Defaults --------------------------------------
TARGET="${TARGET:-aarch64-linux-musl}"
GCC_VER="${GCC_VER:-16.2.0}"
TC_PREFIX="${TC_PREFIX:-/opt/gcc-${GCC_VER}-musl-cross}"
SYSROOT="${SYSROOT:-${TC_PREFIX}/${TARGET}/sysroot}"
TOOLCHAIN_MANIFEST="${TOOLCHAIN_MANIFEST:-${TC_PREFIX}/toolchain-manifest.txt}"

# LINK_MODE:
#   auto    -> detect based on sysroot contents (static-first)
#   dynamic -> build/run dynamic suite (dlopen/DSO tests enabled)
#   static  -> build/run static suite (dlopen/DSO tests skipped)
LINK_MODE="${LINK_MODE:-auto}"

QEMU_AARCH64="${QEMU_AARCH64:-qemu-aarch64}"

PI_SSH="${PI_SSH:-root@raspberrypi2.totten}"
PI_SSH_PORT="${PI_SSH_PORT:-22}"
PI_TMPDIR="${PI_TMPDIR:-/tmp/gcc-toolchain-tests}"

# Optional: Pi sysroot on host (for CA bundle, etc.)
PI_SYSROOT="${PI_SYSROOT:-/build-rpi/rpi/sysroot}"

INTEGRATION="${INTEGRATION:-0}"
INTEGRATION_RUN_ON_PI="${INTEGRATION_RUN_ON_PI:-0}"
PI_INTEGRATION_DIR="${PI_INTEGRATION_DIR:-/tmp/gcc-toolchain-integration}"

PI_NET_TEST="${PI_NET_TEST:-1}"
PI_NET_TEST_URL="${PI_NET_TEST_URL:-https://example.com}"

# When set, we stage a CA bundle into INSTALL_DIR and use it via explicit --cacert
PI_TLS_SELFCONTAINED="${PI_TLS_SELFCONTAINED:-0}"
TLS_CA_BUNDLE="${TLS_CA_BUNDLE:-}"
CA_BUNDLE_URL="${CA_BUNDLE_URL:-https://curl.se/ca/cacert.pem}"

# Stress toggles (rare failure modes)
STRESS_CPP="${STRESS_CPP:-0}"
STRESS_DLOPEN_THREADS="${STRESS_DLOPEN_THREADS:-1}"
STRESS_DLOPEN_THREADS_N="${STRESS_DLOPEN_THREADS_N:-4}"
STRESS_DLOPEN_ITERS="${STRESS_DLOPEN_ITERS:-250}"

STRESS_RTLD_COLLISION="${STRESS_RTLD_COLLISION:-1}"
STRESS_OPENSSL_TLS="${STRESS_OPENSSL_TLS:-1}"

# A+ production validation extras
STRESS_LTO_MATRIX="${STRESS_LTO_MATRIX:-0}"         # build LTO a few ways
STRESS_STRIP_VERIFY="${STRESS_STRIP_VERIFY:-1}"     # ensure strip doesn't break runtime (dynamic only)
STRESS_LIBSTDCPP_ABI="${STRESS_LIBSTDCPP_ABI:-1}"   # small C++ ABI sanity (dynamic+static ok)

ZLIB_VER="${ZLIB_VER:-1.3.2}"
ZLIB_URL="${ZLIB_URL:-https://zlib.net/zlib-${ZLIB_VER}.tar.gz}"
ZLIB_SIG_URL="${ZLIB_SIG_URL:-${ZLIB_URL}.asc}"
ZLIB_SHA256="${ZLIB_SHA256:-bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16}"
ZLIB_GPG_FPR="${ZLIB_GPG_FPR:-5ED46A6721D365587791E2AA783FCD8E58BCAFBA}"

OPENSSL_VER="${OPENSSL_VER:-3.5.7}"
OPENSSL_URL="${OPENSSL_URL:-https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz}"
OPENSSL_SIG_URL="${OPENSSL_SIG_URL:-${OPENSSL_URL}.asc}"
OPENSSL_SHA256="${OPENSSL_SHA256:-a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8}"
OPENSSL_GPG_FPR="${OPENSSL_GPG_FPR:-BA5473A2B0587B07FB27CF2D216094DFD0CB81EF}"

CURL_VER="${CURL_VER:-8.20.0}"
CURL_URL="${CURL_URL:-https://curl.se/download/curl-${CURL_VER}.tar.gz}"
CURL_SIG_URL="${CURL_SIG_URL:-${CURL_URL}.asc}"
CURL_SHA256="${CURL_SHA256:-fc5819cad3f9f5482669adcdc49a782c15f36d2a0715b395b06d9173593d2dc0}"
CURL_GPG_FPR="${CURL_GPG_FPR:-27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2}"

VERIFY_INTEGRATION_DOWNLOADS="${VERIFY_INTEGRATION_DOWNLOADS:-1}"
VERIFY_INTEGRATION_GPG="${VERIFY_INTEGRATION_GPG:-1}"
INTEGRATION_SOURCE_REFRESH="${INTEGRATION_SOURCE_REFRESH:-1}"

CURL_DISABLE_LIBPSL="${CURL_DISABLE_LIBPSL:-1}"
CURL_DISABLE_BROTLI="${CURL_DISABLE_BROTLI:-1}"

# Sanity sysroot purity audit
SYSROOT_LINK_AUDIT="${SYSROOT_LINK_AUDIT:-1}"

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
WORK_DIR="${WORK_DIR:-$(pwd)/.toolchain-test-work}"
LOG_DIR="${LOG_DIR:-$(pwd)/logs-tests}"
CACHE_DIR="${CACHE_DIR:-$(pwd)/.toolchain-test-cache}"
TARBALL_DIR="${TARBALL_DIR:-${CACHE_DIR}/tarballs}"
SRC_DIR="${SRC_DIR:-${CACHE_DIR}/src}"
BUILD_DIR="${BUILD_DIR:-${CACHE_DIR}/build}"
INSTALL_DIR="${INSTALL_DIR:-${CACHE_DIR}/install/${TARGET}}"

KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
KEEP_CACHE="${KEEP_CACHE:-0}"
KEEP_REMOTE="${KEEP_REMOTE:-0}"
FRESH_LOGS="${FRESH_LOGS:-1}"
EXIT_CLEANUP_ENABLED=0
REMOTE_TMPDIR_USED=0
REMOTE_INTEGRATION_USED=0
declare -A RUN_LOGGED_SEEN=()

# ------------------------------ A+ Super Suite Switch --------------------------
A_PLUS="${A_PLUS:-0}"
case "${A_PLUS}" in
  0|1) ;;
  *)
    echo "ERROR: A_PLUS must be 0 or 1" >&2
    exit 2
    ;;
esac
if [[ "${A_PLUS}" == "1" ]]; then
  echo "A_PLUS=1: enabling full integration + stress suite"

  # A+ is inherently dynamic (integration builds shared curl + dlopen stress)
  if [[ "${LINK_MODE}" == "static" ]]; then
    echo "ERROR: A_PLUS=1 is not compatible with LINK_MODE=static (integration/dlopen suite is dynamic)." >&2
    exit 2
  fi

  INTEGRATION=1
  INTEGRATION_RUN_ON_PI=1
  PI_NET_TEST=1
  PI_TLS_SELFCONTAINED=1

  STRESS_CPP=1
  STRESS_DLOPEN_THREADS=1
  STRESS_DLOPEN_THREADS_N="${A_PLUS_DLOPEN_THREADS_N:-6}"
  STRESS_DLOPEN_ITERS="${A_PLUS_DLOPEN_ITERS:-750}"

  STRESS_RTLD_COLLISION=1
  STRESS_OPENSSL_TLS=1

  STRESS_LTO_MATRIX=1
  STRESS_STRIP_VERIFY=1
  STRESS_LIBSTDCPP_ABI=1
fi

# ------------------------------ PASS/FAIL semantics ----------------------------
CURRENT_TIER=""
TIER_STATUS_DIR=""

on_err() {
  local exit_code=$?
  if [[ -n "${CURRENT_TIER}" ]]; then
    echo
    echo ">>> ${CURRENT_TIER}: FAIL (exit=${exit_code})"
    if [[ -n "${TIER_STATUS_DIR}" ]]; then
      echo "FAIL" > "${TIER_STATUS_DIR}/${CURRENT_TIER}.status" 2>/dev/null || true
    fi
  else
    echo
    echo ">>> FAIL (exit=${exit_code})"
  fi
  echo ">>> Last command: ${BASH_COMMAND}"
  echo ">>> Hint: check logs in: ${LOG_DIR}"
  exit "${exit_code}"
}
trap on_err ERR

mark_tier_start() {
  local tier="$1"
  CURRENT_TIER="${tier}"
  mkdir -p "${LOG_DIR}"
  TIER_STATUS_DIR="${LOG_DIR}/.status"
  mkdir -p "${TIER_STATUS_DIR}"
  echo "RUNNING" > "${TIER_STATUS_DIR}/${tier}.status"
}

mark_tier_pass() {
  local tier="$1"
  echo "PASS" > "${TIER_STATUS_DIR}/${tier}.status"
  echo "==> ${tier}: PASS"
  CURRENT_TIER=""
}

tier_summary() {
  local sdir="${LOG_DIR}/.status"
  echo
  echo "==================== Tier Summary ===================="
  for t in report sanity smoke nightly; do
    if [[ -f "${sdir}/${t}.status" ]]; then
      printf "%-8s : %s\n" "${t}" "$(cat "${sdir}/${t}.status")"
    fi
  done
  echo "======================================================"
  write_validation_report
}

musl_version_from_sysroot() {
  local libc
  libc="$(find "${SYSROOT}" -type f -name 'libc.so' -print -quit 2>/dev/null || true)"
  if [[ -n "${libc}" ]]; then
    strings "${libc}" 2>/dev/null | grep -E '^Version [0-9]+([.][0-9]+)+' | head -n 1 || true
  fi
}

manifest_value() {
  local key="$1"
  [[ -f "${TOOLCHAIN_MANIFEST}" ]] || return 1
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; found=1; exit } END { exit !found }' "${TOOLCHAIN_MANIFEST}"
}

write_validation_report() {
  local report="${LOG_DIR}/validation-report.txt"
  local sdir="${LOG_DIR}/.status"
  local musl_version=""
  musl_version="$(manifest_value musl_version 2>/dev/null || musl_version_from_sysroot 2>/dev/null || true)"

  mkdirp "${LOG_DIR}"
  {
    echo "validation_report_version=1"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "script_version=${SCRIPT_VERSION}"
    echo
    echo "[toolchain]"
    echo "target=${TARGET}"
    echo "tc_prefix=${TC_PREFIX}"
    echo "sysroot=${SYSROOT}"
    echo "link_mode=${LINK_MODE}"
    echo "libc_name=musl"
    echo "libc_version=${musl_version}"
    echo "musl_version=${musl_version}"
    if [[ -x "${TC_PREFIX}/bin/${TARGET}-gcc" ]]; then
      echo "gcc_version=$("${TC_PREFIX}/bin/${TARGET}-gcc" -dumpfullversion -dumpversion 2>/dev/null || true)"
      echo "gcc_machine=$("${TC_PREFIX}/bin/${TARGET}-gcc" -dumpmachine 2>/dev/null || true)"
      echo "gcc_configured_sysroot=$("${TC_PREFIX}/bin/${TARGET}-gcc" -print-sysroot 2>/dev/null || true)"
    fi
    if [[ -x "${TC_PREFIX}/bin/${TARGET}-ld" ]]; then
      echo "ld_version=$("${TC_PREFIX}/bin/${TARGET}-ld" --version 2>/dev/null | head -n 1 || true)"
    fi
    echo
    echo "[tiers]"
    for t in report sanity smoke nightly; do
      if [[ -f "${sdir}/${t}.status" ]]; then
        echo "${t}=$(cat "${sdir}/${t}.status")"
      else
        echo "${t}=NOT_RUN"
      fi
    done
    echo
    echo "[validation_toggles]"
    echo "a_plus=${A_PLUS}"
    echo "sysroot_link_audit=${SYSROOT_LINK_AUDIT}"
    echo "integration=${INTEGRATION}"
    echo "integration_run_on_pi=${INTEGRATION_RUN_ON_PI}"
    echo "pi_net_test=${PI_NET_TEST}"
    echo "pi_tls_selfcontained=${PI_TLS_SELFCONTAINED}"
    echo "keep_workdir=${KEEP_WORKDIR}"
    echo "keep_cache=${KEEP_CACHE}"
    echo "keep_remote=${KEEP_REMOTE}"
    echo "verify_integration_downloads=${VERIFY_INTEGRATION_DOWNLOADS}"
    echo "verify_integration_gpg=${VERIFY_INTEGRATION_GPG}"
    echo "integration_source_refresh=${INTEGRATION_SOURCE_REFRESH}"
    echo "stress_cpp=${STRESS_CPP}"
    echo "stress_dlopen_threads=${STRESS_DLOPEN_THREADS}"
    echo "stress_dlopen_threads_n=${STRESS_DLOPEN_THREADS_N}"
    echo "stress_dlopen_iters=${STRESS_DLOPEN_ITERS}"
    echo "stress_rtld_collision=${STRESS_RTLD_COLLISION}"
    echo "stress_openssl_tls=${STRESS_OPENSSL_TLS}"
    echo "stress_lto_matrix=${STRESS_LTO_MATRIX}"
    echo "stress_strip_verify=${STRESS_STRIP_VERIFY}"
    echo "stress_libstdcpp_abi=${STRESS_LIBSTDCPP_ABI}"
    echo
    echo "[target_pi]"
    echo "pi_ssh=${PI_SSH}"
    echo "pi_ssh_port=${PI_SSH_PORT}"
    echo "pi_tmpdir=${PI_TMPDIR}"
    echo "pi_integration_dir=${PI_INTEGRATION_DIR}"
    echo "pi_net_test_url=${PI_NET_TEST_URL}"
    echo
    echo "[logs]"
    echo "log_dir=${LOG_DIR}"
  } > "${report}"

  echo "==> validation report: ${report}"
}

# ------------------------------ Helpers ---------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
mkdirp() { mkdir -p "$@"; }

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

reset_logs_for_run() {
  [[ "${FRESH_LOGS}" == "1" ]] || return 0

  mkdirp "${LOG_DIR}"
  rm -f "${LOG_DIR}"/*.log "${LOG_DIR}/validation-report.txt"
  rm -rf "${LOG_DIR}/.status"
}

validate_settings() {
  local bool_name bool_value

  for bool_name in \
    FRESH_LOGS \
    VERIFY_INTEGRATION_DOWNLOADS \
    VERIFY_INTEGRATION_GPG \
    INTEGRATION_SOURCE_REFRESH \
    INTEGRATION \
    INTEGRATION_RUN_ON_PI \
    PI_NET_TEST \
    PI_TLS_SELFCONTAINED \
    CURL_DISABLE_LIBPSL \
    CURL_DISABLE_BROTLI \
    SYSROOT_LINK_AUDIT \
    KEEP_WORKDIR \
    KEEP_CACHE \
    STRESS_CPP \
    STRESS_DLOPEN_THREADS \
    STRESS_RTLD_COLLISION \
    STRESS_OPENSSL_TLS \
    STRESS_LTO_MATRIX \
    STRESS_STRIP_VERIFY \
    STRESS_LIBSTDCPP_ABI
  do
    bool_value="${!bool_name}"
    case "${bool_value}" in
      0|1) ;;
      *) die "${bool_name} must be 0 or 1" ;;
    esac
  done

  case "${LINK_MODE}" in
    auto|static|dynamic) ;;
    *) die "LINK_MODE must be auto, static, or dynamic" ;;
  esac
  case "${FRESH_LOGS}" in
    0|1) ;;
    *) die "FRESH_LOGS must be 0 or 1" ;;
  esac

  [[ "${STRESS_DLOPEN_THREADS_N}" =~ ^[1-9][0-9]*$ ]] || die "STRESS_DLOPEN_THREADS_N must be a positive integer"
  [[ "${STRESS_DLOPEN_ITERS}" =~ ^[1-9][0-9]*$ ]] || die "STRESS_DLOPEN_ITERS must be a positive integer"
}

cleanup_remove_path() {
  local label="$1"
  local path="$2"
  local path_abs root_abs prefix_abs sysroot_abs

  [[ -n "${path}" ]] || die "cleanup ${label} path must not be empty"
  have_cmd realpath || die "clean/distclean requires realpath"

  path_abs="$(realpath -m "${path}")"
  root_abs="$(realpath -m "$(pwd)")"
  prefix_abs="$(realpath -m "${TC_PREFIX}")"
  sysroot_abs="$(realpath -m "${SYSROOT}")"

  [[ "${path_abs}" != "/" ]] || die "refusing to clean ${label}: resolved to /"
  [[ "${path_abs}" != "${root_abs}" ]] || die "refusing to clean ${label}: resolved to current directory (${root_abs})"

  case "${path_abs}" in
    "${root_abs}"/*) ;;
    *) die "refusing to clean ${label}: ${path_abs} is outside current directory (${root_abs})" ;;
  esac

  case "${path_abs}" in
    "${prefix_abs}"|"${prefix_abs}"/*)
      die "refusing to clean ${label}: ${path_abs} is inside TC_PREFIX (${prefix_abs})"
      ;;
  esac
  case "${prefix_abs}" in
    "${path_abs}"/*)
      die "refusing to clean ${label}: ${path_abs} contains TC_PREFIX (${prefix_abs})"
      ;;
  esac
  case "${path_abs}" in
    "${sysroot_abs}"|"${sysroot_abs}"/*)
      die "refusing to clean ${label}: ${path_abs} is inside SYSROOT (${sysroot_abs})"
      ;;
  esac
  case "${sysroot_abs}" in
    "${path_abs}"/*)
      die "refusing to clean ${label}: ${path_abs} contains SYSROOT (${sysroot_abs})"
      ;;
  esac

  if [[ -e "${path_abs}" ]]; then
    log "clean: removing ${label}: ${path_abs}"
    rm -rf -- "${path_abs}"
  else
    log "clean: already clean ${label}: ${path_abs}"
  fi
}

clean_test_artifacts() {
  log "clean: preserving installed toolchain TC_PREFIX: ${TC_PREFIX}"
  log "clean: preserving SYSROOT under TC_PREFIX: ${SYSROOT}"

  cleanup_remove_path "test work directory" "${WORK_DIR}"
  cleanup_remove_path "test log directory" "${LOG_DIR}"
}

distclean_test_artifacts() {
  clean_test_artifacts

  cleanup_remove_path "integration tarball directory" "${TARBALL_DIR}"
  cleanup_remove_path "integration source directory" "${SRC_DIR}"
  cleanup_remove_path "integration build directory" "${BUILD_DIR}"
  cleanup_remove_path "integration install directory" "${INSTALL_DIR}"
  cleanup_remove_path "test cache directory" "${CACHE_DIR}"
}

check_remote_artifact_path() {
  local path="$2"

  [[ -n "${path}" ]] || return 1
  [[ "${path}" == /* ]] || return 1
  [[ "${path}" != "/" ]] || return 1

  case "${path}" in
    *"'"*|*$'\n'*|*$'\r'*)
      return 1
      ;;
  esac

  case "${path}" in
    /tmp/*|/var/tmp/*) ;;
    *) return 1 ;;
  esac
}

validate_remote_artifact_path() {
  local label="$1"
  local path="$2"

  if ! check_remote_artifact_path "${label}" "${path}"; then
    die "${label} must be an absolute /tmp or /var/tmp child path without quotes/newlines: ${path}"
  fi
}

remote_reset_dir() {
  local label="$1"
  local path="$2"

  validate_remote_artifact_path "${label}" "${path}"
  ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
    set -e
    rm -rf -- '${path}'
    mkdir -p '${path}'
  "
}

remote_cleanup_dir() {
  local label="$1"
  local path="$2"

  [[ "${KEEP_REMOTE}" == "0" ]] || return 0
  have_cmd ssh || return 0

  if ! check_remote_artifact_path "${label}" "${path}"; then
    echo "WARNING: skipping unsafe remote cleanup for ${label}: ${path}" >&2
    return 0
  fi

  log "remote-clean: removing ${label}: ${PI_SSH}:${path}"
  ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "rm -rf -- '${path}'" >/dev/null 2>&1 || \
    echo "WARNING: remote cleanup failed for ${label}: ${PI_SSH}:${path}" >&2
}

run_logged() {
  local name="$1"; shift
  local logf="${LOG_DIR}/${name}.log"
  mkdirp "${LOG_DIR}"
  if [[ "${FRESH_LOGS}" == "1" && -z "${RUN_LOGGED_SEEN[${name}]+x}" ]]; then
    rm -f -- "${logf}"
    RUN_LOGGED_SEEN["${name}"]=1
  fi
  log "${name}"
  echo "    log: ${logf}"
  ( "$@" ) > >(tee -a "${logf}") 2> >(tee -a "${logf}" 1>&2)
}

cleanup() {
  [[ "${EXIT_CLEANUP_ENABLED}" == "1" ]] || return 0

  if [[ "${REMOTE_INTEGRATION_USED}" == "1" ]]; then
    remote_cleanup_dir "Pi integration directory" "${PI_INTEGRATION_DIR}"
  fi
  if [[ "${REMOTE_TMPDIR_USED}" == "1" ]]; then
    remote_cleanup_dir "Pi test directory" "${PI_TMPDIR}"
  fi

  if [[ "${KEEP_WORKDIR}" == "1" ]]; then
    log "KEEP_WORKDIR=1 leaving work dir: ${WORK_DIR}"
  else
    rm -rf "${WORK_DIR}" >/dev/null 2>&1 || true
  fi

  if [[ "${KEEP_CACHE}" == "0" ]]; then
    rm -rf "${CACHE_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

tc() {
  local tool="$1"
  shift
  "${TC_PREFIX}/bin/${TARGET}-${tool}" "$@"
}

detect_link_mode() {
  case "${LINK_MODE}" in
    static|dynamic) return 0 ;;
    auto)
      # prefer static if libc.a exists
      if [[ -f "${SYSROOT}/lib/libc.a" || -f "${SYSROOT}/usr/lib/libc.a" ]]; then
        LINK_MODE="static"
        return 0
      fi
      if [[ -e "${SYSROOT}/lib/ld-musl-aarch64.so.1" || -e "${SYSROOT}/lib/ld-linux-aarch64.so.1" ]]; then
        LINK_MODE="dynamic"
        return 0
      fi
      die "LINK_MODE=auto but could not detect: no libc.a in ${SYSROOT}/{lib,usr/lib} and no loader in ${SYSROOT}/lib."
      ;;
    *) die "Invalid LINK_MODE='${LINK_MODE}'. Use: auto|dynamic|static" ;;
  esac
}

need_paths() {
  [[ -x "${TC_PREFIX}/bin/${TARGET}-gcc" ]] || die "missing compiler: ${TC_PREFIX}/bin/${TARGET}-gcc"
  [[ -x "${TC_PREFIX}/bin/${TARGET}-g++" ]] || die "missing compiler: ${TC_PREFIX}/bin/${TARGET}-g++"
  [[ -x "${TC_PREFIX}/bin/${TARGET}-ar"  ]] || die "missing: ${TC_PREFIX}/bin/${TARGET}-ar"
  [[ -x "${TC_PREFIX}/bin/${TARGET}-ranlib"  ]] || die "missing: ${TC_PREFIX}/bin/${TARGET}-ranlib"
  [[ -x "${TC_PREFIX}/bin/${TARGET}-pkg-config" ]] || die "missing pkg-config wrapper: ${TC_PREFIX}/bin/${TARGET}-pkg-config"
  [[ -d "${SYSROOT}/usr/include" ]] || die "missing sysroot headers: ${SYSROOT}/usr/include"

  detect_link_mode

  if [[ "${LINK_MODE}" == "dynamic" ]]; then
    if [[ ! -e "${SYSROOT}/lib/ld-musl-aarch64.so.1" && ! -e "${SYSROOT}/lib/ld-linux-aarch64.so.1" ]]; then
      die "LINK_MODE=dynamic but no dynamic loader found in ${SYSROOT}/lib (expected ld-musl-aarch64.so.1 or ld-linux-aarch64.so.1)"
    fi
  else
    if [[ ! -f "${SYSROOT}/lib/libc.a" && ! -f "${SYSROOT}/usr/lib/libc.a" ]]; then
      die "LINK_MODE=static but no libc.a found in ${SYSROOT}/{lib,usr/lib}"
    fi
  fi
}

need_qemu() {
  have_cmd "${QEMU_AARCH64}" || die "missing ${QEMU_AARCH64}. Install qemu-user (Debian: apt install qemu-user)"
}

qemu_run() {
  detect_link_mode
  if [[ "${LINK_MODE}" == "dynamic" ]]; then
    "${QEMU_AARCH64}" -L "${SYSROOT}" "$@"
  else
    "${QEMU_AARCH64}" "$@"
  fi
}

download() {
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

download_try() {
  # download_try <out> <url1> [url2 ...]
  local out="$1"; shift
  mkdirp "$(dirname "$out")"
  if [[ -f "$out" ]]; then
    echo "==> download: already present: $out"
    return 0
  fi

  local u
  for u in "$@"; do
    echo "==> download_try: $u"
    if have_cmd curl; then
      if curl -L --fail -o "$out" "$u"; then
        return 0
      fi
    elif have_cmd wget; then
      if wget -O "$out" "$u"; then
        return 0
      fi
    else
      die "need curl or wget to download: $u"
    fi
    rm -f "$out" >/dev/null 2>&1 || true
  done

  die "all download attempts failed for: $out"
}

verify_sha256() {
  local file="$1"
  local expect="$2"

  [[ "${VERIFY_INTEGRATION_DOWNLOADS}" == "1" ]] || return 0
  [[ -n "${expect}" ]] || die "missing SHA256 for $(basename "${file}"). Set the matching *_SHA256 or VERIFY_INTEGRATION_DOWNLOADS=0."
  have_cmd sha256sum || die "sha256sum not found"

  local got
  got="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${got}" == "${expect}" ]] || die "SHA256 mismatch for ${file}: got ${got}, expected ${expect}"
  echo "==> sha256 ok: $(basename "${file}")"
}

normalize_fpr() {
  tr '[:lower:]' '[:upper:]' <<< "${1//[[:space:]]/}"
}

verify_gpg_signature() {
  local file="$1"
  local sig_url="$2"
  local expected_fpr="$3"
  local sig="${file}.asc"

  [[ "${VERIFY_INTEGRATION_GPG}" == "1" ]] || return 0
  have_cmd gpg || die "VERIFY_INTEGRATION_GPG=1 requires gpg"
  [[ -n "${expected_fpr}" ]] || die "missing expected GPG fingerprint for $(basename "${file}")"

  local expected status gpg_status
  expected="$(normalize_fpr "${expected_fpr}")"
  download "${sig_url}" "${sig}"
  gpg_status=0
  status="$(gpg --status-fd 1 --verify "${sig}" "${file}" 2>&1)" || gpg_status=$?
  printf '%s\n' "${status}"

  [[ "${gpg_status}" == "0" ]] || die "GPG verification failed for $(basename "${file}")"

  if ! awk -v expect="${expected}" '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
      if (toupper($3) == expect || toupper($NF) == expect) ok = 1
    }
    END { exit ok ? 0 : 1 }
  ' <<< "${status}"; then
    die "GPG signature for $(basename "${file}") was not made by expected key ${expected}"
  fi

  echo "==> gpg signature ok: $(basename "${file}") (expected key ${expected})"
}

integration_source_needs_extract() {
  local src="$1"
  local marker="$2"

  [[ "${INTEGRATION_SOURCE_REFRESH}" == "1" ]] && return 0
  [[ -d "${src}" && -f "${src}/${marker}" ]] && return 1
  return 0
}

extract() {
  local tarball="$1"
  local dest="$2"
  mkdirp "$(dirname "$dest")"
  rm -rf "$dest"
  local tmp
  tmp="$(mktemp -d)"
  tar --no-same-owner -xf "$tarball" -C "$tmp"
  local top
  top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  [[ -n "$top" ]] || die "extract failed: no top-level dir in $tarball"
  mv "$top" "$dest"
  rm -rf "$tmp"
}

inspect_elf() {
  local bin="$1"
  run_logged "inspect-$(basename "$bin")" bash -c "
    set -e
    echo '--- file ---'
    file '$bin'
    echo
    echo '--- interpreter ---'
    readelf -l '$bin' | grep -E 'Requesting program interpreter' || true
    echo
    echo '--- NEEDED ---'
    readelf -d '$bin' | grep -E 'NEEDED' || true
  "
}

assert_static_elf_clean() {
  detect_link_mode
  [[ "${LINK_MODE}" == "static" ]] || return 0

  local bin="$1"
  have_cmd readelf || die "missing readelf"

  if readelf -l "${bin}" 2>/dev/null | grep -E 'INTERP|Requesting program interpreter' >/dev/null 2>&1; then
    echo
    echo ">>> STATIC ASSERT FAIL: interpreter present in: ${bin}"
    echo ">>> readelf -l (INTERP excerpt):"
    readelf -l "${bin}" | grep -E 'INTERP|Requesting program interpreter' || true
    echo
    die "LINK_MODE=static requires no ELF interpreter (PT_INTERP)."
  fi

  if readelf -d "${bin}" 2>/dev/null | grep -E 'NEEDED' >/dev/null 2>&1; then
    echo
    echo ">>> STATIC ASSERT FAIL: DT_NEEDED entries present in: ${bin}"
    echo ">>> readelf -d (NEEDED excerpt):"
    readelf -d "${bin}" | grep -E 'NEEDED' || true
    echo
    die "LINK_MODE=static requires zero DT_NEEDED entries."
  fi
}

# ------------------------------ Sysroot Link Audit -----------------------------
sysroot_link_audit() {
  [[ "${SYSROOT_LINK_AUDIT}" == "1" ]] || { log "SYSROOT_LINK_AUDIT=0: skipping"; return 0; }

  have_cmd grep || die "missing grep"
  have_cmd readelf || die "missing readelf"

  detect_link_mode

  mkdirp "${WORK_DIR}/src" "${WORK_DIR}/bin"

  cat > "${WORK_DIR}/src/link_audit.c" <<'EOF'
#include <stdio.h>
int main(){ puts("link-audit"); return 0; }
EOF

  local sys=(--sysroot="${SYSROOT}")
  local cflags=(-O2)
  local ldflags=()

  if [[ "${LINK_MODE}" == "static" ]]; then
    ldflags+=(-static)
  fi

  run_logged "sanity-link-audit" tc gcc "${sys[@]}" "${cflags[@]}" \
    -Wl,-t "${WORK_DIR}/src/link_audit.c" -o "${WORK_DIR}/bin/link_audit" "${ldflags[@]}"

  local logf="${LOG_DIR}/sanity-link-audit.log"
  [[ -f "${logf}" ]] || die "missing link audit log: ${logf}"

  local bad_re='/(usr/)?lib(64)?/x86_64-linux-gnu/|/lib/x86_64-linux-gnu/|/usr/lib64/|ld-linux-x86-64\.so'
  if grep -E "${bad_re}" -n "${logf}" >/dev/null 2>&1; then
    echo
    echo ">>> sysroot link audit: FAIL (host x86_64 linkage detected)"
    echo ">>> offending lines:"
    grep -E "${bad_re}" -n "${logf}" | head -n 80
    echo
    die "sysroot purity violated: linker opened host x86_64 files (see ${logf})."
  fi

  if [[ "${LINK_MODE}" == "static" ]]; then
    assert_static_elf_clean "${WORK_DIR}/bin/link_audit"
  fi

  run_logged "sanity-link-audit-inspect" bash -c "
    set -e
    file '${WORK_DIR}/bin/link_audit'
    readelf -l '${WORK_DIR}/bin/link_audit' | grep -E 'Requesting program interpreter' || true
    readelf -d '${WORK_DIR}/bin/link_audit' | grep -E 'NEEDED' || true
  "
}

assert_pkg_config_wrapper() {
  have_cmd pkg-config || die "missing host pkg-config"

  local wrapper="${TC_PREFIX}/bin/${TARGET}-pkg-config"
  local pcroot="${WORK_DIR}/pkg-config-sysroot"
  local usr_pc="${pcroot}/usr/lib/pkgconfig"
  local lib_pc="${pcroot}/lib/pkgconfig"
  local share_pc="${pcroot}/usr/share/pkgconfig"
  local overlay_pc="${WORK_DIR}/pkg-config-overlay"
  local host_pc="${WORK_DIR}/pkg-config-host"

  mkdirp "${usr_pc}" "${lib_pc}" "${share_pc}" "${overlay_pc}" "${host_pc}"

  cat > "${usr_pc}/wrapper-usr.pc" <<'EOF'
prefix=/usr
includedir=${prefix}/include/wrapper-usr
libdir=${prefix}/lib

Name: wrapper-usr
Description: musl usr pkg-config wrapper probe
Version: 1.0
Cflags: -I${includedir}
Libs: -L${libdir} -lwrapper-usr
EOF

  cat > "${lib_pc}/wrapper-lib.pc" <<'EOF'
prefix=
includedir=/include/wrapper-lib
libdir=/lib

Name: wrapper-lib
Description: musl root lib pkg-config wrapper probe
Version: 1.0
Cflags: -I${includedir}
Libs: -L${libdir} -lwrapper-lib
EOF

  cat > "${share_pc}/wrapper-share.pc" <<'EOF'
prefix=/usr
includedir=${prefix}/include/wrapper-share

Name: wrapper-share
Description: musl share pkg-config wrapper probe
Version: 1.0
Cflags: -I${includedir}
Libs:
EOF

  cat > "${overlay_pc}/wrapper-overlay.pc" <<'EOF'
prefix=/opt/wrapper-overlay
includedir=${prefix}/include

Name: wrapper-overlay
Description: explicit target overlay pkg-config wrapper probe
Version: 1.0
Cflags: -I${includedir}
Libs:
EOF

  cat > "${host_pc}/wrapper-host-leak.pc" <<'EOF'
prefix=/usr
includedir=${prefix}/include/host-leak

Name: wrapper-host-leak
Description: inherited host PKG_CONFIG_PATH leak probe
Version: 1.0
Cflags: -I${includedir}
Libs:
EOF

  run_logged "pkg-config-wrapper" env \
    PKG_CONFIG_PATH="${host_pc}" \
    PKG_CONFIG_SYSROOT_DIR="/host-leak-sysroot" \
    PKG_CONFIG_LIBDIR="/host/leak/pkgconfig" \
    TARGET_PKG_CONFIG_SYSROOT_DIR="${pcroot}" \
    TARGET_PKG_CONFIG_PATH= \
    "${wrapper}" \
    --cflags --libs wrapper-usr wrapper-lib wrapper-share

  local logf="${LOG_DIR}/pkg-config-wrapper.log"
  [[ -f "${logf}" ]] || die "missing pkg-config wrapper log: ${logf}"
  grep -F -- "-I${pcroot}/usr/include/wrapper-usr" "${logf}" >/dev/null \
    || die "pkg-config wrapper did not sysroot usr Cflags"
  grep -F -- "-L${pcroot}/usr/lib" "${logf}" >/dev/null \
    || die "pkg-config wrapper did not sysroot usr Libs"
  grep -F -- "-I${pcroot}/include/wrapper-lib" "${logf}" >/dev/null \
    || die "pkg-config wrapper did not search root lib pkgconfig dir"
  grep -F -- "-L${pcroot}/lib" "${logf}" >/dev/null \
    || die "pkg-config wrapper did not sysroot root lib Libs"
  grep -F -- "-I${pcroot}/usr/include/wrapper-share" "${logf}" >/dev/null \
    || die "pkg-config wrapper did not search usr/share pkgconfig dir"

  if env PKG_CONFIG_PATH="${host_pc}" TARGET_PKG_CONFIG_SYSROOT_DIR="${pcroot}" TARGET_PKG_CONFIG_PATH= "${wrapper}" --exists wrapper-host-leak; then
    die "pkg-config wrapper leaked inherited host PKG_CONFIG_PATH"
  fi

  run_logged "pkg-config-wrapper-overlay" env \
    TARGET_PKG_CONFIG_SYSROOT_DIR="${pcroot}" \
    TARGET_PKG_CONFIG_PATH="${overlay_pc}" \
    "${wrapper}" --cflags wrapper-overlay
  grep -F -- "-I${pcroot}/opt/wrapper-overlay/include" "${LOG_DIR}/pkg-config-wrapper-overlay.log" >/dev/null \
    || die "pkg-config wrapper did not honor TARGET_PKG_CONFIG_PATH"
}

# ------------------------------ Pi musl runtime staging ------------------------
copy_first_found() {
# copy_first_found <destdir> <name1> [name2 ...]
  if (( $# < 2 )); then
    echo "ERROR: copy_first_found: expected <destdir> <name...>, got $# args" >&2
    return 2
  fi

  local destdir="$1"; shift
  mkdirp "${destdir}"

  local name path
  for name in "$@"; do
    path="$(find -L "${SYSROOT}" -type f -name "${name}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${path}" ]]; then
      cp -aL "${path}" "${destdir}/"
      return 0
    fi
  done
  return 1
}

stage_pi_musl_runtime_tree() {
  detect_link_mode
  [[ "${LINK_MODE}" == "dynamic" ]] || return 0

  local rt="${WORK_DIR}/pi-rt"
  rm -rf "${rt}"
  mkdirp "${rt}/lib" "${rt}/usr/lib" "${rt}/etc/ssl/certs"

  if [[ ! -e "${SYSROOT}/lib/ld-musl-aarch64.so.1" ]]; then
    die "LINK_MODE=dynamic: missing sysroot loader: ${SYSROOT}/lib/ld-musl-aarch64.so.1"
  fi
  cp -aL "${SYSROOT}/lib/ld-musl-aarch64.so.1" "${rt}/lib/ld-musl-aarch64.so.1"

  shopt -s nullglob
  local musl_usr=( "${SYSROOT}/usr/lib/"lib*.so* "${SYSROOT}/usr/lib64/"lib*.so* )
  local musl_lib=( "${SYSROOT}/lib/"lib*.so* "${SYSROOT}/lib64/"lib*.so* )
  shopt -u nullglob

  if (( ${#musl_lib[@]} > 0 )); then
    cp -aL "${musl_lib[@]}" "${rt}/lib/" || true
  fi
  if (( ${#musl_usr[@]} > 0 )); then
    cp -aL "${musl_usr[@]}" "${rt}/usr/lib/" || true
  fi

  copy_first_found "${rt}/usr/lib" "libc.so" || die "could not find libc.so anywhere under SYSROOT=${SYSROOT}"
  copy_first_found "${rt}/usr/lib" "libgcc_s.so.1" || die "could not find libgcc_s.so.1 anywhere under SYSROOT=${SYSROOT}"
  copy_first_found "${rt}/usr/lib" "libstdc++.so.6" || die "could not find libstdc++.so.6 anywhere under SYSROOT=${SYSROOT}"

  copy_first_found "${rt}/usr/lib" \
    "libatomic.so.1" \
    "libgomp.so.1" \
    "libquadmath.so.0" \
    "libasan.so.8" \
    "libubsan.so.1" \
    "liblsan.so.0" \
    "libtsan.so.2" \
    "libssp.so.0" || true

  if [[ "${PI_TLS_SELFCONTAINED}" == "1" ]]; then
    local ca_src=""
    if ca_src="$(find_tls_ca_bundle)"; then
      cp -aL "${ca_src}" "${rt}/etc/ssl/certs/ca-certificates.crt"
    else
      echo "WARNING: PI_TLS_SELFCONTAINED=1 but no valid CA bundle found in TLS_CA_BUNDLE, SYSROOT, PI_SYSROOT, or host trust paths" >&2
    fi
  fi

  {
    echo "staged_from_sysroot=${SYSROOT}"
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "--- rt/lib ---"
    (cd "${rt}/lib" && ls -la) || true
    echo "--- rt/usr/lib (head) ---"
    # shellcheck disable=SC2012
    (cd "${rt}/usr/lib" && ls -la | head -n 120) || true
  } > "${rt}/MANIFEST.txt"

  run_logged "pi-stage-runtime-tree" bash -c "
    set -e
    echo 'pi-rt=${rt}'
    file '${rt}/lib/ld-musl-aarch64.so.1' || true
    echo 'required dsos:'
    ls -la '${rt}/usr/lib/libc.so' '${rt}/usr/lib/libgcc_s.so.1' '${rt}/usr/lib/libstdc++.so.6'
    if [[ -f '${rt}/etc/ssl/certs/ca-certificates.crt' ]]; then
      echo 'ca-bundle-staged: yes'
      wc -c '${rt}/etc/ssl/certs/ca-certificates.crt' | awk '{print \$1, \$2}'
    else
      echo 'ca-bundle-staged: no'
    fi
  "
}

pack_pi_runtime_tarball() {
  detect_link_mode
  [[ "${LINK_MODE}" == "dynamic" ]] || return 0

  have_cmd tar || die "missing tar"
  local rt="${WORK_DIR}/pi-rt"
  [[ -d "${rt}" ]] || die "pi runtime tree missing: ${rt} (stage_pi_musl_runtime_tree did not run?)"

  run_logged "pi-pack-runtime-tar" bash -c "
    set -e
    cd '${WORK_DIR}'
    rm -f 'pi-rt.tgz'
    tar -czf 'pi-rt.tgz' 'pi-rt'
    ls -la 'pi-rt.tgz'
  "
}

# ------------------------------ Test Programs --------------------------------
write_sources() {
  mkdirp "${WORK_DIR}/src" "${WORK_DIR}/bin" "${WORK_DIR}/lib"

  cat > "${WORK_DIR}/src/hello.c" <<'EOF'
#include <stdio.h>
int main(){ puts("hello-c"); return 0; }
EOF

  cat > "${WORK_DIR}/src/hello.cpp" <<'EOF'
#include <iostream>
int main(){ std::cout << "hello-cpp\n"; return 0; }
EOF

  cat > "${WORK_DIR}/src/pthread.c" <<'EOF'
#include <pthread.h>
#include <stdio.h>
static void* f(void* p){ (void)p; return (void*)42; }
int main(){
  pthread_t t; void* r=0;
  if(pthread_create(&t,0,f,0)) return 2;
  pthread_join(t,&r);
  printf("pthread ok %ld\n",(long)r);
  return 0;
}
EOF

  cat > "${WORK_DIR}/src/except.cpp" <<'EOF'
#include <iostream>
#include <stdexcept>
int main(){
  try { throw std::runtime_error("boom"); }
  catch(const std::exception& e){ std::cout << "caught: " << e.what() << "\n"; }
  return 0;
}
EOF

  cat > "${WORK_DIR}/src/atomics.c" <<'EOF'
#include <stdatomic.h>
#include <stdio.h>
int main(){
  atomic_int x = 0;
  atomic_fetch_add(&x, 41);
  atomic_fetch_add(&x, 1);
  printf("atomics %d\n", atomic_load(&x));
  return 0;
}
EOF

  cat > "${WORK_DIR}/src/dlopen.c" <<'EOF'
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <stdio.h>
int main(){
  void* h = dlopen("libm.so", RTLD_LAZY);
  if(!h){ puts(dlerror()); return 2; }
  dlclose(h);
  puts("dlopen ok");
  return 0;
}
EOF

  cat > "${WORK_DIR}/src/lto1.c" <<'EOF'
int add(int a,int b){return a+b;}
EOF
  cat > "${WORK_DIR}/src/lto2.c" <<'EOF'
#include <stdio.h>
int add(int,int);
int main(){ printf("lto %d\n", add(2,3)); return 0; }
EOF

  cat > "${WORK_DIR}/src/throwlib.cpp" <<'EOF'
#include <stdexcept>
extern "C" void throw_from_dso() {
  throw std::runtime_error("dso-boom");
}
EOF

  cat > "${WORK_DIR}/src/dso_catch.cpp" <<'EOF'
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <iostream>
#include <stdexcept>

using fn_t = void (*)();

int main() {
  void* h = dlopen("./libthrow.so", RTLD_NOW);
  if (!h) {
    std::cerr << "dlopen failed: " << dlerror() << "\n";
    return 2;
  }

  dlerror();
  auto sym = dlsym(h, "throw_from_dso");
  const char* e = dlerror();
  if (e) {
    std::cerr << "dlsym failed: " << e << "\n";
    return 3;
  }

  try {
    reinterpret_cast<fn_t>(sym)();
    std::cerr << "ERROR: did not throw\n";
    return 4;
  } catch (const std::exception& ex) {
    std::cout << "caught-from-dso: " << ex.what() << "\n";
  }

  dlclose(h);
  return 0;
}
EOF

  cat > "${WORK_DIR}/src/dlopen_threads.cpp" <<'EOF'
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static int g_iters = 200;

static void* worker(void* arg){
  const char* so = (const char*)arg;
  for(int i=0;i<g_iters;i++){
    void* h = dlopen(so, RTLD_NOW);
    if(!h){
      const char* e = dlerror();
      fprintf(stderr, "dlopen fail: %s\n", e ? e : "(null)");
      return (void*)1;
    }
    dlerror();
    void* sym = dlsym(h, "throw_from_dso");
    (void)sym;
    dlclose(h);
  }
  return 0;
}

int main(int argc, char** argv){
  int threads = 4;
  const char* so = "./libthrow.so";
  if(argc > 1) threads = atoi(argv[1]);
  if(argc > 2) g_iters = atoi(argv[2]);
  if(argc > 3) so = argv[3];

  if(threads < 1) threads = 1;
  if(g_iters < 1) g_iters = 1;

  pthread_t* ts = (pthread_t*)calloc((size_t)threads, sizeof(pthread_t));
  if(!ts){ perror("calloc"); return 2; }

  for(int i=0;i<threads;i++){
    if(pthread_create(&ts[i], 0, worker, (void*)so)){
      fprintf(stderr, "pthread_create failed\n");
      return 3;
    }
  }
  int bad = 0;
  for(int i=0;i<threads;i++){
    void* r = 0;
    pthread_join(ts[i], &r);
    if(r) bad = 1;
  }
  free(ts);

  if(bad){
    fprintf(stderr, "dlopen-thread-stress: FAIL\n");
    return 5;
  }
  printf("dlopen-thread-stress: ok threads=%d iters=%d so=%s\n", threads, g_iters, so);
  return 0;
}
EOF

  cat > "${WORK_DIR}/src/sym_a.c" <<'EOF'
int magic(){ return 111; }
EOF
  cat > "${WORK_DIR}/src/sym_b.c" <<'EOF'
int magic(){ return 222; }
EOF
  cat > "${WORK_DIR}/src/rtld_collision.c" <<'EOF'
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <stdio.h>

typedef int (*fn_t)();

int main(){
  void* a = dlopen("./libsym_a.so", RTLD_NOW | RTLD_GLOBAL);
  if(!a){ fprintf(stderr, "dlopen A: %s\n", dlerror()); return 2; }

  void* b = dlopen("./libsym_b.so", RTLD_NOW | RTLD_LOCAL);
  if(!b){ fprintf(stderr, "dlopen B: %s\n", dlerror()); return 3; }

  dlerror();
  fn_t f_def = (fn_t)dlsym(RTLD_DEFAULT, "magic");
  const char* e1 = dlerror();
  if(e1){ fprintf(stderr, "dlsym default: %s\n", e1); return 4; }

  dlerror();
  fn_t f_b = (fn_t)dlsym(b, "magic");
  const char* e2 = dlerror();
  if(e2){ fprintf(stderr, "dlsym b: %s\n", e2); return 5; }

  int v_def = f_def ? f_def() : -1;
  int v_b   = f_b   ? f_b()   : -1;

  printf("rtld-collision: default=%d b=%d\n", v_def, v_b);

  if(v_def != 111 || v_b != 222){
    fprintf(stderr, "rtld-collision: FAIL expected default=111 and b=222\n");
    return 6;
  }

  dlclose(b);
  dlclose(a);
  printf("rtld-collision: ok\n");
  return 0;
}
EOF

  cat > "${WORK_DIR}/src/abi_string.cpp" <<'EOF'
#include <iostream>
#include <string>
#include <vector>
#include <numeric>

static std::string make() {
  std::vector<int> v(1000);
  std::iota(v.begin(), v.end(), 1);
  long long s = std::accumulate(v.begin(), v.end(), 0LL);
  return std::string("abi-string-ok:") + std::to_string(s);
}

int main(){
  std::cout << make() << "\n";
  return 0;
}
EOF
}

build_binaries() {
  detect_link_mode

  local cflags=(-O2)
  local sys=(--sysroot="${SYSROOT}")

  local ldflags=()
  local cxx_ldflags=()
  local origin_rpath
  # shellcheck disable=SC2016
  origin_rpath='$ORIGIN/../lib'
  if [[ "${LINK_MODE}" == "static" ]]; then
    ldflags+=(-static)
    cxx_ldflags+=(-static -static-libgcc -static-libstdc++)
  fi

  run_logged "build-hello-c"   tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/hello.c"   -o "${WORK_DIR}/bin/hello_c" "${ldflags[@]}"
  run_logged "build-hello-cpp" tc g++ "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/hello.cpp" -o "${WORK_DIR}/bin/hello_cpp" "${cxx_ldflags[@]}"

  run_logged "build-pthread" tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/pthread.c" -o "${WORK_DIR}/bin/pthread" -pthread "${ldflags[@]}"
  run_logged "build-except"  tc g++ "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/except.cpp" -o "${WORK_DIR}/bin/except" "${cxx_ldflags[@]}"
  run_logged "build-atomics" tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/atomics.c" -o "${WORK_DIR}/bin/atomics" "${ldflags[@]}"
  run_logged "build-lto"     tc gcc "${sys[@]}" "${cflags[@]}" -flto \
    "${WORK_DIR}/src/lto1.c" "${WORK_DIR}/src/lto2.c" -o "${WORK_DIR}/bin/lto_test" "${ldflags[@]}"

  if [[ "${STRESS_LIBSTDCPP_ABI}" == "1" ]]; then
    run_logged "build-abi-string" tc g++ "${sys[@]}" "${cflags[@]}" \
      "${WORK_DIR}/src/abi_string.cpp" -o "${WORK_DIR}/bin/abi_string" "${cxx_ldflags[@]}"
  fi

  if [[ "${LINK_MODE}" == "dynamic" ]]; then
    run_logged "build-dlopen"  tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/dlopen.c" -o "${WORK_DIR}/bin/dlopen" -ldl

    run_logged "build-libthrow" tc g++ "${sys[@]}" "${cflags[@]}" -fPIC -shared \
      -Wl,-soname,libthrow.so \
      "${WORK_DIR}/src/throwlib.cpp" -o "${WORK_DIR}/lib/libthrow.so"

    run_logged "build-dso-catch" tc g++ "${sys[@]}" "${cflags[@]}" \
      "${WORK_DIR}/src/dso_catch.cpp" -o "${WORK_DIR}/bin/dso_catch" \
      -ldl -Wl,-rpath,"${origin_rpath}"

    run_logged "build-libthrow-symlink" bash -c "
      set -e
      ln -sf ../lib/libthrow.so '${WORK_DIR}/bin/libthrow.so'
      ls -l '${WORK_DIR}/bin/libthrow.so'
    "

    run_logged "build-dlopen-threads" tc g++ "${sys[@]}" "${cflags[@]}" \
      "${WORK_DIR}/src/dlopen_threads.cpp" -o "${WORK_DIR}/bin/dlopen_threads" \
      -ldl -pthread -Wl,-rpath,"${origin_rpath}"

    run_logged "build-libsym-a" tc gcc "${sys[@]}" "${cflags[@]}" -fPIC -shared \
      -Wl,-soname,libsym_a.so \
      "${WORK_DIR}/src/sym_a.c" -o "${WORK_DIR}/lib/libsym_a.so"

    run_logged "build-libsym-b" tc gcc "${sys[@]}" "${cflags[@]}" -fPIC -shared \
      -Wl,-soname,libsym_b.so \
      "${WORK_DIR}/src/sym_b.c" -o "${WORK_DIR}/lib/libsym_b.so"

    run_logged "build-rtld-collision" tc gcc "${sys[@]}" "${cflags[@]}" \
      "${WORK_DIR}/src/rtld_collision.c" -o "${WORK_DIR}/bin/rtld_collision" \
      -ldl -Wl,-rpath,"${origin_rpath}"

    run_logged "build-symlink-sym-a" bash -c "set -e; ln -sf ../lib/libsym_a.so '${WORK_DIR}/bin/libsym_a.so'; ls -l '${WORK_DIR}/bin/libsym_a.so'"
    run_logged "build-symlink-sym-b" bash -c "set -e; ln -sf ../lib/libsym_b.so '${WORK_DIR}/bin/libsym_b.so'; ls -l '${WORK_DIR}/bin/libsym_b.so'"

    if [[ "${STRESS_STRIP_VERIFY}" == "1" ]]; then
      run_logged "strip-verify" bash -c "
        set -e
        cp -a '${WORK_DIR}/bin/hello_c' '${WORK_DIR}/bin/hello_c.stripped'
        '${TC_PREFIX}/bin/${TARGET}-strip' '${WORK_DIR}/bin/hello_c.stripped' || true
        '${QEMU_AARCH64}' -L '${SYSROOT}' '${WORK_DIR}/bin/hello_c.stripped' >/dev/null
        echo 'strip-verify: ok'
      "
    fi
  else
    log "LINK_MODE=static: skipping dlopen/DSO/rtld collision builds"
  fi
}

# ------------------------------ Stress C++ -----------------------------------
stress_cpp_compile() {
  mkdirp "${WORK_DIR}/src" "${WORK_DIR}/bin"
  cat > "${WORK_DIR}/src/stress.cpp" <<'EOF'
#include <algorithm>
#include <functional>
#include <iostream>
#include <map>
#include <numeric>
#include <optional>
#include <random>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

template <typename T>
struct Box { T value; constexpr Box(T v) : value(v) {} constexpr T get() const { return value; } };

template <typename... Ts>
constexpr auto fold_sum(Ts... xs) { return (xs + ... + 0); }

static inline int run() {
  std::vector<int> v(5000);
  std::iota(v.begin(), v.end(), 1);
  std::shuffle(v.begin(), v.end(), std::mt19937{123});
  std::sort(v.begin(), v.end());
  auto s = std::accumulate(v.begin(), v.end(), 0);

  std::map<std::string,int> m;
  m["sum"] = s;

  std::optional<int> o = m["sum"];
  if (!o) return 2;

  constexpr Box<int> b(7);
  static_assert(b.get() == 7);

  constexpr auto z = fold_sum(1,2,3,4,5);
  static_assert(z == 15);

  return (o.value() == (5000*5001)/2) ? 0 : 3;
}

int main(){ return run(); }
EOF

  detect_link_mode
  local extra=()
  if [[ "${LINK_MODE}" == "static" ]]; then
    extra+=(-static -static-libgcc -static-libstdc++)
  fi

  run_logged "stress-cpp-build" tc g++ --sysroot="${SYSROOT}" -O2 -std=gnu++20 \
    "${WORK_DIR}/src/stress.cpp" -o "${WORK_DIR}/bin/stress_cpp" "${extra[@]}"
}

stress_lto_matrix() {
  [[ "${STRESS_LTO_MATRIX}" == "1" ]] || return 0
  mkdirp "${WORK_DIR}/bin"

  detect_link_mode
  local sys=(--sysroot="${SYSROOT}")
  local base=(-O2)
  local ldflags=()
  if [[ "${LINK_MODE}" == "static" ]]; then ldflags+=(-static); fi

  run_logged "stress-lto" tc gcc "${sys[@]}" "${base[@]}" -flto \
    "${WORK_DIR}/src/lto1.c" "${WORK_DIR}/src/lto2.c" -o "${WORK_DIR}/bin/lto" "${ldflags[@]}"
  run_logged "qemu-run-lto" qemu_run "${WORK_DIR}/bin/lto"

  run_logged "stress-lto-jobs" tc gcc "${sys[@]}" "${base[@]}" -flto="${JOBS}" \
    "${WORK_DIR}/src/lto1.c" "${WORK_DIR}/src/lto2.c" -o "${WORK_DIR}/bin/lto_jobs" "${ldflags[@]}"
  run_logged "qemu-run-lto-jobs" qemu_run "${WORK_DIR}/bin/lto_jobs"
}

# ------------------------------ Integration Builds ----------------------------
integration_prepare() {
  detect_link_mode
  [[ "${LINK_MODE}" == "dynamic" ]] || die "integration suite requires LINK_MODE=dynamic"
  have_cmd tar || die "missing tar"
  have_cmd make || die "missing make"
  mkdirp "${TARBALL_DIR}" "${SRC_DIR}" "${BUILD_DIR}" "${INSTALL_DIR}"
}

path_without_stale_target_toolchains() {
  local original="$1"
  local prefix_bin="${TC_PREFIX}/bin"
  local out="" dir
  local -a path_parts

  IFS=':' read -r -a path_parts <<< "${original}"
  for dir in "${path_parts[@]}"; do
    [[ -n "${dir}" ]] || continue
    [[ "${dir}" == "${prefix_bin}" ]] && continue

    if [[ "${dir}" == /opt/gcc-*/bin ]] \
      && [[ -x "${dir}/${TARGET}-gcc" || -x "${dir}/${TARGET}-g++" || -x "${dir}/${TARGET}-pkg-config" ]]; then
      continue
    fi

    if [[ -z "${out}" ]]; then
      out="${dir}"
    else
      out="${out}:${dir}"
    fi
  done

  printf '%s\n' "${out}"
}

export_integration_env() {
  local sanitized_path

  sanitized_path="$(path_without_stale_target_toolchains "${PATH}")"
  export PATH="${TC_PREFIX}/bin:${sanitized_path}"
  export CC="${TC_PREFIX}/bin/${TARGET}-gcc"
  export CXX="${TC_PREFIX}/bin/${TARGET}-g++"
  export AR="${TC_PREFIX}/bin/${TARGET}-ar"
  export AS="${TC_PREFIX}/bin/${TARGET}-as"
  export LD="${TC_PREFIX}/bin/${TARGET}-ld"
  export NM="${TC_PREFIX}/bin/${TARGET}-nm"
  export OBJCOPY="${TC_PREFIX}/bin/${TARGET}-objcopy"
  export OBJDUMP="${TC_PREFIX}/bin/${TARGET}-objdump"
  export RANLIB="${TC_PREFIX}/bin/${TARGET}-ranlib"
  export READELF="${TC_PREFIX}/bin/${TARGET}-readelf"
  export STRIP="${TC_PREFIX}/bin/${TARGET}-strip"
  export PKG_CONFIG="${TC_PREFIX}/bin/${TARGET}-pkg-config"
  export CFLAGS="${CFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export LDFLAGS="${LDFLAGS:-} --sysroot=${SYSROOT}"

  export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
  export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/pkgconfig:${SYSROOT}/usr/share/pkgconfig:${INSTALL_DIR}/lib/pkgconfig:${INSTALL_DIR}/share/pkgconfig"
  export PKG_CONFIG_PATH="${INSTALL_DIR}/lib/pkgconfig:${INSTALL_DIR}/share/pkgconfig"
}

find_tls_ca_bundle() {
  local candidate resolved
  local -a candidates=()

  if [[ -n "${TLS_CA_BUNDLE}" ]]; then
    candidates+=("${TLS_CA_BUNDLE}")
  fi

  candidates+=("${SYSROOT}/etc/ssl/certs/ca-certificates.crt")

  if [[ -L "${SYSROOT}/usr/lib/ssl/cert.pem" ]]; then
    resolved="$(readlink "${SYSROOT}/usr/lib/ssl/cert.pem")"
    if [[ "${resolved}" == /* ]]; then
      candidates+=("${SYSROOT}${resolved}")
    else
      candidates+=("${SYSROOT}/usr/lib/ssl/${resolved}")
    fi
  else
    candidates+=("${SYSROOT}/usr/lib/ssl/cert.pem")
  fi

  candidates+=("${PI_SYSROOT}/etc/ssl/certs/ca-certificates.crt")

  if [[ -L "${PI_SYSROOT}/usr/lib/ssl/cert.pem" ]]; then
    resolved="$(readlink "${PI_SYSROOT}/usr/lib/ssl/cert.pem")"
    if [[ "${resolved}" == /* ]]; then
      candidates+=("${PI_SYSROOT}${resolved}")
    else
      candidates+=("${PI_SYSROOT}/usr/lib/ssl/${resolved}")
    fi
  else
    candidates+=("${PI_SYSROOT}/usr/lib/ssl/cert.pem")
  fi

  candidates+=("/etc/ssl/certs/ca-certificates.crt")
  candidates+=("/etc/pki/tls/certs/ca-bundle.crt")
  candidates+=("/etc/ssl/ca-bundle.pem")

  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    [[ -f "${candidate}" ]] || continue
    if grep -q -- "-----BEGIN CERTIFICATE-----" "${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

integration_stage_ca_bundle() {
  [[ "${PI_TLS_SELFCONTAINED}" == "1" ]] || return 0

  local dest="${INSTALL_DIR}/ssl/certs/ca-certificates.crt"
  mkdirp "$(dirname "${dest}")"

  local ca_src=""
  if ca_src="$(find_tls_ca_bundle)"; then
    run_logged "integration-stage-ca-bundle" bash -c "
      set -e
      cp -f '${ca_src}' '${dest}'
      echo 'staged_ca_bundle_src=${ca_src}'
      echo 'staged_ca_bundle_dest=${dest}'
      wc -c '${dest}' | awk '{print \$1, \$2}'
    "
    return 0
  fi

  run_logged "integration-stage-ca-bundle" bash -c "
    set -e
    echo 'No valid CA bundle found in TLS_CA_BUNDLE, SYSROOT, PI_SYSROOT, or host trust paths.'
    echo 'Falling back to download: ${CA_BUNDLE_URL}'
  "

  download_try "${dest}" "${CA_BUNDLE_URL}"

  run_logged "integration-stage-ca-bundle-verify" bash -c "
    set -e
    test -s '${dest}'
    grep -m1 'BEGIN CERTIFICATE' '${dest}' >/dev/null 2>&1 || { echo 'ERROR: staged CA bundle missing PEM header'; exit 2; }
    echo 'staged_ca_bundle_dest=${dest}'
    wc -c '${dest}' | awk '{print \$1, \$2}'
  "
}

integration_zlib() {
  integration_prepare
  export_integration_env

  local tb="${TARBALL_DIR}/zlib-${ZLIB_VER}.tar.gz"
  local src="${SRC_DIR}/zlib-${ZLIB_VER}"

  download_try "${tb}" \
    "${ZLIB_URL}" \
    "https://zlib.net/fossils/zlib-${ZLIB_VER}.tar.gz" \
    "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz"
  verify_sha256 "${tb}" "${ZLIB_SHA256}"
  verify_gpg_signature "${tb}" "${ZLIB_SIG_URL}" "${ZLIB_GPG_FPR}"

  if integration_source_needs_extract "${src}" "configure"; then
    extract "${tb}" "${src}"
  fi

  run_logged "integration-zlib-configure" bash -c "
    set -e
    cd '${src}'
    ./configure --prefix='${INSTALL_DIR}'
  "
  run_logged "integration-zlib-build" bash -c "set -e; cd '${src}'; make -j'${JOBS}'"
  run_logged "integration-zlib-install" bash -c "set -e; cd '${src}'; make install"
}

integration_openssl() {
  integration_prepare
  export_integration_env

  local tb="${TARBALL_DIR}/openssl-${OPENSSL_VER}.tar.gz"
  local src="${SRC_DIR}/openssl-${OPENSSL_VER}"
  download "${OPENSSL_URL}" "${tb}"
  verify_sha256 "${tb}" "${OPENSSL_SHA256}"
  verify_gpg_signature "${tb}" "${OPENSSL_SIG_URL}" "${OPENSSL_GPG_FPR}"
  if integration_source_needs_extract "${src}" "Configure"; then
    extract "${tb}" "${src}"
  fi

  run_logged "integration-openssl-configure" bash -c "
    set -e
    cd '${src}'
    ./Configure linux-aarch64 \
      --prefix='${INSTALL_DIR}' \
      --openssldir='${INSTALL_DIR}/ssl' \
      no-tests
  "
  run_logged "integration-openssl-build" bash -c "set -e; cd '${src}'; make -j'${JOBS}'"
  run_logged "integration-openssl-install" bash -c "set -e; cd '${src}'; make install_sw"
}

integration_curl() {
  integration_prepare
  export_integration_env

  local tb="${TARBALL_DIR}/curl-${CURL_VER}.tar.gz"
  local src="${SRC_DIR}/curl-${CURL_VER}"
  download "${CURL_URL}" "${tb}"
  verify_sha256 "${tb}" "${CURL_SHA256}"
  verify_gpg_signature "${tb}" "${CURL_SIG_URL}" "${CURL_GPG_FPR}"
  if integration_source_needs_extract "${src}" "configure"; then
    extract "${tb}" "${src}"
  fi

  local extra_opts=()
  if [[ "${CURL_DISABLE_LIBPSL}" == "1" ]]; then extra_opts+=(--without-libpsl); fi
  if [[ "${CURL_DISABLE_BROTLI}" == "1" ]]; then extra_opts+=(--without-brotli); fi

  # Keep target defaults portable; self-contained tests pass explicit staged CA
  # bundles at runtime instead of baking host cache paths into curl.
  run_logged "integration-curl-configure" bash -c "
    set -e
    cd '${src}'
    export CPPFLAGS='-I${INSTALL_DIR}/include'
    export LDFLAGS='${LDFLAGS} -L${INSTALL_DIR}/lib'
    ./configure \
      --host='${TARGET}' \
      --prefix='${INSTALL_DIR}' \
      --with-sysroot='${SYSROOT}' \
      --with-zlib='${INSTALL_DIR}' \
      --with-openssl='${INSTALL_DIR}' \
      --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
      --with-ca-path=/etc/ssl/certs \
      ${extra_opts[*]} \
      --disable-manual \
      --disable-debug \
      --enable-shared \
      --disable-static
  "
  run_logged "integration-curl-build" bash -c "set -e; cd '${src}'; make -j'${JOBS}'"
  run_logged "integration-curl-install" bash -c "set -e; cd '${src}'; make install"
}

_fixup_runpath_for_bin() {
  local name="$1"
  local bin="$2"
  [[ -x "${bin}" ]] || die "${name} binary not found at: ${bin}"
  have_cmd readelf || die "missing readelf"
  have_cmd grep || die "missing grep"

  local wanted_runpath
  # shellcheck disable=SC2016
  wanted_runpath='$ORIGIN/../lib:$ORIGIN/../lib64'

  run_logged "${name}" bash -c "
    set -e
    echo 'before:'
    readelf -d '${bin}' | grep -E 'RPATH|RUNPATH' || true
  "

  if have_cmd patchelf; then
    patchelf --set-rpath "${wanted_runpath}" "${bin}"
  elif have_cmd chrpath; then
    chrpath -r "${wanted_runpath}" "${bin}"
  else
    echo "ERROR: need patchelf or chrpath on host to fix RPATH/RUNPATH" >&2
    return 2
  fi

  run_logged "${name}-after" bash -c "
    set -e
    echo 'after:'
    readelf -d '${bin}' | grep -E 'RPATH|RUNPATH' || true
  "
}

integration_fixup_curl_rpath() {
  _fixup_runpath_for_bin "integration-fixup-curl-rpath" "${INSTALL_DIR}/bin/curl"
}

integration_fixup_openssl_rpath() {
  _fixup_runpath_for_bin "integration-fixup-openssl-rpath" "${INSTALL_DIR}/bin/openssl"
}

# ------------------------------ TLS postcheck (NO bash -c quoting) -------------
_tls_candidates() {
  # precedence:
  #   TLS_CA_BUNDLE (if set) -> staged -> PI_SYSROOT -> host
  local forced="${TLS_CA_BUNDLE:-}"
  local staged="${INSTALL_DIR}/ssl/certs/ca-certificates.crt"
  local pi_ca="${PI_SYSROOT}/etc/ssl/certs/ca-certificates.crt"
  local host_ca="/etc/ssl/certs/ca-certificates.crt"

  if [[ -n "${forced}" ]]; then
    echo "${forced}"
    return 0
  fi
  echo "${staged}"
  echo "${pi_ca}"
  echo "${host_ca}"
}

_tls_try_one() {
  # _tls_try_one <ca_file> <curl_bin>
  local ca="$1"
  local curl_bin="$2"

  local tmp
  tmp="$(mktemp)"
  local capath
  capath="$(dirname "${ca}")"

  local capath_args=()
  [[ -d "${capath}" ]] && capath_args+=(--capath "${capath}")

  set +e
  CURL_CA_BUNDLE="${ca}" SSL_CERT_FILE="${ca}" \
    "${QEMU_AARCH64}" -L "${SYSROOT}" "${curl_bin}" \
      -vI --max-time 15 --cacert "${ca}" "${capath_args[@]}" "${PI_NET_TEST_URL}" \
      2>&1 | sed -n '1,140p' > "${tmp}"
  local st_curl=${PIPESTATUS[0]}
  set -e

  # print transcript exactly once
  cat "${tmp}"

  if [[ "${st_curl}" -ne 0 ]]; then
    echo "(curl exit=${st_curl})"
    rm -f "${tmp}"
    return 2
  fi

  if ! grep -E '^(< )?HTTP/' "${tmp}" >/dev/null 2>&1; then
    echo "(warning: no HTTP status line observed in truncated output)"
  fi

  rm -f "${tmp}"
  return 0
}

postcheck_qemu_curl_tls() {
  # expects globals: INSTALL_DIR, QEMU_AARCH64, SYSROOT, PI_SYSROOT, PI_NET_TEST_URL
  local curl_bin="${INSTALL_DIR}/bin/curl"

  local ok=0
  local chosen=""

  while IFS= read -r cand; do
    [[ -n "${cand}" ]] || continue
    echo "---"
    echo "Trying CA bundle: ${cand}"
    if _tls_try_one "${cand}" "${curl_bin}"; then
      ok=1
      chosen="${cand}"
      break
    else
      echo "(failed with CA: ${cand})"
    fi
  done < <(_tls_candidates)

  if [[ "${ok}" != "1" ]]; then
    echo
    echo "ERROR: TLS postcheck failed with all CA bundle candidates."
    echo "Tried (in order):"
    _tls_candidates | sed 's/^/  - /'
    echo
    echo "Hints:"
    echo "  - If you are behind HTTPS inspection, set TLS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
    echo "  - Or point TLS_CA_BUNDLE at the enterprise root bundle you trust."
    return 60
  fi

  echo
  echo "TLS postcheck: PASS using CA bundle: ${chosen}"
  return 0
}

postcheck_integration_artifacts() {
  detect_link_mode
  [[ "${LINK_MODE}" == "dynamic" ]] || return 0

  have_cmd readelf || die "missing readelf"

  local curl_bin="${INSTALL_DIR}/bin/curl"
  local openssl_bin="${INSTALL_DIR}/bin/openssl"
  local libdir="${INSTALL_DIR}/lib"

  run_logged "postcheck-curl-needed-exists" bash -c "
    set -e
    echo 'curl NEEDED:'
    readelf -d '${curl_bin}' | grep -E 'NEEDED' | sed -E 's/.*\\[(.*)\\].*/\\1/' || true
    echo
    for so in libcurl.so.4 libssl.so.3 libcrypto.so.3 libz.so.1; do
      test -e '${libdir}/'\"\$so\" || { echo 'missing: ${libdir}/'\"\$so\"; exit 2; }
      ls -l '${libdir}/'\"\$so\"
    done
  "

  run_logged "postcheck-qemu-openssl-version" bash -c "
    set -e
    '${QEMU_AARCH64}' -L '${SYSROOT}' '${openssl_bin}' version -a
  "

  run_logged "postcheck-qemu-curl-version" bash -c "
    set -e
    '${QEMU_AARCH64}' -L '${SYSROOT}' '${curl_bin}' --version
  "

  if [[ "${PI_NET_TEST}" == "1" ]]; then
    run_logged "postcheck-qemu-curl-tls" postcheck_qemu_curl_tls
  else
    log "PI_NET_TEST=0: skipping TLS postcheck"
  fi
}

integration_run_on_pi() {
  detect_link_mode
  [[ "${LINK_MODE}" == "dynamic" ]] || die "Pi integration run requires LINK_MODE=dynamic"
  have_cmd ssh || die "missing ssh"
  have_cmd scp || die "missing scp"
  have_cmd tar || die "missing tar"

  stage_pi_musl_runtime_tree
  pack_pi_runtime_tarball

  REMOTE_INTEGRATION_USED=1
  run_logged "pi-integration-prepare" remote_reset_dir "PI_INTEGRATION_DIR" "${PI_INTEGRATION_DIR}"

  if have_cmd rsync; then
    run_logged "pi-integration-copy" rsync -a --delete -e "ssh -p ${PI_SSH_PORT}" \
      "${INSTALL_DIR}/" "${PI_SSH}:${PI_INTEGRATION_DIR}/"
  else
    run_logged "pi-integration-copy" bash -c "
      set -e
      scp -P '${PI_SSH_PORT}' -r '${INSTALL_DIR}/.' '${PI_SSH}:${PI_INTEGRATION_DIR}/'
    "
  fi

  run_logged "pi-integration-copy-runtime" scp -P "${PI_SSH_PORT}" \
    "${WORK_DIR}/pi-rt.tgz" "${PI_SSH}:${PI_INTEGRATION_DIR}/"

  run_logged "pi-integration-run" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
    set -e
    cd '${PI_INTEGRATION_DIR}'
    tar -xzf pi-rt.tgz

    I='${PI_INTEGRATION_DIR}'
    LOADER=\"\${I}/pi-rt/lib/ld-musl-aarch64.so.1\"
    LIBPATH=\"\${I}/lib:\${I}/lib64:\${I}/pi-rt/usr/lib:\${I}/pi-rt/lib\"
    C=\"\${I}/bin/curl\"
    O=\"\${I}/bin/openssl\"

    test -x \"\${LOADER}\"
    test -x \"\${C}\"
    test -x \"\${O}\"

    run() { \"\${LOADER}\" --library-path \"\${LIBPATH}\" \"\$@\"; }
    list_deps() { \"\${LOADER}\" --library-path \"\${LIBPATH}\" --list \"\$1\" 2>&1 || true; }

    run \"\${O}\" version
    run \"\${C}\" --version

    echo
    echo '== openssl RUNPATH/RPATH =='
    readelf -d \"\${O}\" | grep -E 'RPATH|RUNPATH' || true

    echo
    echo '== openssl deps =='
    openssl_deps=\$(list_deps \"\${O}\")
    printf '%s\n' \"\${openssl_deps}\"
    ssl_line=\$(printf '%s\n' \"\${openssl_deps}\" | grep -E 'libssl\.so\.3' | head -n1 || true)
    crypto_line=\$(printf '%s\n' \"\${openssl_deps}\" | grep -E 'libcrypto\.so\.3' | head -n1 || true)
    case \"\${ssl_line}\" in
      *\"\${I}/lib\"*) ;;
      *) echo \"ERROR: staged openssl is not loading staged libssl: \${ssl_line}\"; exit 10 ;;
    esac
    case \"\${crypto_line}\" in
      *\"\${I}/lib\"*) ;;
      *) echo \"ERROR: staged openssl is not loading staged libcrypto: \${crypto_line}\"; exit 10 ;;
    esac

    openssl_ver=\$(run \"\${O}\" version)
    openssl_cmd_ver=\$(printf '%s\n' \"\${openssl_ver}\" | sed -nE 's/^OpenSSL[[:space:]]+([^[:space:]]+).*/\1/p')
    openssl_lib_ver=\$(printf '%s\n' \"\${openssl_ver}\" | sed -nE 's/.*\\(Library: OpenSSL[[:space:]]+([^[:space:]]+).*/\1/p')
    if [[ -z \"\${openssl_lib_ver}\" ]]; then openssl_lib_ver=\"\${openssl_cmd_ver}\"; fi
    echo \"openssl-command-version=\${openssl_cmd_ver}\"
    echo \"openssl-library-version=\${openssl_lib_ver}\"
    if [[ -z \"\${openssl_cmd_ver}\" || \"\${openssl_cmd_ver}\" != \"\${openssl_lib_ver}\" ]]; then
      echo 'ERROR: staged openssl command/library version mismatch'
      exit 10
    fi

    echo
    echo '== curl RUNPATH/RPATH =='
    readelf -d \"\${C}\" | grep -E 'RPATH|RUNPATH' || true

    echo
    echo '== curl deps =='
    curl_deps=\$(list_deps \"\${C}\")
    printf '%s\n' \"\${curl_deps}\"
    for so in libcurl.so.4 libssl.so.3 libcrypto.so.3 libz.so.1; do
      line=\$(printf '%s\n' \"\${curl_deps}\" | grep -E \"\${so}\" | head -n1 || true)
      case \"\${line}\" in
        *\"\${I}/lib\"*) ;;
        *) echo \"ERROR: staged curl is not loading staged \${so}: \${line}\"; exit 10 ;;
      esac
    done

    url='${PI_NET_TEST_URL}'
    hostport=\${url#*://}
    hostport=\${hostport%%/*}
    host=\${hostport%%:*}
    port=\${hostport#*:}
    if [[ \"\${port}\" == \"\${hostport}\" ]]; then
      if echo \"\${url}\" | grep -qi '^http://'; then port=80; else port=443; fi
    fi
    if [[ -z \"\${host}\" ]]; then host='example.com'; port=443; fi

    if [[ '${PI_NET_TEST}' == '1' ]]; then
      echo
      echo '== network test (curl https, default trust store) =='
      run \"\${C}\" -fsS -I --max-time 15 '${PI_NET_TEST_URL}' >/dev/null
      echo \"net-ok(default): ${PI_NET_TEST_URL}\"

      echo
      echo '== trust store assertion (robust) =='
      out=\$(run \"\${C}\" -vI --max-time 15 '${PI_NET_TEST_URL}' 2>&1)
      out=\$(printf '%s\n' \"\${out}\" | tr -d '\\r')
      printf '%s\n' \"\${out}\"
      cafile=\$(printf '%s\n' \"\${out}\" | sed -nE 's/^[*[:space:]]*CAfile:[[:space:]]*(.*)\$/\1/p' | head -n1)
      capath=\$(printf '%s\n' \"\${out}\" | sed -nE 's/^[*[:space:]]*CApath:[[:space:]]*(.*)\$/\1/p' | head -n1)
      echo \"seen CAfile: \${cafile:-'(not reported)'}\"
      echo \"seen CApath: \${capath:-'(not reported)'}\"
      if [[ -n \"\${cafile}\" && \"\${cafile}\" != '/etc/ssl/certs/ca-certificates.crt' ]]; then
        echo 'trust-FAIL(default): CAfile mismatch'
        exit 8
      fi
      if [[ -n \"\${capath}\" && \"\${capath}\" != '/etc/ssl/certs' ]]; then
        echo 'trust-FAIL(default): CApath mismatch'
        exit 8
      fi
      echo 'trust-ok(default): CAfile/CApath acceptable'
    fi

    if [[ '${PI_TLS_SELFCONTAINED}' == '1' ]]; then
      echo
      echo '== TLS self-contained test (staged CA bundle) =='
      B=\"\${I}/ssl/certs/ca-certificates.crt\"
      test -s \"\${B}\"
      run \"\${C}\" -fsS -I --max-time 15 --cacert \"\${B}\" '${PI_NET_TEST_URL}' >/dev/null
      echo \"net-ok(selfcontained): ${PI_NET_TEST_URL}\"
    fi

    if [[ '${STRESS_OPENSSL_TLS}' == '1' ]]; then
      echo
      echo '== OpenSSL TLS handshake test =='
      if echo \"\${url}\" | grep -qi '^https://'; then
        echo | run \"\${O}\" s_client -connect \"\${host}:\${port}\" -servername \"\${host}\" \
          -CAfile /etc/ssl/certs/ca-certificates.crt -CApath /etc/ssl/certs \
          -verify_return_error -brief >/dev/null
        echo \"openssl-ok(default): \${host}:\${port}\"

        if [[ '${PI_TLS_SELFCONTAINED}' == '1' ]]; then
          echo | run \"\${O}\" s_client -connect \"\${host}:\${port}\" -servername \"\${host}\" \
            -CAfile \"\${I}/ssl/certs/ca-certificates.crt\" -verify_return_error -brief >/dev/null
          echo \"openssl-ok(selfcontained): \${host}:\${port}\"
        fi
      fi
    fi
  "

  log "INTEGRATION_RUN_ON_PI: PASS"
}

run_integration_suite() {
  log "INTEGRATION=1: running integration builds (zlib -> openssl -> curl)"
  integration_zlib
  integration_openssl
  integration_stage_ca_bundle
  integration_curl
  integration_fixup_curl_rpath
  integration_fixup_openssl_rpath
  postcheck_integration_artifacts
  log "INTEGRATION: PASS"

  if [[ "${INTEGRATION_RUN_ON_PI}" == "1" ]]; then
    log "INTEGRATION_RUN_ON_PI=1: copying musl integration tree to Pi and running openssl/curl"
    integration_run_on_pi
  fi
}

# ------------------------------ Tiers -----------------------------------------
tier_report() {
  mark_tier_start "report"
  need_paths
  mkdirp "${LOG_DIR}"

  run_logged "report" bash -c "
    set -e
    echo 'Toolchain test script: ${SCRIPT_VERSION}'
    echo
    echo 'TC_PREFIX=${TC_PREFIX}'
    echo 'TARGET=${TARGET}'
    echo 'SYSROOT=${SYSROOT}'
    echo 'LINK_MODE=${LINK_MODE}'
    echo 'A_PLUS=${A_PLUS}'
    echo
    echo '--- gcc -v (Configured with) ---'
    '${TC_PREFIX}/bin/${TARGET}-gcc' -v 2>&1 | sed -n '/Configured with:/,/Thread model:/p'
    echo
    echo '--- gcc search dirs ---'
    '${TC_PREFIX}/bin/${TARGET}-gcc' -print-search-dirs
    echo
    echo '--- sysroot lib dir ---'
    ls -l '${SYSROOT}/lib' || true
    echo
    echo '--- qemu ---'
    command -v '${QEMU_AARCH64}' >/dev/null 2>&1 && '${QEMU_AARCH64}' --version | head -n 1 || echo '(qemu not installed)'
    echo
    echo '--- integration toggles ---'
    echo 'INTEGRATION=${INTEGRATION}'
    echo 'INTEGRATION_RUN_ON_PI=${INTEGRATION_RUN_ON_PI}'
    echo 'PI_NET_TEST=${PI_NET_TEST}'
    echo 'PI_NET_TEST_URL=${PI_NET_TEST_URL}'
    echo 'PI_TLS_SELFCONTAINED=${PI_TLS_SELFCONTAINED}'
    echo 'CA_BUNDLE_URL=${CA_BUNDLE_URL}'
    echo 'PI_SYSROOT=${PI_SYSROOT}'
    echo
    echo '--- stress toggles ---'
    echo 'STRESS_CPP=${STRESS_CPP}'
    echo 'STRESS_DLOPEN_THREADS=${STRESS_DLOPEN_THREADS}'
    echo 'STRESS_DLOPEN_THREADS_N=${STRESS_DLOPEN_THREADS_N}'
    echo 'STRESS_DLOPEN_ITERS=${STRESS_DLOPEN_ITERS}'
    echo 'STRESS_RTLD_COLLISION=${STRESS_RTLD_COLLISION}'
    echo 'STRESS_OPENSSL_TLS=${STRESS_OPENSSL_TLS}'
    echo 'STRESS_LTO_MATRIX=${STRESS_LTO_MATRIX}'
    echo 'STRESS_STRIP_VERIFY=${STRESS_STRIP_VERIFY}'
    echo 'STRESS_LIBSTDCPP_ABI=${STRESS_LIBSTDCPP_ABI}'
    echo
    echo 'SYSROOT_LINK_AUDIT=${SYSROOT_LINK_AUDIT}'
  "

  mark_tier_pass "report"
  tier_summary
}

tier_sanity() {
  EXIT_CLEANUP_ENABLED=1
  mark_tier_start "sanity"
  need_paths
  need_qemu
  mkdirp "${WORK_DIR}"
  write_sources

  run_logged "provenance-gcc" bash -c "
    set -e
    '${TC_PREFIX}/bin/${TARGET}-gcc' -v 2>&1 | sed -n '/Configured with:/,/Thread model:/p'
    echo
    '${TC_PREFIX}/bin/${TARGET}-gcc' -print-sysroot
    echo
    '${TC_PREFIX}/bin/${TARGET}-gcc' -print-search-dirs
    echo
    '${TC_PREFIX}/bin/${TARGET}-ld' --version | head -n 2 || true
  "

  sysroot_link_audit
  assert_pkg_config_wrapper

  build_binaries
  inspect_elf "${WORK_DIR}/bin/hello_c"
  inspect_elf "${WORK_DIR}/bin/hello_cpp"

  assert_static_elf_clean "${WORK_DIR}/bin/hello_c"
  assert_static_elf_clean "${WORK_DIR}/bin/hello_cpp"

  run_logged "qemu-run-hello-c"   qemu_run "${WORK_DIR}/bin/hello_c"
  run_logged "qemu-run-hello-cpp" qemu_run "${WORK_DIR}/bin/hello_cpp"

  mark_tier_pass "sanity"
  tier_summary
}

tier_smoke() {
  EXIT_CLEANUP_ENABLED=1
  mark_tier_start "smoke"
  need_paths
  need_qemu
  mkdirp "${WORK_DIR}"
  write_sources
  build_binaries

  if [[ "${STRESS_CPP}" == "1" ]]; then
    stress_cpp_compile
    assert_static_elf_clean "${WORK_DIR}/bin/stress_cpp"
    run_logged "qemu-run-stress-cpp" qemu_run "${WORK_DIR}/bin/stress_cpp"
  fi

  stress_lto_matrix

  assert_static_elf_clean "${WORK_DIR}/bin/pthread"
  assert_static_elf_clean "${WORK_DIR}/bin/except"
  assert_static_elf_clean "${WORK_DIR}/bin/atomics"
  assert_static_elf_clean "${WORK_DIR}/bin/lto_test"

  run_logged "qemu-run-pthread" qemu_run "${WORK_DIR}/bin/pthread"
  run_logged "qemu-run-except"  qemu_run "${WORK_DIR}/bin/except"
  run_logged "qemu-run-atomics" qemu_run "${WORK_DIR}/bin/atomics"
  run_logged "qemu-run-lto"     qemu_run "${WORK_DIR}/bin/lto_test"

  if [[ "${STRESS_LIBSTDCPP_ABI}" == "1" ]]; then
    run_logged "qemu-run-abi-string" qemu_run "${WORK_DIR}/bin/abi_string"
  fi

  if [[ "${LINK_MODE}" == "dynamic" ]]; then
    run_logged "qemu-run-dlopen"  qemu_run "${WORK_DIR}/bin/dlopen"

    inspect_elf "${WORK_DIR}/bin/dso_catch"
    run_logged "qemu-run-dso-catch" bash -c "
      set -e
      cd '${WORK_DIR}/bin'
      '${QEMU_AARCH64}' -L '${SYSROOT}' './dso_catch'
    "

    if [[ "${STRESS_DLOPEN_THREADS}" == "1" ]]; then
      run_logged "qemu-run-dlopen-threads" bash -c "
        set -e
        cd '${WORK_DIR}/bin'
        '${QEMU_AARCH64}' -L '${SYSROOT}' './dlopen_threads' '${STRESS_DLOPEN_THREADS_N}' '${STRESS_DLOPEN_ITERS}' './libthrow.so'
      "
    fi

    if [[ "${STRESS_RTLD_COLLISION}" == "1" ]]; then
      run_logged "qemu-run-rtld-collision" bash -c "
        set -e
        cd '${WORK_DIR}/bin'
        '${QEMU_AARCH64}' -L '${SYSROOT}' './rtld_collision'
      "
    fi
  else
    log "LINK_MODE=static: skipping dlopen/DSO/rtld runtime tests"
  fi

  mark_tier_pass "smoke"
  tier_summary
}

tier_nightly() {
  EXIT_CLEANUP_ENABLED=1
  mark_tier_start "nightly"
  need_paths
  mkdirp "${WORK_DIR}"
  write_sources
  build_binaries

  assert_static_elf_clean "${WORK_DIR}/bin/hello_c"
  assert_static_elf_clean "${WORK_DIR}/bin/hello_cpp"
  assert_static_elf_clean "${WORK_DIR}/bin/pthread"
  assert_static_elf_clean "${WORK_DIR}/bin/except"
  assert_static_elf_clean "${WORK_DIR}/bin/atomics"
  assert_static_elf_clean "${WORK_DIR}/bin/lto_test"

  have_cmd ssh || die "missing ssh"
  have_cmd scp || die "missing scp"
  have_cmd tar || die "missing tar"

  REMOTE_TMPDIR_USED=1
  run_logged "pi-prepare" remote_reset_dir "PI_TMPDIR" "${PI_TMPDIR}"

  run_logged "pi-copy-bins" bash -c "
    set -e
    scp -P '${PI_SSH_PORT}' '${WORK_DIR}/bin/'* '${PI_SSH}:${PI_TMPDIR}/'
    if [[ '${LINK_MODE}' == 'dynamic' ]]; then
      scp -P '${PI_SSH_PORT}' '${WORK_DIR}/lib/'*.so '${PI_SSH}:${PI_TMPDIR}/' || true
    fi
  "

  if [[ "${LINK_MODE}" == "dynamic" ]]; then
    stage_pi_musl_runtime_tree
    pack_pi_runtime_tarball

    run_logged "pi-copy-runtime" bash -c "
      set -e
      scp -P '${PI_SSH_PORT}' '${WORK_DIR}/pi-rt.tgz' '${PI_SSH}:${PI_TMPDIR}/'
    "

    run_logged "pi-unpack-runtime" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
      set -e
      cd '${PI_TMPDIR}'
      tar -xzf pi-rt.tgz
      test -x './pi-rt/lib/ld-musl-aarch64.so.1'
      ./pi-rt/lib/ld-musl-aarch64.so.1 --help >/dev/null 2>&1 || true
      echo 'runtime-staged: OK'
    "

    run_logged "pi-run-suite" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
      set -e
      cd '${PI_TMPDIR}'
      LOADER='./pi-rt/lib/ld-musl-aarch64.so.1'
      LIBPATH='./pi-rt/usr/lib:./pi-rt/lib:${PI_TMPDIR}'
      run() { \"\$LOADER\" --library-path \"\$LIBPATH\" \"\$@\"; }

      run './hello_c'
      run './hello_cpp'
      run './pthread'
      run './except'
      run './atomics'
      run './lto_test'

      run './dlopen'
      run './dso_catch'
      if [[ '${STRESS_DLOPEN_THREADS}' == '1' ]]; then
        run './dlopen_threads' '${STRESS_DLOPEN_THREADS_N}' '${STRESS_DLOPEN_ITERS}' './libthrow.so'
      fi
      if [[ '${STRESS_RTLD_COLLISION}' == '1' ]]; then
        run './rtld_collision'
      fi

      if [[ -x './abi_string' ]]; then
        run './abi_string'
      fi
    "
  else
    run_logged "pi-run-suite" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
      set -e
      cd '${PI_TMPDIR}'
      './hello_c'
      './hello_cpp'
      './pthread'
      './except'
      './atomics'
      './lto_test'
      if [[ -x './abi_string' ]]; then
        './abi_string'
      fi
    "
  fi

  if [[ "${INTEGRATION}" == "1" ]]; then
    run_integration_suite
  fi

  mark_tier_pass "nightly"
  tier_summary
}

tier_all() {
  tier_report
  tier_sanity
  tier_smoke
  tier_nightly
}

usage() {
  cat <<EOF
test-musl-cross-toolchain.sh (version ${SCRIPT_VERSION})

Usage:
  $0 report
  $0 sanity
  $0 smoke
  $0 nightly
  $0 all
  $0 clean
  $0 distclean

LINK_MODE:
  LINK_MODE=auto     (default) detect based on SYSROOT (static-first)
  LINK_MODE=dynamic  run dynamic suite (dlopen/DSO/rtld)
  LINK_MODE=static   run static suite (skip dlopen/DSO/rtld; build -static)
                     + HARD ASSERTS:
                       - no PT_INTERP / no interpreter
                       - no DT_NEEDED

A+ run (dynamic only):
  A_PLUS=1 LINK_MODE=dynamic $0 all

Key env:
  TARGET=${TARGET}
  TC_PREFIX=${TC_PREFIX}
  SYSROOT=${SYSROOT}
  QEMU_AARCH64=${QEMU_AARCH64}
  FRESH_LOGS=1              (default; clears prior logs/status at start of a run)
  KEEP_WORKDIR=${KEEP_WORKDIR}              (default: 0; removes transient host work dir on exit)
  KEEP_CACHE=${KEEP_CACHE}                (default: 0; removes integration cache on exit)
  clean                     removes LOG_DIR and WORK_DIR
  distclean                 removes LOG_DIR, WORK_DIR, and integration CACHE_DIR

Pi env:
  PI_SSH=${PI_SSH}
  PI_SSH_PORT=${PI_SSH_PORT}
  PI_TMPDIR=${PI_TMPDIR}
  KEEP_REMOTE=${KEEP_REMOTE}               (default: 0; removes Pi test/integration dirs on exit)

TLS env:
  PI_NET_TEST=${PI_NET_TEST}
  PI_NET_TEST_URL=${PI_NET_TEST_URL}
  PI_TLS_SELFCONTAINED=${PI_TLS_SELFCONTAINED}
  CA_BUNDLE_URL=${CA_BUNDLE_URL}
  PI_SYSROOT=${PI_SYSROOT}
  TLS_CA_BUNDLE=/path/to/ca.crt (override CA selection)
  VERIFY_INTEGRATION_DOWNLOADS=${VERIFY_INTEGRATION_DOWNLOADS}
  VERIFY_INTEGRATION_GPG=${VERIFY_INTEGRATION_GPG}
  INTEGRATION_SOURCE_REFRESH=${INTEGRATION_SOURCE_REFRESH}
  ZLIB_SHA256=${ZLIB_SHA256}
  ZLIB_GPG_FPR=${ZLIB_GPG_FPR}
  OPENSSL_SHA256=${OPENSSL_SHA256}
  OPENSSL_GPG_FPR=${OPENSSL_GPG_FPR}
  CURL_SHA256=${CURL_SHA256}
  CURL_GPG_FPR=${CURL_GPG_FPR}

A+ stress env:
  STRESS_CPP=${STRESS_CPP}
  STRESS_LTO_MATRIX=${STRESS_LTO_MATRIX}
  STRESS_STRIP_VERIFY=${STRESS_STRIP_VERIFY}
  STRESS_LIBSTDCPP_ABI=${STRESS_LIBSTDCPP_ABI}

EOF
}

main() {
  echo "Version: ${SCRIPT_VERSION}"

  local cmd="${1:-}"
  case "${cmd}" in
    report)  validate_settings; reset_logs_for_run; tier_report ;;
    sanity)  validate_settings; reset_logs_for_run; tier_sanity ;;
    smoke)   validate_settings; reset_logs_for_run; tier_smoke ;;
    nightly) validate_settings; reset_logs_for_run; tier_nightly ;;
    all)     validate_settings; reset_logs_for_run; tier_all ;;
    clean)   clean_test_artifacts ;;
    distclean) distclean_test_artifacts ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
