/**
 * UserMessage — renders a user message with relative timestamp.
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { formatRelativeTime } from '../utils/format.js';
import type { NormalizedUserMessage } from '../../state.js';

interface UserMessageProps {
  message: NormalizedUserMessage;
  now?: number; // for timestamp refresh
  showTimestamp?: boolean;
}

export const UserMessage = React.memo(function UserMessage({ message, showTimestamp = true }: UserMessageProps) {
  const theme = useTheme();

  const timeLabel = showTimestamp && message.timestamp ? formatRelativeTime(message.timestamp) : '';

  return (
    <Box flexDirection="column" marginY={1}>
      <Box>
        <Text bold color={theme.primary}>You:</Text>
        {timeLabel ? <Text color={theme.muted}> {timeLabel}</Text> : null}
      </Box>
      <Text>{message.content}</Text>
    </Box>
  );
});
