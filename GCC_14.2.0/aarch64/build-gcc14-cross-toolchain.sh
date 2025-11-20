#!/usr/bin/env bash
set -euo pipefail

########################################################################
# Configuration
########################################################################

# Versions
GCC_VER=14.2.0
BINUTILS_VER=2.44
GLIBC_VER=2.41
LINUX_VER=6.1.21
LINUX_MAINLINE_VER=6.1

# Triplet & paths
TARGET=aarch64-linux-gnu
PREFIX=/opt/gcc-14-cross
SYSROOT="${PREFIX}/${TARGET}-sysroot"

# Working dirs (relative to script directory)
TOP_DIR="${PWD}"
SRC_DIR="${TOP_DIR}/src"
BUILD_DIR="${TOP_DIR}/build"
LOG_DIR="${TOP_DIR}/logs"

# Parallelism
NPROC="$(nproc || echo 4)"

# Where to fetch GNU tarballs from (can be changed to a local mirror)
GNU_MIRROR="https://ftp.gnu.org/gnu"

########################################################################
# Helpers
########################################################################

log_step() {
    local name="$1"
    shift
    echo
    echo "================================================================"
    echo "==> ${name}"
    echo "================================================================"
    "$@" 2>&1 | tee "${LOG_DIR}/${name}.log"
}

ensure_dirs() {
    # Start from a clean sysroot each run for reproducibility.
    rm -rf "${SYSROOT}"
    mkdir -p "${SRC_DIR}" "${BUILD_DIR}" "${LOG_DIR}" "${SYSROOT}"
}

export_basic_env() {
    # Host tools
    export PATH="${PREFIX}/bin:${PATH}"
    export LC_ALL=C
    umask 022
}

########################################################################
# Optional: install Debian build dependencies
########################################################################

install_deps_debian() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "Installing Debian build dependencies (requires sudo)..."
        sudo apt-get update
        sudo apt-get install -y \
            build-essential wget curl ca-certificates \
            bison flex texinfo \
            gawk libgmp-dev libmpfr-dev libmpc-dev libisl-dev \
            libzstd-dev zlib1g-dev \
            python3
    else
        echo "apt-get not found; please ensure equivalent build deps are installed."
    fi
}

########################################################################
# Download sources
########################################################################

download_sources() {
    cd "${SRC_DIR}"

    # Binutils
    if [[ ! -f "binutils-${BINUTILS_VER}.tar.xz" ]]; then
        wget "${GNU_MIRROR}/binutils/binutils-${BINUTILS_VER}.tar.xz"
    fi
    [[ -d "binutils-${BINUTILS_VER}" ]] || tar xf "binutils-${BINUTILS_VER}.tar.xz"

    # GCC
    if [[ ! -f "gcc-${GCC_VER}.tar.xz" ]]; then
        wget "${GNU_MIRROR}/gcc/gcc-${GCC_VER}/gcc-${GCC_VER}.tar.xz"
    fi
    if [[ ! -d "gcc-${GCC_VER}" ]]; then
        tar xf "gcc-${GCC_VER}.tar.xz"
        # Get GCC prerequisites (gmp/mpfr/mpc/isl as in-tree libs)
        (cd "gcc-${GCC_VER}" && ./contrib/download_prerequisites)
    fi

    # Glibc
    if [[ ! -f "glibc-${GLIBC_VER}.tar.xz" ]]; then
        wget "${GNU_MIRROR}/glibc/glibc-${GLIBC_VER}.tar.xz"
    fi
    [[ -d "glibc-${GLIBC_VER}" ]] || tar xf "glibc-${GLIBC_VER}.tar.xz"

    # Linux kernel (for headers)
    if [[ ! -f "linux-${LINUX_VER}.tar.xz" ]]; then
        wget "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VER}.tar.xz"
    fi
    [[ -d "linux-${LINUX_VER}" ]] || tar xf "linux-${LINUX_VER}.tar.xz"
}

########################################################################
# Step 1: Install Linux headers into sysroot (for AArch64)
########################################################################

install_linux_headers() {
    local bdir="${BUILD_DIR}/linux-headers"
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    cd "${bdir}"

    log_step "linux-headers" \
        make -C "${SRC_DIR}/linux-${LINUX_VER}" \
            ARCH=arm64 \
            INSTALL_HDR_PATH="${SYSROOT}/usr" \
            headers_install
}

########################################################################
# Step 2: Build Binutils for TARGET
########################################################################

build_binutils() {
    local bdir="${BUILD_DIR}/binutils-${BINUTILS_VER}"
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    cd "${bdir}"

    log_step "binutils-configure" \
        "${SRC_DIR}/binutils-${BINUTILS_VER}/configure" \
            --target="${TARGET}" \
            --prefix="${PREFIX}" \
            --with-sysroot="${SYSROOT}" \
            --disable-multilib \
            --disable-nls \
            --disable-werror

    log_step "binutils-make" make -j"${NPROC}"
    log_step "binutils-install" make install
}

########################################################################
# Step 3: Build GCC stage1 (no headers, C only, libc-independent)
########################################################################

build_gcc_stage1() {
    local bdir="${BUILD_DIR}/gcc-${GCC_VER}-stage1"
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    cd "${bdir}"

    export_basic_env

    # Minimal, libc-free cross GCC (LFS-style pass 1) for AArch64.
    log_step "gcc-stage1-configure" \
        "${SRC_DIR}/gcc-${GCC_VER}/configure" \
            --target="${TARGET}" \
            --prefix="${PREFIX}" \
            --with-glibc-version="${GLIBC_VER}" \
            --with-sysroot="${SYSROOT}" \
            --with-newlib \
            --without-headers \
            --disable-nls \
            --disable-shared \
            --disable-multilib \
            --disable-decimal-float \
            --disable-threads \
            --disable-libatomic \
            --disable-libgomp \
            --disable-libquadmath \
            --disable-libssp \
            --disable-libvtv \
            --disable-libstdcxx \
            --enable-languages=c \
            --with-arch=armv8-a \
            --with-tune=cortex-a72

    # Only build what we need: compiler + target libgcc
    log_step "gcc-stage1-make-all-gcc" \
        make -j"${NPROC}" all-gcc

    log_step "gcc-stage1-make-all-target-libgcc" \
        make -j"${NPROC}" all-target-libgcc

    log_step "gcc-stage1-install-gcc" \
        make install-gcc

    log_step "gcc-stage1-install-target-libgcc" \
        make install-target-libgcc

    # Create internal limits.h (same idea as LFS) so glibc build has a
    # sane <limits.h> from this compiler.
    echo
    echo "================================================================"
    echo "==> gcc-stage1: creating internal limits.h"
    echo "================================================================"

    local libgcc_file libgcc_dir
    libgcc_file="$("${TARGET}-gcc" -print-libgcc-file-name)"
    libgcc_dir="$(dirname "${libgcc_file}")"

    mkdir -p "${libgcc_dir}/install-tools/include"

    cat "${SRC_DIR}/gcc-${GCC_VER}/gcc/limitx.h" \
        "${SRC_DIR}/gcc-${GCC_VER}/gcc/glimits.h" \
        "${SRC_DIR}/gcc-${GCC_VER}/gcc/limity.h" > \
        "${libgcc_dir}/install-tools/include/limits.h"
}

########################################################################
# Step 4: Glibc headers + start files (for AArch64)
########################################################################

build_glibc_headers_startfiles() {
    local bdir="${BUILD_DIR}/glibc-${GLIBC_VER}-headers"
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    cd "${bdir}"

    export_basic_env

    # Use the just-built cross-compiler
    export CC="${TARGET}-gcc"
    export CXX="${TARGET}-g++"
    export AR="${TARGET}-ar"
    export RANLIB="${TARGET}-ranlib"
    export LD="${TARGET}-ld"

    # Cross-style glibc: prefix=/usr, install into SYSROOT via DESTDIR.
    log_step "glibc-headers-configure" \
        "${SRC_DIR}/glibc-${GLIBC_VER}/configure" \
            --host="${TARGET}" \
            --build=$("${SRC_DIR}/glibc-${GLIBC_VER}/scripts/config.guess") \
            --prefix=/usr \
            --with-headers="${SYSROOT}/usr/include" \
            --disable-multilib \
            --enable-kernel="$LINUX_MAINLINE_VER"

    # Install headers (bootstrap mode)
    log_step "glibc-headers-make-install-headers" \
        make install-bootstrap-headers=yes install-headers DESTDIR="${SYSROOT}"

    # Create dummy libc.so
    mkdir -p "${SYSROOT}/usr/lib"
    touch "${SYSROOT}/usr/lib/libc.so"

    # Build csu objects (crt1.o, crti.o, crtn.o) in the build tree
    log_step "glibc-headers-make-csu" \
        make -j1 csu/subdir_lib

    install -D csu/crt1.o   "${SYSROOT}/usr/lib/crt1.o"
    install -D csu/crti.o   "${SYSROOT}/usr/lib/crti.o"
    install -D csu/crtn.o   "${SYSROOT}/usr/lib/crtn.o"

    # A minimal libc_nonshared.a is often useful; full glibc will replace it.
    if [[ -f "libc_nonshared.a" ]]; then
        install -D libc_nonshared.a "${SYSROOT}/usr/lib/libc_nonshared.a"
    fi

    # Make sure <gnu/stubs.h> exists so features.h can include it
    mkdir -p "${SYSROOT}/usr/include/gnu"
    touch "${SYSROOT}/usr/include/gnu/stubs.h"
}

########################################################################
# Step 5: Build full Glibc for AArch64
########################################################################

build_glibc_full() {
    local bdir="${BUILD_DIR}/glibc-${GLIBC_VER}-full"
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    cd "${bdir}"

    export_basic_env
    export CC="${TARGET}-gcc"
    export CXX="${TARGET}-g++"
    export AR="${TARGET}-ar"
    export RANLIB="${TARGET}-ranlib"
    export LD="${TARGET}-ld"

    log_step "glibc-full-configure" \
        "${SRC_DIR}/glibc-${GLIBC_VER}/configure" \
            --host="${TARGET}" \
            --build=$("${SRC_DIR}/glibc-${GLIBC_VER}/scripts/config.guess") \
            --prefix=/usr \
            --with-headers="${SYSROOT}/usr/include" \
            --disable-multilib \
            --enable-kernel="$LINUX_MAINLINE_VER"

    log_step "glibc-full-make" make -j"${NPROC}"
    log_step "glibc-full-install" \
        make install DESTDIR="${SYSROOT}"
}

########################################################################
# Step 6: GCC final cross compiler (no bootstrap)
########################################################################

build_gcc_final_cross() {
    local bdir="${BUILD_DIR}/gcc-${GCC_VER}-final"
    rm -rf "${bdir}"
    mkdir -p "${bdir}"
    cd "${bdir}"

    export_basic_env

    # Use system compilers as host/build compilers.
    unset CC CXX AR RANLIB LD
    export CC_FOR_BUILD=gcc
    export CC=gcc
    export CXX=g++

    log_step "gcc-final-configure" \
        "${SRC_DIR}/gcc-${GCC_VER}/configure" \
            --build="$(gcc -dumpmachine)" \
            --host="$(gcc -dumpmachine)" \
            --target="${TARGET}" \
            --prefix="${PREFIX}" \
            --with-sysroot="${SYSROOT}" \
            --disable-multilib \
            --disable-nls \
            --enable-languages=c,ada,c++,go,d,fortran,objc,obj-c++,m2,rust \
            --enable-shared \
            --enable-threads=posix \
            --enable-__cxa_atexit \
            --enable-linker-build-id \
            --with-arch=armv8-a \
            --with-tune=cortex-a72

    log_step "gcc-final-make" make -j"${NPROC}"
    log_step "gcc-final-install" make install
}

########################################################################
# Step 7: Sanity checks (cross)
########################################################################

sanity_test() {
    export_basic_env

    echo
    echo "================================================================"
    echo "==> Sanity test: ${TARGET}-gcc --version"
    echo "================================================================"
    "${TARGET}-gcc" --version || {
        echo "ERROR: ${TARGET}-gcc not found or not working"
        return 1
    }

    tmpdir="$(mktemp -d)"
    cat > "${tmpdir}/hello.c" << 'EOF'
#include <stdio.h>
int main(void) {
    printf("Hello from AArch64 cross GCC toolchain!\n");
    return 0;
}
EOF

    echo
    echo "================================================================"
    echo "==> Building AArch64 test program with ${TARGET}-gcc"
    echo "================================================================"
    "${TARGET}-gcc" -O2 -g -o "${tmpdir}/hello" "${tmpdir}/hello.c"

    echo "Test binary built for AArch64:"
    file "${tmpdir}/hello" || true

    echo
    echo "================================================================"
    echo "Cross toolchain appears to be usable."
    echo "Prefix : ${PREFIX}"
    echo "Sysroot: ${SYSROOT}"
    echo "Target : ${TARGET}"
    echo "================================================================"

    rm -rf "${tmpdir}"
}

########################################################################
# Main driver
########################################################################

main() {
    ensure_dirs
    export_basic_env

    # Uncomment if you want the script to install build deps on Debian:
    # install_deps_debian

    download_sources
    install_linux_headers
    build_binutils
    build_gcc_stage1
    build_glibc_headers_startfiles
    build_glibc_full
    build_gcc_final_cross
    sanity_test
}

main "$@"
