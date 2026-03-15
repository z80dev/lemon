/**
 * NotificationHistoryOverlay — shows past notifications with timestamps.
 */

import React from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { useStore } from '../context/AppContext.js';
import { formatRelativeTime } from '../utils/format.js';
import { OverlayContainer } from './OverlayContainer.js';

interface NotificationHistoryOverlayProps {
  onClose: () => void;
}

export function NotificationHistoryOverlay({ onClose }: NotificationHistoryOverlayProps) {
  const theme = useTheme();
  const store = useStore();
  const history = useAppSelector((s) => s.notificationHistory);

  useInput((input, key) => {
    if (key.escape || input === 'q') {
      onClose();
      return;
    }
    // 'c' to clear history
    if (input === 'c') {
      store.clearNotificationHistory();
      return;
    }
  });

  return (
    <OverlayContainer title="Notifications">
      {history.length === 0 ? (
        <Text color={theme.muted}>No notifications yet.</Text>
      ) : (
        <Box flexDirection="column">
          {history.slice(-20).reverse().map((entry, i) => {
            const color = entry.type === 'error' ? theme.error
              : entry.type === 'warning' ? theme.warning
              : entry.type === 'success' ? theme.success
              : theme.secondary;
            const icon = entry.type === 'error' ? '\u2717'
              : entry.type === 'warning' ? '\u26A0'
              : entry.type === 'success' ? '\u2713'
              : '\u2139';
            return (
              <Box key={i}>
                <Text color={theme.muted}>{formatRelativeTime(entry.timestamp)} </Text>
                <Text color={color}>{icon} {entry.message}</Text>
              </Box>
            );
          })}
        </Box>
      )}
      <Box marginTop={1}>
        <Text color={theme.muted}>c: clear | Esc/q: close</Text>
      </Box>
    </OverlayContainer>
  );
}
