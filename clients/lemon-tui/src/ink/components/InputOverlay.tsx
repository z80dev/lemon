/**
 * InputOverlay — single-line text input dialog.
 */

import React, { useRef, useState } from 'react';
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
  const valueRef = useRef('');
  const cursorPosRef = useRef(0);

  useInput((input, key) => {
    if (key.escape) {
      onCancel();
      return;
    }
    if (key.return) {
      onSubmit(valueRef.current);
      return;
    }
    if (key.backspace || key.delete) {
      const currentCursor = cursorPosRef.current;
      if (currentCursor > 0) {
        const currentValue = valueRef.current;
        const nextValue = currentValue.slice(0, currentCursor - 1) + currentValue.slice(currentCursor);
        const nextCursor = currentCursor - 1;
        valueRef.current = nextValue;
        cursorPosRef.current = nextCursor;
        setValue(nextValue);
        setCursorPos(nextCursor);
      }
      return;
    }
    if (key.leftArrow) {
      const nextCursor = Math.max(0, cursorPosRef.current - 1);
      cursorPosRef.current = nextCursor;
      setCursorPos(nextCursor);
      return;
    }
    if (key.rightArrow) {
      const nextCursor = Math.min(valueRef.current.length, cursorPosRef.current + 1);
      cursorPosRef.current = nextCursor;
      setCursorPos(nextCursor);
      return;
    }
    if (input && !key.ctrl && !key.meta) {
      const currentValue = valueRef.current;
      const currentCursor = cursorPosRef.current;
      const nextValue = currentValue.slice(0, currentCursor) + input + currentValue.slice(currentCursor);
      const nextCursor = currentCursor + input.length;
      valueRef.current = nextValue;
      cursorPosRef.current = nextCursor;
      setValue(nextValue);
      setCursorPos(nextCursor);
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
