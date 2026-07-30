#!/usr/bin/env bash

set -euo pipefail

workflow=".github/workflows/private-ca-release.yml"

if [[ ! -f "${workflow}" ]]; then
  echo "missing ${workflow}" >&2
  exit 1
fi

require() {
  local expected="$1"
  if ! rg --fixed-strings --quiet -- "${expected}" "${workflow}"; then
    echo "${workflow} must contain: ${expected}" >&2
    exit 1
  fi
}

forbid() {
  local prohibited="$1"
  if rg --ignore-case --fixed-strings --quiet -- "${prohibited}" "${workflow}"; then
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
require 'attestations: write'
require 'id-token: write'
require "github.actor == 'BrianInAz'"
require "github.event.label.name == 'build-approved'"
require "github.event.label.name == 'skip'"
require 'refs/tags/'
require '6d03a38da5e3402bf97df1b3c46152887eb3778e'
require 'cherry-pick --no-commit'
require 'just ci'
require 'macos-15'
require 'codesign --verify --deep --strict'
require 'hdiutil create'
require 'SHA256SUMS'
require 'gh release create'
require 'gh issue close'
require '--prerelease'
require 'actions/attest-build-provenance@'
require 'createUpdaterArtifacts": false'
require 'buzz-private-ca-'

forbid 'BUZZ_TEST_WSS_URL'
forbid 'buzz.bjzy.me'
forbid 'insecure_skip_verify'
forbid 'tailscale'
forbid 'VAULT_'
forbid 'APPLE_CERTIFICATE'
forbid 'TAURI_SIGNING_PRIVATE_KEY'

echo "private CA release workflow contract passed"
