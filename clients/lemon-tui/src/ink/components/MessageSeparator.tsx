/**
 * MessageSeparator — turn separator between messages.
 */

import React from 'react';
import { Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';

export function MessageSeparator() {
  const theme = useTheme();
  return <Text color={theme.muted}>{'\u2500\u2500\u2500 \u2500\u2500\u2500 \u2500\u2500\u2500 \u2500\u2500\u2500 \u2500\u2500\u2500'}</Text>;
}
