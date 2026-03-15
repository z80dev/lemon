/**
 * Loader — spinner during busy state.
 */

import React from 'react';
import { Box, Text } from 'ink';
import Spinner from 'ink-spinner';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';

export function Loader() {
  const theme = useTheme();
  const busy = useAppSelector((s) => s.busy);
  const agentWorkingMessage = useAppSelector((s) => s.agentWorkingMessage);
  const toolWorkingMessage = useAppSelector((s) => s.toolWorkingMessage);

  if (!busy) return null;

  const message = agentWorkingMessage || toolWorkingMessage || 'Processing...';

  return (
    <Box>
      <Text color={theme.primary}>
        <Spinner type="dots" />
      </Text>
      <Text color={theme.muted}> {message}</Text>
    </Box>
  );
}
