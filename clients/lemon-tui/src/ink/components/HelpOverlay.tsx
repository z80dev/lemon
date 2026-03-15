/**
 * HelpOverlay — formatted help screen with commands and keybindings.
 */

import React from 'react';
import { Box, Text, useInput } from 'ink';
import { OverlayContainer } from './OverlayContainer.js';
import { useTheme } from '../context/ThemeContext.js';

interface HelpOverlayProps {
  onClose: () => void;
}

function HelpSection({ title, children }: { title: string; children: React.ReactNode }) {
  const theme = useTheme();
  return (
    <Box flexDirection="column" marginTop={1}>
      <Text bold color={theme.primary}>{title}</Text>
      {children}
    </Box>
  );
}

function HelpRow({ left, right }: { left: string; right: string }) {
  const theme = useTheme();
  return (
    <Box>
      <Box width={22}>
        <Text color={theme.accent}>{left}</Text>
      </Box>
      <Text color={theme.muted}>{right}</Text>
    </Box>
  );
}

export function HelpOverlay({ onClose }: HelpOverlayProps) {
  useInput((input, key) => {
    if (key.escape || input === 'q') {
      onClose();
    }
  });

  return (
    <OverlayContainer title="Help">
      <HelpSection title="Session Commands">
        <HelpRow left="/new-session" right="Start a new session" />
        <HelpRow left="/switch [ID]" right="Switch to a session" />
        <HelpRow left="/close-session" right="Close current session" />
        <HelpRow left="/running" right="List running sessions" />
        <HelpRow left="/sessions" right="List saved sessions" />
        <HelpRow left="/save" right="Save current session" />
        <HelpRow left="/resume" right="Resume a saved session" />
      </HelpSection>

      <HelpSection title="Navigation & Display">
        <HelpRow left="/search <query>" right="Search messages" />
        <HelpRow left="/compact" right="Toggle compact mode" />
        <HelpRow left="/stats" right="Show session statistics" />
        <HelpRow left="/notifications" right="Notification history" />
        <HelpRow left="/debug [on|off]" right="Toggle debug mode" />
        <HelpRow left="/settings" right="Open settings" />
      </HelpSection>

      <HelpSection title="Editing & Clipboard">
        <HelpRow left="/edit" right="Edit and resend last message" />
        <HelpRow left="/copy" right="Copy last code block to clipboard" />
      </HelpSection>

      <HelpSection title="Control">
        <HelpRow left="/abort" right="Stop current operation" />
        <HelpRow left="/reset" right="Clear conversation" />
        <HelpRow left="/restart" right="Restart agent" />
        <HelpRow left="/bell" right="Toggle completion bell" />
        <HelpRow left="/quit" right="Exit application" />
      </HelpSection>

      <HelpSection title="Keybindings">
        <HelpRow left="Ctrl+N" right="New session" />
        <HelpRow left="Ctrl+S" right="Session picker" />
        <HelpRow left="Ctrl+O" right="Toggle tool panel" />
        <HelpRow left="Ctrl+T" right="Toggle thinking expansion" />
        <HelpRow left="Ctrl+D" right="Toggle compact mode" />
        <HelpRow left="Ctrl+F" right="Search messages" />
        <HelpRow left="Escape" right="Close overlay" />
      </HelpSection>

      <HelpSection title="Input Editor">
        <HelpRow left="Ctrl+Left/Right" right="Word navigation" />
        <HelpRow left="Ctrl+A" right="Go to beginning" />
        <HelpRow left="Ctrl+E" right="Go to end of line" />
        <HelpRow left="Ctrl+K" right="Kill to end of line" />
        <HelpRow left="Ctrl+U" right="Kill to start of line" />
        <HelpRow left="Ctrl+W" right="Delete word backwards" />
        <HelpRow left="Ctrl+Z / Ctrl+Y" right="Undo / Redo" />
        <HelpRow left="Tab" right="Autocomplete" />
        <HelpRow left="Shift+Enter" right="New line" />
      </HelpSection>

      <Box marginTop={1}>
        <Text dimColor>Press Escape or q to close</Text>
      </Box>
    </OverlayContainer>
  );
}
