# Raspberry Pi 4B AArch64 Toolchain README

This directory contains scripts for building and validating production cross
toolchains for a Raspberry Pi 4B target.

Target platform:

- Raspberry Pi 4B
- AArch64
- Debian 13 (trixie), glibc 2.41
- Raspberry Pi kernel 6.18.34+rpt-rpi-v8

Pinned toolchain inputs:

- GCC 15.3.0
- GNU binutils 2.46.1
- zlib 1.3.2 for integration validation
- OpenSSL 3.5.7 for integration validation
- curl 8.20.0 for integration validation

The production GCC/glibc build now defaults to the strict path:

- `INSTALL_SYSROOT=1`: copy the validated sysroot into the toolchain prefix.
- `VERIFY_GPG=1`: verify GCC/binutils release signatures.
- `VERIFY_INTEGRATION_DOWNLOADS=1`: verify integration source SHA256 values.
- `VERIFY_INTEGRATION_GPG=1`: verify zlib/OpenSSL/curl release signatures.

Import and trust the upstream release-signing keys before building. For a
temporary bootstrap/debug run only, the GPG checks can be disabled with
`VERIFY_GPG=0` or `VERIFY_INTEGRATION_GPG=0`.

Before relying on the GPG checks, confirm imported key fingerprints from the
official project release pages for:

- GNU/GCC release signing keys
- GNU/binutils release signing keys
- zlib release signing keys
- OpenSSL release signing keys
- curl release signing keys

Keep a copy of the confirmed fingerprints with your release records. Do not
treat an arbitrary locally trusted key as sufficient provenance.

## Strongest GCC/glibc Validation

Run from this `aarch64` directory:

```sh
cd /root/GCC-toolchain-scripts/GCC_15.3.0/aarch64
```

Print candidate source hashes if updating pinned versions:

```sh
gcc/build-cross-toolchain.sh fetch-hashes
gcc/test-cross-toolchain.sh fetch-integration-hashes
```

Run the host preflight check:

```sh
gcc/build-cross-toolchain.sh verify-host
```

This must pass with `VERIFY_GPG=1` before a production build. If it fails on
missing `gpg` or untrusted keys, install/import the signing keys rather than
disabling verification.

Build the production cross toolchain:

```sh
sudo -E CLEAN_PREFIX=1 gcc/build-cross-toolchain.sh build
```

The build installs to `/opt/gcc-15.3.0-cross` by default and writes:

```text
/opt/gcc-15.3.0-cross/toolchain-manifest.txt
/opt/gcc-15.3.0-cross/aarch64-linux-gnu/sysroot
```

Run the full local validation suite against the installed sysroot:

```sh
SYSROOT=/opt/gcc-15.3.0-cross/aarch64-linux-gnu/sysroot \
  gcc/test-cross-toolchain.sh all
```

Run the strongest final validation, including Raspberry Pi execution,
integration builds, TLS checks, and stress tests:

```sh
SYSROOT=/opt/gcc-15.3.0-cross/aarch64-linux-gnu/sysroot \
  A_PLUS=1 gcc/test-cross-toolchain.sh all
```

This `A_PLUS=1` run enables:

- `INTEGRATION=1`
- `INTEGRATION_RUN_ON_PI=1`
- `PI_NET_TEST=1`
- `PI_TLS_SELFCONTAINED=1`
- threaded `dlopen` stress
- RTLD collision stress
- OpenSSL TLS handshake checks

## What The Tests Assert

The GCC/glibc test suite validates:

- compiler provenance and configured sysroot
- sysroot link purity
- sysroot glibc version and Pi glibc version match
- C and C++ execution under qemu
- C and C++ execution on the Pi
- pthreads, atomics, exceptions, `dlopen`, LTO, and DSO exception crossing
- fresh toolchain `libstdc++` and `libgcc_s` runtime usability
- default PIE, stack protector, RELRO, non-executable stack, `.gnu.hash`, and
  `BIND_NOW` behavior
- integration cross-builds for zlib, OpenSSL, and curl
- curl/OpenSSL TLS behavior on the Pi

Each run updates:

```text
gcc/logs-tests/validation-report.txt
```

## Musl Companion

The musl scripts remain available under `musl/`. Their validation commands are:

```sh
sudo -E CLEAN_PREFIX=1 musl/build-musl-cross-toolchain.sh build

LINK_MODE=dynamic SYSROOT_LINK_AUDIT=1 A_PLUS=1 \
  musl/test-musl-cross-toolchain.sh all

LINK_MODE=static SYSROOT_LINK_AUDIT=1 STRESS_CPP=1 STRESS_LTO_MATRIX=1 \
  musl/test-musl-cross-toolchain.sh all
```
