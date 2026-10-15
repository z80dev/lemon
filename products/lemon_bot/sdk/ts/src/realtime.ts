import type { Cursor, RealtimeClientFrame, RealtimeEvent, RealtimeServerFrame, Snapshot } from '../../../contracts/protocol.ts';
import { LemonBotError, localError } from './errors.ts';

export type RealtimeState = 'connecting' | 'authenticating' | 'syncing' | 'replaying' | 'live'
  | 'reconnecting' | 'unauthenticated' | 'forbidden' | 'error' | 'closed';
export interface RealtimeOptions {
  deviceId?: string;
  cursor?: Cursor;
  onEvent: (event: RealtimeEvent) => void | Promise<void>;
  onFrame?: (frame: RealtimeServerFrame) => void | Promise<void>;
  onState?: (state: RealtimeState, error?: unknown) => void;
  /** Replace derived state and fetch required pages/history before returning. */
  onReset: () => Promise<Snapshot>;
  saveCursor?: (cursor: Cursor) => void | Promise<void>;
  /** Test/host transport seam. The URL never contains a credential. */
  webSocket?: (url: string) => WebSocket;
  reconnectDelayMs?: number;
}

export function compareCursors(left: Cursor, right: Cursor): -1 | 0 | 1 {
  if (!/^\d+$/.test(left) || !/^\d+$/.test(right)) throw localError('invalid_request', 'Realtime cursors must be unsigned decimal strings.');
  const a = BigInt(left);
  const b = BigInt(right);
  return a < b ? -1 : a > b ? 1 : 0;
}

/** Ordered apply → persist → ack. Only subscriptions/pings can resume automatically. */
export class RealtimeConnection {
  private socket: WebSocket | null = null;
  private readonly listeners = new Set<(frame: RealtimeServerFrame) => void>();
  private readonly terminals = new Map<string, number>();
  private queue: Promise<void> = Promise.resolve();
  private generation = 0;
  private running = false;
  private authenticated = false;
  private subscribed = false;
  private subscriptionId: string | null = null;
  private selection: string[] | undefined;
  private safeCursor?: Cursor;
  private currentState: RealtimeState = 'closed';
  private reconnectTimer?: number;
  private retryAt: number | null = null;
  private deadline?: number;
  private heartbeat?: number;
  private liveness?: number;
  private pendingPing: string | null = null;
  private attempts = 0;

  constructor(private readonly baseUrl: string, private readonly token: string | undefined,
    private readonly options: RealtimeOptions) {
    if (options.cursor !== undefined) compareCursors(options.cursor, '0');
    this.safeCursor = options.cursor;
  }

  get state(): RealtimeState { return this.currentState; }
  get cursor(): Cursor | undefined { return this.safeCursor; }
  /** Scheduled reconnect deadline, or null while connecting/live/closed. */
  get nextRetryAtMs(): number | null { return this.retryAt; }

  start(): void {
    if (this.running) return;
    if (!this.token) {
      this.setState('unauthenticated', localError('unauthenticated', 'A product session is required for realtime.'));
      return;
    }
    this.running = true;
    this.connect();
  }

  close(): void {
    this.running = false;
    this.generation++;
    this.clearTimers();
    clearTimeout(this.reconnectTimer);
    this.reconnectTimer = undefined;
    this.retryAt = null;
    this.socket?.close(1000, 'Client closed');
    this.socket = null;
    this.authenticated = false;
    this.subscribed = false;
    this.terminals.clear();
    this.setState('closed');
  }

  subscribe(listener: (frame: RealtimeServerFrame) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  /** Sends now or throws. Voice, typing, presence and terminal input are never queued. */
  send(frame: RealtimeClientFrame): void {
    if (!this.authenticated || !this.socket || this.socket.readyState !== 1) {
      throw localError('upstream_unavailable', 'Realtime is not authenticated; no command was queued.');
    }
    if (frame.type === 'auth') throw localError('invalid_request', 'Authentication is managed by the realtime connection.');
    if (frame.type === 'subscribe') {
      if (frame.cursor === undefined || this.safeCursor === undefined || compareCursors(frame.cursor, this.safeCursor) > 0) {
        throw localError('invalid_request', 'Subscription changes require a previously applied snapshot cursor.');
      }
      this.selection = frame.conversationIds;
      this.subscriptionId = frame.requestId;
      this.subscribed = false;
      this.setState('replaying');
      this.armDeadline(10000, 'Subscription acknowledgement timed out.');
    } else if (frame.type === 'ack') {
      if (!this.safeCursor || compareCursors(frame.cursor, this.safeCursor) > 0) {
        throw localError('invalid_request', 'Cannot acknowledge unapplied events.');
      }
    } else if (frame.type === 'terminal_subscribe') {
      this.terminals.set(frame.terminalId, frame.afterSeq ?? 0);
    } else if (!this.subscribed) {
      throw localError('upstream_unavailable', 'Realtime subscription is not ready; no command was queued.');
    }
    this.socket.send(JSON.stringify(frame));
  }

  private connect(): void {
    if (!this.running) return;
    const generation = ++this.generation;
    this.authenticated = false;
    this.subscribed = false;
    this.subscriptionId = null;
    this.setState(this.attempts ? 'reconnecting' : 'connecting');
    const url = new URL(`${this.baseUrl}/realtime`);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    let socket: WebSocket;
    try { socket = this.options.webSocket ? this.options.webSocket(url.href) : new WebSocket(url.href); }
    catch (error) { this.scheduleReconnect(error); return; }
    this.socket = socket;
    this.armDeadline(5000, 'Realtime authentication timed out.');
    socket.addEventListener('open', () => {
      if (generation !== this.generation || !this.running) return;
      this.setState('authenticating');
      socket.send(JSON.stringify({ type: 'auth', token: this.token, ...(this.options.deviceId ? { deviceId: this.options.deviceId } : {}) }));
    });
    socket.addEventListener('message', message => {
      if (generation !== this.generation || !this.running) return;
      if (this.authenticated) this.armLiveness();
      this.queue = this.queue.then(async () => {
        if (generation !== this.generation || !this.running) return;
        if (typeof message.data !== 'string' || new TextEncoder().encode(message.data).byteLength > 1024 * 1024) {
          throw localError('invalid_request', 'Realtime requires bounded UTF-8 JSON frames.');
        }
        const frame: RealtimeServerFrame = JSON.parse(message.data);
        await this.apply(frame, generation);
      }).catch(error => {
        if (generation === this.generation && this.running) this.fail(error);
      });
    });
    socket.addEventListener('close', event => {
      if (generation !== this.generation || !this.running) return;
      this.socket = null;
      this.authenticated = false;
      this.subscribed = false;
      this.clearTimers();
      if (event.code === 4401 || event.code === 4403) {
        this.running = false;
        this.generation++;
        this.setState(event.code === 4401 ? 'unauthenticated' : 'forbidden', localError(event.code === 4401 ? 'unauthenticated' : 'forbidden', 'Realtime access was revoked or expired.'));
      } else if ([4400, 1009].includes(event.code)) {
        this.running = false;
        this.generation++;
        this.setState('error', localError('invalid_request', 'Backend rejected the realtime protocol or frame size.'));
      } else {
        this.generation++;
        this.scheduleReconnect(localError('upstream_unavailable', 'Realtime disconnected; resuming from the last applied cursor.'));
      }
    });
    // Close drives reconnect. Browser error events intentionally contain no secrets or invented result.
    socket.addEventListener('error', () => {
      if (generation === this.generation && this.running) this.fail(localError('upstream_unavailable', 'Realtime transport failed.'));
    });
  }

  private async apply(frame: RealtimeServerFrame, generation: number): Promise<void> {
    if (!frame || typeof frame !== 'object' || typeof frame.type !== 'string') throw localError('invalid_request', 'Invalid realtime frame.');
    if (frame.type === 'ready') {
      if (this.authenticated) throw localError('invalid_request', 'Duplicate authentication acknowledgement.');
      compareCursors(frame.cursor, frame.earliestCursor);
      if (!Number.isFinite(frame.heartbeatMs) || frame.heartbeatMs <= 0) throw localError('invalid_request', 'Invalid heartbeat interval.');
      this.authenticated = true;
      clearTimeout(this.deadline);
      this.armLiveness();
      this.heartbeat = Number(setInterval(() => {
        if (generation !== this.generation || !this.running || !this.socket) return;
        if (!this.pendingPing) {
          this.pendingPing = crypto.randomUUID();
          this.socket.send(JSON.stringify({ type: 'ping', requestId: this.pendingPing }));
        }
      }, Math.min(frame.heartbeatMs, 25000)));
      if (this.safeCursor === undefined || compareCursors(this.safeCursor, frame.cursor) > 0) await this.reset(generation);
      if (generation !== this.generation || !this.running) return;
      this.beginSubscription();
    } else {
      if (!this.authenticated) throw localError('unauthenticated', 'Received a realtime frame before authentication.');
      if (frame.type === 'subscribed') {
        if (frame.requestId !== this.subscriptionId) return;
        clearTimeout(this.deadline);
        compareCursors(frame.cursor, '0');
        this.subscribed = true;
      } else if (frame.type === 'event') {
        if (!this.subscribed || this.safeCursor === undefined) throw localError('invalid_request', 'Received events before correlated subscription acknowledgement.');
        if (compareCursors(frame.seq, this.safeCursor) <= 0) return;
        await this.options.onEvent(frame);
        await this.notify(frame);
        if (generation !== this.generation || !this.running) return;
        await this.advance(frame.seq, generation);
        return;
      } else if (frame.type === 'caught_up' || frame.type === 'watermark') {
        if (!this.subscribed) throw localError('invalid_request', 'Received a watermark before subscription acknowledgement.');
        await this.notify(frame);
        if (generation !== this.generation || !this.running) return;
        await this.advance(frame.cursor, generation);
        if (frame.type === 'caught_up') {
          this.attempts = 0;
          this.setState('live');
          for (const [terminalId, afterSeq] of this.terminals) {
            this.socket?.send(JSON.stringify({ type: 'terminal_subscribe', terminalId, afterSeq }));
          }
        }
        return;
      } else if (frame.type === 'pong') {
        if (frame.requestId === this.pendingPing) this.pendingPing = null;
      } else if (frame.type === 'error') {
        const error = new LemonBotError(frame.error);
        if (error.code === 'cursor_expired' && frame.requestId === this.subscriptionId) {
          this.subscribed = false;
          await this.reset(generation);
          if (generation === this.generation && this.running) this.beginSubscription();
        } else if (error.code === 'unauthenticated' || error.code === 'forbidden' && !frame.requestId) {
          this.running = false;
          this.generation++;
          this.clearTimers();
          this.socket?.close(error.code === 'unauthenticated' ? 4401 : 4403);
          this.socket = null;
          this.setState(error.code, error);
        } else {
          this.options.onState?.(this.currentState, error);
          if (frame.requestId === this.subscriptionId) throw error;
        }
      } else if (frame.type === 'terminal_output') {
        const previous = this.terminals.get(frame.terminalId);
        if (previous === undefined || frame.seq <= previous) return;
        await this.notify(frame);
        if (generation === this.generation && this.running) this.terminals.set(frame.terminalId, frame.seq);
        return;
      } else if (frame.type === 'terminal_exit') {
        this.terminals.delete(frame.terminalId);
      }
    }
    await this.notify(frame);
  }

  private async reset(generation: number): Promise<void> {
    this.setState('syncing');
    const snapshot = await this.options.onReset();
    compareCursors(snapshot.cursor, '0');
    if (generation !== this.generation || !this.running) return;
    // An authoritative reset is the sole point where restored server state may replace the cursor.
    await this.options.saveCursor?.(snapshot.cursor);
    if (generation === this.generation && this.running) this.safeCursor = snapshot.cursor;
  }

  private beginSubscription(): void {
    this.subscriptionId = crypto.randomUUID();
    this.subscribed = false;
    this.setState('replaying');
    this.socket?.send(JSON.stringify({ type: 'subscribe', requestId: this.subscriptionId, cursor: this.safeCursor,
      ...(this.selection ? { conversationIds: this.selection } : {}) }));
    this.armDeadline(10000, 'Subscription acknowledgement timed out.');
  }

  private async advance(cursor: Cursor, generation: number): Promise<void> {
    if (this.safeCursor !== undefined && compareCursors(cursor, this.safeCursor) <= 0) return;
    await this.options.saveCursor?.(cursor);
    if (generation !== this.generation || !this.running) return;
    this.safeCursor = cursor;
    this.socket?.send(JSON.stringify({ type: 'ack', cursor }));
  }

  private async notify(frame: RealtimeServerFrame): Promise<void> {
    await this.options.onFrame?.(frame);
    for (const listener of this.listeners) await listener(frame);
  }

  private setState(state: RealtimeState, error?: unknown): void {
    this.currentState = state;
    this.options.onState?.(state, error);
  }

  private armDeadline(ms: number, message: string): void {
    clearTimeout(this.deadline);
    this.deadline = Number(setTimeout(() => { this.fail(localError('upstream_unavailable', message)); }, ms));
  }

  private armLiveness(): void {
    clearTimeout(this.liveness);
    this.liveness = Number(setTimeout(() => {
      this.fail(localError('upstream_unavailable', 'Realtime heartbeat expired.'));
    }, 60000));
  }

  private clearTimers(): void {
    clearTimeout(this.deadline);
    clearInterval(this.heartbeat);
    clearTimeout(this.liveness);
    this.deadline = undefined;
    this.heartbeat = undefined;
    this.liveness = undefined;
    this.pendingPing = null;
  }

  private fail(error: unknown): void {
    this.generation++;
    this.clearTimers();
    this.socket?.close(1000, 'Reconnect');
    this.socket = null;
    this.authenticated = false;
    this.subscribed = false;
    this.scheduleReconnect(error);
  }

  private scheduleReconnect(error: unknown): void {
    if (!this.running || this.reconnectTimer) return;
    this.attempts++;
    const delay = this.options.reconnectDelayMs ?? Math.min(30000, 500 * 2 ** Math.min(this.attempts - 1, 6));
    this.retryAt = Date.now() + delay;
    this.setState('reconnecting', error);
    this.reconnectTimer = Number(setTimeout(() => {
      this.reconnectTimer = undefined;
      this.retryAt = null;
      this.connect();
    }, delay));
  }
}
