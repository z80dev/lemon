/**
 * MessageList — renders the conversation messages with compact mode,
 * expandable thinking, and timestamp refresh support.
 */

import React, { useState, useEffect } from 'react';
import { Box } from 'ink';
import { useMessages, useStreamingMessage } from '../hooks/useMessages.js';
import { useAppSelector } from '../hooks/useAppState.js';
import { useStore } from '../context/AppContext.js';
import { UserMessage } from './UserMessage.js';
import { AssistantMessage } from './AssistantMessage.js';
import { ToolResultMessage } from './ToolResultMessage.js';
import { MessageSeparator } from './MessageSeparator.js';
import type {
  NormalizedUserMessage,
  NormalizedAssistantMessage,
  NormalizedToolResultMessage,
} from '../../state.js';

interface MessageListProps {
  showToolResults: boolean;
}

export function MessageList({ showToolResults }: MessageListProps) {
  const messages = useMessages();
  const streamingMessage = useStreamingMessage();
  const store = useStore();
  const compactMode = useAppSelector((s) => s.compactMode);
  const expandedThinkingIds = useAppSelector((s) => s.expandedThinkingIds);
  const showTimestamps = useAppSelector((s) => s.showTimestamps);

  // Refresh timestamps every 30s
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 30000);
    return () => clearInterval(timer);
  }, []);

  const elements: React.ReactNode[] = [];
  let prevType: string | null = null;

  for (const msg of messages) {
    // In compact mode, hide tool results
    if (msg.type === 'tool_result' && (compactMode || !showToolResults)) continue;

    // Add separator between turns
    const isNewTurn =
      prevType !== null &&
      ((prevType === 'user' && msg.type === 'assistant') ||
        (prevType === 'assistant' && msg.type === 'user') ||
        (prevType === 'tool_result' && msg.type === 'user'));

    if (isNewTurn) {
      elements.push(<MessageSeparator key={`sep-${msg.id}`} />);
    }

    switch (msg.type) {
      case 'user':
        elements.push(
          <UserMessage key={msg.id} message={msg as NormalizedUserMessage} now={now} showTimestamp={showTimestamps} />
        );
        break;
      case 'assistant': {
        const assistantMsg = msg as NormalizedAssistantMessage;
        elements.push(
          <AssistantMessage
            key={msg.id}
            message={assistantMsg}
            thinkingExpanded={expandedThinkingIds.has(msg.id)}
            compactMode={compactMode}
            showTimestamp={showTimestamps}
            onToggleThinking={() => store.toggleThinkingExpanded(msg.id)}
            now={now}
          />
        );
        break;
      }
      case 'tool_result':
        elements.push(<ToolResultMessage key={msg.id} message={msg as NormalizedToolResultMessage} />);
        break;
    }

    prevType = msg.type;
  }

  // Streaming message
  if (streamingMessage) {
    if (prevType === 'user') {
      elements.push(<MessageSeparator key="sep-streaming" />);
    }
    elements.push(
      <AssistantMessage
        key="streaming"
        message={streamingMessage}
        compactMode={compactMode}
        showTimestamp={showTimestamps}
        now={now}
      />
    );
  }

  if (elements.length === 0) return null;

  return (
    <Box flexDirection="column">
      {elements}
    </Box>
  );
}
