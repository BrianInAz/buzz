import type {
  AgentPersona,
  CreatePersonaInput,
  RespondToMode,
} from "@/shared/api/types";
import type { PendingAgentDraft } from "@/shared/api/tauriAgentDrafts";

export const AGENT_DRAFT_VERSION = 1 as const;

export type AgentManagementCreateRequest = {
  version: typeof AGENT_DRAFT_VERSION;
  action: "create";
  requestId: string;
  channelId: string;
  request: {
    displayName: string;
    systemPrompt: string;
  };
};

export type AgentManagementUpdateRequest = {
  version: typeof AGENT_DRAFT_VERSION;
  action: "update";
  requestId: string;
  channelId: string;
  request: {
    agentName: string;
    displayName?: string;
    systemPrompt?: string;
    runtime?: string;
    provider?: string;
    model?: string;
    respondTo?: RespondToMode;
  };
};

export type AgentManagementRequest =
  | AgentManagementCreateRequest
  | AgentManagementUpdateRequest;

function isText(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isRespondTo(value: unknown): value is RespondToMode | undefined {
  return value === undefined || value === "owner-only" || value === "anyone";
}

function hasOnlyKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
) {
  return Object.keys(value).every((key) => allowed.includes(key));
}

/**
 * Parses the deliberately narrow no-secret NIP-AD agent-draft contract
 * (`AgentDraftRequestPayload`). `version` MUST be 1 (fail closed on any other
 * value); unknown fields are ignored; the strict `hasOnlyKeys` allowlists are
 * load-bearing and must not be loosened.
 */
export function parseAgentManagementRequest(
  value: unknown,
): AgentManagementRequest | null {
  if (typeof value !== "object" || value === null) return null;
  const payload = value as Record<string, unknown>;
  if (
    payload.version !== AGENT_DRAFT_VERSION ||
    !isText(payload.requestId) ||
    (payload.action !== "create" && payload.action !== "update") ||
    !isText(payload.channelId) ||
    typeof payload.request !== "object" ||
    payload.request === null
  ) {
    return null;
  }
  const request = payload.request as Record<string, unknown>;

  if (payload.action === "create") {
    if (!hasOnlyKeys(request, ["displayName", "systemPrompt"])) {
      return null;
    }
    if (!isText(request.displayName) || !isText(request.systemPrompt)) {
      return null;
    }
    return {
      version: AGENT_DRAFT_VERSION,
      action: "create",
      requestId: payload.requestId,
      channelId: payload.channelId,
      request: {
        displayName: request.displayName,
        systemPrompt: request.systemPrompt,
      },
    };
  }

  if (
    !isRespondTo(request.respondTo) ||
    !hasOnlyKeys(request, [
      "agentName",
      "displayName",
      "systemPrompt",
      "runtime",
      "provider",
      "model",
      "respondTo",
    ]) ||
    !isText(request.agentName)
  ) {
    return null;
  }
  const changes = {
    ...(isText(request.displayName)
      ? { displayName: request.displayName }
      : {}),
    ...(isText(request.systemPrompt)
      ? { systemPrompt: request.systemPrompt }
      : {}),
    ...(isText(request.runtime) ? { runtime: request.runtime } : {}),
    ...(isText(request.provider) ? { provider: request.provider } : {}),
    ...(isText(request.model) ? { model: request.model } : {}),
    ...(request.respondTo ? { respondTo: request.respondTo } : {}),
  };
  if (Object.keys(changes).length === 0) return null;
  return {
    version: AGENT_DRAFT_VERSION,
    action: "update",
    requestId: payload.requestId,
    channelId: payload.channelId,
    request: {
      agentName: request.agentName,
      ...changes,
    },
  };
}

export function requestTargetsEditablePersona(
  persona: AgentPersona | undefined,
): persona is AgentPersona {
  return Boolean(persona && !persona.sourceTeam);
}

/**
 * Convert a decrypted, flattened `PendingAgentDraft` (from the durable NIP-AD
 * store) into the nested `AgentManagementRequest` shape the review dialog
 * consumes. Returns `null` when the draft is structurally incomplete.
 */
export function pendingDraftToRequest(
  draft: PendingAgentDraft,
): AgentManagementRequest | null {
  if (draft.action === "create") {
    if (!draft.displayName || !draft.systemPrompt) {
      return null;
    }
    return {
      version: AGENT_DRAFT_VERSION,
      action: "create",
      requestId: draft.requestId,
      channelId: draft.channelId,
      request: {
        displayName: draft.displayName,
        systemPrompt: draft.systemPrompt,
      },
    };
  }
  if (!draft.agentName) {
    return null;
  }
  const changes: Record<string, string> = {};
  if (draft.displayName) changes.displayName = draft.displayName;
  if (draft.systemPrompt) changes.systemPrompt = draft.systemPrompt;
  if (draft.runtime) changes.runtime = draft.runtime;
  if (draft.provider) changes.provider = draft.provider;
  if (draft.model) changes.model = draft.model;
  if (draft.respondTo) changes.respondTo = draft.respondTo;
  if (Object.keys(changes).length === 0) {
    return null;
  }
  return {
    version: AGENT_DRAFT_VERSION,
    action: "update",
    requestId: draft.requestId,
    channelId: draft.channelId,
    request: { agentName: draft.agentName, ...changes },
  };
}

export function createInputFromRequest(
  request: Extract<AgentManagementRequest, { action: "create" }>,
): CreatePersonaInput {
  return {
    displayName: request.request.displayName,
    systemPrompt: request.request.systemPrompt,
  };
}
