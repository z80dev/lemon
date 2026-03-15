/**
 * ToolHint — shows Ctrl+O toggle hint when tools are present.
 */

import React from 'react';
import { Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useToolExecutions } from '../hooks/useToolExecutions.js';

export function ToolHint({ collapsed }: { collapsed: boolean }) {
  const theme = useTheme();
  const toolExecutions = useToolExecutions();

  if (toolExecutions.size === 0) return null;

  const hint = collapsed
    ? 'Ctrl+O to show tool output'
    : 'Ctrl+O to hide tool output';

  return <Text color={theme.muted}>{hint}</Text>;
}
