import type { Channel, UserProfileSummary } from "@/shared/api/types";

export type AgentDraftOrigin = "buffer" | "accept" | "reject";

/**
 * Decide whether a durable NIP-AD draft may open for review.
 *
 * Accept requires BOTH:
 *   1. The requesting agent's kind:0 profile declares this owner via NIP-OA
 *      (`profiles[agentPubkey].ownerPubkey === currentPubkey`), resolved
 *      through `useUsersBatchQuery` — NOT membership of the local managed-agent
 *      list. This is the fix for B4: a brand-new identity that has never been
 *      locally managed can still be adopted.
 *   2. The claimed `channelId` resolves to a channel where the owner is a
 *      member AND the requesting agent is in `memberPubkeys` (preserved from
 *      the old `assertAgentCanActFromOrigin` rule).
 *
 * Returns `"buffer"` only while `profiles` or `channels` is still `undefined`.
 *
 * The relay has already enforced `is_agent_owner` before it would store or
 * serve the event, so this is defence-in-depth, not the only gate.
 */
export function classifyAgentDraftOrigin(
  profiles: Record<string, UserProfileSummary> | undefined,
  channels:
    | readonly Pick<Channel, "id" | "isMember" | "memberPubkeys">[]
    | undefined,
  agentPubkey: string,
  channelId: string,
  currentPubkey: string,
): AgentDraftOrigin {
  if (profiles === undefined || channels === undefined) {
    return "buffer";
  }
  const normalizedAgentPubkey = agentPubkey.toLowerCase();
  const normalizedCurrentPubkey = currentPubkey.toLowerCase();

  const profile = profiles[normalizedAgentPubkey];
  if (
    !profile ||
    profile.ownerPubkey?.toLowerCase() !== normalizedCurrentPubkey
  ) {
    return "reject";
  }

  const originChannel = channels.find((channel) => channel.id === channelId);
  if (
    originChannel?.isMember !== true ||
    !originChannel.memberPubkeys.some(
      (pubkey) => pubkey.toLowerCase() === normalizedAgentPubkey,
    )
  ) {
    return "reject";
  }
  return "accept";
}
