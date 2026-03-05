#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# test-gcc14-cross-toolchain.sh
#
# Run the following tests and if all are clean then toolchain is good:
#
# ./test-gcc14-cross-toolchain.sh sanity
# ./test-gcc14-cross-toolchain.sh smoke
# A_PLUS=1 ./test-gcc14-cross-toolchain.sh nightly
# ==============================================================================

SCRIPT_VERSION="v0.0.19"

# ------------------------------ Defaults --------------------------------------
TARGET="${TARGET:-aarch64-linux-gnu}"
TC_PREFIX="${TC_PREFIX:-/opt/gcc-14.2.0-cross}"
SYSROOT="${SYSROOT:-/build-rpi/rpi/sysroot}"

QEMU_AARCH64="${QEMU_AARCH64:-qemu-aarch64}"

PI_SSH="${PI_SSH:-root@raspberrypi2.totten}"
PI_SSH_PORT="${PI_SSH_PORT:-22}"
PI_TMPDIR="${PI_TMPDIR:-/tmp/gcc14-toolchain-tests}"

INTEGRATION="${INTEGRATION:-0}"
INTEGRATION_RUN_ON_PI="${INTEGRATION_RUN_ON_PI:-0}"
PI_INTEGRATION_DIR="${PI_INTEGRATION_DIR:-/tmp/gcc14-toolchain-integration}"

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

OPENSSL_VER="${OPENSSL_VER:-3.3.2}"
OPENSSL_URL="${OPENSSL_URL:-https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz}"

CURL_VER="${CURL_VER:-8.11.1}"
CURL_URL="${CURL_URL:-https://curl.se/download/curl-${CURL_VER}.tar.gz}"

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
  STRESS_DLOPEN_THREADS_N="${STRESS_DLOPEN_THREADS_N:-4}"
  STRESS_DLOPEN_ITERS="${STRESS_DLOPEN_ITERS:-500}"

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
    [[ -n "${TIER_STATUS_DIR}" ]] && echo "FAIL" > "${TIER_STATUS_DIR}/${CURRENT_TIER}.status" 2>/dev/null || true
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
}

# ------------------------------ Helpers ---------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
mkdirp() { mkdir -p "$@"; }

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

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
  [[ -e "${SYSROOT}/lib/ld-linux-aarch64.so.1" ]] || die "missing sysroot loader: ${SYSROOT}/lib/ld-linux-aarch64.so.1"
}

need_qemu() {
  have_cmd "${QEMU_AARCH64}" || die "missing ${QEMU_AARCH64}. Install qemu-user (Debian: apt install qemu-user)"
}

tc() { "${TC_PREFIX}/bin/${TARGET}-$@"; }
qemu_run() { "${QEMU_AARCH64}" -L "${SYSROOT}" "$@"; }

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

extract() {
  local tarball="$1"
  local dest="$2"
  mkdirp "$(dirname "$dest")"
  rm -rf "$dest"
  local tmp
  tmp="$(mktemp -d)"
  tar -xf "$tarball" -C "$tmp"
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
    -ldl -Wl,-rpath,'$ORIGIN/../lib'

  # Make dlopen("./libthrow.so") succeed when running from WORK_DIR/bin
  run_logged "build-libthrow-symlink" bash -lc "
    set -e
    ln -sf ../lib/libthrow.so '${WORK_DIR}/bin/libthrow.so'
    ls -l '${WORK_DIR}/bin/libthrow.so'
  "

  # Threaded dlopen stress binary
  run_logged "build-dlopen-threads" tc g++ "${sys[@]}" "${cflags[@]}" \
    "${WORK_DIR}/src/dlopen_threads.cpp" -o "${WORK_DIR}/bin/dlopen_threads" \
    -ldl -pthread -Wl,-rpath,'$ORIGIN/../lib'

  # RTLD collision artifacts
  run_logged "build-libsym-a" tc gcc "${sys[@]}" "${cflags[@]}" -fPIC -shared \
    -Wl,-soname,libsym_a.so \
    "${WORK_DIR}/src/sym_a.c" -o "${WORK_DIR}/lib/libsym_a.so"
  run_logged "build-libsym-b" tc gcc "${sys[@]}" "${cflags[@]}" -fPIC -shared \
    -Wl,-soname,libsym_b.so \
    "${WORK_DIR}/src/sym_b.c" -o "${WORK_DIR}/lib/libsym_b.so"
  run_logged "build-rtld-collision" tc gcc "${sys[@]}" "${cflags[@]}" \
    "${WORK_DIR}/src/rtld_collision.c" -o "${WORK_DIR}/bin/rtld_collision" \
    -ldl -Wl,-rpath,'$ORIGIN/../lib'

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
  export LD="${TC_PREFIX}/bin/${TARGET}-ld"
  export CFLAGS="${CFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export CXXFLAGS="${CXXFLAGS:--O2 -pipe} --sysroot=${SYSROOT}"
  export LDFLAGS="${LDFLAGS:-} --sysroot=${SYSROOT}"

  export PKG_CONFIG_SYSROOT_DIR="${SYSROOT}"
  export PKG_CONFIG_LIBDIR="${SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${SYSROOT}/usr/share/pkgconfig:${INSTALL_DIR}/lib/pkgconfig:${INSTALL_DIR}/share/pkgconfig"
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

integration_fixup_curl_rpath() {
  local curl_bin="${INSTALL_DIR}/bin/curl"
  [[ -x "${curl_bin}" ]] || die "curl binary not found at: ${curl_bin}"
  have_cmd readelf || die "missing readelf"
  have_cmd grep || die "missing grep"

  local wanted_runpath='$ORIGIN/../lib:$ORIGIN/../lib64'

  run_logged "integration-fixup-curl-rpath" bash -lc "
    set -e
    echo 'before:'
    readelf -d '${curl_bin}' | grep -E 'RPATH|RUNPATH' || true
  "

  if have_cmd patchelf; then
    patchelf --set-rpath "${wanted_runpath}" "${curl_bin}"
  elif have_cmd chrpath; then
    chrpath -r "${wanted_runpath}" "${curl_bin}"
  else
    echo
    echo "ERROR: need patchelf or chrpath on host to fix RPATH/RUNPATH"
    return 2
  fi
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
  integration_fixup_curl_rpath

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
    ls -l '${SYSROOT}/lib/ld-linux-aarch64.so.1' || true
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

  build_binaries
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
  write_sources
  build_binaries

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
  mkdirp "${WORK_DIR}"
  write_sources
  build_binaries

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

usage() {
  cat <<EOF
test-gcc14-cross-toolchain.sh (version ${SCRIPT_VERSION})

Usage:
  $0 report
  $0 sanity
  $0 smoke
  $0 nightly

One-liner A+ run:
  A_PLUS=1 $0 nightly

Key env (common):
  TARGET=${TARGET}
  TC_PREFIX=${TC_PREFIX}
  SYSROOT=${SYSROOT}
  QEMU_AARCH64=${QEMU_AARCH64}

Nightly (runs on Pi):
  PI_SSH=${PI_SSH}
  PI_SSH_PORT=${PI_SSH_PORT}
  PI_TMPDIR=${PI_TMPDIR}

Integration:
  INTEGRATION=1
  INTEGRATION_RUN_ON_PI=1
  PI_NET_TEST=1
  PI_NET_TEST_URL=https://example.com
  PI_TLS_SELFCONTAINED=1    (stages sysroot CA bundle + uses CURL_CA_BUNDLE on Pi)

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
  need_paths

  local cmd="${1:-}"
  case "${cmd}" in
    report)  tier_report ;;
    sanity)  tier_sanity ;;
    smoke)   tier_smoke ;;
    nightly) tier_nightly ;;
    ""|help|-h|--help) usage ;;
    *) die "unknown command: ${cmd}" ;;
  esac
}

main "$@"
