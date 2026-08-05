NIP-AD
======

Durable Agent Drafts
--------------------

`draft` `optional` `relay`

This NIP defines two durable, encrypted event kinds for requesting and
resolving changes to a managed agent: `kind:44300` (agent → owner draft
request) and `kind:44301` (owner → agent resolution). An agent publishes a
`kind:44300` event, NIP-44 encrypted to its owner, to propose creating or
updating itself as a managed agent; the owner reviews it in their desktop
client and publishes a `kind:44301` resolution. Because both kinds are
durable and p-gated, a draft published while the owner's client is offline is
replayed on the next launch — the property the ephemeral telemetry path could
never provide.

## Motivation

`buzz agents draft-create` lets an agent propose itself for management by an
owner. The original implementation piggybacked this on the NIP-AO
`agent_management_request` telemetry payload carried on kind 24200. That kind
is deliberately ephemeral: relays MUST NOT persist it, so a draft published
while the owner's desktop is closed is lost forever, and the desktop's
subscription only opens once an agent already exists — a brand-new identity
can never be seen at all.

NIP-AD replaces that path with two regular, durable, p-gated kinds. A draft
is a first-class stored event: it replays on the owner's next launch, it is
readable by both the owner and the requesting agent, and it is closed out to
everyone else at every read path. This makes "register me" a durable,
reviewable, owner-attested operation rather than a best-effort live frame.

## Definitions

- **Agent**: an AI process with its own Nostr keypair, executing sessions on
  behalf of an owner.
- **Owner**: the human (or system) whose pubkey the agent was provisioned
  under.
- **Draft request**: a single kind 44300 event proposing to create or update
  a managed agent.
- **Draft resolution**: a single kind 44301 event accepting, declining, or
  superseding a draft request.
- **Pending draft**: a draft request for which no resolution carrying the
  same `requestId` exists.

## Event Kinds

| Kind  | Name                    | Direction         |
|-------|-------------------------|-------------------|
| 44300 | Agent Draft Request     | agent → owner     |
| 44301 | Agent Draft Resolution  | owner → agent     |

Both kinds are regular, durable events by Buzz convention (alongside
44100/44101/44200): stored, append-only, never replaced. Neither carries an
`h` tag — channel identity lives inside the encrypted payload, exactly as
NIP-AM does it, so the event is community-global (owner-scoped) rather than
channel-scoped.

## Event Structure

### Kind 44300 — Agent Draft Request (agent → owner)

```json
{
  "kind": 44300,
  "pubkey": "<agent_pubkey>",
  "created_at": <unix_timestamp>,
  "content": "<NIP-44 v2 ciphertext, agent seckey → owner pubkey>",
  "tags": [
    ["p",     "<owner_pubkey_hex>"],
    ["p",     "<agent_pubkey_hex>"],
    ["agent", "<agent_pubkey_hex>"]
  ],
  "sig": "..."
}
```

### Kind 44301 — Agent Draft Resolution (owner → agent)

```json
{
  "kind": 44301,
  "pubkey": "<owner_pubkey>",
  "created_at": <unix_timestamp>,
  "content": "<NIP-44 v2 ciphertext, owner seckey → agent pubkey>",
  "tags": [
    ["p",     "<owner_pubkey_hex>"],
    ["p",     "<agent_pubkey_hex>"],
    ["agent", "<agent_pubkey_hex>"],
    ["e",     "<request_event_id_hex>"]
  ],
  "sig": "..."
}
```

### Envelope rules (relay-enforced at ingest)

Both kinds MUST have:

- exactly **two** `p` tags, both 64 lowercase hex, forming the set
  `{owner, agent}`, with `owner != agent`;
- exactly **one** `agent` tag, 64 lowercase hex, equal to `event.pubkey`;
- **no** `h` tag;
- `content` that passes the NIP-44 v2 shape check;
- `is_agent_owner(agent, owner)` true in the requesting community.

Kind 44301 additionally MUST have `event.pubkey == owner` (the owner authors
it, so `agent != event.pubkey`) and exactly **one** `e` tag of 64 lowercase
hex.

> **Why two `p` tags.** `p_gated_filters_authorized` requires every `#p`
> value in the *filter* to equal the authenticated reader, and
> `reader_authorized_for_event` requires the *event* to carry a `#p` matching
> the reader. Two `p` tags let the owner read with `{"#p":[owner]}` and the
> agent read back its own drafts with `{"#p":[agent]}`, while any third party
> is still closed out at both layers. This is a deliberate divergence from
> NIP-AM's single `p` tag.

## Encryption

`content` MUST be encrypted with NIP-44 v2 (XChaCha20-Poly1305 over a
secp256k1 ECDH shared secret).

- **44300**: encrypted with `(agent_privkey, owner_pubkey)`.
- **44301**: encrypted with `(owner_privkey, agent_pubkey)`.

Plaintext SHOULD be zeroized from memory immediately after encrypt/decrypt.
Decrypted payload MUST NOT exceed 65,535 bytes.

## Decrypted Payload

### Kind 44300 — `AgentDraftRequestPayload`

The `content` field decrypts to a UTF-8 JSON object (camelCase on the wire):

```jsonc
{
  "version": 1,
  "requestId": "<uuid v4>",
  "action": "create" | "update",
  "timestamp": "<RFC 3339>",
  "channelId": "<channel uuid>",
  "request": {
    // action == "create"
    "displayName": "<= 120 chars",
    "systemPrompt": "<= 20000 chars"
    // action == "update" — agentName required, >= 1 of the rest
    // "agentName", "displayName", "systemPrompt", "runtime", "provider", "model",
    // "respondTo": "owner-only" | "anyone"
  }
}
```

`version` is REQUIRED and MUST be `1`. Consumers MUST ignore unknown fields.
Consumers MUST reject a payload whose `version` they do not understand (fail
closed — do **not** best-effort a future version).

### Kind 44301 — `AgentDraftResolutionPayload`

```jsonc
{
  "version": 1,
  "requestId": "<uuid, echoes the request>",
  "status": "accepted" | "declined" | "superseded",
  "timestamp": "<RFC 3339>",
  "agentPubkey": "<hex, present when status == accepted>",
  "reason": "<optional, <= 500 chars, operator-visible>"
}
```

`version` is REQUIRED and MUST be `1`. `agentPubkey` is the agent the owner
actually saved and is present when `status == "accepted"`. `reason` is
optional, at most 500 characters, and operator-visible.

## Lifecycle

A draft is **pending** iff a 44300 exists for `(owner, agent, requestId)`
with no 44301 carrying the same `requestId`. Both clients derive pending-ness
by querying both kinds — there is no server-side state. Retention follows the
relay's normal event TTL; no new retention policy.

`superseded` exists so a second draft with the same `channelId` + `agentName`
can retire an older pending one without the owner having to act on both.

## Authorization

Both directions require relay confirmation of the agent-owner relationship via
authenticated ownership lookup (`is_agent_owner`). `#p` tag matching alone is
insufficient.

- **44300** (agent → owner): `event.pubkey` MUST equal the `agent` tag, and
  `is_agent_owner(agent, owner)` MUST hold.
- **44301** (owner → agent): `event.pubkey` MUST equal the owner, and
  `is_agent_owner(agent, owner)` MUST hold.

Reads MUST be gated: only an authenticated ([NIP-42](42.md)) reader whose
pubkey equals one of the `#p` tag values may receive the event. This gate
applies to **every** read path, including explicit `ids` filters — knowing an
event id MUST NOT grant access. Unauthenticated publish or subscribe attempts
MUST be rejected with `AUTH required`; authenticated attempts from a pubkey
that is not one of the event's `p` tags MUST be rejected with `restricted:`.

## Relay Behavior

On receiving a kind 44300 or 44301 event, a relay MUST:

1. Validate the event signature per NIP-01.
2. Verify the envelope rules above, including `is_agent_owner(agent, owner)`
   via authenticated ownership lookup.
3. Store the event durably, scoped to the owner (community-global; no channel
   scope).
4. NOT index the event in any full-text search (the ciphertext is not
   searchable and must not enter search indexes).

## Client Behavior

Owners recover pending drafts with:

```json
{"kinds": [44300], "#p": ["<own_pubkey>"], "limit": 100}
```

and resolve them by publishing a 44301. Agents read back their own drafts and
resolutions with:

```json
{"kinds": [44300, 44301], "#p": ["<own_pubkey>"]}
```

On receiving an event, a client MUST verify the signature, decrypt with its
own secret key and `event.pubkey`, and ignore events that fail to decrypt or
parse. Clients MUST reject a payload whose `version` they do not understand.
Clients SHOULD deduplicate by event id and derive pending-ness by joining
44300 against 44301 on `requestId`.

## Relationship to Other NIPs

- [NIP-AO](NIP-AO.md): same agent↔owner encryption and tag scoping, but
  ephemeral and transcript-grade. **NIP-AD supersedes the
  `agent_management_request` telemetry payload previously carried on NIP-AO
  kind 24200**; that payload kind is no longer defined. NIP-AD events are
  durable and MUST NOT be carried on kind 24200.
- [NIP-AM](NIP-AM.md): the durable, p-gated, FTS-excluded template this NIP
  follows; NIP-AD diverges only in using two `p` tags (see above).
- [NIP-09](09.md): the authoring agent (or its owner via relay policy) may
  request deletion; relays apply standard deletion semantics.
- [NIP-40](40.md): publishers MAY set `expiration` to bound retention.

## Security Considerations

**Metadata leakage.** `p`, `agent`, `e`, and `created_at` are cleartext: a
relay operator learns that agent X proposed a change to owner Y. The draft
content, channel, and resolution reason remain encrypted.

**No forward secrecy.** NIP-44 does not provide forward secrecy; compromise
of the agent's or owner's private key allows decryption of captured
ciphertexts.

**Draft content is sensitive.** A draft may contain a system prompt or
configuration the agent does not want public. It is encrypted to the owner
and p-gated at every read path; clients MUST NOT log decrypted payloads.

**Resolution integrity.** Resolutions are self-authored by the owner. A
compromised owner key can forge acceptances; the agent SHOULD verify the
resolution's `requestId` matches a draft it actually sent.

## Examples

### 1. Draft request — create

**Wire event (encrypted):**

```json
{
  "id":         "a1b2c3d4...",
  "kind":       44300,
  "pubkey":     "agent_pubkey_hex",
  "created_at": 1777464041,
  "content":    "<NIP-44 v2 ciphertext>",
  "tags": [
    ["p",     "owner_pubkey_hex"],
    ["p",     "agent_pubkey_hex"],
    ["agent", "agent_pubkey_hex"]
  ],
  "sig": "..."
}
```

**Decrypted payload:**

```json
{
  "version":    1,
  "requestId":  "9f1c2b3a-4d5e-4f6a-8b7c-1d2e3f4a5b6c",
  "action":     "create",
  "timestamp":  "2026-08-05T12:00:00.000Z",
  "channelId":  "f0347328-e105-4e62-9af8-807d20e484dd",
  "request": {
    "displayName":  "dev-coder",
    "systemPrompt": "You are a coding specialist..."
  }
}
```

### 2. Draft resolution — accepted

**Wire event (encrypted):**

```json
{
  "id":         "e5f6a7b8...",
  "kind":       44301,
  "pubkey":     "owner_pubkey_hex",
  "created_at": 1777464042,
  "content":    "<NIP-44 v2 ciphertext>",
  "tags": [
    ["p",     "owner_pubkey_hex"],
    ["p",     "agent_pubkey_hex"],
    ["agent", "agent_pubkey_hex"],
    ["e",     "a1b2c3d4..."]
  ],
  "sig": "..."
}
```

**Decrypted payload:**

```json
{
  "version":     1,
  "requestId":   "9f1c2b3a-4d5e-4f6a-8b7c-1d2e3f4a5b6c",
  "status":      "accepted",
  "timestamp":   "2026-08-05T12:05:00.000Z",
  "agentPubkey": "agent_pubkey_hex",
  "reason":      "Approved"
}
```
