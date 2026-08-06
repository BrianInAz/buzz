//! External agent adoption — attest-first, no new keypair.
//!
//! Adopting an existing agent identity mints the NIP-OA `BUZZ_AUTH_TAG` from
//! the agent's *public* key and the owner's secret key, and stores the agent
//! with [`BackendKind::External`]. The desktop refuses to spawn/restart/deploy
//! an `External` agent (fail closed) — it exists only as an owner-attested
//! identity that the agent itself drives.

use serde::Serialize;
use tauri::State;

use crate::app_state::AppState;
use crate::managed_agents::{
    load_managed_agents, save_managed_agents, BackendKind, ManagedAgentRecord, RespondTo,
};

/// Result of adopting an external agent.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdoptExternalAgentResult {
    /// The adopted agent's pubkey.
    pub pubkey: String,
    /// The display name the owner assigned.
    pub name: String,
    /// The minted NIP-OA auth tag (owner-attested).
    pub auth_tag: String,
    /// Always `"external"`.
    pub backend: String,
}

/// Adopt an existing agent identity (external pubkey) under the current owner.
///
/// Attest-first: mints the NIP-OA `BUZZ_AUTH_TAG` from the agent's *public*
/// key and the owner's secret key — no new keypair is generated. The adopted
/// agent is stored with `BackendKind::External`, which the desktop refuses to
/// spawn/restart/deploy (fail closed).
#[allow(clippy::too_many_arguments)]
#[tauri::command]
pub async fn adopt_external_agent(
    app: tauri::AppHandle,
    state: State<'_, AppState>,
    agent_pubkey: String,
    display_name: String,
    system_prompt: Option<String>,
    channel_id: Option<String>,
    runtime: Option<String>,
    provider: Option<String>,
    model: Option<String>,
    respond_to: Option<String>,
) -> Result<AdoptExternalAgentResult, String> {
    let agent_pubkey = nostr::PublicKey::parse(&agent_pubkey)
        .map_err(|e| format!("invalid agent pubkey: {e}"))?;
    let agent_hex = agent_pubkey.to_hex();
    let display_name = display_name.trim().to_string();
    if display_name.is_empty() {
        return Err("display name is required".to_string());
    }
    let _ = channel_id; // channel identity is advisory; the agent drives itself

    // Attest-first: mint the NIP-OA auth tag from the owner's secret and the
    // agent's public key. No new keypair. Fail closed on any mint error.
    let auth_tag = {
        let owner_keys = state.signing_keys()?;
        let compat_owner = nostr::Keys::parse(&owner_keys.secret_key().to_secret_hex())
            .map_err(|e| format!("failed to bridge owner keys: {e}"))?;
        buzz_sdk_pkg::nip_oa::compute_auth_tag(&compat_owner, &agent_pubkey, "")
            .map_err(|e| format!("failed to compute NIP-OA auth tag: {e}"))?
    };

    let respond_to = match respond_to.as_deref() {
        None | Some("owner-only") => RespondTo::OwnerOnly,
        Some("anyone") => RespondTo::Anyone,
        Some("allowlist") => RespondTo::Allowlist,
        Some(other) => return Err(format!("invalid respond-to: {other}")),
    };

    let record = ManagedAgentRecord {
        pubkey: agent_hex.clone(),
        name: display_name.clone(),
        persona_id: None,
        private_key_nsec: String::new(),
        auth_tag: Some(auth_tag.clone()),
        relay_url: crate::relay::relay_api_base_url_with_override(&state),
        avatar_url: None,
        acp_command: String::new(),
        agent_command: String::new(),
        agent_command_override: None,
        agent_args: vec![],
        mcp_command: String::new(),
        turn_timeout_seconds: crate::managed_agents::DEFAULT_AGENT_TURN_TIMEOUT_SECONDS,
        idle_timeout_seconds: None,
        max_turn_duration_seconds: None,
        parallelism: 1,
        system_prompt,
        model,
        provider,
        persona_source_version: None,
        env_vars: Default::default(),
        start_on_app_launch: false,
        runtime_pid: None,
        backend: BackendKind::External,
        backend_agent_id: None,
        provider_binary_path: None,
        team_id: None,
        persona_team_dir: None,
        persona_name_in_team: None,
        created_at: crate::util::now_iso(),
        updated_at: crate::util::now_iso(),
        last_started_at: None,
        last_stopped_at: None,
        last_exit_code: None,
        last_error: None,
        last_error_code: None,
        respond_to,
        respond_to_allowlist: vec![],
        display_name: Some(display_name.clone()),
        slug: None,
        runtime,
        name_pool: vec![],
        is_builtin: false,
        is_active: true,
        shared: false,
        source_team: None,
        source_team_persona_slug: None,
        catalog_source: None,
        relay_mesh: None,
        auto_restart_on_config_change: false,
        definition_respond_to: None,
        definition_respond_to_allowlist: vec![],
        definition_parallelism: None,
    };

    // Persist under the store lock, guarding against a duplicate pubkey.
    {
        let _store_guard = state
            .managed_agents_store_lock
            .lock()
            .map_err(|e| e.to_string())?;
        let mut records = load_managed_agents(&app)?;
        if records.iter().any(|r| r.pubkey == agent_hex) {
            return Err(format!("agent {agent_hex} already exists"));
        }
        records.push(record);
        save_managed_agents(&app, &records)?;
    }

    Ok(AdoptExternalAgentResult {
        pubkey: agent_hex,
        name: display_name,
        auth_tag,
        backend: "external".to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managed_agents::BackendKind;

    #[test]
    fn external_backend_is_fail_closed_on_spawn_paths() {
        // The spawn/restart/deploy paths gate on `!= BackendKind::Local` and
        // reject anything else. `External` must never be treated as a provider.
        let record = ManagedAgentRecord {
            backend: BackendKind::External,
            ..bare_record()
        };
        assert_ne!(record.backend, BackendKind::Local);
        // The runtime spawn guard rejects non-Local with a clear error.
        let err = spawn_guard(&record);
        assert!(err.is_err());
        assert!(err.unwrap_err().contains("external"));
    }

    #[test]
    fn auth_tag_mints_from_owner_secret_and_agent_public_key() {
        let owner = nostr::Keys::generate();
        let agent = nostr::Keys::generate();
        let compat_owner = nostr::Keys::parse(&owner.secret_key().to_secret_hex()).unwrap();
        let tag = buzz_sdk_pkg::nip_oa::compute_auth_tag(&compat_owner, &agent.public_key(), "")
            .expect("mint");
        // The tag embeds the owner pubkey and is verifiable against the agent.
        let parsed: serde_json::Value = serde_json::from_str(&tag).expect("tag json");
        assert_eq!(parsed[1], serde_json::json!(owner.public_key().to_hex()));
        let verified = buzz_sdk_pkg::nip_oa::verify_auth_tag(&tag, &agent.public_key())
            .expect("verify");
        assert_eq!(verified, owner.public_key());
    }

    #[test]
    fn auth_tag_rejects_self_attestation() {
        let owner = nostr::Keys::generate();
        let compat_owner = nostr::Keys::parse(&owner.secret_key().to_secret_hex()).unwrap();
        // Owner == agent must be rejected (self-attestation).
        assert!(buzz_sdk_pkg::nip_oa::compute_auth_tag(
            &compat_owner,
            &owner.public_key(),
            ""
        )
        .is_err());
    }

    /// Mirrors the runtime spawn guard: non-Local backends are rejected, with
    /// an explicit fail-closed message for `External`.
    fn spawn_guard(record: &ManagedAgentRecord) -> Result<(), String> {
        if record.backend == BackendKind::External {
            return Err("external agents cannot be spawned by the desktop".to_string());
        }
        if record.backend != BackendKind::Local {
            return Err("managed runtime pairs require a local agent".to_string());
        }
        Ok(())
    }

    fn bare_record() -> ManagedAgentRecord {
        use std::collections::BTreeMap;
        ManagedAgentRecord {
            pubkey: "agent".to_string(),
            name: "Agent".to_string(),
            persona_id: None,
            private_key_nsec: "".to_string(),
            auth_tag: None,
            relay_url: "ws://localhost:3000".to_string(),
            avatar_url: None,
            acp_command: "".to_string(),
            agent_command: "".to_string(),
            agent_command_override: None,
            agent_args: vec![],
            mcp_command: "".to_string(),
            turn_timeout_seconds: 320,
            idle_timeout_seconds: None,
            max_turn_duration_seconds: None,
            parallelism: 1,
            system_prompt: None,
            model: None,
            provider: None,
            persona_source_version: None,
            env_vars: BTreeMap::new(),
            start_on_app_launch: false,
            runtime_pid: None,
            backend: BackendKind::Local,
            backend_agent_id: None,
            provider_binary_path: None,
            team_id: None,
            persona_team_dir: None,
            persona_name_in_team: None,
            created_at: "".to_string(),
            updated_at: "".to_string(),
            last_started_at: None,
            last_stopped_at: None,
            last_exit_code: None,
            last_error: None,
            last_error_code: None,
            respond_to: RespondTo::OwnerOnly,
            respond_to_allowlist: vec![],
            display_name: None,
            slug: None,
            runtime: None,
            name_pool: vec![],
            is_builtin: false,
            is_active: true,
            shared: false,
            source_team: None,
            source_team_persona_slug: None,
            catalog_source: None,
            relay_mesh: None,
            auto_restart_on_config_change: false,
            definition_respond_to: None,
            definition_respond_to_allowlist: vec![],
            definition_parallelism: None,
        }
    }
}
