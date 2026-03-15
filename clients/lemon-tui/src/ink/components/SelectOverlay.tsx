/**
 * SelectOverlay — select list overlay for choosing from options.
 */

import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { OverlayContainer } from './OverlayContainer.js';

interface SelectOption {
  label: string;
  value: string;
  description?: string | null;
}

interface SelectOverlayProps {
  title: string;
  options: SelectOption[];
  onSelect: (value: string) => void;
  onCancel: () => void;
}

export function SelectOverlay({ title, options, onSelect, onCancel }: SelectOverlayProps) {
  const theme = useTheme();
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [filter, setFilter] = useState('');

  const filtered = filter
    ? options.filter((o) => o.label.toLowerCase().includes(filter.toLowerCase()))
    : options;

  useInput((input, key) => {
    if (key.escape) {
      onCancel();
      return;
    }
    if (key.return) {
      if (filtered.length > 0) {
        onSelect(filtered[selectedIndex].value);
      }
      return;
    }
    if (key.upArrow) {
      setSelectedIndex((i) => Math.max(0, i - 1));
      return;
    }
    if (key.downArrow) {
      setSelectedIndex((i) => Math.min(filtered.length - 1, i + 1));
      return;
    }
    if (key.backspace || key.delete) {
      setFilter((f) => f.slice(0, -1));
      setSelectedIndex(0);
      return;
    }
    if (input && !key.ctrl && !key.meta) {
      setFilter((f) => f + input);
      setSelectedIndex(0);
    }
  });

  return (
    <OverlayContainer title={title}>
      {filter && <Text color={theme.muted}>Filter: {filter}</Text>}
      <Box flexDirection="column">
        {filtered.slice(0, 12).map((option, i) => (
          <Box key={option.value}>
            <Text color={i === selectedIndex ? theme.primary : undefined}>
              {i === selectedIndex ? '> ' : '  '}
            </Text>
            <Text bold={i === selectedIndex}>{option.label}</Text>
            {option.description && (
              <Text color={theme.muted}> {option.description}</Text>
            )}
          </Box>
        ))}
        {filtered.length > 12 && (
          <Text color={theme.muted}>  ...{filtered.length - 12} more</Text>
        )}
        {filtered.length === 0 && (
          <Text color={theme.muted}>  No matches</Text>
        )}
      </Box>
      <Text color={theme.muted}>Enter to select · Esc to cancel</Text>
    </OverlayContainer>
  );
}
