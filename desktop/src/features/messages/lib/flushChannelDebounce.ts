import { detectPrefixQuery } from "@/shared/lib/detectPrefixQuery";

type ChannelCandidate = {
  name: string;
};

export type FlushChannelDebounceResult<T extends ChannelCandidate> =
  | { type: "match"; suggestion: T; startIndex: number }
  | { type: "no-match" }
  | { type: "inactive" };

/**
 * Resolve a pending channel query from the latest editor state instead of the
 * suggestion list produced by the previous debounce. This closes the window
 * where Enter or Tab can otherwise commit a stale channel.
 */
export function flushChannelDebounce<T extends ChannelCandidate>(opts: {
  channels: readonly T[];
  debounceTimerRef: React.MutableRefObject<ReturnType<
    typeof setTimeout
  > | null>;
  knownNamesLowerRef: React.RefObject<string[]>;
  latestCursorRef: React.RefObject<number>;
  latestValueRef: React.RefObject<string>;
}): FlushChannelDebounceResult<T> {
  if (opts.debounceTimerRef.current !== null) {
    clearTimeout(opts.debounceTimerRef.current);
  }
  opts.debounceTimerRef.current = null;

  const channel = detectPrefixQuery(
    "#",
    opts.latestValueRef.current,
    opts.latestCursorRef.current,
    opts.knownNamesLowerRef.current,
  );
  if (!channel) {
    return { type: "inactive" };
  }

  const lowerQuery = channel.query.toLowerCase();
  const suggestion = opts.channels.find((candidate) =>
    candidate.name.toLowerCase().includes(lowerQuery),
  );
  if (!suggestion) {
    return { type: "no-match" };
  }

  return {
    type: "match",
    suggestion,
    startIndex: channel.startIndex,
  };
}
