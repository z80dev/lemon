/**
 * SettingsOverlay — settings panel for theme, bell, compact, timestamps.
 */

import React, { useState } from 'react';
import { Box, Text, useInput } from 'ink';
import { useThemeContext } from '../context/ThemeContext.js';
import { useStore } from '../context/AppContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { getAvailableThemes } from '../../theme.js';
import { saveTUIConfigKey } from '../../config.js';
import { OverlayContainer } from './OverlayContainer.js';

interface SettingsOverlayProps {
  onClose: () => void;
}

interface SettingItem {
  key: string;
  label: string;
  value: string;
  options?: string[];
  type: 'select' | 'toggle';
}

export function SettingsOverlay({ onClose }: SettingsOverlayProps) {
  const { theme, themeName, setTheme } = useThemeContext();
  const store = useStore();
  const bellEnabled = useAppSelector((s) => s.bellEnabled);
  const compactMode = useAppSelector((s) => s.compactMode);
  const showTimestamps = useAppSelector((s) => s.showTimestamps);
  const availableThemes = getAvailableThemes();
  const [selectedIndex, setSelectedIndex] = useState(0);

  const settings: SettingItem[] = [
    { key: 'theme', label: 'Theme', value: themeName, options: availableThemes, type: 'select' },
    { key: 'bell', label: 'Completion Bell', value: bellEnabled ? 'on' : 'off', options: ['on', 'off'], type: 'toggle' },
    { key: 'compact', label: 'Compact Mode', value: compactMode ? 'on' : 'off', options: ['on', 'off'], type: 'toggle' },
    { key: 'timestamps', label: 'Timestamps', value: showTimestamps ? 'on' : 'off', options: ['on', 'off'], type: 'toggle' },
  ];

  useInput((input, key) => {
    if (key.escape) {
      onClose();
      return;
    }
    if (key.upArrow) {
      setSelectedIndex((i) => Math.max(0, i - 1));
      return;
    }
    if (key.downArrow) {
      setSelectedIndex((i) => Math.min(settings.length - 1, i + 1));
      return;
    }
    if (key.leftArrow || key.rightArrow || key.return) {
      const setting = settings[selectedIndex];

      if (setting.key === 'theme' && setting.options) {
        const currentIdx = setting.options.indexOf(setting.value);
        const newIdx = key.rightArrow || key.return
          ? (currentIdx + 1) % setting.options.length
          : (currentIdx - 1 + setting.options.length) % setting.options.length;
        const newValue = setting.options[newIdx];
        setTheme(newValue);
        saveTUIConfigKey('theme', newValue);
      } else if (setting.key === 'bell') {
        store.toggleBell();
        saveTUIConfigKey('bell', !bellEnabled);
      } else if (setting.key === 'compact') {
        store.toggleCompactMode();
        saveTUIConfigKey('compact', !compactMode);
      } else if (setting.key === 'timestamps') {
        store.toggleTimestamps();
        saveTUIConfigKey('timestamps', !showTimestamps);
      }
    }
  });

  return (
    <OverlayContainer title="Settings">
      <Box flexDirection="column">
        {settings.map((setting, i) => (
          <Box key={setting.key}>
            <Text color={i === selectedIndex ? theme.primary : undefined}>
              {i === selectedIndex ? '\u25B6 ' : '  '}
            </Text>
            <Box width={20}>
              <Text bold={i === selectedIndex}>{setting.label}</Text>
            </Box>
            <Text color={theme.secondary}>{setting.value}</Text>
            {i === selectedIndex && (
              <Text color={theme.muted}>
                {setting.type === 'select' ? ' \u2190/\u2192 change' : ' Enter to toggle'}
              </Text>
            )}
          </Box>
        ))}
      </Box>
      <Box marginTop={1}>
        <Text color={theme.muted}>Esc to close · Settings saved automatically</Text>
      </Box>
    </OverlayContainer>
  );
}
