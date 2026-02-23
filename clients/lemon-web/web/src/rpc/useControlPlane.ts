/**
 * React hook for the Lemon control-plane WebSocket connection.
 *
 * Wraps `createControlPlaneTransport` with React lifecycle management:
 * auto-connect on mount, state updates via useState, stable event handler
 * via useRef, and cleanup on unmount.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  createControlPlaneTransport,
  buildControlPlaneUrl,
  type ControlPlaneConnectionState,
  type ControlPlaneEventHandler,
  type ControlPlaneRequestOptions,
  type ControlPlaneTransport,
  type HelloOkSnapshot,
} from './controlPlaneTransport';

// ============================================================================
// Public API types
// ============================================================================

export interface UseControlPlaneOptions {
  /** Override WS URL. Defaults to same-origin /ws with token appended. */
  url?: string;
  /** Auth token appended as ?token=TOKEN */
  token?: string;
  /** Automatically connect on mount. Default: true */
  autoConnect?: boolean;
  /** Maximum reconnect attempts (0 = unlimited). Default: 0 */
  maxReconnectAttempts?: number;
}

export interface UseControlPlaneReturn {
  connectionState: ControlPlaneConnectionState;
  isConnected: boolean;
  snapshot: HelloOkSnapshot | null;
  lastEvent: { name: string; payload: unknown; seq: number } | null;
  request: <T = unknown>(
    method: string,
    params?: Record<string, unknown>,
    opts?: ControlPlaneRequestOptions
  ) => Promise<T>;
  connect: () => void;
  disconnect: () => void;
}

// ============================================================================
// Hook
// ============================================================================

export function useControlPlane(
  onEvent?: ControlPlaneEventHandler,
  opts?: UseControlPlaneOptions
): UseControlPlaneReturn {
  const {
    url,
    token,
    autoConnect = true,
  } = opts ?? {};

  const [connectionState, setConnectionState] =
    useState<ControlPlaneConnectionState>('disconnected');
  const [snapshot, setSnapshot] = useState<HelloOkSnapshot | null>(null);
  const [lastEvent, setLastEvent] = useState<{
    name: string;
    payload: unknown;
    seq: number;
  } | null>(null);

  // Keep the onEvent callback in a ref so that changes don't cause transport
  // recreation or re-subscription.
  const onEventRef = useRef<ControlPlaneEventHandler | undefined>(onEvent);
  useEffect(() => {
    onEventRef.current = onEvent;
  }, [onEvent]);

  // Create the transport once. It is stable for the lifetime of the component.
  const transport = useMemo<ControlPlaneTransport>(() => {
    return createControlPlaneTransport({
      onConnected: (snap) => {
        setConnectionState('connected');
        setSnapshot(snap);
      },
      onDisconnected: (_reason) => {
        setConnectionState('disconnected');
      },
      onEvent: (eventName, payload, seq, stateVersion) => {
        setLastEvent({ name: eventName, payload, seq });
        onEventRef.current?.(eventName, payload, seq, stateVersion);
      },
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []); // intentionally empty — transport is long-lived

  // Derive the WebSocket URL once.
  const resolvedUrl = useMemo<string>(() => {
    if (url) return url;
    return buildControlPlaneUrl(token);
  }, [url, token]);

  // connect / disconnect helpers exposed to callers.
  const connect = useCallback(() => {
    setConnectionState('connecting');
    transport.connect(resolvedUrl, token);
  }, [transport, resolvedUrl, token]);

  const disconnect = useCallback(() => {
    transport.disconnect();
  }, [transport]);

  // Auto-connect on mount; destroy transport on unmount.
  useEffect(() => {
    if (autoConnect) {
      connect();
    }

    return () => {
      transport.destroy();
    };
    // We only want this to run once on mount.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Reflect internal reconnecting state changes.
  // The transport sets state internally; we need to poll or proxy it.
  // We proxy via the connectionState already set in handlers, but the
  // 'reconnecting' state is set inside the transport without a callback.
  // Expose a stable request wrapper that always delegates to the transport.
  const request = useCallback(
    <T = unknown>(
      method: string,
      params?: Record<string, unknown>,
      reqOpts?: ControlPlaneRequestOptions
    ): Promise<T> => {
      return transport.request<T>(method, params, reqOpts);
    },
    [transport]
  );

  return {
    connectionState,
    isConnected: connectionState === 'connected',
    snapshot,
    lastEvent,
    request,
    connect,
    disconnect,
  };
}
