# Sprig rolling-release bootstrap remediation

## Status

Implemented with TDD on `fix/sprig-rolling-release-bootstrap` from merged
`origin/main` commit `4deea1a0d7fc`. Beads item `ios-buzz-59e.9` tracks
delivery. The pull request and merged commit are recorded at promotion time.

## Root cause

The `Sprig` workflow successfully built both static Linux artifacts on a push
to `main`, then unconditionally ran `gh release edit sprig-latest`. This fork
had no `sprig-latest` release, so its first rolling publication failed with
`release not found` after all build work had completed.

Creating the release manually would leave the workflow unable to bootstrap a
new fork or recover after deliberate release removal. The defect therefore
required a source-controlled fix rather than a one-time GitHub mutation.

## Remediation

The workflow now delegates rolling publication to
`scripts/publish-sprig-rolling-release.sh`. The helper:

- validates the repository, triggering SHA, GitHub CLI, artifact directory,
  and non-empty artifact set before mutation;
- queries the exact `sprig-latest` release through the GitHub API;
- creates the prerelease with all assets when the API returns `404`;
- updates metadata and replaces assets when the release already exists;
- treats every non-404 query failure and every release command failure as
  fatal; and
- explicitly scopes all release operations to the triggering repository.

No release, tag, or asset is created manually. The first successful
post-merge workflow run is the acceptance path that bootstraps
`sprig-latest`.

## TDD evidence

The new contract first failed because the checked-in publisher did not exist.
After implementation it proves:

- a missing release performs one create operation and no edit/upload path;
- an existing release performs edit plus clobber upload and no create path;
- both paths publish metadata for the triggering SHA;
- a non-404 API failure stops before any release mutation;
- a release command failure remains fatal; and
- both the Sprig workflow and the Ubuntu CI detector execute the checked-in
  helper and contract respectively.

## Rollback

Revert the delivery pull request. If the first successful promotion created
`sprig-latest`, retain it unless release removal is separately authorized;
deleting a published release or its tag is not part of this rollback.
