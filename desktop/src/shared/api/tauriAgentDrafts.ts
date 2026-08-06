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
