import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Text } from '@mariozechner/pi-tui';
import type { NormalizedToolResultMessage } from './state.js';
import { MessageRenderer } from './message-renderer.js';
import { ansi, setTheme } from './theme.js';

function createRenderer(): MessageRenderer {
  return new MessageRenderer({
    isToolPanelCollapsed: () => false,
  });
}

function createToolResultMessage(
  overrides: Partial<NormalizedToolResultMessage> = {}
): NormalizedToolResultMessage {
  return {
    id: 'tool_1',
    type: 'tool_result',
    toolCallId: 'call_1',
    toolName: 'read',
    content: 'ok',
    images: [],
    trust: 'trusted',
    trustMetadata: null,
    isTrusted: true,
    isError: false,
    timestamp: 1,
    ...overrides,
  };
}

describe('MessageRenderer tool_result trust rendering', () => {
  beforeEach(() => {
    setTheme('lemon');
  });

  afterEach(() => {
    setTheme('lemon');
  });

  it('keeps trusted rendering unchanged', () => {
    const renderer = createRenderer();
    const component = renderer.createMessageComponent(createToolResultMessage());

    expect(component).toBeInstanceOf(Text);
    const lines = (component as Text).render(120).join('\n');

    expect(lines).toContain(ansi.secondary('[read] ok'));
    expect(lines).not.toContain('[untrusted]');
  });

  it('keeps error rendering unchanged for trusted tool results', () => {
    const renderer = createRenderer();
    const component = renderer.createMessageComponent(
      createToolResultMessage({
        content: 'failed',
        isError: true,
      })
    );

    expect(component).toBeInstanceOf(Text);
    const lines = (component as Text).render(120).join('\n');

    expect(lines).toContain(ansi.error('[read] failed'));
    expect(lines).not.toContain('[untrusted]');
  });

  it('renders explicit untrusted indicator for untrusted tool results', () => {
    const renderer = createRenderer();
    const component = renderer.createMessageComponent(
      createToolResultMessage({
        trust: 'untrusted',
        isTrusted: false,
      })
    );

    expect(component).toBeInstanceOf(Text);
    const lines = (component as Text).render(120).join('\n');

    expect(lines).toContain(ansi.secondary('[read] [untrusted] ok'));
  });
});
