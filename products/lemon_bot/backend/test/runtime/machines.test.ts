import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { createMachineRoutes, ensureMachineRuntimeReady, refreshMachines } from '../../src/runtime/machines';
import { getTerminalService } from '../../src/runtime/terminals';
import { fixture, compatibleFeatures } from './fixture';
const stat = { path: '/home/worker/result.txt', type: 'regular', size: 3, mtimeMs: 101, mode: 0o600, mime: 'text/plain', readable: false, writable: true };

describe('privileged destination machine boundary', () => {
  test('accepts live authenticated privacy capability descriptors without inventing grants', async () => {
    const f = fixture();
    f.rpc = async method => {
      if (method !== 'node.runtime.features') throw new Error('Unexpected RPC');
      return { ...compatibleFeatures('node_1'), capabilities: { 'coding_agent.run': { version: 1, nativePrivacyContext: { version: 1 } } }, nativePrivacyContext: { version: 1 } };
    };
    try {
      expect(await ensureMachineRuntimeReady(f.services, f.machine, true)).toMatchObject({ botReady: true, nativePrivacyContext: { version: 1 }, capabilities: { 'coding_agent.run': { version: 1 } } });
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
