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
const initial: BotGrant = { ...resource, id: 'grant_terminal', botId: bot.id, machineId: machine.id, capabilityId: 'terminal', requestedLevel: 'off', effectiveLevel: 'off', reasons: ['destination_shell_measured'] };
const stale: BotGrant = { ...initial, revision: 2, requestedLevel: 'read_interact', effectiveLevel: 'off', reasons: ['Tool-policy cutover has not been acknowledged.'] };
const effective: BotGrant = { ...stale, revision: 3, effectiveLevel: 'read_interact', reasons: ['destination_shell_measured'] };
const capabilities: MachineCapabilities = { machineId: machine.id, os: 'macOS', measuredAtMs: 1, stale: false, items: [{ id: 'terminal', name: 'Terminal', category: 'shell', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['bash'], reason: 'destination_shell_measured', measuredAtMs: 1, stale: false }] };
const staleRead = Promise.withResolvers<Page<BotGrant>>();
let grantReads = 0;
const calls: string[] = [];
const app = {
  online: true,
  client: { call: async (endpoint: string) => {
    calls.push(endpoint);
    if (endpoint === 'GET /bots/:id/grants') {
      grantReads++;
      if (grantReads === 1) return { items: [initial], nextCursor: null };
      if (grantReads === 2) return staleRead.promise;
      return { items: [effective], nextCursor: null };
    }
    if (endpoint === 'PATCH /bots/:id/grants/:grantId') return effective;
    if (endpoint === 'GET /machines/:id/capabilities') return capabilities;
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
