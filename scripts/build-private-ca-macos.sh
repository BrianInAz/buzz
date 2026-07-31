#!/usr/bin/env bash

set -euo pipefail

readonly upstream_repository="https://github.com/block/buzz.git"
readonly fork_repository="https://github.com/BrianInAz/buzz.git"
readonly patch_commit="6d03a38da5e3402bf97df1b3c46152887eb3778e"

tag="${1:?usage: $0 <upstream-tag> <upstream-sha> [output-directory]}"
source_sha="${2:?usage: $0 <upstream-tag> <upstream-sha> [output-directory]}"
output_directory="${3:-$PWD/dist/private-ca/${tag}}"

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "this packaging helper must run on macOS" >&2
  exit 1
}

for command in git just pnpm codesign hdiutil shasum; do
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
git -C "${work_directory}/source" fetch --depth 2 "${fork_repository}" "${patch_commit}"
git -C "${work_directory}/source" cherry-pick --no-commit "${patch_commit}"
git -C "${work_directory}/source" diff --check

(
  cd "${work_directory}/source"
  just desktop-install-ci
  just _ensure-sidecar-stubs
  cat > desktop/src-tauri/tauri.private-ca.conf.json <<'EOF'
{ "bundle": { "macOS": { "minimumSystemVersion": "10.15" }, "createUpdaterArtifacts": false } }
EOF
  cd desktop
  pnpm tauri build --verbose --no-sign --features mesh-llm --config src-tauri/tauri.private-ca.conf.json
)

app_path="${work_directory}/source/desktop/src-tauri/target/release/bundle/macos/Buzz.app"
dmg_path="${output_directory}/Buzz-${tag}-private-ca-arm64.dmg"
codesign --force --deep --sign - "${app_path}"
codesign --verify --deep --strict --verbose=2 "${app_path}"
cp -R "${app_path}" "${output_directory}/dmg-root/Buzz.app"
hdiutil create -volname Buzz -srcfolder "${output_directory}/dmg-root" -ov -format UDZO "${dmg_path}"

cat > "${output_directory}/manifest.json" <<EOF
{"upstream_tag":"${tag}","upstream_sha":"${source_sha}","patch_sha":"${patch_commit}","result_tree_sha":"$(git -C "${work_directory}/source" write-tree)","architecture":"$(uname -m)"}
EOF
git -C "${work_directory}/source" diff --binary "${source_sha}" > "${output_directory}/private-ca.patch"
(
  cd "${output_directory}"
  shasum -a 256 "$(basename "${dmg_path}")" manifest.json private-ca.patch > SHA256SUMS
)

rm -rf "${output_directory}/dmg-root"
echo "private-CA package written to ${output_directory}"
