//! NIP-AD agent draft read/resolve commands (kinds 44300/44301).
//!
//! The owner's desktop lists pending draft requests (kind 44300) addressed to
//! it, decrypts them with the owner key, and resolves them by publishing a
//! kind 44301 resolution. See `docs/nips/NIP-AD.md`.

use serde::Serialize;
use tauri::State;

use crate::app_state::AppState;
use crate::relay::{query_relay, submit_event_with_keys};

/// A pending agent draft surfaced to the owner for review.
///
/// Carries only the decrypted, flattened request fields — never a secret.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingAgentDraftInfo {
    /// Event id of the kind 44300 request.
    pub request_event_id: String,
    /// The draft's request id (uuid).
    pub request_id: String,
    /// `create` or `update`.
    pub action: String,
    /// Channel UUID the draft is scoped to.
    pub channel_id: String,
    /// The requesting agent's pubkey.
    pub agent_pubkey: String,
    /// Unix timestamp of the request.
    pub created_at: u64,
    /// Proposed display name (create, or update when present).
    pub display_name: Option<String>,
    /// Proposed system prompt (create, or update when present).
    pub system_prompt: Option<String>,
    /// Agent name to update (update only).
    pub agent_name: Option<String>,
    /// New runtime (update only).
    pub runtime: Option<String>,
    /// New provider (update only).
    pub provider: Option<String>,
    /// New model (update only).
    pub model: Option<String>,
    /// New respond-to policy (update only).
    pub respond_to: Option<String>,
}

/// List pending (unresolved) agent drafts addressed to the current owner.
///
/// Queries both kinds, decrypts each 44300 with the owner key, drops any that
/// fail to decrypt or that already have a 44301 resolution for the same
/// `requestId`, and returns the remainder newest-first.
#[tauri::command]
pub async fn list_pending_agent_drafts(
    state: State<'_, AppState>,
) -> Result<Vec<PendingAgentDraftInfo>, String> {
    let owner_keys = state.signing_keys()?;
    let owner_hex = owner_keys.public_key().to_hex();

    let requests = query_relay(
        &state,
        &[serde_json::json!({
            "kinds": [buzz_core_pkg::kind::KIND_AGENT_DRAFT_REQUEST],
            "#p": [owner_hex],
            "limit": 100,
        })],
    )
    .await?;
    let resolutions = query_relay(
        &state,
        &[serde_json::json!({
            "kinds": [buzz_core_pkg::kind::KIND_AGENT_DRAFT_RESOLUTION],
            "#p": [owner_hex],
        })],
    )
    .await?;

    // Collect request event ids that already have a resolution. The owner
    // cannot decrypt 44301 (it is encrypted to the agent), so resolved-ness is
    // derived from the cleartext `e` tag, which references the request event id.
    let mut resolved_event_ids: std::collections::HashSet<String> =
        std::collections::HashSet::new();
    for event in &resolutions {
        for tag in event.tags.iter() {
            let parts = tag.as_slice();
            if parts.len() >= 2 && parts[0].as_str() == "e" {
                resolved_event_ids.insert(parts[1].to_string());
            }
        }
    }

    let mut drafts = Vec::new();
    for event in requests {
        let payload =
            match buzz_core_pkg::agent_draft::decrypt_agent_draft_request(&owner_keys, &event) {
                Ok(p) => p,
                Err(_) => continue, // not decryptable by this key — drop
            };
        if resolved_event_ids.contains(&event.id.to_hex()) {
            continue; // already resolved
        }
        let (action, display_name, system_prompt, agent_name, runtime, provider, model, respond_to) =
            match payload.request {
                buzz_core_pkg::agent_draft::AgentDraftRequest::Create(c) => (
                    "create".to_string(),
                    Some(c.display_name),
                    Some(c.system_prompt),
                    None,
                    None,
                    None,
                    None,
                    None,
                ),
                buzz_core_pkg::agent_draft::AgentDraftRequest::Update(u) => (
                    "update".to_string(),
                    u.display_name,
                    u.system_prompt,
                    Some(u.agent_name),
                    u.runtime,
                    u.provider,
                    u.model,
                    u.respond_to.map(|r| match r {
                        buzz_core_pkg::agent_draft::AgentDraftRespondTo::OwnerOnly => {
                            "owner-only".to_string()
                        }
                        buzz_core_pkg::agent_draft::AgentDraftRespondTo::Anyone => {
                            "anyone".to_string()
                        }
                    }),
                ),
            };
        drafts.push(PendingAgentDraftInfo {
            request_event_id: event.id.to_hex(),
            request_id: payload.request_id,
            action,
            channel_id: payload.channel_id,
            agent_pubkey: event.pubkey.to_hex(),
            created_at: event.created_at.as_secs(),
            display_name,
            system_prompt,
            agent_name,
            runtime,
            provider,
            model,
            respond_to,
        });
    }
    // Newest first.
    drafts.sort_by_key(|d| std::cmp::Reverse(d.created_at));
    Ok(drafts)
}

/// Resolve an agent draft by publishing a kind 44301 resolution.
///
/// `status` is one of `accepted`, `declined`, `superseded`. `agent_pubkey_saved`
/// is the agent the owner actually saved and is required when `status` is
/// `accepted`. `reason` is an optional operator-visible note.
#[tauri::command]
pub async fn resolve_agent_draft(
    state: State<'_, AppState>,
    request_event_id: String,
    request_id: String,
    agent_pubkey: String,
    status: String,
    agent_pubkey_saved: Option<String>,
    reason: Option<String>,
) -> Result<serde_json::Value, String> {
    let owner_keys = state.signing_keys()?;
    let status_enum = match status.as_str() {
        "accepted" => buzz_core_pkg::agent_draft::AgentDraftResolutionStatus::Accepted,
        "declined" => buzz_core_pkg::agent_draft::AgentDraftResolutionStatus::Declined,
        "superseded" => buzz_core_pkg::agent_draft::AgentDraftResolutionStatus::Superseded,
        other => return Err(format!("invalid status: {other}")),
    };
    let agent_pubkey =
        nostr::PublicKey::parse(&agent_pubkey).map_err(|e| format!("invalid agent pubkey: {e}"))?;
    let payload = buzz_core_pkg::agent_draft::AgentDraftResolutionPayload {
        version: buzz_core_pkg::agent_draft::AGENT_DRAFT_VERSION,
        request_id,
        status: status_enum,
        timestamp: chrono::Utc::now().to_rfc3339(),
        agent_pubkey: agent_pubkey_saved,
        reason,
    };
    let encrypted = buzz_core_pkg::agent_draft::encrypt_agent_draft_resolution(
        &owner_keys,
        &agent_pubkey,
        &payload,
    )
    .map_err(|e| format!("could not encrypt draft resolution: {e}"))?;
    let builder = buzz_sdk_pkg::build_agent_draft_resolution(
        &owner_keys.public_key().to_hex(),
        &agent_pubkey.to_hex(),
        &request_event_id,
        &encrypted,
    )
    .map_err(|e| format!("could not build draft resolution: {e}"))?;
    let response = submit_event_with_keys(builder, &state, &owner_keys, None).await?;
    Ok(serde_json::json!({
        "event_id": response.event_id,
        "accepted": response.accepted,
        "message": response.message,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use buzz_core_pkg::agent_draft::{
        encrypt_agent_draft_request, AgentDraftAction, AgentDraftCreateRequest, AgentDraftRequest,
        AgentDraftRequestPayload, AgentDraftResolutionPayload, AgentDraftResolutionStatus,
        AGENT_DRAFT_VERSION,
    };
    use nostr::{EventBuilder, Kind, Tag};

    fn build_request_event(
        agent_keys: &nostr::Keys,
        owner_pubkey: &nostr::PublicKey,
        payload: &AgentDraftRequestPayload,
    ) -> nostr::Event {
        let encrypted =
            encrypt_agent_draft_request(agent_keys, owner_pubkey, payload).expect("encrypt");
        EventBuilder::new(
            Kind::Custom(buzz_core_pkg::kind::KIND_AGENT_DRAFT_REQUEST as u16),
            encrypted,
        )
        .tags([
            Tag::parse(["p", &owner_pubkey.to_hex()]).unwrap(),
            Tag::parse(["p", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(agent_keys)
        .expect("sign")
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

    fn build_resolution_event(
        owner_keys: &nostr::Keys,
        agent_pubkey: &nostr::PublicKey,
        request_id: &str,
        request_event_id: &str,
    ) -> nostr::Event {
        let payload = AgentDraftResolutionPayload {
            version: AGENT_DRAFT_VERSION,
            request_id: request_id.to_string(),
            status: AgentDraftResolutionStatus::Accepted,
            timestamp: "2026-08-05T12:05:00.000Z".to_string(),
            agent_pubkey: Some(agent_pubkey.to_hex()),
            reason: None,
        };
        let encrypted = buzz_core_pkg::agent_draft::encrypt_agent_draft_resolution(
            owner_keys,
            agent_pubkey,
            &payload,
        )
        .expect("encrypt");
        EventBuilder::new(
            Kind::Custom(buzz_core_pkg::kind::KIND_AGENT_DRAFT_RESOLUTION as u16),
            encrypted,
        )
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent_pubkey.to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_pubkey.to_hex()]).unwrap(),
            Tag::parse(["e", request_event_id]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(owner_keys)
        .expect("sign")
    }

    #[test]
    fn pending_draft_info_flattens_create_request() {
        let agent = nostr::Keys::generate();
        let owner = nostr::Keys::generate();
        let payload = sample_create_payload("req-1");
        let event = build_request_event(&agent, &owner.public_key(), &payload);

        let info = pending_draft_info(&owner, &event).expect("decrypt");
        assert_eq!(info.request_id, "req-1");
        assert_eq!(info.action, "create");
        assert_eq!(info.channel_id, payload.channel_id);
        assert_eq!(info.agent_pubkey, agent.public_key().to_hex());
        assert_eq!(info.display_name.as_deref(), Some("dev-coder"));
        assert_eq!(
            info.system_prompt.as_deref(),
            Some("You are a coding specialist.")
        );
        assert!(info.agent_name.is_none());
    }

    #[test]
    fn pending_draft_info_rejects_unsupported_version() {
        let agent = nostr::Keys::generate();
        let owner = nostr::Keys::generate();
        let mut payload = sample_create_payload("req-2");
        payload.version = 2;
        // encrypt_agent_draft_request validates and would reject version 2, so
        // encrypt via the lower-level observer path to simulate a future/malformed
        // publisher that bypassed validation.
        let encrypted = buzz_core_pkg::observer::encrypt_observer_payload(
            &agent,
            &owner.public_key(),
            &payload,
        )
        .expect("lower-level encrypt");
        let event = EventBuilder::new(
            Kind::Custom(buzz_core_pkg::kind::KIND_AGENT_DRAFT_REQUEST as u16),
            encrypted,
        )
        .tags([
            Tag::parse(["p", &owner.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent.public_key().to_hex()]).unwrap(),
        ])
        .allow_self_tagging()
        .sign_with_keys(&agent)
        .expect("sign");
        // decrypt_agent_draft_request fails closed on version 2.
        assert!(buzz_core_pkg::agent_draft::decrypt_agent_draft_request(&owner, &event).is_err());
    }

    #[test]
    fn pending_draft_info_drops_undecryptable_event() {
        let agent = nostr::Keys::generate();
        let owner = nostr::Keys::generate();
        let wrong_owner = nostr::Keys::generate();
        let payload = sample_create_payload("req-3");
        let event = build_request_event(&agent, &owner.public_key(), &payload);
        // A different key cannot decrypt it.
        assert!(pending_draft_info(&wrong_owner, &event).is_none());
    }

    #[test]
    fn resolution_filtering_uses_e_tag_to_drop_resolved_requests() {
        let agent = nostr::Keys::generate();
        let owner = nostr::Keys::generate();
        let payload = sample_create_payload("req-4");
        let request_event = build_request_event(&agent, &owner.public_key(), &payload);
        let resolution_event = build_resolution_event(
            &owner,
            &agent.public_key(),
            "req-4",
            &request_event.id.to_hex(),
        );

        // The owner cannot decrypt 44301; resolved-ness comes from the cleartext
        // `e` tag, which references the request event id.
        let mut resolved_event_ids = std::collections::HashSet::new();
        for tag in resolution_event.tags.iter() {
            let parts = tag.as_slice();
            if parts.len() >= 2 && parts[0].as_str() == "e" {
                resolved_event_ids.insert(parts[1].to_string());
            }
        }
        assert!(
            resolved_event_ids.contains(&request_event.id.to_hex()),
            "resolution e tag must reference the request event id"
        );
    }

    #[test]
    fn resolve_builds_correct_envelope() {
        let owner = nostr::Keys::generate();
        let agent = nostr::Keys::generate();
        let request_event_id = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2";
        let payload = AgentDraftResolutionPayload {
            version: AGENT_DRAFT_VERSION,
            request_id: "req-5".to_string(),
            status: AgentDraftResolutionStatus::Accepted,
            timestamp: "2026-08-05T12:05:00.000Z".to_string(),
            agent_pubkey: Some(agent.public_key().to_hex()),
            reason: Some("Approved".to_string()),
        };
        let encrypted = buzz_core_pkg::agent_draft::encrypt_agent_draft_resolution(
            &owner,
            &agent.public_key(),
            &payload,
        )
        .expect("encrypt");
        let builder = buzz_sdk_pkg::build_agent_draft_resolution(
            &owner.public_key().to_hex(),
            &agent.public_key().to_hex(),
            request_event_id,
            &encrypted,
        )
        .expect("build");
        let event = builder.sign_with_keys(&owner).expect("sign");
        assert_eq!(
            event.kind.as_u16(),
            buzz_core_pkg::kind::KIND_AGENT_DRAFT_RESOLUTION as u16
        );
        let p_tags: Vec<String> = event
            .tags
            .iter()
            .filter(|t| t.as_slice().first().map(|v| v.as_str()) == Some("p"))
            .map(|t| t.as_slice()[1].to_string())
            .collect();
        assert_eq!(p_tags.len(), 2);
        assert!(p_tags.contains(&owner.public_key().to_hex()));
        assert!(p_tags.contains(&agent.public_key().to_hex()));
        let e_tags: Vec<String> = event
            .tags
            .iter()
            .filter(|t| t.as_slice().first().map(|v| v.as_str()) == Some("e"))
            .map(|t| t.as_slice()[1].to_string())
            .collect();
        assert_eq!(e_tags, vec![request_event_id.to_string()]);
    }

    /// Decrypt a 44300 request with the owner key and flatten it, or `None`
    /// when it cannot be decrypted (mirrors the list command's drop behavior).
    fn pending_draft_info(
        owner_keys: &nostr::Keys,
        event: &nostr::Event,
    ) -> Option<PendingAgentDraftInfo> {
        let payload =
            buzz_core_pkg::agent_draft::decrypt_agent_draft_request(owner_keys, event).ok()?;
        let (action, display_name, system_prompt, agent_name, runtime, provider, model, respond_to) =
            match payload.request {
                AgentDraftRequest::Create(c) => (
                    "create".to_string(),
                    Some(c.display_name),
                    Some(c.system_prompt),
                    None,
                    None,
                    None,
                    None,
                    None,
                ),
                AgentDraftRequest::Update(u) => (
                    "update".to_string(),
                    u.display_name,
                    u.system_prompt,
                    Some(u.agent_name),
                    u.runtime,
                    u.provider,
                    u.model,
                    u.respond_to.map(|r| match r {
                        buzz_core_pkg::agent_draft::AgentDraftRespondTo::OwnerOnly => {
                            "owner-only".to_string()
                        }
                        buzz_core_pkg::agent_draft::AgentDraftRespondTo::Anyone => {
                            "anyone".to_string()
                        }
                    }),
                ),
            };
        Some(PendingAgentDraftInfo {
            request_event_id: event.id.to_hex(),
            request_id: payload.request_id,
            action,
            channel_id: payload.channel_id,
            agent_pubkey: event.pubkey.to_hex(),
            created_at: event.created_at.as_secs(),
            display_name,
            system_prompt,
            agent_name,
            runtime,
            provider,
            model,
            respond_to,
        })
    }
}
