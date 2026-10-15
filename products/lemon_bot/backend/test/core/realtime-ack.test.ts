import { expect, test } from 'bun:test';
import type { ServerWebSocket } from 'bun';
import type * as P from '../../../contracts/protocol';
import { createRealtime, type RealtimeData } from '../../src/core/realtime';
import { fixture } from '../runtime/fixture';

test('a socket rejects a global snapshot cursor beyond its delivered frame but accepts the frame cursor', async () => {
  const f = fixture(), realtime = createRealtime(f.services), frames: P.RealtimeServerFrame[] = [];
  const socket = { data: realtime.data(), readyState: 1, send(value: string) { frames.push(JSON.parse(value) as P.RealtimeServerFrame); }, close() {}, ping() {} } as unknown as ServerWebSocket<RealtimeData>;
  const receive = async (frame: P.RealtimeClientFrame) => { realtime.websocket.message!(socket, JSON.stringify(frame)); await socket.data.queue; };
  try {
    realtime.websocket.open!(socket);
    await receive({ type: 'auth', token: 'ack_boundary_session_token', deviceId: f.alice.deviceId! });
    socket.data.delivered = '5';
    await receive({ type: 'ack', cursor: '100' });
    expect(frames.at(-1)).toMatchObject({ type: 'error', error: { code: 'invalid_request', message: 'Acknowledgement cursor was not delivered.' } });
    expect(socket.data.acked).toBe('0');
    const count = frames.length;
    await receive({ type: 'ack', cursor: '5' });
    expect(socket.data.acked).toBe('5'); expect(frames).toHaveLength(count);
  } finally { realtime.close(); f.store.close(); }
});
