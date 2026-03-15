/**
 * SessionPickerOverlay — lists all sessions and allows switching between them.
 */

import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { OverlayContainer } from './OverlayContainer.js';

interface SessionPickerOverlayProps {
  onClose: () => void;
  onSwitchSession: (sessionId: string) => void;
  onNewSession: () => void;
}

export function SessionPickerOverlay({
  onClose,
  onSwitchSession,
  onNewSession,
}: SessionPickerOverlayProps) {
  const theme = useTheme();
  const sessions = useAppSelector((s) => s.sessions);
  const activeSessionId = useAppSelector((s) => s.activeSessionId);
  const sessionList = Array.from(sessions.values());
  const [selectedIndex, setSelectedIndex] = useState(() => {
    const idx = sessionList.findIndex((s) => s.sessionId === activeSessionId);
    return idx >= 0 ? idx : 0;
  });

  useInput((input, key) => {
    if (key.escape) {
      onClose();
      return;
    }

    if (key.upArrow) {
      setSelectedIndex((i) => Math.max(0, i - 1));
      return;
    }

    if (key.downArrow) {
      setSelectedIndex((i) => Math.min(sessionList.length - 1, i + 1));
      return;
    }

    if (key.return) {
      const session = sessionList[selectedIndex];
      if (session) {
        onSwitchSession(session.sessionId);
        onClose();
      }
      return;
    }

    if (input === 'n') {
      onNewSession();
      return;
    }
  });

  const shortenCwd = (cwd: string): string => {
    const home = process.env.HOME || '';
    if (home && cwd.startsWith(home)) {
      return '~' + cwd.slice(home.length);
    }
    return cwd;
  };

  return (
    <OverlayContainer title="Sessions">
      <Box flexDirection="column">
        {sessionList.map((session, i) => {
          const shortId = session.sessionId.slice(0, 8);
          const isActive = session.sessionId === activeSessionId;
          const isSelected = i === selectedIndex;
          const indicator = session.busy ? '\u25CF' : isActive ? '\u25CB' : ' ';
          const indicatorColor = session.busy ? theme.warning : isActive ? theme.success : theme.muted;

          return (
            <Box key={session.sessionId}>
              <Text color={isSelected ? theme.primary : undefined}>
                {isSelected ? '\u25B6 ' : '  '}
              </Text>
              <Text color={indicatorColor}>{indicator} </Text>
              <Text bold={isSelected} color={isActive ? theme.primary : undefined}>
                {shortId}
              </Text>
              <Text color={theme.muted}> {session.model.id}</Text>
              <Text color={theme.secondary}> {shortenCwd(session.cwd)}</Text>
              {isActive && <Text color={theme.success}> (active)</Text>}
            </Box>
          );
        })}
      </Box>
      <Box marginTop={1}>
        <Text color={theme.muted}>
          {'Enter: switch | n: new session | Esc: close'}
        </Text>
      </Box>
    </OverlayContainer>
  );
}
