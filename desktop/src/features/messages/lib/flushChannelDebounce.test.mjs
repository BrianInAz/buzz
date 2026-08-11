import assert from "node:assert/strict";
import test from "node:test";

import { flushChannelDebounce } from "./flushChannelDebounce.ts";

function ref(current) {
  return { current };
}

function suggestion(name, overrides = {}) {
  return {
    id: name,
    name,
    channelType: "stream",
    ...overrides,
  };
}

function flushOptions({
  channels = [suggestion("general"), suggestion("random")],
  cursor,
  timer = setTimeout(() => {}, 1_000),
  value,
}) {
  return {
    channels,
    debounceTimerRef: ref(timer),
    knownNamesLowerRef: ref(
      channels.map((channel) => channel.name.toLowerCase()),
    ),
    latestCursorRef: ref(cursor ?? value.length),
    latestValueRef: ref(value),
  };
}

test("flushChannelDebounce returns inactive when the latest editor text is empty", () => {
  const options = flushOptions({ value: "" });

  const flushed = flushChannelDebounce(options);

  assert.deepEqual(flushed, { type: "inactive" });
  assert.equal(options.debounceTimerRef.current, null);
});

test("flushChannelDebounce resolves a changed query from the latest editor state", () => {
  const options = flushOptions({ value: "Open #ran" });

  const flushed = flushChannelDebounce(options);

  assert.equal(flushed.type, "match");
  assert.equal(flushed.suggestion.name, "random");
  assert.equal(flushed.startIndex, 5);
});

test("flushChannelDebounce returns no-match for an active query with no fresh suggestion", () => {
  const flushed = flushChannelDebounce(
    flushOptions({ value: "Open #does-not-exist" }),
  );

  assert.deepEqual(flushed, { type: "no-match" });
});

test("flushChannelDebounce returns the fresh replacement offset", () => {
  const value = "See #general, then #gen";

  const flushed = flushChannelDebounce(flushOptions({ value }));

  assert.equal(flushed.type, "match");
  assert.equal(flushed.suggestion.name, "general");
  assert.equal(flushed.startIndex, value.lastIndexOf("#"));
});

test("flushChannelDebounce cancels the pending timer", async () => {
  let fired = false;
  const options = flushOptions({
    timer: setTimeout(() => {
      fired = true;
    }, 10),
    value: "#gen",
  });

  flushChannelDebounce(options);
  await new Promise((resolve) => setTimeout(resolve, 25));

  assert.equal(options.debounceTimerRef.current, null);
  assert.equal(fired, false);
});
