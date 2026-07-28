#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=mobile-voice-native.sh
source "${repo_root}/scripts/mobile-voice-native.sh"

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
prebuilt_root="${test_root}/toolchains/llvm/prebuilt"

assert_toolchain() {
  local host_os="$1"
  local host_arch="$2"
  local expected="$3"
  local actual
  actual="$(android_toolchain "$test_root" "$host_os" "$host_arch")"
  if [[ "$actual" != "${prebuilt_root}/${expected}" ]]; then
    echo "expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

mkdir -p "${prebuilt_root}/linux-x86_64"
assert_toolchain Linux x86_64 linux-x86_64
rm -rf "${prebuilt_root}/linux-x86_64"

mkdir -p "${prebuilt_root}/darwin-arm64" "${prebuilt_root}/darwin-x86_64"
assert_toolchain Darwin arm64 darwin-arm64
rm -rf "${prebuilt_root}/darwin-arm64"
assert_toolchain Darwin arm64 darwin-x86_64
assert_toolchain Darwin x86_64 darwin-x86_64
rm -rf "${prebuilt_root}/darwin-x86_64"

if android_toolchain "$test_root" Linux x86_64 >/dev/null 2>&1; then
  echo "missing Linux toolchain unexpectedly succeeded" >&2
  exit 1
fi

if android_toolchain "$test_root" Linux aarch64 >/dev/null 2>&1; then
  echo "unsupported host unexpectedly succeeded" >&2
  exit 1
fi

echo "mobile voice native toolchain selection tests passed"
