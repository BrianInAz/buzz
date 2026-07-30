#!/usr/bin/env bash

set -euo pipefail

workflow=".github/workflows/private-ca-release.yml"
local_builder="scripts/build-private-ca-macos.sh"

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
require "github.actor == 'BrianInAz'"
require "github.event.label.name == 'build-approved'"
require "github.event.label.name == 'skip'"
require 'refs/tags/'
require '6d03a38da5e3402bf97df1b3c46152887eb3778e'
require 'cherry-pick --no-commit'
require 'just ci'
require 'gh issue close'
require 'Local macOS package handoff'
require 'scripts/build-private-ca-macos.sh'

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

for expected in 'set -euo pipefail' 'createUpdaterArtifacts": false' 'codesign --verify --deep --strict' 'hdiutil create'; do
  if ! rg --fixed-strings --quiet -- "${expected}" "${local_builder}"; then
    echo "${local_builder} must contain: ${expected}" >&2
    exit 1
  fi
done

if rg --ignore-case --fixed-strings --quiet -- 'insecure_skip_verify' "${local_builder}"; then
  echo "${local_builder} must not bypass TLS verification" >&2
  exit 1
fi

echo "private CA release workflow contract passed"
