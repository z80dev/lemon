import { describe, expect, spyOn, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { createMachineRoutes, ensureMachineRuntimeReady, refreshMachines } from '../../src/runtime/machines';
import { getTerminalService } from '../../src/runtime/terminals';
import { fixture, compatibleFeatures } from './fixture';
import { createSyncRoutes } from '../../src/core/sync';
import { ApiError } from '../../src/core/errors';
const stat = { path: '/home/worker/result.txt', type: 'regular', size: 3, mtimeMs: 101, mode: 0o600, mime: 'text/plain', readable: false, writable: true };

describe('privileged destination machine boundary', () => {
  test('projects controller session states and emits each credential transition only once', async () => {
    const f = fixture();
    const emitted: P.Machine[] = [];
    const emit = f.services.events.emit.bind(f.services.events);
    f.services.events.emit = ((event, payload, audience) => {
      if (event === 'machine.upserted') emitted.push(payload as P.Machine);
      return emit(event, payload, audience);
    }) as typeof f.services.events.emit;
    let session: string | undefined;
    let present = true;
    f.rpc = async method => {
      expect(method).toBe('nodes.list');
      return { nodes: present ? [{ id: f.machine.nodeId, name: f.machine.nodeName, purpose: 'lemon_bot', enrollmentInviteId: null, status: 'offline', lastSeenMs: f.machine.lastSeenAtMs, pairedAtMs: 1, capabilities: [], ...(session === undefined ? {} : { session }) }] : [], summary: { presenceAvailable: true, truncated: false } };
    };
    const routes = createMachineRoutes(f.services);
    const list = routes.find(route => route.method === 'GET' && route.path === '/v1/machines')!;
    try {
      for (const [value, expected] of [[undefined, 'unknown'], ['active', 'active'], ['expired', 'expired'], ['revoked', 'revoked'], ['none', 'unknown'], ['unknown', 'unknown']] as const) {
        session = value;
        const before = emitted.length;
        const previous = f.store.require<P.Machine>('machines', f.machine.id).credential;
        const result = await list.handler(f.context(list, undefined)) as P.Page<P.Machine>;
        expect(result.items.find(machine => machine.id === f.machine.id)).toMatchObject({ status: 'offline', credential: expected });
        expect(emitted.length - before).toBe(previous === expected ? 0 : 1);
        const count = emitted.length;
        await refreshMachines(f.services);
        expect(emitted).toHaveLength(count);
      }
      session = 'expired'; await refreshMachines(f.services);
      present = false; await refreshMachines(f.services);
      expect(f.store.require<P.Machine>('machines', f.machine.id).credential).toBe('expired');
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });

  test('enrollment preview reports SSH prerequisites without issuing an invite or exposing controller details', async () => {
    const f = fixture(); const routes = createMachineRoutes(f.services);
    const route = routes.find(route => route.path === '/v1/machines/enrollment-preview')!;
    try {
      expect(route.auth).toBe('admin');
      for (const reachability of ['loopback_only', 'routable'] as const) {
        for (const [controlUrl, gateway, launcher, reason] of [
          ['wss://controller.example/ws', true, '/private/lemon', 'controller_remote'],
          ['ws://127.0.0.1:4040/ws', false, '/private/lemon', 'node_gateway_unavailable'],
          ['ws://127.0.0.1:4040/ws', true, undefined, 'launcher_unavailable'],
          ['ws://127.0.0.1:4040/ws', true, '/private/lemon', null],
        ] as const) {
          f.services.config.controlUrl = controlUrl;
          f.services.config.runtimeLauncher = launcher;
          f.rpc = async method => {
            expect(method).toBe('node.pair.preview');
            return { reachability, nodeGateway: { available: gateway, port: gateway ? 4044 : null }, controllerUrl: 'wss://private.example/ws', operatorToken: f.services.config.operatorToken };
          };
          expect(await route.handler(f.context(route, undefined))).toEqual({ reachability, ssh: { available: reason === null, reason } });
        }
      }
      expect(f.calls.every(call => !call.mutation)).toBe(true);
      expect(f.store.list('machineInvites')).toEqual([]);
      f.rpc = async () => ({ reachability: 'unknown' });
      await expect(route.handler(f.context(route, undefined))).rejects.toMatchObject({ code: 'upstream_unavailable' });
      f.disconnect();
      const dispatched = f.calls.length;
      await expect(route.handler(f.context(route, undefined))).rejects.toMatchObject({ code: 'upstream_unavailable' });
      expect(f.calls).toHaveLength(dispatched);
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });

  test('legacy links default to direct in REST and snapshots; SSH addresses require management access', async () => {
    const f = fixture(); const routes = createMachineRoutes(f.services);
    const list = routes.find(route => route.method === 'GET' && route.path === '/v1/machines')!;
    const get = routes.find(route => route.method === 'GET' && route.path === '/v1/machines/:id')!;
    const sync = createSyncRoutes(f.services).find(route => route.path === '/v1/sync')!;
    f.store.put('workspaces', { id: f.alice.workspaceId });
    const { link: _legacyLink, ...legacy } = f.machine;
    f.store.put('machines', legacy);
    const originalMachine = f.services.auth.machine.bind(f.services.auth);
    const originalCanRead = f.services.auth.canRead.bind(f.services.auth);
    f.services.auth.canRead = (actor, table, value) => table === 'conversations'
      ? (value as P.Conversation).ownerUserId === actor.userId
      : originalCanRead(actor, table, value);
    f.services.auth.machine = (actor, machineId, manage) => {
      if (actor.userId === f.bob.userId) {
        if (manage) throw new ApiError('forbidden', 'Read-only host access.');
        return f.store.require<P.Machine>('machines', machineId);
      }
      return originalMachine(actor, machineId, manage);
    };
    try {
      expect(await get.handler(f.context(get, undefined, f.alice, { id: f.machine.id }))).toMatchObject({ link: { kind: 'direct' } });
      expect((await list.handler(f.context(list, undefined)) as P.Page<P.Machine>).items[0]?.link).toEqual({ kind: 'direct' });
      expect((await sync.handler(f.context(sync, undefined)) as P.Snapshot).machines[0]?.link).toEqual({ kind: 'direct' });
      const link: P.MachineLink = { kind: 'ssh_tunnel', sshDestination: 'me@private-host', nodePort: 4044, productPort: 4100, tunnel: { state: 'unknown', detail: null, checkedAtMs: null } };
      f.store.put('machines', { ...f.machine, link });
      expect(await get.handler(f.context(get, undefined, f.alice, { id: f.machine.id }))).toMatchObject({ link: { sshDestination: 'me@private-host' } });
      expect(await get.handler(f.context(get, undefined, f.bob, { id: f.machine.id }))).toMatchObject({ link: { sshDestination: null } });
      expect((await list.handler(f.context(list, undefined, f.bob)) as P.Page<P.Machine>).items[0]?.link).toMatchObject({ kind: 'ssh_tunnel', sshDestination: null });
      expect((await sync.handler(f.context(sync, undefined, f.bob)) as P.Snapshot).machines[0]?.link).toMatchObject({ kind: 'ssh_tunnel', sshDestination: null });
      expect(f.store.require<P.Machine>('machines', f.machine.id).link).toMatchObject({ sshDestination: 'me@private-host' });
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });

  test('SSH setup routes declare asynchronous status and reject malformed input before spawning', async () => {
    const f = fixture(); const routes = createMachineRoutes(f.services);
    const start = routes.find(route => route.method === 'POST' && route.path === '/v1/machines/ssh')!;
    const get = routes.find(route => route.path === '/v1/machine-setups/:id')!;
    try {
      expect(start).toMatchObject({ auth: 'admin', status: 202, mutation: false });
      await expect(Promise.resolve().then(() => start.handler(f.context(start, { clientNonce: 'machine_ssh_nonce_invalid', sshDestination: 'me@host', unknown: true })))).rejects.toMatchObject({ code: 'invalid_request' });
      await expect(Promise.resolve().then(() => get.handler(f.context(get, undefined, f.alice, { id: 'missing_setup' })))).rejects.toMatchObject({ code: 'not_found' });
      expect(f.calls).toHaveLength(0);
      expect(f.store.list('machineSetups')).toEqual([]);
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });

  test('detach uninstalls the tunnel only after node revocation and audits failures without blocking detach', async () => {
    for (const exitCode of [0, 1]) {
      const f = fixture(); f.services.config.runtimeLauncher = '/mock/lemon';
      f.store.put('machines', { ...f.machine, link: { kind: 'ssh_tunnel', sshDestination: 'me@worker', nodePort: 4044, productPort: 4100, tunnel: { state: 'online', detail: null, checkedAtMs: 1 } } });
      const order: string[] = [];
      f.rpc = async (method, params) => {
        expect(method).toBe('nodes.revoke');
        expect(params).toEqual({ nodeId: f.machine.nodeId, confirmName: f.machine.nodeName });
        order.push('revoke'); return { revoked: true };
      };
      const spawn = spyOn(Bun, 'spawn').mockImplementation(() => {
        order.push('uninstall');
        return { exited: Promise.resolve(exitCode), stdout: new Blob(['']).stream(), stderr: new Blob(['']).stream(), kill() {} } as unknown as Bun.Subprocess;
      });
      const routes = createMachineRoutes(f.services);
      const preview = routes.find(route => route.path === '/v1/machines/:id/preview')!;
      const remove = routes.find(route => route.method === 'DELETE' && route.path === '/v1/machines/:id')!;
      try {
        const confirmation = await preview.handler(f.context(preview, { clientNonce: `machine_preview_detach_${exitCode}`, action: 'detach' }, f.alice, { id: f.machine.id })) as P.Confirmation;
        expect(await remove.handler(f.context(remove, { clientNonce: `machine_confirm_detach_${exitCode}`, revision: confirmation.revision, confirmationToken: confirmation.confirmationToken, confirmName: confirmation.confirmName }, f.alice, { id: f.machine.id }))).toEqual({ id: f.machine.id, deleted: true });
        expect(order).toEqual(['revoke', 'uninstall']);
        expect(spawn.mock.calls[0]?.[0]).toEqual(['/mock/lemon', 'service', 'uninstall', 'tunnel', '--name', f.machine.nodeName, '--json']);
        expect(f.store.require<P.Machine>('machines', f.machine.id).status).toBe('revoked');
        expect(f.store.list<P.AuditRecord>('auditRecords', value => value.action === 'machine.tunnel_uninstall')).toMatchObject([{ outcome: exitCode === 0 ? 'succeeded' : 'failed' }]);
      } finally { spawn.mockRestore(); getTerminalService(f.services).dispose(); f.store.close(); }
    }
  });

  test('accepts live authenticated privacy capability descriptors without inventing grants', async () => {
    const f = fixture();
    f.rpc = async method => {
      if (method !== 'node.runtime.features') throw new Error('Unexpected RPC');
      return { ...compatibleFeatures('node_1'), capabilities: { 'coding_agent.run': { version: 2, executionContext: { version: 1 }, nativePrivacyContext: { version: 1 } } }, nativePrivacyContext: { version: 1 } };
    };
    try {
      expect(await ensureMachineRuntimeReady(f.services, f.machine, true)).toMatchObject({ botReady: true, nativePrivacyContext: { version: 1 }, capabilities: { 'coding_agent.run': { version: 2, executionContext: { version: 1 } } } });
      expect(f.store.list('botGrants')).toEqual([]);
    } finally { f.store.close(); }
  });

  test('bot visibility never confers human host access; invalid chunks and truncate offset are rejected before dispatch', async () => {
    const f = fixture(); const routes = createMachineRoutes(f.services); const write = routes.find(route => route.method === 'PUT' && route.path === '/v1/machines/:id/files')!;
    try {
      await expect(write.handler(f.context(write, { clientNonce: 'file_write_nonce_000001', path: 'result.txt', dataBase64: 'eA==' }, f.bob, { id: f.machine.id }))).rejects.toMatchObject({ code: 'forbidden' });
      await expect(write.handler(f.context(write, { clientNonce: 'file_write_nonce_000002', path: 'result.txt', dataBase64: 'eB==' }, f.alice, { id: f.machine.id }))).rejects.toMatchObject({ code: 'invalid_request' });
      await expect(write.handler(f.context(write, { clientNonce: 'file_write_nonce_000003', path: 'result.txt', dataBase64: 'eA==', offset: 1, truncate: true }, f.alice, { id: f.machine.id }))).rejects.toMatchObject({ code: 'invalid_request' });
      expect(f.calls).toHaveLength(0);
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });
  test('overwrite and no-overwrite move carry worker CAS fences and actual readable/writable measurements', async () => {
    const f = fixture(); const routes = createMachineRoutes(f.services);
    f.rpc = async method => method === 'node.fs.write' ? { path: stat.path, offset: 0, bytesWritten: 3, size: 3, mtimeMs: 101 } : method === 'node.fs.stat' ? stat : { moved: true };
    try {
      const write = routes.find(route => route.method === 'PUT' && route.path === '/v1/machines/:id/files')!;
      const result = await write.handler(f.context(write, { clientNonce: 'file_write_nonce_000004', path: stat.path, dataBase64: 'YWJj', expectedModifiedAtMs: 100 }, f.alice, { id: f.machine.id }));
      expect(result).toMatchObject({ readable: false, writable: true, modifiedAtMs: 101 });
      expect(f.calls.find(call => call.method === 'node.fs.write')?.params.expectedModifiedAtMs).toBe(100);
      const move = routes.find(route => route.path.endsWith('/files/move'))!;
      await move.handler(f.context(move, { clientNonce: 'file_move_nonce_000001', path: stat.path, destination: 'other.txt', expectedModifiedAtMs: 101 }, f.alice, { id: f.machine.id }));
      expect(f.calls.find(call => call.method === 'node.fs.move')?.params).toMatchObject({ nodeId: 'node_1', expectedModifiedAtMs: 101, overwrite: false });
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });
  test('deletion previews bind principal, path, stat/candidates and exact basename before worker mutation', async () => {
    const f = fixture(); const routes = createMachineRoutes(f.services);
    f.rpc = async method => { if (method === 'node.fs.delete.preview') return { path: stat.path, stat, childCount: 0, candidateCount: 1, childrenDigest: 'remote_digest', confirmationToken: 'private_worker_confirmation', expiresAtMs: f.services.now() + 300_000 }; if (method === 'node.fs.delete') return { deleted: true }; throw new Error(`Unexpected ${method}`); };
    try {
      const preview = routes.find(route => route.path.endsWith('/files/preview'))!;
      const confirmation = await preview.handler(f.context(preview, { clientNonce: 'file_preview_nonce_0001', path: 'result.txt', action: 'delete' }, f.alice, { id: f.machine.id })) as P.Confirmation;
      const remove = routes.find(route => route.method === 'DELETE' && route.path.endsWith('/files'))!;
      await expect(remove.handler(f.context(remove, { clientNonce: 'file_delete_nonce_0001', path: 'different.txt', confirmationToken: confirmation.confirmationToken, confirmName: confirmation.confirmName }, f.alice, { id: f.machine.id }))).rejects.toMatchObject({ code: 'confirmation_required' });
      expect(f.calls.filter(call => call.method === 'node.fs.delete')).toHaveLength(0);
      await remove.handler(f.context(remove, { clientNonce: 'file_delete_nonce_0002', path: 'result.txt', confirmationToken: confirmation.confirmationToken, confirmName: confirmation.confirmName }, f.alice, { id: f.machine.id }));
      expect(f.calls.find(call => call.method === 'node.fs.delete')?.params).toEqual({ nodeId: 'node_1', path: 'result.txt', confirm: 'result.txt', confirmationToken: 'private_worker_confirmation' });
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });
  test('same-node repair is invite-bound, while matching name without consumed invite evidence cannot attach an arbitrary node', async () => {
    const f = fixture(); const pending: P.Machine = { ...f.machine, id: 'pending_machine', nodeId: null, nodeName: 'new-worker', status: 'pending', botIds: [] }; f.store.put('machines', pending);
    const invite: P.MachineInvite = f.services.resource('machine_invite', { machineId: pending.id, inviteCode: 'one_use', joinCommand: 'platform join command', expiresAtMs: f.services.now() + 300_000, status: 'pending', enrollment: 'waiting_for_join', lastError: null }); f.store.put('machineInvites', invite); f.store.setMetadata(`machineInviteUpstream:${invite.id}`, 'actual_issued_invite');
    let evidence = 'other_invite';
    f.rpc = async (method, params) => method === 'node.runtime.features' ? compatibleFeatures(String(params.nodeId)) : ({ nodes: [{ id: 'durable_node_new', name: 'new-worker', purpose: 'lemon_bot', enrollmentInviteId: evidence, status: 'online', lastSeenMs: 10, pairedAtMs: 1, capabilities: [] }], summary: { presenceAvailable: true, truncated: false } });
    try {
      await refreshMachines(f.services); expect(f.store.require<P.Machine>('machines', pending.id).nodeId).toBeNull();
      evidence = 'actual_issued_invite'; await refreshMachines(f.services);
      expect(f.store.require<P.Machine>('machines', pending.id)).toMatchObject({ nodeId: 'durable_node_new', status: 'online' });
      expect(f.store.require<P.MachineInvite>('machineInvites', invite.id)).toMatchObject({ status: 'joined', enrollment: 'online' });
      const routes = createMachineRoutes(f.services); const reconnect = routes.find(route => route.path.endsWith('/reconnect'))!;
      f.rpc = async (method, params) => { expect(method).toBe('node.pair.invite'); expect(params.nodeId).toBe('durable_node_new'); return { inviteId: 'repair_invite', inviteCode: 'fresh_one_use', joinCommand: 'real platform repair command', expiresAtMs: f.services.now() + 300_000 }; };
      await reconnect.handler(f.context(reconnect, { clientNonce: 'machine_repair_nonce_1' }, f.alice, { id: pending.id }));
      expect(f.store.list<P.Machine>('machines').filter(machine => machine.nodeId === 'durable_node_new')).toHaveLength(1);
    } finally { getTerminalService(f.services).dispose(); f.store.close(); }
  });
});
