import { useCallback, useEffect, useRef } from 'react';
import type { ClientCommand, WireServerMessage } from '@lemon-web/shared';
import { useLemonStore } from '../store/useLemonStore';

function buildWsUrl(): string {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const envUrl = import.meta.env.VITE_LEMON_WS_URL as string | undefined;
  if (envUrl) {
    return envUrl;
  }
  return `${protocol}//localhost:3939/ws`;
}

export function useLemonSocket(): void {
  const applyServerMessage = useLemonStore((state) => state.applyServerMessage);
  const setConnectionState = useLemonStore((state) => state.setConnectionState);
  const setSendCommand = useLemonStore((state) => state.setSendCommand);

  const socketRef = useRef<WebSocket | null>(null);
  const reconnectTimer = useRef<number | null>(null);
  const retryCount = useRef(0);
  const queued = useRef<string[]>([]);

  const send = useCallback((command: ClientCommand) => {
    const payload = JSON.stringify(command);
    if (socketRef.current && socketRef.current.readyState === WebSocket.OPEN) {
      socketRef.current.send(payload);
    } else {
      queued.current.push(payload);
    }
  }, []);

  useEffect(() => {
    setSendCommand(send);
  }, [send, setSendCommand]);

  useEffect(() => {
    let cancelled = false;

    const connect = () => {
      if (cancelled) {
        return;
      }

      setConnectionState('connecting');

      const ws = new WebSocket(buildWsUrl());
      socketRef.current = ws;

      ws.onopen = () => {
        retryCount.current = 0;
        setConnectionState('connected');
        while (queued.current.length > 0) {
          const next = queued.current.shift();
          if (next) {
            ws.send(next);
          }
        }
      };

      ws.onmessage = (event) => {
        try {
          const parsed = JSON.parse(event.data as string) as WireServerMessage;
          applyServerMessage(parsed);
        } catch (err) {
          setConnectionState('error', 'Failed to parse server message');
        }
      };

      ws.onerror = () => {
        setConnectionState('error', 'WebSocket error');
      };

      ws.onclose = () => {
        if (cancelled) {
          return;
        }
        setConnectionState('disconnected');
        const delay = Math.min(10000, 500 * Math.pow(2, retryCount.current));
        retryCount.current += 1;
        reconnectTimer.current = window.setTimeout(connect, delay);
      };
    };

    connect();

    return () => {
      cancelled = true;
      if (reconnectTimer.current) {
        window.clearTimeout(reconnectTimer.current);
      }
      socketRef.current?.close();
    };
  }, [applyServerMessage, setConnectionState]);
}
