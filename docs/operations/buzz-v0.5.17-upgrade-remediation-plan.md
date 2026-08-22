# Buzz Platform Upgrade Remediation Plan — `desktop-v0.5.17`

**Plan ID:** `BUZZ-UPGRADE-2026-08-19`
**Authored:** 2026-08-19 (Cursor / Claude Opus 5)
**Reviewed for execution:** 2026-08-19 (Cursor / Grok 4.6) — credential bootstrap, CLI-only delivery, standing decisions, Linux AMD64 build, Hermes `buzz` layer, and AWX launch commands were added so this document is executable without further design.
**Intended executor:** Grok 4.6 Medium
**Accountable approver:** BrianInAz
**Responsible role:** BjzyLabs homelab platform
**Notion mirror (non-secret):** [Buzz Platform Upgrade to desktop-v0.5.17](https://app.notion.com/p/3c23569aa25581dc83e7ca6ae7e28478) — Git is authoritative if the two drift.
**Standing authorization:** BrianInAz asked the implementing agent to execute this plan end-to-end by CLI/API. Normal non-force GitFlow (commit, push, PR, merge, `develop`→`main` promotion), AWX launches including Production Buzz JT 215 and Hermes JT 199, Vault pin patches, Harbor publication via the source-controlled publisher, and the scripted desktop install are **already authorized**. Do not stop to re-ask for those. Stop only on a **STOP condition** in this document.

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
   capture. Record it as you go (closeout is §15). Never claim a result you did not
   observe in command output.
4. **Verify presence, never print secrets.** You may confirm a Vault field
   exists and is non-empty. You must never echo, log, or copy a secret value,
   private key, token, or identity into chat, files, Git, Beads, Notion, or AWX.
5. **No leftover human gates.** There are **zero** `[HUMAN]` wait-for-Brian steps in this plan. Standing decisions are in §0.7. If a credential or capability is missing, **fail fast and report** — do not invent a workaround and do not wait indefinitely for a human to paste values.
6. **Never destroy client state.** No signing out, no clearing app data, no
   Keychain reset, no identity regeneration, no removing a community, no
   deleting message history. The macOS app upgrade is state-preserving by
   design; if a step would violate that, stop.
7. **Read the referenced runbook before executing a phase that cites one.** This
   plan references runbooks rather than duplicating them, so the runbook is
   authoritative on procedure detail. If the runbook and this plan conflict,
   stop and report the conflict.
8. **Read the matching skill before using that tool.** Catalog in §0.4. Skills live under `~/.config/ruler/.ruler/skills/<name>/SKILL.md`. Do not improvise auth; copy the skill's smart-auth pattern.

### 0.2 Repositories and worktrees

| Purpose | Path | Remote | Branch model |
|---|---|---|---|
| Buzz fork (app source) | `/Users/b/Code/buzz/grok-deploy-new-version` | `origin` = `BrianInAz/buzz`, `upstream` = `block/buzz` | `main` only, no `develop`, no GitFlow guard |
| Buzz human worktree | `/Users/b/Code/buzz/human` | same | do not use for agent work |
| Homelab ops (registry, roles, AWX, runbooks) | `/Users/b/Code/homelab-playbooks/grok` | `BjzyLabs/homelab-playbooks` | `develop` → `main`, GitFlow guard **enforced** |

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

### 0.4 Skills and CLIs (mandatory; mostly already authed)

Read each skill file **before** first use. If a CLI is not authed, follow the skill — **Vault CLI is the credential source of truth**. Never invent tokens, GitHub secrets, or `extra_vars`.

| Domain | Skill | CLI / interface | Auth pattern (fail closed) |
|---|---|---|---|
| Vault | `~/.config/ruler/.ruler/skills/vault-cli/SKILL.md` | `vault` | `export VAULT_ADDR=https://vault.bjzy.me:8200`; `vault token lookup`; if fail: `vault login -method=userpass username=$USER` (**never root**) |
| AWX | `~/.config/ruler/.ruler/skills/awx/SKILL.md` | `awx` **always with `--conf.insecure`** | `awx me --conf.insecure`; if fail: `export TOWER_HOST=https://awx.bjzy.me` and `export TOWER_OAUTH_TOKEN=$(vault kv get -field=api_token kvProd_v2/AWX/API)` then assert `/me` username is `b`. **Do not use `kvProd_v2/AWX/Agents`** — that token cannot launch Production Buzz. |
| Buzz CLI | `~/.config/ruler/.ruler/skills/buzz/SKILL.md` | `buzz` | Load owner key from Keychain into `BUZZ_PRIVATE_KEY` without echoing (skill snippet). Presence only: `test -n "$BUZZ_PRIVATE_KEY" && echo key=present`. |
| Beads | `~/.config/ruler/.ruler/skills/beads/SKILL.md` | `bd` | Homelab: `scripts/setup_beads_git_integration.sh --check` then `bd list`. Commands: `bd create`, `bd update --claim`, `bd close`, `bd dep add`. **There is no `bd create-epic` / `bd create-task` on this install** — use `bd create "Epic: …"` then `bd create "<epic-id>.1" "…"`. |
| Harbor / OCI | `~/.config/ruler/.ruler/skills/skopeo/SKILL.md` + `oras` | `skopeo`, `oras` | Runtime Vault robots. `skopeo inspect --tls-verify=false`. Never log `--creds`. |
| GitHub | (builtin `gh`) | `gh` | `gh auth status`. Must write `BrianInAz/buzz` and `BjzyLabs/homelab-playbooks`. |
| GitHub KB (read-only) | `~/.config/ruler/.ruler/skills/github-knowledge-base/SKILL.md` | files under `~/ops/github-knowledge-base` | Optional context. Do not write the KB. |
| Tailnet | `~/.config/ruler/.ruler/skills/tailnet-acl/SKILL.md` | — | Read-only if a reachability question arises. **Never edit ACLs.** |
| Token lifecycle | `~/.config/ruler/.ruler/skills/token-lifecycle/SKILL.md` | `vault` + Notion | Only if a new long-lived token is minted. Prefer not to mint; reuse robots. |
| Notion | Notion MCP (`user-Notion`) | `notion-fetch`, `notion-update-page` | If MCP tools are missing, run tool discovery then retry. Do not skip the Notion mirror. |
| Grafana / Mimir | `~/.config/ruler/.ruler/skills/use-grafana-mcp/SKILL.md` **or** direct metrics | Prefer `curl` to `http://100.75.115.112:9102/metrics` (prod relay) for baselines. Grafana UI: `https://grafana.bjzy.me/d/buzz-production/buzz-production-overview` |
| Session closeout | `~/.config/ruler/.ruler/skills/cleanup/SKILL.md` | git | After all delivery boundaries. Do not delete long-lived branches. |
| Hermes | No dedicated ruler skill. Follow AGENTS.md Hermes section + `docs/runbooks/hermes-*.md` in homelab-playbooks. | AWX JT 198 / 199 | After relay pin is live. Launch with `operation` only — template extra_vars already set `hermes_environment`. |

### 0.5 Exact local paths (do not invent worktrees)

| Repo | Worktree you use | Do not use |
|---|---|---|
| Buzz fork | `/Users/b/Code/buzz/grok-deploy-new-version` | `/Users/b/Code/buzz/human` |
| homelab-playbooks | `/Users/b/Code/homelab-playbooks/grok` | parent `/Users/b/Code/homelab-playbooks` (container only — see `START_HERE.md`), and `human/` |

Homelab GitFlow: `cd /Users/b/Code/homelab-playbooks/grok && git fetch origin && git checkout develop && git pull --ff-only && git checkout -b feature/buzz-upgrade-desktop-v0.5.17`. Verify prefix with `git branch --show-current` before every commit and `gh pr create`. Allowed PR heads: `feature/` `fix/` `chore/` `docs/` `bugfix/` `hotfix/` `codex/` `cursor/` `copilot/` `dependabot/`. **`agent/` is forbidden** on this repo.

### 0.6 Credential bootstrap — run this BEFORE any other phase

Copy this block. If any check fails, **stop the entire plan** and report the failed ID. Do not continue "around" it.

```bash
set -euo pipefail
export VAULT_ADDR=https://vault.bjzy.me:8200
export TOWER_HOST=https://awx.bjzy.me

# C0 Vault session
if ! vault token lookup >/dev/null 2>&1; then
  vault login -method=userpass username="$USER"
fi
vault token lookup -format=json | jq '{ttl: .data.ttl, policies: .data.policies, display_name: .data.display_name}'

# C1 AWX as operator b (Production launches require this identity)
export TOWER_OAUTH_TOKEN="$(vault kv get -field=api_token kvProd_v2/AWX/API)"
awx me --conf.insecure | jq -e '.results[0].username == "b"'
# STOP if this is "agents" — that identity cannot launch JT 215.

# C2 GitHub
gh auth status
gh api user --jq .login
gh api repos/BrianInAz/buzz --jq '{visibility,fork,parent:.parent.full_name}'
gh api repos/BjzyLabs/homelab-playbooks --jq .full_name

# C3 Buzz owner identity present (never print)
export BUZZ_RELAY_URL="https://buzz.bjzy.me"
export BUZZ_PRIVATE_KEY="$(
  security find-generic-password -s buzz-desktop -a secrets -w \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])'
)"
test -n "$BUZZ_PRIVATE_KEY" && echo "buzz_owner_key=present" || { echo "buzz_owner_key=MISSING"; exit 1; }
unset BUZZ_PRIVATE_KEY   # re-load later only when a buzz command needs it

# C4 Docker (required for linux/amd64 relay binaries on this Mac)
docker version >/dev/null
docker buildx version >/dev/null

# C5 oras + skopeo
command -v oras
command -v skopeo
```

Then presence-only Vault inventory (keys only, never values):

```bash
# Required application + pin fields
vault kv get -format=json kvProd_v2/Buzz/Prod | jq -r '.data.data | keys[]' | sort
vault kv get -format=json kvProd_v2/Buzz/Development | jq -r '.data.data | keys[]' | sort

# Harbor robots — list the mount, then require Puller plus publisher identities
vault kv list kvProd_v2/Harbor/
# Expected at minimum: Buzz-Puller. Discover Buzz-Admin / Buzz-Publisher (or equivalent
# names) from this list. Record exact path names. STOP if no publisher robot exists.
for p in Buzz-Puller Buzz-Admin Buzz-Publisher; do
  if vault kv get -format=json "kvProd_v2/Harbor/$p" >/dev/null 2>&1; then
    echo "harbor_robot=$p present fields=$(vault kv get -format=json "kvProd_v2/Harbor/$p" | jq -r '.data.data | keys | join(",")')"
  else
    echo "harbor_robot=$p MISSING"
  fi
done

vault kv get -format=json kvProd_v2/Backups/S3 | jq -r '.data.data | keys[]'

# Write capability probe on pin metadata (non-secret fields). Do not change values yet.
# If this returns permission denied, STOP — you cannot promote pins.
vault kv get -format=json kvProd_v2/Buzz/Development | jq -r '.data.metadata.version'
```

**STOP if:** Vault login fails; AWX `/me` is not `b`; `gh` cannot write both repos; Buzz Keychain identity missing; Docker/buildx missing; `Buzz-Puller` missing; no Harbor publisher robot; Vault denies read on `Buzz/Prod` or `Buzz/Development`.

### 0.7 Standing decisions (locked — do not re-open)

| ID | Decision | Why |
|---|---|---|
| D-mobile | Skip iOS/Android install (Option B2-B). Rebase mobile **source** only. | BrianInAz, 2026-08-19. |
| **D-1-B** | Canonical private-CA implementation is **native-roots feature flag** (fork PRs #17/#22/#23). Do **not** cherry-pick `6d03a38` onto the rebase. Keep `origin/fix/macos-private-ca-websocket` as the upstream contribution vehicle for `block/buzz#3455` only. | This is what `/Applications/Buzz.app` and the Hermes CLI pin already run. Applying both TLS stacks is forbidden. |
| D-artifact | One Harbor artifact per upgrade SHA containing **four** Linux AMD64 binaries: `buzz-relay`, `buzz-admin`, `buzz-pair-relay`, and `buzz` (CLI). Buzz hosts and Hermes both pin that digest. | Eliminates relay/CLI version skew. Hermes `buzz_binary.yml` installs file `buzz` from the OCI pull. |
| D-prod | Production AWX launches (JT 215, JT 199) are in scope once Dev certification passes. | User authorized full execution of this plan. |

### 0.8 Execution order (do not skip ahead)

1. Read every skill in §0.4. Copy auth from the skill, not from memory.
2. Run §0.6 credential bootstrap. Any failed ID stops the entire plan.
3. Create Beads epic + children (§4.1 B1.5). Claim `$EPIC.1`.
4. Phase 0 — TDD the Harbor publisher in `homelab-playbooks/grok` on `feature/buzz-upgrade-desktop-v0.5.17` off `develop`. Merge to `develop` before Phase 3 uses it.
5. Phase 1 — re-verify live state (§5). Read-only.
6. Phase 2 — rebase `BrianInAz/buzz` from **`origin/main`**, not from this docs-only branch. PR to `BrianInAz/buzz` `main`.
7. Phase 3 — Docker linux/amd64 extract → publisher `--check` then push → Vault Development pin → GitOps defaults.
8. Phase 4 — AWX Dev JT 222, then Prod JT 215, then Hermes JT 198 then 199.
9. Phase 5 — native canary build (scripts already updated to stop cherry-picking A/security) → WSS gate → scripted install → §9.5.
10. Phase 6 — **do not run.**
11. Closeout — registry, Notion, Beads, upstream PR hygiene (§12–§15).

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
| Relay binary pin (GitOps) | `harbor.bjzy.me/bjzy-custom/buzz-native-bin:nip-ad-ba8826c9-amd64` @ `sha256:e63072f1067567bfa90d62aa75b950f5043e60b85a40b159abeaafae02eddcc7` | new artifact | `rg -n 'buzz_binary_oci' /Users/b/Code/homelab-playbooks/grok/roles/buzz/defaults/main.yml` |
| Hermes `buzz` CLI pin | `harbor.bjzy.me/bjzy-custom/buzz-native-bin:native-roots-0f7edef1-amd64` @ `sha256:94d31fbc762118e137cbceda70ada3e0391cb54092473417414182245f5656c5` | new artifact | `rg -n 'hermes_buzz_cli_binary_oci' /Users/b/Code/homelab-playbooks/grok/roles/hermes/defaults/main.yml` |
| iOS app on physical iPhone | unmanaged; no governed homelab artifact exists | **deferred (D-mobile / B2-B)** | §4.2 — do not install |

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
9. iOS/mobile app — **deferred (D-mobile).** Rebase source only. Do not install.
10. Deviation registry reconciliation, and the supporting runbooks, tests,
    role defaults, Vault pin metadata, Notion mirrors, and Beads records.

### 2.2 Explicitly out of scope, with evidence

Do **not** deploy these. Each was checked and is not in homelab use:

| Component | Why out of scope |
|---|---|
| `web/` and `admin-web/` bundles | The `buzz` Ansible role never sets `BUZZ_WEB_DIR` or an admin web root; native relays are headless. Verify with `rg -n 'BUZZ_WEB_DIR|admin_web' /Users/b/Code/homelab-playbooks/grok/roles/buzz/` returning no deployment wiring. |
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

### 3.0 Grouping principle: one deviation per originating fork PR

The registry's five Buzz entries do not line up with how the work was actually
done. The authoritative grouping is the **fork's own pull requests** — each PR
was one intended feature or fix. Verified mapping of all 74 commits:

| Fork PR | Branch | Commits | Belongs to |
|---|---|---|---|
| #2, #4, #5, #6, #7, #8, #10, #11 | private-CA release automation | 14 | D1 (tooling for it) |
| #12 | `codex/sync-upstream-main-20260803` | merges only | not a deviation |
| #13 | `codex/contextual-agent-conversations` | 9 | D3 |
| #14 | `codex/mobile-persistent-agent-audience` | 1 | D4 |
| #15 | `codex/desktop-agent-audience-editor` | **17** | D5 |
| #17, #22, #23 | CLI + desktop native TLS roots | 3 | **D1 (same root cause)** |
| #20 | `feat/nip-ad-durable-agent-drafts` | **20** | **D6 (new)** |
| #25, #34 | iOS peer-presence hydration | 2 | D7 (new) |
| #26, #29 | CI path filter, Sprig rolling release | 2 | D9 (new, CI-only) |
| #27 | mobile channel scroll anchor | 1 | D7 (new) |
| #28, #30 | desktop test isolation, atomic provider publish | 2 | D8 (new) |
| #31 | thread scroll anchor test | 1 | **DROP — now upstream** |
| #33 | flush stale channel autocomplete before Enter | 1 | D5 (same audience/autocomplete family) |
| — | obsolete RUSTSEC patch `7dbfcd785` | 1 | D2 → retire |

**Total: 74.** Every fork commit is accounted for, none orphaned. Verify with
`git cherry -v desktop-v0.5.17 main` and the per-PR extraction in §5.2.

Three grouping corrections this produces, all of which the current registry gets
wrong:

1. **The Docker `--locked` commits are not their own deviation.** `a6c86d6f0`,
   `e58fcd8af`, and `95ba0103a` are inside PR #20 — they exist because NIP-AD
   changed the dependency graph and broke the locked Docker build. They retire
   with NIP-AD, not independently.
2. **The private-CA release machinery is not its own deviation.** PRs #2–#11 are
   the build/CI tooling *for* D1 and already appear in D1's `affected_paths`.
   They belong inside D1.
3. **The TLS-trust work is one deviation, not two.** PRs #17, #22, and #23 have
   the same root cause as the registered private-CA entry and must be folded in
   (see §3.3, which is a more serious finding).

### 3.1 Findings — verified against `desktop-v0.5.17`

| Registry ID | Upstream status at `desktop-v0.5.17` | Verdict | Action |
|---|---|---|---|
| `buzz-macos-private-ca-v1` | **NOT fixed.** `desktop/src-tauri/src/native_websocket.rs` still calls plain `connect_async` with no platform verifier; `rustls-platform-verifier` is absent from the dependency graph. Upstream issue #2940 and PR #3455 both still **OPEN**. | Carry forward, **but rescope** | See §3.3. The registered patch is not the implementation we actually ship. |
| `buzz-desktop-nostr-signature-verification-v1` | **FIXED UPSTREAM.** `nostr-relay-pool` is **absent from both `Cargo.lock` and `desktop/src-tauri/Cargo.lock`** at `desktop-v0.5.17`. Upstream PR #4139 (`chore(deps): bump nostr-relay-pool for RUSTSEC-2026-0224`) merged 2026-08-01 as `9d6726e5b387310975f5809473ce8372f6fde0dc`; the crate was subsequently removed entirely. | **RETIRE** | Our patch `7dbfcd785be0a9c002863a793c4fbab89a6258c3` now **CONFLICTS** (verified: `UU Cargo.lock`, `UU desktop/src-tauri/Cargo.lock`) and is obsolete. Retire per §5.2. |
| `buzz-contextual-agent-conversations-v1` | Not upstream. Our PR `block/buzz#4688` is **OPEN**. | Carry forward | Rebase all **9** commits of fork PR #13; promote `proposed` → `active` only after runtime acceptance. |
| `buzz-mobile-persistent-agent-audience-v1` | Not upstream. No standalone upstream PR (sequenced behind #4688). | Carry source, **do not deploy** | Stays `proposed` / `stale`. Mobile deferred by decision (§4.2). |
| `buzz-desktop-removable-audience-chips-v1` | Not upstream. Our PR `block/buzz#4689` is **OPEN**. | Carry forward, **rescope** | Registry implies a single merge commit; the real series is **17** commits from fork PR #15 plus `f73b2bdd5` from PR #33. Most are audience-reconciliation stabilization fixes — dropping them re-introduces the send-race bugs they fixed. |
| `hermes-buzz-presence-lifecycle-v1` | Hermes lane, `certification_state: blocked`. | Out of this plan's mutation scope | After the relay upgrade, re-run the Hermes deviation monitor and record whether relay `0.2.1` changes presence behavior. Do not modify the transform here. |
| `hermes-openrouter-online-web-search-filter-v1` | Unrelated to Buzz versions. | No action | — |

**Bottom line on the request "identify anything that has been fixed since our
last build":** exactly one deviation has been fixed upstream — the
RUSTSEC-2026-0224 Nostr signature-verification bypass. It is now moot because
upstream dropped the vulnerable crate. One additional fork commit
(`ad9e7c31d`, thread scroll anchor test) has landed upstream and must be
dropped. Everything else we carry is still ours to carry.

### 3.2 The registered private-CA patch is not what we ship `[LOCKED: D-1-B]`

This is the most serious registry defect found, and it changes how D1 must be
rebased.

**There are two different, incompatible implementations of private-CA WSS
trust in this fork, and the registry documents the one we do not run.**

**Implementation A — registered in D1, used by the build scripts.**
Commit `6d03a38da5e3402bf97df1b3c46152887eb3778e`. Adds
`rustls-platform-verifier`, builds an explicit `Connector::Rustls` via
`ClientConfig::with_platform_verifier()`, and swaps `connect_async` for
`connect_async_tls_with_config`. Touches 5 files, ~65 lines of TLS code in
`native_websocket.rs` plus `commands/pairing.rs` and `huddle/relay_api.rs`.
**Verified: this commit is NOT an ancestor of fork `main`.** It exists only on
`origin/fix/macos-private-ca-websocket`. It is the commit that
`scripts/build-private-ca-macos.sh` and the homelab
`scripts/build_buzz_fork_canary_macos.sh` cherry-pick onto a base at build time,
and it is what upstream PR `block/buzz#3455` proposes.

**Implementation B — what fork `main` actually ships.** Fork PRs #17, #22, #23:

- `6e8523101` (#17) — root `Cargo.toml`: `tokio-tungstenite` feature
  `rustls-tls-webpki-roots` → **`rustls-tls-native-roots`**. Three lines.
- `7765d12ec` (#22) — same one-line feature swap in
  `desktop/src-tauri/Cargo.toml`, plus one `#[ignore]`d integration test.
- `0f7edef10` (#23) — one `#[ignore]`d CLI certification test.

**Implementation B contains no production code change at all** — it is a
dependency feature flag. Verified on fork `main`: `native_websocket.rs` still
calls plain `connect_async`, and both `Cargo.toml` files carry
`features = ["rustls-tls-native-roots"]`.

**What we actually run today is B.** The installed `0.5.3-bjzy` app was built by
the fork-canary path from fork `main` (receipt `source_sha`
`f2c5f9476d1db190c5b78f1b7ce0d6ee81bd7a24`), and the production Hermes `buzz`
CLI pin is literally named `native-roots-0f7edef1-amd64` after `0f7edef10`.

Consequences that must be fixed:

- D1's `implementation.patch_or_transform_reference` points at a commit that is
  not on fork `main`.
- D1's `affected_paths` lists `native_websocket.rs`, which is correct for A and
  wrong for B — B's real paths are the two `Cargo.toml` files and their lockfiles.
- D1 has **no CLI scope at all**, yet the production Hermes CLI depends on it.
- The build scripts cherry-pick A on top of a base that may already contain B,
  layering two TLS mechanisms.

**STOP condition:** do not rebase D1 using both implementations. Canonical choice is **D-1-B** (§0.7). Implementation A stays on `origin/fix/macos-private-ca-websocket` for upstream PR #3455 only. Build scripts must stop cherry-picking `6d03a38`.

### 3.3 Corrected deviation register

Nine entries, replacing the current five. Register or rescope each before
Phase 2 completes.

| ID | State | What it is | Commits | Runs where | Severity |
|---|---|---|---|---|---|
| **D1** `buzz-private-ca-wss-trust-v1` *(rescope of `buzz-macos-private-ca-v1`)* | active | Private-CA WSS trust for desktop **and** CLI (`rustls-tls-native-roots`), plus private-CA build/release machinery as tooling | **B only:** `6e8523101`, `7765d12ec`, `0f7edef10`. Plus machinery listed in §3.0. **Do not carry `6d03a38`.** | Desktop app; `buzz` CLI incl. **Hermes hosts** | critical-client-connectivity |
| **D2** `buzz-desktop-nostr-signature-verification-v1` | **retire** | Obsolete RUSTSEC-2026-0224 patch | `7dbfcd785` (**is** on fork main — drop it in the rebase) | nowhere after retirement | — |
| **D3** `buzz-contextual-agent-conversations-v1` | proposed → active on acceptance | Contextual agent conversation routing and reply placement | Fork PR #13, 9 commits: `78458eb84`, `88a1161a7`, `d6978d467`, `300b7b50c`, `bad53924a`, `3796ea4c6`, `af9d56ebc`, `445100d2d`, `ff08ba01d` | Desktop, ACP, mobile policy | client-conversation-routing |
| **D4** `buzz-mobile-persistent-agent-audience-v1` | stays proposed | Mobile persistent agent audience parity | Fork PR #14: `ac319b30c` | mobile source only — **not deployed** | mobile-conversation-continuity |
| **D5** `buzz-desktop-removable-audience-chips-v1` | proposed → active on acceptance | Removable persistent-audience chips **and** the audience-reconciliation stabilization series | Fork PR #15, 17 commits: `970f97a3b`, `0d8af4eb3`, `4d8c72bef`, `d7cd9d2dc`, `dc845ae62`, `e222d1884`, `87cba29dd`, `457314295`, `056db6fe7`, `333059ae8`, `8742c8473`, `9df4c9700`, `662e7d5c6`, `8a2ea4624`, `6b24b1751`, `683b826ce`, `2da9629aa`; plus PR #33 `f73b2bdd5` | Desktop | client-audience-control |
| **D6** `buzz-nip-ad-durable-agent-drafts-v1` **(new)** | active — **unregistered until now** | NIP-AD durable agent drafts and external agent adoption: kinds 44300/44301, relay ingest + read gate + FTS exclusion, migration `0027_agent_draft_fts.sql`, SDK builders, CLI `buzz agents draft-*`, desktop draft store and adoption UI, plus the Docker `--locked` and observer-REQ changes the feature required | Fork PR #20, 20 commits: `384d1525a`, `2400d8473`, `3a00282cb`, `fac7b6cd4`, `699c552eb`, `26252785b`, `113bfa266`, `1be4547a3`, `4ab0eb868`, `1c28f7203`, `e5a57cd5a`, `8447d9c31`, `d31ebe970`, `ba8826c94`, `a61e3b2e1`, `8b4dc5048`, `95ba0103a`, `e0f18f8bc`, `a6c86d6f0`, `e58fcd8af` | **Production relay** (`nip-ad-ba8826c9-amd64`) **and production DB schema** | **critical-server-feature** |
| **D7** `buzz-mobile-presence-and-scroll-v1` **(new)** | proposed | iOS peer-presence hydration and channel scroll-anchor preservation | Fork PRs #25/#34 `79bfb1d9b`, `f8e7e0c74`; PR #27 `594d8cc5c` | mobile source only — **not deployed** | mobile-correctness |
| **D8** `buzz-desktop-carried-fixes-v1` **(new)** | active | Atomic staged-provider publication and relay-admission test isolation | PR #30 `4ff406444`; PR #28 `4deea1a0d` | Desktop app | client-correctness |
| **D9** `buzz-fork-ci-hygiene-v1` **(new)** | active | Fork-only CI: desktop path-filter scope, Sprig rolling-release bootstrap | PR #26 `ef72743fb`; PR #29 `ce5acf44c` | fork CI only | ci-only |

**Dropped, not registered:** `ad9e7c31d` (PR #31) — equivalent patch is upstream
at `desktop-v0.5.17`. Do not reapply.

D6 is the entry that matters most. It is `critical-server-feature`, it is live
in production, it owns a database migration, and it had **no registry entry at
all** — so no upgrade gate has ever protected it. See Blocker B3.

Registration procedure is `docs/runbooks/upstream-deviation-management.md`. Each
entry needs the full schema-v2 field set, and
`python3 scripts/validate_upstream_deviations.py --check` plus
`python3 scripts/render_upstream_deviation_docs.py --check` must pass.

Note that `a7faf67d9` (`fix(ci): certify Buzz security patch series`) exists to
certify the D2 patch that is being retired. Re-evaluate it during the rebase: if
its only purpose was the obsolete security commit, retire it with D2 rather than
carrying it under D1.

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

**This is Phase 0. Build it before anything else touches the server lane.**

#### B1.1 Deliverables

All in `BjzyLabs/homelab-playbooks`, on a `feature/` branch off `develop`:

| Path | Purpose |
|---|---|
| `scripts/buzz/publish_buzz_native_bin.py` | The publisher |
| `tests/unit/test_publish_buzz_native_bin.py` | Unit tests (written **first**) |
| `docs/runbooks/buzz-native-bin-publisher.md` | Operator runbook |
| `tests/fixtures/buzz_native_bin_manifest.json` | Extend for `buzz-pair-relay` |
| `docs/runbooks/buzz-release-boundary.md` | Update to reference the real script |

#### B1.2 Required behaviour (the contract the tests encode)

1. **Refuses to run in CI.** Exits non-zero if `CI`, `GITHUB_ACTIONS`, or
   `GITHUB_RUN_ID` is set. The boundary runbook forbids hosted publication
   because `vault.bjzy.me` is not publicly reachable.
2. **Refuses to run on a non-operator host.** Requires macOS (`Darwin`) and a
   reachable `vault.bjzy.me:8200`.
3. **Runtime-only credentials.** Reads `Buzz-Admin` and `Buzz-Publisher` from
   Vault at invocation. Never writes them to disk, argv, environment dumps,
   logs, or `extra_vars`. Redacts them from any traceback.
4. **Verifies the Harbor immutability rule** for the target repository before
   pushing, and aborts if the computed tag already exists.
5. **Inputs:** `--source-sha` (40 hex chars, mandatory), `--source-image` (record `BrianInAz/buzz@<sha>` — **not** a fake `ghcr.io/block/buzz` if you built from the fork), `--binaries-dir`, `--branch`, and `--check`.
6. **Validates the binaries** before packaging: all four of `buzz-relay`,
   `buzz-admin`, `buzz-pair-relay`, **`buzz`** (CLI) present, non-empty, ELF x86-64, executable. Hermes `roles/hermes/tasks/buzz_binary.yml` installs the file named `buzz`.
7. **Tag format** `<branch>-<short-sha>-amd64`, short SHA = first 8 characters.
8. **Artifact contents:** the four binaries plus `PIN.txt` and `SHA256SUMS`.
   Update `tests/fixtures/buzz_native_bin_manifest.json` to include the `buzz` layer.
9. **`--check` performs every validation and pushes nothing.** Verify by
   asserting the push call is never made.
10. **Emits a machine-readable pin record** on success — OCI digest, tag,
    per-binary SHA-256, `source_image`, `source_index_digest`,
    `source_amd64_manifest_digest` — so §7.4 pin promotion is copy-paste and not
    transcription by hand.
11. **Idempotent and fail-closed.** A partial failure leaves no half-published
    tag; on any error it exits non-zero with the failing stage named.

#### B1.3 TDD sequence — write tests first, in this order

Red → green → refactor, one test at a time. **Do not write the implementation
before its test fails for the right reason.** Never stub a module into
`sys.modules`; if a dependency is missing, install it into the repo venv
(Critical Rule #7 and #2).

| # | Test | Asserts |
|---|---|---|
| T1 | `test_refuses_to_run_in_github_actions` | non-zero exit and no Vault call when `GITHUB_ACTIONS=true` |
| T2 | `test_requires_operator_workstation` | non-zero exit on non-Darwin platform |
| T3 | `test_rejects_malformed_source_sha` | rejects short, long, and non-hex SHAs |
| T4 | `test_requires_all_four_binaries` | fails naming the missing binary among `buzz-relay`, `buzz-admin`, `buzz-pair-relay`, `buzz` |
| T5 | `test_rejects_empty_or_non_elf_binary` | fails on zero-byte and wrong-architecture inputs |
| T6 | `test_tag_format_matches_branch_shortsha_arch` | `main-abc12345-amd64` for branch `main`, SHA `abc12345…` |
| T7 | `test_aborts_when_tag_already_exists` | immutability guard trips, no push |
| T8 | `test_check_mode_validates_but_never_pushes` | push mock never called, exit zero |
| T9 | `test_artifact_contains_expected_members` | four binaries + `PIN.txt` + `SHA256SUMS`, matching the extended fixture |
| T10 | `test_sha256sums_match_actual_binaries` | recorded checksums equal recomputed ones |
| T11 | `test_pin_record_contains_all_promotion_fields` | all seven fields present and well-formed |
| T12 | `test_secrets_never_appear_in_output_or_logs` | inject sentinel secret values, assert absent from stdout, stderr, log records, and a forced traceback |
| T13 | `test_partial_failure_leaves_no_published_tag` | simulated mid-push failure triggers cleanup and non-zero exit |
| T14 | `test_vault_fetch_failure_fails_closed` | Vault unreachable → non-zero, no push, no fallback credential path |

T12 is the one that must never be allowed to go soft. It is the test that keeps
this script from becoming a credential-leak vector.

#### B1.4 Gates

```bash
cd /Users/b/Code/homelab-playbooks/grok
source .venv/bin/activate          # or the repo's existing venv — never system Python
python3 -m pytest -q tests/unit/test_publish_buzz_native_bin.py
python3 -m pytest -q tests/unit/test_buzz_release_boundary.py
python3 -m pytest -q tests/unit/test_buzz_role_contracts.py
ruff check scripts/buzz/publish_buzz_native_bin.py tests/unit/test_publish_buzz_native_bin.py
yamllint docs/runbooks/buzz-native-bin-publisher.md docs/runbooks/buzz-release-boundary.md
```

All green, zero lint violations, before the PR.

#### B1.5 Beads tracking

Progress tracking is mandatory (Critical Rule #6). Prefix `tailscale-vault-of5`,
JSONL/no-db, sync branch `beads-sync`.

```bash
cd /Users/b/Code/homelab-playbooks/grok
scripts/setup_beads_git_integration.sh --check

EPIC="$(bd create "Epic: Buzz platform upgrade to upstream desktop-v0.5.17" -p 0 --json | jq -r '.id')"
echo "EPIC=$EPIC"
bd create "$EPIC.1" "Phase 0 credential bootstrap and fail-fast" -p 0
bd create "$EPIC.2" "Author source-controlled buzz-native-bin publisher TDD T1-T14 (B1)" -p 0
bd create "$EPIC.3" "Rebase BrianInAz/buzz onto desktop-v0.5.17 (D-1-B)" -p 0
bd create "$EPIC.4" "Build linux/amd64 binaries and publish Harbor artifact" -p 0
bd create "$EPIC.5" "Dev then Prod AWX relay install + Hermes CLI pin" -p 0
bd create "$EPIC.6" "macOS desktop canary build, WSS gate, scripted install" -p 0
bd create "$EPIC.7" "Registry + Notion + Beads closeout (D2 retire, D6-D9 add)" -p 1
bd create "$EPIC.8" "Follow-up: Apple Developer Program for mobile canary (deferred)" -p 2
bd dep add "$EPIC.3" "$EPIC.1"
bd dep add "$EPIC.4" "$EPIC.2"
bd dep add "$EPIC.4" "$EPIC.3"
bd dep add "$EPIC.5" "$EPIC.4"
bd dep add "$EPIC.6" "$EPIC.3"
bd update "$EPIC.1" --claim
```

Record the returned IDs in the closeout. Link the publisher task as a blocker of
the Phase 3 and Phase 4 tasks so the dependency is explicit in Beads, not just
in prose. Beads syncs on `beads-sync`, never on the feature branch.

#### B1.6 Stop conditions

- **`Buzz-Publisher` does not exist in Vault.** Then the publishing identity
  itself is missing, not just the script. Stop and report; do not substitute
  `Buzz-Admin`, `Buzz-Puller`, or any other robot.
- **The Harbor repository has no immutability rule.** Stop and report; do not
  publish into a mutable repository and do not create the rule unilaterally.
- **You cannot satisfy the boundary runbook** without granting GitHub Actions
  Vault access, exposing Vault publicly, or putting a Harbor credential in a
  GitHub secret. Stop. Report that the release boundary needs a reviewed network
  design decision from BrianInAz. Do not build a workaround.

### 4.2 B2 — Mobile deferred `[RESOLVED — DECIDED 2026-08-19]`

**Decision: BrianInAz elected to skip mobile for this upgrade (Option B2-B).**

This blocker is closed by decision, not by remediation. Accordingly:

- **Do not build, sign, or install any iOS or Android artifact in this plan.**
  Phase 6 does not run.
- The iPhone keeps its current app. State that plainly in the closeout.
- Mobile **source** is still rebased in Phase 2 so the fork stays coherent and
  the work is not lost: D4 (`ac319b30c`) and D7 (`79bfb1d9b`, `f8e7e0c74`,
  `594d8cc5c`). Source gates `just mobile-check` and `just mobile-test` must
  still pass.
- D4 and D7 stay `proposed` / `stale` in the registry with the deferral recorded
  in the entry, the Notion mirror, and a Beads follow-up.
- Do not delete or weaken the mobile deviation entries just because they are not
  deployed. They document real carried source.

The underlying constraint is unchanged and is recorded here so the follow-up
does not have to rediscover it:

> The only signing identity on this Mac is `Apple Development:
> web@briancharbonneau.com`, a personal team expiring **2026-10-03**. There is
> no Apple Distribution identity, so no TestFlight and no App Store. Zero
> provisioning profiles are installed. Upstream's only physical-device path is
> Block's private Buildkite, which the fork cannot trigger. Building the
> governed mobile canary lane therefore needs a prior decision on **Apple
> Developer Program enrollment**, since a personal team yields only 7-day
> development builds.

Create one Beads follow-up for the deferred lane:

```bash
bd create "$EPIC.8" "Decide Apple Developer Program enrollment for governed mobile canary lane (deferred from desktop-v0.5.17 upgrade)" -p 2
```

The original analysis is retained below for that follow-up.

<details>
<summary>Original B2 analysis and options (retained for the deferred follow-up)</summary>

#### B2 — No governed path to install a Buzz build on the physical iPhone

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

**STOP condition (historical):** do not build or install any iOS artifact until
BrianInAz selects an option in writing. — *Resolved: Option B2-B selected
2026-08-19.*

</details>

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
- Register `buzz-nip-ad-durable-agent-drafts-v1` (§3.3) before promotion.

**STOP condition:** if the NIP-AD relay series cannot be rebased cleanly and the
conflict resolution is not obviously behaviour-preserving, stop. Do not ship a
relay that silently drops NIP-AD.

### 4.4 B4 — The deviation registry is incomplete `[BLOCKS CLOSEOUT]`

73 fork-only commits versus 5 registry entries (§1.3, §3.3). The registry cannot
gate what it does not know about. **Final closeout is not complete** until every
fork-only commit is either registered, contributed upstream, or retired with
evidence. (Phase 6 is the deferred mobile lane and does not gate this.)

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
| P1.4 | AWX CLI authenticated as `b` | see §0.6 `awx me --conf.insecure` | username `b` |
| P1.5 | Vault login | see §0.6 (`vault token lookup` then userpass `$USER`) | token issued, never root |
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

Create the working branch from **fork `main`**, not from `agent/grok/deploy-new-version`
(that branch is docs-only for this plan):

```bash
git fetch origin
git checkout -b feature/upgrade-desktop-v0.5.17 origin/main
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

Reduce all of these to **D-1-B native-roots** (no `SECURITY_PATCH_COMMIT`, no cherry-pick of `6d03a38`). The canary/private-CA build scripts must apply the three native-roots commits or, once they are on the rebased `main`, apply **no extra TLS patch**. Keep the `deny.toml`
hardening from the security commit **only if** advisory scans still need it;
verify by running the scans (§6.5) both with and without, and record which.

### 6.4 Rebase

Rebase the retained series onto `desktop-v0.5.17`, **one deviation group at a
time** using the §3.3 register, so every conflict is attributable to a named
deviation. Order:

| Order | Deviation | Commits | Notes |
|---|---|---|---|
| 1 | **D1** TLS trust | `6e8523101`, `7765d12ec`, `0f7edef10` (**D-1-B only**) | Feature-flag. Do not apply `6d03a38`. |
| 2 | **D1** machinery | 14 commits | Minus the security-patch references stripped in §6.3; re-evaluate `a7faf67d9`. |
| 3 | **D6** NIP-AD | 20 commits | **Highest risk — see B3.** Verify migration numbering *first*. The Docker `--locked` commits (`95ba0103a`, `a6c86d6f0`, `e58fcd8af`) are the tail of this group; re-test whether they are still needed at `desktop-v0.5.17` and retire them within D6 if the lock is now consistent. |
| 4 | **D3** contextual conversations | 9 commits (PR #13) | |
| 5 | **D5** audience chips | 17 commits (PR #15) + `f73b2bdd5` (PR #33) | Apply the full series. The stabilization fixes are load-bearing — dropping them re-introduces send-race bugs. |
| 6 | **D4** mobile audience | `ac319b30c` | Source only; not deployed (§4.2). |
| 7 | **D7** mobile presence/scroll | `79bfb1d9b`, `f8e7e0c74`, `594d8cc5c` | Source only; not deployed. |
| 8 | **D8** desktop carried fixes | `4ff406444`, `4deea1a0d` | |
| 9 | **D9** fork CI | `ef72743fb`, `ce5acf44c` | |

Excluded deliberately: `7dbfcd785` (D2, obsolete — §6.3) and `ad9e7c31d`
(upstream now — §6.2).

For each group record: commits applied, conflicts encountered, how each conflict
was resolved, and why the resolution preserves behaviour. Verify the group
totals against §3.0 so nothing is silently dropped.

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

# Formatting/lint — check only. Do not run `just fix-all` as a gate (it rewrites the tree).
cargo fmt --check
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
export TOWER_HOST=https://awx.bjzy.me
export TOWER_OAUTH_TOKEN="$(vault kv get -field=api_token kvProd_v2/AWX/API)"
awx me --conf.insecure | jq -e '.results[0].username == "b"'

# Discover live IDs (do not trust this doc if they drifted)
awx job_templates list --page_size 200 --conf.insecure \
  | jq -r '.results[] | select(.name|test("Buzz|Hermes - Manage")) | "\(.id)\t\(.name)\tinv=\(.inventory)\tlimit=\(.limit)"'

# Expected at authoring: 215 Prod, 222 Dev, 216 HAProxy Prod, 223 HAProxy Dev, 198 Hermes Dev, 199 Hermes Prod
```

Record: template existence, project/inventory/playbook/limit, current SCM
revision, survey spec, schedule IDs 50/51 and their `next_run`. Compare against
`awx/buzz/*.yml` and `awx/devbuzz/*.yml` in homelab-playbooks. If the dev
surface is genuinely unapplied, apply it with `awx/devbuzz/apply.sh` as a
prerequisite and record the result.

### 7.2 Build Linux AMD64 binaries on this Mac, then publish

This Mac is arm64. **Do not cross-compile with a guessed cargo target.** Use Docker `linux/amd64` against the **merged fork SHA** from §6.6.

```bash
cd /Users/b/Code/buzz/grok-deploy-new-version
source ./bin/activate-hermit
SHA="$(git rev-parse HEAD)"          # must equal the merged fork SHA
test "$(git rev-parse --abbrev-ref HEAD)" = "main"

OUT="/tmp/buzz-native-bin-$SHA"
rm -rf "$OUT" && mkdir -p "$OUT"

docker buildx build --platform linux/amd64 --load \
  --target stripped-binaries \
  -t "buzz-native-src:$SHA" \
  -f Dockerfile .

CID="$(docker create --platform linux/amd64 "buzz-native-src:$SHA")"
docker cp "$CID:/build/target/release/buzz-relay"      "$OUT/buzz-relay"
docker cp "$CID:/build/target/release/buzz-admin"      "$OUT/buzz-admin"
docker cp "$CID:/build/target/release/buzz-pair-relay" "$OUT/buzz-pair-relay"
docker cp "$CID:/build/target/release/buzz"            "$OUT/buzz"
docker rm "$CID"

file "$OUT"/* | grep -E 'ELF 64-bit LSB.+, x86-64'   # STOP if not ELF x86-64
chmod 0755 "$OUT"/*
```

If `buzz` is not at `target/release/buzz` in the stripped stage, **extend the Dockerfile in the same Phase 2 PR**. Current lines 73–82 only build three binaries. Required edit:

```dockerfile
RUN cargo build --release -p buzz-relay --bin buzz-relay \
                                   -p buzz-admin --bin buzz-admin \
                                   -p buzz-pair-relay --bin buzz-pair-relay \
                                   -p buzz-cli --bin buzz
# in stripped-binaries:
RUN strip target/release/buzz-relay \
    && strip target/release/buzz-admin \
    && strip target/release/buzz-pair-relay \
    && strip target/release/buzz
```

Also add `COPY` of `buzz` in the `runtime` and `runtime-debug` stages so the image stays consistent. Tests: the image still builds and `file` reports ELF x86-64 for all four. This is required by D-artifact (§0.7), not optional.

Then publish:

```bash
cd /Users/b/Code/homelab-playbooks/grok
source .venv/bin/activate   # or venv per Critical Rule #7
python3 scripts/buzz/publish_buzz_native_bin.py --check \
  --source-sha "$SHA" \
  --source-image "BrianInAz/buzz@$SHA" \
  --binaries-dir "$OUT" \
  --branch main
python3 scripts/buzz/publish_buzz_native_bin.py \
  --source-sha "$SHA" \
  --source-image "BrianInAz/buzz@$SHA" \
  --binaries-dir "$OUT" \
  --branch main
# Capture the printed pin JSON (digest, tag, four sha256s). Never print Harbor passwords.
```

Record: source SHA, Harbor tag, OCI digest, four binary SHA-256s. `source_image` is the fork SHA, **not** `ghcr.io/block/buzz:main`.

Populate `buzz_pair_relay_binary_sha256` (currently empty in role defaults) **and** `hermes_buzz_cli_binary_sha256` from the same pin record.

### 7.3 Vault pin write (agent, fail-fast)

No human paste-handoff. After the publisher emits the pin JSON:

```bash
# Presence-only probe already ran in §0.6. Patch non-secret pin fields.
# STOP on permission denied — do not route around via extra_vars or a second secret path.
PIN_JSON=...  # from publisher stdout file, not chat

vault kv patch kvProd_v2/Buzz/Development \
  binary_ref="$TAG" \
  binary_oci_digest="$DIGEST" \
  buzz_relay_sha256="$RELAY_SHA" \
  buzz_admin_sha256="$ADMIN_SHA" \
  buzz_pair_relay_sha256="$PAIR_SHA" \
  source_image="BrianInAz/buzz@$SHA" \
  source_index_digest="" \
  source_amd64_manifest_digest=""

# Repeat for kvProd_v2/Buzz/Prod ONLY after Dev AWX install+test in §8.1 succeeds.
```

Record new Vault versions (`vault kv metadata get`) — never field values that are secrets. Pin fields above are checksums and refs, not credentials.

If `vault kv patch` is denied, report the token policies from `vault token lookup` and stop. That is a capability gap, not a prompt for Brian to type the pins by hand as a workaround.

### 7.4 GitOps pin promotion

On a `feature/` branch off `develop` in homelab-playbooks:

- `roles/buzz/defaults/main.yml`: `buzz_binary_oci_ref`,
  `buzz_binary_oci_digest`, `buzz_relay_binary_sha256`,
  `buzz_admin_binary_sha256`, `buzz_pair_relay_binary_sha256`.
- `tests/fixtures/buzz_native_bin_manifest.json`.
- `roles/hermes/defaults/main.yml` — all three pin fields:
  `hermes_buzz_cli_binary_oci_ref`, `hermes_buzz_cli_binary_oci_digest`,
  `hermes_buzz_cli_binary_sha256`. Hermes does **not** store this pin in Vault;
  GitOps is the source of truth.
- `docs/runbooks/buzz-hermes-version-pinning.md` — the authoritative version record.
- New publisher script + runbook from B1.
- Registry updates from §3.3 (retire D2, refresh D1/D3/D5 `source_lock`, add
  D6–D9).

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

Launch pattern (copy per operation; extra_vars must contain **only** survey fields):

```bash
launch_buzz() {
  local jt="$1" op="$2"
  awx job_templates launch "$jt" --conf.insecure --monitor \
    --extra_vars "{\"operation\":\"${op}\",\"restore_selector\":\"latest\"}"
}

# §8.1 Dev (JT 222). Sync Development project 136 to the promoted develop SHA first.
DEV_JT=222
PROJECT_ID=$(awx job_templates get "$DEV_JT" --conf.insecure | jq -r '.project')
awx projects get "$PROJECT_ID" --conf.insecure | jq '{name,status,scm_branch,scm_revision}'
awx projects update "$PROJECT_ID" --conf.insecure --wait
awx job_templates get "$DEV_JT" --conf.insecure | jq '{id,name,inventory,limit,playbook}'

launch_buzz "$DEV_JT" backup
launch_buzz "$DEV_JT" status
launch_buzz "$DEV_JT" test
launch_buzz "$DEV_JT" install
launch_buzz "$DEV_JT" status
launch_buzz "$DEV_JT" test
```
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

Baselines — scrape the relay metrics port (do not skip TLS on the public edge; this is the Tailnet metrics listener documented in `buzz-ops-closeout.md`):

```bash
curl -sS http://100.75.115.112:9102/metrics | tee /tmp/buzz-prod-metrics-before.txt \
  | rg '^(buzz_community_messages|buzz_community_channels|buzz_community_workflows|buzz_total_subscriptions|buzz_total_relay_members|buzz_total_storage_objects|buzz_total_storage_bytes) '
```

These must **not decrease** after install. Re-scrape to `/tmp/buzz-prod-metrics-after.txt` and diff.

Sequence using the same `launch_buzz 215 …` helper after **Production project 8** is synced to promoted `main` (webhook may already have done this — verify `scm_revision` before `projects update`):

`backup` → `status` → `test` → `install` → `status` → `test` →
readiness and metrics verification → historical-total comparison → expire the
silence (`amtool silence expire <id>` or equivalent).

**Prod JT 215 inventory is the Buzz prod host, not swarm inventory 15.** Still treat it as production: verify `awx job_templates get 215 --conf.insecure | jq '{name,inventory,limit}'` shows name `Buzz - Manage - Prod` and limit `buzz` before launch. Standing authorization is in the plan header.

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

```bash
# Hermes templates already pin hermes_environment in extra_vars
# (198 → Development, 199 → Production). Launch with operation only.
# Dump first: awx job_templates get 198 --conf.insecure | jq '{name,extra_vars,survey_spec,project}'
# Sync 198's project (136 / develop) then 199's project (8 / main) before install.
awx job_templates launch 198 --conf.insecure --monitor \
  --extra_vars '{"operation":"install"}'
awx job_templates launch 198 --conf.insecure --monitor \
  --extra_vars '{"operation":"status"}'
awx job_templates launch 199 --conf.insecure --monitor \
  --extra_vars '{"operation":"install"}'
awx job_templates launch 199 --conf.insecure --monitor \
  --extra_vars '{"operation":"status"}'
```

Verify Hermes Buzz presence still works — online, heartbeat, graceful offline,
reconnect, message delivery — and re-run the Hermes runtime deviation monitor
workflow. Record whether `hermes-buzz-presence-lifecycle-v1` classification changed.
On the Hermes host, `sha256sum /home/b/.hermes/bin/buzz` must equal the new pin.

---

## 9. Phase 5 — macOS Desktop client and CLI

### 9.1 Build

Use the fork's native Apple Silicon canary builder against the **merged fork
SHA** from §6.6. After D-1-B, that SHA already contains native-roots; the builder
must **not** cherry-pick `6d03a38` or `7dbfcd78`. Update `scripts/build_buzz_fork_canary_macos.sh` in the homelab PR **before** running it.

```bash
cd /Users/b/Code/homelab-playbooks/grok
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

Because this is fully scripted, **do not wait for a drag-to-Applications step**.
If `install_buzz_fork_canary_macos.sh` fails, **STOP**, keep the current app, and
report the script error. Do not ask the human to copy the bundle by hand.

### 9.4 CLI verification

`/Users/b/.local/bin/buzz` is a symlink into the app bundle, so it upgrades
automatically. Confirm the symlink still resolves and the CLI runs:

```bash
ls -la /Users/b/.local/bin/buzz
buzz --help
buzz agents --help      # NIP-AD / draft surface must still exist
```

### 9.5 Runtime acceptance (CLI + existing tests — no GUI babysitting)

Do **not** sit in the Desktop UI looking for chips. Prove the same contracts from CLI and the repo's tests.

```bash
# Identity (owner key from Keychain — buzz skill; never print)
export BUZZ_RELAY_URL="https://buzz.bjzy.me"
export BUZZ_PRIVATE_KEY="$(
  security find-generic-password -s buzz-desktop -a secrets -w \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["identity"])'
)"
buzz --format compact users get | python3 -c 'import json,sys; d=json.load(sys.stdin); print("display="+str(d[0].get("display_name")))'

# Private-CA WSS (same gate the ignored unit tests use)
export BUZZ_TEST_WSS_URL="wss://buzz.bjzy.me"
cd /Users/b/Code/buzz/grok-deploy-new-version && source ./bin/activate-hermit
cargo test -p buzz-cli -- --ignored configured_wss_trusts_native_platform_roots --exact --nocapture

# Send/receive
HOME_CH="8dcbf11a-9025-4bb2-89a3-2765958309cd"   # production agent-control
buzz messages send --channel "$HOME_CH" --content "upgrade-canary $(date -u +%Y%m%dT%H%M%SZ)"
buzz messages get --channel "$HOME_CH" --limit 5 --kinds 9

# NIP-AD / agent-draft surface (subcommand names follow live CLI --help)
buzz --help | rg -i 'draft|agent'
buzz agents --help

# Installed bundle
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/Buzz.app/Contents/Info.plist
ls /Applications/Buzz.app/Contents/MacOS/

# Desktop contracts already in-tree (no GUI babysitting, no grep fallback)
cd /Users/b/Code/buzz/grok-deploy-new-version/desktop
pnpm exec playwright test tests/e2e/persistent-agent-audience.spec.ts
pnpm test -- src/features/channels/lib/contextualAgentConversationPolicy.test.mjs
```

Also required: private WSS gate from §9.2 green; app launches (`open -a Buzz`) and `pgrep -lf Buzz.app` is non-empty; after `osascript -e 'quit app "Buzz"'` and relaunch, `buzz users get` still succeeds (identity reuse).

**STOP condition:** any command above fails → roll back per §11, keep registry entries un-promoted, report.

---

## 10. Phase 6 — iOS / mobile: DEFERRED, DOES NOT RUN

**BrianInAz elected Option B2-B on 2026-08-19. This phase does not execute.**

Do not build, sign, or install any iOS or Android artifact. Instead:

1. Confirm the mobile **source** groups D4 and D7 rebased in Phase 2 and that
   `just mobile-check` and `just mobile-test` passed.
2. Keep D4 and D7 at `proposed` / `stale`, with the deferral and its reason
   recorded in each registry entry.
3. Record the Apple Developer Program follow-up in Beads (§4.2).
4. State plainly in the closeout that **the iPhone still runs its previous app
   and was intentionally not touched.**

Do not treat the deferral as an invitation to do a "quick" development-signed
install. That is exactly the workaround this plan forbids.

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
- `docs/operations/private-ca-desktop-release-lifecycle.md` updated to
  **D-1-B native-roots** (no extra TLS cherry-pick, no `SECURITY_PATCH_COMMIT`).
- `.github/workflows/private-ca-release.yml` and
  `scripts/build-private-ca-macos.sh` with the obsolete `SECURITY_PATCH_COMMIT`
  and `6d03a38` cherry-pick removed.
- If NIP-AD is renumbered, the migration and its references.

**homelab-playbooks** (`BjzyLabs/homelab-playbooks`, `feature/` → `develop` → `main`):
- `docs/upstream-deviations.json` — implement the corrected nine-entry register
  from §3.3: retire D2 as a tombstone; **rescope D1** per decision D-1-B
  including its CLI scope and the machinery paths; correct D5's commit series to
  the full 17 + `f73b2bdd5`; add **D6, D7, D8, D9**; refresh every
  `source_lock` to `c3bfd669`; record the mobile deferral on D4 and D7; update
  `snapshot_utc`.
- `docs/current-upstream-deviations.md` — regenerated, never hand-edited.
- New: `scripts/buzz/publish_buzz_native_bin.py`,
  `tests/unit/test_publish_buzz_native_bin.py`, and
  `docs/runbooks/buzz-native-bin-publisher.md` (B1, §4.1).
- `roles/buzz/defaults/main.yml`, `roles/hermes/defaults/main.yml`,
  `tests/fixtures/buzz_native_bin_manifest.json` — new pins.
- `docs/runbooks/buzz-hermes-version-pinning.md` — new authoritative versions.
- `scripts/build_buzz_fork_canary_macos.sh` — stop cherry-picking `6d03a38` and `7dbfcd785`.
- `docs/evidence/buzz-upgrade-v0.5.17-<date>.md` — full evidence record.
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
| **Buzz Platform Upgrade to desktop-v0.5.17** (this plan's mirror, already created) | `3c23569a-a255-81dc-83e7-ca6ae7e28478` | Execution status, evidence links, final acceptance matrix, B2 decision |

The upgrade page already exists — **update it, do not create a duplicate.**
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
| 1 | §0.6 credential bootstrap passed. Phase 1 checks all pass, or a failure is reported as a blocker. D-1-B is locked in this document — do not wait for another decision. |
| 2 | Fork `main` rebased onto `c3bfd66947978fae93f4cfb46bea98ba20e32ccf`, group by group per §6.4; obsolete security patch and `ad9e7c31d` removed; group totals reconcile to §3.0 with no orphaned commit; all §6.5 gates green; PR merged. |
| 3 | Source-controlled Harbor publisher merged with tests **T1–T14 green** (B1 cleared), runbook written, fixture extended, and boundary runbook updated. |
| 4 | New `buzz-native-bin` artifact published; digest and all **four** binary checksums recorded; pins promoted in Git and Vault (Buzz) plus Hermes GitOps sha256. |
| 5 | devbuzz reports relay `0.2.1`; pair-relay reachable; NIP-AD functional; dev certified. |
| 6 | buzz.bjzy.me reports relay `0.2.1`; readiness/metrics green; **no historical total decreased**; schedules 50/51 intact; silence removed. |
| 7 | Hermes `buzz` CLI pin rolled; Buzz presence and delivery verified. |
| 8 | `/Applications/Buzz.app` rebuilt on `desktop-v0.5.17` with private-CA trust (D-1-B); private WSS gate green; all §9.5 acceptance items pass; rollback bundle archived with a receipt. |
| 9 | `buzz` CLI symlink resolves; `buzz agents --help` exposes `draft-*` (NIP-AD). |
| 10 | Mobile **not touched**; D4 and D7 remain `proposed`; Apple Developer follow-up recorded in Beads; closeout states the iPhone was intentionally left alone. |
| 11 | Registry matches §3.3 exactly: D2 retired as a tombstone, D1 rescoped per D-1-B with CLI scope, D5 corrected to its full series, D6/D7/D8/D9 registered, all `source_lock` values refreshed, validator and renderer `--check` pass, and every one of the 74 commits is accounted for (B4 cleared). |
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
- Build, sign, or install **any** iOS or Android artifact — mobile is deferred
  (§4.2). A development-signed "quick test" install is not an exception.
- Rebase D1 by cherry-picking `6d03a38` onto a tree that already has native-roots, or apply both private-CA implementations at once.
- Hand-run an undocumented `oras push` to Harbor in place of the B1 publisher.
- Write the publisher implementation before its test fails for the right reason,
  or soften test T12 (secret-leak prevention) to get a green run.
- Commit the human's unrelated Ruler-sync working-tree changes (§6.1).

---

## 15. Evidence to report at the end

Produce a single closeout with:

1. Upstream base SHA used and every tag involved.
2. Fork pre- and post-rebase SHAs; the merge commit; the PR URL.
3. Full `git cherry` census, before and after.
4. Deviation reconciliation outcome per entry, with the verification command
   output that justifies it.
5. Harbor tag, OCI digest, and the **four** binary SHA-256 values (`buzz-relay`, `buzz-admin`, `buzz-pair-relay`, `buzz`).
6. Vault pin versions changed (field names and version numbers only — never
   values).
7. Every AWX job ID with template, operation, SCM revision, and status.
8. Before/after metric baselines for prod.
9. Desktop DMG SHA-256, install receipt path, rollback directory, and the §9.5
   acceptance results.
10. Confirmation D-1-B shipped (native-roots; `6d03a38` not applied).
11. Confirmation that mobile was deferred and untouched, with the Apple
    Developer follow-up Beads ID.
12. All Git commits, PRs, merges, and promotions in both repos.
13. Notion pages updated or created; Beads IDs created or closed.
14. Every gate that failed and how it was resolved — or, if unresolved, the
     exact blocker, with no attempt to paper over it.
