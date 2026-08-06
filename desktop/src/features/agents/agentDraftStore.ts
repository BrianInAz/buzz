import * as React from "react";

import { relayClient } from "@/shared/api/relayClient";
import { getIdentity } from "@/shared/api/tauriIdentity";
import {
  listPendingAgentDrafts,
  resolveAgentDraft,
  type AgentDraftResolutionStatus,
  type PendingAgentDraft,
} from "@/shared/api/tauriAgentDrafts";
import type { RelayEvent } from "@/shared/api/types";
import { KIND_AGENT_DRAFT_REQUEST } from "@/shared/constants/kinds";

const DRAFT_LIVE_LOOKBACK_SECS = 30;

// Module-level singleton store for durable NIP-AD agent drafts (kinds
// 44300/44301). Replaces the ephemeral kind-24200 observer-frame path: drafts
// are durable, so they replay on the next launch and across devices.
let pendingDrafts: PendingAgentDraft[] = [];
const seenEventIds = new Set<string>();
const listeners = new Set<() => void>();
let unsubscribeLive: (() => Promise<void>) | null = null;
let started = false;
let startPromise: Promise<void> | null = null;

function notify() {
  for (const listener of listeners) {
    listener();
  }
}

async function refresh() {
  try {
    pendingDrafts = await listPendingAgentDrafts();
    notify();
  } catch (error) {
    console.error("Failed to list pending agent drafts", error);
  }
}

/**
 * Ensure the draft store is started: backfill pending drafts from the relay,
 * then subscribe live for new arrivals. Idempotent.
 */
export function ensureAgentDraftStore(): Promise<void> {
  if (started) {
    return startPromise ?? Promise.resolve();
  }
  if (startPromise) {
    return startPromise;
  }
  started = true;
  startPromise = (async () => {
    const identity = await getIdentity();
    const me = identity.pubkey;
    await refresh();
    try {
      unsubscribeLive = await relayClient.subscribeLive(
        {
          kinds: [KIND_AGENT_DRAFT_REQUEST],
          "#p": [me],
          limit: 50,
          since: Math.floor(Date.now() / 1_000) - DRAFT_LIVE_LOOKBACK_SECS,
        },
        (event: RelayEvent) => {
          // Dedupe by request event id; a live arrival just signals that the
          // decrypted list may have changed, so re-fetch.
          if (seenEventIds.has(event.id)) {
            return;
          }
          seenEventIds.add(event.id);
          void refresh();
        },
      );
    } catch (error) {
      console.error("Failed to subscribe to agent drafts", error);
    }
  })();
  return startPromise;
}

/** Resolve a draft (accept/decline/supersede) and refresh the pending list. */
export async function resolveDraft(input: {
  requestEventId: string;
  requestId: string;
  agentPubkey: string;
  status: AgentDraftResolutionStatus;
  agentPubkeySaved?: string;
  reason?: string;
}): Promise<void> {
  await resolveAgentDraft(input);
  await refresh();
}

/** Subscribe to pending-draft changes. Returns an unsubscribe function. */
export function subscribeAgentDrafts(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Read the current pending drafts (non-reactive). */
export function getPendingAgentDrafts(): PendingAgentDraft[] {
  return pendingDrafts;
}

/** Reset the store on community/identity boundary changes. */
export function resetAgentDraftStore() {
  pendingDrafts = [];
  seenEventIds.clear();
  if (unsubscribeLive) {
    void unsubscribeLive().catch(() => {});
    unsubscribeLive = null;
  }
  started = false;
  startPromise = null;
  notify();
}

/** Reactive hook over the pending draft list. */
export function useAgentDrafts(): PendingAgentDraft[] {
  const [drafts, setDrafts] = React.useState<PendingAgentDraft[]>(
    getPendingAgentDrafts(),
  );
  React.useEffect(() => {
    void ensureAgentDraftStore();
    return subscribeAgentDrafts(() => setDrafts(getPendingAgentDrafts()));
  }, []);
  return drafts;
}

/** Selector for the next pending draft to review (newest first). */
export function useNextPendingAgentDraft(): PendingAgentDraft | null {
  const drafts = useAgentDrafts();
  return drafts[0] ?? null;
}
