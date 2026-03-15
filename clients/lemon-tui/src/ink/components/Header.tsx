/**
 * Header component — shows model info and current working directory.
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';

export function Header() {
  const theme = useTheme();
  const ready = useAppSelector((s) => s.ready);
  const model = useAppSelector((s) => s.model);
  const cwd = useAppSelector((s) => s.cwd);

  const cwdShort = cwd.replace(process.env.HOME || '', '~');

  return (
    <Box flexDirection="column">
      <Box>
        <Text bold>Lemon </Text>
        {ready ? (
          <Text color={theme.primary}>{model.provider}:{model.id}</Text>
        ) : (
          <Text color={theme.muted}>connecting...</Text>
        )}
      </Box>
      <Text color={theme.muted}>{cwdShort}</Text>
    </Box>
  );
}
