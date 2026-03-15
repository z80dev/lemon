/**
 * AssistantMessage — renders an assistant message with streaming support,
 * per-turn token display, expandable thinking, compact mode, timestamps,
 * and markdown rendering.
 */

import React from 'react';
import { Box, Text } from 'ink';
import { useTheme } from '../context/ThemeContext.js';
import { MarkdownRenderer } from './MarkdownRenderer.js';
import { formatTokenCount, formatCost, formatRelativeTime } from '../utils/format.js';
import type { NormalizedAssistantMessage } from '../../state.js';

interface AssistantMessageProps {
  message: NormalizedAssistantMessage;
  thinkingExpanded?: boolean;
  compactMode?: boolean;
  showTimestamp?: boolean;
  onToggleThinking?: () => void;
  now?: number; // for timestamp refresh
}

export const AssistantMessage = React.memo(function AssistantMessage({
  message,
  thinkingExpanded = false,
  compactMode = false,
  showTimestamp = true,
  onToggleThinking,
}: AssistantMessageProps) {
  const theme = useTheme();

  // Timestamp
  const timeLabel = showTimestamp && message.timestamp ? formatRelativeTime(message.timestamp) : '';

  return (
    <Box flexDirection="column" marginY={1}>
      <Box>
        <Text bold color={theme.success}>Assistant:</Text>
        {timeLabel ? <Text color={theme.muted}> {timeLabel}</Text> : null}
      </Box>

      {/* Thinking content */}
      {message.thinkingContent && !compactMode ? (
        <Box flexDirection="column">
          <Text dimColor italic>[thinking]</Text>
          {thinkingExpanded ? (
            <Text color={theme.muted}>{message.thinkingContent}</Text>
          ) : (
            <>
              <Text color={theme.muted}>{message.thinkingContent.slice(0, 200)}...</Text>
              <Text dimColor>
                [{message.thinkingContent.length} chars {'\u2014'} expand with Ctrl+T]
              </Text>
            </>
          )}
          <Text>{' '}</Text>
        </Box>
      ) : null}

      {/* Main text content */}
      {message.textContent ? (
        compactMode ? (
          <Text>
            {message.textContent.split('\n').slice(0, 3).join('\n')}
            {message.textContent.split('\n').length > 3 ? '\n...' : ''}
          </Text>
        ) : (
          <MarkdownRenderer content={message.textContent} />
        )
      ) : null}

      {/* Tool calls */}
      {compactMode && message.toolCalls.length > 0 ? (
        <Box>
          <Text color={theme.muted}>
            [{message.toolCalls.length} tools: {message.toolCalls.map((t) => t.name).join(', ')}]
          </Text>
        </Box>
      ) : (
        message.toolCalls.map((tool) => (
          <Box key={tool.id}>
            <Text color={theme.warning}>{'->'} </Text>
            <Text>{tool.name}</Text>
          </Box>
        ))
      )}

      {/* Streaming indicator */}
      {message.isStreaming ? <Text color={theme.muted}>...</Text> : null}

      {/* Per-turn token/cost display */}
      {!message.isStreaming && message.usage ? (
        <Box>
          <Text color={theme.muted}>
            {message.usage.inputTokens != null ? `\u2193${formatTokenCount(message.usage.inputTokens)}` : ''}
            {message.usage.outputTokens != null ? ` \u2191${formatTokenCount(message.usage.outputTokens)}` : ''}
            {message.usage.totalCost != null && message.usage.totalCost > 0
              ? ` ${formatCost(message.usage.totalCost)}`
              : ''}
          </Text>
        </Box>
      ) : null}

      {/* Stop reason */}
      {!message.isStreaming && message.stopReason === 'length' ? (
        <Text color={theme.warning}>[truncated]</Text>
      ) : null}
      {!message.isStreaming && message.stopReason === 'error' ? (
        <Text color={theme.error}>[error]</Text>
      ) : null}
      {!message.isStreaming && message.stopReason === 'aborted' ? (
        <Text color={theme.error}>[aborted]</Text>
      ) : null}
    </Box>
  );
});
