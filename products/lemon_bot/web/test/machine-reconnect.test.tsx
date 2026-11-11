import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act } from 'react';
import type { Root } from 'react-dom/client';
import type { Conversation, Machine, MachineInvite } from '@lemon-bot/sdk';
import { app, bot, calls, host, machine, navigations, resetFixtures, responses, useApp } from './fixtures/bots-machines';

const browser = new Window();
Object.assign(globalThis, {
  window: browser,
  document: browser.document,
  navigator: browser.navigator,
  sessionStorage: browser.sessionStorage,
  HTMLElement: browser.HTMLElement,
  HTMLInputElement: browser.HTMLInputElement,
  CustomEvent: browser.CustomEvent,
  ResizeObserver: browser.ResizeObserver,
  IS_REACT_ACT_ENVIRONMENT: true,
});
// Exception: React DOM must initialize after global DOM shims.
const { createRoot } = await import('react-dom/client');
mock.module('../src/app', () => ({ useApp }));
mock.module('@xterm/xterm', () => ({ Terminal: class {} }));
mock.module('@xterm/addon-fit', () => ({ FitAddon: class { fit() {} } }));

// Exception: Feature modules must import dynamically after Bun mock.module mocks are registered.
const { machineNeedsReconnect, MachinesScreen } = await import('../src/features/machines');
const { BotPanel } = await import('../src/features/chat/panel');
let container: HTMLDivElement;
let root: Root;

const invite: MachineInvite = {
  id: 'invite_rec_test',
  revision: 1,
  createdAtMs: Date.now(),
  updatedAtMs: Date.now(),
  machineId: machine.id,
  inviteCode: 'reconnect-code-123',
  joinCommand: 'lemon node join --invite reconnect-code-123',
  expiresAtMs: Date.now() + 900000,
  status: 'pending',
  enrollment: 'waiting_for_join',
  lastError: null,
};

beforeEach(() => {
  resetFixtures();
  responses.set('GET /machines/enrollment-preview', { reachability: 'routable' });
  responses.set('GET /machines/:id/invites', { items: [invite], nextCursor: null });
  responses.set('POST /machines/:id/reconnect', invite);
  container = document.createElement('div');
  document.body.append(container);
  root = createRoot(container);
});

afterEach(async () => {
  await act(async () => root.unmount());
  container.remove();
});

test('machineNeedsReconnect helper classifies expired and revoked offline machines', () => {
  expect(machineNeedsReconnect({ status: 'offline', credential: 'expired' })).toBe(true);
  expect(machineNeedsReconnect({ status: 'offline', credential: 'revoked' })).toBe(true);
  expect(machineNeedsReconnect({ status: 'offline', credential: 'active' })).toBe(false);
  expect(machineNeedsReconnect({ status: 'offline', credential: 'unknown' })).toBe(false);
  expect(machineNeedsReconnect({ status: 'offline' })).toBe(false);
  expect(machineNeedsReconnect({ status: 'online', credential: 'expired' })).toBe(false);
  expect(machineNeedsReconnect({ status: 'online', credential: 'revoked' })).toBe(false);
  expect(machineNeedsReconnect({ status: 'online', credential: 'active' })).toBe(false);
  expect(machineNeedsReconnect({ status: 'pending', credential: 'expired' })).toBe(false);
  expect(machineNeedsReconnect({ status: 'revoked', credential: 'revoked' })).toBe(false);
  expect(machineNeedsReconnect(null)).toBe(false);
  expect(machineNeedsReconnect(undefined)).toBe(false);
});

test('machines list shows "needs reconnecting" badge and warning copy for expired machine', async () => {
  const expiredMachine: Machine = {
    ...machine,
    id: 'm_expired',
    name: 'Mac Mini',
    status: 'offline',
    credential: 'expired',
  };
  responses.set('GET /machines', { items: [expiredMachine], nextCursor: null });

  await act(async () => root.render(<MachinesScreen route={{ screen: 'machines' }} />));

  const badge = container.querySelector('.badge');
  expect(badge?.textContent).toBe('needs reconnecting');
  expect(container.textContent).toContain('Mac Mini needs to be reconnected — its sign-in expired after 7 days offline');
});

test('machines list shows "needs reconnecting" badge and warning copy for revoked machine', async () => {
  const revokedMachine: Machine = {
    ...machine,
    id: 'm_revoked',
    name: 'Linux Worker',
    status: 'offline',
    credential: 'revoked',
  };
  responses.set('GET /machines', { items: [revokedMachine], nextCursor: null });

  await act(async () => root.render(<MachinesScreen route={{ screen: 'machines' }} />));

  const badge = container.querySelector('.badge');
  expect(badge?.textContent).toBe('needs reconnecting');
  expect(container.textContent).toContain('Linux Worker needs to be reconnected — its access was revoked');
});

test('machines list keeps plain "offline" badge for offline machine with active credential', async () => {
  const activeOfflineMachine: Machine = {
    ...machine,
    id: 'm_active_offline',
    name: 'Active Offline Box',
    status: 'offline',
    credential: 'active',
  };
  responses.set('GET /machines', { items: [activeOfflineMachine], nextCursor: null });

  await act(async () => root.render(<MachinesScreen route={{ screen: 'machines' }} />));

  const badge = container.querySelector('.badge');
  expect(badge?.textContent).toBe('offline');
  expect(container.textContent).not.toContain('needs to be reconnected');
});

test('machine detail shows "Machine · Needs reconnecting" eyebrow, warning panel, and Reconnect button issues POST', async () => {
  const expiredMachine: Machine = {
    ...machine,
    id: 'm_detail_expired',
    name: 'Build Node',
    status: 'offline',
    credential: 'expired',
  };
  responses.set('GET /machines/:id', expiredMachine);
  responses.set('GET /machines/:id/host', { ...host, hostname: 'build-node' });
  responses.set('GET /machines/:id/capabilities', { machineId: expiredMachine.id, os: host.os, measuredAtMs: host.measuredAtMs, stale: true, items: [] });
  responses.set('GET /bots', { items: [], nextCursor: null });

  await act(async () => root.render(<MachinesScreen route={{ screen: 'machine.detail', id: expiredMachine.id }} />));

  const eyebrow = container.querySelector('.eyebrow');
  expect(eyebrow?.textContent).toBe('Machine · Needs reconnecting');

  const warning = container.querySelector('.machine-warning[role="alert"]');
  expect(warning?.textContent).toContain('Build Node needs to be reconnected — its sign-in expired after 7 days offline');

  const reconnectBtn = [...container.querySelectorAll('button')].find(btn => btn.textContent === 'Reconnect');
  expect(reconnectBtn).toBeDefined();

  await act(async () => reconnectBtn!.click());

  const postCall = calls.find(call => call.endpoint === 'POST /machines/:id/reconnect');
  expect(postCall).toBeDefined();
  expect(postCall?.options).toMatchObject({ params: { id: expiredMachine.id } });
  expect(navigations).toContainEqual({ screen: 'machine.attach', id: expiredMachine.id });
});

test('machine detail displays revoked warning copy when credential is revoked', async () => {
  const revokedMachine: Machine = {
    ...machine,
    id: 'm_detail_revoked',
    name: 'Revoked Machine',
    status: 'offline',
    credential: 'revoked',
  };
  responses.set('GET /machines/:id', revokedMachine);
  responses.set('GET /machines/:id/host', host);
  responses.set('GET /machines/:id/capabilities', { machineId: revokedMachine.id, os: host.os, measuredAtMs: host.measuredAtMs, stale: true, items: [] });
  responses.set('GET /bots', { items: [], nextCursor: null });

  await act(async () => root.render(<MachinesScreen route={{ screen: 'machine.detail', id: revokedMachine.id }} />));

  const eyebrow = container.querySelector('.eyebrow');
  expect(eyebrow?.textContent).toBe('Machine · Needs reconnecting');

  const warning = container.querySelector('.machine-warning[role="alert"]');
  expect(warning?.textContent).toContain('Revoked Machine needs to be reconnected — its access was revoked');
});

test('machine detail displays plain "Machine · Offline" and no warning panel when credential is active', async () => {
  const activeOfflineMachine: Machine = {
    ...machine,
    id: 'm_detail_active',
    name: 'Active Offline Box',
    status: 'offline',
    credential: 'active',
  };
  responses.set('GET /machines/:id', activeOfflineMachine);
  responses.set('GET /machines/:id/host', host);
  responses.set('GET /machines/:id/capabilities', { machineId: activeOfflineMachine.id, os: host.os, measuredAtMs: host.measuredAtMs, stale: true, items: [] });
  responses.set('GET /bots', { items: [], nextCursor: null });

  await act(async () => root.render(<MachinesScreen route={{ screen: 'machine.detail', id: activeOfflineMachine.id }} />));

  const eyebrow = container.querySelector('.eyebrow');
  expect(eyebrow?.textContent).toBe('Machine · Offline');
  expect(container.querySelector('.machine-warning[role="alert"]') === null).toBe(true);
  expect(container.textContent).not.toContain('needs to be reconnected');

  const reconnectSameBtn = [...container.querySelectorAll('button')].find(btn => btn.textContent === 'Reconnect same machine');
  expect(reconnectSameBtn).toBeDefined();
});

test('attach screen shows warning panel and Reconnect button issuing POST for reconnecting machine', async () => {
  const expiredMachine: Machine = {
    ...machine,
    id: 'm_attach_expired',
    name: 'Dev Station',
    status: 'offline',
    credential: 'expired',
  };
  responses.set('GET /machines/:id', expiredMachine);
  responses.set('GET /machines/:id/invites', { items: [invite], nextCursor: null });

  await act(async () => root.render(<MachinesScreen route={{ screen: 'machine.attach', id: expiredMachine.id }} />));

  const warning = container.querySelector('.machine-warning[role="alert"]');
  expect(warning?.textContent).toContain('Dev Station needs to be reconnected — its sign-in expired after 7 days offline');

  const reconnectBtn = [...container.querySelectorAll('button')].find(btn => btn.textContent === 'Reconnect');
  expect(reconnectBtn).toBeDefined();

  await act(async () => reconnectBtn!.click());

  const postCall = calls.find(call => call.endpoint === 'POST /machines/:id/reconnect');
  expect(postCall).toBeDefined();
  expect(postCall?.options).toMatchObject({ params: { id: expiredMachine.id } });
});

test('chat panel offline line and bot header reflect "Needs reconnecting" vs plain offline', async () => {
  const expiredMachine: Machine = {
    ...machine,
    id: 'm_chat_expired',
    name: 'Remote Mac',
    status: 'offline',
    credential: 'expired',
  };
  const offlineBot = { ...bot, machineId: expiredMachine.id, activity: 'offline' as const };
  const conversation: Conversation = {
    id: 'conv_offline',
    revision: 1,
    createdAtMs: Date.now(),
    updatedAtMs: Date.now(),
    workspaceId: 'workspace_test',
    ownerUserId: 'owner',
    kind: 'dm',
    name: 'Research partner',
    botIds: [offlineBot.id],
    leadBotId: offlineBot.id,
    parentConversationId: null,
    summary: '',
    unread: false,
  };

  app.snapshot.machines = [expiredMachine];
  app.snapshot.bots = [offlineBot];
  app.snapshot.conversations = [conversation];
  app.snapshot.routines = [];
  responses.set('GET /runs', { items: [], nextCursor: null });
  responses.set('GET /upcoming', { items: [], nextCursor: null });
  responses.set('GET /activity', { items: [], nextCursor: null });

  await act(async () => root.render(
    <BotPanel
      id="test_panel"
      conversation={conversation}
      changed={() => {}}
      runs={[]}
      entries={[]}
      tab="activity"
      setTab={() => {}}
      stop={() => {}}
      stopDisabled={false}
    />
  ));

  const idleText = container.querySelector('.now-idle');
  expect(idleText?.textContent).toBe('Offline — its machine needs reconnecting');

  const statusChips = container.querySelector('.status-chips');
  expect(statusChips?.textContent).toContain('Needs reconnecting');

  // Now test with active offline machine (outage, not reconnect)
  const activeMachine: Machine = {
    ...machine,
    id: 'm_chat_active',
    name: 'Remote Mac',
    status: 'offline',
    credential: 'active',
  };
  const activeOfflineBot = { ...bot, machineId: activeMachine.id, activity: 'offline' as const };
  app.snapshot.machines = [activeMachine];
  app.snapshot.bots = [activeOfflineBot];

  await act(async () => root.render(
    <BotPanel
      id="test_panel"
      conversation={{ ...conversation, botIds: [activeOfflineBot.id], leadBotId: activeOfflineBot.id }}
      changed={() => {}}
      runs={[]}
      entries={[]}
      tab="activity"
      setTab={() => {}}
      stop={() => {}}
      stopDisabled={false}
    />
  ));

  const idleTextActive = container.querySelector('.now-idle');
  expect(idleTextActive?.textContent).toBe('Offline — its machine isn’t reachable');

  const statusChipsActive = container.querySelector('.status-chips');
  expect(statusChipsActive?.textContent).toContain('Offline');
  expect(statusChipsActive?.textContent).not.toContain('Needs reconnecting');
});
