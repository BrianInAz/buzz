import * as React from "react";
import { useQueryClient } from "@tanstack/react-query";

import {
  createInputFromRequest,
  pendingDraftToRequest,
  requestTargetsEditablePersona,
  type AgentManagementRequest,
} from "./agentManagement";
import { resolveDraft, useNextPendingAgentDraft } from "./agentDraftStore";
import { classifyAgentDraftOrigin } from "./agentDraftTrust";
import {
  adoptExternalAgent,
  importExternalAgentKey,
} from "@/shared/api/tauriAgentDrafts";
import { useIdentityQuery } from "@/shared/api/hooks";
import { useUsersBatchQuery } from "@/features/profile/hooks";
import {
  managedAgentsQueryKey,
  personasQueryKey,
  useAcpRuntimesQuery,
  useCreateManagedAgentMutation,
  useCreatePersonaMutation,
  usePersonasQuery,
  useUpdatePersonaMutation,
} from "./hooks";
import {
  availableRuntimesForStart,
  buildInstanceInputForDefinition,
  type BackendIntent,
} from "./lib/instanceInputForDefinition";
import { useCreatedAgentChannelAttachment } from "./useCreatedAgentChannelAttachment";
import { useChannelsQuery } from "@/features/channels/hooks";
import { resolveManagedAgentAvatarUrl } from "./ui/managedAgentAvatar";
import type { AgentCreateIntent } from "./ui/agentCreateIntent";
import { editPersonaDialogState } from "./ui/personaDialogState";
import type {
  CreatePersonaInput,
  UpdatePersonaInput,
} from "@/shared/api/types";

function updateInputFromRequest(
  request: Extract<AgentManagementRequest, { action: "update" }>,
  current: UpdatePersonaInput,
): UpdatePersonaInput {
  const changes = request.request;
  return {
    ...current,
    displayName: changes.displayName ?? current.displayName,
    systemPrompt: changes.systemPrompt ?? current.systemPrompt,
    runtime: changes.runtime ?? current.runtime,
    provider: changes.provider ?? current.provider,
    model: changes.model ?? current.model,
    ...(changes.respondTo
      ? {
          behavior: {
            respondTo: changes.respondTo,
            respondToAllowlist: [],
            parallelism: current.behavior?.parallelism,
          },
        }
      : {}),
  };
}

export function useAgentManagement() {
  const queryClient = useQueryClient();
  const identityQuery = useIdentityQuery();
  const currentPubkey = identityQuery.data?.pubkey;
  const personasQuery = usePersonasQuery();
  const channelsQuery = useChannelsQuery();
  const runtimesQuery = useAcpRuntimesQuery({ enabled: true });
  const createPersonaMutation = useCreatePersonaMutation();
  const updatePersonaMutation = useUpdatePersonaMutation();
  const createAgentMutation = useCreateManagedAgentMutation();
  const [error, setError] = React.useState<string | null>(null);
  const [adoptedAuthTag, setAdoptedAuthTag] = React.useState<string | null>(
    null,
  );
  const createdAgentAttachment = useCreatedAgentChannelAttachment();
  // In-session guard: a draft is resolved durably via its 44301 event, so this
  // set only prevents double-publishing within this session.
  const resolvedRequestIds = React.useRef(new Set<string>());

  const nextDraft = useNextPendingAgentDraft();
  const request = nextDraft ? pendingDraftToRequest(nextDraft) : null;
  const agentPubkey = nextDraft?.agentPubkey;

  // Resolve the requesting agent's kind:0 profile for declared NIP-OA
  // ownership (defence-in-depth; the relay already enforced is_agent_owner).
  const usersBatch = useUsersBatchQuery(agentPubkey ? [agentPubkey] : [], {
    enabled: Boolean(agentPubkey),
  });
  const profiles = usersBatch.data?.profiles;

  const origin = React.useMemo(() => {
    if (!request || !agentPubkey || !currentPubkey) {
      return "buffer";
    }
    return classifyAgentDraftOrigin(
      profiles,
      channelsQuery.data,
      agentPubkey,
      request.channelId,
      currentPubkey,
    );
  }, [request, agentPubkey, currentPubkey, profiles, channelsQuery.data]);

  // Only surface the dialog for an accepted draft.
  const visibleRequest = origin === "accept" ? request : null;

  const matchingPersonas = React.useMemo(() => {
    if (visibleRequest?.action !== "update") return [];
    const target = visibleRequest.request.agentName.trim().toLocaleLowerCase();
    return (personasQuery.data ?? []).filter(
      (persona) =>
        persona.displayName.trim().toLocaleLowerCase() === target &&
        requestTargetsEditablePersona(persona),
    );
  }, [personasQuery.data, visibleRequest]);
  const currentPersona =
    matchingPersonas.length === 1 ? matchingPersonas[0] : undefined;

  const isPending =
    createPersonaMutation.isPending ||
    updatePersonaMutation.isPending ||
    createAgentMutation.isPending;

  function assertAgentCanActFromOrigin(channelId: string) {
    const targetChannel = (channelsQuery.data ?? []).find(
      (channel) => channel.id === channelId,
    );
    const requestingPubkey = agentPubkey?.toLowerCase();
    if (
      !targetChannel?.isMember ||
      !requestingPubkey ||
      !targetChannel.memberPubkeys.some(
        (pubkey) => pubkey.toLowerCase() === requestingPubkey,
      )
    ) {
      throw new Error(
        "An agent can only manage agents from a channel you both belong to.",
      );
    }
  }

  async function publishResolution(
    status: "accepted" | "declined",
    agentPubkeySaved?: string,
  ) {
    if (!nextDraft) {
      return;
    }
    if (resolvedRequestIds.current.has(nextDraft.requestId)) {
      return;
    }
    resolvedRequestIds.current.add(nextDraft.requestId);
    await resolveDraft({
      requestEventId: nextDraft.requestEventId,
      requestId: nextDraft.requestId,
      agentPubkey: nextDraft.agentPubkey,
      status,
      agentPubkeySaved,
    });
  }

  async function submitCreate(
    input: CreatePersonaInput | UpdatePersonaInput,
    intent: AgentCreateIntent,
    backendIntent: BackendIntent | null,
  ): Promise<boolean> {
    if (visibleRequest?.action !== "create" || "id" in input) {
      return false;
    }
    setError(null);
    try {
      assertAgentCanActFromOrigin(visibleRequest.channelId);
      const runtimes = await availableRuntimesForStart(runtimesQuery);
      const runtime = runtimes.find(
        (candidate) => candidate.id === input.runtime,
      );
      if (!runtime) {
        throw new Error("Choose an available runtime for this agent.");
      }

      const avatarUrl = await resolveManagedAgentAvatarUrl(
        input.avatarUrl,
        undefined,
        runtime.avatarUrl,
      );
      const persona = await createPersonaMutation.mutateAsync({
        ...input,
        avatarUrl,
      });

      if (intent === "definition_start") {
        const created = await createAgentMutation.mutateAsync(
          await buildInstanceInputForDefinition(
            persona,
            runtime,
            undefined,
            backendIntent ?? undefined,
          ),
        );
        if (created.spawnError) throw new Error(created.spawnError);
        const targetChannel = (channelsQuery.data ?? []).find(
          (channel) => channel.id === visibleRequest.channelId,
        );
        await createdAgentAttachment.presentCreatedAgent(created, {
          id: visibleRequest.channelId,
          name: targetChannel?.name ?? "this channel",
        });
      }

      await publishResolution("accepted", agentPubkey);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: personasQueryKey }),
        queryClient.invalidateQueries({ queryKey: managedAgentsQueryKey }),
      ]);
      return true;
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : "Could not save this agent.",
      );
      return false;
    }
  }

  async function submitUpdate(input: CreatePersonaInput | UpdatePersonaInput) {
    if (visibleRequest?.action !== "update" || !("id" in input)) {
      return false;
    }
    setError(null);
    try {
      assertAgentCanActFromOrigin(visibleRequest.channelId);
      await updatePersonaMutation.mutateAsync(input);
      await publishResolution("accepted", agentPubkey);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: personasQueryKey }),
        queryClient.invalidateQueries({ queryKey: managedAgentsQueryKey }),
      ]);
      return true;
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : "Could not save this agent.",
      );
      return false;
    }
  }

  function dismiss() {
    // Closing the dialog without accepting declines the draft durably.
    void publishResolution("declined");
  }

  /** Adopt the requesting agent's existing identity (no new keypair). */
  async function adopt(): Promise<boolean> {
    if (!nextDraft || nextDraft.action !== "create") {
      return false;
    }
    setError(null);
    try {
      assertAgentCanActFromOrigin(nextDraft.channelId);
      const result = await adoptExternalAgent({
        agentPubkey: nextDraft.agentPubkey,
        displayName: nextDraft.displayName ?? "",
        systemPrompt: nextDraft.systemPrompt,
        channelId: nextDraft.channelId,
        runtime: nextDraft.runtime,
        provider: nextDraft.provider,
        model: nextDraft.model,
        respondTo: nextDraft.respondTo,
      });
      setAdoptedAuthTag(result.authTag);
      await publishResolution("accepted", nextDraft.agentPubkey);
      await queryClient.invalidateQueries({
        queryKey: managedAgentsQueryKey,
      });
      return true;
    } catch (cause) {
      setError(
        cause instanceof Error ? cause.message : "Could not adopt this agent.",
      );
      return false;
    }
  }

  /** Import the agent's private key so the desktop can run it locally. */
  async function importKey(nsec: string): Promise<boolean> {
    if (!nextDraft || nextDraft.action !== "create") {
      return false;
    }
    setError(null);
    try {
      assertAgentCanActFromOrigin(nextDraft.channelId);
      const result = await importExternalAgentKey({
        agentPubkey: nextDraft.agentPubkey,
        nsec,
        displayName: nextDraft.displayName ?? "",
      });
      setAdoptedAuthTag(result.authTag);
      await publishResolution("accepted", nextDraft.agentPubkey);
      await queryClient.invalidateQueries({
        queryKey: managedAgentsQueryKey,
      });
      return true;
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "Could not import this agent key.",
      );
      return false;
    }
  }

  const createInitialValues = React.useMemo(
    () =>
      visibleRequest?.action === "create"
        ? createInputFromRequest(visibleRequest)
        : null,
    [visibleRequest],
  );

  const editInitialValues = React.useMemo(() => {
    if (visibleRequest?.action !== "update" || !currentPersona) return null;
    return updateInputFromRequest(
      visibleRequest,
      editPersonaDialogState(currentPersona)
        .initialValues as UpdatePersonaInput,
    );
  }, [currentPersona, visibleRequest]);

  const editError = React.useMemo(() => {
    if (visibleRequest?.action !== "update") return error;
    if (error) return error;
    if (matchingPersonas.length > 1) {
      return "More than one personal agent has that name. Rename it in Agents, then ask the agent again.";
    }
    if (!currentPersona) {
      return "Agents can only update a personal agent profile by its current name.";
    }
    return null;
  }, [currentPersona, error, matchingPersonas.length, visibleRequest]);

  return {
    request: visibleRequest,
    nextDraft,
    createInitialValues,
    editInitialValues,
    editError,
    error,
    adoptedAuthTag,
    ...createdAgentAttachment,
    isPending,
    runtimes: runtimesQuery.data ?? [],
    runtimeCatalogStatus: runtimesQuery.isLoading
      ? ("loading" as const)
      : runtimesQuery.isError
        ? ("error" as const)
        : ("ready" as const),
    submitCreate,
    submitUpdate,
    adopt,
    importKey,
    dismiss,
  };
}
