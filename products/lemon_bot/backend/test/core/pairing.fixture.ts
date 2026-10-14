import { mkdtemp, rm } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { installHelpers } from '../../src/core/helpers';
import { createPrivateCodec } from '../../src/core/config';
import { createAccessService } from '../../src/core/auth';
import { createAccountRoutes } from '../../src/core/accounts';
import { createEventService } from '../../src/core/events';
import { createGateService } from '../../src/core/gates';
import { createMutationService } from '../../src/core/mutations';
import { createPairingRoutes, createPairingService, type PairingService } from '../../src/core/pairing';
import { Router } from '../../src/core/router';

export interface PairingFixture {
  readonly services: BackendServices;
  readonly store: Store;
  readonly router: Router;
  readonly pairingService: PairingService;
  readonly persistentCalls: number;
  workspace: P.Workspace;
  owner: P.AuthResult;
  other: P.AuthResult;
  desktop: P.Device;
  advance(ms: number): void;
  restart(): void;
  fetch(method: string, path: string, body?: unknown, token?: string | null, extraHeaders?: Record<string, string>): Promise<Response>;
  close(): Promise<void>;
}

/** Real on-disk SQLite, AES-GCM, HTTP router, nonce, account/device and access lifecycles. */
export async function pairingFixture(): Promise<PairingFixture> {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-pairing-'));
  const database = join(directory, 'product.sqlite');
  const key = randomBytes(32);
  const codec = createPrivateCodec(key);
  let clock = 1791940000000;
  let persistentCalls = 0;
  let services: BackendServices;
  let store: Store;
  let router: Router;
  let closeGates: () => void;
  let pairingService: PairingService;
  const config = { publicUrl: 'https://desktop.example', controlUrl: 'ws://127.0.0.1:4040/ws', operatorToken: 'fixture-operator-never-in-qr', dataDir: directory, host: '127.0.0.1', port: 4080, trustedOverlay: false, operator: { version: 1, trustedFrontendOrigins: [], oauthRedirectUris: [], serverSecrets: {}, channelProviders: [], emailProviders: [], eventProviders: [], hostDrivers: [], xProvider: null, exportAllowedOrigins: [], requiredRuntimeDestinations: [], breakGlassOwnerUserId: null } };
  function open() {
    store = new Store(database);
    services = { config, store, ...codec, integrations: {} } as unknown as BackendServices;
    installHelpers(services); services.now = () => clock;
    services.mutations = createMutationService(services, key);
    services.events = createEventService(services);
    services.auth = createAccessService(services);
    const issue = services.auth.session;
    services.auth.session = (userId, deviceId, options) => {
      if (options?.persistent) persistentCalls += 1;
      return issue(userId, deviceId, options);
    };
    const gates = createGateService(services); services.gates = gates; closeGates = gates.close;
    pairingService = createPairingService(services);
    router = new Router(services);
    router.register([...createAccountRoutes(services), ...createPairingRoutes(services)]);
  }
  open();
  const workspace: P.Workspace = services!.resource('workspace', { name: 'My exact desktop cluster', ownerUserId: 'owner', enabled: true, timezone: 'UTC' });
  store!.put('workspaces', workspace); store!.setMetadata('workspaceId', workspace.id);
  const preferences: P.Preferences = { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false };
  for (const userId of ['owner', 'other-owner']) {
    const user: P.User = { ...services!.resource('user', { email: `${userId}@example.com`, displayName: userId, avatarAttachmentId: null, preferences, notifications: { enabled: true, sound: false, previews: false, completed: true, needsInput: true } }), id: userId };
    store!.put('users', user);
    store!.put('members', services!.resource('member', { userId, email: user.email, displayName: user.displayName, role: 'owner', enabled: true }));
  }
  const desktop: P.Device = services!.resource('device', { userId: 'owner', platform: 'macos', name: 'Owner Mac', appVersion: '1', pushEnabled: false, lastSeenAtMs: clock });
  store!.put('devices', desktop); store!.setMetadata(`deviceInstallation:${desktop.id}`, 'desktop-installation');
  const owner = await services!.auth.session('owner', desktop.id);
  const other = await services!.auth.session('other-owner');
  return {
    get services() { return services; }, get store() { return store; }, get router() { return router; }, get pairingService() { return pairingService; }, get persistentCalls() { return persistentCalls; },
    workspace, owner, other, desktop,
    advance(ms: number) { clock += ms; },
    restart() { pairingService.close(); closeGates(); store.close(); open(); },
    fetch(method: string, path: string, body?: unknown, token: string | null = owner.token, extraHeaders: Record<string, string> = {}) {
      return router.fetch(new Request(`https://desktop.example${path}`, { method, headers: { ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...extraHeaders }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
    },
    async close() { pairingService.close(); closeGates(); store.close(); await rm(directory, { recursive: true, force: true }); },
  };
}
