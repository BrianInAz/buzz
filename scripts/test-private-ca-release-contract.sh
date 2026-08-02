#!/usr/bin/env bash

set -euo pipefail

workflow=".github/workflows/private-ca-release.yml"
local_builder="scripts/build-private-ca-macos.sh"
tag_parser="scripts/normalize-private-ca-desktop-tag.sh"

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
require 'cherry-pick --no-commit'
require 'just ci'
require 'Stub Tauri sidecar binaries'
require 'desktop/src-tauri/binaries'
require 'gh issue close'
require 'Local macOS package handoff'
require 'scripts/build-private-ca-macos.sh'
require 'scripts/normalize-private-ca-desktop-tag.sh'
require '--assignee BrianInAz'
require 'ticket already exists'
require "github.event.label.name == 'built'"
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
forbid 'runs-on: macos'
forbid 'actions/attest-build-provenance@'
forbid 'gh release create'

if [[ ! -x "${local_builder}" ]]; then
  echo "missing executable ${local_builder}" >&2
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

for expected in 'set -euo pipefail' 'createUpdaterArtifacts": false' 'codesign --verify --deep --strict' 'hdiutil create'; do
  if ! grep -F -q -- "${expected}" "${local_builder}"; then
    echo "${local_builder} must contain: ${expected}" >&2
    exit 1
  fi
done

if grep -i -F -q -- 'insecure_skip_verify' "${local_builder}"; then
  echo "${local_builder} must not bypass TLS verification" >&2
  exit 1
fi

echo "private CA release workflow contract passed"
