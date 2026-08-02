#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 <release-tag>" >&2
  exit 64
fi

tag="$1"

if [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  [[ "${tag}" =~ ^desktop-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' "${tag}"
  exit 0
fi

echo "not a stable Buzz Desktop tag: ${tag}" >&2
exit 1
