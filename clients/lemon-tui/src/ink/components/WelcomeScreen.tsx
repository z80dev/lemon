/**
 * Welcome screen with ASCII art and info.
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';

export function WelcomeScreen() {
  const theme = useTheme();
  const ready = useAppSelector((s) => s.ready);
  const model = useAppSelector((s) => s.model);
  const cwd = useAppSelector((s) => s.cwd);
  const sessionCount = useAppSelector((s) => s.sessions.size);

  const cwdShort = (cwd || process.cwd()).replace(process.env.HOME || '', '~');

  return (
    <Box flexDirection="column" marginY={1}>
      <Box flexDirection="column" marginLeft={4}>
        <Text color={theme.success}>       {'▄██▄'}</Text>
        <Text>      <Text color={theme.primary}>{'▄'}</Text><Text color={theme.success}>{'████'}</Text><Text color={theme.primary}>{'▄'}</Text></Text>
        <Text color={theme.primary}>     {'████████'}</Text>
        <Text>    <Text color={theme.primary}>{'██'}</Text> <Text color={theme.accent}>{'◠'}</Text>  <Text color={theme.accent}>{'◠'}</Text> <Text color={theme.primary}>{'██'}</Text></Text>
        <Text>    <Text color={theme.primary}>{'██'}</Text>  <Text color={theme.accent}>{'‿'}</Text>   <Text color={theme.primary}>{'██'}</Text></Text>
        <Text color={theme.primary}>     {'████████'}</Text>
        <Text color={theme.primary}>      {'▀████▀'}</Text>
      </Box>

      <Box marginTop={1}>
        <Text bold>  Welcome to Lemon!</Text>
      </Box>

      <Box flexDirection="column" marginTop={1}>
        <Box>
          <Text color={theme.muted}>  cwd     </Text>
          <Text color={theme.secondary}>{cwdShort}</Text>
        </Box>
        <Box>
          <Text color={theme.muted}>  model   </Text>
          {ready ? (
            <Text color={theme.secondary}>{model.provider}:{model.id}</Text>
          ) : (
            <Text dimColor>connecting...</Text>
          )}
        </Box>
        {sessionCount > 0 && (
          <Box>
            <Text color={theme.muted}>  sessions </Text>
            <Text color={theme.secondary}>{sessionCount}</Text>
            <Text color={theme.muted}> active</Text>
          </Box>
        )}
      </Box>

      <Box marginTop={1}>
        <Text color={theme.muted}>  Type a message to get started, or </Text>
        <Text color={theme.primary}>/help</Text>
        <Text color={theme.muted}> for commands.</Text>
      </Box>

      <Box flexDirection="column" marginTop={1}>
        <Box>
          <Text color={theme.muted}>  Shortcuts: </Text>
          <Text color={theme.accent}>Ctrl+N</Text>
          <Text color={theme.muted}> new session · </Text>
          <Text color={theme.accent}>Ctrl+Tab</Text>
          <Text color={theme.muted}> cycle · </Text>
          <Text color={theme.accent}>Ctrl+O</Text>
          <Text color={theme.muted}> tools · </Text>
          <Text color={theme.accent}>/settings</Text>
          <Text color={theme.muted}> config</Text>
        </Box>
        <Box>
          <Text color={theme.muted}>             </Text>
          <Text color={theme.accent}>Ctrl+F</Text>
          <Text color={theme.muted}> search · </Text>
          <Text color={theme.accent}>Ctrl+D</Text>
          <Text color={theme.muted}> compact · </Text>
          <Text color={theme.accent}>Ctrl+T</Text>
          <Text color={theme.muted}> thinking · </Text>
          <Text color={theme.accent}>Ctrl+Z</Text>
          <Text color={theme.muted}> undo</Text>
        </Box>
      </Box>
    </Box>
  );
}
