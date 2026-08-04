import { expect, test, type Page } from "@playwright/test";

import { waitForAnimations } from "../helpers/animations";
import { installMockBridge } from "../helpers/bridge";

const SHOTS = "test-results/persistent-agent-audience-removable-chips";
const OWNER = "deadbeef".repeat(8);
const CHANNEL_ID = "9a1657ac-f7aa-5db0-b632-d8bbeb6dfb50";
const AGENT_A = "a".repeat(64);
const AGENT_B = "b".repeat(64);
const THREAD_ROOT_ID = "mock-general-welcome";
const SCOPE = `${OWNER}:${CHANNEL_ID}:thread:${THREAD_ROOT_ID}`;
const AUDIENCES_STORAGE_KEY = "buzz:persistent-agent-audiences:v2";

async function seedAudience(page: Page, pubkeys: string[], theme = "buzz") {
  await page.addInitScript(
    ({ audience, scope, selectedTheme }) => {
      window.localStorage.setItem("buzz:keep-addressed-agents-active", "1");
      window.localStorage.setItem(
        "buzz:persistent-agent-audiences:v2",
        JSON.stringify({ [scope]: audience }),
      );
      window.localStorage.setItem("buzz-theme", selectedTheme);
    },
    { audience: pubkeys, scope: SCOPE, selectedTheme: theme },
  );
}

async function openGeneral(page: Page) {
  await page.goto(`/#/channels/${CHANNEL_ID}`, {
    waitUntil: "domcontentloaded",
  });
  await expect(page.getByTestId("chat-title")).toHaveText("general");
}

async function openThread(page: Page, threadRootId = THREAD_ROOT_ID) {
  await page.goto(
    `/#/channels/${CHANNEL_ID}?messageId=${threadRootId}&thread=${threadRootId}`,
    { waitUntil: "domcontentloaded" },
  );
  await expect(page.getByTestId("message-thread-panel")).toBeVisible();
}

async function emitRootMessage(
  page: Page,
  content: string,
  mentionPubkeys: string[],
) {
  const event = await page.evaluate(
    ({ message, pubkeys }) =>
      (
        window as Window & {
          __BUZZ_E2E_EMIT_MOCK_MESSAGE__?: (input: {
            channelName: string;
            content: string;
            mentionPubkeys: string[];
          }) => { id: string };
        }
      ).__BUZZ_E2E_EMIT_MOCK_MESSAGE__?.({
        channelName: "general",
        content: message,
        mentionPubkeys: pubkeys,
      }),
    { message: content, pubkeys: mentionPubkeys },
  );
  if (!event) throw new Error("Mock message emitter is not installed");
  return event;
}

function channelComposer(page: Page) {
  return page.getByTestId("channel-composer-overlay");
}

function threadComposer(page: Page) {
  return page.getByTestId("thread-composer-overlay");
}

async function installAudienceFixtures(
  page: Page,
  options: { sendMessageDelayMs?: number } = {},
) {
  await installMockBridge(page, {
    ...options,
    managedAgents: [
      {
        pubkey: AGENT_A,
        name: "Morgarita",
        status: "running",
        channelNames: ["general"],
      },
      {
        pubkey: AGENT_B,
        name: "Vogue",
        status: "running",
        channelNames: ["general"],
      },
    ],
  });
}

async function readAudience(page: Page, scope = SCOPE) {
  return page.evaluate(
    ({ storageKey, targetScope }) => {
      const payload = JSON.parse(
        window.localStorage.getItem(storageKey) ?? "{}",
      );
      return payload[targetScope] ?? [];
    },
    { storageKey: AUDIENCES_STORAGE_KEY, targetScope: scope },
  );
}

async function readOutgoingMentionPubkeys(page: Page, content: string) {
  return page.evaluate((expectedContent) => {
    const entries =
      (
        window as Window & {
          __BUZZ_E2E_COMMAND_PAYLOADS__?: Array<{
            command: string;
            payload: unknown;
          }>;
        }
      ).__BUZZ_E2E_COMMAND_PAYLOADS__ ?? [];

    for (const entry of entries.toReversed()) {
      if (entry.command !== "send_channel_message") continue;
      const payload = entry.payload as
        | { content?: string; mentionPubkeys?: string[] }
        | undefined;
      if (!payload?.content?.includes(expectedContent)) continue;
      return payload.mentionPubkeys ?? [];
    }

    return null;
  }, content);
}

test("first thread open inherits explicitly addressed agents in authored order", async ({
  page,
}) => {
  await page.addInitScript(() => {
    window.localStorage.setItem("buzz:keep-addressed-agents-active", "1");
  });
  await installAudienceFixtures(page);
  await openGeneral(page);
  const root = await emitRootMessage(
    page,
    "@Vogue please pair with @Morgarita",
    // Event tag order deliberately opposes authored mention order.
    [AGENT_A, AGENT_B],
  );

  await openThread(page, root.id);

  const input = threadComposer(page).getByTestId("message-input");
  await expect(input).toHaveText("@Vogue @Morgarita ");
  await expect(input.locator(".agent-mention-highlight")).toHaveCount(2);
  await expect
    .poll(() =>
      page.evaluate(
        ({ owner, channelId, rootId }) => {
          const stored = JSON.parse(
            localStorage.getItem("buzz:persistent-agent-audiences:v2") ?? "{}",
          );
          return stored[`${owner}:${channelId}:thread:${rootId}`] ?? null;
        },
        { owner: OWNER, channelId: CHANNEL_ID, rootId: root.id },
      ),
    )
    .toEqual([AGENT_B, AGENT_A]);
});

test("persistent agents transition atomically before Enter-send resolves", async ({
  page,
}) => {
  await seedAudience(page, [AGENT_A]);
  await installAudienceFixtures(page, { sendMessageDelayMs: 1_500 });
  await openThread(page);

  const composer = threadComposer(page);
  const input = composer.getByTestId("message-input");
  const send = composer.getByTestId("send-message");
  await input.fill("@Morgarita hello");
  await input.press("Enter");

  // The network send is still pending, so this is the first observable
  // post-submit editor state rather than the later success hydration pass.
  await expect(input).toHaveText("@Morgarita ", { timeout: 500 });
  await expect(input.locator(".agent-mention-highlight")).toHaveCount(1, {
    timeout: 500,
  });
  await expect(input).toBeFocused();
  await page.waitForTimeout(200);
  await expect(composer.getByTestId("mention-autocomplete")).toHaveCount(0);

  await expect(send).toBeEnabled();
  await expect
    .poll(() =>
      input.evaluate((element) => {
        const selection = window.getSelection();
        const viewDesc = (
          element as HTMLElement & {
            pmViewDesc?: {
              posFromDOM: (node: Node, offset: number, bias: number) => number;
              size: number;
            };
          }
        ).pmViewDesc;
        if (!selection?.anchorNode || !viewDesc) return null;
        const position = viewDesc.posFromDOM(
          selection.anchorNode,
          selection.anchorOffset,
          1,
        );
        // The root view desc includes the document's two boundary tokens,
        // while posFromDOM is relative to the editable root. Converting both
        // to ProseMirror coordinates proves selection.from/to === doc.content.size.
        return {
          empty: selection.isCollapsed,
          atDocumentEnd: position + 1 === viewDesc.size - 2,
        };
      }),
    )
    .toEqual({ empty: true, atDocumentEnd: true });
});

test("timeline agent send remains one-shot and returns to the placeholder", async ({
  page,
}) => {
  await seedAudience(page, [AGENT_A]);
  await installAudienceFixtures(page, { sendMessageDelayMs: 1_500 });
  await openGeneral(page);

  const composer = channelComposer(page);
  const input = composer.getByTestId("message-input");
  await input.fill("@Mor");
  await composer
    .getByTestId("mention-autocomplete")
    .getByText("Morgarita", { exact: true })
    .click();
  await input.pressSequentially("hello");
  await expect(input).toHaveText("@Morgarita hello");
  await input.press("Enter");

  await expect(input).toHaveText("", { timeout: 500 });
  await expect(input.locator("[data-placeholder]").first()).toHaveAttribute(
    "data-placeholder",
    "Message #general",
    { timeout: 500 },
  );
  await expect(input).toBeFocused();
  await expect
    .poll(() =>
      input.evaluate((element) => {
        const selection = window.getSelection();
        return {
          collapsed: selection?.isCollapsed ?? false,
          inside: Boolean(
            selection?.anchorNode && element.contains(selection.anchorNode),
          ),
        };
      }),
    )
    .toEqual({ collapsed: true, inside: true });
});

test("persistent agents restore through the native inline mention UI", async ({
  page,
}) => {
  await seedAudience(page, [AGENT_B, AGENT_A]);
  await installAudienceFixtures(page);
  await openThread(page);

  const composer = threadComposer(page);
  const input = composer.getByTestId("message-input");
  await expect(input).toHaveText("@Vogue @Morgarita ");
  await expect(page.getByText("Talking to", { exact: true })).toHaveCount(0);
  await expect(input.locator(".agent-mention-highlight")).toHaveCount(2);

  await input.fill("@Morgarita hello");
  await expect
    .poll(() =>
      page.evaluate(
        ({ scope }) => {
          const stored = JSON.parse(
            localStorage.getItem("buzz:persistent-agent-audiences:v2") ?? "{}",
          );
          return stored[scope] ?? [];
        },
        { scope: SCOPE },
      ),
    )
    .toEqual([AGENT_A]);

  await composer.getByTestId("send-message").click();
  await expect(input).toContainText("@Morgarita");
  await expect(input).not.toContainText("@Vogue");
  await expect(input.locator(".agent-mention-highlight")).toHaveCount(1);
});

for (const theme of ["buzz", "buzz-dark"]) {
  test(`captures native persistent mentions in ${theme}`, async ({ page }) => {
    await seedAudience(page, [AGENT_A, AGENT_B], theme);
    await installAudienceFixtures(page);
    await openThread(page);
    const overlay = threadComposer(page);
    const composer = overlay.getByTestId("message-composer");
    await overlay.getByTestId("message-input").focus();
    await waitForAnimations(page);
    await composer.screenshot({
      path: `${SHOTS}/${theme}-native-mentions.png`,
    });
  });
}

test("persistent audience renders removable agent chips above the composer", async ({
  page,
}) => {
  await seedAudience(page, [AGENT_A, AGENT_B]);
  await installAudienceFixtures(page);
  await openThread(page);
  const composer = threadComposer(page);
  await waitForAnimations(page);

  const chips = composer.getByTestId("composer-audience-chips");
  await expect(chips).toBeVisible();
  await expect(chips.getByText("Morgarita")).toBeVisible();
  await expect(chips.getByText("Vogue")).toBeVisible();
  await expect(
    chips.getByRole("button", { name: /remove morgarita/i }),
  ).toBeVisible();
  await expect(
    chips.getByRole("button", { name: /remove vogue/i }),
  ).toBeVisible();
});

test("removing an audience chip updates draft mentions and persisted audience", async ({
  page,
}) => {
  await seedAudience(page, [AGENT_A, AGENT_B]);
  await installAudienceFixtures(page);
  await openThread(page);

  const composer = threadComposer(page);
  const input = composer.getByTestId("message-input");
  await expect(input).toHaveText("@Morgarita @Vogue ");

  await composer
    .getByTestId("composer-audience-chips")
    .getByRole("button", { name: /remove morgarita/i })
    .click();

  await expect(input).toHaveText("@Vogue ");
  await expect.poll(() => readAudience(page)).toEqual([AGENT_B]);
});

test("manual audience exclusions can be re-added with @agent selection", async ({
  page,
}) => {
  await seedAudience(page, [AGENT_A, AGENT_B]);
  await installAudienceFixtures(page);
  await openThread(page);

  const composer = threadComposer(page);
  const input = composer.getByTestId("message-input");
  await expect(input).toHaveText("@Morgarita @Vogue ");

  await composer
    .getByTestId("composer-audience-chips")
    .getByRole("button", { name: /remove morgarita/i })
    .click();
  await expect(input).toHaveText("@Vogue ");

  await input.focus();
  await input.pressSequentially("@Morg");
  await expect.poll(() => readAudience(page)).toEqual([AGENT_B]);
  const morgaritaSuggestion = composer
    .getByTestId("mention-autocomplete")
    .getByText("Morgarita", { exact: true });
  await expect(morgaritaSuggestion).toBeVisible();
  await morgaritaSuggestion.click();
  await expect(input).toContainText("@Morgarita");
  await expect(input).toContainText("@Vogue");
  await expect.poll(() => readAudience(page)).toEqual([AGENT_B]);
  await input.pressSequentially("hello");
  await composer.getByTestId("send-message").click();
  await expect
    .poll(() => readOutgoingMentionPubkeys(page, "hello"))
    .toEqual([AGENT_B, AGENT_A]);
  await expect.poll(() => readAudience(page)).toEqual([AGENT_A, AGENT_B]);
});

test("persistent removals stay removed across composer scope transitions", async ({
  page,
}) => {
  await seedAudience(page, [AGENT_A, AGENT_B]);
  await installAudienceFixtures(page);
  await openThread(page);

  const threadComposerRoot = threadComposer(page);
  const threadInput = threadComposerRoot.getByTestId("message-input");
  await expect(threadInput).toHaveText("@Morgarita @Vogue ");

  await threadComposerRoot
    .getByTestId("composer-audience-chips")
    .getByRole("button", { name: /remove morgarita/i })
    .click();
  await expect(threadInput).toHaveText("@Vogue ");

  await openGeneral(page);
  await expect(channelComposer(page).getByTestId("message-input")).toHaveText(
    "",
  );

  await openThread(page);
  await expect(threadComposer(page).getByTestId("message-input")).toHaveText(
    "@Vogue ",
  );
  await expect(
    threadComposer(page)
      .getByTestId("composer-audience-chips")
      .getByText("Morgarita"),
  ).toHaveCount(0);
});

test("removed persistent audience fits the narrow composer", async ({
  page,
}) => {
  await page.setViewportSize({ width: 700, height: 760 });
  await seedAudience(page, [AGENT_A, AGENT_B]);
  await installAudienceFixtures(page);
  await openThread(page);
  const overlay = threadComposer(page);
  const composer = overlay.getByTestId("message-composer");
  await expect(overlay.getByTestId("message-input")).toContainText(
    "@Morgarita",
  );
  await overlay
    .getByTestId("composer-audience-chips")
    .getByRole("button", { name: /remove morgarita/i })
    .click();
  await expect(overlay.getByTestId("message-input")).toHaveText("@Vogue ");
  await waitForAnimations(page);
  await composer.screenshot({
    path: `${SHOTS}/narrow-removed-audience-chip.png`,
  });
});
