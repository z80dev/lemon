/**
 * InputEditor — multi-line text input with autocomplete and keyboard handling.
 *
 * Built on Ink's useInput. Supports:
 * - Multi-line editing with cursor tracking
 * - History navigation (up/down on empty input)
 * - Autocomplete popup (Tab trigger, arrow nav, Enter select)
 * - Submit on Enter, newline on Shift+Enter
 * - Disabled state when busy
 */

import React, { useState, useCallback, useRef, useImperativeHandle, forwardRef } from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import type { AutocompleteProvider, AutocompleteItem } from '../types.js';

export interface InputEditorHandle {
  setText: (text: string) => void;
  getText: () => string;
  focus: () => void;
}

interface InputEditorProps {
  onSubmit: (text: string) => void;
  autocompleteProvider?: AutocompleteProvider | null;
  isFocused?: boolean;
}

export const InputEditor = forwardRef<InputEditorHandle, InputEditorProps>(
  function InputEditor({ onSubmit, autocompleteProvider, isFocused = true }, ref) {
    const theme = useTheme();
    const busy = useAppSelector((s) => s.busy);
    const [lines, setLines] = useState<string[]>(['']);
    const [cursorLine, setCursorLine] = useState(0);
    const [cursorCol, setCursorCol] = useState(0);
    const [history, setHistory] = useState<string[]>([]);
    const [historyIndex, setHistoryIndex] = useState(-1);
    const [suggestions, setSuggestions] = useState<AutocompleteItem[] | null>(null);
    const [suggestionPrefix, setSuggestionPrefix] = useState('');
    const [selectedSuggestion, setSelectedSuggestion] = useState(0);
    const [ctrlCFirst, setCtrlCFirst] = useState(false);
    const [escFirst, setEscFirst] = useState(false);
    const [rejectFlash, setRejectFlash] = useState(false);
    const ctrlCTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
    const escTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

    // Undo/redo state
    interface UndoEntry { lines: string[]; cursorLine: number; cursorCol: number }
    const undoStack = useRef<UndoEntry[]>([]);
    const redoStack = useRef<UndoEntry[]>([]);
    const lastUndoSave = useRef(0);

    const saveUndoState = useCallback(() => {
      // Debounce — don't save more than once per 300ms
      const now = Date.now();
      if (now - lastUndoSave.current < 300) return;
      lastUndoSave.current = now;

      undoStack.current.push({ lines: [...lines], cursorLine, cursorCol });
      if (undoStack.current.length > 50) undoStack.current.shift();
      redoStack.current = [];
    }, [lines, cursorLine, cursorCol]);

    const getText = useCallback(() => lines.join('\n'), [lines]);

    const setText = useCallback((text: string) => {
      const newLines = text.split('\n');
      setLines(newLines);
      setCursorLine(newLines.length - 1);
      setCursorCol(newLines[newLines.length - 1].length);
      setSuggestions(null);
    }, []);

    useImperativeHandle(ref, () => ({
      setText,
      getText,
      focus: () => {},
    }), [setText, getText]);

    const closeSuggestions = useCallback(() => {
      setSuggestions(null);
      setSuggestionPrefix('');
      setSelectedSuggestion(0);
    }, []);

    const submitText = useCallback(() => {
      const text = lines.join('\n');
      if (busy || !text.trim()) {
        if (!busy && !text.trim()) {
          // Flash the border to indicate rejected submit
          setRejectFlash(true);
          setTimeout(() => setRejectFlash(false), 300);
        }
        return;
      }

      // Add to history
      if (text.trim()) {
        setHistory((prev) => [text, ...prev]);
      }
      setHistoryIndex(-1);
      onSubmit(text);
      setLines(['']);
      setCursorLine(0);
      setCursorCol(0);
      closeSuggestions();
    }, [lines, busy, onSubmit, closeSuggestions]);

    useInput(
      (input, key) => {
        if (!isFocused) return;

        // Handle autocomplete navigation when suggestions are visible
        if (suggestions && suggestions.length > 0) {
          if (key.downArrow) {
            setSelectedSuggestion((i) => Math.min(i + 1, suggestions.length - 1));
            return;
          }
          if (key.upArrow) {
            setSelectedSuggestion((i) => Math.max(i - 1, 0));
            return;
          }
          if (key.return) {
            // Apply selected suggestion
            if (autocompleteProvider) {
              const result = autocompleteProvider.applyCompletion(
                lines, cursorLine, cursorCol, suggestions[selectedSuggestion], suggestionPrefix
              );
              setLines(result.lines);
              setCursorLine(result.cursorLine);
              setCursorCol(result.cursorCol);
            }
            closeSuggestions();
            return;
          }
          if (key.escape) {
            closeSuggestions();
            return;
          }
        }

        // Ctrl+Z — undo
        if (key.ctrl && input === 'z') {
          if (undoStack.current.length > 0) {
            const entry = undoStack.current.pop()!;
            redoStack.current.push({ lines: [...lines], cursorLine, cursorCol });
            setLines(entry.lines);
            setCursorLine(entry.cursorLine);
            setCursorCol(entry.cursorCol);
          }
          closeSuggestions();
          return;
        }

        // Ctrl+Y — redo
        if (key.ctrl && input === 'y') {
          if (redoStack.current.length > 0) {
            const entry = redoStack.current.pop()!;
            undoStack.current.push({ lines: [...lines], cursorLine, cursorCol });
            setLines(entry.lines);
            setCursorLine(entry.cursorLine);
            setCursorCol(entry.cursorCol);
          }
          closeSuggestions();
          return;
        }

        // Ctrl+C handling
        if (key.ctrl && input === 'c') {
          const hasText = lines.some((l) => l.length > 0);
          if (hasText) {
            setLines(['']);
            setCursorLine(0);
            setCursorCol(0);
            closeSuggestions();
          }
          // ctrlC double-press for quit is handled at app level
          return;
        }

        // Tab -> trigger autocomplete
        if (key.tab) {
          if (autocompleteProvider) {
            const result = autocompleteProvider.getSuggestions(lines, cursorLine, cursorCol);
            if (result && result.items.length > 0) {
              setSuggestions(result.items);
              setSuggestionPrefix(result.prefix);
              setSelectedSuggestion(0);
            }
          }
          return;
        }

        // Enter -> submit (Shift+Enter or when no suggestions -> newline not supported in basic Ink useInput)
        if (key.return) {
          if (key.shift || key.meta) {
            // Insert newline
            saveUndoState();
            const newLines = [...lines];
            const before = newLines[cursorLine].slice(0, cursorCol);
            const after = newLines[cursorLine].slice(cursorCol);
            newLines[cursorLine] = before;
            newLines.splice(cursorLine + 1, 0, after);
            setLines(newLines);
            setCursorLine(cursorLine + 1);
            setCursorCol(0);
            closeSuggestions();
          } else {
            submitText();
          }
          return;
        }

        // Ctrl+A — select all (move to start of first line)
        if (key.ctrl && input === 'a') {
          setCursorLine(0);
          setCursorCol(0);
          closeSuggestions();
          return;
        }

        // Ctrl+E — move to end of current line
        if (key.ctrl && input === 'e') {
          setCursorCol(lines[cursorLine].length);
          closeSuggestions();
          return;
        }

        // Ctrl+K — kill to end of line
        if (key.ctrl && input === 'k') {
          saveUndoState();
          const newLines = [...lines];
          newLines[cursorLine] = newLines[cursorLine].slice(0, cursorCol);
          setLines(newLines);
          closeSuggestions();
          return;
        }

        // Ctrl+U — kill to start of line
        if (key.ctrl && input === 'u') {
          saveUndoState();
          const newLines = [...lines];
          newLines[cursorLine] = newLines[cursorLine].slice(cursorCol);
          setLines(newLines);
          setCursorCol(0);
          closeSuggestions();
          return;
        }

        // Arrow keys
        if (key.leftArrow) {
          if (key.ctrl || key.meta) {
            // Word navigation — jump to start of previous word
            const line = lines[cursorLine];
            if (cursorCol > 0) {
              let pos = cursorCol - 1;
              // Skip whitespace
              while (pos > 0 && /\s/.test(line[pos])) pos--;
              // Skip word chars
              while (pos > 0 && !/\s/.test(line[pos - 1])) pos--;
              setCursorCol(pos);
            } else if (cursorLine > 0) {
              setCursorLine(cursorLine - 1);
              setCursorCol(lines[cursorLine - 1].length);
            }
          } else {
            if (cursorCol > 0) {
              setCursorCol(cursorCol - 1);
            } else if (cursorLine > 0) {
              setCursorLine(cursorLine - 1);
              setCursorCol(lines[cursorLine - 1].length);
            }
          }
          closeSuggestions();
          return;
        }
        if (key.rightArrow) {
          if (key.ctrl || key.meta) {
            // Word navigation — jump to end of next word
            const line = lines[cursorLine];
            if (cursorCol < line.length) {
              let pos = cursorCol;
              // Skip current word chars
              while (pos < line.length && !/\s/.test(line[pos])) pos++;
              // Skip whitespace
              while (pos < line.length && /\s/.test(line[pos])) pos++;
              setCursorCol(pos);
            } else if (cursorLine < lines.length - 1) {
              setCursorLine(cursorLine + 1);
              setCursorCol(0);
            }
          } else {
            if (cursorCol < lines[cursorLine].length) {
              setCursorCol(cursorCol + 1);
            } else if (cursorLine < lines.length - 1) {
              setCursorLine(cursorLine + 1);
              setCursorCol(0);
            }
          }
          closeSuggestions();
          return;
        }
        if (key.upArrow) {
          if (cursorLine > 0) {
            setCursorLine(cursorLine - 1);
            setCursorCol(Math.min(cursorCol, lines[cursorLine - 1].length));
          } else if (lines.length === 1 && lines[0] === '') {
            // History navigation
            const nextIdx = historyIndex + 1;
            if (nextIdx < history.length) {
              setHistoryIndex(nextIdx);
              const histText = history[nextIdx];
              const histLines = histText.split('\n');
              setLines(histLines);
              setCursorLine(histLines.length - 1);
              setCursorCol(histLines[histLines.length - 1].length);
            }
          }
          closeSuggestions();
          return;
        }
        if (key.downArrow) {
          if (cursorLine < lines.length - 1) {
            setCursorLine(cursorLine + 1);
            setCursorCol(Math.min(cursorCol, lines[cursorLine + 1].length));
          } else if (historyIndex > 0) {
            const nextIdx = historyIndex - 1;
            setHistoryIndex(nextIdx);
            const histText = history[nextIdx];
            const histLines = histText.split('\n');
            setLines(histLines);
            setCursorLine(histLines.length - 1);
            setCursorCol(histLines[histLines.length - 1].length);
          } else if (historyIndex === 0) {
            setHistoryIndex(-1);
            setLines(['']);
            setCursorLine(0);
            setCursorCol(0);
          }
          closeSuggestions();
          return;
        }

        // Ctrl+W — delete word backwards
        if (key.ctrl && input === 'w') {
          saveUndoState();
          const line = lines[cursorLine];
          if (cursorCol > 0) {
            let pos = cursorCol - 1;
            while (pos > 0 && /\s/.test(line[pos])) pos--;
            while (pos > 0 && !/\s/.test(line[pos - 1])) pos--;
            const newLines = [...lines];
            newLines[cursorLine] = line.slice(0, pos) + line.slice(cursorCol);
            setLines(newLines);
            setCursorCol(pos);
          }
          closeSuggestions();
          return;
        }

        // Backspace
        if (key.backspace || key.delete) {
          saveUndoState();
          if (cursorCol > 0) {
            const newLines = [...lines];
            newLines[cursorLine] = newLines[cursorLine].slice(0, cursorCol - 1) + newLines[cursorLine].slice(cursorCol);
            setLines(newLines);
            setCursorCol(cursorCol - 1);
          } else if (cursorLine > 0) {
            const newLines = [...lines];
            const prevLineLen = newLines[cursorLine - 1].length;
            newLines[cursorLine - 1] += newLines[cursorLine];
            newLines.splice(cursorLine, 1);
            setLines(newLines);
            setCursorLine(cursorLine - 1);
            setCursorCol(prevLineLen);
          }
          closeSuggestions();
          return;
        }

        // Escape (for abort double-press — handled at app level too)
        if (key.escape) {
          closeSuggestions();
          return;
        }

        // Regular character input
        if (input && !key.ctrl && !key.meta) {
          saveUndoState();
          const newLines = [...lines];
          newLines[cursorLine] =
            newLines[cursorLine].slice(0, cursorCol) + input + newLines[cursorLine].slice(cursorCol);
          setLines(newLines);
          setCursorCol(cursorCol + input.length);
          closeSuggestions();
          setHistoryIndex(-1);
        }
      },
      { isActive: isFocused }
    );

    // Render
    const displayLines = lines.map((line, lineIdx) => {
      if (lineIdx === cursorLine && isFocused) {
        // Show cursor
        const before = line.slice(0, cursorCol);
        const cursorChar = line[cursorCol] || ' ';
        const after = line.slice(cursorCol + 1);
        return (
          <Box key={lineIdx}>
            {lineIdx === 0 && <Text color={theme.primary}>{busy ? '· ' : '> '}</Text>}
            {lineIdx > 0 && <Text color={theme.muted}>  </Text>}
            <Text>{before}</Text>
            <Text inverse>{cursorChar}</Text>
            <Text>{after}</Text>
          </Box>
        );
      }
      return (
        <Box key={lineIdx}>
          {lineIdx === 0 && <Text color={theme.primary}>{busy ? '· ' : '> '}</Text>}
          {lineIdx > 0 && <Text color={theme.muted}>  </Text>}
          <Text>{line}</Text>
        </Box>
      );
    });

    // Position indicator for multi-line input
    const positionHint = lines.length > 1
      ? `Ln ${cursorLine + 1}, Col ${cursorCol + 1}`
      : null;

    return (
      <Box flexDirection="column">
        <Box flexDirection="column" borderStyle="single" borderColor={rejectFlash ? theme.error : theme.primary} paddingX={1}>
          {displayLines}
        </Box>
        {positionHint && isFocused && (
          <Box justifyContent="flex-end">
            <Text color={theme.muted}>{positionHint}</Text>
          </Box>
        )}

        {/* Autocomplete popup */}
        {suggestions && suggestions.length > 0 && (
          <Box flexDirection="column" borderStyle="single" borderColor={theme.border} marginLeft={2}>
            {suggestions.slice(0, 8).map((item, i) => (
              <Box key={item.value}>
                <Text inverse={i === selectedSuggestion}>
                  {item.label}
                </Text>
                {item.description && (
                  <Text color={theme.muted}> {item.description}</Text>
                )}
              </Box>
            ))}
            {suggestions.length > 8 && (
              <Text color={theme.muted}>  ...{suggestions.length - 8} more</Text>
            )}
          </Box>
        )}
      </Box>
    );
  }
);
