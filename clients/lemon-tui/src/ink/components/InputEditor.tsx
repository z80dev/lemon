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
  onAbort?: () => void;
  autocompleteProvider?: AutocompleteProvider | null;
  isFocused?: boolean;
}

export const InputEditor = forwardRef<InputEditorHandle, InputEditorProps>(
  function InputEditor({ onSubmit, onAbort, autocompleteProvider, isFocused = true }, ref) {
    const theme = useTheme();
    const busy = useAppSelector((s) => s.busy);
    const [lines, setLines] = useState<string[]>(['']);
    const [cursorLine, setCursorLine] = useState(0);
    const [cursorCol, setCursorCol] = useState(0);
    const linesRef = useRef<string[]>(['']);
    const cursorLineRef = useRef(0);
    const cursorColRef = useRef(0);
    const [history, setHistory] = useState<string[]>([]);
    const [historyIndex, setHistoryIndex] = useState(-1);
    const [suggestions, setSuggestions] = useState<AutocompleteItem[] | null>(null);
    const [suggestionPrefix, setSuggestionPrefix] = useState('');
    const [selectedSuggestion, setSelectedSuggestion] = useState(0);
    const suggestionsRef = useRef<AutocompleteItem[] | null>(null);
    const suggestionPrefixRef = useRef('');
    const selectedSuggestionRef = useRef(0);
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

    const setEditorState = useCallback((nextLines: string[], nextLine: number, nextCol: number) => {
      linesRef.current = nextLines;
      cursorLineRef.current = nextLine;
      cursorColRef.current = nextCol;
      setLines(nextLines);
      setCursorLine(nextLine);
      setCursorCol(nextCol);
    }, []);

    const setEditorCursor = useCallback((nextLine: number, nextCol: number) => {
      cursorLineRef.current = nextLine;
      cursorColRef.current = nextCol;
      setCursorLine(nextLine);
      setCursorCol(nextCol);
    }, []);

    const setEditorLines = useCallback((nextLines: string[]) => {
      linesRef.current = nextLines;
      setLines(nextLines);
    }, []);

    const saveUndoState = useCallback(() => {
      const now = Date.now();
      if (now - lastUndoSave.current < 300) return;
      lastUndoSave.current = now;

      undoStack.current.push({
        lines: [...linesRef.current],
        cursorLine: cursorLineRef.current,
        cursorCol: cursorColRef.current,
      });
      if (undoStack.current.length > 50) undoStack.current.shift();
      redoStack.current = [];
    }, []);

    const getText = useCallback(() => linesRef.current.join('\n'), []);

    const setText = useCallback((text: string) => {
      const newLines = text.split('\n');
      setEditorState(newLines, newLines.length - 1, newLines[newLines.length - 1].length);
      setSuggestions(null);
      suggestionsRef.current = null;
      suggestionPrefixRef.current = '';
      selectedSuggestionRef.current = 0;
    }, [setEditorState]);

    useImperativeHandle(ref, () => ({
      setText,
      getText,
      focus: () => {},
    }), [setText, getText]);

    const closeSuggestions = useCallback(() => {
      setSuggestions(null);
      setSuggestionPrefix('');
      setSelectedSuggestion(0);
      suggestionsRef.current = null;
      suggestionPrefixRef.current = '';
      selectedSuggestionRef.current = 0;
    }, []);

    const submitText = useCallback(() => {
      const text = linesRef.current.join('\n');
      if (busy || !text.trim()) {
        if (!busy && !text.trim()) {
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
      setEditorState([''], 0, 0);
      closeSuggestions();
    }, [busy, onSubmit, closeSuggestions, setEditorState]);

    const requestAbort = useCallback(
      (kind: 'ctrl_c' | 'escape') => {
        if (!busy || !onAbort) return false;

        const isCtrlC = kind === 'ctrl_c';
        const first = isCtrlC ? ctrlCFirst : escFirst;
        const setFirst = isCtrlC ? setCtrlCFirst : setEscFirst;
        const timer = isCtrlC ? ctrlCTimer : escTimer;

        if (first) {
          if (timer.current) clearTimeout(timer.current);
          setFirst(false);
          onAbort();
          return true;
        }

        setFirst(true);
        timer.current = setTimeout(() => setFirst(false), 800);
        return true;
      },
      [busy, ctrlCFirst, escFirst, onAbort]
    );

    useInput(
      (input, key) => {
        if (!isFocused) return;

        const currentLines = linesRef.current;
        const currentLine = cursorLineRef.current;
        const currentCol = cursorColRef.current;

        const activeSuggestions = suggestions ?? suggestionsRef.current;

        if (activeSuggestions && activeSuggestions.length > 0) {
          if (key.downArrow) {
            setSelectedSuggestion((i) => {
              const next = Math.min(i + 1, activeSuggestions.length - 1);
              selectedSuggestionRef.current = next;
              return next;
            });
            return;
          }
          if (key.upArrow) {
            setSelectedSuggestion((i) => {
              const next = Math.max(i - 1, 0);
              selectedSuggestionRef.current = next;
              return next;
            });
            return;
          }
          if (key.return) {
            // Apply selected suggestion
            if (autocompleteProvider) {
              const activeSelected = Math.min(
                selectedSuggestionRef.current,
                activeSuggestions.length - 1
              );
              const result = autocompleteProvider.applyCompletion(
                currentLines,
                currentLine,
                currentCol,
                activeSuggestions[activeSelected],
                suggestionPrefixRef.current
              );
              setEditorState(result.lines, result.cursorLine, result.cursorCol);
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
            redoStack.current.push({
              lines: [...linesRef.current],
              cursorLine: cursorLineRef.current,
              cursorCol: cursorColRef.current,
            });
            setEditorState(entry.lines, entry.cursorLine, entry.cursorCol);
          }
          closeSuggestions();
          return;
        }

        // Ctrl+Y — redo
        if (key.ctrl && input === 'y') {
          if (redoStack.current.length > 0) {
            const entry = redoStack.current.pop()!;
            undoStack.current.push({
              lines: [...linesRef.current],
              cursorLine: cursorLineRef.current,
              cursorCol: cursorColRef.current,
            });
            setEditorState(entry.lines, entry.cursorLine, entry.cursorCol);
          }
          closeSuggestions();
          return;
        }

        // Ctrl+C handling
        if ((key.ctrl && input === 'c') || input === '\x03') {
          if (requestAbort('ctrl_c')) return;

          const hasText = currentLines.some((l) => l.length > 0);
          if (hasText) {
            setEditorState([''], 0, 0);
            closeSuggestions();
          }
          return;
        }

        // Tab -> trigger autocomplete
        if (key.tab) {
          if (autocompleteProvider) {
            const result = autocompleteProvider.getSuggestions(currentLines, currentLine, currentCol);
            if (result && result.items.length > 0) {
              setSuggestions(result.items);
              setSuggestionPrefix(result.prefix);
              setSelectedSuggestion(0);
              suggestionsRef.current = result.items;
              suggestionPrefixRef.current = result.prefix;
              selectedSuggestionRef.current = 0;
            }
          }
          return;
        }

        // Enter -> submit (Shift+Enter or when no suggestions -> newline not supported in basic Ink useInput)
        if (key.return) {
          if (key.shift || key.meta) {
            saveUndoState();
            const newLines = [...currentLines];
            const before = newLines[currentLine].slice(0, currentCol);
            const after = newLines[currentLine].slice(currentCol);
            newLines[currentLine] = before;
            newLines.splice(currentLine + 1, 0, after);
            setEditorState(newLines, currentLine + 1, 0);
            closeSuggestions();
          } else {
            submitText();
          }
          return;
        }

        if (key.ctrl && input === 'a') {
          setEditorCursor(0, 0);
          closeSuggestions();
          return;
        }

        if (key.ctrl && input === 'e') {
          setEditorCursor(currentLine, currentLines[currentLine].length);
          closeSuggestions();
          return;
        }

        if (key.ctrl && input === 'k') {
          saveUndoState();
          const newLines = [...currentLines];
          newLines[currentLine] = newLines[currentLine].slice(0, currentCol);
          setEditorLines(newLines);
          closeSuggestions();
          return;
        }

        if (key.ctrl && input === 'u') {
          saveUndoState();
          const newLines = [...currentLines];
          newLines[currentLine] = newLines[currentLine].slice(currentCol);
          setEditorState(newLines, currentLine, 0);
          closeSuggestions();
          return;
        }

        if (key.leftArrow) {
          if (key.ctrl || key.meta) {
            const line = currentLines[currentLine];
            if (currentCol > 0) {
              let pos = currentCol - 1;
              while (pos > 0 && /\s/.test(line[pos])) pos--;
              while (pos > 0 && !/\s/.test(line[pos - 1])) pos--;
              setEditorCursor(currentLine, pos);
            } else if (currentLine > 0) {
              setEditorCursor(currentLine - 1, currentLines[currentLine - 1].length);
            }
          } else {
            if (currentCol > 0) {
              setEditorCursor(currentLine, currentCol - 1);
            } else if (currentLine > 0) {
              setEditorCursor(currentLine - 1, currentLines[currentLine - 1].length);
            }
          }
          closeSuggestions();
          return;
        }
        if (key.rightArrow) {
          if (key.ctrl || key.meta) {
            const line = currentLines[currentLine];
            if (currentCol < line.length) {
              let pos = currentCol;
              while (pos < line.length && !/\s/.test(line[pos])) pos++;
              while (pos < line.length && /\s/.test(line[pos])) pos++;
              setEditorCursor(currentLine, pos);
            } else if (currentLine < currentLines.length - 1) {
              setEditorCursor(currentLine + 1, 0);
            }
          } else {
            if (currentCol < currentLines[currentLine].length) {
              setEditorCursor(currentLine, currentCol + 1);
            } else if (currentLine < currentLines.length - 1) {
              setEditorCursor(currentLine + 1, 0);
            }
          }
          closeSuggestions();
          return;
        }
        if (key.upArrow) {
          if (currentLine > 0) {
            setEditorCursor(currentLine - 1, Math.min(currentCol, currentLines[currentLine - 1].length));
          } else if (currentLines.length === 1 && currentLines[0] === '') {
            const nextIdx = historyIndex + 1;
            if (nextIdx < history.length) {
              setHistoryIndex(nextIdx);
              const histText = history[nextIdx];
              const histLines = histText.split('\n');
              setEditorState(histLines, histLines.length - 1, histLines[histLines.length - 1].length);
            }
          }
          closeSuggestions();
          return;
        }
        if (key.downArrow) {
          if (currentLine < currentLines.length - 1) {
            setEditorCursor(currentLine + 1, Math.min(currentCol, currentLines[currentLine + 1].length));
          } else if (historyIndex > 0) {
            const nextIdx = historyIndex - 1;
            setHistoryIndex(nextIdx);
            const histText = history[nextIdx];
            const histLines = histText.split('\n');
            setEditorState(histLines, histLines.length - 1, histLines[histLines.length - 1].length);
          } else if (historyIndex === 0) {
            setHistoryIndex(-1);
            setEditorState([''], 0, 0);
          }
          closeSuggestions();
          return;
        }

        if (key.ctrl && input === 'w') {
          saveUndoState();
          const line = currentLines[currentLine];
          if (currentCol > 0) {
            let pos = currentCol - 1;
            while (pos > 0 && /\s/.test(line[pos])) pos--;
            while (pos > 0 && !/\s/.test(line[pos - 1])) pos--;
            const newLines = [...currentLines];
            newLines[currentLine] = line.slice(0, pos) + line.slice(currentCol);
            setEditorState(newLines, currentLine, pos);
          }
          closeSuggestions();
          return;
        }

        if (key.backspace || key.delete) {
          saveUndoState();
          if (currentCol > 0) {
            const newLines = [...currentLines];
            newLines[currentLine] = newLines[currentLine].slice(0, currentCol - 1) + newLines[currentLine].slice(currentCol);
            setEditorState(newLines, currentLine, currentCol - 1);
          } else if (currentLine > 0) {
            const newLines = [...currentLines];
            const prevLineLen = newLines[currentLine - 1].length;
            newLines[currentLine - 1] += newLines[currentLine];
            newLines.splice(currentLine, 1);
            setEditorState(newLines, currentLine - 1, prevLineLen);
          }
          closeSuggestions();
          return;
        }

        if (key.escape || input === '\x1B') {
          if (requestAbort('escape')) return;
          closeSuggestions();
          return;
        }

        if (input && !key.ctrl && !key.meta) {
          saveUndoState();
          const newLines = [...currentLines];
          newLines[currentLine] =
            newLines[currentLine].slice(0, currentCol) + input + newLines[currentLine].slice(currentCol);
          setEditorState(newLines, currentLine, currentCol + input.length);
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
