/**
 * Modeline — session tabs, git info, keybinding hints.
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { MODELINE_PREFIXES } from '../../constants.js';

function isModelineKey(key: string): boolean {
  if (key === 'modeline') return true;
  return MODELINE_PREFIXES.some((prefix) => key.startsWith(prefix));
}

function formatModelineEntry(key: string, value: string): string | null {
  if (key === 'modeline') return value;
  const prefix = MODELINE_PREFIXES.find((p) => key.startsWith(p));
  if (!prefix) return null;
  const label = key.slice(prefix.length).trim();
  return label ? `${label}: ${value}` : value;
}

export function Modeline() {
  const theme = useTheme();
  const sessions = useAppSelector((s) => s.sessions);
  const activeSessionId = useAppSelector((s) => s.activeSessionId);
  const status = useAppSelector((s) => s.status);
  const busy = useAppSelector((s) => s.busy);
  const cwd = useAppSelector((s) => s.cwd);

  const parts: React.ReactNode[] = [];

  // Session tabs
  if (sessions.size > 1 && activeSessionId) {
    const tabs: React.ReactNode[] = [];
    for (const session of sessions.values()) {
      const shortId = session.sessionId.slice(0, 6);
      const modelShort = session.model.id.split('/').pop() || session.model.id;
      const isActive = session.sessionId === activeSessionId;
      const label = `${shortId}\u00B7${modelShort}`;
      tabs.push(
        isActive
          ? <Text key={session.sessionId} bold color={theme.primary}>*[{label}]</Text>
          : <Text key={session.sessionId} color={theme.muted}>[{label}]</Text>
      );
    }
    parts.push(<Box key="tabs" gap={1}>{tabs}</Box>);
  }

  // Modeline status entries
  for (const [key, value] of status) {
    if (!value) continue;
    const formatted = formatModelineEntry(key, value);
    if (formatted) {
      parts.push(<Text key={`ml-${key}`} color={theme.secondary}>{formatted}</Text>);
    }
  }

  // Default: show cwd
  if (parts.length === 0) {
    const cwdShort = cwd.replace(process.env.HOME || '', '~');
    parts.push(<Text key="cwd" color={theme.secondary}>{cwdShort}</Text>);
  }

  // Context-aware keybinding hints
  if (busy) {
    parts.push(<Text key="hints" color={theme.muted}>Esc×2: abort | Ctrl+O: tools | Ctrl+D: compact</Text>);
  } else if (activeSessionId) {
    const sessionHint = sessions.size > 1 ? 'Ctrl+S: sessions | ' : '';
    parts.push(<Text key="hints" color={theme.muted}>{sessionHint}Ctrl+F: search | Ctrl+O: tools | Ctrl+T: thinking | /help</Text>);
  } else {
    parts.push(<Text key="hints" color={theme.muted}>Ctrl+N: new session | /settings</Text>);
  }

  return (
    <Box>
      {parts.map((part, i) => (
        <React.Fragment key={i}>
          {i > 0 && <Text color={theme.muted}> | </Text>}
          {part}
        </React.Fragment>
      ))}
    </Box>
  );
}
