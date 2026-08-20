# Buzz Platform Upgrade Remediation Plan — `desktop-v0.5.17`

**Plan ID:** `BUZZ-UPGRADE-2026-08-19`
**Authored:** 2026-08-19 (Cursor / Claude Opus 5)
**Intended executor:** Grok 4.6
**Accountable approver:** BrianInAz
**Responsible role:** BjzyLabs homelab platform

---

## 0. How to use this document

You are the implementing agent. This plan is written so that every step is
mechanically checkable. Read this section completely before running anything.

### 0.1 Rules of engagement (non-negotiable)

1. **No workarounds.** If a gate fails, a prerequisite is missing, or a command
   errors, you **stop at that step**, record the exact failure, and report the
   blocker. You do not substitute credentials, relax a TLS setting, broaden a
   Tailscale ACL, put secrets in AWX `extra_vars`, skip an advisory scan, pass
   `--no-verify`, force-push, disable a test, stub a module into `sys.modules`,
   or invent an alternate access path. A blocked step is a successful outcome of
   this plan if you report it accurately.
2. **Fail closed.** Every step below has an explicit **STOP condition**. When it
   trips, halt that phase. Do not continue to a later phase that depends on it.
3. **Evidence or it did not happen.** Every step names the evidence you must
   capture. Record it as you go (see §8). Never claim a result you did not
   observe in command output.
4. **Verify presence, never print secrets.** You may confirm a Vault field
   exists and is non-empty. You must never echo, log, or copy a secret value,
   private key, token, or identity into chat, files, Git, Beads, Notion, or AWX.
5. **Human-only actions are explicitly marked** with **[HUMAN]**. There are
   exactly three of them in this plan (§7.3). Everything else is yours to do by
   CLI or API. Do not ask the human to run anything not marked **[HUMAN]**.
6. **Never destroy client state.** No signing out, no clearing app data, no
   Keychain reset, no identity regeneration, no removing a community, no
   deleting message history. The macOS app upgrade is state-preserving by
   design; if a step would violate that, stop.
7. **Read the referenced runbook before executing a phase that cites one.** This
   plan references runbooks rather than duplicating them, so the runbook is
   authoritative on procedure detail. If the runbook and this plan conflict,
   stop and report the conflict.

### 0.2 Repositories and worktrees

| Purpose | Path | Remote | Branch model |
|---|---|---|---|
| Buzz fork (app source) | `/Users/b/Code/buzz/grok-deploy-new-version` | `origin` = `BrianInAz/buzz`, `upstream` = `block/buzz` | `main` only, no `develop`, no GitFlow guard |
| Buzz human worktree | `/Users/b/Code/buzz/human` | same | do not use for agent work |
| Homelab ops (registry, roles, AWX, runbooks) | `/Users/b/Code/homelab-playbooks/<worktree>` | `BjzyLabs/homelab-playbooks` | `develop` → `main`, GitFlow guard **enforced** |

**Branch naming:** the Buzz fork has no GitFlow guard, so the existing branch
`agent/grok/deploy-new-version` is acceptable there. **homelab-playbooks does
enforce a guard** and `agent/` is *not* on its allowlist. For every
homelab-playbooks change in this plan, use a `feature/` or `fix/` branch off
`develop`. Verify with `git branch --show-current` before every commit and before
every `gh pr create`.

### 0.3 Toolchain

The Buzz repo pins its toolchain with Hermit. Activate it before any build,
lint, or test command in that repo:

```bash
cd /Users/b/Code/buzz/grok-deploy-new-version
source ./bin/activate-hermit
```

Hermit provides `cargo`, `cargo-deny`, `just`, `pnpm`, `node`, `flutter`,
`dart`, `cmake`, `biome`, `lefthook`. **`flutter` is not on the system PATH** —
it exists only through Hermit. Python work in homelab-playbooks uses that
repo's own venv (Critical Rule #7): check `<repo>/.venv`, then `<repo>/venv`,
and activate before `pip` or `pytest`.

---

## 1. Verified current state

Every row below was verified on 2026-08-19 by the command in the last column.
**Re-verify each one before you act on it** — state may have drifted.

### 1.1 Upstream release state (`block/buzz`)

| Lane | Latest public release | Notes | Verify |
|---|---|---|---|
| Desktop | **`desktop-v0.5.17`** = `c3bfd66947978fae93f4cfb46bea98ba20e32ccf`, published 2026-08-18 | Marked `Latest` on GitHub | `gh release list --repo block/buzz --limit 5` |
| Relay | **`relay-v0.2.1`** = `6e5c462ac524de60d7edb46c66130fd779cc9006` | **Contained in `desktop-v0.5.17`** — verified ancestor | `git merge-base --is-ancestor relay-v0.2.1 desktop-v0.5.17` |
| Mobile | **`mobile-v0.13.0-rc.2`** | RC tag only; store build runs on Block's private Buildkite | `git ls-remote --tags upstream 'mobile-*'` |
| Sprig | `sprig-latest` (rolling pre-release) | Not deployed in this homelab | `gh release list --repo block/buzz` |

**Consequence:** because `relay-v0.2.1` is an ancestor of `desktop-v0.5.17`, a
**single upstream base commit — `c3bfd66947978fae93f4cfb46bea98ba20e32ccf` —
serves both the desktop lane and the server lane.** Use one base for the whole
upgrade. Do not rebase the two lanes onto different upstream commits.

### 1.2 What we currently run

| Component | Installed / deployed now | Target | Verify |
|---|---|---|---|
| macOS Desktop app | `0.5.3-bjzy`, **ad-hoc signed**, bundle `xyz.block.buzz.app`, at `/Applications/Buzz.app` | rebuilt on `desktop-v0.5.17` | `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Buzz.app/Contents/Info.plist` |
| Desktop provenance | fork canary from fork SHA `f2c5f9476d1db190c5b78f1b7ce0d6ee81bd7a24`, installed 2026-08-06T06:05:33Z | — | `cat "/Users/b/Applications/Buzz Rollback/fork-canary-f2c5f9476d1d-20260806T060532Z/INSTALL-RECEIPT.json"` |
| `buzz` CLI | **symlink** `/Users/b/.local/bin/buzz` → `/Applications/Buzz.app/Contents/MacOS/buzz` | follows the app | `ls -la /Users/b/.local/bin/buzz` |
| Bundled sidecars in app | `buzz`, `buzz-acp`, `buzz-agent`, `buzz-desktop`, `buzz-dev-mcp`, `git-credential-nostr` | same set, rebuilt | `ls /Applications/Buzz.app/Contents/MacOS/` |
| Relay — prod `buzz.bjzy.me` | NIP-11 reports `version: 0.2.0` | `0.2.1` | `curl -H 'Accept: application/nostr+json' https://buzz.bjzy.me/ \| jq -r .version` |
| Relay — dev `devbuzz.bjzy.me` | NIP-11 reports `version: 0.2.0` | `0.2.1` | `curl -H 'Accept: application/nostr+json' https://devbuzz.bjzy.me/ \| jq -r .version` |
| Relay binary pin (GitOps) | `harbor.bjzy.me/bjzy-custom/buzz-native-bin:nip-ad-ba8826c9-amd64` @ `sha256:e63072f1067567bfa90d62aa75b950f5043e60b85a40b159abeaafae02eddcc7` | new artifact | `rg -n 'buzz_binary_oci' <homelab>/roles/buzz/defaults/main.yml` |
| Hermes `buzz` CLI pin | `harbor.bjzy.me/bjzy-custom/buzz-native-bin:native-roots-0f7edef1-amd64` @ `sha256:94d31fbc762118e137cbceda70ada3e0391cb54092473417414182245f5656c5` | new artifact | `rg -n 'buzz' <homelab>/roles/hermes/defaults/main.yml` |
| iOS app on physical iPhone | unmanaged; no governed homelab artifact exists | **see Blocker B2** | §4.2 |

**The production relay is running fork code, not upstream code.** The pin tag
`nip-ad-ba8826c9-amd64` corresponds to fork commit `ba8826c9`, which is part of
the fork-only NIP-AD feature series. This is load-bearing: see Blocker B3.

### 1.3 Fork divergence from upstream

Measured with `git cherry -v desktop-v0.5.17 main` in the Buzz fork:

- **74 commits** on fork `main` are not in `desktop-v0.5.17`.
- **1** has an equivalent patch already upstream: `ad9e7c31d5bee85c719acf474c4a49dffce0b487` `test(desktop): await thread scroll anchor (#3174)`. **Drop it.**
- **73** remain fork-only and must each be carried forward, contributed, or retired.
- The deviation registry records only **5** Buzz entries. See Blocker B4.

Merge base: `a5dbdf5e61e4c512acd99c219c79c154ddb57295`.

---

## 2. Scope

### 2.1 In scope

1. macOS Desktop client (Tauri) — rebuild on `desktop-v0.5.17`.
2. `buzz` CLI — upgraded as a consequence of the desktop bundle (§1.2).
3. Desktop-bundled sidecars — `buzz-acp`, `buzz-agent`, `buzz-dev-mcp`,
   `git-credential-nostr`.
4. Relay `buzz-relay` on prod host `buzz` and dev host `devbuzz`.
5. `buzz-pair-relay` pairing sidecar on both hosts (the "sidecars" on devBuzz
   and buzz.bjzy.me).
6. `buzz-admin` operator binary on both hosts.
7. The Harbor OCI artifact `buzz-native-bin` that carries items 4–6.
8. **Hermes `buzz` CLI pin** on Hermes hosts — *this is the component not named
   in the request*. Hermes hosts run a separately pinned `buzz` CLI extracted
   from the same Harbor artifact family. Leaving it behind creates a version
   skew between the agents and the relay they talk to.
9. iOS/mobile app — **gated by Blocker B2**.
10. Deviation registry reconciliation, and the supporting runbooks, tests,
    role defaults, Vault pin metadata, Notion mirrors, and Beads records.

### 2.2 Explicitly out of scope, with evidence

Do **not** deploy these. Each was checked and is not in homelab use:

| Component | Why out of scope |
|---|---|
| `web/` and `admin-web/` bundles | The `buzz` Ansible role never sets `BUZZ_WEB_DIR` or an admin web root; native relays are headless. Verify with `rg -n 'BUZZ_WEB_DIR\|admin_web' <homelab>/roles/buzz/` returning no deployment wiring. |
| `buzz-push-gateway` | No references in homelab-playbooks. APNs push is handled by the upstream-hosted gateway advertised in NIP-11. |
| `sprig` binary and `buzz-sprig` image | Published by CI only; not installed on any homelab host. |
| Helm charts (`deploy/charts/*`) | Homelab relays are native systemd, not Kubernetes. |
| `buzz-backend-kubernetes` | Not present in the installed app bundle (§1.2) and no K8s remote-agent backend is configured. |

If you discover evidence contradicting any row, **stop and report** rather than
expanding scope on your own judgement.

---

## 3. Deviation reconciliation

Authoritative registry: `docs/upstream-deviations.json` in homelab-playbooks.
Rendered dashboard: `docs/current-upstream-deviations.md`. SOP:
`docs/runbooks/upstream-deviation-management.md`.

The registry snapshot is `2026-08-04T09:13:00Z` and is **stale in two ways**:
it claims the installed artifact is `v0.5.2` when it is actually the
`0.5.3-bjzy` fork canary (§1.2), and it omits most of the fork delta (§1.3).

### 3.1 Findings — verified against `desktop-v0.5.17`

| Registry ID | Upstream status at `desktop-v0.5.17` | Verdict | Action |
|---|---|---|---|
| `buzz-macos-private-ca-v1` | **NOT fixed.** `desktop/src-tauri/src/native_websocket.rs` still calls plain `connect_async` with no platform verifier; `rustls-platform-verifier` is absent from the dependency graph. Upstream issue #2940 and PR #3455 are both still **OPEN**. | Carry forward | Patch `6d03a38da5e3402bf97df1b3c46152887eb3778e` **applies cleanly** to `desktop-v0.5.17` (verified by trial cherry-pick: 5 files auto-merged, zero conflicts). Keep entry `active`, refresh `source_lock` to the new base. |
| `buzz-desktop-nostr-signature-verification-v1` | **FIXED UPSTREAM.** `nostr-relay-pool` is **absent from both `Cargo.lock` and `desktop/src-tauri/Cargo.lock`** at `desktop-v0.5.17`. Upstream PR #4139 (`chore(deps): bump nostr-relay-pool for RUSTSEC-2026-0224`) merged 2026-08-01 as `9d6726e5b387310975f5809473ce8372f6fde0dc`; the crate was subsequently removed entirely. | **RETIRE** | Our patch `7dbfcd785be0a9c002863a793c4fbab89a6258c3` now **CONFLICTS** (verified: `UU Cargo.lock`, `UU desktop/src-tauri/Cargo.lock`) and is obsolete. Retire per §5.2. |
| `buzz-contextual-agent-conversations-v1` | Not upstream. Our PR `block/buzz#4688` is **OPEN**. | Carry forward | Rebase the series; promote `proposed` → `active` only after runtime acceptance. |
| `buzz-mobile-persistent-agent-audience-v1` | Not upstream. No standalone upstream PR (sequenced behind #4688). | Carry forward | Remains `proposed`. Blocked by B2. |
| `buzz-desktop-removable-audience-chips-v1` | Not upstream. Our PR `block/buzz#4689` is **OPEN**. | Carry forward | Rebase the series; promote after runtime acceptance. |
| `hermes-buzz-presence-lifecycle-v1` | Hermes lane, `certification_state: blocked`. | Out of this plan's mutation scope | After the relay upgrade, re-run the Hermes deviation monitor and record whether relay `0.2.1` changes presence behavior. Do not modify the transform here. |
| `hermes-openrouter-online-web-search-filter-v1` | Unrelated to Buzz versions. | No action | — |

**Bottom line on the request "identify anything that has been fixed since our
last build":** exactly one deviation has been fixed upstream — the
RUSTSEC-2026-0224 Nostr signature-verification bypass. It is now moot because
upstream dropped the vulnerable crate. One additional fork commit
(`ad9e7c31d`, thread scroll anchor test) has landed upstream and must be
dropped. Everything else we carry is still ours to carry.

### 3.2 Unregistered deviations that must be registered

These are fork-only changes in production use with **no registry entry**. This
is a registry integrity failure, not a bookkeeping nicety: the SOP's upgrade
gates cannot protect a deviation nobody recorded. Register each before or
during Phase 2.

| Proposed ID | What it is | Commits | Where it runs today | Severity |
|---|---|---|---|---|
| `buzz-nip-ad-durable-agent-drafts-v1` | NIP-AD durable agent drafts: new event kinds 44300/44301, relay ingest + read gate + FTS exclusion, DB migration `0027_agent_draft_fts.sql`, SDK builders, CLI `drafts` commands, desktop draft store and adoption UI | `384d1525a`, `2400d8473`, `3a00282cb`, `fac7b6cd4`, `699c552eb`, `26252785b`, `113bfa266`, `1be4547a3`, `4ab0eb868`, `1c28f7203`, `e5a57cd5a`, `8447d9c31`, `d31ebe970`, `ba8826c94`, `a61e3b2e1` | **Production relay** (`nip-ad-ba8826c9-amd64`) and prod DB schema | critical-server-feature |
| `buzz-cli-native-root-wss-trust-v1` | `buzz` CLI uses rustls native roots so WSS to the private CA works | `6e8523101`, `0f7edef10`, `7765d12ec` | **Hermes hosts** (`native-roots-0f7edef1-amd64`) and desktop-bundled CLI | critical-agent-connectivity |
| `buzz-docker-locked-build-v1` | Relay and push-gateway images build without `--locked` after `cargo chef cook`; refreshed `Cargo.lock` | `a6c86d6f0`, `e58fcd8af`, `95ba0103a` | Image build path feeding the Harbor artifact | build-reproducibility |
| `buzz-private-ca-release-machinery-v1` | The fork's private-CA build/release automation and its CI guards | `eda5dc91d`, `01c378da9`, `ce82fd3e1`, `3c58f62f2`, `c469d81e7`, `a7c0baa05`, `2f24cb3a0`, `da4bd103c`, `f4065d1b1`, `b5f6b1ba4`, `c81f9fe5b`, `a7faf67d9`, `4c4c8738f`, `f4ea9e39d` | Fork CI | release-tooling |
| `buzz-desktop-carried-fixes-v1` | Desktop fixes not yet upstream: observer REQ gating, staged provider publication, autocomplete flush, relay admission test isolation | `e0f18f8bc`, `4ff406444`, `f73b2bdd5`, `4deea1a0d`, `8b4dc5048` | Desktop app | client-correctness |
| `buzz-mobile-carried-fixes-v1` | Mobile channel scroll anchor and peer-presence hydration | `594d8cc5c`, `79bfb1d9b`, `f8e7e0c74` | Mobile source (not deployed — see B2) | mobile-correctness |
| `buzz-sprig-rolling-release-ci-v1` | Sprig rolling-release CI bootstrap | `ce5acf44c` | Fork CI only | ci-only |

Registration procedure is in `docs/runbooks/upstream-deviation-management.md`.
Each entry needs the full schema-v2 field set, and
`python3 scripts/validate_upstream_deviations.py --check` plus
`python3 scripts/render_upstream_deviation_docs.py --check` must pass.

---

## 4. Hard blockers

These must be resolved **before** the phases that depend on them. None of them
may be worked around. If a blocker cannot be cleared, that phase does not run
and you report it.

### 4.1 B1 — The Harbor artifact publisher is not source-controlled `[BLOCKS PHASE 3]`

`docs/runbooks/buzz-release-boundary.md` states that
`harbor.bjzy.me/bjzy-custom/buzz-native-bin` is published only by a "local
controlled publisher" on the operator workstation, which fetches the
`Buzz-Admin` and `Buzz-Publisher` Vault robots at runtime, because
`vault.bjzy.me` is not publicly reachable and therefore GitHub-hosted runners
cannot publish.

**That publisher does not exist as code.** A filesystem search across
`/Users/b/Code`, `~/dotfiles`, `~/.config`, `~/bin`, `~/.local/bin`, and
`~/scripts` for `buzz-native-bin` or `Buzz-Publisher` returns only
documentation, role defaults, test fixtures, and unit tests — no build or push
script, playbook, or workflow.

This violates GitOps durability (Critical Rule #9): the desired state of the
production relay binary has no source-controlled producer. **You cannot upgrade
the relay without re-creating this artifact, and you must not hand-run
undocumented `oras push` commands to do it.**

**Required resolution — author the publisher as source-controlled code.** Add to
homelab-playbooks (suggested `scripts/buzz/publish_buzz_native_bin.py` plus
`docs/runbooks/buzz-native-bin-publisher.md`), TDD-first with unit tests under
`tests/unit/`, satisfying the boundary runbook exactly:

- Runs only on the trusted operator workstation; refuses to run in GitHub Actions.
- Fetches `Buzz-Admin` and `Buzz-Publisher` from Vault at runtime. Never writes
  them to disk, logs, or `extra_vars`.
- Verifies the Harbor immutability rule before pushing.
- Takes the fork source SHA and the built Linux AMD64 binaries as inputs.
- Emits `buzz-relay`, `buzz-admin`, `buzz-pair-relay`, `PIN.txt`, `SHA256SUMS`,
  matching `tests/fixtures/buzz_native_bin_manifest.json`.
- Tags as `<branch>-<short-sha>-amd64`.
- Supports `--check` (validate, do not publish).
- Prints the resulting OCI digest and per-binary SHA-256 for pin promotion.

**STOP condition:** if you cannot satisfy the boundary runbook without granting
GitHub Actions Vault access, exposing Vault publicly, or storing a Harbor
credential in a GitHub secret — stop. Report that the release boundary needs a
reviewed network design decision from BrianInAz. Do not build a workaround.

### 4.2 B2 — No governed path to install a Buzz build on the physical iPhone `[BLOCKS PHASE 5]`

Verified constraints on this Mac:

- The only code-signing identity is `Apple Development: web@briancharbonneau.com (NNBR3V7LJ8)`, a **personal team** (`O=brian charbonneau`), expiring **2026-10-03**.
- **No `Apple Distribution` / `iPhone Distribution` identity exists** → no TestFlight, no App Store, no ad-hoc distribution build.
- **Zero provisioning profiles** are installed (`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` and `~/Library/MobileDevice/Provisioning Profiles/` are empty).
- The target device `MyPhone` (iPhone 16 Pro, `44C6D660-D300-5A28-BD0F-03D22A12B243`) is known to `devicectl` but currently `unavailable` (not connected).
- Xcode 26.6 is installed. `flutter` is available only via Hermit.
- Upstream's only physical-device path is `mobile-vX.Y.Z-rc.N` → **Block's private Buildkite** (`buildkite.com/runway/buzz-mobile-releases`), which the fork cannot trigger.
- `docs/runbooks/buzz-contextual-fork-canary.md` states explicitly that it **does not authorize mobile installation**, and the registry keeps `buzz-mobile-persistent-agent-audience-v1` at `proposed` precisely because no governed physical-iPhone artifact exists.

There is therefore **no compliant way to put a new Buzz build on the iPhone
today**, and installing a development-signed build by hand would be exactly the
kind of workaround this plan forbids.

**Required resolution — build the missing lane, or defer.** Do not improvise.
Present these two options to BrianInAz and wait for a decision:

- **Option B2-A — build the governed mobile canary lane.** Deliver, TDD-first:
  a `scripts/build_buzz_mobile_canary_ios.sh` analogous to the macOS canary
  script (exact-SHA verification, patch certification, real build, checksums,
  manifest); a device-install + rollback script using `xcrun devicectl`; a
  `docs/runbooks/buzz-mobile-canary.md` runbook with state-preserving install,
  identity-preservation and cross-client acceptance criteria; a registry entry
  and promotion gates. **Prerequisite the human must supply:** a decision on
  Apple Developer Program enrollment (a paid membership gives 1-year
  provisioning and proper distribution signing; the current personal team gives
  7-day development builds only). This is a credential/access prerequisite, so
  per Critical Rule #8 it must be resolved by the human before implementation.
- **Option B2-B — defer mobile.** Ship Phases 1–4 and 6, keep
  `buzz-mobile-persistent-agent-audience-v1` at `proposed`, and record in the
  registry, Notion, and Beads that mobile remains on its existing app with a
  documented follow-up. The mobile source fixes still get rebased in Phase 2 so
  the fork stays coherent; they simply are not deployed.

**STOP condition:** do not build or install any iOS artifact until BrianInAz
selects an option in writing. Record the decision before proceeding.

### 4.3 B3 — NIP-AD is fork-only and is in the production relay `[BLOCKS PHASE 3]`

NIP-AD (durable agent drafts) exists **only in the fork**. Verified: at
`desktop-v0.5.17` there are no NIP-AD files upstream, while fork `main` carries
`crates/buzz-core/src/agent_draft.rs`, `crates/buzz-cli/src/commands/agent_drafts.rs`,
`desktop/src-tauri/src/commands/agent_drafts.rs`, `docs/nips/NIP-AD.md`, and
migration `migrations/0027_agent_draft_fts.sql`, plus relay ingest and read-gate
changes.

The production relay runs this code. **Deploying an unmodified upstream
`relay-v0.2.1` binary would remove kinds 44300/44301 handling from a relay whose
database already has the NIP-AD schema and whose Hermes agents depend on draft
publish/resolve.** That is a functional regression and a possible data-visibility
change, not a version bump.

**Required resolution:** the Phase 2 rebase must carry the full NIP-AD series
onto `desktop-v0.5.17`, and the Phase 3 artifact must be built from the rebased
fork — not from upstream. Additionally:

- Confirm migration `0027_agent_draft_fts.sql` still applies on top of any new
  upstream migrations at `desktop-v0.5.17`; check for numbering collisions with
  `git ls-tree desktop-v0.5.17 migrations/ --name-only | sort | tail -5`. If a
  collision exists, renumber the fork migration and record it.
- Register `buzz-nip-ad-durable-agent-drafts-v1` (§3.2) before promotion.

**STOP condition:** if the NIP-AD relay series cannot be rebased cleanly and the
conflict resolution is not obviously behaviour-preserving, stop. Do not ship a
relay that silently drops NIP-AD.

### 4.4 B4 — The deviation registry is incomplete `[BLOCKS PHASE 6 sign-off]`

73 fork-only commits versus 5 registry entries (§1.3, §3.2). The registry cannot
gate what it does not know about. Phase 6 is not complete until every fork-only
commit is either registered, contributed upstream, or retired with evidence.

### 4.5 B5 — The dev AWX surface may not be applied `[BLOCKS PHASE 4 dev-first ordering]`

`awx/devbuzz/README.md` in homelab-playbooks states the dev manifests are
committed but **not yet applied**, pending the devBuzz VM, the Development AWX
project, and a populated `kvProd_v2/Buzz/Development`. But `devbuzz.bjzy.me`
currently answers NIP-11 with `version: 0.2.0`, so *something* is deployed there.

**Resolve the contradiction before Phase 4** by reading actual AWX state (§7.1),
not by assuming. The SOP requires dev certification before production
promotion; if the dev AWX surface genuinely is not applied, applying it via
`awx/devbuzz/apply.sh` becomes a Phase 4 prerequisite.

**STOP condition:** never promote to production while dev certification is
`stale` or `blocked`. `production_blocked_when_development_blocked` is `true`
for every Buzz entry in the registry.

---

## 5. Phase 1 — Prerequisite verification (no mutations)

Run this entire phase before changing anything. It is read-only. Record every
result. **If any check fails, stop and report — do not proceed and do not
substitute an alternative.**

### 5.1 Access and tooling

| ID | Check | Command | Pass condition |
|---|---|---|---|
| P1.1 | Fork metadata (gates hosted macOS runners, Critical Rule #10) | `gh api repos/BrianInAz/buzz --jq '{visibility, fork, parent: .parent.full_name}'` | `visibility=public`, `fork=true`, `parent=block/buzz` |
| P1.2 | GitHub auth and scopes | `gh auth status` | authenticated, can write to `BrianInAz/buzz` |
| P1.3 | AWX API | `curl -sS -o /dev/null -w '%{http_code}\n' https://awx.bjzy.me/api/v2/ping/` | `200` |
| P1.4 | AWX CLI authenticated | `awx --conf.host https://awx.bjzy.me job_templates list --name 'Buzz - Manage - Prod' -f human` | returns template 215 |
| P1.5 | Vault login (userpass, never root) | `export VAULT_ADDR=https://vault.bjzy.me:8200; vault login -method=userpass username=<user>` | token issued |
| P1.6 | Vault Buzz prod fields **present** (do not print values) | `vault kv get -format=json kvProd_v2/Buzz/Prod \| jq -r '.data.data \| keys[]'` | contains `database_password`, `redis_password`, `local_minio_access_key`, `local_minio_secret_key`, `relay_private_key`, `git_hook_hmac_secret`, `restic_password`, `relay_owner_pubkey`, `binary_ref`, `binary_oci_digest`, `buzz_relay_sha256`, `buzz_admin_sha256`, `source_image`, `source_index_digest`, `source_amd64_manifest_digest` |
| P1.7 | Vault Buzz dev fields present | same for `kvProd_v2/Buzz/Development` | same key set (resolves part of B5) |
| P1.8 | Harbor robots present | `vault kv get -format=json kvProd_v2/Harbor/Buzz-Puller \| jq -r '.data.data \| keys[]'` and the same for `Buzz-Admin` / `Buzz-Publisher` if they exist | `username`, `password` present; **record whether `Buzz-Publisher` exists at all** — it is required by B1 |
| P1.9 | Backup robots present | `vault kv get -format=json kvProd_v2/Backups/S3 \| jq -r '.data.data \| keys[]'` | access/secret keys present |
| P1.10 | Hermit toolchain | `source ./bin/activate-hermit && cargo --version && just --version && pnpm --version && cargo-deny --version && flutter --version` | all resolve |
| P1.11 | macOS build host | `uname -s` = `Darwin`, `uname -m` = `arm64` | both true |
| P1.12 | Harbor reachable + `oras` | `oras version` and a Harbor login test using the puller robot | both succeed |
| P1.13 | Relay endpoints | `curl -H 'Accept: application/nostr+json' https://buzz.bjzy.me/ \| jq -r .version` and dev equivalent | both return a version |
| P1.14 | Beads integration (both repos) | in homelab-playbooks: `scripts/setup_beads_git_integration.sh --check` | passes |
| P1.15 | Notion MCP | list the Buzz operations page `3aa3569a-a255-8168-b633-d840da8b324f` | fetch succeeds |

### 5.2 Re-verify the §3.1 upstream findings

Do not trust this document's table; reproduce it. Record each output.

```bash
cd /Users/b/Code/buzz/grok-deploy-new-version
source ./bin/activate-hermit
git fetch upstream --tags --prune
git fetch origin --prune

# The single upstream base for this whole upgrade
BASE=$(git rev-parse desktop-v0.5.17^{commit})
echo "BASE=$BASE"   # expect c3bfd66947978fae93f4cfb46bea98ba20e32ccf

# Relay lane is contained in the desktop lane
git merge-base --is-ancestor relay-v0.2.1 desktop-v0.5.17 && echo "relay-v0.2.1 CONTAINED"

# D2 retirement evidence: the vulnerable crate must be absent from BOTH lockfiles
git show desktop-v0.5.17:Cargo.lock                   | grep -c 'name = "nostr-relay-pool"' || echo "root lock: ABSENT"
git show desktop-v0.5.17:desktop/src-tauri/Cargo.lock | grep -c 'name = "nostr-relay-pool"' || echo "desktop lock: ABSENT"

# D1 still needed: upstream has no platform verifier
git show desktop-v0.5.17:desktop/src-tauri/src/native_websocket.rs | grep -c 'platform_verifier' || echo "no platform verifier upstream: D1 STILL REQUIRED"

# Upstream contribution status
for pr in 3455 4256 4688 4689 4139; do
  gh pr view $pr --repo block/buzz --json number,state,mergedAt \
    --template '{{.number}} {{.state}} {{.mergedAt}}{{"\n"}}'
done

# Full fork-delta equivalence census
git cherry -v desktop-v0.5.17 main > /tmp/buzz-cherry-$(date -u +%Y%m%dT%H%M%SZ).txt
grep -c '^-' /tmp/buzz-cherry-*.txt   # expect 1  (ad9e7c31d, drop it)
grep -c '^+' /tmp/buzz-cherry-*.txt   # expect 73
```

**STOP conditions for Phase 1:**
- `nostr-relay-pool` present at `desktop-v0.5.17` → §3.1's retirement of
  `buzz-desktop-nostr-signature-verification-v1` is wrong. Re-derive before
  touching the registry.
- `platform_verifier` already present upstream → D1 may be retirable instead of
  carried. Re-derive.
- Any of #4688 / #4689 now `MERGED` → those deviations move to retirement, not
  carry-forward. Re-derive.
- `Buzz-Publisher` absent from Vault → B1 escalates from "write the publisher"
  to "the publishing credential does not exist". Report immediately.

---

## 6. Phase 2 — Rebase the fork onto `desktop-v0.5.17`

**Goal:** fork `main` sits on `c3bfd66947978fae93f4cfb46bea98ba20e32ccf` carrying
exactly the deviations we intend to keep, with the obsolete ones removed.

**Delivery boundary for this phase:** commits on a fork feature branch → pushed
to `origin` → PR into `BrianInAz/buzz` `main` → fork CI green → merge. No
production deployment happens in this phase.

### 6.1 Prepare

```bash
cd /Users/b/Code/buzz/grok-deploy-new-version
source ./bin/activate-hermit
git status --short --branch          # must be clean of YOUR changes
git branch --show-current
```

**Do not commit unrelated pre-existing working-tree changes.** At authoring time
this worktree had uncommitted modifications to `.gitignore`, `AGENTS.md`,
`CLAUDE.md`, deletions under `.agents/skills/`, `.claude/skills/`,
`.codex/skills/`, and untracked `.geminiignore`, `.qwen/`, `.ruler/`. These are
Ruler-sync artifacts belonging to the human. **Leave them alone.** Commit only
files you deliberately change.

Create the working branch:

```bash
git checkout -b feature/upgrade-desktop-v0.5.17 main
```

Record the pre-rebase fork head so rollback is possible:

```bash
git rev-parse main | tee /tmp/buzz-fork-main-pre-rebase.txt
```

### 6.2 Drop the commit that landed upstream

`ad9e7c31d5bee85c719acf474c4a49dffce0b487` has an upstream equivalent. It must
not be reapplied. If you rebase, git will normally drop it automatically; verify
afterward that it is gone rather than assuming.

### 6.3 Remove the obsolete security patch

`7dbfcd785be0a9c002863a793c4fbab89a6258c3` is obsolete (§3.1) and conflicts.
Drop it from the series. Then remove its now-dead references:

- `.github/workflows/private-ca-release.yml` hardcodes
  `SECURITY_PATCH_COMMIT: 7dbfcd785be0a9c002863a793c4fbab89a6258c3` at line ~23.
  **The workflow will fail if this stays**, because the commit no longer applies.
- `scripts/build-private-ca-macos.sh` declares
  `readonly security_patch_commit="7dbfcd785be0a9c002863a793c4fbab89a6258c3"`
  and cherry-picks it in a loop.
- `docs/operations/private-ca-desktop-release-lifecycle.md` documents the
  two-patch series.
- In homelab-playbooks: `scripts/build_buzz_fork_canary_macos.sh` also
  cherry-picks both patches and must be updated in the same delivery.

Reduce all of these to the single private-CA patch. Keep the `deny.toml`
hardening from the security commit **only if** advisory scans still need it;
verify by running the scans (§6.5) both with and without, and record which.

### 6.4 Rebase

Rebase the retained series onto `desktop-v0.5.17`. Work in dependency order and
commit-group at a time so conflicts stay attributable:

1. Private-CA patch (`6d03a38d`) — verified to apply cleanly.
2. CLI native-root WSS trust (`6e8523101`, `0f7edef10`, `7765d12ec`).
3. NIP-AD series (15 commits, §3.2) — highest risk, see B3. Verify the
   migration numbering before proceeding.
4. Contextual agent conversation series (`78458eb84` … `2da9629aa`).
5. Removable audience chips series (`970f97a3b`, `0d8af4eb3`, `4d8c72bef`, and
   the associated test/fix commits).
6. Mobile parity and mobile fixes (`ac319b30c`, `bad53924a`, `594d8cc5c`,
   `79bfb1d9b`, `f8e7e0c74`).
7. Docker `--locked` build fixes (`a6c86d6f0`, `e58fcd8af`, `95ba0103a`) —
   **re-evaluate**: these worked around a stale `Cargo.lock`. At
   `desktop-v0.5.17` the lock may already be consistent, in which case these
   commits should be retired rather than carried. Test the Docker build both
   ways and record the evidence.
8. Private-CA release machinery and CI guards (§3.2), minus the security-patch
   references removed in §6.3.
9. Remaining desktop carried fixes (`e0f18f8bc`, `4ff406444`, `f73b2bdd5`,
   `4deea1a0d`, `8b4dc5048`).
10. Sprig rolling-release CI (`ce5acf44c`).

For each group record: commits applied, conflicts encountered, how each conflict
was resolved, and why the resolution preserves behaviour.

**STOP conditions:**
- A conflict whose correct resolution is not clear from the surrounding code.
  Do not guess at semantics in a security, TLS, auth, relay read-gate, or
  event-verification path.
- Any commit that becomes empty unexpectedly — that means upstream changed
  something and you must understand it before dropping.

### 6.5 Gates

All must pass. No `--no-verify`, no ignored advisories, no skipped tests.

```bash
# Advisory scans — both graphs, as the SOP requires
cargo-deny --locked check --config deny.toml advisories
cargo-deny --locked \
  --manifest-path desktop/src-tauri/Cargo.toml \
  --target aarch64-apple-darwin \
  --exclude-dev \
  check --config deny.toml advisories

# Workspace
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --workspace --locked

# Desktop
just desktop-install-ci
pnpm -C desktop test
pnpm -C desktop build

# Mobile source gates (source only; no device install — see B2)
just mobile-check
just mobile-test

# Formatting/lint across the repo
just fix-all   # then confirm it produced no diff
git diff --exit-code
```

**Expected advisory outcome:** clean *without* the obsolete security patch,
because the vulnerable crate is gone upstream. If advisories are **not** clean,
stop — do not add an ignore entry. Report the advisory ID and the dependency
path.

### 6.6 Deliver

```bash
git push -u origin feature/upgrade-desktop-v0.5.17
gh pr create --repo BrianInAz/buzz --base main \
  --title "chore(deps): rebase fork onto upstream desktop-v0.5.17" \
  --body "$(cat <<'EOF'
Rebases the BjzyLabs fork onto upstream block/buzz desktop-v0.5.17
(c3bfd66947978fae93f4cfb46bea98ba20e32ccf), which also contains relay-v0.2.1.

Retires the RUSTSEC-2026-0224 patch series: upstream removed nostr-relay-pool
entirely, so 7dbfcd78 is obsolete and its release-machinery references are
removed.

Drops ad9e7c31d (thread scroll anchor test) — now upstream.

Carries forward: private-CA platform trust, CLI native-root WSS trust, NIP-AD
durable agent drafts, contextual agent conversations, removable audience chips,
mobile parity and fixes, and the private-CA release machinery.

Plan: docs/operations/buzz-v0.5.17-upgrade-remediation-plan.md
EOF
)"
```

Wait for fork CI. Merge only when green. Record the merge commit — it becomes
the source SHA for Phases 3 and 4.

**STOP condition:** red CI. Fix the cause; never merge past a failing check
(Critical Rule #2).

---

## 7. Phase 3 — Server artifact (relay, pair-relay, admin)

**Blocked by B1 and B3.** Do not start until both are resolved.

### 7.1 Establish real AWX and dev state (resolves B5)

```bash
AWX=https://awx.bjzy.me
awx --conf.host $AWX job_templates get 215 -f json   # Buzz - Manage - Prod
awx --conf.host $AWX job_templates get 222 -f json   # Buzz - Manage - Dev
awx --conf.host $AWX job_templates get 216 -f json   # Buzz - Configure HAProxy Routing (Prod)
awx --conf.host $AWX job_templates get 223 -f json   # Buzz - Configure HAProxy Routing (Dev)
awx --conf.host $AWX projects get 8   -f json        # Home Lab Ansible - Production
awx --conf.host $AWX schedules list --job_template 215 -f human
```

Record: template existence, project/inventory/playbook/limit, current SCM
revision, survey spec, schedule IDs 50/51 and their `next_run`. Compare against
`awx/buzz/*.yml` and `awx/devbuzz/*.yml` in homelab-playbooks. If the dev
surface is genuinely unapplied, apply it with `awx/devbuzz/apply.sh` as a
prerequisite and record the result.

### 7.2 Build and publish the artifact

1. Build the Linux AMD64 server binaries from the **merged fork SHA** from §6.6
   (not upstream), producing `buzz-relay`, `buzz-admin`, `buzz-pair-relay`.
2. Publish with the **new source-controlled publisher from B1**, in `--check`
   mode first, then for real.
3. Record: source SHA, `source_image`, `source_index_digest`,
   `source_amd64_manifest_digest`, resulting Harbor tag
   (`<branch>-<short-sha>-amd64`), OCI manifest digest, and the SHA-256 of each
   of the three binaries.

Note the existing pin does **not** record a `buzz_pair_relay_binary_sha256`
(`roles/buzz/defaults/main.yml` has it empty). Populate it in this delivery so
the pair-relay sidecar gets the same integrity guarantee as the other two
binaries, and extend the role's verification and its unit test accordingly.

### 7.3 Human-gated actions **[HUMAN]**

Exactly three actions in this entire plan require the human. Batch them into a
single request; do not spread them out.

1. **[HUMAN] Vault pin promotion values.** If your Vault token lacks write
   capability on `kvProd_v2/Buzz/*`, you must not acquire one by another route.
   Provide BrianInAz the exact non-secret field/value pairs to set
   (`binary_ref`, `binary_oci_digest`, `buzz_relay_sha256`, `buzz_admin_sha256`,
   `buzz_pair_relay_sha256`, `source_image`, `source_index_digest`,
   `source_amd64_manifest_digest`), Development first, then Prod. If your token
   *does* have write capability, do it yourself via `vault kv patch` and record
   the version numbers.
2. **[HUMAN] B2 mobile decision** (§4.2) — Option B2-A or B2-B.
3. **[HUMAN] Drag the built `Buzz.app` to Applications** if, and only if, the
   scripted state-preserving install in §9.3 is unavailable. The scripted path
   is preferred and is fully automatable; prefer it.

### 7.4 GitOps pin promotion

On a `feature/` branch off `develop` in homelab-playbooks:

- `roles/buzz/defaults/main.yml`: `buzz_binary_oci_ref`,
  `buzz_binary_oci_digest`, `buzz_relay_binary_sha256`,
  `buzz_admin_binary_sha256`, `buzz_pair_relay_binary_sha256`.
- `tests/fixtures/buzz_native_bin_manifest.json`.
- `roles/hermes/defaults/main.yml` — the Hermes `buzz` CLI pin (§2.1 item 8).
- `docs/runbooks/buzz-hermes-version-pinning.md` — the authoritative version record.
- New publisher script + runbook from B1.
- Registry updates from §3 (retire D2, refresh D1/D3/D5 `source_lock`, add the
  §3.2 entries).

Then:

```bash
source .venv/bin/activate      # or the repo's existing venv
python3 -m pytest -q tests/unit/test_buzz_role_contracts.py
python3 -m pytest -q tests/unit/test_buzz_release_boundary.py
python3 -m pytest -q tests/unit/test_upstream_deviation_management.py
python3 scripts/validate_upstream_deviations.py --check
python3 scripts/render_upstream_deviation_docs.py --check
ansible-lint playbooks/Buzz-manage.yml
yamllint roles/buzz/
```

PR into `develop`, merge, then promote `develop` → `main`, then sync AWX
project 8 to the promoted `main` revision.

**STOP condition:** `develop` not promoted to `main`, or AWX project revision not
matching the promoted `main` — do not launch a production job against a stale
project revision.

---

## 8. Phase 4 — Relay deployment (dev first, then prod)

Authoritative procedure: `docs/runbooks/buzz-production-lifecycle.md`. **All
deployment runs through AWX. Never run `ansible-playbook` by hand against these
hosts.**

### 8.1 Dev certification (host `devbuzz`, template 222)

1. Capture baseline metrics before touching anything.
2. `operation=backup`.
3. `operation=status` and `operation=test` — record pre-state.
4. `operation=install` — picks up the new pin.
5. `operation=status`, `operation=test`.
6. Verify `curl -H 'Accept: application/nostr+json' https://devbuzz.bjzy.me/ | jq -r .version` → `0.2.1`.
7. Verify pair-relay: `jq -r .pairing_relay_url` from the same NIP-11 payload, and that `https://devbuzz.bjzy.me/pair` upgrades to a WebSocket.
8. Verify NIP-AD survived: kinds 44300/44301 still accepted, drafts publish and resolve via the `buzz` CLI against dev.
9. Record every AWX job ID, SCM revision, and status.

**STOP condition:** any dev gate fails → do not touch production. Registry
`production_blocked_when_development_blocked` is `true`.

### 8.2 Production (host `buzz`, template 215)

Follow `buzz-production-lifecycle.md` exactly, including the Alertmanager
silence and PromQL baselines:

```bash
amtool silence add \
  --duration=60m \
  --comment="Buzz relay 0.2.1 upgrade" \
  --alertmanager.url=http://alertmanager.bjzy.me:9093 \
  'alertname=~ProdBuzz(Readiness|Metrics)Unavailable' \
  'source=mimir' 'tenant=Bjzy.Labs' 'environment=production'
```

Baselines to capture before and compare after — these must **not decrease**:
`sum(buzz_community_messages)`, `sum(buzz_community_channels)`,
`sum(buzz_community_workflows)`, `sum(buzz_total_subscriptions)`,
`sum(buzz_total_relay_members)`, `sum(buzz_total_storage_objects)`,
`sum(buzz_total_storage_bytes)`.

Sequence: `backup` → `status` → `test` → `install` → `status` → `test` →
readiness and metrics verification → historical-total comparison → remove the
silence.

Post-install verification:
- `curl -sk https://buzz.bjzy.me/_readiness` → `200` and `ready`.
- `up{job="buzz-prod-metrics"} == 1`, `probe_success{job="buzz-prod-readiness"} == 1`.
- NIP-11 `version` → `0.2.1`.
- Pair-relay reachable at `/pair`.
- Grafana dashboard `buzz-production` healthy; no firing Buzz alerts.
- Schedules 50 and 51 still enabled with future `next_run`.

**STOP conditions:**
- Any historical total decreases → **stop all writes immediately**, preserve
  evidence, do not attempt a manual restore, escalate.
- Readiness or metrics fail → roll back per §11 and do not remove the silence
  while Buzz is unhealthy.
- `uninstall-purge` is never used.

### 8.3 Hermes CLI pin rollout

After the relay is accepted, roll the Hermes `buzz` CLI pin through the Hermes
AWX templates (dev 198 first, then prod) so agents and relay match. Verify
Hermes Buzz presence still works — online, heartbeat, graceful offline,
reconnect, message delivery — and re-run the Hermes runtime deviation monitor.
Record whether `hermes-buzz-presence-lifecycle-v1` classification changed.

---

## 9. Phase 5 — macOS Desktop client and CLI

### 9.1 Build

Use the fork's native Apple Silicon canary builder against the **merged fork
SHA** from §6.6, updated in §6.3 to a single-patch series:

```bash
cd /Users/b/Code/homelab-playbooks/<worktree>
source /Users/b/Code/buzz/grok-deploy-new-version/bin/activate-hermit
scripts/build_buzz_fork_canary_macos.sh <merged-fork-sha> \
  "/Users/b/Downloads/Buzz Upgrade v0.5.17/<sha12>"
```

The script fails closed on: non-Darwin/non-arm64, existing output directory,
remote SHA mismatch, patch conflict, missing or zero-byte sidecars, missing
Tauri bundle. **Real release sidecars are mandatory** — placeholder stubs are
forbidden. Outputs: DMG, `manifest.json`, `fork-canary.patch`, `SHA256SUMS`.

If the hosted path is used instead, the fork is verified public with parent
`block/buzz` (P1.1), so the free standard `macos-15` ARM64 runner is authorized
under Critical Rule #10. Note that
`docs/runbooks/buzz-contextual-fork-canary.md` forbids an *agent* starting a
hosted macOS runner for the canary lane — so prefer the native local build.

### 9.2 Private WSS gate

```bash
gh workflow run buzz-private-ca-wss-gate.yml \
  --repo BjzyLabs/homelab-playbooks --ref main \
  -f upstream_sha=<merged-fork-sha> \
  -f source_repository=BrianInAz/buzz \
  -f source_ref=main
```

Must be green before any installation. **STOP condition:** gate red → do not
install; keep the current app as the rollback control. Never repair the gate by
adding network access, expanding a Tailnet ACL, or bypassing TLS.

### 9.3 Install (state-preserving, scripted)

```bash
scripts/install_buzz_fork_canary_macos.sh install \
  "/Users/b/Downloads/Buzz Upgrade v0.5.17/<sha12>"
```

This verifies `SHA256SUMS`, mounts the DMG, checks bundle ID
`xyz.block.buzz.app`, verifies the ad-hoc signature, quits the running app,
archives the current app to `/Users/b/Applications/Buzz Rollback/<receipt-dir>/`,
installs the new bundle, writes `INSTALL-RECEIPT.json`, and launches it. It does
not touch identity, Keychain, Application Support, or history.

Because this is fully scripted, **the human does not need to drag anything**.
Only fall back to **[HUMAN]** drag-to-Applications if this script fails, and
report why it failed.

### 9.4 CLI verification

`/Users/b/.local/bin/buzz` is a symlink into the app bundle, so it upgrades
automatically. Confirm the symlink still resolves and the CLI runs:

```bash
ls -la /Users/b/.local/bin/buzz
buzz --help
buzz drafts --help      # NIP-AD surface must still exist
```

### 9.5 Runtime acceptance

All must pass on the installed artifact. Record each:

- Identity reused; owner status intact; no re-auth prompt.
- Connects to `wss://buzz.bjzy.me` over the private CA (validates D1).
- History present and complete.
- Send and receive work.
- Contextual agent conversations: single-agent replies flat, multi-agent in
  shared threads (validates D3).
- Persistent audience chips render by name; draft-local and persistent removal;
  mention hydration removal; `@mention` re-addition (validates D5).
- NIP-AD drafts publish, list, and resolve.
- Full quit → relaunch → reconnect → history restored.

**STOP condition:** any acceptance item fails → roll back per §11, keep the
registry entries un-promoted, and report.

---

## 10. Phase 6 — iOS / mobile

**Entirely gated by B2 (§4.2). Do not start until BrianInAz has chosen an
option.**

- **If B2-A:** deliver the governed mobile canary lane (build script, device
  install/rollback script, runbook, registry entry, tests) and only then build,
  install to `MyPhone`, and run cross-client acceptance: identity preservation,
  persistent audience, thread isolation, explicit mentions, failure behaviour,
  mentions-only mode, and continuity against the upgraded relay.
- **If B2-B:** do not build or install any iOS artifact. Keep
  `buzz-mobile-persistent-agent-audience-v1` at `proposed` / `stale`, record the
  deferral in the registry, Notion, and Beads with a named follow-up, and state
  plainly in the final report that the iPhone still runs its previous app.

---

## 11. Rollback

Each lane rolls back independently. Never mix them.

| Lane | Rollback |
|---|---|
| Desktop app | `scripts/install_buzz_fork_canary_macos.sh rollback "/Users/b/Applications/Buzz Rollback/<receipt-dir>"`. Preserves the failed candidate for diagnosis. Prove identity, community, reconnect, and history after restoring. |
| `buzz` CLI | Follows the app bundle; no separate action. |
| Relay (prod/dev) | Restore the previous Vault pin and role defaults (previous prod pin: `nip-ad-ba8826c9-amd64` @ `sha256:e63072f1067567bfa90d62aa75b950f5043e60b85a40b159abeaafae02eddcc7`), promote through GitFlow, and re-run AWX `install`. **Never** hand-edit the host or run Ansible manually. |
| Hermes CLI pin | Restore `native-roots-0f7edef1-amd64` @ `sha256:94d31fbc762118e137cbceda70ada3e0391cb54092473417414182245f5656c5` and re-run the Hermes AWX template. |
| Fork `main` | Revert the Phase 2 merge commit via a new PR. Do not force-push. Pre-rebase head is recorded in `/tmp/buzz-fork-main-pre-rebase.txt`. |
| Data | Backups via AWX `operation=backup`; restores only via `operation=restore-verify` with `restore_selector`. Never restore outside the AWX contract. |

---

## 12. Documentation obligations

Nothing is complete until the desired state exists in Git and is mirrored where
the SOP requires.

### 12.1 Git

**Buzz fork** (`BrianInAz/buzz`):
- This plan (already committed).
- Rebased series on `main` via the Phase 2 PR.
- `docs/operations/private-ca-desktop-release-lifecycle.md` updated to the
  single-patch series.
- `.github/workflows/private-ca-release.yml` and
  `scripts/build-private-ca-macos.sh` with the obsolete `SECURITY_PATCH_COMMIT`
  removed.
- If NIP-AD is renumbered, the migration and its references.

**homelab-playbooks** (`BjzyLabs/homelab-playbooks`, `feature/` → `develop` → `main`):
- `docs/upstream-deviations.json` — retire D2; refresh D1/D3/D4/D5 `source_lock`
  to the new base; add the seven §3.2 entries; update `snapshot_utc`.
- `docs/current-upstream-deviations.md` — regenerated, never hand-edited.
- New: `scripts/buzz/publish_buzz_native_bin.py` and
  `docs/runbooks/buzz-native-bin-publisher.md` (B1).
- `roles/buzz/defaults/main.yml`, `roles/hermes/defaults/main.yml`,
  `tests/fixtures/buzz_native_bin_manifest.json` — new pins.
- `docs/runbooks/buzz-hermes-version-pinning.md` — new authoritative versions.
- `scripts/build_buzz_fork_canary_macos.sh` — single-patch series.
- `docs/evidence/buzz-upgrade-v0.5.17-<date>.md` — full evidence record.
- If B2-A: the mobile canary lane files.
- New/updated unit tests for every contract changed.

Before declaring done: `git status --short --branch` in both repos, classify
every modified and untracked file, remove only proven-unused local artifacts,
delete merged task branches per the cleanup standard, and state the next
GitFlow step.

### 12.2 Notion

Update these existing pages (do not create duplicates):

| Page | ID | What to update |
|---|---|---|
| Buzz — Private Community Relay | `3aa3569a-a255-8168-b633-d840da8b324f` | New relay/desktop versions, new Harbor pin, AWX job IDs, acceptance evidence |
| Current Homelab Upstream Deviations | `3b03569a-a255-81cf-8434-cfff70a26897` | Mirror the regenerated dashboard; Git remains authoritative |
| Upstream Deviation Management SOP | `3b03569a-a255-81d5-af88-eb03db2865a4` | Only if the SOP itself changes |
| Buzz Contextual Conversations Fork Canary | `3b23569a-a255-814c-a600-e875c42e905d` | New base SHA, rebased PR refs, promotion state |
| Upstream Watchlist (database) | `eed01786-2875-4ef5-9fdb-6115924dc62b` | Row for `desktop-v0.5.17`; close the RUSTSEC-2026-0224 watch item |
| Buzz iOS Peer-Presence Hydration Remediation | `3b83569a-a255-81ab-8970-fbc7ea4dd211` | Mobile status under the B2 decision |

Create **one** new page under the Buzz operations hub: *"Buzz Platform Upgrade
to desktop-v0.5.17"* containing the plan summary, the deviation reconciliation
table, blocker resolutions, evidence links, and the final acceptance matrix.
Never put secrets or identity material in Notion.

### 12.3 Beads

Progress tracking is mandatory (Critical Rule #6).

- **homelab-playbooks**, prefix `tailscale-vault-of5`: create an epic for this
  upgrade; children for each phase and each new registry entry. Link the
  existing children `tailscale-vault-of5-213.1` (private-CA),
  `tailscale-vault-of5-213.6` (**close on D2 retirement**),
  `tailscale-vault-of5-215.6.1/.2/.3`, `tailscale-vault-of5-215.7.1`.
- **Buzz fork**, prefix `ios-buzz` (per `.beads/issues.jsonl`): items for the
  fork-side rebase and mobile work.
- Run `scripts/setup_beads_git_integration.sh --check` at session start;
  Beads syncs on the `beads-sync` branch, not feature branches.

### 12.4 Upstream contribution hygiene

- **Close `block/buzz#4256`** with an explanation that upstream removed
  `nostr-relay-pool` so the fix is moot.
- Rebase and refresh `block/buzz#4688` and `#4689` onto `desktop-v0.5.17` so
  they remain mergeable.
- Open the standalone mobile persistent-audience PR once #4688 merges.
- Note in `block/buzz#2940` / `#3455` that the private-CA gap still reproduces
  at `desktop-v0.5.17`, with evidence.

---

## 13. Definition of done

Phase-by-phase. Every row needs recorded evidence.

| # | Criterion |
|---|---|
| 1 | Phase 1 checks all pass, or a failure is reported as a blocker. |
| 2 | Fork `main` rebased onto `c3bfd66947978fae93f4cfb46bea98ba20e32ccf`; obsolete security patch and `ad9e7c31d` removed; all §6.5 gates green; PR merged. |
| 3 | Source-controlled Harbor publisher exists, is tested, and is merged (B1 cleared). |
| 4 | New `buzz-native-bin` artifact published; digest and all three binary checksums recorded; pins promoted in Git and Vault. |
| 5 | devbuzz reports relay `0.2.1`; pair-relay reachable; NIP-AD functional; dev certified. |
| 6 | buzz.bjzy.me reports relay `0.2.1`; readiness/metrics green; **no historical total decreased**; schedules 50/51 intact; silence removed. |
| 7 | Hermes `buzz` CLI pin rolled; Buzz presence and delivery verified. |
| 8 | `/Applications/Buzz.app` rebuilt on `desktop-v0.5.17` with private-CA trust; private WSS gate green; all §9.5 acceptance items pass; rollback bundle archived with a receipt. |
| 9 | `buzz` CLI resolves and `buzz drafts` works. |
| 10 | Mobile handled per the B2 decision, with the outcome recorded either way. |
| 11 | Registry: D2 retired as a tombstone; D1/D3/D4/D5 `source_lock` refreshed; the seven §3.2 entries registered; validator and renderer `--check` pass; no fork-only commit is unaccounted for (B4 cleared). |
| 12 | Notion pages updated; the new upgrade page exists; Upstream Watchlist current. |
| 13 | Beads epic and children reflect reality; `tailscale-vault-of5-213.6` closed. |
| 14 | Upstream PR hygiene done (#4256 closed; #4688/#4689 rebased). |
| 15 | Both repos clean; merged task branches deleted; no untracked agent artifacts; next GitFlow step stated. |

---

## 14. Prohibited actions

Never, under any circumstance in this plan:

- Put a secret, token, private key, or identity in AWX `extra_vars`, a survey,
  Git, Beads, Notion, a log, or chat.
- Use a Vault root token, or place one on disk.
- Broaden a Tailscale ACL, add a wildcard port, or grant a CIDR to fix
  reachability. Required paths are exact-port only. `tag:operator-hw` is the
  only sanctioned wildcard and is never applied to a server or agent host.
- Bypass TLS verification, add a `danger_accept_invalid_certs`-style escape, or
  disable certificate validation to make a connection work.
- Add a `cargo-deny` ignore, skip an advisory scan, or narrow a scan's scope to
  make it pass.
- Stub a module into `sys.modules` or mock a missing dependency at module scope
  to make an import succeed. Install the dependency into the project venv.
- Install to system Python.
- Merge with failing tests or checks; use `--no-verify`; force-push; admin-merge
  past a branch guard.
- Run `ansible-playbook` manually against `buzz` or `devbuzz`.
- Use `uninstall-purge`.
- Promote to production while dev certification is `stale` or `blocked`.
- Sign out of Buzz, clear app data, reset the Keychain, regenerate or import an
  identity, remove a community, or delete message history.
- Disable Gatekeeper globally.
- Start a hosted macOS or Windows runner for any repository that is not verified
  public with parent `block/buzz`.
- Install an iOS artifact before the B2 decision is recorded.
- Hand-run an undocumented `oras push` to Harbor in place of the B1 publisher.
- Commit the human's unrelated Ruler-sync working-tree changes (§6.1).

---

## 15. Evidence to report at the end

Produce a single closeout with:

1. Upstream base SHA used and every tag involved.
2. Fork pre- and post-rebase SHAs; the merge commit; the PR URL.
3. Full `git cherry` census, before and after.
4. Deviation reconciliation outcome per entry, with the verification command
   output that justifies it.
5. Harbor tag, OCI digest, and the three binary SHA-256 values.
6. Vault pin versions changed (field names and version numbers only — never
   values).
7. Every AWX job ID with template, operation, SCM revision, and status.
8. Before/after metric baselines for prod.
9. Desktop DMG SHA-256, install receipt path, rollback directory, and the §9.5
   acceptance results.
10. The B2 decision and what was done about mobile.
11. All Git commits, PRs, merges, and promotions in both repos.
12. Notion pages updated or created; Beads IDs created or closed.
13. Every gate that failed and how it was resolved — or, if unresolved, the
     exact blocker, with no attempt to paper over it.
