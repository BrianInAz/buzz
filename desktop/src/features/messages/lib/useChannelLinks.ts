import * as React from "react";

import { useChannelNavigation } from "@/shared/context/ChannelNavigationContext";
import { detectPrefixQuery } from "@/shared/lib/detectPrefixQuery";
import { flushChannelDebounce } from "./flushChannelDebounce";
import type { AutocompleteEdit } from "./useRichTextEditor";

export type ChannelSuggestion = {
  id: string;
  name: string;
  channelType: "stream" | "forum";
};

const CHANNEL_QUERY_DEBOUNCE_MS = 120;

export function useChannelLinks() {
  const { channels } = useChannelNavigation();

  const [channelQuery, setChannelQuery] = React.useState<string | null>(null);
  const [channelStartIndex, setChannelStartIndex] = React.useState(0);
  const [channelSelectedIndex, setChannelSelectedIndex] = React.useState(0);

  const debounceTimerRef = React.useRef<ReturnType<typeof setTimeout> | null>(
    null,
  );
  const latestValueRef = React.useRef<string>("");
  const latestCursorRef = React.useRef<number>(0);
  const flushedChannelStartIndexRef = React.useRef<number | null>(null);

  const channelCandidates = React.useMemo<ChannelSuggestion[]>(
    () =>
      channels
        .filter((channel) => channel.channelType !== "dm")
        .map((channel) => ({
          id: channel.id,
          name: channel.name,
          channelType: channel.channelType as "stream" | "forum",
        })),
    [channels],
  );

  /** Channel names (original casing) for overlay highlighting. */
  const knownChannelNames = React.useMemo<string[]>(
    () => channelCandidates.map((channel) => channel.name),
    [channelCandidates],
  );

  /** Lower-cased channel names for case-insensitive prefix matching. */
  const knownNamesLower = React.useMemo<string[]>(
    () => knownChannelNames.map((n) => n.toLowerCase()),
    [knownChannelNames],
  );

  const knownNamesLowerRef = React.useRef<string[]>(knownNamesLower);

  // Keep the known-names ref in sync so the debounced callback never reads stale data.
  React.useEffect(() => {
    knownNamesLowerRef.current = knownNamesLower;
  }, [knownNamesLower]);

  React.useEffect(() => {
    return () => {
      if (debounceTimerRef.current !== null) {
        clearTimeout(debounceTimerRef.current);
      }
    };
  }, []);

  const channelSuggestions = React.useMemo<ChannelSuggestion[]>(() => {
    if (channelQuery === null) {
      return [];
    }

    const lowerQuery = channelQuery.toLowerCase();
    return channelCandidates
      .filter((channel) => channel.name.toLowerCase().includes(lowerQuery))
      .slice(0, 8);
  }, [channelCandidates, channelQuery]);

  const isChannelOpen = channelQuery !== null && channelSuggestions.length > 0;

  const insertChannel = React.useCallback(
    (suggestion: ChannelSuggestion, selectionEnd: number): AutocompleteEdit => {
      if (debounceTimerRef.current !== null) {
        clearTimeout(debounceTimerRef.current);
        debounceTimerRef.current = null;
      }

      const insertText = `#${suggestion.name} `;

      setChannelQuery(null);
      setChannelSelectedIndex(0);

      const startIndex =
        flushedChannelStartIndexRef.current ?? channelStartIndex;
      flushedChannelStartIndexRef.current = null;
      return {
        replaceFromOffset: startIndex,
        replaceToOffset: selectionEnd,
        insertText,
      };
    },
    [channelStartIndex],
  );

  const updateChannelQuery = React.useCallback(
    (value: string, cursorPosition: number) => {
      // Store latest values so the debounced callback always uses fresh data
      latestValueRef.current = value;
      latestCursorRef.current = cursorPosition;

      if (debounceTimerRef.current !== null) {
        clearTimeout(debounceTimerRef.current);
      }

      debounceTimerRef.current = setTimeout(() => {
        debounceTimerRef.current = null;
        const channel = detectPrefixQuery(
          "#",
          latestValueRef.current,
          latestCursorRef.current,
          knownNamesLowerRef.current,
        );
        if (channel) {
          setChannelQuery(channel.query);
          setChannelStartIndex(channel.startIndex);
          setChannelSelectedIndex(0);
        } else {
          setChannelQuery(null);
        }
      }, CHANNEL_QUERY_DEBOUNCE_MS);
    },
    [],
  );

  const clearChannels = React.useCallback(() => {
    if (debounceTimerRef.current !== null) {
      clearTimeout(debounceTimerRef.current);
      debounceTimerRef.current = null;
    }
    flushedChannelStartIndexRef.current = null;
    setChannelQuery(null);
    setChannelSelectedIndex(0);
  }, []);

  const handleChannelKeyDown = React.useCallback(
    (
      event: React.KeyboardEvent,
    ):
      | { handled: false }
      | {
          handled: true;
          suggestion?: ChannelSuggestion;
          submit?: true;
        } => {
      if (
        event.key === "Escape" &&
        (isChannelOpen || debounceTimerRef.current !== null)
      ) {
        event.preventDefault();
        clearChannels();
        return { handled: true };
      }

      if (!isChannelOpen) {
        return { handled: false };
      }

      if (event.key === "ArrowDown") {
        event.preventDefault();
        setChannelSelectedIndex((current) =>
          current < channelSuggestions.length - 1 ? current + 1 : 0,
        );
        return { handled: true };
      }

      if (event.key === "ArrowUp") {
        event.preventDefault();
        setChannelSelectedIndex((current) =>
          current > 0 ? current - 1 : channelSuggestions.length - 1,
        );
        return { handled: true };
      }

      const isPlainEnter =
        event.key === "Enter" &&
        !event.ctrlKey &&
        !event.metaKey &&
        !event.altKey &&
        !event.shiftKey;
      if (event.key === "Tab" || isPlainEnter) {
        if (debounceTimerRef.current !== null) {
          const flushed = flushChannelDebounce({
            channels: channelCandidates,
            debounceTimerRef,
            knownNamesLowerRef,
            latestCursorRef,
            latestValueRef,
          });
          if (flushed.type === "match") {
            event.preventDefault();
            flushedChannelStartIndexRef.current = flushed.startIndex;
            setChannelQuery(null);
            return { handled: true, suggestion: flushed.suggestion };
          }
          if (flushed.type === "no-match") {
            event.preventDefault();
            clearChannels();
            return { handled: true };
          }

          clearChannels();
          if (isPlainEnter) {
            event.preventDefault();
            return { handled: true, submit: true };
          }
          return { handled: false };
        }

        event.preventDefault();
        return {
          handled: true,
          suggestion: channelSuggestions[channelSelectedIndex],
        };
      }

      return { handled: false };
    },
    [
      channelCandidates,
      channelSelectedIndex,
      channelSuggestions,
      clearChannels,
      isChannelOpen,
    ],
  );

  return {
    channelQuery,
    channelSelectedIndex,
    channelSuggestions,
    clearChannels,
    handleChannelKeyDown,
    insertChannel,
    isChannelOpen,
    knownChannelNames,
    updateChannelQuery,
  };
}

export type UseChannelLinksResult = ReturnType<typeof useChannelLinks>;
