import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act, type ReactNode } from 'react';
import type { Root } from 'react-dom/client';
import { LemonBotError, type DetectedLogin, type ModelReadiness, type ProviderManagement } from '@lemon-bot/sdk';
import { app, bot, calls, machine, resetFixtures, responses, useApp } from './fixtures/bots-machines';

// MOCK TRANSPORT ONLY: no real provider credentials, sign-in or target configuration is used here.
const browser = new Window({ url: 'https://bot.test/' });
Object.assign(globalThis, {
  window: browser,
  document: browser.document,
  navigator: browser.navigator,
  HTMLElement: browser.HTMLElement,
  HTMLInputElement: browser.HTMLInputElement,
  Event: browser.Event,
  sessionStorage: browser.sessionStorage,
  localStorage: browser.localStorage,
  requestAnimationFrame: browser.requestAnimationFrame.bind(browser),
  cancelAnimationFrame: browser.cancelAnimationFrame.bind(browser),
  CustomEvent: browser.CustomEvent,
  ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
  IntersectionObserver: class { observe() {} unobserve() {} disconnect() {} },
  IS_REACT_ACT_ENVIRONMENT: true,
});
const { createRoot } = await import('react-dom/client');
mock.module('../src/app', () => ({ useApp }));

// Loaded after mock.module so the screens bind this fixture context, not the real app context.
const { CreateBot } = await import('../src/features/bots/editor');
const { ConversationScreen } = await import('../src/features/chat');
const { getModelReadinessSkip, ModelStatusLine } = await import('../src/features/bots/model-readiness');

const readiness = (overrides: Partial<ModelReadiness> = {}): ModelReadiness => ({
  state: 'verified', providerId: 'openai_codex', modelId: 'gpt-6.1-sol', check: 'codex_discovery',
  reason: null, availableModelIds: ['gpt-6.1-sol'], suggestedModelId: 'gpt-6.1-sol', checkedAtMs: 1800000000000,
  ...overrides,
});
const management = (overrides: Partial<ProviderManagement> = {}): ProviderManagement => ({
  target: { id: 'worker-target', nodeId: machine.nodeId, hostname: 'studio.local' },
  default: { providerId: 'openai_codex', modelId: 'gpt-6.1-sol' },
  providers: [
    { id: 'anthropic', displayName: 'Anthropic', methods: ['api_key'], configured: false, status: 'needs_login', lastValidation: null, environmentOverrides: [], configurationOverrides: [] },
    { id: 'openai_codex', displayName: 'ChatGPT / Codex', methods: ['device_code'], configured: false, status: 'needs_login', lastValidation: null, environmentOverrides: [], configurationOverrides: [] },
  ],
  readiness: readiness(),
  detected: [],
  ...overrides,
});
const codexDetected: DetectedLogin[] = [{ source: 'codex_cli', providerId: 'openai_codex' }];

let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  resetFixtures();
  app.snapshot.member.role = 'owner';
  sessionStorage.clear();
  container = document.createElement('div');
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
    container.remove();
    for (const node of [...document.body.querySelectorAll('.modal-backdrop')]) node.remove();
  } finally {
    mock.restore();
  }
});

async function render(children: ReactNode) { await act(async () => root.render(children)); }
/** Lets a whole connect sequence (import → check → default → check) settle before asserting. */
async function flush() {
  const { promise, resolve } = Promise.withResolvers<void>();
  setTimeout(resolve, 0);
  await act(async () => { await promise; });
}
function button(label: string, within: ParentNode = container): HTMLButtonElement {
  const element = [...within.querySelectorAll('button')].find(item => item.textContent === label);
  if (!element) throw new Error(`Missing button: ${label}`);
  return element;
}
async function nameTheBot() {
  const input = container.querySelector('input[required]') as HTMLInputElement;
  await act(async () => {
    Object.getOwnPropertyDescriptor(browser.HTMLInputElement.prototype, 'value')!.set!.call(input, 'Alpha Bot');
    input.dispatchEvent(new browser.Event('input', { bubbles: true }));
  });
}
function providerCalls(endpoint: string) { return calls.filter(call => call.endpoint === endpoint); }
function bodyOf(call: { options: unknown } | undefined): Record<string, unknown> {
  const options = call?.options;
  if (options && typeof options === 'object' && 'body' in options && options.body && typeof options.body === 'object') return options.body as Record<string, unknown>;
  return {};
}

test('verified readiness shows the model and enables Create without another check', async () => {
  responses.set('GET /machines/:id/providers', management());
  await render(<CreateBot />);
  await flush();
  await nameTheBot();
  expect(container.textContent).toContain('Verified');
  expect(container.textContent).toContain('gpt-6.1-sol');
  expect(providerCalls('POST /machines/:id/providers/check')).toHaveLength(0);
  expect(button('Create Bot').disabled).toBe(false);
});

test('saved readiness counts as ready and names the first-message check', async () => {
  responses.set('GET /machines/:id/providers', management({ readiness: readiness({ state: 'saved', check: null, reason: 'check_unavailable' }) }));
  responses.set('POST /machines/:id/providers/check', { management: management({ readiness: readiness({ state: 'saved', check: null, reason: 'check_unavailable' }) }), readiness: readiness({ state: 'saved', check: null, reason: 'check_unavailable' }) });
  await render(<CreateBot />);
  await flush();
  await nameTheBot();
  expect(container.textContent).toContain('Lemon checks it on your first message');
  expect(button('Create Bot').disabled).toBe(false);
});

test('action_required with a stored credential runs exactly one automatic non-generating check', async () => {
  const stale = management({
    providers: [{ id: 'openai_codex', displayName: 'ChatGPT / Codex', methods: ['device_code'], configured: true, status: 'expired', lastValidation: null, environmentOverrides: [], configurationOverrides: [] }],
    readiness: readiness({ state: 'action_required', reason: 'credential_expired', check: null, checkedAtMs: null }),
  });
  responses.set('GET /machines/:id/providers', stale);
  responses.set('POST /machines/:id/providers/check', { management: management(), readiness: readiness() });
  await render(<CreateBot />);
  await flush();
  await nameTheBot();
  const checks = providerCalls('POST /machines/:id/providers/check');
  expect(checks).toHaveLength(1);
  expect(bodyOf(checks[0]).targetId).toBe('worker-target');
  expect(bodyOf(checks[0]).clientNonce).toBeString();
  expect(container.textContent).toContain('Verified');
  expect(button('Create Bot').disabled).toBe(false);
});

test('detected Codex login shows the consent sentence and one click runs import, check, default and check', async () => {
  responses.set('GET /machines/:id/providers', management({
    default: { providerId: null, modelId: null },
    readiness: readiness({ state: 'not_configured', providerId: null, modelId: null, check: null, reason: 'no_default', availableModelIds: null, suggestedModelId: null, checkedAtMs: null }),
    detected: codexDetected,
  }));
  responses.set('POST /machines/:id/providers/:providerId/import', management({ default: { providerId: null, modelId: null }, readiness: readiness({ state: 'action_required', reason: 'no_default' }), detected: codexDetected }));
  responses.set('POST /machines/:id/providers/check', { management: management({ detected: codexDetected }), readiness: readiness() });
  responses.set('POST /machines/:id/providers/default', management({ detected: codexDetected }));

  await render(<CreateBot />);
  await flush();
  await nameTheBot();

  expect(container.textContent).toContain('Codex CLI ChatGPT login found on Studio Mac');
  expect(container.textContent).toContain('Your ~/.codex/auth.json is not changed');
  expect(container.textContent).toContain('Lemon and the Codex CLI will share this login; if either refreshes it, the other may need to sign in again.');
  expect(button('Create Bot').disabled).toBe(true);
  expect(providerCalls('POST /machines/:id/providers/:providerId/import')).toHaveLength(0);

  await act(async () => button('Use your Codex CLI login').click());
  await flush();

  const imports = providerCalls('POST /machines/:id/providers/:providerId/import');
  expect(imports).toHaveLength(1);
  expect(bodyOf(imports[0])).toMatchObject({ targetId: 'worker-target', source: 'codex_cli', consent: 'copy_login' });
  const checks = providerCalls('POST /machines/:id/providers/check');
  expect(checks).toHaveLength(2);
  expect(bodyOf(checks[0]).providerId).toBe('openai_codex');
  expect(bodyOf(checks[1]).providerId).toBeUndefined();
  const defaults = providerCalls('POST /machines/:id/providers/default');
  expect(defaults).toHaveLength(1);
  expect(bodyOf(defaults[0])).toMatchObject({ providerId: 'openai_codex', modelId: 'gpt-6.1-sol' });
  // Every request carries its own nonce; none is reused.
  const nonces = [...imports, ...checks, ...defaults].map(call => bodyOf(call).clientNonce);
  expect(new Set(nonces).size).toBe(nonces.length);
  expect(button('Create Bot').disabled).toBe(false);
});

test('a provider-scoped check never counts as the current default’s readiness, and no default is set without a model', async () => {
  responses.set('GET /machines/:id/providers', management({
    default: { providerId: 'anthropic', modelId: 'claude-model' },
    readiness: readiness({ state: 'action_required', providerId: 'anthropic', modelId: 'claude-model', reason: 'credential_missing', check: null, checkedAtMs: null }),
    detected: codexDetected,
  }));
  responses.set('POST /machines/:id/providers/:providerId/import', management({ detected: codexDetected }));
  // The scoped check reports the imported provider with no model it can suggest.
  responses.set('POST /machines/:id/providers/check', {
    management: management({ detected: codexDetected }),
    readiness: readiness({ state: 'action_required', reason: 'model_unavailable', availableModelIds: [], suggestedModelId: null }),
  });
  await render(<CreateBot />);
  await flush();
  await act(async () => button('Use your Codex CLI login').click());
  await flush();
  expect(providerCalls('POST /machines/:id/providers/check')).toHaveLength(2);
  expect(providerCalls('POST /machines/:id/providers/default')).toHaveLength(0);
});

test('device sign-in reuses the existing device-code flow', async () => {
  responses.set('GET /machines/:id/providers', management({
    readiness: readiness({ state: 'not_configured', providerId: null, modelId: null, check: null, reason: 'no_default', availableModelIds: null, suggestedModelId: null, checkedAtMs: null }),
  }));
  // A device receipt is accepted only when it echoes the login nonce this client dispatched.
  responses.set('POST /machines/:id/providers/:providerId/device-login', {
    get loginId() { return String(bodyOf(providerCalls('POST /machines/:id/providers/:providerId/device-login').at(-1)).clientNonce); },
    targetId: 'worker-target', providerId: 'openai_codex', status: 'pending',
    verificationUrl: 'https://auth.openai.com/codex/device', userCode: 'MOCK-CODE', expiresAtMs: Date.now() + 600000, pollIntervalMs: 5000,
  });
  await render(<CreateBot />);
  await flush();
  await act(async () => button('Sign in with ChatGPT (device code)').click());
  await flush();
  const started = providerCalls('POST /machines/:id/providers/:providerId/device-login');
  expect(started).toHaveLength(1);
  expect(bodyOf(started[0]).targetId).toBe('worker-target');
  expect(container.textContent).toContain('Waiting for sign-in');
  expect(container.textContent).toContain('MOCK-CODE');
});

test('a device receipt for another login is rejected without showing a code', async () => {
  responses.set('GET /machines/:id/providers', management({
    readiness: readiness({ state: 'not_configured', providerId: null, modelId: null, check: null, reason: 'no_default', availableModelIds: null, suggestedModelId: null, checkedAtMs: null }),
  }));
  responses.set('POST /machines/:id/providers/:providerId/device-login', {
    loginId: 'another-login', targetId: 'worker-target', providerId: 'openai_codex', status: 'pending',
    verificationUrl: 'https://auth.openai.com/codex/device', userCode: 'MOCK-CODE', expiresAtMs: Date.now() + 600000, pollIntervalMs: 5000,
  });
  await render(<CreateBot />);
  await flush();
  await act(async () => button('Sign in with ChatGPT (device code)').click());
  await flush();
  expect(container.textContent).not.toContain('MOCK-CODE');
  expect(container.textContent).toContain('We couldn’t confirm this change.');
});

test('Paste an API key opens the write-only form outside the Create Bot form', async () => {
  responses.set('GET /machines/:id/providers', management({
    readiness: readiness({ state: 'not_configured', providerId: null, modelId: null, check: null, reason: 'no_default', availableModelIds: null, suggestedModelId: null, checkedAtMs: null }),
  }));
  await render(<CreateBot />);
  await flush();
  await act(async () => button('Paste an API key').click());
  const dialog = document.body.querySelector('[role="dialog"]')!;
  expect(dialog).toBeTruthy();
  expect(dialog.querySelector('input[type="password"]')).toBeTruthy();
  expect(container.querySelector('form form')).toBeNull();
  expect(dialog.textContent).toContain('never restored or saved in browser storage');
});

test('Skip for now enables Create and remembers the choice for that machine only', async () => {
  responses.set('GET /machines/:id/providers', management({
    readiness: readiness({ state: 'not_configured', providerId: null, modelId: null, check: null, reason: 'no_default', availableModelIds: null, suggestedModelId: null, checkedAtMs: null }),
  }));
  await render(<CreateBot />);
  await flush();
  await nameTheBot();
  expect(button('Create Bot').disabled).toBe(true);

  await act(async () => button('Skip for now').click());
  expect(button('Create Bot').disabled).toBe(false);
  expect(getModelReadinessSkip('workspace_test', machine.id)).toBe(true);
  expect(getModelReadinessSkip('workspace_test', 'machine_other')).toBe(false);
  expect(container.textContent).toContain('Skipped for now');
  expect(providerCalls('POST /machines/:id/providers/check')).toHaveLength(0);
});

test('connecting after a skip clears the remembered skip for that machine', async () => {
  sessionStorage.setItem(`lemonbot.model-readiness-skip:workspace_test:${machine.id}`, 'true');
  responses.set('GET /machines/:id/providers', management({
    readiness: readiness({ state: 'action_required', reason: 'credential_missing', checkedAtMs: null }),
    detected: codexDetected,
  }));
  responses.set('POST /machines/:id/providers/:providerId/import', management({ detected: codexDetected }));
  responses.set('POST /machines/:id/providers/check', { management: management({ detected: codexDetected }), readiness: readiness() });
  responses.set('POST /machines/:id/providers/default', management({ detected: codexDetected }));
  await render(<CreateBot />);
  await flush();
  expect(container.textContent).toContain('Skipped for now');
  await act(async () => button('Connect a model').click());
  await act(async () => button('Use your Codex CLI login').click());
  await flush();
  expect(getModelReadinessSkip('workspace_test', machine.id)).toBe(false);
  expect(container.textContent).toContain('Verified');
});

test('a failed connect reports the capability message and keeps the gate closed', async () => {
  responses.set('GET /machines/:id/providers', management({
    readiness: readiness({ state: 'not_configured', providerId: null, modelId: null, check: null, reason: 'no_default', availableModelIds: null, suggestedModelId: null, checkedAtMs: null }),
    detected: codexDetected,
  }));
  responses.set('POST /machines/:id/providers/:providerId/import', new LemonBotError({ code: 'capability_unavailable', message: 'unsupported', requestId: 'req_test', retrySafe: true }));
  await render(<CreateBot />);
  await flush();
  await nameTheBot();
  await act(async () => button('Use your Codex CLI login').click());
  await flush();
  expect(container.textContent).toContain('This sign-in method is not available on the execution target.');
  expect(providerCalls('POST /machines/:id/providers/check')).toHaveLength(0);
  expect(button('Create Bot').disabled).toBe(true);
});

test('a runtime without the readiness capability never gates Create', async () => {
  responses.set('GET /machines/:id/providers', management({ readiness: null, detected: [] }));
  await render(<CreateBot />);
  await flush();
  await nameTheBot();
  expect(container.textContent).toContain('Model status unavailable');
  expect(button('Create Bot').disabled).toBe(false);
  expect(providerCalls('POST /machines/:id/providers/check')).toHaveLength(0);
});

test('a caller who cannot manage providers is never read for readiness and never gates Create', async () => {
  app.snapshot.member.role = 'member';
  responses.set('GET /machines/:id/providers', management());
  await render(<CreateBot />);
  await flush();
  await nameTheBot();
  expect(container.textContent).toContain('Model status unavailable');
  expect(providerCalls('GET /machines/:id/providers')).toHaveLength(0);
  expect(button('Create Bot').disabled).toBe(false);
});

test('a skipped machine shows a non-blocking conversation banner that opens the connect panel', async () => {
  sessionStorage.setItem(`lemonbot.model-readiness-skip:workspace_test:${machine.id}`, 'true');
  responses.set('GET /machines/:id/providers', management({
    readiness: readiness({ state: 'action_required', reason: 'credential_missing', check: null, checkedAtMs: null }),
    detected: codexDetected,
  }));
  responses.set('GET /conversations/:id', {
    id: 'conversation_empty', revision: 1, createdAtMs: 1, updatedAtMs: 1, kind: 'dm', name: 'Research partner',
    botIds: [bot.id], ownerUserId: 'owner', parentConversationId: null, leadBotId: bot.id, channelBindingId: null,
    lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [],
  });
  responses.set('GET /conversations/:id/entries', { items: [], nextCursor: null });
  responses.set('GET /runs', { items: [], nextCursor: null });

  await render(<ConversationScreen route={{ screen: 'conversation', id: 'conversation_empty' }} />);
  await flush();

  expect(container.textContent).toContain('No model is connected on Studio Mac');
  // The banner never blocks the transcript or the composer.
  expect(container.querySelector('.chat-transcript')).toBeTruthy();

  await act(async () => button('Connect a model').click());
  await flush();
  const dialog = container.querySelector('[role="dialog"][aria-label="Connect a model"]');
  expect(dialog).toBeTruthy();
  // The remembered skip survives opening (and closing) the dialog; only a successful connect clears it.
  expect(getModelReadinessSkip('workspace_test', machine.id)).toBe(true);
  expect(dialog!.textContent).toContain('Use your Codex CLI login');
  expect(dialog!.textContent).not.toContain('Skip for now');
});

for (const [state, label] of [['verified', 'Model: Verified'], ['saved', 'Model: Saved'], ['action_required', 'Model: Not connected'], ['not_configured', 'Model: Not connected']] as const) {
  test(`the first-run card reports “${label}” for a ${state} machine`, async () => {
    responses.set('GET /machines/:id/providers', management({ readiness: readiness({ state }) }));
    await render(<ModelStatusLine machineId={machine.id} />);
    await flush();
    expect(container.textContent).toContain(label);
    expect(container.textContent).toContain('Studio Mac');
  });
}

test('the first-run card stays silent when the target has no readiness capability', async () => {
  responses.set('GET /machines/:id/providers', management({ readiness: null }));
  await render(<ModelStatusLine machineId={machine.id} />);
  await flush();
  expect(container.textContent).toBe('');
});

test('the first-run card never reads providers for a caller who cannot manage them', async () => {
  app.snapshot.member.role = 'member';
  responses.set('GET /machines/:id/providers', management());
  await render(<ModelStatusLine machineId={machine.id} />);
  await flush();
  expect(container.textContent).toBe('');
  expect(providerCalls('GET /machines/:id/providers')).toHaveLength(0);
});
