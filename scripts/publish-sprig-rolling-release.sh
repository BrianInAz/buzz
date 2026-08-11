#!/usr/bin/env bash

set -euo pipefail

repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
sha=${GITHUB_SHA:?GITHUB_SHA is required}
dist_dir=${SPRIG_DIST_DIR:-dist}
tag='sprig-latest'
title='Sprig (rolling)'
notes="Rolling Linux build of Sprig (all-in-one buzz-acp + buzz-agent + buzz-dev-mcp), tracking \`main\` (\`${sha}\`)."

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to publish the Sprig rolling release" >&2
  exit 1
fi

if [[ ! "${repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "GITHUB_REPOSITORY must use the owner/repository form" >&2
  exit 1
fi

if [[ ! -d "${dist_dir}" ]]; then
  echo "Sprig artifact directory does not exist: ${dist_dir}" >&2
  exit 1
fi

shopt -s nullglob
assets=("${dist_dir}"/*)
shopt -u nullglob
if ((${#assets[@]} == 0)); then
  echo "Sprig artifact directory is empty: ${dist_dir}" >&2
  exit 1
fi

release_response=''
if release_response=$(gh api --include "repos/${repo}/releases/tags/${tag}" 2>&1); then
  release_exists=true
elif grep -E -q '^HTTP/[0-9.]+ 404([[:space:]]|$)' <<<"${release_response}"; then
  release_exists=false
else
  printf '%s\n' "${release_response}" >&2
  exit 1
fi

if [[ "${release_exists}" == true ]]; then
  gh release edit "${tag}" \
    --prerelease \
    --target "${sha}" \
    --title "${title}" \
    --notes "${notes}" \
    --repo "${repo}"
  gh release upload "${tag}" "${assets[@]}" \
    --clobber \
    --repo "${repo}"
else
  gh release create "${tag}" "${assets[@]}" \
    --prerelease \
    --target "${sha}" \
    --title "${title}" \
    --notes "${notes}" \
    --repo "${repo}"
fi
