#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# test-cross-toolchain.sh
#
# Run the following tests and if all are clean then toolchain is good:
#
# ./test-cross-toolchain.sh sanity
# ./test-cross-toolchain.sh smoke
# A_PLUS=1 ./test-cross-toolchain.sh nightly
# ==============================================================================

SCRIPT_VERSION="v0.1.0"

# ------------------------------ Defaults --------------------------------------
TARGET="${TARGET:-aarch64-linux-gnu}"
GCC_VER="${GCC_VER:-15.3.0}"
TC_PREFIX="${TC_PREFIX:-/opt/gcc-${GCC_VER}-cross}"
SYSROOT="${SYSROOT:-/build-rpi/rpi/sysroot}"

QEMU_AARCH64="${QEMU_AARCH64:-qemu-aarch64}"

PI_SSH="${PI_SSH:-root@raspberrypi2.totten}"
PI_SSH_PORT="${PI_SSH_PORT:-22}"
PI_TMPDIR="${PI_TMPDIR:-/tmp/gcc-toolchain-tests}"

INTEGRATION="${INTEGRATION:-0}"
INTEGRATION_RUN_ON_PI="${INTEGRATION_RUN_ON_PI:-0}"
PI_INTEGRATION_DIR="${PI_INTEGRATION_DIR:-/tmp/gcc-toolchain-integration}"

PI_NET_TEST="${PI_NET_TEST:-1}"
PI_NET_TEST_URL="${PI_NET_TEST_URL:-https://example.com}"

# When set, we stage a CA bundle into INSTALL_DIR and use it via CURL_CA_BUNDLE
PI_TLS_SELFCONTAINED="${PI_TLS_SELFCONTAINED:-0}"

# Stress toggles (rare failure modes)
STRESS_CPP="${STRESS_CPP:-0}"
STRESS_DLOPEN_THREADS="${STRESS_DLOPEN_THREADS:-1}"
STRESS_DLOPEN_THREADS_N="${STRESS_DLOPEN_THREADS_N:-4}"
STRESS_DLOPEN_ITERS="${STRESS_DLOPEN_ITERS:-250}"

STRESS_RTLD_COLLISION="${STRESS_RTLD_COLLISION:-1}"

# OpenSSL handshake test on Pi (in addition to curl). Uses bundled openssl when integration runs.
STRESS_OPENSSL_TLS="${STRESS_OPENSSL_TLS:-1}"

ZLIB_VER="${ZLIB_VER:-1.3.2}"
ZLIB_URL="${ZLIB_URL:-https://zlib.net/zlib-${ZLIB_VER}.tar.gz}"
ZLIB_SIG_URL="${ZLIB_SIG_URL:-${ZLIB_URL}.asc}"
ZLIB_SHA256="${ZLIB_SHA256:-bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16}"

OPENSSL_VER="${OPENSSL_VER:-3.5.7}"
OPENSSL_URL="${OPENSSL_URL:-https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz}"
OPENSSL_SIG_URL="${OPENSSL_SIG_URL:-${OPENSSL_URL}.asc}"
OPENSSL_SHA256="${OPENSSL_SHA256:-a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8}"

CURL_VER="${CURL_VER:-8.20.0}"
CURL_URL="${CURL_URL:-https://curl.se/download/curl-${CURL_VER}.tar.gz}"
CURL_SIG_URL="${CURL_SIG_URL:-${CURL_URL}.asc}"
CURL_SHA256="${CURL_SHA256:-fc5819cad3f9f5482669adcdc49a782c15f36d2a0715b395b06d9173593d2dc0}"

VERIFY_INTEGRATION_DOWNLOADS="${VERIFY_INTEGRATION_DOWNLOADS:-1}"
VERIFY_INTEGRATION_GPG="${VERIFY_INTEGRATION_GPG:-1}"

# Integration toggles
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
KEEP_CACHE="${KEEP_CACHE:-1}"
FRESH_LOGS="${FRESH_LOGS:-1}"

# ------------------------------ A+ Super Suite Switch --------------------------
# When A_PLUS=1, automatically enable all heavy integration + stress tests.
A_PLUS="${A_PLUS:-0}"

if [[ "${A_PLUS}" == "1" ]]; then
  echo "A_PLUS=1: enabling full integration + stress suite"

  INTEGRATION=1
  INTEGRATION_RUN_ON_PI=1
  PI_NET_TEST=1
  PI_TLS_SELFCONTAINED=1

  STRESS_DLOPEN_THREADS=1
  STRESS_DLOPEN_THREADS_N="${A_PLUS_DLOPEN_THREADS_N:-4}"
  STRESS_DLOPEN_ITERS="${A_PLUS_DLOPEN_ITERS:-500}"

  STRESS_RTLD_COLLISION=1
  STRESS_OPENSSL_TLS=1
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

write_validation_report() {
  local report="${LOG_DIR}/validation-report.txt"
  local sdir="${LOG_DIR}/.status"
  local sysroot_glibc=""
  sysroot_glibc="$(sysroot_glibc_version 2>/dev/null || true)"

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
    echo "sysroot_glibc=${sysroot_glibc}"
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
    echo "verify_integration_downloads=${VERIFY_INTEGRATION_DOWNLOADS}"
    echo "verify_integration_gpg=${VERIFY_INTEGRATION_GPG}"
    echo "stress_dlopen_threads=${STRESS_DLOPEN_THREADS}"
    echo "stress_dlopen_threads_n=${STRESS_DLOPEN_THREADS_N}"
    echo "stress_dlopen_iters=${STRESS_DLOPEN_ITERS}"
    echo "stress_rtld_collision=${STRESS_RTLD_COLLISION}"
    echo "stress_openssl_tls=${STRESS_OPENSSL_TLS}"
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

run_logged() {
  local name="$1"; shift
  local logf="${LOG_DIR}/${name}.log"
  mkdirp "${LOG_DIR}"
  log "${name}"
  echo "    log: ${logf}"
  ( "$@" ) > >(tee -a "${logf}") 2> >(tee -a "${logf}" 1>&2)
}

cleanup() {
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

need_paths() {
  [[ -x "${TC_PREFIX}/bin/${TARGET}-gcc" ]] || die "missing compiler: ${TC_PREFIX}/bin/${TARGET}-gcc"
  [[ -x "${TC_PREFIX}/bin/${TARGET}-g++" ]] || die "missing compiler: ${TC_PREFIX}/bin/${TARGET}-g++"
  [[ -x "${TC_PREFIX}/bin/${TARGET}-ar"  ]] || die "missing: ${TC_PREFIX}/bin/${TARGET}-ar"
  [[ -x "${TC_PREFIX}/bin/${TARGET}-ranlib"  ]] || die "missing: ${TC_PREFIX}/bin/${TARGET}-ranlib"
  [[ -d "${SYSROOT}/usr/include" ]] || die "missing sysroot headers: ${SYSROOT}/usr/include"
  sysroot_loader >/dev/null || die "missing sysroot loader ld-linux-aarch64.so.1 under ${SYSROOT}"
}

need_qemu() {
  have_cmd "${QEMU_AARCH64}" || die "missing ${QEMU_AARCH64}. Install qemu-user (Debian: apt install qemu-user)"
}

tc() {
  local tool="$1"
  shift
  "${TC_PREFIX}/bin/${TARGET}-${tool}" "$@"
}
qemu_run() { "${QEMU_AARCH64}" -L "${SYSROOT}" "$@"; }

sysroot_loader() {
  local p
  for p in \
    "${SYSROOT}/lib/ld-linux-aarch64.so.1" \
    "${SYSROOT}/usr/lib/ld-linux-aarch64.so.1" \
    "${SYSROOT}/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" \
    "${SYSROOT}/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
  do
    [[ -e "${p}" ]] && { printf '%s\n' "${p}"; return 0; }
  done
  return 1
}

sysroot_glibc_version() {
  local libc line
  libc="$(find "${SYSROOT}" -type f -name 'libc.so.6' -print -quit 2>/dev/null || true)"
  [[ -n "${libc}" ]] || return 1

  line="$(strings "${libc}" 2>/dev/null | grep -E 'GNU C Library.*release version [0-9]' | head -n 1 || true)"
  if [[ -n "${line}" ]]; then
    printf '%s\n' "${line}" | sed -nE 's/.*release version ([0-9]+([.][0-9]+)+).*/\1/p'
    return 0
  fi

  strings "${libc}" 2>/dev/null | sed -nE 's/.*GLIBC ([0-9]+([.][0-9]+)+).*/\1/p' | head -n 1
}

assert_sysroot_abi() {
  have_cmd strings || die "missing strings"

  local glibc
  glibc="$(sysroot_glibc_version || true)"
  [[ -n "${glibc}" ]] || die "could not determine sysroot glibc version from ${SYSROOT}"

  run_logged "sysroot-abi" bash -lc "
    set -e
    echo 'sysroot=${SYSROOT}'
    echo 'glibc_version=${glibc}'
    find '${SYSROOT}' -type f -name 'libc.so.6' -print -quit
    find '${SYSROOT}' -path '*ld-linux-aarch64.so.1' -print 2>/dev/null | sort
  "
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

verify_sha256() {
  local file="$1"
  local expect="$2"

  [[ "${VERIFY_INTEGRATION_DOWNLOADS}" == "1" ]] || return 0
  [[ -n "${expect}" ]] || die "missing SHA256 for $(basename "${file}"). Set the matching *_SHA256 or VERIFY_INTEGRATION_DOWNLOADS=0."
  have_cmd sha256sum || die "sha256sum not found"

  local got
  got="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${got}" == "${expect}" ]] || die "SHA256 mismatch for ${file}: got ${got} expected ${expect}"
  log "sha256 ok: $(basename "${file}")"
}

verify_gpg_signature() {
  local file="$1"
  local sig_url="$2"
  local sig="${file}.asc"

  [[ "${VERIFY_INTEGRATION_GPG}" == "1" ]] || return 0
  have_cmd gpg || die "VERIFY_INTEGRATION_GPG=1 requires gpg"

  download "${sig_url}" "${sig}"
  gpg --verify "${sig}" "${file}"
  log "gpg signature ok: $(basename "${file}")"
}

print_integration_hashes() {
  have_cmd sha256sum || die "sha256sum not found"
  mkdirp "${TARBALL_DIR}"

  local zlib_tb="${TARBALL_DIR}/zlib-${ZLIB_VER}.tar.gz"
  local openssl_tb="${TARBALL_DIR}/openssl-${OPENSSL_VER}.tar.gz"
  local curl_tb="${TARBALL_DIR}/curl-${CURL_VER}.tar.gz"

  download "${ZLIB_URL}" "${zlib_tb}"
  download "${OPENSSL_URL}" "${openssl_tb}"
  download "${CURL_URL}" "${curl_tb}"

  echo
  echo "Candidate integration hashes; verify these against upstream signatures before pinning:"
  sha256sum "${zlib_tb}" "${openssl_tb}" "${curl_tb}"
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

# ------------------------------ Sysroot Link Audit -----------------------------
sysroot_link_audit() {
  [[ "${SYSROOT_LINK_AUDIT}" == "1" ]] || { log "SYSROOT_LINK_AUDIT=0: skipping"; return 0; }

  have_cmd grep || die "missing grep"
  have_cmd readelf || die "missing readelf"

  mkdirp "${WORK_DIR}/src" "${WORK_DIR}/bin"

  cat > "${WORK_DIR}/src/link_audit.c" <<'EOF'
#include <stdio.h>
int main(){ puts("link-audit"); return 0; }
EOF

  run_logged "sanity-link-audit" tc gcc --sysroot="${SYSROOT}" -O2 \
    -Wl,-t "${WORK_DIR}/src/link_audit.c" -o "${WORK_DIR}/bin/link_audit"

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

  run_logged "sanity-link-audit-inspect" bash -lc "
    set -e
    file '${WORK_DIR}/bin/link_audit'
    readelf -l '${WORK_DIR}/bin/link_audit' | grep -E 'Requesting program interpreter' || true
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
  void* h = dlopen("libm.so.6", RTLD_LAZY);
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

  # Throw/catch across dlopen boundary
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

  # Threaded dlopen stress (loader + pthread + dlerror thread-safety)
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

  # RTLD_GLOBAL collision test (symbol interposition surprises)
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
}

build_binaries() {
  local cflags=(-O2)
  local sys=(--sysroot="${SYSROOT}")
  local origin_rpath
  # shellcheck disable=SC2016
  origin_rpath='$ORIGIN/../lib'

  run_logged "build-hello-c"   tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/hello.c"   -o "${WORK_DIR}/bin/hello_c"
  run_logged "build-hello-cpp" tc g++ "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/hello.cpp" -o "${WORK_DIR}/bin/hello_cpp"

  run_logged "build-pthread" tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/pthread.c" -o "${WORK_DIR}/bin/pthread" -pthread
  run_logged "build-except"  tc g++ "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/except.cpp" -o "${WORK_DIR}/bin/except"
  run_logged "build-atomics" tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/atomics.c" -o "${WORK_DIR}/bin/atomics"
  run_logged "build-dlopen"  tc gcc "${sys[@]}" "${cflags[@]}" "${WORK_DIR}/src/dlopen.c" -o "${WORK_DIR}/bin/dlopen" -ldl
  run_logged "build-lto"     tc gcc "${sys[@]}" "${cflags[@]}" -flto \
    "${WORK_DIR}/src/lto1.c" "${WORK_DIR}/src/lto2.c" -o "${WORK_DIR}/bin/lto_test"

  run_logged "build-libthrow" tc g++ "${sys[@]}" "${cflags[@]}" -fPIC -shared \
    -Wl,-soname,libthrow.so \
    "${WORK_DIR}/src/throwlib.cpp" -o "${WORK_DIR}/lib/libthrow.so"

  run_logged "build-dso-catch" tc g++ "${sys[@]}" "${cflags[@]}" \
    "${WORK_DIR}/src/dso_catch.cpp" -o "${WORK_DIR}/bin/dso_catch" \
    -ldl -Wl,-rpath,"${origin_rpath}"

  # Make dlopen("./libthrow.so") succeed when running from WORK_DIR/bin
  run_logged "build-libthrow-symlink" bash -lc "
    set -e
    ln -sf ../lib/libthrow.so '${WORK_DIR}/bin/libthrow.so'
    ls -l '${WORK_DIR}/bin/libthrow.so'
  "

  # Threaded dlopen stress binary
  run_logged "build-dlopen-threads" tc g++ "${sys[@]}" "${cflags[@]}" \
    "${WORK_DIR}/src/dlopen_threads.cpp" -o "${WORK_DIR}/bin/dlopen_threads" \
    -ldl -pthread -Wl,-rpath,"${origin_rpath}"

  # RTLD collision artifacts
  run_logged "build-libsym-a" tc gcc "${sys[@]}" "${cflags[@]}" -fPIC -shared \
    -Wl,-soname,libsym_a.so \
    "${WORK_DIR}/src/sym_a.c" -o "${WORK_DIR}/lib/libsym_a.so"
  run_logged "build-libsym-b" tc gcc "${sys[@]}" "${cflags[@]}" -fPIC -shared \
    -Wl,-soname,libsym_b.so \
    "${WORK_DIR}/src/sym_b.c" -o "${WORK_DIR}/lib/libsym_b.so"
  run_logged "build-rtld-collision" tc gcc "${sys[@]}" "${cflags[@]}" \
    "${WORK_DIR}/src/rtld_collision.c" -o "${WORK_DIR}/bin/rtld_collision" \
    -ldl -Wl,-rpath,"${origin_rpath}"

  run_logged "build-symlink-sym-a" bash -lc "set -e; ln -sf ../lib/libsym_a.so '${WORK_DIR}/bin/libsym_a.so'; ls -l '${WORK_DIR}/bin/libsym_a.so'"
  run_logged "build-symlink-sym-b" bash -lc "set -e; ln -sf ../lib/libsym_b.so '${WORK_DIR}/bin/libsym_b.so'; ls -l '${WORK_DIR}/bin/libsym_b.so'"
}

inspect_elf() {
  local bin="$1"
  run_logged "inspect-$(basename "$bin")" bash -lc "
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

assert_default_hardening() {
  mkdirp "${WORK_DIR}/src" "${WORK_DIR}/bin"

  cat > "${WORK_DIR}/src/hardening.c" <<'EOF'
#include <stdio.h>
#include <string.h>
int main(int argc, char** argv){
  char buf[64];
  const char* s = argc > 1 ? argv[1] : "hardening";
  snprintf(buf, sizeof(buf), "%s", s);
  return (int)strlen(buf) == 0;
}
EOF

  run_logged "hardening-build-defaults" tc gcc --sysroot="${SYSROOT}" -O2 \
    "${WORK_DIR}/src/hardening.c" -o "${WORK_DIR}/bin/hardening_default"
  run_logged "hardening-build-now" tc gcc --sysroot="${SYSROOT}" -O2 \
    "${WORK_DIR}/src/hardening.c" -o "${WORK_DIR}/bin/hardening_now" \
    -Wl,-z,now

  run_logged "hardening-assert-defaults" bash -lc "
    set -e
    bin='${WORK_DIR}/bin/hardening_default'
    nowbin='${WORK_DIR}/bin/hardening_now'

    echo '--- ELF type ---'
    readelf -h \"\${bin}\" | grep -E 'Type:[[:space:]]*DYN' >/dev/null
    readelf -h \"\${bin}\" | grep -E 'Type:'

    echo
    echo '--- stack protector symbol ---'
    readelf -Ws \"\${bin}\" | grep -E '__stack_chk_fail' >/dev/null
    readelf -Ws \"\${bin}\" | grep -E '__stack_chk_fail' | head -n 5

    echo
    echo '--- RELRO segment ---'
    readelf -l \"\${bin}\" | grep -E 'GNU_RELRO' >/dev/null
    readelf -l \"\${bin}\" | grep -E 'GNU_RELRO'

    echo
    echo '--- non-executable stack ---'
    readelf -W -l \"\${bin}\" | awk '/GNU_STACK/ { found=1; if (\$7 ~ /E/) exit 1 } END { exit found ? 0 : 2 }'
    readelf -W -l \"\${bin}\" | grep -E 'GNU_STACK'

    echo
    echo '--- GNU hash section ---'
    readelf -S \"\${bin}\" | grep -F '.gnu.hash' >/dev/null
    readelf -S \"\${bin}\" | grep -F '.gnu.hash'

    echo
    echo '--- BIND_NOW with -z now ---'
    readelf -d \"\${nowbin}\" | grep -E 'BIND_NOW|FLAGS.*NOW' >/dev/null
    readelf -d \"\${nowbin}\" | grep -E 'BIND_NOW|FLAGS.*NOW'
  "
}

assert_toolchain_runtime_libs() {
  local libstdcxx libgcc libstdcxx_dir libgcc_dir

  libstdcxx="$(tc g++ -print-file-name=libstdc++.so.6)"
  libgcc="$(tc gcc -print-file-name=libgcc_s.so.1)"
  libstdcxx_dir="$(dirname "${libstdcxx}")"
  libgcc_dir="$(dirname "${libgcc}")"

  [[ -f "${libstdcxx}" ]] || die "fresh libstdc++.so.6 not found via compiler: ${libstdcxx}"
  [[ -f "${libgcc}" ]] || die "fresh libgcc not found via compiler: ${libgcc}"

  run_logged "runtime-lib-provenance" bash -lc "
    set -e
    echo 'libstdcxx=${libstdcxx}'
    echo 'libgcc=${libgcc}'
    file '${libstdcxx}'
    file '${libgcc}'
    readelf -h '${libstdcxx}' | grep -E 'Machine:[[:space:]]*AArch64'
    readelf -h '${libgcc}' | grep -E 'Machine:[[:space:]]*AArch64'
  "

  run_logged "qemu-run-hello-cpp-fresh-runtime" env \
    LD_LIBRARY_PATH="${libstdcxx_dir}:${libgcc_dir}" \
    "${QEMU_AARCH64}" -L "${SYSROOT}" "${WORK_DIR}/bin/hello_cpp"
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

  run_logged "stress-cpp-build" tc g++ --sysroot="${SYSROOT}" -O2 -std=gnu++20 \
    "${WORK_DIR}/src/stress.cpp" -o "${WORK_DIR}/bin/stress_cpp"
}

# ------------------------------ Integration Builds ----------------------------
integration_prepare() {
  have_cmd tar || die "missing tar"
  have_cmd make || die "missing make"
  mkdirp "${TARBALL_DIR}" "${SRC_DIR}" "${BUILD_DIR}" "${INSTALL_DIR}"
}

export_integration_env() {
  export CC="${TC_PREFIX}/bin/${TARGET}-gcc"
  export CXX="${TC_PREFIX}/bin/${TARGET}-g++"
  export AR="${TC_PREFIX}/bin/${TARGET}-ar"
  export RANLIB="${TC_PREFIX}/bin/${TARGET}-ranlib"
  export STRIP="${TC_PREFIX}/bin/${TARGET}-strip"
  export CFLAGS="${CFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export LDFLAGS="${LDFLAGS:-} --sysroot=${SYSROOT}"

  export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
  export PKG_CONFIG_LIBDIR="${INSTALL_DIR}/lib/pkgconfig:${INSTALL_DIR}/share/pkgconfig:${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig"
  export PKG_CONFIG_PATH="${INSTALL_DIR}/lib/pkgconfig:${INSTALL_DIR}/share/pkgconfig"
}

integration_stage_ca_bundle() {
  [[ "${PI_TLS_SELFCONTAINED}" == "1" ]] || return 0

  local src="${SYSROOT}/etc/ssl/certs/ca-certificates.crt"
  local dest="${INSTALL_DIR}/ssl/certs/ca-certificates.crt"

  [[ -f "${src}" ]] || die "CA bundle not found in sysroot: ${src}"
  mkdirp "$(dirname "${dest}")"

  run_logged "integration-stage-ca-bundle" bash -lc "
    set -e
    cp -f '${src}' '${dest}'
    echo 'staged_ca_bundle_src=${src}'
    echo 'staged_ca_bundle_dest=${dest}'
    wc -c '${dest}' | awk '{print \$1, \$2}'
  "
}

integration_zlib() {
  integration_prepare
  export_integration_env

  local tb="${TARBALL_DIR}/zlib-${ZLIB_VER}.tar.gz"
  local src="${SRC_DIR}/zlib-${ZLIB_VER}"
  download "${ZLIB_URL}" "${tb}"
  verify_sha256 "${tb}" "${ZLIB_SHA256}"
  verify_gpg_signature "${tb}" "${ZLIB_SIG_URL}"
  [[ -d "${src}" && -f "${src}/configure" ]] || extract "${tb}" "${src}"

  run_logged "integration-zlib-configure" bash -lc "
    set -e
    cd '${src}'
    ./configure --prefix='${INSTALL_DIR}'
  "
  run_logged "integration-zlib-build" bash -lc "set -e; cd '${src}'; make -j'${JOBS}'"
  run_logged "integration-zlib-install" bash -lc "set -e; cd '${src}'; make install"
}

integration_openssl() {
  integration_prepare
  export_integration_env

  local tb="${TARBALL_DIR}/openssl-${OPENSSL_VER}.tar.gz"
  local src="${SRC_DIR}/openssl-${OPENSSL_VER}"
  download "${OPENSSL_URL}" "${tb}"
  verify_sha256 "${tb}" "${OPENSSL_SHA256}"
  verify_gpg_signature "${tb}" "${OPENSSL_SIG_URL}"
  [[ -d "${src}" && -f "${src}/Configure" ]] || extract "${tb}" "${src}"

  run_logged "integration-openssl-configure" bash -lc "
    set -e
    cd '${src}'
    ./Configure linux-aarch64 \
      --prefix='${INSTALL_DIR}' \
      --openssldir='${INSTALL_DIR}/ssl' \
      no-tests
  "
  run_logged "integration-openssl-build" bash -lc "set -e; cd '${src}'; make -j'${JOBS}'"
  run_logged "integration-openssl-install" bash -lc "set -e; cd '${src}'; make install_sw"
}

integration_curl() {
  integration_prepare
  export_integration_env

  local tb="${TARBALL_DIR}/curl-${CURL_VER}.tar.gz"
  local src="${SRC_DIR}/curl-${CURL_VER}"
  download "${CURL_URL}" "${tb}"
  verify_sha256 "${tb}" "${CURL_SHA256}"
  verify_gpg_signature "${tb}" "${CURL_SIG_URL}"
  [[ -d "${src}" && -f "${src}/configure" ]] || extract "${tb}" "${src}"

  local extra_opts=()
  if [[ "${CURL_DISABLE_LIBPSL}" == "1" ]]; then
    extra_opts+=(--without-libpsl)
  fi
  if [[ "${CURL_DISABLE_BROTLI}" == "1" ]]; then
    extra_opts+=(--without-brotli)
  fi

  # IMPORTANT:
  # - Do NOT bake host build paths like ${INSTALL_DIR}/... into curl.
  # - Do set target runtime defaults to Debian/RPi trust store paths.
  run_logged "integration-curl-configure" bash -lc "
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
  run_logged "integration-curl-build" bash -lc "set -e; cd '${src}'; make -j'${JOBS}'"
  run_logged "integration-curl-install" bash -lc "set -e; cd '${src}'; make install"
}

integration_fixup_binary_rpath() {
  local name="$1"
  local bin="$2"

  [[ -x "${bin}" ]] || die "${name} binary not found at: ${bin}"
  have_cmd readelf || die "missing readelf"
  have_cmd grep || die "missing grep"

  local wanted_runpath
  # shellcheck disable=SC2016
  wanted_runpath='$ORIGIN/../lib:$ORIGIN/../lib64'

  run_logged "integration-fixup-${name}-rpath-before" bash -lc "
    set -e
    echo 'before:'
    readelf -d '${bin}' | grep -E 'RPATH|RUNPATH' || true
  "

  if have_cmd patchelf; then
    patchelf --set-rpath "${wanted_runpath}" "${bin}"
  elif have_cmd chrpath; then
    chrpath -r "${wanted_runpath}" "${bin}"
  else
    echo
    echo "ERROR: need patchelf or chrpath on host to fix RPATH/RUNPATH"
    return 2
  fi

  run_logged "integration-fixup-${name}-rpath-after" bash -lc "
    set -e
    echo 'after:'
    readelf -d '${bin}' | grep -E 'RPATH|RUNPATH'
  "
}

integration_fixup_runtime_rpaths() {
  integration_fixup_binary_rpath "openssl" "${INSTALL_DIR}/bin/openssl"
  integration_fixup_binary_rpath "curl" "${INSTALL_DIR}/bin/curl"
}

integration_run_on_pi() {
  have_cmd ssh || die "missing ssh"
  have_cmd scp || die "missing scp"

  run_logged "pi-integration-prepare" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
    set -e
    rm -rf '${PI_INTEGRATION_DIR}'
    mkdir -p '${PI_INTEGRATION_DIR}'
  "

  if have_cmd rsync; then
    run_logged "pi-integration-copy" rsync -a --delete -e "ssh -p ${PI_SSH_PORT}" \
      "${INSTALL_DIR}/" "${PI_SSH}:${PI_INTEGRATION_DIR}/"
  else
    run_logged "pi-integration-copy" bash -lc "
      set -e
      scp -P '${PI_SSH_PORT}' -r '${INSTALL_DIR}/.' '${PI_SSH}:${PI_INTEGRATION_DIR}/'
    "
  fi

  run_logged "pi-integration-run" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
    set -e

    C='${PI_INTEGRATION_DIR}/bin/curl'
    O='${PI_INTEGRATION_DIR}/bin/openssl'
    if [[ ! -x \"\${C}\" ]]; then C='curl'; fi
    if [[ ! -x \"\${O}\" ]]; then O='openssl'; fi

    \"\${O}\" version || true
    \"\${C}\" --version || true

    echo
    echo '== openssl RUNPATH/RPATH =='
    if [[ -x '${PI_INTEGRATION_DIR}/bin/openssl' ]]; then
      readelf -d '${PI_INTEGRATION_DIR}/bin/openssl' | grep -E 'RPATH|RUNPATH' || true
    else
      echo '(integrated openssl not present; using system openssl)'
    fi

    echo
    echo '== openssl deps (subset) =='
    if [[ -x '${PI_INTEGRATION_DIR}/bin/openssl' ]]; then
      openssl_deps=\$(ldd '${PI_INTEGRATION_DIR}/bin/openssl')
      printf '%s\n' \"\${openssl_deps}\" | grep -E 'ssl|crypto' || true

      ssl_line=\$(printf '%s\n' \"\${openssl_deps}\" | grep -E 'libssl\.so\.3[[:space:]]+=>' | head -n1 || true)
      crypto_line=\$(printf '%s\n' \"\${openssl_deps}\" | grep -E 'libcrypto\.so\.3[[:space:]]+=>' | head -n1 || true)
      case \"\${ssl_line}\" in
        *'${PI_INTEGRATION_DIR}'*) ;;
        *) echo \"ERROR: staged openssl is not loading staged libssl: \${ssl_line}\"; exit 10 ;;
      esac
      case \"\${crypto_line}\" in
        *'${PI_INTEGRATION_DIR}'*) ;;
        *) echo \"ERROR: staged openssl is not loading staged libcrypto: \${crypto_line}\"; exit 10 ;;
      esac

      openssl_ver=\$(\"\${O}\" version)
      openssl_cmd_ver=\$(printf '%s\n' \"\${openssl_ver}\" | sed -nE 's/^OpenSSL[[:space:]]+([^[:space:]]+).*/\1/p')
      openssl_lib_ver=\$(printf '%s\n' \"\${openssl_ver}\" | sed -nE 's/.*\\(Library: OpenSSL[[:space:]]+([^[:space:]]+).*/\1/p')
      if [[ -z \"\${openssl_lib_ver}\" ]]; then openssl_lib_ver=\"\${openssl_cmd_ver}\"; fi
      echo \"openssl-command-version=\${openssl_cmd_ver}\"
      echo \"openssl-library-version=\${openssl_lib_ver}\"
      if [[ -z \"\${openssl_cmd_ver}\" || \"\${openssl_cmd_ver}\" != \"\${openssl_lib_ver}\" ]]; then
        echo \"ERROR: staged openssl command/library version mismatch\"
        exit 10
      fi
    else
      echo '(integrated openssl not present; using system openssl)'
    fi

    echo
    echo '== curl -V (CAfile/CApath visibility) =='
    \"\${C}\" -V || true

    echo
    echo '== curl RUNPATH/RPATH =='
    if [[ -x '${PI_INTEGRATION_DIR}/bin/curl' ]]; then
      readelf -d '${PI_INTEGRATION_DIR}/bin/curl' | grep -E 'RPATH|RUNPATH' || true
    else
      echo '(integrated curl not present; using system curl)'
    fi

    echo
    echo '== curl deps (subset) =='
    if [[ -x '${PI_INTEGRATION_DIR}/bin/curl' ]]; then
      ldd '${PI_INTEGRATION_DIR}/bin/curl' | grep -E 'ssl|crypto|zlib|zstd|nghttp2|libcurl' || true
    else
      echo '(integrated curl not present; using system curl)'
    fi

    # derive host:port from PI_NET_TEST_URL
    url='${PI_NET_TEST_URL}'
    hostport=\${url#*://}
    hostport=\${hostport%%/*}
    host=\${hostport%%:*}
    port=\${hostport#*:}
    if [[ \"\${port}\" == \"\${hostport}\" ]]; then
      # default port by scheme
      if echo \"\${url}\" | grep -qi '^http://'; then port=80; else port=443; fi
    fi
    if [[ -z \"\${host}\" ]]; then host='example.com'; port=443; fi

    if [[ '${PI_NET_TEST}' == '1' ]]; then
      echo
      echo '== network test (curl https, default trust store) =='
      set +e
      \"\${C}\" -fsS -I --max-time 15 '${PI_NET_TEST_URL}' >/dev/null
      rc=\$?
      set -e

      if [[ \$rc -ne 0 ]]; then
        echo \"net-warn(default): failed (exit=\$rc)\"
        if [[ '${PI_TLS_SELFCONTAINED}' == '1' ]]; then
          echo \"(non-fatal; PI_TLS_SELFCONTAINED=1 makes staged bundle authoritative)\"
        else
          exit \$rc
        fi
      else
        echo \"net-ok(default): ${PI_NET_TEST_URL}\"
      fi

      echo
      echo '== trust store assertion (robust) =='
      echo 'expected CAfile: /etc/ssl/certs/ca-certificates.crt'
      echo 'expected CApath: /etc/ssl/certs'

      out=\$(\"\\\${C}\" -vI --max-time 15 '${PI_NET_TEST_URL}' 2>&1 || true)
      out=\$(printf '%s\n' \"\\\${out}\" | tr -d '\\r')

      cafile=\$(printf '%s\n' \"\\\${out}\" | sed -nE 's/^[*[:space:]]*CAfile:[[:space:]]*(.*)\$/\\1/p' | head -n1)
      capath=\$(printf '%s\n' \"\\\${out}\" | sed -nE 's/^[*[:space:]]*CApath:[[:space:]]*(.*)\$/\\1/p' | head -n1)

      echo \"seen CAfile: \${cafile:-'(not reported)'}\"
      echo \"seen CApath: \${capath:-'(not reported)'}\"

      exp_file='/etc/ssl/certs/ca-certificates.crt'
      exp_path='/etc/ssl/certs'

      fail=0
      if [[ -n \"\${cafile}\" && \"\${cafile}\" != \"\${exp_file}\" ]]; then
        echo \"trust-FAIL(default): CAfile mismatch (expected \${exp_file})\"
        fail=1
      fi
      if [[ -n \"\${capath}\" && \"\${capath}\" != \"\${exp_path}\" ]]; then
        echo \"trust-FAIL(default): CApath mismatch (expected \${exp_path})\"
        fail=1
      fi

      if [[ \"\${fail}\" -eq 1 ]]; then
        exit 8
      fi

      if [[ -z \"\${cafile}\" && -z \"\${capath}\" ]]; then
        echo 'trust-WARN(default): curl did not report CAfile/CApath in verbose output (non-fatal)'
        echo 'trust-ok(default): TLS succeeded; defaults appear functional'
      else
        echo 'trust-ok(default): CAfile/CApath acceptable'
      fi

      if [[ '${PI_TLS_SELFCONTAINED}' == '1' ]]; then
        echo
        echo '== TLS self-contained test (staged CA bundle) =='
        B='${PI_INTEGRATION_DIR}/ssl/certs/ca-certificates.crt'
        if [[ ! -f \"\${B}\" ]]; then
          echo \"ERROR: staged bundle missing on Pi: \${B}\"
          exit 2
        fi
        echo \"using staged CA bundle: \${B}\"
        stat \"\${B}\" || true

        CURL_CA_BUNDLE=\"\${B}\" \"\${C}\" -fsS -I --max-time 15 '${PI_NET_TEST_URL}' >/dev/null
        echo \"net-ok(selfcontained): ${PI_NET_TEST_URL}\"
      fi

      if [[ '${STRESS_OPENSSL_TLS}' == '1' ]]; then
        echo
        echo '== OpenSSL TLS handshake test (default trust store) =='
        # Only meaningful for TLS endpoints.
        if echo \"\${url}\" | grep -qi '^https://'; then
          echo | \"\${O}\" s_client -connect \"\${host}:\${port}\" -servername \"\${host}\" \
            -CAfile /etc/ssl/certs/ca-certificates.crt -CApath /etc/ssl/certs \
            -verify_return_error -brief >/dev/null
          echo \"openssl-ok(default): \${host}:\${port}\"
        else
          echo 'openssl-skip(default): non-https URL'
        fi

        if [[ '${PI_TLS_SELFCONTAINED}' == '1' ]]; then
          echo
          echo '== OpenSSL TLS handshake test (staged CA bundle) =='
          if echo \"\${url}\" | grep -qi '^https://'; then
            B='${PI_INTEGRATION_DIR}/ssl/certs/ca-certificates.crt'
            echo | \"\${O}\" s_client -connect \"\${host}:\${port}\" -servername \"\${host}\" \
              -CAfile \"\${B}\" -verify_return_error -brief >/dev/null
            echo \"openssl-ok(selfcontained): \${host}:\${port}\"
          else
            echo 'openssl-skip(selfcontained): non-https URL'
          fi
        fi
      fi
    else
      echo
      echo '== network test =='
      echo 'PI_NET_TEST=0: skipped'
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
  integration_fixup_runtime_rpaths

  log "INTEGRATION: PASS"

  if [[ "${INTEGRATION_RUN_ON_PI}" == "1" ]]; then
    log "INTEGRATION_RUN_ON_PI=1: copying INSTALL_DIR to Pi and running openssl/curl"
    integration_run_on_pi
  fi
}

# ------------------------------ Commands --------------------------------------
tier_report() {
  mark_tier_start "report"
  need_paths
  mkdirp "${LOG_DIR}"

  run_logged "report" bash -lc "
    set -e
    echo 'Toolchain test script: ${SCRIPT_VERSION}'
    echo
    echo 'TC_PREFIX=${TC_PREFIX}'
    echo 'TARGET=${TARGET}'
    echo 'SYSROOT=${SYSROOT}'
    echo
    echo 'A_PLUS=${A_PLUS}'
    echo
    echo '--- gcc -v (Configured with) ---'
    '${TC_PREFIX}/bin/${TARGET}-gcc' -v 2>&1 | sed -n '/Configured with:/,/Thread model:/p'
    echo
    echo '--- gcc search dirs ---'
    '${TC_PREFIX}/bin/${TARGET}-gcc' -print-search-dirs
    echo
    echo '--- sysroot loader ---'
    find '${SYSROOT}' -path '*ld-linux-aarch64.so.1' -print 2>/dev/null | sort
    echo
    echo '--- qemu ---'
    command -v '${QEMU_AARCH64}' >/dev/null 2>&1 && '${QEMU_AARCH64}' --version | head -n 1 || echo '(qemu not installed)'
    echo
    echo '--- nightly target ---'
    echo 'PI_SSH=${PI_SSH}:${PI_SSH_PORT}'
    echo
    echo '--- integration toggles ---'
    echo 'INTEGRATION=${INTEGRATION}'
    echo 'INTEGRATION_RUN_ON_PI=${INTEGRATION_RUN_ON_PI}'
    echo 'PI_INTEGRATION_DIR=${PI_INTEGRATION_DIR}'
    echo 'PI_NET_TEST=${PI_NET_TEST}'
    echo 'PI_NET_TEST_URL=${PI_NET_TEST_URL}'
    echo 'PI_TLS_SELFCONTAINED=${PI_TLS_SELFCONTAINED}'
    echo
    echo '--- stress toggles ---'
    echo 'STRESS_DLOPEN_THREADS=${STRESS_DLOPEN_THREADS}'
    echo 'STRESS_DLOPEN_THREADS_N=${STRESS_DLOPEN_THREADS_N}'
    echo 'STRESS_DLOPEN_ITERS=${STRESS_DLOPEN_ITERS}'
    echo 'STRESS_RTLD_COLLISION=${STRESS_RTLD_COLLISION}'
    echo 'STRESS_OPENSSL_TLS=${STRESS_OPENSSL_TLS}'
    echo
    echo 'SYSROOT_LINK_AUDIT=${SYSROOT_LINK_AUDIT}'
  "

  mark_tier_pass "report"
  tier_summary
}

tier_sanity() {
  mark_tier_start "sanity"
  need_paths
  need_qemu
  mkdirp "${WORK_DIR}"
  write_sources

  run_logged "provenance-gcc" bash -lc "
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

  assert_sysroot_abi
  build_binaries
  assert_default_hardening
  assert_toolchain_runtime_libs
  inspect_elf "${WORK_DIR}/bin/hello_c"
  inspect_elf "${WORK_DIR}/bin/hello_cpp"
  run_logged "qemu-run-hello-c"   qemu_run "${WORK_DIR}/bin/hello_c"
  run_logged "qemu-run-hello-cpp" qemu_run "${WORK_DIR}/bin/hello_cpp"

  mark_tier_pass "sanity"
  tier_summary
}

tier_smoke() {
  mark_tier_start "smoke"
  need_paths
  need_qemu
  mkdirp "${WORK_DIR}"
  assert_sysroot_abi
  write_sources
  build_binaries
  assert_default_hardening
  assert_toolchain_runtime_libs

  if [[ "${STRESS_CPP}" == "1" ]]; then
    stress_cpp_compile
    run_logged "qemu-run-stress-cpp" qemu_run "${WORK_DIR}/bin/stress_cpp"
  fi

  run_logged "qemu-run-pthread" qemu_run "${WORK_DIR}/bin/pthread"
  run_logged "qemu-run-except"  qemu_run "${WORK_DIR}/bin/except"
  run_logged "qemu-run-atomics" qemu_run "${WORK_DIR}/bin/atomics"
  run_logged "qemu-run-dlopen"  qemu_run "${WORK_DIR}/bin/dlopen"
  run_logged "qemu-run-lto"     qemu_run "${WORK_DIR}/bin/lto_test"

  inspect_elf "${WORK_DIR}/bin/dso_catch"
  run_logged "qemu-run-dso-catch" bash -lc "
    set -e
    cd '${WORK_DIR}/bin'
    '${QEMU_AARCH64}' -L '${SYSROOT}' './dso_catch'
  "

  if [[ "${STRESS_DLOPEN_THREADS}" == "1" ]]; then
    run_logged "qemu-run-dlopen-threads" bash -lc "
      set -e
      cd '${WORK_DIR}/bin'
      '${QEMU_AARCH64}' -L '${SYSROOT}' './dlopen_threads' '${STRESS_DLOPEN_THREADS_N}' '${STRESS_DLOPEN_ITERS}' './libthrow.so'
    "
  fi

  if [[ "${STRESS_RTLD_COLLISION}" == "1" ]]; then
    run_logged "qemu-run-rtld-collision" bash -lc "
      set -e
      cd '${WORK_DIR}/bin'
      '${QEMU_AARCH64}' -L '${SYSROOT}' './rtld_collision'
    "
  fi

  mark_tier_pass "smoke"
  tier_summary
}

tier_nightly() {
  mark_tier_start "nightly"
  need_paths
  have_cmd strings || die "missing strings"
  mkdirp "${WORK_DIR}"
  write_sources
  build_binaries

  local sysroot_glibc
  sysroot_glibc="$(sysroot_glibc_version || true)"
  [[ -n "${sysroot_glibc}" ]] || die "could not determine sysroot glibc version from ${SYSROOT}"

  have_cmd ssh || die "missing ssh"
  have_cmd scp || die "missing scp"

  run_logged "pi-prepare" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "mkdir -p '${PI_TMPDIR}' && rm -f '${PI_TMPDIR}'/*"

  # Copy bins + required DSOs
  run_logged "pi-copy-bins" bash -lc "
    set -e
    scp -P '${PI_SSH_PORT}' '${WORK_DIR}/bin/'* '${PI_SSH}:${PI_TMPDIR}/'
    scp -P '${PI_SSH_PORT}' '${WORK_DIR}/lib/libthrow.so' '${PI_SSH}:${PI_TMPDIR}/'
    scp -P '${PI_SSH_PORT}' '${WORK_DIR}/lib/libsym_a.so' '${PI_SSH}:${PI_TMPDIR}/'
    scp -P '${PI_SSH_PORT}' '${WORK_DIR}/lib/libsym_b.so' '${PI_SSH}:${PI_TMPDIR}/'
  "

  run_logged "pi-run-suite" ssh -p "${PI_SSH_PORT}" "${PI_SSH}" "
    set -e
    cd '${PI_TMPDIR}'

    pi_glibc=\$(getconf GNU_LIBC_VERSION | sed -nE 's/^glibc[[:space:]]+([0-9]+([.][0-9]+)+).*/\\1/p')
    echo \"sysroot-glibc=${sysroot_glibc}\"
    echo \"pi-glibc=\${pi_glibc}\"
    if [[ -z \"\${pi_glibc}\" || \"\${pi_glibc}\" != '${sysroot_glibc}' ]]; then
      echo \"ERROR: sysroot/Pi glibc mismatch\"
      exit 9
    fi

    './hello_c'
    './hello_cpp'
    './pthread'
    './except'
    './atomics'
    './dlopen'
    './lto_test'
    './dso_catch'

    if [[ '${STRESS_DLOPEN_THREADS}' == '1' ]]; then
      './dlopen_threads' '${STRESS_DLOPEN_THREADS_N}' '${STRESS_DLOPEN_ITERS}' './libthrow.so'
    fi

    if [[ '${STRESS_RTLD_COLLISION}' == '1' ]]; then
      './rtld_collision'
    fi
  "

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

  if [[ "${RUN_NIGHTLY:-0}" == "1" || "${A_PLUS}" == "1" ]]; then
    tier_nightly
  else
    log "RUN_NIGHTLY=0 and A_PLUS=0: skipping nightly in all"
  fi

  tier_summary
}

usage() {
  cat <<EOF
test-cross-toolchain.sh (version ${SCRIPT_VERSION})

Usage:
  $0 report
  $0 sanity
  $0 smoke
  $0 nightly
  $0 all
  $0 fetch-integration-hashes

One-liner A+ run:
  A_PLUS=1 $0 nightly

Key env (common):
  TARGET=${TARGET}
  TC_PREFIX=${TC_PREFIX}
  SYSROOT=${SYSROOT}
  QEMU_AARCH64=${QEMU_AARCH64}
  FRESH_LOGS=1              (default; clears prior logs/status at start of a run)

Nightly (runs on Pi):
  PI_SSH=${PI_SSH}
  PI_SSH_PORT=${PI_SSH_PORT}
  PI_TMPDIR=${PI_TMPDIR}
  RUN_NIGHTLY=1             (include nightly in $0 all; A_PLUS=1 also includes it)

Integration:
  INTEGRATION=1
  INTEGRATION_RUN_ON_PI=1
  PI_NET_TEST=1
  PI_NET_TEST_URL=https://example.com
  PI_TLS_SELFCONTAINED=1    (stages sysroot CA bundle + uses CURL_CA_BUNDLE on Pi)
  VERIFY_INTEGRATION_DOWNLOADS=1
  VERIFY_INTEGRATION_GPG=1  (requires trusted upstream signing keys; set 0 only for bootstrap/debug)
  ZLIB_SHA256=...
  OPENSSL_SHA256=...
  CURL_SHA256=...

Rare-failure stressors:
  STRESS_DLOPEN_THREADS=1
  STRESS_DLOPEN_THREADS_N=4
  STRESS_DLOPEN_ITERS=250
  STRESS_RTLD_COLLISION=1
  STRESS_OPENSSL_TLS=1      (runs on Pi during integration run)

Equivalent explicit A+ run:
  INTEGRATION=1 INTEGRATION_RUN_ON_PI=1 PI_NET_TEST=1 PI_TLS_SELFCONTAINED=1 \\
  STRESS_DLOPEN_THREADS=1 STRESS_DLOPEN_THREADS_N=4 STRESS_DLOPEN_ITERS=500 \\
  STRESS_RTLD_COLLISION=1 STRESS_OPENSSL_TLS=1 \\
  $0 nightly
EOF
}

main() {
  echo "Version: ${SCRIPT_VERSION}"

  local cmd="${1:-}"
  case "${cmd}" in
    fetch-integration-hashes) print_integration_hashes ;;
    report)  reset_logs_for_run; tier_report ;;
    sanity)  reset_logs_for_run; tier_sanity ;;
    smoke)   reset_logs_for_run; tier_smoke ;;
    nightly) reset_logs_for_run; tier_nightly ;;
    all)     reset_logs_for_run; tier_all ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
