import { expect, test } from "@playwright/test";

import { installMockBridge, TEST_IDENTITIES } from "../helpers/bridge";

const AGENT = TEST_IDENTITIES.charlie;
// A mock DM channel where charlie and the owner are both members, so the
// draft-origin trust gate (declared NIP-OA ownership + shared channel) passes.
const CHANNEL = "d1ec7000-d000-4000-8000-000000000003";

test("draft arrives → review dialog opens; adopt shows auth tag", async ({
  page,
}) => {
  await installMockBridge(page, {
    managedAgents: [
      {
        pubkey: AGENT.pubkey,
        name: "dev-coder",
        channelIds: [CHANNEL],
      },
    ],
    pendingAgentDrafts: [
      {
        requestId: "draft-adopt-1",
        action: "create",
        channelId: CHANNEL,
        agentPubkey: AGENT.pubkey,
        displayName: "dev-coder",
        systemPrompt: "You are a coding specialist.",
      },
    ],
  });
  await page.goto("/");

  // The durable backfill surfaces the pending draft and opens the review dialog.
  await expect(
    page.getByRole("dialog", { name: "Adopt this agent" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Adopt this identity" }),
  ).toBeVisible();

  // Adopt → the minted BUZZ_AUTH_TAG is shown with a copy affordance.
  await page.getByRole("button", { name: "Adopt this identity" }).click();
  await expect(page.getByText("BUZZ_AUTH_TAG")).toBeVisible();
  await expect(page.getByRole("button", { name: "Copy tag" })).toBeVisible();
});

test("decline publishes a resolution and the draft does not reappear after reload", async ({
  page,
}) => {
  await installMockBridge(page, {
    managedAgents: [
      {
        pubkey: AGENT.pubkey,
        name: "dev-coder",
        channelIds: [CHANNEL],
      },
    ],
    pendingAgentDrafts: [
      {
        requestId: "draft-decline-1",
        action: "create",
        channelId: CHANNEL,
        agentPubkey: AGENT.pubkey,
        displayName: "dev-coder",
        systemPrompt: "You are a coding specialist.",
      },
    ],
  });
  await page.goto("/");

  await expect(
    page.getByRole("dialog", { name: "Adopt this agent" }),
  ).toBeVisible();

  // Close the dialog (decline) — publishes a 44301 resolution.
  await page.keyboard.press("Escape");
  await expect(
    page.getByRole("dialog", { name: "Adopt this agent" }),
  ).not.toBeVisible();

  // Reload — the durable resolution means the draft must not resurface.
  await page.reload();
  await expect(
    page.getByRole("dialog", { name: "Adopt this agent" }),
  ).not.toBeVisible();
});
