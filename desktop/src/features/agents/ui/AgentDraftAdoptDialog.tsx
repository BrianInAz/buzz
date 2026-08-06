import { useState } from "react";

import type { PendingAgentDraft } from "@/shared/api/tauriAgentDrafts";
import { Button } from "@/shared/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/shared/ui/dialog";
import { CopyButton } from "./CopyButton";

/**
 * Review surface for a durable NIP-AD create draft. The primary action adopts
 * the requesting agent's existing identity (no new keypair); a secondary,
 * separately-confirmed action imports its private key so the desktop can run
 * it locally. After a successful adopt, the minted `BUZZ_AUTH_TAG` is shown
 * with a copy affordance.
 */
export function AgentDraftAdoptDialog({
  draft,
  error,
  isPending,
  adoptedAuthTag,
  onAdopt,
  onImportKey,
  onOpenChange,
}: {
  draft: PendingAgentDraft | null;
  error: string | null;
  isPending: boolean;
  adoptedAuthTag: string | null;
  onAdopt: () => Promise<boolean>;
  onImportKey: (nsec: string) => Promise<boolean>;
  onOpenChange: (open: boolean) => void;
}) {
  const [importing, setImporting] = useState(false);
  const [nsec, setNsec] = useState("");

  const handleImport = async () => {
    setImporting(true);
    try {
      await onImportKey(nsec.trim());
    } finally {
      setImporting(false);
    }
  };

  return (
    <Dialog onOpenChange={onOpenChange} open>
      <DialogContent className="max-w-2xl overflow-hidden p-0">
        <div className="flex max-h-[85vh] flex-col">
          <DialogHeader className="border-b border-border/60 px-6 py-5 pr-14">
            <DialogTitle>Adopt this agent</DialogTitle>
            <DialogDescription>
              {draft?.displayName ?? "An agent"} is asking to be registered as
              yours. Adopting it attests that you own it — no new key is
              created.
            </DialogDescription>
          </DialogHeader>

          <div className="flex-1 space-y-4 overflow-y-auto px-6 py-5">
            {draft ? (
              <div className="rounded-2xl border border-border/70 bg-muted/20 p-4">
                <p className="text-sm font-semibold tracking-tight">
                  {draft.displayName ?? "Unnamed agent"}
                </p>
                {draft.systemPrompt ? (
                  <p className="mt-1 text-sm text-muted-foreground">
                    {draft.systemPrompt}
                  </p>
                ) : null}
                <code className="mt-3 block break-all rounded-xl border border-border/70 bg-background/80 px-3 py-2 text-xs">
                  {draft.agentPubkey}
                </code>
              </div>
            ) : null}

            {adoptedAuthTag ? (
              <div className="rounded-2xl border border-primary/20 bg-primary/10 p-4">
                <div className="flex items-center justify-between gap-3">
                  <div>
                    <p className="text-sm font-semibold tracking-tight">
                      BUZZ_AUTH_TAG
                    </p>
                    <p className="text-sm text-muted-foreground">
                      Add this to the agent&apos;s environment where it runs.
                    </p>
                  </div>
                  <CopyButton label="Copy tag" value={adoptedAuthTag} />
                </div>
                <code className="mt-3 block break-all rounded-xl border border-border/70 bg-background/80 px-3 py-2 text-xs">
                  {adoptedAuthTag}
                </code>
              </div>
            ) : null}

            {error ? (
              <p
                className="rounded-2xl border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-destructive"
                role="alert"
              >
                {error}
              </p>
            ) : null}

            {importing ? (
              <div className="space-y-3 rounded-2xl border border-border/70 bg-muted/20 p-4">
                <p className="text-sm font-semibold tracking-tight">
                  Import key to run from this Desktop
                </p>
                <p className="text-sm text-muted-foreground">
                  Paste the agent&apos;s private key (nsec). This lets Buzz run
                  the agent locally on this machine.
                </p>
                <input
                  className="w-full rounded-xl border border-border/70 bg-background/80 px-3 py-2 text-sm"
                  onChange={(event) => setNsec(event.target.value)}
                  placeholder="nsec1…"
                  type="password"
                  value={nsec}
                />
                <div className="flex justify-end gap-2">
                  <Button
                    onClick={() => setImporting(false)}
                    size="sm"
                    type="button"
                    variant="outline"
                  >
                    Cancel
                  </Button>
                  <Button
                    disabled={nsec.trim().length === 0 || isPending}
                    onClick={() => void handleImport()}
                    size="sm"
                    type="button"
                  >
                    {isPending ? "Importing…" : "Import key"}
                  </Button>
                </div>
              </div>
            ) : null}
          </div>

          <div className="flex flex-wrap justify-end gap-2 border-t border-border/60 px-6 py-4">
            {!adoptedAuthTag ? (
              <>
                <Button
                  disabled={isPending}
                  onClick={() => setImporting(true)}
                  size="sm"
                  type="button"
                  variant="outline"
                >
                  Import key to run from this Desktop
                </Button>
                <Button
                  disabled={isPending}
                  onClick={() => void onAdopt()}
                  size="sm"
                  type="button"
                >
                  {isPending ? "Adopting…" : "Adopt this identity"}
                </Button>
              </>
            ) : (
              <Button
                onClick={() => onOpenChange(false)}
                size="sm"
                type="button"
                variant="outline"
              >
                Done
              </Button>
            )}
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
