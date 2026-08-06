//! NIP-AD: Agent Draft — payload types and encrypt/decrypt helpers.
//!
//! Two durable, p-gated kinds carry agent draft requests and resolutions:
//! `kind:44300` (agent → owner draft request) and `kind:44301` (owner → agent
//! resolution). Their content is a NIP-44 v2 ciphertext that decodes to an
//! [`AgentDraftRequestPayload`] or [`AgentDraftResolutionPayload`] JSON object.
//!
//! See `docs/nips/NIP-AD.md` for the full specification.

use nostr::{Event, Keys, PublicKey};
use serde::{Deserialize, Serialize};

use crate::observer::{decrypt_observer_payload, encrypt_observer_payload, ObserverPayloadError};

// Re-export for callers that only need the error type.
pub use crate::observer::ObserverPayloadError as AgentDraftError;

/// Maximum length of a draft `displayName` (NIP-AD §Decrypted Payload).
pub const AGENT_DRAFT_MAX_DISPLAY_NAME: usize = 120;
/// Maximum length of a draft `systemPrompt` (NIP-AD §Decrypted Payload).
pub const AGENT_DRAFT_MAX_SYSTEM_PROMPT: usize = 20_000;
/// Maximum length of a resolution `reason` (NIP-AD §Decrypted Payload).
pub const AGENT_DRAFT_MAX_REASON: usize = 500;
/// The only supported payload version. Consumers MUST reject any other value.
pub const AGENT_DRAFT_VERSION: u32 = 1;

/// The action a draft request proposes: create a new managed agent, or update
/// an existing one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentDraftAction {
    /// Propose creating a new managed agent.
    Create,
    /// Propose updating an existing managed agent.
    Update,
}

/// Who an updated agent may respond to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AgentDraftRespondTo {
    /// Only the owner may prompt the agent.
    OwnerOnly,
    /// Any community member may prompt the agent.
    Anyone,
}

/// The `request` body of a `create` draft (`action == "create"`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentDraftCreateRequest {
    /// Proposed display name, at most [`AGENT_DRAFT_MAX_DISPLAY_NAME`] chars.
    pub display_name: String,
    /// Proposed system prompt, at most [`AGENT_DRAFT_MAX_SYSTEM_PROMPT`] chars.
    pub system_prompt: String,
}

impl AgentDraftCreateRequest {
    /// Validate length constraints from NIP-AD §Decrypted Payload.
    pub fn validate(&self) -> Result<(), AgentDraftError> {
        if self.display_name.chars().count() > AGENT_DRAFT_MAX_DISPLAY_NAME {
            return Err(ObserverPayloadError::InvalidPayload(format!(
                "displayName exceeds {} chars",
                AGENT_DRAFT_MAX_DISPLAY_NAME
            )));
        }
        if self.system_prompt.chars().count() > AGENT_DRAFT_MAX_SYSTEM_PROMPT {
            return Err(ObserverPayloadError::InvalidPayload(format!(
                "systemPrompt exceeds {} chars",
                AGENT_DRAFT_MAX_SYSTEM_PROMPT
            )));
        }
        Ok(())
    }
}

/// The `request` body of an `update` draft (`action == "update"`).
///
/// `agent_name` is REQUIRED; at least one of the remaining fields MUST be
/// present (an update with no changed field is rejected).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentDraftUpdateRequest {
    /// The name of the agent to update. REQUIRED.
    pub agent_name: String,
    /// New display name, at most [`AGENT_DRAFT_MAX_DISPLAY_NAME`] chars.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    /// New system prompt, at most [`AGENT_DRAFT_MAX_SYSTEM_PROMPT`] chars.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub system_prompt: Option<String>,
    /// New runtime identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub runtime: Option<String>,
    /// New provider identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider: Option<String>,
    /// New model identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// New respond-to policy.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub respond_to: Option<AgentDraftRespondTo>,
}

impl AgentDraftUpdateRequest {
    /// Validate NIP-AD constraints: `agent_name` present, at least one changed
    /// field, and length limits on any present `displayName`/`systemPrompt`.
    pub fn validate(&self) -> Result<(), AgentDraftError> {
        if self.agent_name.is_empty() {
            return Err(ObserverPayloadError::InvalidPayload(
                "update request requires agentName".to_string(),
            ));
        }
        let has_change = self.display_name.is_some()
            || self.system_prompt.is_some()
            || self.runtime.is_some()
            || self.provider.is_some()
            || self.model.is_some()
            || self.respond_to.is_some();
        if !has_change {
            return Err(ObserverPayloadError::InvalidPayload(
                "update request requires at least one changed field".to_string(),
            ));
        }
        if let Some(d) = &self.display_name {
            if d.chars().count() > AGENT_DRAFT_MAX_DISPLAY_NAME {
                return Err(ObserverPayloadError::InvalidPayload(format!(
                    "displayName exceeds {} chars",
                    AGENT_DRAFT_MAX_DISPLAY_NAME
                )));
            }
        }
        if let Some(s) = &self.system_prompt {
            if s.chars().count() > AGENT_DRAFT_MAX_SYSTEM_PROMPT {
                return Err(ObserverPayloadError::InvalidPayload(format!(
                    "systemPrompt exceeds {} chars",
                    AGENT_DRAFT_MAX_SYSTEM_PROMPT
                )));
            }
        }
        Ok(())
    }
}

/// The `request` field of a draft request payload — a union discriminated by
/// the top-level `action` field. `create` carries a
/// [`AgentDraftCreateRequest`]; `update` carries an [`AgentDraftUpdateRequest`].
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum AgentDraftRequest {
    /// A create proposal.
    Create(AgentDraftCreateRequest),
    /// An update proposal.
    Update(AgentDraftUpdateRequest),
}

impl<'de> Deserialize<'de> for AgentDraftRequest {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // Disambiguate on the presence of `agentName` (only update requests
        // carry it). Unknown fields are otherwise ignored for forward compat.
        let value = serde_json::Value::deserialize(deserializer)?;
        if value.get("agentName").is_some() {
            serde_json::from_value(value)
                .map(AgentDraftRequest::Update)
                .map_err(serde::de::Error::custom)
        } else {
            serde_json::from_value(value)
                .map(AgentDraftRequest::Create)
                .map_err(serde::de::Error::custom)
        }
    }
}

/// Decrypted payload of a `kind:44300` Agent Draft Request event.
///
/// `version` is REQUIRED and MUST be [`AGENT_DRAFT_VERSION`]. Consumers MUST
/// ignore unknown fields, and MUST reject a payload whose `version` they do
/// not understand (fail closed).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentDraftRequestPayload {
    /// Payload version. MUST be [`AGENT_DRAFT_VERSION`].
    pub version: u32,
    /// UUID v4 identifying this draft request.
    pub request_id: String,
    /// Whether this proposes creating or updating an agent.
    pub action: AgentDraftAction,
    /// RFC 3339 timestamp of the request.
    pub timestamp: String,
    /// Channel UUID the draft is scoped to.
    pub channel_id: String,
    /// The create or update body.
    pub request: AgentDraftRequest,
}

impl AgentDraftRequestPayload {
    /// Validate NIP-AD constraints: `version` must be supported, the `action`
    /// must match the `request` variant, and the request body must pass its own
    /// validation.
    pub fn validate(&self) -> Result<(), AgentDraftError> {
        if self.version != AGENT_DRAFT_VERSION {
            return Err(ObserverPayloadError::InvalidPayload(format!(
                "unsupported version {} (expected {})",
                self.version, AGENT_DRAFT_VERSION
            )));
        }
        match (&self.action, &self.request) {
            (AgentDraftAction::Create, AgentDraftRequest::Create(r)) => r.validate(),
            (AgentDraftAction::Update, AgentDraftRequest::Update(r)) => r.validate(),
            _ => Err(ObserverPayloadError::InvalidPayload(
                "action does not match request body".to_string(),
            )),
        }
    }
}

/// The status of a draft resolution.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentDraftResolutionStatus {
    /// The owner accepted the draft and saved the agent.
    Accepted,
    /// The owner declined the draft.
    Declined,
    /// A newer draft superseded this one; no action was taken.
    Superseded,
}

/// Decrypted payload of a `kind:44301` Agent Draft Resolution event.
///
/// `version` is REQUIRED and MUST be [`AGENT_DRAFT_VERSION`]. `agent_pubkey`
/// is present when `status == "accepted"`. `reason` is optional, at most
/// [`AGENT_DRAFT_MAX_REASON`] chars, and operator-visible.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentDraftResolutionPayload {
    /// Payload version. MUST be [`AGENT_DRAFT_VERSION`].
    pub version: u32,
    /// The `requestId` of the draft this resolves (echoes the request).
    pub request_id: String,
    /// The resolution status.
    pub status: AgentDraftResolutionStatus,
    /// RFC 3339 timestamp of the resolution.
    pub timestamp: String,
    /// The agent the owner actually saved; present when `status == "accepted"`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_pubkey: Option<String>,
    /// Optional operator-visible reason, at most [`AGENT_DRAFT_MAX_REASON`] chars.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl AgentDraftResolutionPayload {
    /// Validate NIP-AD constraints: `version` must be supported, `reason` must
    /// be within length limits, and `agent_pubkey` must be present when the
    /// status is `accepted`.
    pub fn validate(&self) -> Result<(), AgentDraftError> {
        if self.version != AGENT_DRAFT_VERSION {
            return Err(ObserverPayloadError::InvalidPayload(format!(
                "unsupported version {} (expected {})",
                self.version, AGENT_DRAFT_VERSION
            )));
        }
        if let Some(r) = &self.reason {
            if r.chars().count() > AGENT_DRAFT_MAX_REASON {
                return Err(ObserverPayloadError::InvalidPayload(format!(
                    "reason exceeds {} chars",
                    AGENT_DRAFT_MAX_REASON
                )));
            }
        }
        if self.status == AgentDraftResolutionStatus::Accepted && self.agent_pubkey.is_none() {
            return Err(ObserverPayloadError::InvalidPayload(
                "accepted resolution requires agentPubkey".to_string(),
            ));
        }
        Ok(())
    }
}

/// Encrypt an [`AgentDraftRequestPayload`] into a NIP-44 v2 ciphertext string
/// using the agent's key pair and the owner's public key.
///
/// This is the content field of a `kind:44300` event.
pub fn encrypt_agent_draft_request(
    agent_keys: &Keys,
    owner_pubkey: &PublicKey,
    payload: &AgentDraftRequestPayload,
) -> Result<String, AgentDraftError> {
    payload.validate()?;
    encrypt_observer_payload(agent_keys, owner_pubkey, payload)
}

/// Decrypt and deserialize an [`AgentDraftRequestPayload`] from a `kind:44300`
/// event. `recipient_keys` is the owner's key pair.
pub fn decrypt_agent_draft_request(
    recipient_keys: &Keys,
    event: &Event,
) -> Result<AgentDraftRequestPayload, AgentDraftError> {
    let payload: AgentDraftRequestPayload = decrypt_observer_payload(recipient_keys, event)?;
    payload.validate()?;
    Ok(payload)
}

/// Encrypt an [`AgentDraftResolutionPayload`] into a NIP-44 v2 ciphertext
/// string using the owner's key pair and the agent's public key.
///
/// This is the content field of a `kind:44301` event.
pub fn encrypt_agent_draft_resolution(
    owner_keys: &Keys,
    agent_pubkey: &PublicKey,
    payload: &AgentDraftResolutionPayload,
) -> Result<String, AgentDraftError> {
    payload.validate()?;
    encrypt_observer_payload(owner_keys, agent_pubkey, payload)
}

/// Decrypt and deserialize an [`AgentDraftResolutionPayload`] from a
/// `kind:44301` event. `recipient_keys` is the agent's key pair.
pub fn decrypt_agent_draft_resolution(
    recipient_keys: &Keys,
    event: &Event,
) -> Result<AgentDraftResolutionPayload, AgentDraftError> {
    let payload: AgentDraftResolutionPayload = decrypt_observer_payload(recipient_keys, event)?;
    payload.validate()?;
    Ok(payload)
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Kind, Tag};

    fn sample_create_payload() -> AgentDraftRequestPayload {
        AgentDraftRequestPayload {
            version: 1,
            request_id: "9f1c2b3a-4d5e-4f6a-8b7c-1d2e3f4a5b6c".to_string(),
            action: AgentDraftAction::Create,
            timestamp: "2026-08-05T12:00:00.000Z".to_string(),
            channel_id: "f0347328-e105-4e62-9af8-807d20e484dd".to_string(),
            request: AgentDraftRequest::Create(AgentDraftCreateRequest {
                display_name: "dev-coder".to_string(),
                system_prompt: "You are a coding specialist.".to_string(),
            }),
        }
    }

    fn sample_update_payload() -> AgentDraftRequestPayload {
        AgentDraftRequestPayload {
            version: 1,
            request_id: "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d".to_string(),
            action: AgentDraftAction::Update,
            timestamp: "2026-08-05T12:10:00.000Z".to_string(),
            channel_id: "f0347328-e105-4e62-9af8-807d20e484dd".to_string(),
            request: AgentDraftRequest::Update(AgentDraftUpdateRequest {
                agent_name: "dev-coder".to_string(),
                display_name: Some("dev-coder-v2".to_string()),
                system_prompt: None,
                runtime: None,
                provider: None,
                model: None,
                respond_to: None,
            }),
        }
    }

    fn sample_resolution_payload() -> AgentDraftResolutionPayload {
        AgentDraftResolutionPayload {
            version: 1,
            request_id: "9f1c2b3a-4d5e-4f6a-8b7c-1d2e3f4a5b6c".to_string(),
            status: AgentDraftResolutionStatus::Accepted,
            timestamp: "2026-08-05T12:05:00.000Z".to_string(),
            agent_pubkey: Some(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_string(),
            ),
            reason: Some("Approved".to_string()),
        }
    }

    fn build_request_event(
        agent_keys: &Keys,
        owner_pubkey: &PublicKey,
        ciphertext: String,
    ) -> Event {
        EventBuilder::new(
            Kind::Custom(crate::kind::KIND_AGENT_DRAFT_REQUEST as u16),
            ciphertext,
        )
        .tags([
            Tag::parse(["p", &owner_pubkey.to_hex()]).unwrap(),
            Tag::parse(["p", &agent_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_keys.public_key().to_hex()]).unwrap(),
        ])
        // The agent's own pubkey is a `p` tag; nostr's EventBuilder discards
        // self-`p`-tags unless self-tagging is allowed.
        .allow_self_tagging()
        .sign_with_keys(agent_keys)
        .expect("sign")
    }

    fn build_resolution_event(
        owner_keys: &Keys,
        agent_pubkey: &PublicKey,
        ciphertext: String,
    ) -> Event {
        EventBuilder::new(
            Kind::Custom(crate::kind::KIND_AGENT_DRAFT_RESOLUTION as u16),
            ciphertext,
        )
        .tags([
            Tag::parse(["p", &owner_keys.public_key().to_hex()]).unwrap(),
            Tag::parse(["p", &agent_pubkey.to_hex()]).unwrap(),
            Tag::parse(["agent", &agent_pubkey.to_hex()]).unwrap(),
            Tag::parse([
                "e",
                "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
            ])
            .unwrap(),
        ])
        // The owner's own pubkey is a `p` tag; nostr's EventBuilder discards
        // self-`p`-tags unless self-tagging is allowed.
        .allow_self_tagging()
        .sign_with_keys(owner_keys)
        .expect("sign")
    }

    #[test]
    fn request_round_trip_encrypt_decrypt() {
        let agent_keys = Keys::generate();
        let owner_keys = Keys::generate();

        let payload = sample_create_payload();
        let ciphertext =
            encrypt_agent_draft_request(&agent_keys, &owner_keys.public_key(), &payload)
                .expect("encrypt");
        let event = build_request_event(&agent_keys, &owner_keys.public_key(), ciphertext);
        let decoded = decrypt_agent_draft_request(&owner_keys, &event).expect("decrypt");
        assert_eq!(decoded, payload);
    }

    #[test]
    fn update_request_round_trip_encrypt_decrypt() {
        let agent_keys = Keys::generate();
        let owner_keys = Keys::generate();

        let payload = sample_update_payload();
        let ciphertext =
            encrypt_agent_draft_request(&agent_keys, &owner_keys.public_key(), &payload)
                .expect("encrypt");
        let event = build_request_event(&agent_keys, &owner_keys.public_key(), ciphertext);
        let decoded = decrypt_agent_draft_request(&owner_keys, &event).expect("decrypt");
        assert_eq!(decoded, payload);
    }

    #[test]
    fn resolution_round_trip_encrypt_decrypt() {
        let owner_keys = Keys::generate();
        let agent_keys = Keys::generate();

        let payload = sample_resolution_payload();
        let ciphertext =
            encrypt_agent_draft_resolution(&owner_keys, &agent_keys.public_key(), &payload)
                .expect("encrypt");
        let event = build_resolution_event(&owner_keys, &agent_keys.public_key(), ciphertext);
        let decoded = decrypt_agent_draft_resolution(&agent_keys, &event).expect("decrypt");
        assert_eq!(decoded, payload);
    }

    #[test]
    fn rejects_unsupported_version() {
        let mut payload = sample_create_payload();
        payload.version = 2;
        assert!(
            matches!(
                payload.validate(),
                Err(ObserverPayloadError::InvalidPayload(_))
            ),
            "version 2 must be rejected (fail closed)"
        );

        let mut resolution = sample_resolution_payload();
        resolution.version = 2;
        assert!(
            matches!(
                resolution.validate(),
                Err(ObserverPayloadError::InvalidPayload(_))
            ),
            "resolution version 2 must be rejected"
        );
    }

    #[test]
    fn rejects_overlong_display_name() {
        let mut payload = sample_create_payload();
        if let AgentDraftRequest::Create(r) = &mut payload.request {
            r.display_name = "x".repeat(AGENT_DRAFT_MAX_DISPLAY_NAME + 1);
        }
        assert!(payload.validate().is_err());
    }

    #[test]
    fn rejects_overlong_system_prompt() {
        let mut payload = sample_create_payload();
        if let AgentDraftRequest::Create(r) = &mut payload.request {
            r.system_prompt = "x".repeat(AGENT_DRAFT_MAX_SYSTEM_PROMPT + 1);
        }
        assert!(payload.validate().is_err());
    }

    #[test]
    fn rejects_overlong_reason() {
        let mut resolution = sample_resolution_payload();
        resolution.reason = Some("x".repeat(AGENT_DRAFT_MAX_REASON + 1));
        assert!(resolution.validate().is_err());
    }

    #[test]
    fn rejects_update_with_no_changed_field() {
        let payload = AgentDraftRequestPayload {
            version: 1,
            request_id: "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d".to_string(),
            action: AgentDraftAction::Update,
            timestamp: "2026-08-05T12:10:00.000Z".to_string(),
            channel_id: "f0347328-e105-4e62-9af8-807d20e484dd".to_string(),
            request: AgentDraftRequest::Update(AgentDraftUpdateRequest {
                agent_name: "dev-coder".to_string(),
                display_name: None,
                system_prompt: None,
                runtime: None,
                provider: None,
                model: None,
                respond_to: None,
            }),
        };
        assert!(
            matches!(
                payload.validate(),
                Err(ObserverPayloadError::InvalidPayload(_))
            ),
            "an update with no changed field must be rejected"
        );
    }

    #[test]
    fn rejects_action_request_mismatch() {
        // action=create but request=update body.
        let payload = AgentDraftRequestPayload {
            version: 1,
            request_id: "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d".to_string(),
            action: AgentDraftAction::Create,
            timestamp: "2026-08-05T12:10:00.000Z".to_string(),
            channel_id: "f0347328-e105-4e62-9af8-807d20e484dd".to_string(),
            request: AgentDraftRequest::Update(AgentDraftUpdateRequest {
                agent_name: "dev-coder".to_string(),
                display_name: Some("x".to_string()),
                system_prompt: None,
                runtime: None,
                provider: None,
                model: None,
                respond_to: None,
            }),
        };
        assert!(payload.validate().is_err());
    }

    #[test]
    fn unknown_fields_are_ignored() {
        // A future payload with extra fields must still parse (forward compat).
        let json = r#"{
            "version": 1,
            "requestId": "9f1c2b3a-4d5e-4f6a-8b7c-1d2e3f4a5b6c",
            "action": "create",
            "timestamp": "2026-08-05T12:00:00.000Z",
            "channelId": "f0347328-e105-4e62-9af8-807d20e484dd",
            "futureField": { "nested": true },
            "request": {
                "displayName": "dev-coder",
                "systemPrompt": "You are a coding specialist.",
                "futurePromptField": "ignored"
            }
        }"#;
        let payload: AgentDraftRequestPayload = serde_json::from_str(json).expect("parse");
        assert_eq!(payload.version, 1);
        assert_eq!(payload.action, AgentDraftAction::Create);
        assert!(payload.validate().is_ok());
    }

    #[test]
    fn update_deserializes_by_agent_name_presence() {
        let json = r#"{
            "version": 1,
            "requestId": "7a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
            "action": "update",
            "timestamp": "2026-08-05T12:10:00.000Z",
            "channelId": "f0347328-e105-4e62-9af8-807d20e484dd",
            "request": {
                "agentName": "dev-coder",
                "displayName": "dev-coder-v2"
            }
        }"#;
        let payload: AgentDraftRequestPayload = serde_json::from_str(json).expect("parse");
        assert_eq!(payload.action, AgentDraftAction::Update);
        assert!(matches!(payload.request, AgentDraftRequest::Update(_)));
        assert!(payload.validate().is_ok());
    }

    #[test]
    fn accepted_resolution_requires_agent_pubkey() {
        let mut resolution = sample_resolution_payload();
        resolution.agent_pubkey = None;
        assert!(
            matches!(
                resolution.validate(),
                Err(ObserverPayloadError::InvalidPayload(_))
            ),
            "accepted resolution without agentPubkey must be rejected"
        );
    }
}
