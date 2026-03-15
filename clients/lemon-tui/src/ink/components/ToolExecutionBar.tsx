/**
 * ToolExecutionBar — spinner + active tool names inline with context breadcrumbs.
 */

import React, { useState, useEffect } from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { useActiveToolExecutions } from '../hooks/useToolExecutions.js';
import { SPINNER_FRAMES, TOOL_CATEGORIES } from '../../constants.js';
import { formatDuration } from '../utils/format.js';
import type { ToolExecution } from '../../state.js';

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

function getToolContext(tool: ToolExecution): string | null {
  const args = tool.args;
  const name = tool.name;

  // File tools — show file path
  if (['read', 'write', 'edit', 'multiedit', 'patch'].includes(name)) {
    const filePath = args.file_path || args.path;
    if (typeof filePath === 'string') {
      // Show just filename or last 2 path segments
      const parts = filePath.split('/');
      return parts.length > 2 ? parts.slice(-2).join('/') : filePath;
    }
  }

  // Bash/exec — show truncated command
  if (['bash', 'exec'].includes(name)) {
    const cmd = args.command;
    if (typeof cmd === 'string') {
      return cmd.length > 40 ? cmd.slice(0, 37) + '...' : cmd;
    }
  }

  // Grep — show search pattern
  if (name === 'grep') {
    const pattern = args.pattern;
    if (typeof pattern === 'string') {
      return pattern.length > 30 ? pattern.slice(0, 27) + '...' : pattern;
    }
  }

  // Glob/find — show pattern
  if (['glob', 'find'].includes(name)) {
    const pattern = args.pattern || args.glob;
    if (typeof pattern === 'string') {
      return pattern;
    }
  }

  // WebSearch — show query
  if (name === 'websearch') {
    const query = args.query;
    if (typeof query === 'string') {
      return query.length > 30 ? query.slice(0, 27) + '...' : query;
    }
  }

  return null;
}

export function ToolExecutionBar() {
  const theme = useTheme();
  const activeTools = useActiveToolExecutions();
  const [spinnerIdx, setSpinnerIdx] = useState(0);

  useEffect(() => {
    if (activeTools.length === 0) return;
    const timer = setInterval(() => {
      setSpinnerIdx((i) => (i + 1) % SPINNER_FRAMES.length);
    }, 100);
    return () => clearInterval(timer);
  }, [activeTools.length]);

  if (activeTools.length === 0) return null;

  const spinnerChar = SPINNER_FRAMES[spinnerIdx];

  return (
    <Box>
      {activeTools.map((tool, i) => {
        const elapsed = formatDuration(Date.now() - tool.startTime);
        const colorKey = getToolColorKey(tool.name);
        const color = theme[colorKey as keyof typeof theme] as string;
        const context = getToolContext(tool);

        return (
          <React.Fragment key={tool.id}>
            {i > 0 && <Text color={theme.muted}> | </Text>}
            <Text color={theme.accent}>{spinnerChar}</Text>
            <Text> </Text>
            {tool.name === 'task' && tool.taskEngine ? (
              <>
                <Text color={color}>task</Text>
                <Text>[</Text>
                <Text color={theme.secondary}>{tool.taskEngine}</Text>
                <Text>]</Text>
                {tool.taskCurrentAction && (
                  <Text> {'\u2192'} {tool.taskCurrentAction.title}</Text>
                )}
              </>
            ) : (
              <>
                <Text color={color}>{tool.name}</Text>
                {context && <Text color={theme.muted}> {context}</Text>}
              </>
            )}
            <Text color={theme.muted}> ({elapsed})</Text>
          </React.Fragment>
        );
      })}
    </Box>
  );
}
