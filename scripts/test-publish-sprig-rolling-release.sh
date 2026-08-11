#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
publisher="${repo_root}/scripts/publish-sprig-rolling-release.sh"
sprig_workflow="${repo_root}/.github/workflows/sprig.yml"
ci_workflow="${repo_root}/.github/workflows/ci.yml"

fail() {
  echo "sprig rolling release contract failed: $*" >&2
  exit 1
}

[[ -x "${publisher}" ]] || fail "missing executable ${publisher}"
grep -F -q 'scripts/publish-sprig-rolling-release.sh' "${sprig_workflow}" \
  || fail "Sprig workflow must invoke the checked-in publisher"
grep -F -q 'scripts/test-publish-sprig-rolling-release.sh' "${ci_workflow}" \
  || fail "CI must execute the Sprig rolling release contract"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin" "${tmp}/dist"
touch \
  "${tmp}/dist/sprig-aarch64-unknown-linux-musl.tar.gz" \
  "${tmp}/dist/sprig-aarch64-unknown-linux-musl.tar.gz.sha256" \
  "${tmp}/dist/sprig-x86_64-unknown-linux-musl.tar.gz" \
  "${tmp}/dist/sprig-x86_64-unknown-linux-musl.tar.gz.sha256"

cat >"${tmp}/bin/gh" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

command_name=${1-}
shift || true
{
  printf '%s' "${command_name}"
  for argument in "$@"; do
    printf '\t%s' "${argument}"
  done
  printf '\n'
} >>"${GH_LOG:?}"

case "${command_name}" in
  api)
    case "${GH_API_MODE:?}" in
      existing)
        printf 'HTTP/2.0 200 OK\n\n{"tag_name":"sprig-latest"}\n'
        ;;
      missing)
        printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'
        exit 1
        ;;
      error)
        printf 'HTTP/2.0 500 Internal Server Error\n\n{"message":"failure"}\n'
        exit 1
        ;;
      *)
        echo "unexpected GH_API_MODE=${GH_API_MODE}" >&2
        exit 2
        ;;
    esac
    ;;
  release)
    exit "${GH_RELEASE_STATUS:-0}"
    ;;
  *)
    echo "unexpected gh command: ${command_name}" >&2
    exit 2
    ;;
esac
EOF
chmod +x "${tmp}/bin/gh"

run_publisher() {
  local mode=$1
  local log=$2
  GH_API_MODE="${mode}" \
    GH_LOG="${log}" \
    GITHUB_REPOSITORY='BrianInAz/buzz' \
    GITHUB_SHA='0123456789abcdef' \
    PATH="${tmp}/bin:${PATH}" \
    SPRIG_DIST_DIR="${tmp}/dist" \
    "${publisher}"
}

missing_log="${tmp}/missing.log"
run_publisher missing "${missing_log}"
grep -F -q $'api\t--include\trepos/BrianInAz/buzz/releases/tags/sprig-latest' "${missing_log}" \
  || fail "missing-release path must query the exact tag"
grep -F -q $'release\tcreate\tsprig-latest' "${missing_log}" \
  || fail "missing-release path must create sprig-latest"
grep -F -q $'\t--prerelease\t--target\t0123456789abcdef' "${missing_log}" \
  || fail "create must publish a prerelease at the triggering SHA"
grep -F -q $'\t--repo\tBrianInAz/buzz' "${missing_log}" \
  || fail "create must target the triggering repository explicitly"
if grep -F -q $'release\tedit\t' "${missing_log}" \
  || grep -F -q $'release\tupload\t' "${missing_log}"; then
  fail "missing-release path must not edit or separately upload"
fi

existing_log="${tmp}/existing.log"
run_publisher existing "${existing_log}"
grep -F -q $'release\tedit\tsprig-latest' "${existing_log}" \
  || fail "existing-release path must edit sprig-latest"
grep -F -q $'\t--prerelease\t--target\t0123456789abcdef' "${existing_log}" \
  || fail "edit must retarget the prerelease to the triggering SHA"
grep -F -q $'release\tupload\tsprig-latest' "${existing_log}" \
  || fail "existing-release path must replace rolling assets"
grep -F -q $'\t--clobber\t--repo\tBrianInAz/buzz' "${existing_log}" \
  || fail "asset replacement must be explicit and repository-scoped"
if grep -F -q $'release\tcreate\t' "${existing_log}"; then
  fail "existing-release path must not create a duplicate release"
fi

error_log="${tmp}/error.log"
if run_publisher error "${error_log}" >"${tmp}/error.out" 2>&1; then
  fail "non-404 API failure must stop publication"
fi
grep -F -q '500 Internal Server Error' "${tmp}/error.out" \
  || fail "non-404 API failure must remain visible"
if grep -F -q $'release\t' "${error_log}"; then
  fail "non-404 API failure must not attempt release mutation"
fi

release_error_log="${tmp}/release-error.log"
if GH_RELEASE_STATUS=23 run_publisher missing "${release_error_log}" >/dev/null 2>&1; then
  fail "release command failure must remain fatal"
fi

echo "sprig rolling release contract passed"
