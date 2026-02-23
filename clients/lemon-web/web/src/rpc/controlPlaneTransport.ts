/**
 * Control-plane WebSocket transport.
 *
 * Connects to the Lemon control-plane /ws endpoint which uses a
 * request/response + server-push event protocol distinct from the
 * bridge-based WebSocket transport in useLemonSocket.ts.
 *
 * Protocol summary:
 *   - Server sends `hello-ok` on connect (no client hello needed for token auth)
 *   - Client sends `req` frames; server replies with matching `res` frames
 *   - Server pushes `event` frames asynchronously
 */

import type { CPServerFrame, CPReqFrame, CPHelloOkFrame } from '@lemon-web/shared/src/controlPlaneTypes';
import { getReconnectDelayMs } from './socketTransport';

// ============================================================================
// Public types
// ============================================================================

export interface ControlPlaneRequestOptions {
  /** Request timeout in milliseconds. Default: 30000 */
  timeoutMs?: number;
}

export interface HelloOkSnapshot {
  protocol: number;
  server: {
    version?: string;
    nodeId?: string;
    uptimeMs?: number;
  };
  features: Record<string, boolean>;
  snapshot?: Record<string, unknown>;
  policy?: Record<string, unknown>;
  auth?: Record<string, unknown>;
}

export type ControlPlaneEventHandler = (
  eventName: string,
  payload: unknown,
  seq: number,
  stateVersion: Record<string, number>
) => void;

export interface ControlPlaneConnectionHandler {
  onConnected: (snapshot: HelloOkSnapshot) => void;
  onDisconnected: (reason: string) => void;
  onEvent: ControlPlaneEventHandler;
}

export type ControlPlaneConnectionState =
  | 'connecting'
  | 'connected'
  | 'disconnected'
  | 'reconnecting'
  | 'error';

export interface ControlPlaneTransport {
  connect(url: string, token?: string): void;
  disconnect(): void;
  request<T = unknown>(
    method: string,
    params?: Record<string, unknown>,
    opts?: ControlPlaneRequestOptions
  ): Promise<T>;
  isConnected(): boolean;
  getConnectionState(): ControlPlaneConnectionState;
  destroy(): void;
}

// ============================================================================
// Internal types
// ============================================================================

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
}

// ============================================================================
// URL builder
// ============================================================================

/**
 * Build the control-plane WebSocket URL.
 * Uses VITE_LEMON_CP_URL if set, otherwise same-origin /ws.
 * Appends `?token=TOKEN` if a token is provided and not already present.
 */
export function buildControlPlaneUrl(token?: string): string {
  const envUrl = (import.meta.env.VITE_LEMON_CP_URL as string | undefined)?.trim();
  const base = envUrl || (() => {
    const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${proto}//${window.location.host}/ws`;
  })();

  if (!token) {
    return base;
  }

  try {
    const parsed = new URL(base, `${window.location.protocol}//${window.location.host}`);
    if (!parsed.searchParams.has('token')) {
      parsed.searchParams.set('token', token);
    }
    return parsed.toString();
  } catch {
    const sep = base.includes('?') ? '&' : '?';
    return `${base}${sep}token=${encodeURIComponent(token)}`;
  }
}

// ============================================================================
// ID generation
// ============================================================================

let _idCounter = 0;

function generateId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  // Fallback for environments without crypto.randomUUID
  _idCounter += 1;
  return `cp-${Date.now()}-${_idCounter}`;
}

// ============================================================================
// Factory
// ============================================================================

const DEFAULT_TIMEOUT_MS = 30_000;

/**
 * Create a control-plane transport instance.
 *
 * The transport manages a single WebSocket connection with automatic
 * reconnection using exponential backoff. Pending requests are rejected
 * when the connection drops.
 */
export function createControlPlaneTransport(
  handlers: ControlPlaneConnectionHandler
): ControlPlaneTransport {
  let socket: WebSocket | null = null;
  let state: ControlPlaneConnectionState = 'disconnected';
  let currentUrl = '';
  let currentToken: string | undefined;
  let retryCount = 0;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let destroyed = false;

  const pendingRequests = new Map<string, PendingRequest>();

  // ---- helpers ----

  function setState(next: ControlPlaneConnectionState): void {
    state = next;
  }

  function rejectAllPending(reason: string): void {
    const error = new Error(reason);
    for (const [, pending] of pendingRequests) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    pendingRequests.clear();
  }

  function clearReconnectTimer(): void {
    if (reconnectTimer !== null) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
  }

  function scheduleReconnect(): void {
    if (destroyed) return;
    const delay = getReconnectDelayMs(retryCount);
    retryCount += 1;
    setState('reconnecting');
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      if (!destroyed) {
        openSocket(currentUrl);
      }
    }, delay);
  }

  // ---- WebSocket lifecycle ----

  function openSocket(url: string): void {
    if (destroyed) return;
    currentUrl = url;
    setState('connecting');

    const ws = new WebSocket(url);
    socket = ws;

    ws.onopen = () => {
      // The control-plane protocol requires the client to send a `connect`
      // req frame first. The server responds with `hello-ok` (not a regular
      // res frame) on success. We don't add this to pendingRequests because
      // the response frame type is `hello-ok`, not `res`.
      const frame: CPReqFrame = {
        type: 'req',
        id: generateId(),
        method: 'connect',
        params: currentToken ? { auth: { token: currentToken } } : {},
      };
      try {
        ws.send(JSON.stringify(frame));
      } catch {
        // If send fails the onclose handler will trigger reconnect
      }
    };

    ws.onmessage = (event: MessageEvent) => {
      let frame: CPServerFrame;
      try {
        frame = JSON.parse(event.data as string) as CPServerFrame;
      } catch {
        // Ignore malformed frames
        return;
      }

      handleFrame(frame);
    };

    ws.onerror = () => {
      setState('error');
    };

    ws.onclose = () => {
      if (socket !== ws) {
        // Stale socket — ignore
        return;
      }
      socket = null;

      const wasConnected = state === 'connected';
      rejectAllPending('WebSocket connection closed');

      if (!destroyed) {
        handlers.onDisconnected(wasConnected ? 'connection closed' : 'connection failed');
        scheduleReconnect();
      }
    };
  }

  function handleFrame(frame: CPServerFrame): void {
    switch (frame.type) {
      case 'hello-ok': {
        retryCount = 0;
        setState('connected');
        const snapshot: HelloOkSnapshot = {
          protocol: frame.protocol,
          server: frame.server,
          features: frame.features,
          snapshot: frame.snapshot,
          policy: frame.policy,
          auth: frame.auth,
        };
        handlers.onConnected(snapshot);
        break;
      }

      case 'res': {
        const pending = pendingRequests.get(frame.id);
        if (!pending) break;
        pendingRequests.delete(frame.id);
        clearTimeout(pending.timer);

        if (frame.ok) {
          pending.resolve(frame.payload);
        } else {
          const err = frame.error;
          const msg = err ? `${err.code}: ${err.message}` : 'Request failed';
          pending.reject(new Error(msg));
        }
        break;
      }

      case 'event': {
        handlers.onEvent(frame.event, frame.payload, frame.seq, frame.stateVersion);
        break;
      }

      case 'pong': {
        // No-op — pong just acknowledges a ping
        break;
      }

      default: {
        // Unknown frame type — ignore gracefully
        break;
      }
    }
  }

  // ---- Public interface ----

  return {
    connect(url: string, token?: string): void {
      if (destroyed) return;
      clearReconnectTimer();
      if (socket) {
        socket.onclose = null;
        socket.onerror = null;
        socket.onmessage = null;
        socket.onopen = null;
        socket.close();
        socket = null;
      }
      rejectAllPending('Transport reconnecting');
      retryCount = 0;
      currentToken = token;
      // Token goes in the connect req frame body (not the URL) because the
      // HTTP router does not read query parameters before the WS upgrade.
      openSocket(url);
    },

    disconnect(): void {
      clearReconnectTimer();
      if (socket) {
        socket.onclose = null;
        socket.onerror = null;
        socket.onmessage = null;
        socket.onopen = null;
        socket.close();
        socket = null;
      }
      rejectAllPending('Transport disconnected');
      setState('disconnected');
      handlers.onDisconnected('disconnect called');
    },

    request<T = unknown>(
      method: string,
      params?: Record<string, unknown>,
      opts?: ControlPlaneRequestOptions
    ): Promise<T> {
      return new Promise<T>((resolve, reject) => {
        if (!socket || socket.readyState !== WebSocket.OPEN) {
          reject(new Error('Not connected'));
          return;
        }

        const id = generateId();
        const timeoutMs = opts?.timeoutMs ?? DEFAULT_TIMEOUT_MS;

        const timer = setTimeout(() => {
          pendingRequests.delete(id);
          reject(new Error(`Request timed out after ${timeoutMs}ms: ${method}`));
        }, timeoutMs);

        pendingRequests.set(id, {
          resolve: resolve as (value: unknown) => void,
          reject,
          timer,
        });

        const frame: CPReqFrame = {
          type: 'req',
          id,
          method,
          ...(params !== undefined ? { params } : {}),
        };

        try {
          socket.send(JSON.stringify(frame));
        } catch (err) {
          clearTimeout(timer);
          pendingRequests.delete(id);
          reject(err);
        }
      });
    },

    isConnected(): boolean {
      return state === 'connected';
    },

    getConnectionState(): ControlPlaneConnectionState {
      return state;
    },

    destroy(): void {
      destroyed = true;
      clearReconnectTimer();
      if (socket) {
        socket.onclose = null;
        socket.onerror = null;
        socket.onmessage = null;
        socket.onopen = null;
        socket.close();
        socket = null;
      }
      rejectAllPending('Transport destroyed');
      setState('disconnected');
    },
  };
}

// Re-export shared types so consumers can import from a single place
export type { CPHelloOkFrame, CPServerFrame };
