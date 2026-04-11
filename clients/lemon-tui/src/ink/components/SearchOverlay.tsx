/**
 * SearchOverlay — live-filtering message search with highlighted matches.
 */

import React, { useState, useMemo } from 'react';
import { Box, Text, useInput } from 'ink';
import { OverlayContainer } from './OverlayContainer.js';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { formatRelativeTime } from '../utils/format.js';
import type { NormalizedMessage } from '../../state.js';

interface SearchOverlayProps {
  initialQuery?: string;
  onClose: () => void;
}

interface SearchResult {
  message: NormalizedMessage;
  preview: string;
  matchIndex: number;
}

function getMessageText(msg: NormalizedMessage): string {
  switch (msg.type) {
    case 'user':
      return msg.content;
    case 'assistant':
      return msg.textContent;
    case 'tool_result':
      return `[${msg.toolName}] ${msg.content}`;
  }
}

function getMessageLabel(msg: NormalizedMessage): { label: string; colorKey: string } {
  switch (msg.type) {
    case 'user':
      return { label: 'You', colorKey: 'primary' };
    case 'assistant':
      return { label: 'Assistant', colorKey: 'success' };
    case 'tool_result':
      return { label: msg.toolName, colorKey: 'secondary' };
  }
}

function highlightMatch(text: string, query: string, accentColor: string): React.ReactNode[] {
  if (!query) return [<Text key={0}>{text}</Text>];

  const nodes: React.ReactNode[] = [];
  const lowerText = text.toLowerCase();
  const lowerQuery = query.toLowerCase();
  let lastIndex = 0;
  let key = 0;
  let idx = lowerText.indexOf(lowerQuery);

  while (idx !== -1) {
    if (idx > lastIndex) {
      nodes.push(<Text key={key++}>{text.slice(lastIndex, idx)}</Text>);
    }
    nodes.push(
      <Text key={key++} bold color={accentColor}>
        {text.slice(idx, idx + query.length)}
      </Text>
    );
    lastIndex = idx + query.length;
    idx = lowerText.indexOf(lowerQuery, lastIndex);
  }

  if (lastIndex < text.length) {
    nodes.push(<Text key={key}>{text.slice(lastIndex)}</Text>);
  }

  return nodes;
}

const MAX_RESULTS = 20;
const PREVIEW_CONTEXT = 60;

export function SearchOverlay({ initialQuery = '', onClose }: SearchOverlayProps) {
  const theme = useTheme();
  const messages = useAppSelector((s) => s.messages);
  const [query, setQuery] = useState(initialQuery);
  const [selectedIndex, setSelectedIndex] = useState(0);

  const results = useMemo((): SearchResult[] => {
    if (!query.trim()) return [];

    const lowerQuery = query.toLowerCase();
    const found: SearchResult[] = [];

    for (let i = messages.length - 1; i >= 0 && found.length < MAX_RESULTS; i--) {
      const msg = messages[i];
      const text = getMessageText(msg);
      const matchIndex = text.toLowerCase().indexOf(lowerQuery);

      if (matchIndex !== -1) {
        // Extract preview around match
        const start = Math.max(0, matchIndex - PREVIEW_CONTEXT);
        const end = Math.min(text.length, matchIndex + query.length + PREVIEW_CONTEXT);
        let preview = text.slice(start, end).replace(/\n/g, ' ');
        if (start > 0) preview = '...' + preview;
        if (end < text.length) preview = preview + '...';

        found.push({ message: msg, preview, matchIndex });
      }
    }

    return found;
  }, [query, messages]);

  useInput((input, key) => {
    if (key.escape) {
      onClose();
      return;
    }

    if (key.return) {
      onClose();
      return;
    }

    if (key.upArrow) {
      setSelectedIndex((i) => Math.max(0, i - 1));
      return;
    }

    if (key.downArrow) {
      setSelectedIndex((i) => Math.min(results.length - 1, i + 1));
      return;
    }

    if (key.backspace || key.delete) {
      setQuery((q) => q.slice(0, -1));
      setSelectedIndex(0);
      return;
    }

    if (input && !key.ctrl && !key.meta) {
      setQuery((q) => q + input);
      setSelectedIndex(0);
    }
  });

  return (
    <OverlayContainer title="Search Messages">
      <Box marginBottom={1}>
        <Text color={theme.primary}>{'> '}</Text>
        <Text>{query}</Text>
        <Text inverse> </Text>
      </Box>

      {query.trim() && results.length === 0 && (
        <Text color={theme.muted}>No matches found</Text>
      )}

      {results.map((result, i) => {
        const { label, colorKey } = getMessageLabel(result.message);
        const color = theme[colorKey as keyof typeof theme] as string;
        const timeLabel = result.message.timestamp
          ? formatRelativeTime(result.message.timestamp)
          : '';

        return (
          <Box key={result.message.id} flexDirection="column">
            <Box>
              {i === selectedIndex && <Text color={theme.accent}>{'\u25B6'} </Text>}
              {i !== selectedIndex && <Text>  </Text>}
              <Text bold color={color}>{label}</Text>
              {timeLabel && <Text color={theme.muted}> {timeLabel}</Text>}
            </Box>
            <Box marginLeft={4}>
              <Text>{highlightMatch(result.preview, query, theme.accent)}</Text>
            </Box>
          </Box>
        );
      })}

      {!query.trim() && (
        <Text color={theme.muted}>Type to search through messages</Text>
      )}

      <Box marginTop={1}>
        <Text dimColor>
          {results.length > 0 ? `${results.length} result${results.length === 1 ? '' : 's'} · ` : ''}
          Escape to close
        </Text>
      </Box>
    </OverlayContainer>
  );
}
