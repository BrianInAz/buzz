//! `buzz agents drafts` — list and inspect durable NIP-AD agent drafts.
//!
//! Both `list` and `status` work for either side of the agent↔owner
//! relationship because of the two-`p`-tag design: run as the agent it lists
//! the agent's own drafts; run as the owner it lists everything addressed to
//! that owner. Drafts are decrypted with the running key; anything that key
//! cannot decrypt is skipped.

use std::collections::HashMap;

use buzz_core::agent_draft::{decrypt_agent_draft_request, AgentDraftRequest};
use serde_json::{json, Value};

use crate::client::BuzzClient;
use crate::error::CliError;
use crate::DraftsCmd;

pub async fn dispatch(command: DraftsCmd, client: &BuzzClient) -> Result<(), CliError> {
    match command {
        DraftsCmd::List {
            channel,
            pending,
            all,
            limit,
        } => {
            let drafts = list_drafts(client, channel.as_deref(), all, limit).await?;
            let _ = pending; // `--pending` is the default; `--all` opts into resolved
            println!(
                "{}",
                serde_json::to_string(&drafts)
                    .map_err(|e| CliError::Other(format!("serialization failed: {e}")))?
            );
            Ok(())
        }
        DraftsCmd::Status { request_id } => {
            let status = status_draft(client, &request_id).await?;
            match status {
                Some(s) => {
                    println!(
                        "{}",
                        serde_json::to_string(&s)
                            .map_err(|e| CliError::Other(format!("serialization failed: {e}")))?
                    );
                    Ok(())
                }
                None => {
                    println!("{}", json!({"error": "unknown request_id"}));
                    Err(CliError::Usage("unknown request_id".into()))
                }
            }
        }
    }
}

async fn list_drafts(
    client: &BuzzClient,
    channel: Option<&str>,
    all: bool,
    limit: u32,
) -> Result<Vec<Value>, CliError> {
    let me = client.keys().public_key().to_hex();
    let request_filter = json!({
        "kinds": [buzz_core::kind::KIND_AGENT_DRAFT_REQUEST],
        "#p": [me],
        "limit": limit,
    });
    let requests = client.query_paginated(request_filter, limit).await?;
    let resolution_filter = json!({
        "kinds": [buzz_core::kind::KIND_AGENT_DRAFT_RESOLUTION],
        "#p": [me],
    });
    let resolutions = client.query_all(resolution_filter).await?;

    // Resolved-ness is derived from the cleartext `e` tag of 44301 events
    // (which references the request event id). The owner cannot decrypt 44301
    // (it is encrypted to the agent), so we never rely on decryption here.
    let mut resolved_event_ids: HashMap<String, String> = HashMap::new();
    for raw in resolutions {
        let event: nostr::Event = match serde_json::from_value(raw) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for tag in event.tags.iter() {
            let parts = tag.as_slice();
            if parts.len() >= 2 && parts[0].as_str() == "e" {
                resolved_event_ids.insert(parts[1].to_string(), event.id.to_hex());
            }
        }
    }

    let mut drafts = Vec::new();
    for raw in requests {
        let event: nostr::Event = match serde_json::from_value(raw) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let payload = match decrypt_agent_draft_request(client.keys(), &event) {
            Ok(p) => p,
            Err(_) => continue, // not decryptable by this key — skip
        };
        if let Some(ch) = channel {
            if payload.channel_id != ch {
                continue;
            }
        }
        let status = if resolved_event_ids.contains_key(&event.id.to_hex()) {
            "resolved".to_string()
        } else {
            "pending".to_string()
        };
        if !all && status != "pending" {
            continue;
        }
        let action = match &payload.request {
            AgentDraftRequest::Create(_) => "create",
            AgentDraftRequest::Update(_) => "update",
        };
        drafts.push(json!({
            "request_id": payload.request_id,
            "event_id": event.id.to_hex(),
            "action": action,
            "channel_id": payload.channel_id,
            "agent_pubkey": event.pubkey.to_hex(),
            "created_at": event.created_at.as_secs(),
            "status": status,
        }));
    }
    // Newest first.
    drafts.sort_by(|a, b| b["created_at"].as_u64().cmp(&a["created_at"].as_u64()));
    Ok(drafts)
}

async fn status_draft(client: &BuzzClient, request_id: &str) -> Result<Option<Value>, CliError> {
    let me = client.keys().public_key().to_hex();
    let request_filter = json!({
        "kinds": [buzz_core::kind::KIND_AGENT_DRAFT_REQUEST],
        "#p": [me],
        "limit": 100,
    });
    let requests = client.query_paginated(request_filter, 100).await?;
    let resolution_filter = json!({
        "kinds": [buzz_core::kind::KIND_AGENT_DRAFT_RESOLUTION],
        "#p": [me],
    });
    let resolutions = client.query_all(resolution_filter).await?;

    // Resolved-ness from the cleartext `e` tag (the owner cannot decrypt 44301).
    let mut resolved_event_ids: HashMap<String, String> = HashMap::new();
    for raw in resolutions {
        let event: nostr::Event = match serde_json::from_value(raw) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for tag in event.tags.iter() {
            let parts = tag.as_slice();
            if parts.len() >= 2 && parts[0].as_str() == "e" {
                resolved_event_ids.insert(parts[1].to_string(), event.id.to_hex());
            }
        }
    }

    for raw in requests {
        let event: nostr::Event = match serde_json::from_value(raw) {
            Ok(e) => e,
            Err(_) => continue,
        };
        let payload = match decrypt_agent_draft_request(client.keys(), &event) {
            Ok(p) => p,
            Err(_) => continue,
        };
        if payload.request_id != request_id {
            continue;
        }
        let action = match &payload.request {
            AgentDraftRequest::Create(_) => "create",
            AgentDraftRequest::Update(_) => "update",
        };
        let status = if resolved_event_ids.contains_key(&event.id.to_hex()) {
            "resolved"
        } else {
            "pending"
        };
        let mut out = json!({
            "request_id": payload.request_id,
            "event_id": event.id.to_hex(),
            "action": action,
            "channel_id": payload.channel_id,
            "agent_pubkey": event.pubkey.to_hex(),
            "created_at": event.created_at.as_secs(),
            "status": status,
        });
        if let Some(resolution_event_id) = resolved_event_ids.get(&event.id.to_hex()) {
            out["resolution"] = json!({ "event_id": resolution_event_id });
        }
        return Ok(Some(out));
    }
    Ok(None)
}
