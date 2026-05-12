/**
 * SelectOverlay — select list overlay for choosing from options.
 */

import React, { useRef, useState } from 'react';
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
  const selectedIndexRef = useRef(0);

  const filtered = filter
    ? options.filter((o) => o.label.toLowerCase().includes(filter.toLowerCase()))
    : options;
  const filteredRef = useRef(filtered);
  filteredRef.current = filtered;

  const updateSelectedIndex = (next: number) => {
    selectedIndexRef.current = next;
    setSelectedIndex(next);
  };

  useInput((input, key) => {
    if (key.escape) {
      onCancel();
      return;
    }
    if (key.return) {
      const currentFiltered = filteredRef.current;
      if (currentFiltered.length > 0) {
        onSelect(currentFiltered[selectedIndexRef.current].value);
      }
      return;
    }
    if (key.upArrow) {
      updateSelectedIndex(Math.max(0, selectedIndexRef.current - 1));
      return;
    }
    if (key.downArrow) {
      updateSelectedIndex(Math.min(filteredRef.current.length - 1, selectedIndexRef.current + 1));
      return;
    }
    if (key.backspace || key.delete) {
      setFilter((f) => f.slice(0, -1));
      updateSelectedIndex(0);
      return;
    }
    if (input && !key.ctrl && !key.meta) {
      setFilter((f) => f + input);
      updateSelectedIndex(0);
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
