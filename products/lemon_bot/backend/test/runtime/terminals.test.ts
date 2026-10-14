import { describe, expect, test, vi } from 'bun:test';
import { createTerminalService, decodeChunk, type TerminalFrame } from '../../src/runtime/terminals';
import { fixture } from './fixture';

describe('destination PTY routing', () => {
  test('omitted cwd is measured from the destination before the real shell is opened', async () => {
    const f = fixture(); const terminal = createTerminalService(f.services);
    f.rpc = async (method, params) => {
      if (method === 'node.host.info') return { defaultCwd: '/actual/destination/cwd' };
      if (method === 'node.shell.open') { expect(params.cwd).toBe('/actual/destination/cwd'); return { shellId: 'default_cwd_shell' }; }
      throw new Error('Unexpected RPC');
    };
    try {
      const opened = await terminal.open(f.alice, f.machine, { clientNonce: 'measured_cwd_nonce_001', deviceId: f.alice.deviceId!, cols: 80, rows: 24 });
      expect(opened.cwd).toBe('/actual/destination/cwd');
    } finally { terminal.dispose(); f.store.close(); }
  });

  test('maps product ID to the actual remote shell, confines output to opener, and keeps output out of workspace replay', async () => {
    const f = fixture();
    f.rpc = async method => { if (method === 'node.shell.open') return { shellId: 'actual_remote_shell' }; if (method === 'node.shell.input' || method === 'node.shell.resize' || method === 'node.shell.close') return { ok: true }; throw new Error(`Unexpected RPC ${method}`); };
    const terminal = createTerminalService(f.services);
    try {
      const opened = await terminal.open(f.alice, f.machine, { clientNonce: 'terminal_open_nonce_001', deviceId: f.alice.deviceId!, cols: 80, rows: 24, cwd: '/destination/home' });
      const frames: TerminalFrame[] = [];
      const release = terminal.subscribe(f.alice, f.alice.deviceId!, opened.id, 0, frame => frames.push(frame));
      expect(() => terminal.subscribe({ ...f.bob, role: 'owner' }, f.bob.deviceId!, opened.id, 0, () => {})).toThrow();
      expect(() => terminal.subscribe(f.alice, f.bob.deviceId!, opened.id, 0, () => {})).toThrow();
      f.emit('node.shell.output', { shellId: 'unowned_shell', seq: 1, dataBase64: Buffer.from('invisible').toString('base64') });
      f.emit('node.shell.output', { shellId: 'actual_remote_shell', seq: 1, dataBase64: Buffer.from('destination PTY output').toString('base64') });
      await terminal.input(f.alice, opened.id, Buffer.from('echo test\n').toString('base64'));
      const resized = await terminal.resize(f.alice, opened.id, 100, 40);
      expect(resized.cols).toBe(100);
      expect(f.calls.find(call => call.method === 'node.shell.open')?.params).toEqual({ nodeId: 'node_1', cwd: '/destination/home', cols: 80, rows: 24 });
      expect(f.calls.find(call => call.method === 'node.shell.input')?.params.shellId).toBe('actual_remote_shell');
      expect(frames).toEqual([{ type: 'terminal_output', terminalId: opened.id, seq: 1, dataBase64: Buffer.from('destination PTY output').toString('base64') }]);
      expect(f.services.events.cursor()).toBe('0'); expect(f.store.list('auditRecords')).toEqual([]);
      f.emit('node.shell.exit', { shellId: 'actual_remote_shell', code: 7 });
      expect(terminal.require(f.alice, opened.id)).toMatchObject({ state: 'closed', exitCode: 7 });
      expect(frames.at(-1)).toEqual({ type: 'terminal_exit', terminalId: opened.id, code: 7 });
      release();
    } finally { terminal.dispose(); f.store.close(); }
  });
  test('spools a real early output/exit before the open response establishes product mapping', async () => {
    const f = fixture();
    f.rpc = async method => { if (method !== 'node.shell.open') throw new Error('Unexpected RPC'); f.emit('node.shell.output', { shellId: 'early_shell', seq: 1, dataBase64: 'eA==' }); f.emit('node.shell.exit', { shellId: 'early_shell', code: 0 }); return { shellId: 'early_shell' }; };
    const terminal = createTerminalService(f.services);
    try {
      const opened = await terminal.open(f.alice, f.machine, { clientNonce: 'terminal_open_nonce_002', deviceId: f.alice.deviceId!, cols: 80, rows: 24, cwd: '/destination/home' });
      const frames: TerminalFrame[] = [];
      const release = terminal.subscribe(f.alice, f.alice.deviceId!, opened.id, 0, frame => frames.push(frame));
      expect(opened.state).toBe('closed'); expect(frames.map(frame => frame.type)).toEqual(['terminal_output', 'terminal_exit']); release();
    } finally { terminal.dispose(); f.store.close(); }
  });
  test('bounded spool reports an explicit gap and same-device reconnect cancels disconnect grace', async () => {
    vi.useFakeTimers(); const f = fixture(); const closed = Promise.withResolvers<void>();
    const originalUpdate = f.services.update;
    f.services.update = (resource, changes) => { const next = originalUpdate(resource, changes); if ('state' in changes && changes.state === 'closed') closed.resolve(); return next; };
    f.rpc = async method => { if (method === 'node.shell.open') return { shellId: 'buffer_shell' }; if (method === 'node.shell.close') return { ok: true }; throw new Error('Unexpected RPC'); };
    const terminal = createTerminalService(f.services, { graceMs: 60_000 });
    try {
      const opened = await terminal.open(f.alice, f.machine, { clientNonce: 'terminal_open_nonce_003', deviceId: f.alice.deviceId!, cols: 80, rows: 24, cwd: '/destination/home' });
      const dataBase64 = Buffer.alloc(16_384, 120).toString('base64');
      for (let seq = 1; seq <= 70; seq++) f.emit('node.shell.output', { shellId: 'buffer_shell', seq, dataBase64 });
      const frames: TerminalFrame[] = [];
      const detach = terminal.subscribe(f.alice, f.alice.deviceId!, opened.id, 0, frame => frames.push(frame));
      expect(frames[0]).toEqual({ type: 'terminal_gap', terminalId: opened.id, earliestSeq: 7, latestSeq: 70 });
      expect(frames.filter(frame => frame.type === 'terminal_output')).toHaveLength(64);
      detach(); vi.advanceTimersByTime(30_000);
      const reattach = terminal.subscribe({ ...f.alice, sessionId: 'reauthenticated_same_device' }, f.alice.deviceId!, opened.id, 70, () => {});
      vi.advanceTimersByTime(40_000); expect(f.calls.filter(call => call.method === 'node.shell.close')).toHaveLength(0);
      reattach(); vi.advanceTimersByTime(60_000); await closed.promise;
      expect(f.calls.filter(call => call.method === 'node.shell.close')).toHaveLength(1);
    } finally { terminal.dispose(); f.store.close(); vi.useRealTimers(); }
  });
  test('controller loss closes connection-owned terminals and never opens replacement shells', async () => {
    const f = fixture(); f.rpc = async () => ({ shellId: 'shell_before_loss' }); const terminal = createTerminalService(f.services);
    try {
      const opened = await terminal.open(f.alice, f.machine, { clientNonce: 'terminal_open_nonce_004', deviceId: f.alice.deviceId!, cols: 80, rows: 24, cwd: '/destination/home' });
      f.disconnect(); expect(terminal.require(f.alice, opened.id)).toMatchObject({ state: 'closed', exitCode: null });
      expect(f.calls.filter(call => call.method === 'node.shell.open')).toHaveLength(1);
    } finally { terminal.dispose(); f.store.close(); }
  });
  test('revoking one opening session closes only its terminals, not the user’s other device', async () => {
    const f = fixture(); let number = 0;
    f.rpc = async method => method === 'node.shell.open' ? { shellId: `session_shell_${++number}` } : { ok: true };
    const other = { ...f.alice, deviceId: 'alice_second_device', sessionId: 'alice_second_session' };
    f.store.put('devices', { ...f.store.require('devices', f.alice.deviceId!) as object, id: other.deviceId, userId: 'alice' });
    const terminal = createTerminalService(f.services);
    try {
      const first = await terminal.open(f.alice, f.machine, { clientNonce: 'terminal_session_nonce1', deviceId: f.alice.deviceId!, cols: 80, rows: 24, cwd: '/destination/home' });
      const second = await terminal.open(other, f.machine, { clientNonce: 'terminal_session_nonce2', deviceId: other.deviceId, cols: 80, rows: 24, cwd: '/destination/home' });
      await terminal.revokeSession(f.alice.sessionId!);
      expect(f.calls.filter(call => call.method === 'node.shell.close').map(call => call.params.shellId)).toEqual(['session_shell_1']);
      expect(terminal.require(other, second.id).state).toBe('open');
      expect(f.store.require<{ state: string }>('terminals', first.id).state).toBe('closed');
    } finally { terminal.dispose(); f.store.close(); }
  });
  test('rejects noncanonical/oversized base64 before destination dispatch', () => {
    expect(() => decodeChunk('eB==', 64)).toThrow(); expect(() => decodeChunk('eA', 64)).toThrow(); expect(() => decodeChunk(Buffer.alloc(65_537).toString('base64'), 65_536)).toThrow(); expect(decodeChunk('eA==', 64).toString()).toBe('x');
  });
});
