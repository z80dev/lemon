import { render, screen } from '@testing-library/react';
import { describe, it, expect } from 'vitest';
import { MessageCard } from './MessageCard';

const baseToolMessage = {
  __struct__: 'Elixir.Ai.Types.ToolResultMessage',
  role: 'tool_result' as const,
  tool_call_id: 'call-1',
  tool_name: 'read',
  content: [
    {
      __struct__: 'Elixir.Ai.Types.TextContent',
      type: 'text' as const,
      text: 'OK',
    },
  ],
  details: { lines: 2 },
  is_error: false,
  timestamp: Date.now(),
};

const baseAssistantMessage = {
  __struct__: 'Elixir.Ai.Types.AssistantMessage',
  role: 'assistant' as const,
  content: [
    {
      __struct__: 'Elixir.Ai.Types.TextContent',
      type: 'text' as const,
      text: 'Hello',
    },
  ],
  provider: 'mock',
  model: 'mock-model',
  api: 'mock-api',
  usage: {
    input: 10,
    output: 5,
    total_tokens: 15,
  },
  stop_reason: 'stop' as const,
  error_message: null,
  timestamp: Date.now(),
};

describe('MessageCard', () => {
  it('renders tool result metadata', () => {
    render(<MessageCard message={baseToolMessage} />);

    expect(screen.getByText(/tool read/)).toBeInTheDocument();
    expect(screen.getByText('Success')).toBeInTheDocument();
    expect(screen.getByText(/details: 1/)).toBeInTheDocument();
  });

  it('renders assistant usage footer', () => {
    render(<MessageCard message={baseAssistantMessage} />);

    expect(screen.getByText(/tokens: 15/)).toBeInTheDocument();
    expect(screen.getByText(/input: 10/)).toBeInTheDocument();
    expect(screen.getByText(/output: 5/)).toBeInTheDocument();
  });
});
