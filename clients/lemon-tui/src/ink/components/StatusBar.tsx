/**
 * StatusBar — busy indicator, elapsed timer, token usage, stats, compact indicator.
 */

import React, { useState, useEffect } from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { formatTokenCount, formatDuration, formatCost } from '../utils/format.js';

export function StatusBar() {
  const theme = useTheme();
  const busy = useAppSelector((s) => s.busy);
  const agentWorkingMessage = useAppSelector((s) => s.agentWorkingMessage);
  const toolWorkingMessage = useAppSelector((s) => s.toolWorkingMessage);
  const status = useAppSelector((s) => s.status);
  const cumulativeUsage = useAppSelector((s) => s.cumulativeUsage);
  const stats = useAppSelector((s) => s.stats);
  const agentStartTime = useAppSelector((s) => s.agentStartTime);
  const compactMode = useAppSelector((s) => s.compactMode);
  const model = useAppSelector((s) => s.model);
  const activeSessionId = useAppSelector((s) => s.activeSessionId);
  const sessionCount = useAppSelector((s) => s.sessions.size);

  // Elapsed timer — tick every second while agent is working
  const [elapsed, setElapsed] = useState(0);
  useEffect(() => {
    if (!agentStartTime) {
      setElapsed(0);
      return;
    }
    setElapsed(Date.now() - agentStartTime);
    const timer = setInterval(() => {
      setElapsed(Date.now() - agentStartTime);
    }, 1000);
    return () => clearInterval(timer);
  }, [agentStartTime]);

  const parts: React.ReactNode[] = [];

  if (busy) {
    parts.push(<Text key="busy" color={theme.primary}>{'●'}</Text>);
    // Elapsed timer
    if (agentStartTime && elapsed > 0) {
      parts.push(
        <Text key="elapsed" color={theme.muted}>Working... {formatDuration(elapsed)}</Text>
      );
    }
  }

  const workingMessage = agentWorkingMessage || toolWorkingMessage;
  if (workingMessage && !agentStartTime) {
    parts.push(<Text key="working" color={theme.muted}>{workingMessage}</Text>);
  }

  // Model name
  if (model && model.id) {
    const shortModel = model.id.split('/').pop() || model.id;
    parts.push(<Text key="model" color={theme.secondary}>{shortModel}</Text>);
  }

  // Session indicator (only when multiple sessions)
  if (sessionCount > 1 && activeSessionId) {
    parts.push(
      <Text key="session" color={theme.muted}>{activeSessionId.slice(0, 6)} ({sessionCount})</Text>
    );
  }

  // Compact mode indicator
  if (compactMode) {
    parts.push(<Text key="compact" color={theme.accent}>[compact]</Text>);
  }

  // UI status entries (skip modeline keys)
  for (const [key, value] of status) {
    if (value && !key.startsWith('modeline')) {
      parts.push(
        <Text key={`status-${key}`} color={theme.secondary}>{key}: {value}</Text>
      );
    }
  }

  // Token and cost display
  if (cumulativeUsage.inputTokens > 0 || cumulativeUsage.outputTokens > 0) {
    const tokenPart = `\u2B07 ${formatTokenCount(cumulativeUsage.inputTokens)}  \u2B06 ${formatTokenCount(cumulativeUsage.outputTokens)}${cumulativeUsage.totalCost > 0 ? `  ${formatCost(cumulativeUsage.totalCost)}` : ''}`;
    parts.push(<Text key="tokens" color={theme.muted}>{tokenPart}</Text>);
  }

  if (stats) {
    parts.push(
      <Text key="stats" color={theme.muted}>
        turns: {stats.turn_count} · msgs: {stats.message_count}
      </Text>
    );
  }

  if (parts.length === 0) return null;

  return (
    <Box>
      {parts.map((part, i) => (
        <React.Fragment key={i}>
          {i > 0 && <Text color={theme.muted}> | </Text>}
          {part}
        </React.Fragment>
      ))}
    </Box>
  );
}
