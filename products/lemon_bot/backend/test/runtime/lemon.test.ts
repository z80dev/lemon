import { describe, expect, test, vi } from 'bun:test';
import { createLemonService, type ControlSocket } from '../../src/runtime/lemon';
import { ApiError } from '../../src/core/errors';
interface RequestFrame { type: string; id: string; method: string; params: Record<string, unknown> }
class Socket implements ControlSocket {
  sent: RequestFrame[] = [];
  handlers: { open(): void; frame(data: unknown): void; closed(): void } | null = null;
  send(text: string) { this.sent.push(JSON.parse(text) as RequestFrame); }
  close() { this.handlers?.closed(); }
  listen(handlers: { open(): void; frame(data: unknown): void; closed(): void }) { this.handlers = handlers; }
  deliver(value: unknown) { this.handlers?.frame(JSON.stringify(value)); }
  handshake(methods = ['chat.send', 'nodes.list']) { this.handlers?.open(); this.deliver({ type: 'hello-ok', protocol: 1, server: {}, features: { methods, events: ['chat'] }, snapshot: {}, policy: {}, auth: { role: 'operator' } }); }
}
const config = { controlUrl: 'wss://controller.example/ws', operatorToken: 'server-only-test-token', trustedOverlay: false };

describe('long-lived operator connection', () => {
  test('uses the exact connect auth frame and correlates interleaved responses/events', async () => {
    const socket = new Socket(); const service = createLemonService(config, { socket: () => socket });
    const observed: unknown[] = []; service.onEvent((event, payload) => observed.push({ event, payload }));
    try {
      service.start(); socket.handshake();
      expect(socket.sent[0]?.method).toBe('connect');
      expect(socket.sent[0]?.params.auth).toEqual({ token: config.operatorToken });
      const first = service.call('nodes.list'); const second = service.call('chat.send', { runId: 'fixed_run', sessionKey: 'session', prompt: 'test' }, { mutation: true, resourceIds: ['fixed_run'] });
      socket.deliver({ type: 'event', event: 'chat', seq: 1, payload: { runId: 'other_run', text: 'data' } });
      socket.deliver({ type: 'res', id: socket.sent[2]!.id, ok: true, payload: { runId: 'fixed_run' } });
      socket.deliver({ type: 'res', id: socket.sent[1]!.id, ok: true, payload: { nodes: [] } });
      expect(await first).toEqual({ nodes: [] }); expect(await second).toEqual({ runId: 'fixed_run' });
      expect(observed).toEqual([{ event: 'chat', payload: { runId: 'other_run', text: 'data' } }]);
    } finally { service.close(); }
  });
  test('authentication failure never becomes connected or exposes credential diagnostics', async () => {
    vi.useFakeTimers();
    const socket = new Socket(); let opens = 0;
    const service = createLemonService(config, { socket: () => { opens++; return socket; }, reconnectMinMs: 1, reconnectMaxMs: 1 });
    service.start(); socket.handlers!.open();
    socket.deliver({ type: 'res', id: socket.sent[0]!.id, ok: false, error: { code: 'UNAUTHORIZED', message: 'raw secret diagnostic' } });
    expect(service.connected).toBe(false);
    await expect(service.call('nodes.list')).rejects.toMatchObject({ code: 'upstream_unavailable', retrySafe: true });
    vi.advanceTimersByTime(5); expect(opens).toBe(1); service.close(); vi.useRealTimers();
  });
  test('disconnect rejects dispatched mutation uncertain, reconnects without replay, and fails reads honestly', async () => {
    vi.useFakeTimers();
    const sockets: Socket[] = [];
    const service = createLemonService(config, { socket: () => { const socket = new Socket(); sockets.push(socket); return socket; }, reconnectMinMs: 1, reconnectMaxMs: 1, random: () => 0 });
    try {
      service.start(); sockets[0]!.handshake();
      const mutation = service.call('chat.send', { runId: 'run_fixed' }, { mutation: true, resourceIds: ['run_fixed'] }).catch(error => error as ApiError);
      const read = service.call('nodes.list').catch(error => error as ApiError);
      sockets[0]!.close();
      expect(await mutation).toMatchObject({ code: 'outcome_unknown', retrySafe: false, details: { resourceIds: ['run_fixed'] } });
      expect(await read).toMatchObject({ code: 'upstream_unavailable', retrySafe: true });
      vi.advanceTimersByTime(5); sockets[1]!.handshake();
      expect(sockets[1]!.sent.map(frame => frame.method)).toEqual(['connect']);
      expect(service.connected).toBe(true);
    } finally { service.close(); vi.useRealTimers(); }
  });
  test('known remote path rejection is not an uncertain mutation and raw values never escape', async () => {
    const socket = new Socket(); const service = createLemonService(config, { socket: () => socket });
    try {
      service.start(); socket.handshake(['node.fs.write']);
      const result = service.call('node.fs.write', { nodeId: 'node', path: '/outside', dataBase64: '' }, { mutation: true }).catch(error => error as ApiError);
      socket.deliver({ type: 'res', id: socket.sent[1]!.id, ok: false, error: { code: 'INVALID_REQUEST', message: 'secret and raw path', details: { reason: 'path_not_allowed', retrySafe: true } } });
      const failure = await result;
      expect(failure).toMatchObject({ code: 'forbidden', retrySafe: true });
      if (!(failure instanceof ApiError)) throw new Error('Expected a typed safe rejection.');
      expect(failure.message).not.toContain('secret');
    } finally { service.close(); }
  });
  test('scalar controller error details reject only the correlated query without disconnecting healthy host reads', async () => {
    for (const details of ['private native diagnostic', ['private native diagnostic']]) {
      const socket = new Socket();
      const service = createLemonService(config, { socket: () => socket });
      try {
        service.start(); socket.handshake(['agent.wait', 'nodes.list']);
        const missing = service.call('agent.wait', { runId: 'unknown_run' }).catch((error: unknown) => error);
        const hosts = service.call('nodes.list');
        socket.deliver({ type: 'res', id: socket.sent[1]!.id, ok: false, error: { code: 'NOT_FOUND', message: 'private native diagnostic', details } });
        const failure = await missing;
        if (!(failure instanceof ApiError)) throw new Error('Expected a classified query rejection.');
        expect(failure.code).toBe('not_found');
        expect(JSON.stringify(failure)).not.toContain('private native diagnostic');
        expect(service.connected).toBe(true);
        socket.deliver({ type: 'res', id: socket.sent[2]!.id, ok: true, payload: { nodes: [] } });
        expect(await hosts).toEqual({ nodes: [] });
      } finally { service.close(); }
    }
  });
  test('preserves only authenticated strict-process capacity evidence without making it retry-safe',async()=>{
    for(const method of ['node.process.run','node.process.get','node.process.cancel']){
      for(const reason of ['process_receipt_limit','process_limit','process_busy']){
        const socket=new Socket();const service=createLemonService(config,{socket:()=>socket});
        try{
          service.start();socket.handshake([method]);
          const result=service.call(method,{nodeId:'node',processId:'fixed_process'},{mutation:method!=='node.process.get',resourceIds:['fixed_operation']}).catch((error:unknown)=>error);
          socket.deliver({type:'res',id:socket.sent[1]!.id,ok:false,error:{code:'UNAVAILABLE',message:'private argv and stdin',details:{reason,retrySafe:false,mutationMayHaveApplied:false,preDispatch:false,runId:'private response value',argv:['private argv'],stdin:'private stdin',unknown:'private field'}}});
          const failure=await result;if(!(failure instanceof ApiError))throw new Error('Expected a typed admission rejection.');
          expect(failure.code).toBe('upstream_unavailable');expect(failure.retrySafe).toBe(false);
          expect(failure.details).toEqual({resourceIds:['fixed_operation'],reason,mutationMayHaveApplied:false,preDispatch:false});
          expect(JSON.stringify(failure)).not.toContain('private');expect(socket.sent).toHaveLength(2);
        }finally{service.close();}
      }
    }
  });
  test('missing, mistyped, uncertain or unrelated process evidence cannot prove no effect',async()=>{
    const cases:{method:string;details:Record<string,unknown>;expected:Record<string,unknown>}[]=[
      {method:'node.process.run',details:{reason:'process_limit',retrySafe:false},expected:{reason:'process_limit'}},
      {method:'node.process.run',details:{reason:'process_limit',retrySafe:false,mutationMayHaveApplied:'false',preDispatch:'true'},expected:{reason:'process_limit'}},
      {method:'node.process.run',details:{reason:'process_busy',retrySafe:false,mutationMayHaveApplied:true,preDispatch:false},expected:{reason:'process_busy',mutationMayHaveApplied:true,preDispatch:false}},
      {method:'node.process.run',details:{reason:'unreviewed_reason',retrySafe:false,mutationMayHaveApplied:false},expected:{mutationMayHaveApplied:false}},
      {method:'node.fs.write',details:{reason:'process_limit',retrySafe:false,mutationMayHaveApplied:false,preDispatch:true},expected:{}},
      {method:'node.process.run',details:{retrySafe:false},expected:{}},
    ];
    for(const example of cases){
      const socket=new Socket();const service=createLemonService(config,{socket:()=>socket});
      try{
        service.start();socket.handshake([example.method]);
        // Caller parameters are not evidence of what the authenticated worker actually did.
        const result=service.call(example.method,{mutationMayHaveApplied:false,preDispatch:true,reason:'process_limit'},{mutation:true,resourceIds:['fixed_operation']}).catch((error:unknown)=>error);
        socket.deliver({type:'res',id:socket.sent[1]!.id,ok:false,error:{code:'UNAVAILABLE',details:example.details}});
        const failure=await result;if(!(failure instanceof ApiError))throw new Error('Expected a typed uncertain failure.');
        expect(failure.code).toBe('outcome_unknown');expect(failure.retrySafe).toBe(false);expect(failure.details).toEqual({resourceIds:['fixed_operation'],...example.expected});
        expect(socket.sent).toHaveLength(2);
      }finally{service.close();}
    }
  });
  test('off-loopback plaintext controller is rejected before socket construction', () => {
    expect(() => createLemonService({ ...config, controlUrl: 'ws://remote.example/ws' })).toThrow(ApiError);
  });
});
