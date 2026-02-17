/**
 * Message rendering for Lemon TUI.
 *
 * Handles rendering of messages (user, assistant, tool results) into
 * pi-tui components for display in the messages container.
 */

import {
  Markdown,
  Text,
  Container,
  Image,
  type Component,
} from '@mariozechner/pi-tui';
import type {
  NormalizedMessage,
  NormalizedAssistantMessage,
  NormalizedToolResultMessage,
} from './state.js';
import { ansi } from './theme.js';
import { markdownTheme, imageTheme } from './component-themes.js';
import { defaultRegistry } from './formatters/index.js';

/**
 * Configuration for the MessageRenderer.
 */
export interface MessageRendererConfig {
  /**
   * Function that returns the current tool panel collapsed state.
   */
  isToolPanelCollapsed: () => boolean;
}

/**
 * Handles rendering of conversation messages into pi-tui components.
 */
export class MessageRenderer {
  private config: MessageRendererConfig;

  constructor(config: MessageRendererConfig) {
    this.config = config;
  }

  /**
   * Creates a pi-tui component from a normalized message.
   */
  createMessageComponent(message: NormalizedMessage): Component {
    switch (message.type) {
      case 'user':
        return new Markdown(`${ansi.primary(ansi.bold('You:'))}\n${message.content}`, 1, 1, markdownTheme);

      case 'assistant': {
        const assistant = message as NormalizedAssistantMessage;
        const lines: string[] = [];

        lines.push(ansi.success(ansi.bold('Assistant:')));

        // Thinking (if any, shown dimmed)
        if (assistant.thinkingContent) {
          lines.push(ansi.dim(ansi.italic('[thinking]')));
          lines.push(ansi.muted(assistant.thinkingContent.slice(0, 200) + '...'));
          lines.push('');
        }

        // Main content
        if (assistant.textContent) {
          lines.push(assistant.textContent);
        }

        // Tool calls
        for (const tool of assistant.toolCalls) {
          lines.push(`${ansi.warning('->')} ${tool.name}`);
        }

        // Streaming indicator
        if (assistant.isStreaming) {
          lines.push(ansi.muted('...'));
        }

        // Stop reason indicator (only for non-normal completions)
        if (!assistant.isStreaming && assistant.stopReason) {
          if (assistant.stopReason === 'length') {
            lines.push(ansi.warning('[truncated]'));
          } else if (assistant.stopReason === 'error') {
            lines.push(ansi.error('[error]'));
          } else if (assistant.stopReason === 'aborted') {
            lines.push(ansi.error('[aborted]'));
          }
          // 'stop' and 'tool_use' are normal - don't show anything
        }

        return new Markdown(lines.join('\n'), 1, 1, markdownTheme);
      }

      case 'tool_result': {
        const toolResult = message as NormalizedToolResultMessage;
        const colorFn = toolResult.isError ? ansi.error : ansi.secondary;
        const untrustedIndicator = toolResult.trust === 'untrusted' ? ' [untrusted]' : '';
        const label = `[${toolResult.toolName}]${untrustedIndicator}`;
        const content = toolResult.content.length > 500
          ? toolResult.content.slice(0, 500) + '...'
          : toolResult.content;

        // If there are no images, return a simple Text component
        if (!toolResult.images || toolResult.images.length === 0) {
          return new Text(colorFn(`${label} ${content}`), 1, 1);
        }

        // Otherwise, use a Container to render text and images
        const container = new Container();

        // Add text content first
        if (content) {
          container.addChild(new Text(colorFn(`${label} ${content}`), 1, 1));
        } else {
          container.addChild(new Text(colorFn(label), 1, 0));
        }

        // Add each image
        for (const img of toolResult.images) {
          const imageComponent = new Image(img.data, img.mimeType, imageTheme, {
            maxWidthCells: 80,
            maxHeightCells: 40,
          });
          container.addChild(imageComponent);
        }

        return container;
      }
    }
  }

  /**
   * Renders all messages to the given container.
   *
   * @param messagesContainer - The container to render messages into
   * @param messages - Array of normalized messages to render
   * @param streamingMessage - Optional currently streaming message
   * @returns The streaming component if a streaming message was rendered
   */
  renderMessages(
    messagesContainer: Container,
    messages: NormalizedMessage[],
    streamingMessage: NormalizedAssistantMessage | null
  ): Component | null {
    const showToolResults = !this.config.isToolPanelCollapsed();

    messagesContainer.clear();

    let prevType: string | null = null;
    for (const msg of messages) {
      if (msg.type === 'tool_result' && !showToolResults) {
        continue;
      }
      // Add separator between turns (user→assistant or assistant→user)
      const isNewTurn =
        prevType !== null &&
        ((prevType === 'user' && msg.type === 'assistant') ||
          (prevType === 'assistant' && msg.type === 'user') ||
          (prevType === 'tool_result' && msg.type === 'user'));
      if (isNewTurn) {
        const sep = ansi.muted('─── ─── ─── ─── ───');
        messagesContainer.addChild(new Text(sep, 1, 0));
      }

      const component = this.createMessageComponent(msg);
      messagesContainer.addChild(component);
      prevType = msg.type;
    }

    let streamingComponent: Component | null = null;
    if (streamingMessage) {
      // Separator before streaming if previous was a user message
      if (prevType === 'user') {
        const sep = ansi.muted('─── ─── ─── ─── ───');
        messagesContainer.addChild(new Text(sep, 1, 0));
      }
      streamingComponent = this.createMessageComponent(streamingMessage);
      messagesContainer.addChild(streamingComponent);
    }

    return streamingComponent;
  }

  /**
   * Updates the streaming message in the container.
   *
   * @param messagesContainer - The container holding messages
   * @param currentStreamingComponent - The current streaming component (if any)
   * @param message - The new streaming message (or null to clear)
   * @returns The new streaming component (or null if cleared)
   */
  updateStreamingMessage(
    messagesContainer: Container,
    currentStreamingComponent: Component | null,
    message: NormalizedAssistantMessage | null
  ): Component | null {
    if (message) {
      if (currentStreamingComponent) {
        messagesContainer.removeChild(currentStreamingComponent);
      }
      const newComponent = this.createMessageComponent(message);
      messagesContainer.addChild(newComponent);
      return newComponent;
    } else {
      if (currentStreamingComponent) {
        messagesContainer.removeChild(currentStreamingComponent);
      }
      return null;
    }
  }

  // ============================================================================
  // Tool Formatting Helpers
  // ============================================================================

  /**
   * Formats tool arguments for display.
   */
  formatToolArgs(args: Record<string, unknown>, toolName?: string): string {
    if (toolName) {
      const output = defaultRegistry.formatArgs(toolName, args);
      return this.truncateInline(output.summary, 200);
    }
    // Fallback to existing logic
    if (!args || Object.keys(args).length === 0) {
      return '';
    }
    const json = this.safeStringify(args);
    return this.truncateInline(json, 200);
  }

  /**
   * Formats tool result for display.
   */
  formatToolResult(result: unknown, toolName?: string, args?: Record<string, unknown>): string {
    if (toolName) {
      const output = defaultRegistry.formatResult(toolName, result, args);
      // Return details joined, or summary if no details
      if (output.details.length > 0) {
        return output.details.join('\n');
      }
      return output.summary;
    }
    // Fallback to existing logic
    const text = this.extractToolText(result);
    if (text) {
      return this.truncateMultiline(text, 6, 600);
    }
    const json = this.safeStringify(result);
    return this.truncateMultiline(json, 6, 600);
  }

  /**
   * Extracts text content from a tool result.
   */
  extractToolText(result: unknown): string {
    if (result === null || result === undefined) {
      return '';
    }
    if (typeof result === 'string') {
      return result;
    }
    if (typeof result === 'number' || typeof result === 'boolean') {
      return String(result);
    }
    if (Array.isArray(result)) {
      return this.extractTextFromContentBlocks(result);
    }
    if (typeof result === 'object') {
      const record = result as { content?: unknown; details?: unknown };
      const contentText = this.extractTextFromContentBlocks(record.content);
      if (contentText) {
        return contentText;
      }
      if (record.details !== undefined) {
        const detailsText = this.safeStringify(record.details);
        return detailsText ? `details: ${detailsText}` : '';
      }
    }
    return '';
  }

  /**
   * Extracts text from content blocks (commonly used in tool results).
   */
  extractTextFromContentBlocks(content: unknown): string {
    if (!Array.isArray(content)) {
      return '';
    }
    const parts: string[] = [];
    let imageCount = 0;
    for (const block of content) {
      if (!block || typeof block !== 'object') {
        continue;
      }
      const type = (block as { type?: string }).type;
      if (type === 'text') {
        const text = (block as { text?: string }).text ?? '';
        if (text) parts.push(text);
      } else if (type === 'image') {
        imageCount += 1;
      }
    }
    if (imageCount > 0) {
      parts.push(`[${imageCount} image${imageCount === 1 ? '' : 's'}]`);
    }
    return parts.join('');
  }

  /**
   * Safely stringifies a value, handling circular references.
   */
  safeStringify(value: unknown): string {
    try {
      const seen = new WeakSet();
      return JSON.stringify(
        value,
        (_key, val) => {
          if (typeof val === 'object' && val !== null) {
            if (seen.has(val)) {
              return '[Circular]';
            }
            seen.add(val);
          }
          return val;
        },
        0
      );
    } catch {
      try {
        return String(value);
      } catch {
        return '[unserializable]';
      }
    }
  }

  /**
   * Truncates text to a maximum number of characters on a single line.
   */
  truncateInline(text: string, maxChars: number): string {
    if (text.length <= maxChars) {
      return text;
    }
    return `${text.slice(0, maxChars)}...`;
  }

  /**
   * Truncates text to a maximum number of lines and characters.
   */
  truncateMultiline(text: string, maxLines: number, maxChars: number): string {
    const normalized = text.length > maxChars ? `${text.slice(0, maxChars)}...` : text;
    const lines = normalized.split(/\r?\n/);
    if (lines.length <= maxLines) {
      return normalized;
    }
    const remaining = lines.length - maxLines;
    return `${lines.slice(0, maxLines).join('\n')}\n... (${remaining} more lines)`;
  }
}
