/**
 * EditorOverlay — multi-line text editor dialog.
 */

import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { OverlayContainer } from './OverlayContainer.js';

interface EditorOverlayProps {
  title: string;
  prefill?: string | null;
  onSubmit: (value: string) => void;
  onCancel: () => void;
}

export function EditorOverlay({ title, prefill, onSubmit, onCancel }: EditorOverlayProps) {
  const theme = useTheme();
  const initialLines = (prefill || '').split('\n');
  const [lines, setLines] = useState<string[]>(initialLines.length > 0 ? initialLines : ['']);
  const [cursorLine, setCursorLine] = useState(0);
  const [cursorCol, setCursorCol] = useState(0);

  useInput((input, key) => {
    if (key.escape) {
      onCancel();
      return;
    }
    if (key.return && key.meta) {
      // Meta+Enter to submit
      onSubmit(lines.join('\n'));
      return;
    }
    if (key.return) {
      // Insert newline
      const newLines = [...lines];
      const before = newLines[cursorLine].slice(0, cursorCol);
      const after = newLines[cursorLine].slice(cursorCol);
      newLines[cursorLine] = before;
      newLines.splice(cursorLine + 1, 0, after);
      setLines(newLines);
      setCursorLine(cursorLine + 1);
      setCursorCol(0);
      return;
    }
    if (key.backspace || key.delete) {
      if (cursorCol > 0) {
        const newLines = [...lines];
        newLines[cursorLine] = newLines[cursorLine].slice(0, cursorCol - 1) + newLines[cursorLine].slice(cursorCol);
        setLines(newLines);
        setCursorCol(cursorCol - 1);
      } else if (cursorLine > 0) {
        const newLines = [...lines];
        const prevLen = newLines[cursorLine - 1].length;
        newLines[cursorLine - 1] += newLines[cursorLine];
        newLines.splice(cursorLine, 1);
        setLines(newLines);
        setCursorLine(cursorLine - 1);
        setCursorCol(prevLen);
      }
      return;
    }
    if (key.upArrow) {
      if (cursorLine > 0) {
        setCursorLine(cursorLine - 1);
        setCursorCol(Math.min(cursorCol, lines[cursorLine - 1].length));
      }
      return;
    }
    if (key.downArrow) {
      if (cursorLine < lines.length - 1) {
        setCursorLine(cursorLine + 1);
        setCursorCol(Math.min(cursorCol, lines[cursorLine + 1].length));
      }
      return;
    }
    if (key.leftArrow) {
      if (cursorCol > 0) setCursorCol(cursorCol - 1);
      else if (cursorLine > 0) {
        setCursorLine(cursorLine - 1);
        setCursorCol(lines[cursorLine - 1].length);
      }
      return;
    }
    if (key.rightArrow) {
      if (cursorCol < lines[cursorLine].length) setCursorCol(cursorCol + 1);
      else if (cursorLine < lines.length - 1) {
        setCursorLine(cursorLine + 1);
        setCursorCol(0);
      }
      return;
    }
    if (input && !key.ctrl && !key.meta) {
      const newLines = [...lines];
      newLines[cursorLine] = newLines[cursorLine].slice(0, cursorCol) + input + newLines[cursorLine].slice(cursorCol);
      setLines(newLines);
      setCursorCol(cursorCol + input.length);
    }
  });

  return (
    <OverlayContainer title={title}>
      <Box flexDirection="column">
        {lines.map((line, lineIdx) => {
          if (lineIdx === cursorLine) {
            const before = line.slice(0, cursorCol);
            const cursorChar = line[cursorCol] || ' ';
            const after = line.slice(cursorCol + 1);
            return (
              <Box key={lineIdx}>
                <Text>{before}</Text>
                <Text inverse>{cursorChar}</Text>
                <Text>{after}</Text>
              </Box>
            );
          }
          return <Text key={lineIdx}>{line || ' '}</Text>;
        })}
      </Box>
      <Text color={theme.muted}>Meta+Enter to submit · Esc to cancel</Text>
    </OverlayContainer>
  );
}
