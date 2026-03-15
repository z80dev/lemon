/**
 * ConfirmOverlay — Yes/No confirmation dialog.
 */

import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { OverlayContainer } from './OverlayContainer.js';

interface ConfirmOverlayProps {
  title: string;
  message: string;
  onConfirm: (confirmed: boolean) => void;
}

export function ConfirmOverlay({ title, message, onConfirm }: ConfirmOverlayProps) {
  const theme = useTheme();
  const [selected, setSelected] = useState(0); // 0 = Yes, 1 = No

  useInput((input, key) => {
    if (key.return) {
      onConfirm(selected === 0);
      return;
    }
    if (key.escape) {
      onConfirm(false);
      return;
    }
    if (key.leftArrow || key.rightArrow || key.tab) {
      setSelected((s) => (s === 0 ? 1 : 0));
      return;
    }
    if (input === 'y' || input === 'Y') {
      onConfirm(true);
      return;
    }
    if (input === 'n' || input === 'N') {
      onConfirm(false);
    }
  });

  return (
    <OverlayContainer title={title}>
      <Text>{message}</Text>
      <Box gap={2} marginTop={1}>
        <Text bold={selected === 0} color={selected === 0 ? theme.primary : theme.muted}>
          {selected === 0 ? '> ' : '  '}Yes
        </Text>
        <Text bold={selected === 1} color={selected === 1 ? theme.primary : theme.muted}>
          {selected === 1 ? '> ' : '  '}No
        </Text>
      </Box>
    </OverlayContainer>
  );
}
