//! Owner-reviewed agent draft requests published as durable NIP-AD kind 44300.

use buzz_core::agent_draft::{
    encrypt_agent_draft_request, AgentDraftAction, AgentDraftCreateRequest, AgentDraftRequest,
    AgentDraftRequestPayload, AgentDraftRespondTo, AgentDraftUpdateRequest, AGENT_DRAFT_VERSION,
};
use nostr::{Event, Keys, PublicKey};

use crate::error::CliError;

const MAX_NAME_CHARS: usize = 120;
const MAX_PROMPT_CHARS: usize = 20_000;

#[derive(Debug, Clone)]
pub struct CreateAgentDraft {
    pub channel_id: String,
    pub display_name: String,
    pub system_prompt: String,
}

#[derive(Debug, Clone)]
pub struct UpdateAgentDraft {
    pub channel_id: String,
    pub agent_name: String,
    pub display_name: Option<String>,
    pub system_prompt: Option<String>,
    pub runtime: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub respond_to: Option<String>,
}

#[derive(Debug)]
pub struct BuiltDraftRequest {
    pub event: Event,
    pub event_id: String,
    pub request_id: String,
    pub action: &'static str,
}

fn required(value: String, label: &str, max: usize) -> Result<String, CliError> {
    let value = value.trim();
    if value.is_empty() {
        return Err(CliError::Usage(format!("{label} is required")));
    }
    if value.chars().count() > max {
        return Err(CliError::Usage(format!(
            "{label} is too long (max {max} characters)"
        )));
    }
    Ok(value.to_owned())
}

fn optional(value: Option<String>, label: &str, max: usize) -> Result<Option<String>, CliError> {
    value.map(|value| required(value, label, max)).transpose()
}

fn build(
    keys: &Keys,
    owner: &PublicKey,
    channel_id: String,
    action: AgentDraftAction,
    request: AgentDraftRequest,
) -> Result<BuiltDraftRequest, CliError> {
    let request_id = uuid::Uuid::new_v4().to_string();
    let payload = AgentDraftRequestPayload {
        version: AGENT_DRAFT_VERSION,
        request_id: request_id.clone(),
        action,
        timestamp: chrono::Utc::now().to_rfc3339(),
        channel_id,
        request,
    };
    let encrypted = encrypt_agent_draft_request(keys, owner, &payload)
        .map_err(|error| CliError::Other(format!("could not encrypt draft request: {error}")))?;
    let event = buzz_sdk::build_agent_draft_request(
        &owner.to_hex(),
        &keys.public_key().to_hex(),
        &encrypted,
    )
    .map_err(|error| CliError::Other(format!("could not build draft request: {error}")))?
    .sign_with_keys(keys)
    .map_err(|error| CliError::Other(format!("could not sign draft request: {error}")))?;
    let event_id = event.id.to_hex();
    let action_str = match action {
        AgentDraftAction::Create => "create",
        AgentDraftAction::Update => "update",
    };
    Ok(BuiltDraftRequest {
        event,
        event_id,
        request_id,
        action: action_str,
    })
}

pub fn build_create(
    keys: &Keys,
    owner: &PublicKey,
    draft: CreateAgentDraft,
) -> Result<BuiltDraftRequest, CliError> {
    let channel_id = required(draft.channel_id, "channel", 128)?;
    uuid::Uuid::parse_str(&channel_id)
        .map_err(|_| CliError::Usage(format!("invalid channel UUID: {channel_id}")))?;
    let request = AgentDraftRequest::Create(AgentDraftCreateRequest {
        display_name: required(draft.display_name, "display name", MAX_NAME_CHARS)?,
        system_prompt: required(draft.system_prompt, "system prompt", MAX_PROMPT_CHARS)?,
    });
    build(keys, owner, channel_id, AgentDraftAction::Create, request)
}

pub fn build_update(
    keys: &Keys,
    owner: &PublicKey,
    draft: UpdateAgentDraft,
) -> Result<BuiltDraftRequest, CliError> {
    let channel_id = required(draft.channel_id, "channel", 128)?;
    uuid::Uuid::parse_str(&channel_id)
        .map_err(|_| CliError::Usage(format!("invalid channel UUID: {channel_id}")))?;
    let respond_to = match draft.respond_to.as_deref() {
        None => None,
        Some("owner-only") => Some(AgentDraftRespondTo::OwnerOnly),
        Some("anyone") => Some(AgentDraftRespondTo::Anyone),
        Some(other) => {
            return Err(CliError::Usage(format!(
                "respond-to must be owner-only or anyone (got {other})"
            )))
        }
    };
    let request = AgentDraftRequest::Update(AgentDraftUpdateRequest {
        agent_name: required(draft.agent_name, "agent name", MAX_NAME_CHARS)?,
        display_name: optional(draft.display_name, "display name", MAX_NAME_CHARS)?,
        system_prompt: draft
            .system_prompt
            .map(|value| required(value, "system prompt", MAX_PROMPT_CHARS))
            .transpose()?,
        runtime: optional(draft.runtime, "runtime", 300)?,
        provider: optional(draft.provider, "provider", 300)?,
        model: optional(draft.model, "model", 300)?,
        respond_to,
    });
    if request_has_no_change(&request) {
        return Err(CliError::Usage(
            "include at least one field to update".into(),
        ));
    }
    build(keys, owner, channel_id, AgentDraftAction::Update, request)
}

fn request_has_no_change(request: &AgentDraftRequest) -> bool {
    match request {
        AgentDraftRequest::Update(u) => {
            u.display_name.is_none()
                && u.system_prompt.is_none()
                && u.runtime.is_none()
                && u.provider.is_none()
                && u.model.is_none()
                && u.respond_to.is_none()
        }
        AgentDraftRequest::Create(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use buzz_core::agent_draft::decrypt_agent_draft_request;

    const CHANNEL: &str = "7c07e659-3610-42f4-9a5e-1e9973c09da9";

    #[test]
    fn create_is_owner_encrypted_and_matches_desktop_contract() {
        let agent = Keys::generate();
        let owner = Keys::generate();
        let built = build_create(
            &agent,
            &owner.public_key(),
            CreateAgentDraft {
                channel_id: CHANNEL.into(),
                display_name: "Research helper".into(),
                system_prompt: "Find sources.".into(),
            },
        )
        .unwrap();

        assert_eq!(built.event.kind.as_u16(), 44_300);
        let tags: Vec<Vec<String>> = built
            .event
            .tags
            .iter()
            .map(|tag| tag.as_slice().to_vec())
            .collect();
        // Exactly two `p` tags (owner + agent) and one `agent` tag, no `h`.
        let p_tags: Vec<&Vec<String>> = tags
            .iter()
            .filter(|tag| tag.first().map(String::as_str) == Some("p"))
            .collect();
        assert_eq!(p_tags.len(), 2, "must have exactly two p tags");
        assert!(tags
            .iter()
            .any(|tag| tag == &["p", &owner.public_key().to_hex()]));
        assert!(tags
            .iter()
            .any(|tag| tag == &["p", &agent.public_key().to_hex()]));
        assert!(tags
            .iter()
            .any(|tag| tag == &["agent", &agent.public_key().to_hex()]));
        assert!(!tags
            .iter()
            .any(|tag| tag.first().map(String::as_str) == Some("h")));

        let payload = decrypt_agent_draft_request(&owner, &built.event).unwrap();
        assert_eq!(payload.version, 1);
        assert_eq!(payload.request_id, built.request_id);
        assert_eq!(payload.action, AgentDraftAction::Create);
        assert_eq!(payload.channel_id, CHANNEL);
        match payload.request {
            AgentDraftRequest::Create(create) => {
                assert_eq!(create.display_name, "Research helper");
                assert_eq!(create.system_prompt, "Find sources.");
            }
            AgentDraftRequest::Update(_) => panic!("expected create request"),
        }
    }

    #[test]
    fn update_requires_a_change() {
        let error = build_update(
            &Keys::generate(),
            &Keys::generate().public_key(),
            UpdateAgentDraft {
                channel_id: CHANNEL.into(),
                agent_name: "Scout".into(),
                display_name: None,
                system_prompt: None,
                runtime: None,
                provider: None,
                model: None,
                respond_to: None,
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("at least one field"));
    }

    #[test]
    fn create_rejects_invalid_channel() {
        let error = build_create(
            &Keys::generate(),
            &Keys::generate().public_key(),
            CreateAgentDraft {
                channel_id: "general".into(),
                display_name: "Scout".into(),
                system_prompt: "Help".into(),
            },
        )
        .unwrap_err();
        assert!(error.to_string().contains("invalid channel UUID"));
    }
}
