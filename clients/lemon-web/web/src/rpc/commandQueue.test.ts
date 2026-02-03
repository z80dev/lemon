import { describe, it, expect, beforeEach, vi } from 'vitest';
import {
  CommandQueue,
  createQueuedMeta,
  isCommandExpired,
  isDestructiveCommand,
  hasSessionChanged,
  processQueueOnReconnect,
  MAX_QUEUE_LENGTH,
  DEFAULT_COMMAND_TTL_MS,
  DESTRUCTIVE_COMMANDS,
} from './commandQueue';
import type { ClientCommand } from '@lemon-web/shared';

describe('commandQueue', () => {
  describe('isDestructiveCommand', () => {
    it('returns true for abort command', () => {
      expect(isDestructiveCommand('abort')).toBe(true);
    });

    it('returns true for reset command', () => {
      expect(isDestructiveCommand('reset')).toBe(true);
    });

    it('returns true for close_session command', () => {
      expect(isDestructiveCommand('close_session')).toBe(true);
    });

    it('returns true for quit command', () => {
      expect(isDestructiveCommand('quit')).toBe(true);
    });

    it('returns false for prompt command', () => {
      expect(isDestructiveCommand('prompt')).toBe(false);
    });

    it('returns false for ping command', () => {
      expect(isDestructiveCommand('ping')).toBe(false);
    });
  });

  describe('isCommandExpired', () => {
    it('returns false for fresh command', () => {
      const meta = createQueuedMeta({ type: 'ping' }, null);
      expect(isCommandExpired(meta)).toBe(false);
    });

    it('returns true for expired command', () => {
      const meta = createQueuedMeta({ type: 'ping' }, null, 1000);
      const futureTime = Date.now() + 2000;
      expect(isCommandExpired(meta, futureTime)).toBe(true);
    });

    it('respects custom TTL', () => {
      const meta = createQueuedMeta({ type: 'ping' }, null, 60000);
      const slightlyFuture = Date.now() + 30000;
      expect(isCommandExpired(meta, slightlyFuture)).toBe(false);
    });
  });

  describe('hasSessionChanged', () => {
    it('returns false when both sessions are null', () => {
      const meta = createQueuedMeta({ type: 'ping' }, null);
      expect(hasSessionChanged(meta, null)).toBe(false);
    });

    it('returns false when session matches', () => {
      const meta = createQueuedMeta({ type: 'ping' }, 'session-123');
      expect(hasSessionChanged(meta, 'session-123')).toBe(false);
    });

    it('returns true when session changed', () => {
      const meta = createQueuedMeta({ type: 'ping' }, 'session-123');
      expect(hasSessionChanged(meta, 'session-456')).toBe(true);
    });

    it('returns false when original session was null', () => {
      const meta = createQueuedMeta({ type: 'ping' }, null);
      expect(hasSessionChanged(meta, 'session-123')).toBe(false);
    });

    it('returns false when current session is null', () => {
      const meta = createQueuedMeta({ type: 'ping' }, 'session-123');
      expect(hasSessionChanged(meta, null)).toBe(false);
    });
  });

  describe('createQueuedMeta', () => {
    it('creates metadata with correct command type', () => {
      const command: ClientCommand = { type: 'prompt', text: 'hello' };
      const meta = createQueuedMeta(command, 'session-123');

      expect(meta.commandType).toBe('prompt');
      expect(meta.sessionIdAtEnqueue).toBe('session-123');
      expect(meta.ttlMs).toBe(DEFAULT_COMMAND_TTL_MS);
      expect(JSON.parse(meta.payload)).toEqual(command);
    });

    it('allows custom TTL', () => {
      const meta = createQueuedMeta({ type: 'ping' }, null, 30000);
      expect(meta.ttlMs).toBe(30000);
    });
  });

  describe('processQueueOnReconnect', () => {
    it('sends non-destructive commands immediately', () => {
      const meta = createQueuedMeta({ type: 'ping' }, 'session-123');
      const result = processQueueOnReconnect([meta], 'session-456');

      expect(result.readyToSend).toHaveLength(1);
      expect(result.expired).toHaveLength(0);
      expect(result.needsConfirmation).toHaveLength(0);
    });

    it('marks expired commands', () => {
      const meta = createQueuedMeta({ type: 'ping' }, null, 1);
      const futureTime = Date.now() + 1000;
      const result = processQueueOnReconnect([meta], null, futureTime);

      expect(result.readyToSend).toHaveLength(0);
      expect(result.expired).toHaveLength(1);
      expect(result.needsConfirmation).toHaveLength(0);
    });

    it('requires confirmation for destructive commands with session change', () => {
      const meta = createQueuedMeta({ type: 'abort' }, 'session-123');
      const result = processQueueOnReconnect([meta], 'session-456');

      expect(result.readyToSend).toHaveLength(0);
      expect(result.expired).toHaveLength(0);
      expect(result.needsConfirmation).toHaveLength(1);
    });

    it('sends destructive commands without session change', () => {
      const meta = createQueuedMeta({ type: 'abort' }, 'session-123');
      const result = processQueueOnReconnect([meta], 'session-123');

      expect(result.readyToSend).toHaveLength(1);
      expect(result.expired).toHaveLength(0);
      expect(result.needsConfirmation).toHaveLength(0);
    });

    it('expires takes precedence over confirmation', () => {
      const meta = createQueuedMeta({ type: 'abort' }, 'session-123', 1);
      const futureTime = Date.now() + 1000;
      const result = processQueueOnReconnect([meta], 'session-456', futureTime);

      expect(result.readyToSend).toHaveLength(0);
      expect(result.expired).toHaveLength(1);
      expect(result.needsConfirmation).toHaveLength(0);
    });
  });

  describe('CommandQueue class', () => {
    let queue: CommandQueue;

    beforeEach(() => {
      queue = new CommandQueue();
    });

    it('starts with length 0', () => {
      expect(queue.length).toBe(0);
    });

    it('enqueues commands and updates length', () => {
      queue.enqueue({ type: 'ping' }, null);
      expect(queue.length).toBe(1);

      queue.enqueue({ type: 'ping' }, null);
      expect(queue.length).toBe(2);
    });

    it('notifies listeners on enqueue', () => {
      const listener = vi.fn();
      queue.subscribe(listener);

      // Called immediately with initial count
      expect(listener).toHaveBeenCalledWith(0);

      queue.enqueue({ type: 'ping' }, null);
      expect(listener).toHaveBeenCalledWith(1);
    });

    it('calls onOverflow when max length exceeded', () => {
      const onOverflow = vi.fn();

      // Fill the queue to max
      for (let i = 0; i < MAX_QUEUE_LENGTH; i++) {
        queue.enqueue({ type: 'ping' }, null);
      }

      expect(queue.length).toBe(MAX_QUEUE_LENGTH);
      expect(onOverflow).not.toHaveBeenCalled();

      // Add one more
      queue.enqueue({ type: 'ping' }, null, DEFAULT_COMMAND_TTL_MS, onOverflow);

      expect(queue.length).toBe(MAX_QUEUE_LENGTH);
      expect(onOverflow).toHaveBeenCalled();
    });

    it('processes queue on reconnect', () => {
      queue.enqueue({ type: 'ping' }, 'session-123');
      queue.enqueue({ type: 'abort' }, 'session-123');

      const readyToSend = queue.processOnReconnect('session-456');

      // ping should be ready, abort needs confirmation
      expect(readyToSend).toHaveLength(1);
      expect(readyToSend[0].commandType).toBe('ping');

      // abort should still be in queue awaiting confirmation
      expect(queue.length).toBe(1);
    });

    it('confirms pending commands', () => {
      queue.enqueue({ type: 'abort' }, 'session-123');
      queue.processOnReconnect('session-456');

      const pending = queue.getQueue()[0];
      const confirmed = queue.confirmCommand(pending, true);

      expect(confirmed).not.toBeNull();
      expect(queue.length).toBe(0);
    });

    it('rejects pending commands', () => {
      queue.enqueue({ type: 'abort' }, 'session-123');
      queue.processOnReconnect('session-456');

      const pending = queue.getQueue()[0];
      const result = queue.confirmCommand(pending, false);

      expect(result).toBeNull();
      expect(queue.length).toBe(0);
    });

    it('clears the queue', () => {
      queue.enqueue({ type: 'ping' }, null);
      queue.enqueue({ type: 'ping' }, null);
      expect(queue.length).toBe(2);

      queue.clear();
      expect(queue.length).toBe(0);
    });

    it('unsubscribes listeners', () => {
      const listener = vi.fn();
      const unsubscribe = queue.subscribe(listener);

      listener.mockClear();
      queue.enqueue({ type: 'ping' }, null);
      expect(listener).toHaveBeenCalled();

      listener.mockClear();
      unsubscribe();
      queue.enqueue({ type: 'ping' }, null);
      expect(listener).not.toHaveBeenCalled();
    });
  });

  describe('constants', () => {
    it('has correct MAX_QUEUE_LENGTH', () => {
      expect(MAX_QUEUE_LENGTH).toBe(200);
    });

    it('has correct DEFAULT_COMMAND_TTL_MS (5 minutes)', () => {
      expect(DEFAULT_COMMAND_TTL_MS).toBe(5 * 60 * 1000);
    });

    it('has correct DESTRUCTIVE_COMMANDS', () => {
      expect(DESTRUCTIVE_COMMANDS).toContain('abort');
      expect(DESTRUCTIVE_COMMANDS).toContain('reset');
      expect(DESTRUCTIVE_COMMANDS).toContain('close_session');
      expect(DESTRUCTIVE_COMMANDS).toContain('quit');
    });
  });
});
