/**
 * WidgetPanel — renders dynamic widget content from server.
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';

export function WidgetPanel() {
  const theme = useTheme();
  const widgets = useAppSelector((s) => s.widgets);

  if (widgets.size === 0) return null;

  return (
    <Box flexDirection="column">
      {Array.from(widgets.entries()).map(([key, widget]) => (
        <Box key={key} flexDirection="column">
          <Text color={theme.muted}>[{key}]</Text>
          {widget.content.map((line, i) => (
            <Text key={i} color={theme.muted}>{line}</Text>
          ))}
        </Box>
      ))}
    </Box>
  );
}
