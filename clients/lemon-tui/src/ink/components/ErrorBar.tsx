/**
 * ErrorBar — persistent error notification that dismisses on keypress or after timeout.
 */

import React, { useEffect, useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { useStore } from '../context/AppContext.js';

const ERROR_DISPLAY_TIMEOUT_MS = 15000;

export function ErrorBar() {
  const theme = useTheme();
  const store = useStore();
  const error = useAppSelector((s) => s.error);
  const [visibleError, setVisibleError] = useState<string | null>(() => error);

  useEffect(() => {
    if (error) {
      setVisibleError(error);
      // Auto-dismiss after longer timeout as fallback
      const timer = setTimeout(() => {
        setVisibleError(null);
        store.setError(null);
      }, ERROR_DISPLAY_TIMEOUT_MS);
      return () => clearTimeout(timer);
    }
  }, [error, store]);

  // Dismiss on any keypress
  useInput(
    () => {
      if (visibleError) {
        setVisibleError(null);
        store.setError(null);
      }
    },
    { isActive: !!visibleError }
  );

  if (!visibleError) return null;

  return (
    <Box>
      <Text color={theme.error}>  {'\u2717'} {visibleError}</Text>
      <Text color={theme.muted}> (press any key to dismiss)</Text>
    </Box>
  );
}
