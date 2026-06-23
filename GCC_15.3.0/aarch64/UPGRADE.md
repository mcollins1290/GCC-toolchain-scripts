# GCC 15.3 cross-toolchain upgrade

Target platform:

- Raspberry Pi 4B
- AArch64
- Debian 13 (trixie), glibc 2.41
- Raspberry Pi kernel 6.18.34+rpt-rpi-v8

Pinned toolchain candidates:

- GCC 15.3.0
- GNU binutils 2.46.1
- musl 1.2.6
- Linux UAPI headers 6.18.36
- musl CVE-2026-6042 fix at commit
  `67219f0130ec7c876ac0b299046460fad31caabf`

The build scripts reject archives without an expected SHA256 value. Before the
first build, download the candidates and print their hashes:

```sh
gcc/build-cross-toolchain.sh fetch-hashes
musl/build-musl-cross-toolchain.sh fetch-hashes
```

Verify the resulting hashes against the corresponding upstream signatures,
then set the values in the scripts or export:

```sh
export GCC_SHA256=...
export BINUTILS_SHA256=...
export LINUX_SHA256=...
export MUSL_SHA256=...
export MUSL_ICONV_PATCH_SHA256=...
```

Build into the new parallel prefixes:

```sh
sudo -E CLEAN_PREFIX=1 gcc/build-cross-toolchain.sh build
sudo -E CLEAN_PREFIX=1 musl/build-musl-cross-toolchain.sh build
```

The default prefixes are `/opt/gcc-15.3.0-cross` and
`/opt/gcc-15.3.0-musl-cross`.

Run the local and Raspberry Pi validation suites:

```sh
gcc/test-cross-toolchain.sh sanity
gcc/test-cross-toolchain.sh smoke
A_PLUS=1 gcc/test-cross-toolchain.sh nightly

LINK_MODE=dynamic SYSROOT_LINK_AUDIT=1 A_PLUS=1 \
  musl/test-musl-cross-toolchain.sh all

LINK_MODE=static SYSROOT_LINK_AUDIT=1 STRESS_CPP=1 STRESS_LTO_MATRIX=1 \
  musl/test-musl-cross-toolchain.sh all
```
