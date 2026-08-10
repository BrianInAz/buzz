# CI Desktop path-filter remediation

## Status

Implemented with TDD on `fix/ci-desktop-path-filter` from `origin/main`
commit `0f7edef101f2`. Beads item `ios-buzz-59e.8` tracks delivery.

## Root cause

The CI workflow used these Desktop rules while the pinned
`dorny/paths-filter` action retained its default
`predicate-quantifier: some` behavior:

```yaml
desktop:
  - 'desktop/**'
  - '!desktop/src-tauri/**'
```

Under `some`, every rule is an independent predicate. The negative rule is
true for every file outside `desktop/src-tauri`, so mobile, documentation, and
Beads-only pull requests incorrectly produced `desktop=true`. That activated
the Desktop matrix, including its GitHub-hosted macOS job. The unexpected run
was cancelled immediately after the overmatch was confirmed.

## Remediation

The two-rule include/exclude combination is replaced with one positive
picomatch extglob:

```yaml
desktop:
  - 'desktop/!(src-tauri)/**'
```

This continues to classify Desktop frontend files and top-level Desktop files
as `desktop=true`, while `desktop/src-tauri/**` remains exclusively classified
by the existing `desktop-rust` filter. Existing downstream job conditions
already accept either output, so Tauri validation coverage is unchanged.

The regression contract is executed in the existing Ubuntu-based
`Detect Changed Paths` job. It uses no new dependency and verifies:

- mobile, documentation, and Beads files do not select Desktop;
- Desktop frontend and top-level files do select Desktop;
- `desktop/src-tauri` selects `desktop-rust`, not `desktop`;
- the Desktop filter cannot reintroduce a standalone negative rule while the
  action uses `some` semantics.

## TDD evidence

Red on untouched `origin/main`:

- 3 contract tests failed;
- a mobile file selected Desktop;
- a Tauri file selected both Desktop filters; and
- the standalone negative rule was detected.

Green after the one-rule correction:

- 3/3 new routing contracts passed;
- all 6 existing file-size contract tests passed;
- every existing contract command in the `Detect Changed Paths` job passed;
- workflow YAML parsed successfully;
- Biome and `git diff --check` passed; and
- the replacement pattern matched the pinned action's picomatch semantics.

## Delivery boundary

Repository policy prohibits agents from starting GitHub-hosted macOS or
Windows jobs. Because changing `.github/workflows/ci.yml` is itself classified
as Rust/mobile work on current `main`, an agent-created pull request would
start both hosted job families before this correction could take effect.

The safe automated boundary is therefore a committed and pushed task branch
without an agent-created pull request. A human must create and merge that CI
pull request. Afterward, the iOS presence pull request can be refreshed and
will classify its mobile/docs/Beads-only diff without starting hosted macOS or
Windows jobs.

## Rollback

Revert the CI-filter commit. No application, relay, Desktop runtime, Hermes,
certificate, or mobile rollback is required.
