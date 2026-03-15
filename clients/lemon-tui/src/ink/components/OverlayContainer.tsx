/**
 * OverlayContainer — modal wrapper with border for overlays.
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';

interface OverlayContainerProps {
  title: string;
  children: React.ReactNode;
}

export function OverlayContainer({ title, children }: OverlayContainerProps) {
  const theme = useTheme();

  return (
    <Box
      flexDirection="column"
      borderStyle="round"
      borderColor={theme.primary}
      paddingX={1}
      paddingY={0}
    >
      <Text bold color={theme.primary}>{title}</Text>
      {children}
    </Box>
  );
}
