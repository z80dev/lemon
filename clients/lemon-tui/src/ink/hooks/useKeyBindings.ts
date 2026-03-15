/**
 * Global keyboard shortcut handling via Ink's useInput.
 */

import { useInput } from 'ink';
import { useCallback } from 'react';
import { useConnection } from '../context/AppContext.js';
import { useAppSelector } from './useAppState.js';

interface KeyBindingOptions {
  /** Called when Ctrl+N is pressed */
  onNewSession: () => void;
  /** Called when Ctrl+Tab is pressed */
  onCycleSession: () => void;
  /** Called when Ctrl+O is pressed */
  onToggleToolPanel: () => void;
  /** Called to quit */
  onQuit: () => void;
  /** Whether an overlay is active (suppresses bindings) */
  overlayActive: boolean;
  /** Whether the input editor is focused (some keys handled by editor) */
  editorFocused: boolean;
}

export function useKeyBindings(options: KeyBindingOptions): void {
  const connection = useConnection();
  const busy = useAppSelector((s) => s.busy);

  useInput(
    useCallback(
      (input: string, key: import('ink').Key) => {
        if (options.overlayActive) return;

        // Ctrl+N -> new session
        if (key.ctrl && input === 'n') {
          options.onNewSession();
          return;
        }

        // Ctrl+O -> toggle tool panel
        if (key.ctrl && input === 'o') {
          options.onToggleToolPanel();
          return;
        }

        // Ctrl+C handling is done in the editor component
      },
      [options, connection, busy]
    )
  );
}
