import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act, type ReactNode } from 'react';
import type { Root } from 'react-dom/client';
import type { AppContextValue } from '../src/app';
import type { BotGrant, MachineCapabilities, Page } from '@lemon-bot/sdk';
import { bot, machine } from './fixtures/bots-machines';

const browser = new Window({ url: 'https://bot.test/' });
Object.assign(globalThis, {
  window: browser,
  document: browser.document,
  navigator: browser.navigator,
  HTMLElement: browser.HTMLElement,
  Event: browser.Event,
  CustomEvent: browser.CustomEvent,
  ResizeObserver: browser.ResizeObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
// React DOM reads browser globals during initialization, so this test installs happy-dom first.
const { createRoot } = await import('react-dom/client');

const resource = { revision: 1, createdAtMs: 1, updatedAtMs: 1 };
const initial: BotGrant = { ...resource, id: 'grant_terminal', botId: bot.id, machineId: machine.id, capabilityId: 'terminal', requestedLevel: 'off', pendingLevel: null, effectiveLevel: 'off', reasons: ['destination_shell_measured'] };
const stale: BotGrant = { ...initial, revision: 2, requestedLevel: 'read_interact', effectiveLevel: 'off', reasons: ['Tool-policy cutover has not been acknowledged.'] };
const effective: BotGrant = { ...stale, revision: 3, effectiveLevel: 'read_interact', reasons: ['destination_shell_measured'] };
const capabilities: MachineCapabilities = { machineId: machine.id, os: 'macOS', measuredAtMs: 1, stale: false, items: [{ id: 'terminal', name: 'Terminal', category: 'shell', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['bash'], reason: 'destination_shell_measured', measuredAtMs: 1, stale: false }] };
const staleRead = Promise.withResolvers<Page<BotGrant>>();
let grantReads = 0;
const calls: string[] = [];
let current: BotGrant | undefined;
let patched = effective;
let botFolder: boolean | undefined;
let workspaceReads: 'allow' | 'ask' = 'ask';
let currentRunId: string | null = 'run_from_presence';
let presenceStale = false;
const cancelled: string[] = [];
const app = {
  online: true,
  client: { call: async (endpoint: string, options?: { params?: { id?: string } }) => {
    calls.push(endpoint);
    if (endpoint === 'GET /bots/:id/grants') {
      grantReads++;
      if (current) return { items: [current], nextCursor: null };
      if (grantReads === 1) return { items: [initial], nextCursor: null };
      if (grantReads === 2) return staleRead.promise;
      return { items: [effective], nextCursor: null };
    }
    if (endpoint === 'PATCH /bots/:id/grants/:grantId') { current = current ? patched : undefined; return patched; }
    if (endpoint === 'GET /machines/:id/capabilities') return { ...capabilities, botFolder };
    if (endpoint === 'GET /policies/effective') return { userId: bot.ownerUserId, botId: bot.id, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, workspaceReads, rules: [], networkPolicies: [], explanations: [] };
    if (endpoint === 'GET /bots/:id/presence') return { botId: bot.id, status: currentRunId ? 'working' : 'idle', machineId: machine.id, machineLabel: machine.name, machineStatus: machine.status, currentRunId, taskConversationId: null, summary: currentRunId ? 'Working' : 'Idle', evidenceEntryId: null, measuredAtMs: Date.now(), stale: presenceStale };
    if (endpoint === 'POST /runs/:id/cancel') { cancelled.push(options?.params?.id ?? ''); return {}; }
    if (endpoint === 'GET /bots/:id/connectors') return { items: [], nextCursor: null };
    throw new Error(`Unexpected test endpoint: ${endpoint}`);
  } },
} as unknown as AppContextValue;
mock.module('../src/app', () => ({ useApp: () => app }));
// GrantsPanel must load after the app-context mock; this test intentionally exercises that module boundary.
const { GrantsPanel } = await import('../src/features/bots/grants');

let container: HTMLDivElement;
let root: Root;
beforeEach(() => {
  grantReads = 0;
  calls.length = 0;
  current = undefined; patched = effective; botFolder = undefined; workspaceReads = 'ask';
  currentRunId = 'run_from_presence'; presenceStale = false; cancelled.length = 0; app.online = true;
  container = document.createElement('div');
  document.body.append(container);
  root = createRoot(container);
});
afterEach(async () => {
  try {
    await act(async () => root.unmount());
    container.remove();
  } finally {
    mock.restore();
  }
});

async function render(children: ReactNode) { await act(async () => root.render(children)); }
async function waitFor(predicate: () => boolean) {
  for (let attempt = 0; attempt < 80; attempt++) {
    if (predicate()) return;
    const { promise, resolve } = Promise.withResolvers<void>();
    setTimeout(resolve, 10);
    await act(async () => promise);
  }
  throw new Error('Timed out waiting for grant state');
}

test('PATCH reload wins over an older event-triggered grant read', async () => {
  await render(<GrantsPanel bot={bot} editable />);
  await waitFor(() => grantReads === 1 && !!container.querySelector('button[aria-label="Terminal: Full"]'));

  await act(async () => window.dispatchEvent(new CustomEvent('lemon:event', { detail: { event: 'machine.upserted' } })));
  await waitFor(() => grantReads === 2);

  const full = container.querySelector<HTMLButtonElement>('button[aria-label="Terminal: Full"]')!;
  await act(async () => full.click());
  await waitFor(() => grantReads === 3 && full.getAttribute('aria-pressed') === 'true');
  expect(container.textContent).not.toContain('currently Off');

  await act(async () => staleRead.resolve({ items: [stale], nextCursor: null }));
  await waitFor(() => calls.filter(endpoint => endpoint === 'GET /bots/:id/grants').length === 3);

  expect(full.getAttribute('aria-pressed')).toBe('true');
  expect(container.textContent).not.toContain('currently Off');
  expect(calls.filter(endpoint => endpoint === 'PATCH /bots/:id/grants/:grantId')).toHaveLength(1);
});

test('busy PATCH stays editable, stops the presence run and applies through grant events', async () => {
  current = initial;
  patched = { ...initial, revision: 2, pendingLevel: 'read_interact' };
  await render(<GrantsPanel bot={bot} editable />);
  await waitFor(() => !!container.querySelector('button[aria-label="Terminal: Full"]'));
  const full = container.querySelector<HTMLButtonElement>('button[aria-label="Terminal: Full"]')!;
  await act(async () => full.click());
  await waitFor(() => container.textContent!.includes('Turns on when the current task finishes'));
  expect(full.disabled).toBe(false);
  expect(full.getAttribute('aria-pressed')).toBe('true');
  const off = container.querySelector<HTMLButtonElement>('button[aria-label="Terminal: Off"]')!;
  expect(off.disabled).toBe(false);
  const stop = [...container.querySelectorAll('button')].find(button => button.textContent === 'Stop task')!;
  await act(async () => stop.click());
  expect(cancelled).toEqual(['run_from_presence']);
  current = effective;
  await act(async () => window.dispatchEvent(new CustomEvent('lemon:event', { detail: { event: 'grant.upserted' } })));
  await waitFor(() => !container.textContent!.includes('Turns on when the current task finishes'));
  expect(full.getAttribute('aria-pressed')).toBe('true');
  expect(container.textContent).not.toContain('Stop task');
});

test('pending narrowing and Stop task fail closed without fresh presence or online owner access', async () => {
  current = { ...effective, pendingLevel: 'off' };
  currentRunId = null;
  await render(<GrantsPanel bot={bot} editable />);
  await waitFor(() => container.textContent!.includes('Turns off when the current task finishes'));
  const stop = () => [...container.querySelectorAll('button')].find(button => button.textContent === 'Stop task')!;
  expect(stop().disabled).toBe(true);
  currentRunId = 'run_from_presence'; presenceStale = true;
  await act(async () => window.dispatchEvent(new CustomEvent('lemon:event', { detail: { event: 'bot.presence' } })));
  await waitFor(() => calls.filter(endpoint => endpoint === 'GET /bots/:id/presence').length === 2);
  expect(stop().disabled).toBe(true);
  app.online = false;
  await render(<GrantsPanel bot={bot} editable />);
  expect(stop().disabled).toBe(true);
  app.online = true;
  await render(<GrantsPanel bot={bot} editable={false} />);
  expect(stop().disabled).toBe(true);
  expect(cancelled).toEqual([]);
});

test('Files explains folder reads only when both the machine and effective policy allow them', async () => {
  current = { ...effective, id: 'grant_files', capabilityId: 'files' };
  for (const [feature, policy, shown] of [
    [undefined, 'allow', false], [false, 'allow', false], [true, 'ask', false], [true, 'allow', true],
  ] as const) {
    botFolder = feature; workspaceReads = policy;
    await render(<GrantsPanel key={`${feature}:${policy}`} bot={bot} editable />);
    await waitFor(() => !!container.querySelector('button[aria-label="Files: Full"]'));
    expect(container.textContent!.includes(`Reading files in ${bot.name}'s folder doesn't ask.`)).toBe(shown);
  }
});

test('an owner can clear a pending change using the still-interactive current-level control', async () => {
  current = { ...initial, revision: 2, pendingLevel: 'read_interact' };
  patched = { ...initial, revision: 3 };
  await render(<GrantsPanel bot={bot} editable />);
  await waitFor(() => container.textContent!.includes('Turns on when the current task finishes'));
  const off = container.querySelector<HTMLButtonElement>('button[aria-label="Terminal: Off"]')!;
  await act(async () => off.click());
  await waitFor(() => !container.textContent!.includes('Turns on when the current task finishes'));
  expect(off.getAttribute('aria-pressed')).toBe('true');
  expect(container.textContent).not.toContain('Stop task');
  expect(calls.filter(endpoint => endpoint === 'PATCH /bots/:id/grants/:grantId')).toHaveLength(1);
});
