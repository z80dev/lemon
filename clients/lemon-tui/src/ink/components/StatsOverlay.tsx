/**
 * StatsOverlay — session statistics display.
 */

import React from 'react';
import { Box, Text, useInput } from 'ink';
import { OverlayContainer } from './OverlayContainer.js';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { formatTokenCount, formatDuration, formatCost } from '../utils/format.js';

interface StatsOverlayProps {
  onClose: () => void;
}

function StatRow({ label, value }: { label: string; value: string | number }) {
  const theme = useTheme();
  return (
    <Box>
      <Box width={24}>
        <Text color={theme.muted}>{label}</Text>
      </Box>
      <Text color={theme.primary}>{String(value)}</Text>
    </Box>
  );
}

export function StatsOverlay({ onClose }: StatsOverlayProps) {
  const theme = useTheme();
  const cumulativeUsage = useAppSelector((s) => s.cumulativeUsage);
  const stats = useAppSelector((s) => s.stats);
  const messages = useAppSelector((s) => s.messages);
  const model = useAppSelector((s) => s.model);
  const activeSessionId = useAppSelector((s) => s.activeSessionId);

  useInput((input, key) => {
    if (key.escape || input === 'q') {
      onClose();
    }
  });

  // Count message types
  const userMsgCount = messages.filter((m) => m.type === 'user').length;
  const assistantMsgCount = messages.filter((m) => m.type === 'assistant').length;
  const toolResultCount = messages.filter((m) => m.type === 'tool_result').length;

  // Session duration from first message timestamp
  const firstTimestamp = messages.length > 0 ? messages[0].timestamp : 0;
  const sessionDuration = firstTimestamp > 0 ? Date.now() - firstTimestamp : 0;

  return (
    <OverlayContainer title="Session Statistics">
      <Box flexDirection="column" marginTop={1}>
        <Text bold color={theme.primary}>Session</Text>
        {activeSessionId && <StatRow label="Session ID" value={activeSessionId.slice(0, 12)} />}
        <StatRow label="Model" value={model.id || 'unknown'} />
        {sessionDuration > 0 && <StatRow label="Duration" value={formatDuration(sessionDuration)} />}
      </Box>

      <Box flexDirection="column" marginTop={1}>
        <Text bold color={theme.primary}>Messages</Text>
        <StatRow label="Total" value={messages.length} />
        <StatRow label="User" value={userMsgCount} />
        <StatRow label="Assistant" value={assistantMsgCount} />
        <StatRow label="Tool Results" value={toolResultCount} />
        {stats && (
          <>
            <StatRow label="Turns" value={stats.turn_count} />
          </>
        )}
      </Box>

      <Box flexDirection="column" marginTop={1}>
        <Text bold color={theme.primary}>Token Usage</Text>
        <StatRow label="Input" value={formatTokenCount(cumulativeUsage.inputTokens)} />
        <StatRow label="Output" value={formatTokenCount(cumulativeUsage.outputTokens)} />
        <StatRow label="Cache Read" value={formatTokenCount(cumulativeUsage.cacheReadTokens)} />
        <StatRow label="Cache Write" value={formatTokenCount(cumulativeUsage.cacheWriteTokens)} />
        {cumulativeUsage.inputTokens > 0 && cumulativeUsage.cacheReadTokens > 0 && (
          <StatRow
            label="Cache Hit Rate"
            value={`${Math.round((cumulativeUsage.cacheReadTokens / (cumulativeUsage.inputTokens + cumulativeUsage.cacheReadTokens)) * 100)}%`}
          />
        )}
        <StatRow label="Total Cost" value={formatCost(cumulativeUsage.totalCost)} />
      </Box>

      <Box marginTop={1}>
        <Text dimColor>Press Escape or q to close</Text>
      </Box>
    </OverlayContainer>
  );
}
