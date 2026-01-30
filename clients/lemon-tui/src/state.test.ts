/**
 * Tests for the TUI state store.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { StateStore, type ToolExecution } from './state.js';
import type { UIRequestMessage, AssistantMessage, SessionEvent } from './types.js';

describe('StateStore', () => {
  let store: StateStore;

  beforeEach(() => {
    store = new StateStore();
  });

  describe('initial state', () => {
    it('should have empty pending UI requests queue', () => {
      expect(store.getState().pendingUIRequests).toEqual([]);
    });

    it('should have empty widgets map', () => {
      expect(store.getState().widgets.size).toBe(0);
    });

    it('should have empty status map', () => {
      expect(store.getState().status.size).toBe(0);
    });
  });

  describe('UI request queue', () => {
    const request1: UIRequestMessage = {
      type: 'ui_request',
      id: 'req-1',
      method: 'select',
      params: { title: 'Choose', options: [] },
    };

    const request2: UIRequestMessage = {
      type: 'ui_request',
      id: 'req-2',
      method: 'confirm',
      params: { title: 'Confirm?', message: 'Are you sure?' },
    };

    it('should enqueue UI requests', () => {
      store.enqueueUIRequest(request1);
      expect(store.getState().pendingUIRequests).toHaveLength(1);
      expect(store.getState().pendingUIRequests[0]).toEqual(request1);
    });

    it('should enqueue multiple requests in order', () => {
      store.enqueueUIRequest(request1);
      store.enqueueUIRequest(request2);
      expect(store.getState().pendingUIRequests).toHaveLength(2);
      expect(store.getState().pendingUIRequests[0].id).toBe('req-1');
      expect(store.getState().pendingUIRequests[1].id).toBe('req-2');
    });

    it('should get current UI request without removing it', () => {
      store.enqueueUIRequest(request1);
      store.enqueueUIRequest(request2);

      const current = store.getCurrentUIRequest();
      expect(current?.id).toBe('req-1');
      expect(store.getState().pendingUIRequests).toHaveLength(2);
    });

    it('should dequeue UI requests in FIFO order', () => {
      store.enqueueUIRequest(request1);
      store.enqueueUIRequest(request2);

      const first = store.dequeueUIRequest();
      expect(first?.id).toBe('req-1');
      expect(store.getState().pendingUIRequests).toHaveLength(1);

      const second = store.dequeueUIRequest();
      expect(second?.id).toBe('req-2');
      expect(store.getState().pendingUIRequests).toHaveLength(0);
    });

    it('should return undefined when dequeuing from empty queue', () => {
      const result = store.dequeueUIRequest();
      expect(result).toBeUndefined();
    });

    // Convenience methods
    it('should get pendingUIRequest as first item or null', () => {
      expect(store.pendingUIRequest).toBeNull();

      store.enqueueUIRequest(request1);
      expect(store.pendingUIRequest).toEqual(request1);

      store.enqueueUIRequest(request2);
      expect(store.pendingUIRequest).toEqual(request1); // Still first
    });

    it('should setPendingUIRequest to set a single request', () => {
      store.setPendingUIRequest(request1);
      expect(store.getState().pendingUIRequests).toHaveLength(1);
      expect(store.pendingUIRequest).toEqual(request1);
    });

    it('should setPendingUIRequest(null) to clear all requests', () => {
      store.enqueueUIRequest(request1);
      store.enqueueUIRequest(request2);
      expect(store.getState().pendingUIRequests).toHaveLength(2);

      store.setPendingUIRequest(null);
      expect(store.getState().pendingUIRequests).toHaveLength(0);
      expect(store.pendingUIRequest).toBeNull();
    });

    it('should setPendingUIRequest to replace existing requests', () => {
      store.enqueueUIRequest(request1);
      store.setPendingUIRequest(request2);

      expect(store.getState().pendingUIRequests).toHaveLength(1);
      expect(store.pendingUIRequest?.id).toBe('req-2');
    });
  });

  describe('widgets', () => {
    it('should set widget content', () => {
      store.setWidget('spinner', 'Loading...', { animated: true });

      const widgets = store.getState().widgets;
      expect(widgets.size).toBe(1);
      expect(widgets.get('spinner')).toEqual({
        content: 'Loading...',
        opts: { animated: true },
      });
    });

    it('should update existing widget', () => {
      store.setWidget('status', 'Initial');
      store.setWidget('status', 'Updated');

      expect(store.getState().widgets.get('status')?.content).toBe('Updated');
    });

    it('should remove widget when content is null', () => {
      store.setWidget('temp', 'Temporary');
      expect(store.getState().widgets.has('temp')).toBe(true);

      store.setWidget('temp', null);
      expect(store.getState().widgets.has('temp')).toBe(false);
    });

    it('should handle multiple widgets', () => {
      store.setWidget('a', 'Widget A');
      store.setWidget('b', 'Widget B');
      store.setWidget('c', 'Widget C');

      expect(store.getState().widgets.size).toBe(3);
    });
  });

  describe('status', () => {
    it('should set status value', () => {
      store.setStatus('model', 'gpt-4');
      expect(store.getState().status.get('model')).toBe('gpt-4');
    });

    it('should remove status when value is null', () => {
      store.setStatus('tokens', '1000');
      store.setStatus('tokens', null);
      expect(store.getState().status.has('tokens')).toBe(false);
    });

    it('should handle multiple status entries', () => {
      store.setStatus('model', 'claude');
      store.setStatus('tokens', '5000');
      store.setStatus('mode', 'chat');

      const status = store.getState().status;
      expect(status.size).toBe(3);
      expect(status.get('model')).toBe('claude');
      expect(status.get('tokens')).toBe('5000');
    });
  });

  describe('usage normalization', () => {
    it('should normalize usage with Lemon wire format fields', () => {
      const message: AssistantMessage = {
        __struct__: 'Elixir.Ai.Types.AssistantMessage',
        role: 'assistant',
        content: [{ __struct__: 'Elixir.Ai.Types.TextContent', type: 'text', text: 'Hello' }],
        provider: 'anthropic',
        model: 'claude-3',
        api: 'messages',
        usage: {
          input: 100,
          output: 50,
          cache_read: 25,
          cache_write: 10,
          total_tokens: 175,
          cost: {
            input_cost: 0.001,
            output_cost: 0.002,
            total_cost: 0.003,
          },
        },
        stop_reason: 'stop',
        error_message: null,
        timestamp: Date.now(),
      };

      // Simulate message_end event
      const event: SessionEvent = {
        type: 'message_end',
        data: [message],
      };

      store.handleEvent(event);

      const messages = store.getState().messages;
      expect(messages).toHaveLength(1);

      const normalized = messages[0];
      expect(normalized.type).toBe('assistant');
      if (normalized.type === 'assistant') {
        expect(normalized.usage).toEqual({
          inputTokens: 100,
          outputTokens: 50,
          cacheReadTokens: 25,
          cacheWriteTokens: 10,
          totalTokens: 175,
          totalCost: 0.003,
        });
      }
    });

    it('should handle missing usage gracefully', () => {
      const message: AssistantMessage = {
        __struct__: 'Elixir.Ai.Types.AssistantMessage',
        role: 'assistant',
        content: [],
        provider: 'anthropic',
        model: 'claude-3',
        api: 'messages',
        stop_reason: 'stop',
        error_message: null,
        timestamp: Date.now(),
      };

      const event: SessionEvent = {
        type: 'message_end',
        data: [message],
      };

      store.handleEvent(event);

      const messages = store.getState().messages;
      expect(messages).toHaveLength(1);
      if (messages[0].type === 'assistant') {
        expect(messages[0].usage).toBeUndefined();
      }
    });
  });

  describe('working messages', () => {
    it('should have initial null working messages', () => {
      const state = store.getState();
      expect(state.toolWorkingMessage).toBeNull();
      expect(state.agentWorkingMessage).toBeNull();
    });

    it('should set agent working message independently', () => {
      store.setAgentWorkingMessage('Summarizing branch...');
      expect(store.getState().agentWorkingMessage).toBe('Summarizing branch...');
      expect(store.getState().toolWorkingMessage).toBeNull();
    });

    it('should set tool working message independently', () => {
      store.setToolWorkingMessage('Running bash...');
      expect(store.getState().toolWorkingMessage).toBe('Running bash...');
      expect(store.getState().agentWorkingMessage).toBeNull();
    });

    it('should return agent message as priority in getWorkingMessage', () => {
      store.setToolWorkingMessage('Running bash...');
      store.setAgentWorkingMessage('Summarizing branch...');

      expect(store.getWorkingMessage()).toBe('Summarizing branch...');
    });

    it('should fall back to tool message when no agent message', () => {
      store.setToolWorkingMessage('Running bash...');

      expect(store.getWorkingMessage()).toBe('Running bash...');
    });

    it('should not clear agent message when tool ends', () => {
      store.setAgentWorkingMessage('Summarizing branch...');

      // Simulate tool lifecycle
      store.handleEvent({
        type: 'tool_execution_start',
        data: ['tool-1', 'bash', {}],
      });
      expect(store.getState().toolWorkingMessage).toBe('Running bash...');
      expect(store.getState().agentWorkingMessage).toBe('Summarizing branch...');

      store.handleEvent({
        type: 'tool_execution_end',
        data: ['tool-1', 'bash', 'output', false],
      });

      // Tool message should be cleared, but agent message preserved
      expect(store.getState().toolWorkingMessage).toBeNull();
      expect(store.getState().agentWorkingMessage).toBe('Summarizing branch...');
      expect(store.getWorkingMessage()).toBe('Summarizing branch...');
    });

    it('should legacy setWorkingMessage set agent message', () => {
      store.setWorkingMessage('Test message');
      expect(store.getState().agentWorkingMessage).toBe('Test message');
    });
  });

  describe('tool executions', () => {
    it('should track tool start', () => {
      const event: SessionEvent = {
        type: 'tool_execution_start',
        data: ['tool-1', 'read_file', { path: '/test.txt' }],
      };

      store.handleEvent(event);

      const tools = store.getState().toolExecutions;
      expect(tools.size).toBe(1);

      const tool = tools.get('tool-1');
      expect(tool?.name).toBe('read_file');
      expect(tool?.args).toEqual({ path: '/test.txt' });
      expect(tool?.endTime).toBeUndefined();
    });

    it('should track tool update with partial result', () => {
      store.handleEvent({
        type: 'tool_execution_start',
        data: ['tool-1', 'bash', { command: 'ls' }],
      });

      store.handleEvent({
        type: 'tool_execution_update',
        data: ['tool-1', 'bash', { command: 'ls' }, 'file1.txt\n'],
      });

      const tool = store.getState().toolExecutions.get('tool-1');
      expect(tool?.partialResult).toBe('file1.txt\n');
    });

    it('should track tool end', () => {
      store.handleEvent({
        type: 'tool_execution_start',
        data: ['tool-1', 'bash', {}],
      });

      store.handleEvent({
        type: 'tool_execution_end',
        data: ['tool-1', 'bash', 'output', false],
      });

      const tool = store.getState().toolExecutions.get('tool-1');
      expect(tool?.result).toBe('output');
      expect(tool?.isError).toBe(false);
      expect(tool?.endTime).toBeDefined();
    });

    it('should track tool error', () => {
      store.handleEvent({
        type: 'tool_execution_start',
        data: ['tool-1', 'bash', {}],
      });

      store.handleEvent({
        type: 'tool_execution_end',
        data: ['tool-1', 'bash', 'command not found', true],
      });

      const tool = store.getState().toolExecutions.get('tool-1');
      expect(tool?.isError).toBe(true);
    });
  });

  describe('state listeners', () => {
    it('should notify listeners on state change', () => {
      let notified = false;
      let receivedState: any = null;

      store.subscribe((state, prevState) => {
        notified = true;
        receivedState = state;
      });

      store.setStatus('test', 'value');

      expect(notified).toBe(true);
      expect(receivedState?.status.get('test')).toBe('value');
    });

    it('should allow unsubscribing', () => {
      let callCount = 0;

      const unsubscribe = store.subscribe(() => {
        callCount++;
      });

      store.setStatus('a', '1');
      expect(callCount).toBe(1);

      unsubscribe();

      store.setStatus('b', '2');
      expect(callCount).toBe(1); // Should not increment
    });
  });

  describe('reset', () => {
    it('should reset all state including new fields', () => {
      store.setStatus('model', 'test');
      store.setWidget('spinner', 'Loading');
      store.enqueueUIRequest({
        type: 'ui_request',
        id: 'req',
        method: 'confirm',
        params: { title: 'Test', message: 'Test' },
      });

      store.reset();

      const state = store.getState();
      expect(state.status.size).toBe(0);
      expect(state.widgets.size).toBe(0);
      expect(state.pendingUIRequests).toHaveLength(0);
    });
  });
});
