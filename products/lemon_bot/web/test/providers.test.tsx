import { afterEach, beforeEach, expect, mock, spyOn, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act, type ReactNode } from 'react';
import { LemonBotClient, type ProviderDeviceLogin, type ProviderManagement, type Snapshot } from '@lemon-bot/sdk';
import type { Root } from 'react-dom/client';

// MOCK TRANSPORT ONLY: no real credentials, provider sign-in, target configuration or network calls.
const browser = new Window({ url: 'https://bot.test/' });
Object.assign(globalThis, {
  window: browser, document: browser.document, navigator: browser.navigator,
  HTMLElement: browser.HTMLElement, HTMLInputElement: browser.HTMLInputElement,
  CustomEvent: browser.CustomEvent, Event: browser.Event,
  sessionStorage: browser.sessionStorage, localStorage: browser.localStorage,
  IS_REACT_ACT_ENVIRONMENT: true,
});
// React DOM must initialize after the DOM shim; these tests intentionally exercise this module-loading boundary.
const { createRoot } = await import('react-dom/client');

interface MockRequest { method: string; path: string; body: Record<string, string>; options: RequestInit }
const requests: MockRequest[] = [];
let respond: (request: MockRequest) => unknown | Promise<unknown>;
const mockFetch = (async (input: URL | RequestInfo, options: RequestInit = {}) => {
  const url = new URL(input instanceof Request ? input.url : String(input));
  expect(url.origin).toBe('https://bot.test');
  const request = { method: options.method || 'GET', path: url.pathname.replace(/^\/v1/, ''), body: options.body ? JSON.parse(String(options.body)) : {}, options };
  requests.push(request);
  const response = await respond(request);
  return response instanceof Response ? response : Response.json(response);
}) as typeof fetch;
function mockClient() { return new LemonBotClient({ baseUrl: 'https://bot.test', token: 'MOCK_PRODUCT_SESSION', fetch: mockFetch }); }
const app = {
  client: mockClient(), online: true,
  snapshot: { workspace: { id: 'workspace', name: 'My workspace', ownerUserId: 'owner' }, user: { id: 'owner' }, member: { role: 'owner' } } as Snapshot,
};
mock.module('../src/app', () => ({ useApp: () => app }));
// Load after the account mock is installed; static imports would mount the real authenticated workspace module.
const { ProvidersSettings } = await import('../src/features/settings/providers');
const { checkedDeviceLogin, providerFailure, readProviderIntent } = await import('../src/features/settings/providers-api');

const controller: ProviderManagement = {
  target: { id: 'controller-target', nodeId: null, hostname: 'controller.test' },
  default: { providerId: 'anthropic', modelId: 'model-one' },
  providers: [
    { id: 'anthropic', displayName: 'Anthropic', methods: ['api_key'], configured: false, status: 'needs_login', lastValidation: null, environmentOverrides: [], configurationOverrides: [] },
    { id: 'openai_codex', displayName: 'ChatGPT / Codex', methods: ['device_code'], configured: true, status: 'expired', lastValidation: { kind: 'resolver', ready: false, atMs: 1000 }, environmentOverrides: ['OPENAI_API_KEY'], configurationOverrides: ['credential_pool', 'project_configuration'] },
  ],
};
const worker: ProviderManagement = { ...controller, target: { id: 'worker-target', nodeId: 'worker-node', hostname: 'worker.test' } };
const ownedMachine = { id: 'machine', name: 'My worker', ownerUserId: 'owner', nodeId: 'worker-node', status: 'online' };
function pending(request: MockRequest): ProviderDeviceLogin {
  const loginId = request.path.includes('/device-login/') ? request.path.split('/device-login/')[1]!.split('/')[0]! : request.body.clientNonce!;
  return { loginId, targetId: request.body.targetId!, providerId: 'openai_codex', status: 'pending', verificationUrl: 'https://auth.openai.com/codex/device', userCode: 'MOCK-CODE', expiresAtMs: Date.now() + 600000, pollIntervalMs: 5000 };
}
function terminal(request: MockRequest, status: ProviderDeviceLogin['status'] = 'completed'): ProviderDeviceLogin {
  return { ...pending(request), status, verificationUrl: null, userCode: null, expiresAtMs: null, pollIntervalMs: null };
}
function defaultResponse(request: MockRequest): unknown {
  if (request.path === '/machines') return { items: [ownedMachine, { ...ownedMachine, id: 'foreign', ownerUserId: 'someone-else', name: 'Not mine' }], nextCursor: null };
  if (request.path === '/auth/sessions') return { items: [{ id: 'current-session', current: true }], nextCursor: null };
  if (request.path.includes('/device-login')) return request.path.endsWith('/cancel') ? terminal(request, 'cancelled') : pending(request);
  if (request.path.startsWith('/machines/machine/providers')) return structuredClone(worker);
  if (request.path.startsWith('/instance/providers')) return structuredClone(controller);
  throw new Error(`Unexpected mock request: ${request.method} ${request.path}`);
}
function deferred<T>() {
  let resolve!: (value: T) => void; let reject!: (failure: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
let container: HTMLDivElement; let root: Root;
const timers = new Map<number, { callback: () => void; delay: number }>(); let nextTimer = 0;
beforeEach(() => {
  requests.length = 0; timers.clear(); sessionStorage.clear(); localStorage.clear();
  app.client = mockClient(); app.online = true;
  app.snapshot = { workspace: { id: 'workspace', name: 'My workspace', ownerUserId: 'owner' }, user: { id: 'owner' }, member: { role: 'owner' } } as Snapshot;
  respond = defaultResponse;
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: 'visible' });
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
  spyOn(window, 'setTimeout').mockImplementation((callback, delay) => {
    if (typeof callback !== 'function') throw new Error('Expected a mock timer callback');
    const id = ++nextTimer; timers.set(id, { callback: () => callback(), delay: delay || 0 }); return id;
  });
  spyOn(window, 'clearTimeout').mockImplementation(id => { if (id !== undefined) timers.delete(id); });
  spyOn(globalThis, 'clearTimeout').mockImplementation(id => { if (id !== undefined) timers.delete(Number(id)); });
});
afterEach(async () => {
  try { await act(async () => root.unmount()); container.remove(); expect(timers.size).toBe(0); }
  finally { mock.restore(); }
});
async function render(children: ReactNode = <ProvidersSettings/>) { await act(async () => { root.render(children); }); }
function button(label: string, within: ParentNode = container): HTMLButtonElement {
  const element = [...within.querySelectorAll('button')].find(item => item.textContent === label);
  if (!element) throw new Error(`Missing button: ${label}`);
  return element;
}
async function click(label: string, within: ParentNode = container) { await act(async () => button(label, within).click()); }
function mutations() { return requests.filter(request => request.method !== 'GET'); }
function storageContents() { return [...Array(sessionStorage.length)].map((_, index) => sessionStorage.getItem(sessionStorage.key(index)!)).join('') + [...Array(localStorage.length)].map((_, index) => localStorage.getItem(localStorage.key(index)!)).join(''); }
async function keyField() {
  await click('Add API key');
  const input = container.querySelector<HTMLInputElement>('input[type="password"]')!;
  input.value = 'MOCK_WRITE_ONLY_KEY';
  return input;
}
async function chooseMachine(id: string) {
  await act(async () => { const select = container.querySelector<HTMLSelectElement>('select')!; select.value = id; select.dispatchEvent(new browser.Event('change', { bubbles: true })); });
}
async function firePoll() {
  const timer = [...timers.entries()].find(([, item]) => item.delay === 5000);
  expect(timer).toBeDefined();
  timers.delete(timer![0]); await act(async () => timer![1].callback());
}
async function background(hidden = true) {
  Object.defineProperty(document, 'visibilityState', { configurable: true, value: hidden ? 'hidden' : 'visible' });
  await act(async () => document.dispatchEvent(new browser.Event('visibilitychange')));
}

test('owner-only Providers never queries targets for nonowners', async () => {
  app.snapshot.member.role = 'admin'; await render();
  expect(container.textContent).toContain('Only the workspace owner'); expect(requests).toHaveLength(0);
});

test('target picker excludes foreign machines and shows exact target, workspace, backend and separate effective default', async () => {
  await render();
  expect(container.textContent).not.toContain('Not mine');
  for (const text of ['Current default', 'controller.test', 'controller-target', 'workspace', 'https://bot.test', 'Needs login', 'Expired', 'Configured: No', 'Last resolver validation:', 'OPENAI_API_KEY', 'Credential pool', 'Project configuration']) expect(container.textContent).toContain(text);
  await chooseMachine('machine');
  for (const text of ['Owned execution machine', 'worker.test', 'worker-target', 'worker-node']) expect(container.textContent).toContain(text);
  const input = await keyField(); await click('Submit API key');
  expect(input.value).toBe('');
  const write = mutations()[0]!;
  expect(write.path).toBe('/machines/machine/providers/anthropic/api-key'); expect(write.body.targetId).toBe('worker-target');
  expect(new Headers(write.options.headers).get('Authorization')).toBe('Bearer MOCK_PRODUCT_SESSION');
  expect(write.options.credentials).toBe('omit'); expect(write.options.cache).toBe('no-store');
  expect(mutations()).toHaveLength(1);
});

test('API key is password/off-autocomplete, clears synchronously at submit and is never restored, persisted or used to change default', async () => {
  const receipt = deferred<unknown>(); respond = request => request.method === 'PUT' ? receipt.promise : defaultResponse(request);
  await render(); const input = await keyField();
  expect(input.autocomplete).toBe('off'); expect(input.getAttribute('value')).toBeNull(); expect(input.getAttribute('spellcheck')).toBe('false');
  await act(async () => { button('Submit API key').click(); expect(input.value).toBe(''); });
  expect(mutations()[0]!.body.value).toBe('MOCK_WRITE_ONLY_KEY');
  expect(storageContents()).not.toContain('MOCK_WRITE_ONLY_KEY'); expect(container.innerHTML).not.toContain('MOCK_WRITE_ONLY_KEY');
  await act(async () => receipt.resolve(controller));
  await click('Add API key'); expect(container.querySelector<HTMLInputElement>('input[type="password"]')!.value).toBe('');
  expect(mutations().some(request => request.path.endsWith('/default'))).toBe(false);
});

test('credential errors never echo arbitrary messages, details or keys and failure cannot restore secure input', async () => {
  respond = request => request.method === 'PUT' ? Response.json({ error: { code: 'invalid_request', message: 'SERVER ECHO MOCK_WRITE_ONLY_KEY', retrySafe: true, details: { value: 'MOCK_WRITE_ONLY_KEY' }, requestId: 'SECRET_REQUEST_ID' } }, { status: 400 }) : defaultResponse(request);
  await render(); const input = await keyField(); await click('Submit API key');
  expect(input.value).toBe('');
  for (const text of ['SERVER ECHO', 'MOCK_WRITE_ONLY_KEY', 'SECRET_REQUEST_ID']) { expect(container.innerHTML).not.toContain(text); expect(storageContents()).not.toContain(text); }
  await click('Add API key'); expect(container.querySelector<HTMLInputElement>('input[type="password"]')!.value).toBe('');
});

test('secret input clears on cancel, navigation/unmount, visibility, pagehide, account and target changes', async () => {
  await render();
  let input = await keyField(); await click('Cancel', input.form!); expect(input.value).toBe('');
  input = await keyField(); await background(); expect(input.value).toBe(''); await background(false);
  input = await keyField(); await act(async () => window.dispatchEvent(new browser.Event('pagehide'))); expect(input.value).toBe('');
  await act(async () => window.dispatchEvent(new browser.Event('focus')));
  input = await keyField(); await chooseMachine('machine'); expect(input.value).toBe('');
  await chooseMachine(''); input = await keyField();
  app.snapshot = { ...app.snapshot, user: { ...app.snapshot.user, id: 'different-owner' }, workspace: { ...app.snapshot.workspace, ownerUserId: 'different-owner' } };
  await render(); expect(input.value).toBe('');
  app.snapshot.user.id = 'owner'; app.snapshot.workspace.ownerUserId = 'owner'; await render();
  input = await keyField(); await render(<div>Another destination</div>); expect(input.value).toBe('');
  expect(mutations()).toHaveLength(0); expect(storageContents()).not.toContain('MOCK_WRITE_ONLY_KEY');
});

test('invalid UTF-8 size and NUL clear the key without dispatch', async () => {
  await render(); const input = await keyField();
  input.value = '😀'.repeat(4097); await click('Submit API key'); expect(input.value).toBe(''); expect(mutations()).toHaveLength(0);
  input.value = 'MOCK\0KEY'; await click('Submit API key'); expect(input.value).toBe(''); expect(mutations()).toHaveLength(0);
});

test('unknown key mutation keeps fixed nonsecret fence through generic reads and remount; explicit status review is required', async () => {
  respond = request => { if (request.method === 'PUT') throw new Error('NETWORK ECHO MOCK_WRITE_ONLY_KEY'); return defaultResponse(request); };
  await render(); const input = await keyField(); await click('Submit API key'); expect(input.value).toBe('');
  const originalNonce = mutations()[0]!.body.clientNonce;
  expect(storageContents()).toContain(originalNonce!); expect(storageContents()).not.toContain('MOCK_WRITE_ONLY_KEY');
  await render(<div>Left settings</div>); await render();
  expect(button('Add API key').disabled).toBe(true); expect(container.textContent).not.toContain('I’ve checked — start a new change');
  await act(async () => window.dispatchEvent(new browser.CustomEvent('lemon:refresh')));
  const refreshes = [...timers.entries()].filter(([, timer]) => timer.delay === 180);
  for (const [id, timer] of refreshes) { timers.delete(id); await act(async () => timer.callback()); }
  expect(button('Add API key').disabled).toBe(true); expect(container.textContent).not.toContain('I’ve checked — start a new change');
  await click('Check status'); expect(button('Add API key').disabled).toBe(true);
  expect(container.textContent).toContain('This does not confirm the earlier change');
  await click('I’ve checked — start a new change'); expect(button('Add API key').disabled).toBe(false);
  expect(mutations()).toHaveLength(1); expect(storageContents()).toBe('');
});

test('failed GET cannot unlock a provider fence', async () => {
  let failStatus = false;
  respond = request => { if (request.method === 'PUT' || (failStatus && request.path === '/instance/providers')) throw new Error('MOCK unavailable'); return defaultResponse(request); };
  await render(); await keyField(); await click('Submit API key'); failStatus = true; await click('Check status');
  expect(button('Add API key').disabled).toBe(true); expect(container.textContent).not.toContain('I’ve checked — start a new change'); expect(mutations()).toHaveLength(1);
});

test('default changes require a separate review and confirm; cancel sends nothing and never changes credentials or Bots', async () => {
  await render(); await click('Change default'); await click('Review default change');
  let dialog = container.querySelector('[role="dialog"]')!;
  expect(dialog.textContent).toContain('controller.test'); expect(dialog.textContent).toContain('No credential changes and no Bot/profile rewrites');
  await click('Cancel', dialog); expect(mutations()).toHaveLength(0);
  await click('Review default change'); dialog = container.querySelector('[role="dialog"]')!; await click('Confirm', dialog);
  expect(mutations()).toHaveLength(1); expect(mutations()[0]!.path).toBe('/instance/providers/default');
  expect(mutations()[0]!.body).toMatchObject({ targetId: 'controller-target', providerId: 'anthropic', modelId: 'model-one' });
});

test('disconnect confirmation explicitly means local removal, not provider revocation; cancel is inert', async () => {
  await render(); await click('Disconnect', container.querySelectorAll('article')[1]!); let dialog = container.querySelector('[role="dialog"]')!;
  expect(dialog.textContent).toContain('not provider-side key or OAuth grant revocation'); expect(dialog.textContent).toContain('default and all Bots/profiles are unchanged');
  await click('Cancel', dialog); expect(mutations()).toHaveLength(0);
  await click('Disconnect', container.querySelectorAll('article')[1]!); dialog = container.querySelector('[role="dialog"]')!; await click('Confirm', dialog);
  expect(mutations()).toHaveLength(1); expect(mutations()[0]!.path).toBe('/instance/providers/openai_codex/disconnect');
});

test('device login uses canonical provider, explicit exact browser link, transient code and bounded fixed-nonce polling', async () => {
  const open = spyOn(window, 'open'); await render(); expect(mutations()).toHaveLength(0);
  await click('Re-authenticate'); expect(open).not.toHaveBeenCalled();
  const start = mutations()[0]!;
  expect(start.path).toBe('/instance/providers/openai_codex/device-login');
  const link = container.querySelector<HTMLAnchorElement>('a[target="_blank"]')!;
  expect(link.href).toBe('https://auth.openai.com/codex/device'); expect(link.rel).toBe('noopener noreferrer'); expect(link.referrerPolicy).toBe('no-referrer');
  expect(container.textContent).toContain('MOCK-CODE'); expect(container.textContent).toContain('If the new tab does not open');
  expect(storageContents()).not.toContain('MOCK-CODE'); expect(storageContents()).not.toContain('https://auth.openai.com');
  await firePoll(); await firePoll();
  const polls = mutations().filter(request => request.path.endsWith('/poll'));
  expect(polls).toHaveLength(2); expect(polls[0]!.body.clientNonce).toBe(polls[1]!.body.clientNonce);
  expect(polls[0]!.body.clientNonce).not.toBe(start.body.clientNonce); expect(polls[0]!.path).toContain(start.body.clientNonce!);
  expect(mutations().some(request => request.path.endsWith('/default'))).toBe(false);
});

test('unknown device poll stops automatically; explicit reconciliation repeats only that exact fixed intent', async () => {
  let fail = true;
  respond = request => { if (request.path.endsWith('/poll') && fail) throw new Error('MOCK unknown'); return defaultResponse(request); };
  await render(); await click('Re-authenticate'); await firePoll();
  const uncertainPoll = mutations()[1]!;
  expect([...timers.values()].some(timer => timer.delay === 5000)).toBe(false); expect(container.textContent).not.toContain('MOCK-CODE');
  await click('Check status'); expect(mutations()).toHaveLength(2); expect(button('Re-authenticate').disabled).toBe(true);
  fail = false; await click('Check this login');
  expect(mutations()[2]!.path).toBe(uncertainPoll.path); expect(mutations()[2]!.body).toEqual(uncertainPoll.body);
  expect(mutations().filter(request => request.path.endsWith('/device-login'))).toHaveLength(1);
});

test('unknown device start reconciles exact start nonce; cancel uses another fixed nonce and terminal reloads status', async () => {
  let failStart = true; let failCancel = true;
  respond = request => {
    if (request.path.endsWith('/device-login') && failStart) throw new Error('MOCK start unknown');
    if (request.path.endsWith('/cancel') && failCancel) throw new Error('MOCK cancel unknown');
    return defaultResponse(request);
  };
  await render(); await click('Re-authenticate'); const start = mutations()[0]!;
  failStart = false; await click('Check this login'); expect(mutations()[1]!.body).toEqual(start.body);
  await click('Cancel sign-in'); const cancel = mutations()[2]!;
  expect(cancel.body.clientNonce).not.toBe(start.body.clientNonce); expect(cancel.path).toContain(start.body.clientNonce!);
  const reads = requests.filter(request => request.method === 'GET').length;
  failCancel = false; await click('Check this login');
  expect(mutations()[3]!.body).toEqual(cancel.body); expect(mutations()[3]!.path).toBe(cancel.path);
  expect(requests.filter(request => request.method === 'GET').length).toBeGreaterThan(reads);
  expect(container.textContent).toContain('Sign-in cancelled'); expect(button('Re-authenticate').disabled).toBe(false);
  expect(storageContents()).toBe(''); expect([...timers.values()].some(timer => timer.delay === 5000)).toBe(false);
});

test.each(['completed', 'denied', 'expired', 'lost', 'failed'] as const)('terminal %s stops polling, clears code and reloads status without claiming Ready', async status => {
  respond = request => request.path.endsWith('/poll') ? terminal(request, status) : defaultResponse(request);
  await render(); await click('Re-authenticate'); await firePoll();
  expect(container.textContent).not.toContain('MOCK-CODE'); expect(container.textContent).toContain('completion alone does not prove readiness');
  expect(requests.filter(request => request.method === 'GET' && request.path === '/instance/providers').length).toBe(2);
  expect([...timers.values()].some(timer => timer.delay === 5000)).toBe(false); expect(storageContents()).toBe('');
});

test('background removes code/link and stops polling; foreground requires explicit exact-login check', async () => {
  await render(); await click('Re-authenticate'); await background();
  expect(container.textContent).not.toContain('MOCK-CODE'); expect(container.querySelector('a')).toBeNull(); expect(timers.size).toBe(0);
  await background(false); expect(mutations()).toHaveLength(1); expect(container.textContent).not.toContain('MOCK-CODE');
  await click('Check this login'); expect(mutations()).toHaveLength(2); expect(mutations()[1]!.path).toContain('/poll');
});

test('late device start cannot restore code after backgrounding', async () => {
  const result = deferred<unknown>(); let start: MockRequest | undefined;
  respond = request => { if (request.path.endsWith('/device-login')) { start = request; return result.promise; } return defaultResponse(request); };
  await render(); await click('Re-authenticate'); await background(); await act(async () => result.resolve(pending(start!)));
  expect(container.textContent).not.toContain('MOCK-CODE'); expect(container.querySelector('a')).toBeNull(); expect(timers.size).toBe(0);
});

test('late device result is discarded across target and account changes; safe journal is session scoped', async () => {
  const result = deferred<unknown>(); let start: MockRequest | undefined;
  respond = request => { if (request.path.endsWith('/device-login')) { start = request; return result.promise; } return defaultResponse(request); };
  await render(); await click('Re-authenticate'); await chooseMachine('machine'); await act(async () => result.resolve(pending(start!)));
  expect(container.textContent).toContain('worker.test'); expect(container.textContent).not.toContain('MOCK-CODE'); expect(button('Re-authenticate').disabled).toBe(false);
  await chooseMachine(''); expect(button('Re-authenticate').disabled).toBe(true); expect(container.textContent).toContain('Check this login');
  app.client = mockClient();
  respond = request => request.path === '/auth/sessions' ? { items: [{ id: 'another-session', current: true }], nextCursor: null } : defaultResponse(request);
  await render(); expect(button('Re-authenticate').disabled).toBe(false); expect(container.textContent).not.toContain('MOCK-CODE');
});

test('untrusted verification URL and mismatched login binding fail closed', async () => {
  respond = request => request.path.endsWith('/device-login') ? { ...pending(request), verificationUrl: 'https://evil.test/MOCK_SECRET' } : defaultResponse(request);
  await render(); await click('Re-authenticate'); expect(container.querySelector('a')).toBeNull(); expect(container.innerHTML).not.toContain('evil.test'); expect(storageContents()).not.toContain('MOCK_SECRET');
  const intent = { kind: 'device', clientNonce: 'login', targetId: 'target', providerId: 'openai_codex', pollNonce: 'poll', cancelNonce: 'cancel', action: 'start', startedAtMs: Date.now() } as const;
  expect(() => checkedDeviceLogin({ ...pending({ path: '/device-login', body: { clientNonce: 'different', targetId: 'target' } } as MockRequest) }, intent)).toThrow();
  expect(providerFailure(new Error('MOCK_SECRET')).message).not.toContain('MOCK_SECRET');
});

test('journal parsing allowlists fields and does not restore injected credential/code/URL properties', () => {
  sessionStorage.setItem('mock-journal', JSON.stringify({ kind: 'api_key', clientNonce: 'nonce', targetId: 'target', providerId: 'anthropic', value: 'MOCK_KEY', userCode: 'MOCK_CODE', verificationUrl: 'https://evil.test' }));
  expect(readProviderIntent('mock-journal')).toEqual({ kind: 'api_key', clientNonce: 'nonce', targetId: 'target', providerId: 'anthropic' });
  sessionStorage.setItem('mock-journal', JSON.stringify({ kind: 'device', clientNonce: 'nonce', targetId: 'target', providerId: 'alias', pollNonce: 'poll', cancelNonce: 'cancel', action: 'poll', startedAtMs: Date.now() }));
  expect(readProviderIntent('mock-journal')).toBeNull();
});

test.each(['default', 'disconnect'] as const)('unknown %s is never resent by GET and remains fenced until explicit observed-status review', async kind => {
  respond = request => { if (request.method === 'POST') throw new Error('MOCK ambiguous receipt'); return defaultResponse(request); };
  await render();
  if (kind === 'default') { await click('Change default'); await click('Review default change'); }
  else await click('Disconnect', container.querySelectorAll('article')[1]!);
  await click('Confirm', container.querySelector('[role="dialog"]')!);
  const original = mutations()[0]!;
  expect(storageContents()).toContain(original.body.clientNonce!);
  await click('Check status');
  expect(mutations()).toHaveLength(1); expect(button('Change default').disabled).toBe(true);
  await click('I’ve checked — start a new change');
  expect(button('Change default').disabled).toBe(false); expect(mutations()).toHaveLength(1);
});

test('late API-key receipt cannot replace status on another execution target', async () => {
  const result = deferred<unknown>();
  respond = request => request.method === 'PUT' ? result.promise : defaultResponse(request);
  await render(); await keyField(); await click('Submit API key'); await chooseMachine('machine');
  await act(async () => result.resolve({ ...controller, default: { providerId: 'STALE_PROVIDER', modelId: 'STALE_MODEL' } }));
  expect(container.textContent).toContain('worker.test'); expect(container.textContent).not.toContain('STALE_PROVIDER'); expect(container.textContent).not.toContain('STALE_MODEL');
  expect(button('Add API key').disabled).toBe(false);
});

test('a changed product account discards late device results and does not inherit another owner’s intent', async () => {
  const result = deferred<unknown>(); let start: MockRequest | undefined;
  respond = request => { if (request.path.endsWith('/device-login')) { start = request; return result.promise; } return defaultResponse(request); };
  await render(); await click('Re-authenticate');
  app.snapshot = { ...app.snapshot, user: { ...app.snapshot.user, id: 'new-owner' }, workspace: { ...app.snapshot.workspace, ownerUserId: 'new-owner' } };
  app.client = mockClient(); await render();
  await act(async () => result.resolve(pending(start!)));
  expect(container.textContent).not.toContain('MOCK-CODE'); expect(button('Re-authenticate').disabled).toBe(false);
  expect(mutations()).toHaveLength(1);
});

test('device code expiry clears the code without an early poll, retaining the exact login for explicit reconciliation', async () => {
  const now = spyOn(Date, 'now').mockReturnValue(100000);
  respond = request => request.path.endsWith('/device-login') ? { ...pending(request), expiresAtMs: 101000 } : defaultResponse(request);
  await render(); await click('Re-authenticate');
  const timer = [...timers.entries()].find(([, item]) => item.delay === 1000)!;
  now.mockReturnValue(101000); timers.delete(timer[0]); await act(async () => timer[1].callback());
  expect(mutations()).toHaveLength(1); expect(container.textContent).not.toContain('MOCK-CODE'); expect(container.textContent).toContain('Check this login');
  expect(button('Re-authenticate').disabled).toBe(true);
});

test('starting state is bounded by the original fifteen-minute login deadline', async () => {
  const now = spyOn(Date, 'now').mockReturnValue(100000);
  respond = request => request.path.endsWith('/device-login') ? terminal(request, 'starting') : defaultResponse(request);
  await render(); await click('Re-authenticate');
  const timer = [...timers.entries()].find(([, item]) => item.delay === 1000)!;
  now.mockReturnValue(100000 + 900000); timers.delete(timer[0]); await act(async () => timer[1].callback());
  expect(mutations()).toHaveLength(1); expect(container.textContent).toContain('Check this exact login'); expect(timers.size).toBe(0);
});

test('only canonical advertised Codex device-code metadata exposes phone sign-in', async () => {
  respond = request => request.path === '/instance/providers' ? { ...controller, providers: [
    { ...controller.providers[0], configured: true, status: 'ready', methods: ['unsupported'] },
    { ...controller.providers[1], id: 'openai-codex', status: 'configured' },
  ] } : defaultResponse(request);
  await render();
  expect(container.textContent).toContain('Ready'); expect(container.textContent).toContain('Configured');
  expect(container.textContent).toContain('No supported sign-in method');
  expect([...container.querySelectorAll('button')].some(item => item.textContent === 'Re-authenticate' || item.textContent === 'Sign in with device code')).toBe(false);
  expect(mutations()).toHaveLength(0);
});

test('mismatched enrolled node identity prevents writes and never displays a wrong target as selected', async () => {
  respond = request => request.path === '/machines/machine/providers' ? { ...worker, target: { ...worker.target, nodeId: 'another-node' } } : defaultResponse(request);
  await render(); await chooseMachine('machine');
  expect(container.textContent).toContain('Provider status could not be loaded');
  expect(container.textContent).not.toContain('worker.test'); expect(container.querySelector('input[type="password"]')).toBeNull();
  expect(mutations()).toHaveLength(0);
});

test('blur clears a secure field before a browser background snapshot and never restores it on focus', async () => {
  await render(); const input = await keyField();
  await act(async () => window.dispatchEvent(new browser.Event('blur')));
  expect(input.value).toBe(''); expect(container.querySelector('input[type="password"]')).toBeNull();
  await act(async () => window.dispatchEvent(new browser.Event('focus')));
  await click('Add API key'); expect(container.querySelector<HTMLInputElement>('input[type="password"]')!.value).toBe('');
  expect(mutations()).toHaveLength(0);
});

test('storage refusal prevents credential dispatch rather than losing the reconciliation fence', async () => {
  await render(); const input = await keyField();
  // happy-dom Storage proxies resolve methods independently of prototype spies.
  const storage = sessionStorage;
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: {
    getItem: storage.getItem.bind(storage), removeItem: storage.removeItem.bind(storage),
    setItem: () => { throw new Error('MOCK storage disabled'); },
  } });
  try {
    await click('Submit API key');
    expect(input.value).toBe(''); expect(mutations()).toHaveLength(0); expect(container.innerHTML).not.toContain('MOCK_WRITE_ONLY_KEY');
  } finally { Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, writable: true, value: storage }); }
});
