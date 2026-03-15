/**
 * InputOverlay — single-line text input dialog.
 */

import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { OverlayContainer } from './OverlayContainer.js';

interface InputOverlayProps {
  title: string;
  placeholder?: string | null;
  onSubmit: (value: string) => void;
  onCancel: () => void;
}

export function InputOverlay({ title, placeholder, onSubmit, onCancel }: InputOverlayProps) {
  const theme = useTheme();
  const [value, setValue] = useState('');
  const [cursorPos, setCursorPos] = useState(0);

  useInput((input, key) => {
    if (key.escape) {
      onCancel();
      return;
    }
    if (key.return) {
      onSubmit(value);
      return;
    }
    if (key.backspace || key.delete) {
      if (cursorPos > 0) {
        setValue((v) => v.slice(0, cursorPos - 1) + v.slice(cursorPos));
        setCursorPos((p) => p - 1);
      }
      return;
    }
    if (key.leftArrow) {
      setCursorPos((p) => Math.max(0, p - 1));
      return;
    }
    if (key.rightArrow) {
      setCursorPos((p) => Math.min(value.length, p + 1));
      return;
    }
    if (input && !key.ctrl && !key.meta) {
      setValue((v) => v.slice(0, cursorPos) + input + v.slice(cursorPos));
      setCursorPos((p) => p + input.length);
    }
  });

  const before = value.slice(0, cursorPos);
  const cursorChar = value[cursorPos] || ' ';
  const after = value.slice(cursorPos + 1);

  return (
    <OverlayContainer title={title}>
      {placeholder && !value && (
        <Text color={theme.muted}>{placeholder}</Text>
      )}
      <Box>
        <Text>{before}</Text>
        <Text inverse>{cursorChar}</Text>
        <Text>{after}</Text>
      </Box>
      <Text color={theme.muted}>Enter to submit · Esc to cancel</Text>
    </OverlayContainer>
  );
}
