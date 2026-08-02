#!/usr/bin/env bash

set -euo pipefail

workflow=".github/workflows/private-ca-release.yml"
ci_workflow=".github/workflows/ci.yml"
docker_workflow=".github/workflows/docker.yml"
hosted_builder="scripts/build-private-ca-macos.sh"
tag_parser="scripts/normalize-private-ca-desktop-tag.sh"
lifecycle_doc="docs/operations/private-ca-desktop-release-lifecycle.md"

if [[ ! -f "${workflow}" ]]; then
  echo "missing ${workflow}" >&2
  exit 1
fi

require() {
  local expected="$1"
  if ! grep -F -q -- "${expected}" "${workflow}"; then
    echo "${workflow} must contain: ${expected}" >&2
    exit 1
  fi
}

forbid() {
  local prohibited="$1"
  if grep -i -F -q -- "${prohibited}" "${workflow}"; then
    echo "${workflow} must not contain: ${prohibited}" >&2
    exit 1
  fi
}

require_ci() {
  local expected="$1"
  if ! grep -F -q -- "${expected}" "${ci_workflow}"; then
    echo "${ci_workflow} must contain: ${expected}" >&2
    exit 1
  fi
}

forbid_ci() {
  local prohibited="$1"
  if grep -F -q -- "${prohibited}" "${ci_workflow}"; then
    echo "${ci_workflow} must not contain: ${prohibited}" >&2
    exit 1
  fi
}

require_docker() {
  local expected="$1"
  if ! grep -F -q -- "${expected}" "${docker_workflow}"; then
    echo "${docker_workflow} must contain: ${expected}" >&2
    exit 1
  fi
}

forbid_docker() {
  local prohibited="$1"
  if grep -F -q -- "${prohibited}" "${docker_workflow}"; then
    echo "${docker_workflow} must not contain: ${prohibited}" >&2
    exit 1
  fi
}

require_doc() {
  local expected="$1"
  if ! grep -F -q -- "${expected}" "${lifecycle_doc}"; then
    echo "${lifecycle_doc} must contain: ${expected}" >&2
    exit 1
  fi
}

require 'cron: "5 15 * * *"'
require 'issues:'
require 'labeled'
require 'workflow_dispatch:'
require 'contents: read'
require 'issues: write'
require "github.actor == 'BrianInAz'"
require "github.event.label.name == 'build-approved'"
require "github.event.label.name == 'skip'"
require 'refs/tags/'
require '6d03a38da5e3402bf97df1b3c46152887eb3778e'
require 'PRIVATE_CA_PATCH_COMMIT:'
require 'SECURITY_PATCH_COMMIT:'
require 'private_ca_patch_sha='
require 'security_patch_sha='
# shellcheck disable=SC2016 # These are intentionally literal workflow fragments.
require 'for patch_commit in "${PRIVATE_CA_PATCH_COMMIT}" "${SECURITY_PATCH_COMMIT}"'
# shellcheck disable=SC2016 # These are intentionally literal workflow fragments.
require '[[ "${private_ca_patch_sha}" == "${PRIVATE_CA_PATCH_COMMIT}" ]]'
# shellcheck disable=SC2016 # These are intentionally literal workflow fragments.
require '[[ "${security_patch_sha}" == "${SECURITY_PATCH_COMMIT}" ]]'
require 'cherry-pick --no-commit'
require 'cargo-deny --locked check --config deny.toml advisories'
require "cargo-deny --locked \\"
require "--manifest-path desktop/src-tauri/Cargo.toml \\"
require "--target aarch64-apple-darwin \\"
require "--exclude-dev \\"
require 'just ci'
require 'Stub Tauri sidecar binaries'
require 'desktop/src-tauri/binaries'
require 'gh issue close'
require 'runs-on: macos-15'
require 'Build private-CA package on standard hosted Apple Silicon'
require 'github.event.repository.private'
require 'actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a'
require 'retention-days: 7'
require 'if-no-files-found: error'
require 'GitHub-hosted macOS package built'
require "gh issue edit \"\${ISSUE_NUMBER}\" --repo \"\${GITHUB_REPOSITORY}\" --add-label built"
require 'scripts/build-private-ca-macos.sh'
require 'scripts/normalize-private-ca-desktop-tag.sh'
require '--assignee BrianInAz'
require 'ticket already exists'
require "github.event.label.name == 'accepted'"
require 'accepted requires the built lifecycle state'
require 'not a clean monitor-created ticket'
require "gh issue view \"\${ISSUE_NUMBER}\" --repo \"\${GITHUB_REPOSITORY}\""
require "gh issue comment \"\${ISSUE_NUMBER}\" --repo \"\${GITHUB_REPOSITORY}\""
require "gh issue close \"\${ISSUE_NUMBER}\" --repo \"\${GITHUB_REPOSITORY}\""

forbid 'BUZZ_TEST_WSS_URL'
forbid 'buzz.bjzy.me'
forbid 'insecure_skip_verify'
forbid 'tailscale'
forbid 'VAULT_'
forbid 'APPLE_CERTIFICATE'
forbid 'TAURI_SIGNING_PRIVATE_KEY'
forbid 'Local macOS package handoff'
forbid 'approved local Mac'
forbid "github.event.label.name == 'built'"
forbid 'id-token: write'
forbid 'secrets.'
forbid 'actions/attest-build-provenance@'
forbid 'gh release create'
forbid ' patch_sha='

if grep -Eq '^  PATCH_COMMIT:' "${workflow}"; then
  echo "${workflow} must not use the legacy single PATCH_COMMIT input" >&2
  exit 1
fi

require_ci 'cargo metadata --locked --manifest-path desktop/src-tauri/Cargo.toml --features mesh-llm --format-version 1'
require_ci 'package["manifest_path"] for package in data["packages"] if package["name"] == "mesh-llm-sdk"'
require_ci 'tomllib.load(open("desktop/src-tauri/Cargo.lock", "rb"))'
forbid_ci 'tomllib.load(open("Cargo.lock", "rb"))'
# shellcheck disable=SC2016 # This is an intentionally literal workflow fragment.
forbid_ci 'find "${CARGO_HOME:-$HOME/.cargo}/git/checkouts"'

# Pull requests are build-only. They may read registry caches, but must not
# authenticate to GHCR or try to export caches into an upstream namespace.
require_docker "if: github.event_name != 'pull_request'"
forbid_docker "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"
require_docker "if: github.event_name == 'pull_request' || github.repository == 'block/buzz'"
require_docker "if: github.event_name != 'pull_request' && github.repository == 'block/buzz'"

require_doc "standard GitHub-hosted \`macos-15\` Apple Silicon runner"
require_doc 'standard hosted runners as free and'
require_doc 'unlimited for public repositories'
require_doc "Brian then downloads the exact artifact to his MacBook"

if [[ ! -x "${hosted_builder}" ]]; then
  echo "missing executable ${hosted_builder}" >&2
  exit 1
fi

if [[ ! -x "${tag_parser}" ]]; then
  echo "missing executable ${tag_parser}" >&2
  exit 1
fi

for tag in v0.5.2 desktop-v0.5.3; do
  if [[ "$("${tag_parser}" "${tag}")" != "${tag}" ]]; then
    echo "${tag_parser} must accept stable desktop tag ${tag}" >&2
    exit 1
  fi
done

for tag in relay-v0.5.3 desktop-v0.5.3-rc.1 v0.5.3-beta.1 nonsense; do
  if "${tag_parser}" "${tag}" >/dev/null 2>&1; then
    echo "${tag_parser} must reject non-stable desktop tag ${tag}" >&2
    exit 1
  fi
done

# shellcheck disable=SC2016 # These are intentionally literal builder fragments.
for expected in 'set -euo pipefail' "[[ \"\$(uname -m)\" == \"arm64\" ]]" 'private_ca_patch_commit=' 'security_patch_commit=' 'for patch_commit in "${private_ca_patch_commit}" "${security_patch_commit}"' 'cargo-deny --locked check --config deny.toml advisories' "--target aarch64-apple-darwin \\" '"patch_shas":[' 'cargo metadata --locked --manifest-path' 'prepare-llama.sh' 'build-llama.sh' 'SKIPPY_LLAMA_AUTO_BUILD=0' 'createUpdaterArtifacts": false' 'codesign --force --deep --sign -' 'codesign --verify --deep --strict' 'hdiutil create'; do
  if ! grep -F -q -- "${expected}" "${hosted_builder}"; then
    echo "${hosted_builder} must contain: ${expected}" >&2
    exit 1
  fi
done

if grep -i -F -q -- 'insecure_skip_verify' "${hosted_builder}"; then
  echo "${hosted_builder} must not bypass TLS verification" >&2
  exit 1
fi

echo "private CA release workflow contract passed"
