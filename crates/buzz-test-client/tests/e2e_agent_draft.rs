//! End-to-end tests for NIP-AD agent drafts (kinds 44300/44301).
//!
//! Kinds 44300/44301 are durable, p-gated, FTS-excluded events. These tests
//! assert the wire behaviour of that gate at every read chokepoint (REQ,
//! kindless `ids` lookup, COUNT, live fan-out) plus the ingest envelope rules
//! that make the gate sound:
//! - exactly two `p` tags (owner + agent, `owner != agent`), one `agent` tag,
//!   no `h` tag, NIP-44 content;
//! - 44300 authored by the agent, 44301 authored by the owner;
//! - `is_agent_owner` must hold (established via NIP-OA auth).
//!
//! # Running
//!
//! Start the relay, then run:
//!
//! ```text
//! RELAY_URL=ws://localhost:3000 cargo test --test e2e_agent_draft -- --ignored
//! ```

use std::time::Duration;

use buzz_core::agent_draft::{
    encrypt_agent_draft_request, encrypt_agent_draft_resolution, AgentDraftAction,
    AgentDraftCreateRequest, AgentDraftRequest, AgentDraftRequestPayload,
    AgentDraftResolutionPayload, AgentDraftResolutionStatus, AGENT_DRAFT_VERSION,
};
use buzz_sdk::nip_oa;
use buzz_test_client::{BuzzTestClient, RelayMessage};
use nostr::{EventBuilder, Filter, Keys, Kind, Tag};

const DRAFT_REQUEST_KIND: u16 = 44300;
const DRAFT_RESOLUTION_KIND: u16 = 44301;

fn relay_url() -> String {
    std::env::var("RELAY_URL").unwrap_or_else(|_| "ws://localhost:3000".to_string())
}

fn sub_id(name: &str) -> String {
    format!("e2e-agent-draft-{name}-{}", uuid::Uuid::new_v4())
}

/// Build a NIP-OA auth tag for `agent_keys` signed by `owner_keys`.
fn make_nip_oa_auth_tag(owner_keys: &Keys, agent_keys: &Keys) -> Tag {
    let tag_json = nip_oa::compute_auth_tag(owner_keys, &agent_keys.public_key(), "")
        .expect("compute_auth_tag");
    nip_oa::parse_auth_tag(&tag_json).expect("parse_auth_tag")
}

/// Connect `agent_keys` with NIP-OA, establishing owner→agent in the DB.
async fn connect_agent_with_owner(agent_keys: &Keys, owner_keys: &Keys) -> BuzzTestClient {
    let url = relay_url();
    let auth_tag = make_nip_oa_auth_tag(owner_keys, agent_keys);
    let mut client = BuzzTestClient::connect_unauthenticated(&url)
        .await
        .expect("connect agent unauthenticated");
    client
        .authenticate_with_nip_oa(agent_keys, &auth_tag)
        .await
        .expect("NIP-OA auth");
    client
}

fn sample_create_payload(request_id: &str) -> AgentDraftRequestPayload {
    AgentDraftRequestPayload {
        version: AGENT_DRAFT_VERSION,
        request_id: request_id.to_string(),
        action: AgentDraftAction::Create,
        timestamp: "2026-08-05T12:00:00.000Z".to_string(),
        channel_id: "f0347328-e105-4e62-9af8-807d20e484dd".to_string(),
        request: AgentDraftRequest::Create(AgentDraftCreateRequest {
            display_name: "dev-coder".to_string(),
            system_prompt: "You are a coding specialist.".to_string(),
        }),
    }
}

/// Build a signed kind:44300 draft request event.
fn build_draft_request(
    agent_keys: &Keys,
    owner_pubkey: &nostr::PublicKey,
    payload: &AgentDraftRequestPayload,
) -> nostr::Event {
    let encrypted =
        encrypt_agent_draft_request(agent_keys, owner_pubkey, payload).expect("encrypt request");
    EventBuilder::new(Kind::Custom(DRAFT_REQUEST_KIND), encrypted)
        .tags([
            Tag::parse(["p", &owner_pubkey.to_hex()]).unwrap(),
            Tag::parse(["p", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(agent_keys)
        .expect("sign request")
}

/// Build a signed kind:44301 draft resolution event.
fn build_draft_resolution(
    owner_keys: &Keys,
    agent_pubkey: &nostr::PublicKey,
    request_event_id: &str,
    request_id: &str,
) -> nostr::Event {
    let payload = AgentDraftResolutionPayload {
        version: AGENT_DRAFT_VERSION,
        request_id: request_id.to_string(),
        status: AgentDraftResolutionStatus::Accepted,
        timestamp: "2026-08-05T12:05:00.000Z".to_string(),
        agent_pubkey: Some(agent_pubkey.to_hex()),
        reason: None,
    };
    let encrypted =
        encrypt_agent_draft_resolution(owner_keys, agent_pubkey, &payload).expect("encrypt res");
    EventBuilder::new(Kind::Custom(DRAFT_RESOLUTION_KIND), encrypted)
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent_pubkey.to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_pubkey.to_hex()]).unwrap(),
            Tag::parse(["e", request_event_id]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(owner_keys)
        .expect("sign resolution")
}

fn owner_p_filter(owner: &Keys) -> Filter {
    Filter::new()
        .kind(Kind::Custom(DRAFT_REQUEST_KIND))
        .custom_tags(
            nostr::SingleLetterTag::lowercase(nostr::Alphabet::P),
            [owner.public_key().to_hex()],
        )
}

/// Expect the next message to be a CLOSED with a `restricted:` reason.
async fn expect_closed(client: &mut BuzzTestClient, sid: &str) {
    match client.recv_event(Duration::from_secs(5)).await {
        Ok(RelayMessage::Closed {
            subscription_id,
            message,
        }) => {
            assert_eq!(subscription_id, sid);
            assert!(
                message.contains("restricted:"),
                "expected restricted refusal, got: {message}"
            );
        }
        other => panic!("expected CLOSED, got: {other:?}"),
    }
}

/// Owner reads their pending drafts via REQ.
#[tokio::test]
#[ignore]
async fn test_agent_draft_owner_reads_pending() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let event = build_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    );
    let event_id = event.id;
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);

    let mut owner = BuzzTestClient::connect(&url, &owner_keys)
        .await
        .expect("connect owner");
    let sid = sub_id("owner-read");
    owner
        .subscribe(&sid, vec![owner_p_filter(&owner_keys)])
        .await
        .expect("subscribe");
    let events = owner
        .collect_until_eose(&sid, Duration::from_secs(5))
        .await
        .expect("collect");
    assert!(
        events.iter().any(|e| e.id == event_id),
        "owner must read their pending draft"
    );

    agent.disconnect().await.expect("disconnect agent");
    owner.disconnect().await.expect("disconnect owner");
}

/// The requesting agent reads back its own draft (second `p` tag).
#[tokio::test]
#[ignore]
async fn test_agent_draft_agent_reads_own() {
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let event = build_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    );
    let event_id = event.id;
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);

    let sid = sub_id("agent-read");
    agent
        .subscribe(
            &sid,
            vec![Filter::new()
                .kind(Kind::Custom(DRAFT_REQUEST_KIND))
                .custom_tags(
                    nostr::SingleLetterTag::lowercase(nostr::Alphabet::P),
                    [agent_keys.public_key().to_hex()],
                )],
        )
        .await
        .expect("subscribe");
    let events = agent
        .collect_until_eose(&sid, Duration::from_secs(5))
        .await
        .expect("collect");
    assert!(
        events.iter().any(|e| e.id == event_id),
        "agent must read back its own draft"
    );

    agent.disconnect().await.expect("disconnect agent");
}

/// A third party gets nothing via REQ.
#[tokio::test]
#[ignore]
async fn test_agent_draft_third_party_gets_nothing() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let third_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let event = build_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    );
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);
    agent.disconnect().await.expect("disconnect agent");

    let mut third = BuzzTestClient::connect(&url, &third_keys)
        .await
        .expect("connect third");
    let sid = sub_id("third-req");
    third
        .subscribe(&sid, vec![owner_p_filter(&owner_keys)])
        .await
        .expect("subscribe");
    // The p-gate closes a `#p` filter that does not name the reader.
    expect_closed(&mut third, &sid).await;

    third.disconnect().await.expect("disconnect third");
}

/// Kindless `{ids:[known]}` returns nothing to a third party.
#[tokio::test]
#[ignore]
async fn test_agent_draft_ids_lookup_third_party_gets_nothing() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let third_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let event = build_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    );
    let event_id = event.id;
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);
    agent.disconnect().await.expect("disconnect agent");

    let mut third = BuzzTestClient::connect(&url, &third_keys)
        .await
        .expect("connect third");
    let sid = sub_id("third-ids");
    third
        .subscribe(&sid, vec![Filter::new().id(event_id)])
        .await
        .expect("subscribe");
    let events = third
        .collect_until_eose(&sid, Duration::from_secs(5))
        .await
        .expect("collect");
    assert!(
        events.is_empty(),
        "kindless ids lookup must return nothing to a third party"
    );

    third.disconnect().await.expect("disconnect third");
}

/// COUNT excludes the draft for a third party.
#[tokio::test]
#[ignore]
async fn test_agent_draft_count_third_party_gets_nothing() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let third_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let ok = agent
        .send_event(build_draft_request(
            &agent_keys,
            &owner_keys.public_key(),
            &sample_create_payload(&request_id),
        ))
        .await
        .expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);
    agent.disconnect().await.expect("disconnect agent");

    let mut third = BuzzTestClient::connect(&url, &third_keys)
        .await
        .expect("connect third");
    let sid = sub_id("third-count");
    let count_msg = serde_json::json!(["COUNT", sid, owner_p_filter(&owner_keys)]);
    third.send_raw(&count_msg).await.expect("send COUNT");
    // The p-gate either closes the COUNT or returns 0 — either way the third
    // party learns nothing about the draft.
    match third.recv_event(Duration::from_secs(5)).await {
        Ok(RelayMessage::Count { count, .. }) => {
            assert_eq!(count, 0, "third party COUNT must be 0, got {count}")
        }
        Ok(RelayMessage::Closed { message, .. }) => {
            assert!(
                message.contains("restricted:"),
                "expected restricted COUNT refusal, got: {message}"
            )
        }
        Ok(other) => panic!("unexpected COUNT message: {other:?}"),
        Err(e) => panic!("COUNT error: {e}"),
    }

    third.disconnect().await.expect("disconnect third");
}

/// Live fan-out does not deliver the draft to a third party.
#[tokio::test]
#[ignore]
async fn test_agent_draft_live_fanout_third_party_gets_nothing() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let third_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut third = BuzzTestClient::connect(&url, &third_keys)
        .await
        .expect("connect third");
    let sid = sub_id("third-fanout");
    third
        .subscribe(&sid, vec![owner_p_filter(&owner_keys)])
        .await
        .expect("subscribe");
    // The p-gate closes the subscription before any live delivery.
    expect_closed(&mut third, &sid).await;

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let event = build_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    );
    let event_id = event.id;
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);

    // No live event may reach the third party.
    match third.recv_event(Duration::from_millis(750)).await {
        Err(buzz_test_client::TestClientError::Timeout) => {}
        Ok(RelayMessage::Event { event, .. }) if event.id == event_id => {
            panic!("draft leaked to third-party live subscription")
        }
        Ok(_) => {}
        Err(e) => panic!("unexpected fan-out error: {e}"),
    }

    agent.disconnect().await.expect("disconnect agent");
    third.disconnect().await.expect("disconnect third");
}

/// Ingest rejects a draft with no agent-owner binding.
#[tokio::test]
#[ignore]
async fn test_agent_draft_ingest_rejects_no_owner_binding() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    // Agent connects WITHOUT NIP-OA — no owner binding.
    let mut agent = BuzzTestClient::connect(&url, &agent_keys)
        .await
        .expect("connect agent");
    let event = build_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    );
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(!ok.accepted, "draft without owner binding must be rejected");
    assert!(
        ok.message.contains("restricted:"),
        "expected restricted refusal, got: {}",
        ok.message
    );

    agent.disconnect().await.expect("disconnect agent");
}

/// Ingest rejects wrong `p` cardinality.
#[tokio::test]
#[ignore]
async fn test_agent_draft_ingest_rejects_wrong_p_cardinality() {
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let encrypted = encrypt_agent_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    )
    .expect("encrypt");
    // Only one `p` tag.
    let event = EventBuilder::new(Kind::Custom(DRAFT_REQUEST_KIND), encrypted)
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(&agent_keys)
        .expect("sign");
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(!ok.accepted, "wrong p cardinality must be rejected");
    assert!(
        ok.message.contains("invalid:"),
        "expected invalid refusal, got: {}",
        ok.message
    );

    agent.disconnect().await.expect("disconnect agent");
}

/// Ingest rejects a draft carrying an `h` tag.
#[tokio::test]
#[ignore]
async fn test_agent_draft_ingest_rejects_h_tag() {
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let encrypted = encrypt_agent_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    )
    .expect("encrypt");
    let event = EventBuilder::new(Kind::Custom(DRAFT_REQUEST_KIND), encrypted)
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["h", "some-channel"]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(&agent_keys)
        .expect("sign");
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(!ok.accepted, "draft with h tag must be rejected");
    assert!(
        ok.message.contains("invalid:"),
        "expected invalid refusal, got: {}",
        ok.message
    );

    agent.disconnect().await.expect("disconnect agent");
}

/// Ingest rejects non-NIP-44 content.
#[tokio::test]
#[ignore]
async fn test_agent_draft_ingest_rejects_non_nip44_content() {
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let event = EventBuilder::new(Kind::Custom(DRAFT_REQUEST_KIND), "not-a-ciphertext")
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(&agent_keys)
        .expect("sign");
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(!ok.accepted, "non-NIP-44 content must be rejected");
    assert!(
        ok.message.contains("invalid:"),
        "expected invalid refusal, got: {}",
        ok.message
    );

    agent.disconnect().await.expect("disconnect agent");
}

/// Ingest rejects a 44300 authored by someone other than the agent.
#[tokio::test]
#[ignore]
async fn test_agent_draft_ingest_rejects_wrong_author_44300() {
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let encrypted = encrypt_agent_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    )
    .expect("encrypt");
    // Signed by the OWNER, not the agent — event.pubkey != agent tag.
    let event = EventBuilder::new(Kind::Custom(DRAFT_REQUEST_KIND), encrypted)
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(&owner_keys)
        .expect("sign");
    let ok = agent.send_event(event).await.expect("send draft");
    assert!(!ok.accepted, "44300 authored by non-agent must be rejected");
    assert!(
        ok.message.contains("invalid:"),
        "expected invalid refusal, got: {}",
        ok.message
    );

    agent.disconnect().await.expect("disconnect agent");
}

/// Ingest rejects a 44301 authored by someone other than the owner.
#[tokio::test]
#[ignore]
async fn test_agent_draft_ingest_rejects_wrong_author_44301() {
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();
    let request_event_id = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2";

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let payload = AgentDraftResolutionPayload {
        version: AGENT_DRAFT_VERSION,
        request_id: request_id.clone(),
        status: AgentDraftResolutionStatus::Accepted,
        timestamp: "2026-08-05T12:05:00.000Z".to_string(),
        agent_pubkey: Some(agent_keys.public_key().to_hex()),
        reason: None,
    };
    let encrypted = encrypt_agent_draft_resolution(&owner_keys, &agent_keys.public_key(), &payload)
        .expect("encrypt res");
    // Signed by the AGENT, not the owner — event.pubkey != owner p tag.
    let event = EventBuilder::new(Kind::Custom(DRAFT_RESOLUTION_KIND), encrypted)
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["e", request_event_id]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(&agent_keys)
        .expect("sign");
    let ok = agent.send_event(event).await.expect("send resolution");
    assert!(!ok.accepted, "44301 authored by non-owner must be rejected");
    assert!(
        ok.message.contains("invalid:"),
        "expected invalid refusal, got: {}",
        ok.message
    );

    agent.disconnect().await.expect("disconnect agent");
}

/// A 44301 resolution retires the draft from a pending query.
#[tokio::test]
#[ignore]
async fn test_agent_draft_resolution_retires_draft() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let request = build_draft_request(
        &agent_keys,
        &owner_keys.public_key(),
        &sample_create_payload(&request_id),
    );
    let request_event_id = request.id.to_hex();
    let ok = agent.send_event(request).await.expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);

    let mut owner = BuzzTestClient::connect(&url, &owner_keys)
        .await
        .expect("connect owner");
    let resolution = build_draft_resolution(
        &owner_keys,
        &agent_keys.public_key(),
        &request_event_id,
        &request_id,
    );
    let resolution_id = resolution.id;
    let ok = owner.send_event(resolution).await.expect("send resolution");
    assert!(ok.accepted, "resolution rejected: {}", ok.message);

    // The owner can read the resolution back, and its `e` tag references the
    // request event id — the join a client uses to retire the draft from its
    // pending list.
    let sid = sub_id("resolution-read");
    let resolution_filter = Filter::new()
        .kind(Kind::Custom(DRAFT_RESOLUTION_KIND))
        .custom_tags(
            nostr::SingleLetterTag::lowercase(nostr::Alphabet::P),
            [owner_keys.public_key().to_hex()],
        );
    owner
        .subscribe(&sid, vec![resolution_filter])
        .await
        .expect("subscribe");
    let events = owner
        .collect_until_eose(&sid, Duration::from_secs(5))
        .await
        .expect("collect");
    let resolution_event = events
        .iter()
        .find(|e| e.id == resolution_id)
        .expect("owner must read the resolution");
    let e_tag = resolution_event
        .tags
        .iter()
        .find_map(|t| {
            let parts = t.as_slice();
            if parts.first().map(|p| p.as_str()) == Some("e") {
                parts.get(1).map(|v| v.as_str())
            } else {
                None
            }
        })
        .expect("resolution must carry an e tag");
    assert_eq!(
        e_tag, request_event_id,
        "resolution e tag must reference the request event id"
    );

    agent.disconnect().await.expect("disconnect agent");
    owner.disconnect().await.expect("disconnect owner");
}

/// The draft is not FTS-discoverable via a NIP-50 search filter.
#[tokio::test]
#[ignore]
async fn test_agent_draft_not_fts_discoverable() {
    let url = relay_url();
    let owner_keys = Keys::generate();
    let agent_keys = Keys::generate();
    let request_id = uuid::Uuid::new_v4().to_string();
    let unique_token = format!("draftnosearch_{}", uuid::Uuid::new_v4().simple());

    let mut agent = connect_agent_with_owner(&agent_keys, &owner_keys).await;
    let mut payload = sample_create_payload(&request_id);
    if let AgentDraftRequest::Create(c) = &mut payload.request {
        c.system_prompt = format!("{unique_token} secret instructions");
    }
    let ok = agent
        .send_event(build_draft_request(
            &agent_keys,
            &owner_keys.public_key(),
            &payload,
        ))
        .await
        .expect("send draft");
    assert!(ok.accepted, "draft rejected: {}", ok.message);
    agent.disconnect().await.expect("disconnect agent");

    let mut owner = BuzzTestClient::connect(&url, &owner_keys)
        .await
        .expect("connect owner");
    let sid = sub_id("fts");
    // Scope the search to the owner's drafts so the p-gate is satisfied; the
    // draft must still not surface because its `search_tsv` is NULL.
    let search_filter = Filter::new()
        .kind(Kind::Custom(DRAFT_REQUEST_KIND))
        .custom_tags(
            nostr::SingleLetterTag::lowercase(nostr::Alphabet::P),
            [owner_keys.public_key().to_hex()],
        )
        .search(&unique_token);
    owner
        .subscribe(&sid, vec![search_filter])
        .await
        .expect("subscribe");
    let events = owner
        .collect_until_eose(&sid, Duration::from_secs(5))
        .await
        .expect("collect");
    assert!(
        events.is_empty(),
        "draft must not be FTS-discoverable, got {} events",
        events.len()
    );

    owner.disconnect().await.expect("disconnect owner");
}
