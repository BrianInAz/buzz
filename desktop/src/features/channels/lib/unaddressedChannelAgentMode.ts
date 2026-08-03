/**
 * Device-local setting: how unaddressed channel messages reach agents.
 *
 * Label: "Unaddressed channel messages"
 * - Notify all channel agents  → "all-channel-agents" (default)
 * - Mentions only              → "mentions-only"
 *
 * Semantic storage key is versioned; not community/relay policy.
 */

import type { UnaddressedChannelAgentMode } from "./contextualAgentConversationPolicy.ts";

/** Versioned device-local storage key (do not change without a migration). */
export const UNADDRESSED_CHANNEL_AGENT_MODE_STORAGE_KEY =
  "buzz:unaddressed-channel-agent-mode:v1";

export const DEFAULT_UNADDRESSED_CHANNEL_AGENT_MODE: UnaddressedChannelAgentMode =
  "all-channel-agents";

export function parseUnaddressedChannelAgentMode(
  value: string | null | undefined,
): UnaddressedChannelAgentMode {
  return value === "mentions-only" || value === "all-channel-agents"
    ? value
    : DEFAULT_UNADDRESSED_CHANNEL_AGENT_MODE;
}

export function readUnaddressedChannelAgentMode(
  storage: Pick<Storage, "getItem"> | null | undefined = globalThis.localStorage,
): UnaddressedChannelAgentMode {
  try {
    return parseUnaddressedChannelAgentMode(storage?.getItem(UNADDRESSED_CHANNEL_AGENT_MODE_STORAGE_KEY));
  } catch {
    return DEFAULT_UNADDRESSED_CHANNEL_AGENT_MODE;
  }
}

export function writeUnaddressedChannelAgentMode(
  mode: UnaddressedChannelAgentMode,
  storage: Pick<Storage, "setItem"> | null | undefined = globalThis.localStorage,
): void {
  try {
    storage?.setItem(UNADDRESSED_CHANNEL_AGENT_MODE_STORAGE_KEY, mode);
  } catch {
    // Best-effort persistence.
  }
}
