#!/usr/bin/env bash

set -euo pipefail

readonly upstream_repository="https://github.com/block/buzz.git"
readonly fork_repository="https://github.com/BrianInAz/buzz.git"
readonly private_ca_patch_commit="6d03a38da5e3402bf97df1b3c46152887eb3778e"
readonly security_patch_commit="7dbfcd785be0a9c002863a793c4fbab89a6258c3"

tag="${1:?usage: $0 <upstream-tag> <upstream-sha> [output-directory]}"
source_sha="${2:?usage: $0 <upstream-tag> <upstream-sha> [output-directory]}"
output_directory="${3:-$PWD/dist/private-ca/${tag}}"

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "this packaging helper must run on macOS" >&2
  exit 1
}
[[ "$(uname -m)" == "arm64" ]] || {
  echo "this packaging helper requires Apple Silicon" >&2
  exit 1
}

for command in git just pnpm cargo-deny codesign hdiutil shasum; do
  command -v "${command}" >/dev/null || {
    echo "required command is unavailable: ${command}" >&2
    exit 1
  }
done

work_directory="$(mktemp -d)"
cleanup() {
  rm -rf "${work_directory}"
}
trap cleanup EXIT

mkdir -p "${output_directory}/dmg-root"
git clone --depth 1 --branch "${tag}" "${upstream_repository}" "${work_directory}/source"
[[ "$(git -C "${work_directory}/source" rev-parse HEAD)" == "${source_sha}" ]] || {
  echo "upstream tag did not resolve to the approved SHA" >&2
  exit 1
}
for patch_commit in "${private_ca_patch_commit}" "${security_patch_commit}"; do
  git -C "${work_directory}/source" fetch --depth 2 "${fork_repository}" "${patch_commit}"
  git -C "${work_directory}/source" cherry-pick --no-commit "${patch_commit}"
done
git -C "${work_directory}/source" diff --check

(
  cd "${work_directory}/source"
  cargo-deny --locked check --config deny.toml advisories
  cargo-deny --locked \
    --manifest-path desktop/src-tauri/Cargo.toml \
    --target aarch64-apple-darwin \
    --exclude-dev \
    check --config deny.toml advisories
  just desktop-install-ci
  just _ensure-sidecar-stubs
  sdk_manifest="$({
    cargo metadata --locked --manifest-path desktop/src-tauri/Cargo.toml \
      --features mesh-llm --format-version 1
  } | python3 -c 'import json, sys; data = json.load(sys.stdin); print(next(package["manifest_path"] for package in data["packages"] if package["name"] == "mesh-llm-sdk"))')"
  mesh_root="$(dirname "${sdk_manifest}")"
  while [[ "${mesh_root}" != "/" && ! -x "${mesh_root}/scripts/prepare-llama.sh" ]]; do
    mesh_root="$(dirname "${mesh_root}")"
  done
  [[ -x "${mesh_root}/scripts/prepare-llama.sh" && -x "${mesh_root}/scripts/build-llama.sh" ]] || {
    echo "mesh-llm native build scripts are unavailable" >&2
    exit 1
  }
  export LLAMA_STAGE_BACKEND=metal
  export LLAMA_STAGE_BUILD_DIR="${work_directory}/mesh-llama/build-stage-abi-metal"
  export CMAKE_OSX_DEPLOYMENT_TARGET=10.15
  "${mesh_root}/scripts/prepare-llama.sh" pinned
  "${mesh_root}/scripts/build-llama.sh" -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15
  cat > desktop/src-tauri/tauri.private-ca.conf.json <<'EOF'
{ "bundle": { "macOS": { "minimumSystemVersion": "10.15" }, "createUpdaterArtifacts": false } }
EOF
  cd desktop
  CMAKE_POLICY_VERSION_MINIMUM=3.5 \
    MACOSX_DEPLOYMENT_TARGET=10.15 \
    SKIPPY_LLAMA_AUTO_BUILD=0 \
    TAURI_BUNDLER_DMG_IGNORE_CI=true \
    pnpm tauri build --verbose --no-sign --features mesh-llm \
      --config src-tauri/tauri.private-ca.conf.json
)

app_path="${work_directory}/source/desktop/src-tauri/target/release/bundle/macos/Buzz.app"
dmg_path="${output_directory}/Buzz-${tag}-private-ca-arm64.dmg"
codesign --force --deep --sign - "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"
cp -R "${app_path}" "${output_directory}/dmg-root/Buzz.app"
hdiutil create -volname Buzz -srcfolder "${output_directory}/dmg-root" -ov -format UDZO "${dmg_path}"

cat > "${output_directory}/manifest.json" <<EOF
{"upstream_tag":"${tag}","upstream_sha":"${source_sha}","private_ca_patch_sha":"${private_ca_patch_commit}","security_patch_sha":"${security_patch_commit}","patch_shas":["${private_ca_patch_commit}","${security_patch_commit}"],"result_tree_sha":"$(git -C "${work_directory}/source" write-tree)","architecture":"$(uname -m)"}
EOF
git -C "${work_directory}/source" diff --binary "${source_sha}" > "${output_directory}/private-ca.patch"
(
  cd "${output_directory}"
  shasum -a 256 "$(basename "${dmg_path}")" manifest.json private-ca.patch > SHA256SUMS
)

rm -rf "${output_directory}/dmg-root"
echo "private-CA package written to ${output_directory}"
