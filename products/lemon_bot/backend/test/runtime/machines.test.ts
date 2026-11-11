import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { createMachineRoutes, ensureMachineRuntimeReady, importMachineFile, refreshMachines } from '../../src/runtime/machines';
import { getTerminalService } from '../../src/runtime/terminals';
import { fixture, compatibleFeatures } from './fixture';
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

  test('enrollment preview projects authoritative loopback and wss reachability without issuing an invite or exposing secrets', async () => {
    const f = fixture(); const routes = createMachineRoutes(f.services);
    const route = routes.find(route => route.path === '/v1/machines/enrollment-preview')!;
    try {
      expect(route.auth).toBe('admin');
      for (const reachability of ['loopback_only', 'routable'] as const) {
        f.rpc = async method => {
          expect(method).toBe('node.pair.preview');
          return { reachability, controllerUrl: 'wss://private.example/ws', operatorToken: f.services.config.operatorToken };
        };
        expect(await route.handler(f.context(route, undefined))).toEqual({ reachability });
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

  for (const botFolder of [undefined, false, true]) {
    test(`botFolder=${botFolder} is optional and never participates in required readiness`, async () => {
      const f = fixture();
      const feature = compatibleFeatures(f.machine.nodeId!);
      if (botFolder !== undefined) feature.features.botFolder = botFolder;
      f.rpc = async method => { if (method !== 'node.runtime.features') throw new Error('Unexpected RPC'); return feature; };
      try {
        const ready = await ensureMachineRuntimeReady(f.services, f.machine, true);
        expect(ready.botReady).toBe(true);
        expect(ready.features.botFolder).toBe(botFolder);
        feature.features.hostIO = false;
        await expect(ensureMachineRuntimeReady(f.services, f.machine, true)).rejects.toMatchObject({ code: 'capability_unavailable' });
      } finally { f.store.close(); }
    });
  }

  for (const botFolder of [undefined, false, true]) {
    for (const botContext of [false, true]) {
      test(`file import uses profileId only for Bot context=${botContext} with botFolder=${botFolder}`, async () => {
        const f = fixture(), originalRpc = f.rpc;
        const feature = compatibleFeatures(f.machine.nodeId!);
        if (botFolder !== undefined) feature.features.botFolder = botFolder;
        f.store.setMetadata(`nodeRuntimeFeatures:${f.machine.id}`, feature);
        const input: P.FileImport = { clientNonce: 'folder_file_import_0001', path: 'result.txt', ...(botContext ? { botId: f.bot.id, conversationId: f.conversation.id } : {}) };
        const attachment: P.Attachment = f.services.resource('attachment', { ownerUserId: f.alice.userId, conversationId: input.conversationId ?? null, botId: input.botId ?? null, filename: 'result.txt', mime: 'text/plain', size: 3, sha256: 'a'.repeat(64), width: null, height: null, durationMs: null, source: 'node', state: 'ready', preview: 'text', provenance: { botId: input.botId ?? null, machineId: f.machine.id, runId: null, sourceEntryId: null, generatedAtMs: null } });
        f.services.attachments = {
          async create(actor, bytes, metadata) { expect(actor).toEqual(f.alice); expect(Buffer.from(bytes).toString()).toBe('abc'); expect(metadata.filename).toBe('result.txt'); return attachment; },
          async copy() { throw new Error('Unexpected attachment copy'); },
          async bytes() { throw new Error('Unexpected attachment bytes'); },
          download() { throw new Error('Unexpected attachment download'); },
        };
        f.rpc = async (method, params) => {
          if (method === 'node.fs.stat') return stat;
          if (method === 'node.fs.read') return { path: stat.path, offset: 0, dataBase64: 'YWJj', size: 3, mime: 'text/plain', eof: true };
          return originalRpc(method, params);
        };
        try {
          expect(await importMachineFile(f.services, f.alice, f.machine.id, input)).toEqual(attachment);
          const files = f.calls.filter(call => call.method === 'node.fs.stat' || call.method === 'node.fs.read');
          expect(files).toHaveLength(3);
          for (const call of files) {
            if (botContext && botFolder === true) expect(call.params.profileId).toBe(f.bot.profileId);
            else expect(Object.hasOwn(call.params, 'profileId')).toBe(false);
          }
          expect(files[0]!.params.path).toBe('result.txt');
        } finally { f.store.close(); }
      });
    }
  }

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
