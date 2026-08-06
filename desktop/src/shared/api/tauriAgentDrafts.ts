import { invokeTauri } from "./tauri";

/** A pending NIP-AD agent draft surfaced to the owner for review. */
export type PendingAgentDraft = {
  requestEventId: string;
  requestId: string;
  action: "create" | "update";
  channelId: string;
  agentPubkey: string;
  createdAt: number;
  displayName?: string;
  systemPrompt?: string;
  agentName?: string;
  runtime?: string;
  provider?: string;
  model?: string;
  respondTo?: string;
};

export type AgentDraftResolutionStatus = "accepted" | "declined" | "superseded";

export type ResolveAgentDraftResult = {
  eventId: string;
  accepted: boolean;
  message: string;
};

/** List pending (unresolved) agent drafts addressed to the current owner. */
export async function listPendingAgentDrafts(): Promise<PendingAgentDraft[]> {
  return invokeTauri<PendingAgentDraft[]>("list_pending_agent_drafts");
}

/** Resolve an agent draft by publishing a kind 44301 resolution. */
export async function resolveAgentDraft(input: {
  requestEventId: string;
  requestId: string;
  agentPubkey: string;
  status: AgentDraftResolutionStatus;
  agentPubkeySaved?: string;
  reason?: string;
}): Promise<ResolveAgentDraftResult> {
  const response = await invokeTauri<{
    event_id: string;
    accepted: boolean;
    message: string;
  }>("resolve_agent_draft", {
    requestEventId: input.requestEventId,
    requestId: input.requestId,
    agentPubkey: input.agentPubkey,
    status: input.status,
    agentPubkeySaved: input.agentPubkeySaved,
    reason: input.reason,
  });
  return {
    eventId: response.event_id,
    accepted: response.accepted,
    message: response.message,
  };
}

export type AdoptExternalAgentResult = {
  pubkey: string;
  name: string;
  authTag: string;
  backend: string;
};

/**
 * Adopt an existing agent identity under the current owner. Attest-first:
 * mints the NIP-OA `BUZZ_AUTH_TAG` from the agent's public key and the owner's
 * secret — no new keypair is generated.
 */
export async function adoptExternalAgent(input: {
  agentPubkey: string;
  displayName: string;
  systemPrompt?: string;
  channelId?: string;
  runtime?: string;
  provider?: string;
  model?: string;
  respondTo?: string;
}): Promise<AdoptExternalAgentResult> {
  const response = await invokeTauri<{
    pubkey: string;
    name: string;
    auth_tag: string;
    backend: string;
  }>("adopt_external_agent", {
    agentPubkey: input.agentPubkey,
    displayName: input.displayName,
    systemPrompt: input.systemPrompt,
    channelId: input.channelId,
    runtime: input.runtime,
    provider: input.provider,
    model: input.model,
    respondTo: input.respondTo,
  });
  return {
    pubkey: response.pubkey,
    name: response.name,
    authTag: response.auth_tag,
    backend: response.backend,
  };
}

/**
 * Import an existing agent's private key so the desktop can run it locally.
 * The `nsec` must match `agentPubkey`.
 */
export async function importExternalAgentKey(input: {
  agentPubkey: string;
  nsec: string;
  displayName: string;
}): Promise<AdoptExternalAgentResult> {
  const response = await invokeTauri<{
    pubkey: string;
    name: string;
    auth_tag: string;
    backend: string;
  }>("import_external_agent_key", {
    agentPubkey: input.agentPubkey,
    nsec: input.nsec,
    displayName: input.displayName,
  });
  return {
    pubkey: response.pubkey,
    name: response.name,
    authTag: response.auth_tag,
    backend: response.backend,
  };
}
