import { useAgentManagement } from "@/features/agents/useAgentManagement";
import { AgentCardDialogs } from "./AgentCardViewerDialog";
import { AgentDialog } from "./AgentDialog";
import { AgentDraftAdoptDialog } from "./AgentDraftAdoptDialog";
import { SecretRevealDialog } from "./SecretRevealDialog";

/** Global review surfaces opened by owned agents through the Buzz harness. */
export function AgentManagementDialogs() {
  const management = useAgentManagement();

  return (
    <>
      {management.request?.action === "create" &&
      management.nextDraft?.action === "create" ? (
        <AgentDraftAdoptDialog
          adoptedAuthTag={management.adoptedAuthTag}
          draft={management.nextDraft}
          error={management.error}
          isPending={management.isPending}
          onAdopt={management.adopt}
          onImportKey={management.importKey}
          onOpenChange={(open) => {
            if (!open) management.dismiss();
          }}
        />
      ) : null}
      {management.createdAgent ? (
        <SecretRevealDialog
          attachmentFailure={management.attachmentFailure}
          created={management.createdAgent}
          isRetryingAttachment={management.isRetryingAttachment}
          onOpenChange={(open) => {
            if (!open) management.dismissCreatedAgent();
          }}
          onRetryAttachment={() => {
            void management.retryAttachment();
          }}
        />
      ) : null}
      {management.request?.action === "update" ? (
        <AgentDialog
          description=""
          error={management.editError ? new Error(management.editError) : null}
          initialValues={management.editInitialValues}
          isPending={management.isPending}
          mode="definition-edit"
          onOpenChange={(open) => {
            if (!open) management.dismiss();
          }}
          onSubmit={management.submitUpdate}
          open
          runtimes={management.runtimes}
          runtimesLoading={management.runtimesLoading}
          submitLabel="Save changes"
          title="Edit agent"
        />
      ) : null}
      <AgentCardDialogs />
    </>
  );
}
