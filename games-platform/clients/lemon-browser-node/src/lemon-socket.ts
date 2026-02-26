import WebSocket from 'ws';

type HelloOkFrame = {
  type: 'hello-ok';
  protocol: number;
  server: Record<string, unknown>;
  features: Record<string, unknown>;
  snapshot: Record<string, unknown>;
  policy: Record<string, unknown>;
  auth?: { role?: string; scopes?: string[]; clientId?: string };
};

type EventFrame = {
  type: 'event';
  event: string;
  payload?: unknown;
  seq?: number;
  stateVersion?: unknown;
};

type ResponseFrame = {
  type: 'res';
  id: string;
  ok: boolean;
  payload?: unknown;
  error?: unknown;
};

type RequestFrame = {
  type: 'req';
  id: string;
  method: string;
  params?: unknown;
};

type Pending = {
  resolve: (v: unknown) => void;
  reject: (e: Error) => void;
};

export class LemonSocket {
  private ws: WebSocket;
  private pending = new Map<string, Pending>();
  private onEventCb: ((ev: EventFrame) => void) | null = null;
  private onHelloCb: ((hello: HelloOkFrame) => void) | null = null;
  private closed = false;

  private constructor(ws: WebSocket) {
    this.ws = ws;
    ws.on('message', (data) => this.onMessage(String(data)));
    ws.on('close', () => this.onClosed(new Error('ws closed')));
    ws.on('error', (err) => this.onClosed(err instanceof Error ? err : new Error(String(err))));
  }

  static async connect(wsUrl: string, connectParams: Record<string, unknown> = {}): Promise<{
    socket: LemonSocket;
    hello: HelloOkFrame;
  }> {
    const ws = new WebSocket(wsUrl);
    await new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`ws open timeout: ${wsUrl}`)), 10_000);
      ws.once('open', () => {
        clearTimeout(t);
        resolve();
      });
      ws.once('error', (err) => {
        clearTimeout(t);
        reject(err instanceof Error ? err : new Error(String(err)));
      });
    });

    const socket = new LemonSocket(ws);
    const hello = await socket.handshake(connectParams);
    return { socket, hello };
  }

  onEvent(cb: (ev: EventFrame) => void) {
    this.onEventCb = cb;
  }

  close() {
    this.closed = true;
    try {
      this.ws.close();
    } catch {
      // ignore
    }
  }

  async call(method: string, params?: unknown): Promise<unknown> {
    const id = crypto.randomUUID();
    const frame: RequestFrame = { type: 'req', id, method, ...(params ? { params } : {}) };

    const payload = await new Promise<unknown>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.send(frame);
      // Request-level timeout is caller-controlled via higher-level timeouts.
    });

    return payload;
  }

  private async handshake(connectParams: Record<string, unknown>): Promise<HelloOkFrame> {
    const id = crypto.randomUUID();
    const frame: RequestFrame = { type: 'req', id, method: 'connect', params: connectParams };

    const hello = await new Promise<HelloOkFrame>((resolve, reject) => {
      const t = setTimeout(() => reject(new Error('hello-ok timeout')), 10_000);
      this.onHelloCb = (h) => {
        clearTimeout(t);
        resolve(h);
      };

      // If server rejects connect, it responds with a normal res frame (ok=false).
      this.pending.set(id, {
        resolve: () => {
          // If we got a res ok=true for connect (unexpected), keep waiting for hello-ok.
        },
        reject: (e) => {
          clearTimeout(t);
          reject(e);
        },
      });

      this.send(frame);
    });

    this.onHelloCb = null;
    this.pending.delete(id);
    return hello;
  }

  private send(frame: unknown) {
    if (this.closed) throw new Error('socket closed');
    this.ws.send(JSON.stringify(frame));
  }

  private onMessage(raw: string) {
    let msg: unknown;
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    if (!msg || typeof msg !== 'object') return;
    const type = (msg as any).type;

    if (type === 'hello-ok') {
      this.onHelloCb?.(msg as HelloOkFrame);
      return;
    }

    if (type === 'event') {
      this.onEventCb?.(msg as EventFrame);
      return;
    }

    if (type === 'res') {
      const res = msg as ResponseFrame;
      const p = this.pending.get(res.id);
      if (!p) return;
      this.pending.delete(res.id);

      if (res.ok) {
        p.resolve(res.payload);
      } else {
        const detail =
          res.error && typeof res.error === 'object' ? JSON.stringify(res.error) : String(res.error ?? 'unknown');
        p.reject(new Error(detail));
      }
    }
  }

  private onClosed(err: Error) {
    if (this.closed) return;
    this.closed = true;

    for (const [id, p] of this.pending.entries()) {
      this.pending.delete(id);
      p.reject(err);
    }
  }
}

