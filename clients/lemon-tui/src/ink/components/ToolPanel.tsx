/**
 * ToolPanel — collapsible tool execution details.
 */

import React, { useState, useEffect } from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useToolExecutions } from '../hooks/useToolExecutions.js';
import { SPINNER_FRAMES, TOOL_CATEGORIES } from '../../constants.js';
import { formatDuration } from '../utils/format.js';
import { defaultRegistry } from '../../formatters/index.js';

function getToolColorKey(toolName: string): string {
  const category = TOOL_CATEGORIES[toolName];
  switch (category) {
    case 'file': return 'success';
    case 'shell': return 'warning';
    case 'search': return 'primary';
    case 'orchestration': return 'secondary';
    default: return 'primary';
  }
}

function truncate(text: string, max: number): string {
  return text.length <= max ? text : text.slice(0, max) + '...';
}

const MAX_TOOLS_SHOWN = 8;

export function ToolPanel({ collapsed }: { collapsed: boolean }) {
  const theme = useTheme();
  const toolExecutions = useToolExecutions();
  const [spinnerIdx, setSpinnerIdx] = useState(0);

  const tools = Array.from(toolExecutions.values());
  const hasRunning = tools.some((t) => !t.endTime);

  useEffect(() => {
    if (!hasRunning) return;
    const timer = setInterval(() => {
      setSpinnerIdx((i) => (i + 1) % SPINNER_FRAMES.length);
    }, 100);
    return () => clearInterval(timer);
  }, [hasRunning]);

  if (tools.length === 0 || collapsed) return null;

  const sorted = [...tools].sort((a, b) => b.startTime - a.startTime);
  const shown = sorted.slice(0, MAX_TOOLS_SHOWN);
  const hidden = sorted.length - shown.length;
  const spinnerChar = SPINNER_FRAMES[spinnerIdx];

  return (
    <Box flexDirection="column">
      <Text color={theme.muted}>
        {'\u250C\u2500 tools '}
        <Text color={theme.secondary}>({tools.length})</Text>
        <Text color={theme.muted}>{' \u2500'.repeat(6)}</Text>
      </Text>
      {shown.map((tool) => {
        const isRunning = !tool.endTime;
        const isError = Boolean(tool.isError);
        const durationMs = (tool.endTime ?? Date.now()) - tool.startTime;
        const duration = formatDuration(durationMs);
        const colorKey = getToolColorKey(tool.name);
        const color = theme[colorKey as keyof typeof theme] as string;

        const statusIcon = isRunning ? spinnerChar : isError ? '\u2717' : '\u2713';
        const statusColor = isRunning ? theme.accent : isError ? theme.error : theme.success;

        // Format args using formatter registry
        let argsText = '';
        try {
          const output = defaultRegistry.formatArgs(tool.name, tool.args);
          argsText = truncate(output.summary, 200);
        } catch { /* ignore */ }

        // Format result
        let resultText = '';
        const resultPayload = tool.result ?? tool.partialResult;
        if (resultPayload !== undefined) {
          try {
            const output = defaultRegistry.formatResult(tool.name, resultPayload, tool.args);
            resultText = output.details.length > 0 ? output.details.join('\n') : output.summary;
            resultText = truncate(resultText, 600);
          } catch { /* ignore */ }
        }

        return (
          <Box key={tool.id} flexDirection="column">
            <Box>
              <Text color={theme.muted}>{'\u2502'} </Text>
              <Text color={statusColor}>{statusIcon}</Text>
              <Text> </Text>
              <Text color={color}>{tool.name}</Text>
              <Text color={theme.muted}> ({duration})</Text>
              {isError && <Text color={theme.error}> error</Text>}
            </Box>
            {tool.name === 'task' && tool.taskEngine && (
              <Box>
                <Text color={theme.muted}>{'\u2502'}   engine: </Text>
                <Text color={theme.secondary}>{tool.taskEngine}</Text>
              </Box>
            )}
            {tool.name === 'task' && tool.taskCurrentAction && (
              <Box>
                <Text color={theme.muted}>{'\u2502'}   </Text>
                <Text color={tool.taskCurrentAction.phase === 'completed' ? theme.success : theme.accent}>
                  {tool.taskCurrentAction.phase === 'completed' ? '\u2713' : '\u25B6'}
                </Text>
                <Text> </Text>
                <Text color={theme.secondary}>{tool.taskCurrentAction.title}</Text>
              </Box>
            )}
            {argsText && (
              <Box>
                <Text color={theme.muted}>{'\u2502'}   {argsText}</Text>
              </Box>
            )}
            {resultText && (
              <Box>
                <Text color={theme.muted}>{'\u2502'}   {tool.result ? 'result:' : 'partial:'} </Text>
                <Text color={theme.secondary}>{resultText}</Text>
              </Box>
            )}
          </Box>
        );
      })}
      {hidden > 0 && (
        <Text color={theme.muted}>{'\u2502'}  +{hidden} more tools</Text>
      )}
      <Text color={theme.muted}>{'\u2514' + '\u2500'.repeat(22)}</Text>
    </Box>
  );
}
