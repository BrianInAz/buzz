import assert from "node:assert/strict";
import test from "node:test";

import {
  describeComposerAudienceHint,
  resolveComposerSendAudience,
} from "./composerSendAudience.ts";

const human = "1".repeat(64);
const agentA = "a".repeat(64);
const agentB = "b".repeat(64);

test("channel multi-agent unaddressed merges all verified agents into mentions", () => {
  const result = resolveComposerSendAudience({
    conversation: "channel",
    messagePosition: "top-level",
    unaddressedMode: "all-channel-agents",
    keepAddressedAgentsActive: false,
    explicitMentionPubkeys: [],
    explicitAgentPubkeys: [],
    currentAgentPubkey: null,
    channelMemberPubkeys: [human, agentA, agentB],
    verifiedChannelAgentPubkeys: [agentA, agentB],
    persistentThreadAudience: [],
  });
  assert.deepEqual([...result.mentionPubkeys].sort(), [agentA, agentB].sort());
  assert.equal(result.sharedThread, true);
  assert.equal(result.replyPlacement.kind, "top-level"); // no humanMessageEventId
});

test("explicit agent mention overrides implicit all-agents", () => {
  const result = resolveComposerSendAudience({
    conversation: "channel",
    messagePosition: "top-level",
    unaddressedMode: "all-channel-agents",
    keepAddressedAgentsActive: false,
    explicitMentionPubkeys: [agentB, human],
    explicitAgentPubkeys: [agentB],
    currentAgentPubkey: null,
    channelMemberPubkeys: [human, agentA, agentB],
    verifiedChannelAgentPubkeys: [agentA, agentB],
    persistentThreadAudience: [],
  });
  assert.deepEqual([...result.mentionPubkeys].sort(), [agentB, human].sort());
  assert.deepEqual(result.agentAudiencePubkeys, [agentB]);
});

test("mentions-only with no explicit agents yields empty agent audience", () => {
  const result = resolveComposerSendAudience({
    conversation: "channel",
    messagePosition: "top-level",
    unaddressedMode: "mentions-only",
    keepAddressedAgentsActive: false,
    explicitMentionPubkeys: [human],
    explicitAgentPubkeys: [],
    currentAgentPubkey: null,
    channelMemberPubkeys: [human, agentA],
    verifiedChannelAgentPubkeys: [agentA],
    persistentThreadAudience: [],
  });
  assert.deepEqual(result.agentAudiencePubkeys, []);
  assert.deepEqual(result.mentionPubkeys, [human]);
});

test("describeComposerAudienceHint covers modes", () => {
  assert.match(
    describeComposerAudienceHint({
      conversation: "channel",
      unaddressedMode: "all-channel-agents",
      explicitAgentCount: 0,
      implicitAgentCount: 3,
      retainDraft: false,
    }) ?? "",
    /all 3 channel agents/,
  );
  assert.match(
    describeComposerAudienceHint({
      conversation: "channel",
      unaddressedMode: "mentions-only",
      explicitAgentCount: 0,
      implicitAgentCount: 0,
      retainDraft: false,
    }) ?? "",
    /Mentions only/,
  );
  assert.equal(
    describeComposerAudienceHint({
      conversation: "direct",
      unaddressedMode: "all-channel-agents",
      explicitAgentCount: 0,
      implicitAgentCount: 1,
      retainDraft: false,
    }),
    null,
  );
});
