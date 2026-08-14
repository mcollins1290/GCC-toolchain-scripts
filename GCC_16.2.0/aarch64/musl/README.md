# Raspberry Pi 4B AArch64 musl Toolchain README

This directory contains the musl companion scripts for building and validating
a production `aarch64-linux-musl` cross toolchain for a Raspberry Pi 4B target.

Pinned build inputs:

- GCC 16.2.0
- GNU binutils 2.46.1
- Linux headers 6.18.37
- musl 1.2.6 plus pinned CVE-2026-6042 iconv patch
- zlib 1.3.2 for integration validation
- OpenSSL 3.5.7 for integration validation
- curl 8.20.0 for integration validation

The production build defaults to:

- `VERIFY_GPG=1`: verify GCC, binutils, and musl release signatures.
- `ENABLE_DYNAMIC=1`: build shared and static GCC runtimes.
- `INSTALL_RUNTIME_TO_SYSROOT=1`: stage shared GCC runtimes into the musl sysroot.
- `DEFAULT_HASH_STYLE=gnu`: use GNU hash style by default.
- `BINUTILS_ZSTD=auto` and `GCC_ZSTD=auto`: enable zstd when the host supports it.
- `FRESH_LOGS=1`: clear stale build/test logs at the start of each run.
- `SOURCE_REFRESH=1`: re-extract verified source archives instead of trusting
  stale source trees.
- `INTEGRATION_SOURCE_REFRESH=1`: re-extract verified zlib/OpenSSL/curl
  integration sources before validation builds.

Import and trust upstream release-signing keys before using the default GPG
checks. For bootstrap/debug only, `VERIFY_GPG=0` or
`VERIFY_INTEGRATION_GPG=0` can be used, but that is not the production path.

Expected build-source signing primary fingerprints:

- GCC: `13975A70E63C361C73AE69EF6EEB81F8981C74C7`
- binutils: `5EF3A41171BB77E6110ED2D01F3D03348DB1A3E2`
- musl: `836489290BB6B70F99FFDA0556BCDB593020450F`

Expected integration-source signing fingerprints:

- zlib: `5ED46A6721D365587791E2AA783FCD8E58BCAFBA`
- OpenSSL: `BA5473A2B0587B07FB27CF2D216094DFD0CB81EF`
- curl: `27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2`

One way to import them:

```sh
gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys \
  13975A70E63C361C73AE69EF6EEB81F8981C74C7 \
  5EF3A41171BB77E6110ED2D01F3D03348DB1A3E2 \
  56BCDB593020450F \
  5ED46A6721D365587791E2AA783FCD8E58BCAFBA \
  BA5473A2B0587B07FB27CF2D216094DFD0CB81EF \
  27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2
```

Review the fingerprints after import and assign owner trust according to your
local release-management policy. The scripts assert these exact fingerprints
even when GPG owner trust is not configured. The musl key is fetched above by
its release-signing key ID because some keyservers do not resolve the full
fingerprint in bulk imports; after import, it must fingerprint as
`836489290BB6B70F99FFDA0556BCDB593020450F`.

## Strongest Build

Run from this `musl` directory:

```sh
cd /root/GCC-toolchain-scripts/GCC_16.2.0/aarch64/musl
```

Check the host first:

```sh
./build-musl-cross-toolchain.sh verify-host
```

Optionally check whether the pinned musl release is still current:

```sh
./build-musl-cross-toolchain.sh check-updates
```

Build the production dynamic-capable musl toolchain:

```sh
sudo -E CLEAN_PREFIX=1 ./build-musl-cross-toolchain.sh build
```

The default install writes:

```text
/opt/gcc-16.2.0-musl-cross
/opt/gcc-16.2.0-musl-cross/toolchain-manifest.txt
/opt/gcc-16.2.0-musl-cross/aarch64-linux-musl/sysroot
```

After a successful build, remove build-only workspace artifacts while keeping
the installed `/opt` toolchain available:

```sh
./build-musl-cross-toolchain.sh distclean
```

This removes this directory's generated build tree, extracted sources,
downloaded tarballs, build logs, and `.gnupg-build-verify` cache. It refuses to
remove the install prefix or sysroot.

Validation artifacts are owned by the test script. Remove only transient test
logs/work files:

```sh
./test-musl-cross-toolchain.sh clean
```

Remove all validation artifacts, including cached integration sources/builds:

```sh
./test-musl-cross-toolchain.sh distclean
```

## Strongest Validation

Run the full dynamic A+ validation:

```sh
A_PLUS=1 LINK_MODE=dynamic ./test-musl-cross-toolchain.sh all
```

This enables:

- integration builds for zlib, OpenSSL, and curl
- SHA256 and GPG verification for integration sources
- Raspberry Pi execution for compiled test programs
- Raspberry Pi execution for the staged musl OpenSSL/curl integration tree
- default and self-contained TLS checks
- OpenSSL command/library version assertions
- staged dependency assertions for curl and OpenSSL
- threaded `dlopen` stress
- RTLD symbol collision stress
- LTO matrix checks
- C++ ABI sanity checks
- strip/runtime sanity checks

For static-only validation, run a separate static pass:

```sh
LINK_MODE=static SYSROOT_LINK_AUDIT=1 STRESS_CPP=1 STRESS_LTO_MATRIX=1 \
  ./test-musl-cross-toolchain.sh all
```

The static pass asserts there is no `PT_INTERP` and no `DT_NEEDED` in static
test binaries.

Each build and validation run clears old logs by default. Validation also writes:

```text
logs-tests/validation-report.txt
```

Set `FRESH_LOGS=0` only when intentionally appending diagnostic logs.
