/**
 * ToolResultMessage — renders tool results with smart content formatting.
 *
 * Supports:
 * - JSON pretty-printing with syntax coloring
 * - Unified diff rendering with +/- coloring
 * - Smart truncation at 1000 chars with total-length indicator
 * - Error formatting with cross-mark prefix
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import type { InkTheme } from '../theme.js';
import type { NormalizedToolResultMessage } from '../../state.js';

const TRUNCATION_LIMIT = 1000;

// ---------------------------------------------------------------------------
// Detect & format helpers
// ---------------------------------------------------------------------------

function tryFormatJson(raw: string, theme: InkTheme): React.ReactNode | null {
  const trimmed = raw.trimStart();
  if (trimmed[0] !== '{' && trimmed[0] !== '[') return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }

  const pretty = JSON.stringify(parsed, null, 2);
  const truncated = maybeTruncate(pretty, raw.length);

  // Tokenize JSON line-by-line for coloring
  return colorizeJson(truncated, theme);
}

/** Very small regex-driven JSON colorizer that works per-line. */
function colorizeJson(text: string, theme: InkTheme): React.ReactNode {
  const lines = text.split('\n');
  return (
    <>
      {lines.map((line, i) => (
        <Text key={i}>{colorizeJsonLine(line, theme)}</Text>
      ))}
    </>
  );
}

function colorizeJsonLine(line: string, theme: InkTheme): React.ReactNode {
  // We walk the line and emit colored fragments.
  const fragments: React.ReactNode[] = [];
  let remaining = line;
  let key = 0;

  while (remaining.length > 0) {
    // Match a JSON key  "keyName":
    const keyMatch = remaining.match(/^(\s*")((?:[^"\\]|\\.)*)(":\s*)/);
    if (keyMatch) {
      fragments.push(
        <Text key={key++} color={theme.accent}>
          {keyMatch[1]}{keyMatch[2]}{keyMatch[3]}
        </Text>,
      );
      remaining = remaining.slice(keyMatch[0].length);
      continue;
    }

    // Match a string value  "..."
    const strMatch = remaining.match(/^("(?:[^"\\]|\\.)*")(,?\s*)/);
    if (strMatch) {
      fragments.push(
        <Text key={key++} color={theme.secondary}>
          {strMatch[1]}
        </Text>,
      );
      if (strMatch[2]) {
        fragments.push(<Text key={key++}>{strMatch[2]}</Text>);
      }
      remaining = remaining.slice(strMatch[0].length);
      continue;
    }

    // Match a number
    const numMatch = remaining.match(/^(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)(,?\s*)/);
    if (numMatch) {
      fragments.push(
        <Text key={key++} color={theme.primary}>
          {numMatch[1]}
        </Text>,
      );
      if (numMatch[2]) {
        fragments.push(<Text key={key++}>{numMatch[2]}</Text>);
      }
      remaining = remaining.slice(numMatch[0].length);
      continue;
    }

    // Match a boolean or null
    const boolMatch = remaining.match(/^(true|false|null)(,?\s*)/);
    if (boolMatch) {
      fragments.push(
        <Text key={key++} color={theme.warning}>
          {boolMatch[1]}
        </Text>,
      );
      if (boolMatch[2]) {
        fragments.push(<Text key={key++}>{boolMatch[2]}</Text>);
      }
      remaining = remaining.slice(boolMatch[0].length);
      continue;
    }

    // Consume one character (whitespace, braces, brackets, etc.)
    fragments.push(<Text key={key++}>{remaining[0]}</Text>);
    remaining = remaining.slice(1);
  }

  return <>{fragments}</>;
}

function tryFormatDiff(raw: string, theme: InkTheme): React.ReactNode | null {
  const trimmed = raw.trimStart();
  const isDiff =
    trimmed.startsWith('---') || raw.includes('@@ ');
  if (!isDiff) return null;

  const truncated = maybeTruncate(raw, raw.length);
  const lines = truncated.split('\n');

  return (
    <>
      {lines.map((line, i) => {
        if (line.startsWith('@@')) {
          return <Text key={i} color={theme.accent}>{line}</Text>;
        }
        if (line.startsWith('+')) {
          return <Text key={i} color={theme.success}>{line}</Text>;
        }
        if (line.startsWith('-')) {
          return <Text key={i} color={theme.error}>{line}</Text>;
        }
        return <Text key={i}>{line}</Text>;
      })}
    </>
  );
}

function maybeTruncate(text: string, totalLength: number): string {
  if (text.length <= TRUNCATION_LIMIT) return text;
  return (
    text.slice(0, TRUNCATION_LIMIT) +
    `\n[${totalLength} chars total \u2014 truncated]`
  );
}

// ---------------------------------------------------------------------------
// Component
// ---------------------------------------------------------------------------

export const ToolResultMessage = React.memo(function ToolResultMessage({
  message,
}: {
  message: NormalizedToolResultMessage;
}) {
  const theme = useTheme();

  const untrustedIndicator = message.trust === 'untrusted' ? ' [untrusted]' : '';
  const label = `[${message.toolName}]${untrustedIndicator}`;

  // --- Error formatting ---
  if (message.isError) {
    const errorContent = maybeTruncate(message.content, message.content.length);
    return (
      <Box flexDirection="column" marginY={1}>
        <Text color={theme.error}>{label}</Text>
        <Text color={theme.error}>{'\u2717'} {errorContent}</Text>
        {renderImages(message, theme)}
      </Box>
    );
  }

  // --- Try structured formats ---
  const jsonFormatted = tryFormatJson(message.content, theme);
  if (jsonFormatted) {
    return (
      <Box flexDirection="column" marginY={1}>
        <Text color={theme.secondary}>{label}</Text>
        {jsonFormatted}
        {renderImages(message, theme)}
      </Box>
    );
  }

  const diffFormatted = tryFormatDiff(message.content, theme);
  if (diffFormatted) {
    return (
      <Box flexDirection="column" marginY={1}>
        <Text color={theme.secondary}>{label}</Text>
        {diffFormatted}
        {renderImages(message, theme)}
      </Box>
    );
  }

  // --- Plain text fallback with smart truncation ---
  const plainContent = maybeTruncate(message.content, message.content.length);

  return (
    <Box flexDirection="column" marginY={1}>
      <Text color={theme.secondary}>{label} {plainContent}</Text>
      {renderImages(message, theme)}
    </Box>
  );
});

function renderImages(
  message: NormalizedToolResultMessage,
  theme: InkTheme,
): React.ReactNode {
  if (!message.images || message.images.length === 0) return null;
  return (
    <Text color={theme.muted}>
      [{message.images.length} image{message.images.length === 1 ? '' : 's'}]
    </Text>
  );
}
