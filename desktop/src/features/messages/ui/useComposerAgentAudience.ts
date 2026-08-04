import * as React from "react";

import { useUnaddressedChannelAgentMode } from "@/features/channels/lib/unaddressedChannelAgentMode";
import {
  describeComposerAudienceHint,
  resolveComposerSendAudience,
  type ComposerSendAudienceResult,
} from "@/features/messages/lib/composerSendAudience";
import { getPersistentAgentAudienceScope } from "@/features/messages/lib/persistentAgentAudience";
import type { UseMentionsResult } from "@/features/messages/lib/useMentions";
import type { UseRichTextEditorResult } from "@/features/messages/lib/useRichTextEditor";
import type { ChannelType } from "@/shared/api/types";
import { normalizePubkey, truncatePubkey } from "@/shared/lib/pubkey";

import type { ComposerAudienceChip } from "./ComposerAudienceChips";
import {
  resolvePersistentMentionTargets,
  type usePersistentAgentMentionHydration,
} from "./usePersistentAgentMentionHydration";

type PersistentHydration = ReturnType<
  typeof usePersistentAgentMentionHydration
>;

export function useComposerAgentAudience({
  audienceThreadRootId,
  channelType,
  composerScope,
  editTarget,
  mentions,
  ownerPubkey,
  persistentMentionHydration,
  richText,
}: {
  audienceThreadRootId: string | null;
  channelType: ChannelType | null;
  composerScope: string | null | undefined;
  editTarget: unknown;
  mentions: UseMentionsResult;
  ownerPubkey: string | null | undefined;
  persistentMentionHydration: PersistentHydration;
  richText: UseRichTextEditorResult;
}): {
  audienceChips: readonly ComposerAudienceChip[];
  composerAudienceHint: string | null;
  audienceGeneration: number;
  audienceRevision: number;
  resolveComposerAudience: (input: {
    explicitMentionPubkeys: string[];
    explicitAgentPubkeys: string[];
    messagePosition: "top-level" | "in-thread";
    threadRootEventId: string | null;
  }) => ComposerSendAudienceResult;
  onSuccessfulExplicitAgentAudience:
    | ((audience: {
        channelId: string;
        expectedGeneration: number;
        expectedRevision: number | null;
        explicitAgentPubkeys: string[];
      }) => void)
    | undefined;
  removeAudienceMember: (pubkey: string) => void;
  resolvePostSendContent: PersistentHydration["resolvePostSendContent"];
} {
  const persistentAudience = persistentMentionHydration.audience;
  const {
    enabled: persistentAudienceEnabled,
    generation: audienceGeneration,
    pubkeys: persistentAudiencePubkeys,
    promotePubkeys,
    removePubkey,
    revision: audienceRevision,
  } = persistentAudience;
  const { removeMentionToken, resolvePostSendContent } =
    persistentMentionHydration;
  const {
    extractMentionPubkeys,
    getMentionDisplayName,
    hasResolvedMembers,
    isAgentPubkey,
    memberPubkeys,
  } = mentions;
  const { getPlainTextAndCursor } = richText;
  const [manualRemovedPubkeys, setManualRemovedPubkeys] = React.useState<
    readonly string[]
  >([]);
  const { mode: unaddressedMode } = useUnaddressedChannelAgentMode();
  const conversationKind = channelType === "dm" ? "direct" : "channel";

  React.useEffect(() => {
    void composerScope;
    setManualRemovedPubkeys([]);
  }, [composerScope]);

  const channelMemberPubkeyList = React.useMemo(
    () => [...memberPubkeys],
    [memberPubkeys],
  );
  const verifiedChannelAgentPubkeys = React.useMemo(
    () => channelMemberPubkeyList.filter((pk) => isAgentPubkey(pk)),
    [channelMemberPubkeyList, isAgentPubkey],
  );
  const currentAgentPubkey = React.useMemo(() => {
    if (conversationKind !== "direct") return null;
    const agents = verifiedChannelAgentPubkeys.filter(
      (pk) => pk !== normalizePubkey(ownerPubkey ?? ""),
    );
    return agents[0] ?? null;
  }, [conversationKind, ownerPubkey, verifiedChannelAgentPubkeys]);

  const resolveComposerAudience = React.useCallback(
    ({
      explicitMentionPubkeys,
      explicitAgentPubkeys,
      messagePosition,
      threadRootEventId,
    }: {
      explicitMentionPubkeys: string[];
      explicitAgentPubkeys: string[];
      messagePosition: "top-level" | "in-thread";
      threadRootEventId: string | null;
    }) =>
      resolveComposerSendAudience({
        conversation: conversationKind,
        messagePosition,
        unaddressedMode,
        keepAddressedAgentsActive: persistentAudienceEnabled,
        explicitMentionPubkeys,
        explicitAgentPubkeys,
        currentAgentPubkey,
        channelMemberPubkeys: channelMemberPubkeyList,
        verifiedChannelAgentPubkeys,
        persistentThreadAudience: [...persistentAudiencePubkeys],
        manualRemovedPubkeys,
        threadRootEventId,
        recipientLoadError:
          !hasResolvedMembers && conversationKind === "channel",
      }),
    [
      channelMemberPubkeyList,
      conversationKind,
      currentAgentPubkey,
      hasResolvedMembers,
      persistentAudienceEnabled,
      persistentAudiencePubkeys,
      manualRemovedPubkeys,
      unaddressedMode,
      verifiedChannelAgentPubkeys,
    ],
  );

  const currentAudience = React.useMemo(() => {
    if (editTarget != null || conversationKind === "direct") return null;
    const text = getPlainTextAndCursor().text;
    const explicitMentionPubkeys = extractMentionPubkeys(text);
    const explicitAgentPubkeys = explicitMentionPubkeys.filter((pk) =>
      isAgentPubkey(pk),
    );
    const decision = resolveComposerAudience({
      explicitMentionPubkeys,
      explicitAgentPubkeys,
      messagePosition: audienceThreadRootId ? "in-thread" : "top-level",
      threadRootEventId: audienceThreadRootId,
    });
    return { decision, explicitAgentPubkeys };
  }, [
    audienceThreadRootId,
    conversationKind,
    editTarget,
    extractMentionPubkeys,
    isAgentPubkey,
    resolveComposerAudience,
    getPlainTextAndCursor,
  ]);

  const composerAudienceHint = React.useMemo(() => {
    if (!currentAudience?.decision.retainDraft) return null;
    return describeComposerAudienceHint({
      conversation: conversationKind,
      unaddressedMode,
      explicitAgentCount: currentAudience.explicitAgentPubkeys.length,
      implicitAgentCount:
        currentAudience.explicitAgentPubkeys.length > 0
          ? 0
          : currentAudience.decision.agentAudiencePubkeys.length,
      retainDraft: currentAudience.decision.retainDraft,
    });
  }, [conversationKind, currentAudience, unaddressedMode]);

  const audienceChips = React.useMemo(
    () =>
      resolvePersistentMentionTargets(
        currentAudience?.decision.agentAudiencePubkeys ?? [],
        (pubkey) => getMentionDisplayName(pubkey) ?? truncatePubkey(pubkey),
      ),
    [currentAudience, getMentionDisplayName],
  );

  const removeAudienceMember = React.useCallback(
    (pubkey: string) => {
      const normalizedPubkey = normalizePubkey(pubkey);
      setManualRemovedPubkeys((current) =>
        current.includes(normalizedPubkey)
          ? current
          : [...current, normalizedPubkey],
      );
      removeMentionToken(normalizedPubkey);
      removePubkey(normalizedPubkey);
    },
    [removeMentionToken, removePubkey],
  );

  const promoteExplicitAgentAudience = React.useCallback(
    ({
      channelId: successfulChannelId,
      ...promotion
    }: {
      channelId: string;
      expectedGeneration: number;
      expectedRevision: number | null;
      explicitAgentPubkeys: string[];
    }) => {
      const readdedPubkeys = new Set(
        promotion.explicitAgentPubkeys.map(normalizePubkey),
      );
      setManualRemovedPubkeys((current) =>
        current.filter((pubkey) => !readdedPubkeys.has(pubkey)),
      );
      const scope = getPersistentAgentAudienceScope({
        ownerPubkey: ownerPubkey ?? "",
        channelId: successfulChannelId,
        threadRootId: audienceThreadRootId,
      });
      promotePubkeys({ ...promotion, scope });
    },
    [audienceThreadRootId, ownerPubkey, promotePubkeys],
  );
  const onSuccessfulExplicitAgentAudience =
    persistentAudienceEnabled && ownerPubkey
      ? promoteExplicitAgentAudience
      : undefined;

  return {
    audienceChips,
    composerAudienceHint,
    audienceGeneration,
    audienceRevision,
    resolveComposerAudience,
    onSuccessfulExplicitAgentAudience,
    removeAudienceMember,
    resolvePostSendContent,
  };
}
