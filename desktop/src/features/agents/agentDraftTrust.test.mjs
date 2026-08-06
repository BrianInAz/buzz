import assert from "node:assert/strict";
import test from "node:test";

import { classifyAgentDraftOrigin } from "./agentDraftTrust.ts";

const OWNER =
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const AGENT =
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const OTHER =
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
const CHANNEL = "7c07e659-3610-42f4-9a5e-1e9973c09da9";

function profiles(ownerPubkey) {
  return { [AGENT]: { ownerPubkey } };
}

function channels(agentIsMember = true) {
  return [
    {
      id: CHANNEL,
      isMember: true,
      memberPubkeys: agentIsMember ? [AGENT] : [],
    },
  ];
}

test("buffers while profiles or channels are undefined", () => {
  assert.equal(
    classifyAgentDraftOrigin(undefined, channels(), AGENT, CHANNEL, OWNER),
    "buffer",
  );
  assert.equal(
    classifyAgentDraftOrigin(profiles(OWNER), undefined, AGENT, CHANNEL, OWNER),
    "buffer",
  );
});

test("accepts when the agent declares this owner and shares the channel", () => {
  assert.equal(
    classifyAgentDraftOrigin(
      profiles(OWNER),
      channels(true),
      AGENT,
      CHANNEL,
      OWNER,
    ),
    "accept",
  );
});

test("rejects when the agent declares a different owner", () => {
  assert.equal(
    classifyAgentDraftOrigin(
      profiles(OTHER),
      channels(true),
      AGENT,
      CHANNEL,
      OWNER,
    ),
    "reject",
  );
});

test("rejects when the agent has no declared owner", () => {
  assert.equal(
    classifyAgentDraftOrigin(
      profiles(null),
      channels(true),
      AGENT,
      CHANNEL,
      OWNER,
    ),
    "reject",
  );
});

test("rejects when the agent is not a member of the claimed channel", () => {
  assert.equal(
    classifyAgentDraftOrigin(
      profiles(OWNER),
      channels(false),
      AGENT,
      CHANNEL,
      OWNER,
    ),
    "reject",
  );
});

test("rejects when the owner is not a member of the claimed channel", () => {
  assert.equal(
    classifyAgentDraftOrigin(
      profiles(OWNER),
      [{ id: CHANNEL, isMember: false, memberPubkeys: [AGENT] }],
      AGENT,
      CHANNEL,
      OWNER,
    ),
    "reject",
  );
});
