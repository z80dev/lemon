/**
 * Command queue with offline/disconnected semantics.
 *
 * Features:
 * - Max queue length (200) with oldest-drop policy
 * - Per-command metadata: timestamp, TTL, session_id at enqueue time
 * - Stale command expiration on reconnect
 * - Destructive command confirmation for stale/session-changed commands
 */

import type { ClientCommand } from '@lemon-web/shared';

/** Default TTL for queued commands (5 minutes) */
export const DEFAULT_COMMAND_TTL_MS = 5 * 60 * 1000;

/** Maximum queue length before dropping oldest commands */
export const MAX_QUEUE_LENGTH = 200;

/** Commands that are considered destructive and require confirmation when stale */
export const DESTRUCTIVE_COMMANDS: readonly string[] = [
  'abort',
  'reset',
  'close_session',
  'quit',
] as const;

/** Metadata attached to each queued command */
export interface QueuedCommandMeta {
  /** Original command payload (JSON string) */
  payload: string;
  /** Timestamp when command was queued */
  enqueuedAt: number;
  /** TTL in milliseconds */
  ttlMs: number;
  /** Session ID that was active when command was queued */
  sessionIdAtEnqueue: string | null;
  /** Parsed command type for quick access */
  commandType: string;
}

/** Result of processing queue on reconnect */
export interface QueueProcessResult {
  /** Commands ready to send immediately */
  readyToSend: QueuedCommandMeta[];
  /** Commands that expired (stale) */
  expired: QueuedCommandMeta[];
  /** Destructive commands that need confirmation */
  needsConfirmation: QueuedCommandMeta[];
}

/** Reason a command needs attention */
export type CommandWarningReason = 'expired' | 'session_changed' | 'stale_destructive';

/** Warning info for a command */
export interface CommandWarning {
  command: QueuedCommandMeta;
  reason: CommandWarningReason;
  message: string;
}

/**
 * Check if a command type is destructive
 */
export function isDestructiveCommand(commandType: string): boolean {
  return DESTRUCTIVE_COMMANDS.includes(commandType);
}

/**
 * Check if a command has expired based on its TTL
 */
export function isCommandExpired(meta: QueuedCommandMeta, now: number = Date.now()): boolean {
  return now - meta.enqueuedAt > meta.ttlMs;
}

/**
 * Check if session has changed since command was queued
 */
export function hasSessionChanged(
  meta: QueuedCommandMeta,
  currentSessionId: string | null
): boolean {
  // If command was queued without a session, or current has no session, no change
  if (meta.sessionIdAtEnqueue === null || currentSessionId === null) {
    return false;
  }
  return meta.sessionIdAtEnqueue !== currentSessionId;
}

/**
 * Create metadata for a command being queued
 */
export function createQueuedMeta(
  command: ClientCommand,
  sessionId: string | null,
  ttlMs: number = DEFAULT_COMMAND_TTL_MS
): QueuedCommandMeta {
  return {
    payload: JSON.stringify(command),
    enqueuedAt: Date.now(),
    ttlMs,
    sessionIdAtEnqueue: sessionId,
    commandType: command.type,
  };
}

/**
 * Process the queue on reconnect, categorizing commands
 */
export function processQueueOnReconnect(
  queue: QueuedCommandMeta[],
  currentSessionId: string | null,
  now: number = Date.now()
): QueueProcessResult {
  const result: QueueProcessResult = {
    readyToSend: [],
    expired: [],
    needsConfirmation: [],
  };

  for (const meta of queue) {
    const expired = isCommandExpired(meta, now);
    const sessionChanged = hasSessionChanged(meta, currentSessionId);
    const isDestructive = isDestructiveCommand(meta.commandType);

    if (expired) {
      result.expired.push(meta);
    } else if (isDestructive && sessionChanged) {
      // Destructive command with session change needs confirmation
      result.needsConfirmation.push(meta);
    } else {
      result.readyToSend.push(meta);
    }
  }

  return result;
}

/**
 * Get warnings for commands that need attention
 */
export function getCommandWarnings(
  queue: QueuedCommandMeta[],
  currentSessionId: string | null,
  now: number = Date.now()
): CommandWarning[] {
  const warnings: CommandWarning[] = [];

  for (const meta of queue) {
    const expired = isCommandExpired(meta, now);
    const sessionChanged = hasSessionChanged(meta, currentSessionId);
    const isDestructive = isDestructiveCommand(meta.commandType);

    if (expired) {
      warnings.push({
        command: meta,
        reason: 'expired',
        message: `Command "${meta.commandType}" expired (queued ${formatAge(meta.enqueuedAt, now)} ago)`,
      });
    } else if (isDestructive && sessionChanged) {
      warnings.push({
        command: meta,
        reason: 'stale_destructive',
        message: `Destructive command "${meta.commandType}" was queued for a different session`,
      });
    } else if (sessionChanged) {
      warnings.push({
        command: meta,
        reason: 'session_changed',
        message: `Command "${meta.commandType}" was queued for session ${meta.sessionIdAtEnqueue?.slice(0, 8)}...`,
      });
    }
  }

  return warnings;
}

/**
 * Format age in human readable form
 */
function formatAge(enqueuedAt: number, now: number): string {
  const ageMs = now - enqueuedAt;
  const seconds = Math.floor(ageMs / 1000);
  const minutes = Math.floor(seconds / 60);

  if (minutes > 0) {
    return `${minutes}m ${seconds % 60}s`;
  }
  return `${seconds}s`;
}

/**
 * CommandQueue class for managing the queue state
 */
export class CommandQueue {
  private queue: QueuedCommandMeta[] = [];
  private listeners: Set<(count: number) => void> = new Set();

  /** Get current queue length */
  get length(): number {
    return this.queue.length;
  }

  /** Get a copy of the current queue */
  getQueue(): QueuedCommandMeta[] {
    return [...this.queue];
  }

  /**
   * Enqueue a command with metadata
   * Returns true if command was added, false if it replaced an old command due to max length
   */
  enqueue(
    command: ClientCommand,
    sessionId: string | null,
    ttlMs: number = DEFAULT_COMMAND_TTL_MS,
    onOverflow?: (dropped: QueuedCommandMeta) => void
  ): boolean {
    const meta = createQueuedMeta(command, sessionId, ttlMs);
    let droppedOldest = false;

    // Check max length and drop oldest if needed
    if (this.queue.length >= MAX_QUEUE_LENGTH) {
      const dropped = this.queue.shift();
      if (dropped && onOverflow) {
        onOverflow(dropped);
      }
      droppedOldest = true;
    }

    this.queue.push(meta);
    this.notifyListeners();
    return !droppedOldest;
  }

  /**
   * Process queue on reconnect
   */
  processOnReconnect(
    currentSessionId: string | null,
    onExpired?: (commands: QueuedCommandMeta[]) => void,
    onNeedsConfirmation?: (commands: QueuedCommandMeta[]) => void
  ): QueuedCommandMeta[] {
    const result = processQueueOnReconnect(this.queue, currentSessionId);

    // Notify about expired commands
    if (result.expired.length > 0 && onExpired) {
      onExpired(result.expired);
    }

    // Notify about commands needing confirmation
    if (result.needsConfirmation.length > 0 && onNeedsConfirmation) {
      onNeedsConfirmation(result.needsConfirmation);
    }

    // Keep only commands that need confirmation (user will decide)
    // Ready commands will be returned to send
    this.queue = result.needsConfirmation;
    this.notifyListeners();

    return result.readyToSend;
  }

  /**
   * Confirm or reject a pending command
   */
  confirmCommand(meta: QueuedCommandMeta, confirmed: boolean): QueuedCommandMeta | null {
    const index = this.queue.findIndex(
      (m) => m.payload === meta.payload && m.enqueuedAt === meta.enqueuedAt
    );

    if (index === -1) {
      return null;
    }

    const [removed] = this.queue.splice(index, 1);
    this.notifyListeners();

    return confirmed ? removed : null;
  }

  /**
   * Clear all commands from queue
   */
  clear(): void {
    this.queue = [];
    this.notifyListeners();
  }

  /**
   * Subscribe to queue count changes
   */
  subscribe(listener: (count: number) => void): () => void {
    this.listeners.add(listener);
    // Immediately notify with current count
    listener(this.queue.length);

    return () => {
      this.listeners.delete(listener);
    };
  }

  private notifyListeners(): void {
    const count = this.queue.length;
    for (const listener of this.listeners) {
      listener(count);
    }
  }
}

/** Singleton command queue instance */
export const commandQueue = new CommandQueue();
