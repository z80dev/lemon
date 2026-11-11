import { afterEach, beforeEach, expect, mock, spyOn, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act } from 'react';
import type { Root } from 'react-dom/client';
import { LemonBotClient, type Approval, type Bot, type Conversation, type Machine, type RealtimeEvent, type RealtimeOptions, type RealtimeServerFrame, type Run, type Snapshot, type TranscriptEntry } from '@lemon-bot/sdk';

const browser = new Window({ url: 'https://bot.test/#screen=conversation&id=conversation_test&botId=bot_test' });
const media = { matches: false, media: '', onchange: null, addListener() {}, removeListener() {}, addEventListener() {}, removeEventListener() {}, dispatchEvent: () => true };
Object.assign(globalThis, {
  window: browser,
  document: browser.document,
  navigator: browser.navigator,
  location: browser.location,
  history: browser.history,
  sessionStorage: browser.sessionStorage,
  localStorage: browser.localStorage,
  HTMLElement: browser.HTMLElement,
  Event: browser.Event,
  CustomEvent: browser.CustomEvent,
  matchMedia: () => media,
  requestAnimationFrame: browser.requestAnimationFrame.bind(browser),
  cancelAnimationFrame: browser.cancelAnimationFrame.bind(browser),
  ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
  IntersectionObserver: class { observe() {} unobserve() {} disconnect() {} },
  IS_REACT_ACT_ENVIRONMENT: true,
});
// React DOM and App inspect DOM globals during module initialization, so this test installs happy-dom first.
const { createRoot } = await import('react-dom/client');
const { App } = await import('../src/app');

const resource = { revision: 1, createdAtMs: 1, updatedAtMs: 1 };
const machine: Machine = { ...resource, id: 'machine_test', nodeId: 'node_test', nodeName: 'studio', name: 'Studio', ownerUserId: 'user_test', accessUserIds: [], status: 'online', lastSeenAtMs: 1, labels: { os: 'macOS' }, botIds: ['bot_test'] };
const bot: Bot = { ...resource, id: 'bot_test', ownerUserId: 'user_test', machineId: machine.id, profileId: 'profile_test', name: 'Research Bot', title: 'Research', job: 'Research carefully.', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'conversation_test', sidebar: { sectionId: null, rank: 0, hidden: false, pinned: false, unread: false, notificationsEnabled: true }, activity: 'working', activeRunIds: ['run_test'] };
const conversation: Conversation = { ...resource, id: 'conversation_test', kind: 'dm', name: bot.name, botIds: [bot.id], ownerUserId: 'user_test', parentConversationId: null, leadBotId: bot.id, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] };
const running: Run = { ...resource, id: 'run_test', conversationId: conversation.id, botId: bot.id, initiatorUserId: 'user_test', clientNonce: 'nonce_test', status: 'running', error: null, startedAtMs: 1, completedAtMs: null, routineRunId: null };
const finished: Run = { ...running, revision: 2, updatedAtMs: 2, status: 'succeeded', completedAtMs: 2 };
const streaming: TranscriptEntry = { ...resource, id: 'entry_test', conversationId: conversation.id, seq: 1, timestampMs: 1, actor: { kind: 'bot', id: bot.id, displayName: bot.name }, clientNonce: null, batchId: null, replyToEntryId: null, runId: running.id, targetedUserId: null, reactions: [], kind: 'message', role: 'assistant', text: 'Done', streaming: true, attachmentIds: [] };
const finalEntry: TranscriptEntry = { ...streaming, revision: 2, updatedAtMs: 2, streaming: false };
let transcriptEntries: TranscriptEntry[] = [streaming];
function snapshot(): Snapshot {
  return {
    cursor: '1',
    user: { ...resource, id: 'user_test', email: 'owner@example.test', displayName: 'Owner', avatarAttachmentId: null, preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false }, notifications: { enabled: true, sound: false, previews: false, completed: true, needsInput: true } },
    workspace: { ...resource, id: 'workspace_test', name: 'Workspace', ownerUserId: 'user_test', enabled: true, timezone: 'UTC' },
    member: { ...resource, id: 'member_test', userId: 'user_test', displayName: 'Owner', email: 'owner@example.test', role: 'owner', enabled: true },
    capabilities: { controlConnected: true, methods: [], stt: false, tts: false, imageGeneration: false, apns: false, webPush: false, vapidPublicKey: null, attachmentMaxBytes: 1024, videoMaxBytes: 1024, maxAttachments: 6, minClientVersions: { web: '1.0.0', macos: '1.0.0', ios: '1.0.0' } },
    bots: [bot], machines: [machine], conversations: [conversation], sections: [], notifications: [], activeRuns: [running],
    hasMore: { bots: false, machines: false, conversations: false, notifications: false },
  };
}

let container: HTMLDivElement;
let root: Root;
let realtimeOptions: RealtimeOptions | undefined;
const subscribers = new Set<(frame: RealtimeServerFrame) => void | Promise<void>>();
const calls: string[] = [];

beforeEach(() => {
  calls.length = 0;
  subscribers.clear();
  realtimeOptions = undefined;
  conversation.kind = 'dm'; transcriptEntries = [streaming];
  sessionStorage.clear();
  localStorage.clear();
  location.hash = 'screen=conversation&id=conversation_test&botId=bot_test';
  sessionStorage.setItem('lemonbot.session', JSON.stringify({ baseUrl: 'https://bot.test/v1', token: 'token', workspaceId: 'workspace_test' }));
  container = document.createElement('div');
  document.body.append(container);
  root = createRoot(container);

  spyOn(LemonBotClient.prototype, 'call').mockImplementation((async endpoint => {
    calls.push(endpoint);
    switch (endpoint) {
      case 'GET /sync': return snapshot();
      case 'POST /devices': return { ...resource, id: 'device_test', userId: 'user_test', installationId: 'install_test', platform: 'web', name: 'Browser', appVersion: '1.0.0', pushEnabled: false, lastSeenAtMs: 1 };
      case 'GET /conversations/:id': return conversation;
      case 'GET /conversations/:id/entries': return { items: transcriptEntries, nextCursor: null };
      case 'GET /runs': return { items: [running], nextCursor: null };
      case 'GET /runs/:id': return finished;
      case 'GET /entries/:id': return finalEntry;
      case 'GET /machines/:id/host': return { hostname: 'studio', os: 'macOS', osVersion: '26', arch: 'arm64', cpuCount: 8, memTotalBytes: 1, memFreeBytes: 1, diskTotalBytes: 1, diskFreeBytes: 1, uptimeSec: 1, lemonVersion: '1', defaultCwd: '/tmp', user: 'owner', measuredAtMs: 1 };
      case 'GET /conversations/:id/composer': return { conversationId: conversation.id, text: '', attachmentIds: [], replyToEntryId: null, updatedAtMs: 1, revision: 1 };
      case 'GET /conversations/:id/approval-allowances': return { items: [], nextCursor: null };
      case 'GET /skills': return { items: [], nextCursor: null };
      case 'GET /capabilities': return snapshot().capabilities;
      default: throw new Error(`Unexpected test endpoint: ${endpoint}`);
    }
  }) as never);
  spyOn(LemonBotClient.prototype, 'realtime').mockImplementation(options => {
    realtimeOptions = options;
    return {
      state: 'live', nextRetryAtMs: null,
      start: () => options.onState?.('live'),
      close: () => undefined,
      send: () => undefined,
      subscribe: (listener: (frame: RealtimeServerFrame) => void | Promise<void>) => { subscribers.add(listener); return () => subscribers.delete(listener); },
    } as never;
  });
});

afterEach(async () => {
  try {
    await act(async () => root.unmount());
    container.remove();
  } finally {
    mock.restore();
  }
});

async function waitFor(predicate: () => boolean) {
  for (let attempt = 0; attempt < 80; attempt++) {
    if (predicate()) return;
    await act(async () => { const { promise, resolve } = Promise.withResolvers<void>(); setTimeout(resolve, 0); await promise; });
  }
  throw new Error('Timed out waiting for rendered status');
}

test('idle presence reconciles a withheld terminal run and its streaming entry without blocking realtime', async () => {
  await act(async () => root.render(<App />));
  await waitFor(() => !!container.querySelector('.chat-caret') && !!container.querySelector('.roster .live-step'));
  expect(container.querySelector('.roster .live-step')?.textContent).toContain('Thinking');
  expect(container.querySelector('.chat-working-step')?.textContent).toBe('Writing a reply');

  const presence: RealtimeEvent = { type: 'event', seq: '2', event: 'bot.presence', timestampMs: 2, payload: { botId: bot.id, status: 'idle', machineId: machine.id, machineLabel: machine.name, machineStatus: 'online', currentRunId: null, taskConversationId: null, summary: 'Idle', evidenceEntryId: null, measuredAtMs: 2, stale: false } };
  expect(realtimeOptions).toBeDefined();
  await act(async () => {
    await realtimeOptions!.onEvent(presence);
    for (const subscriber of subscribers) await subscriber(presence);
  });
  await waitFor(() => !container.querySelector('.chat-caret') && !container.querySelector('.roster .live-step'));

  expect(calls.filter(endpoint => endpoint === 'GET /runs/:id')).toHaveLength(1);
  expect(calls.filter(endpoint => endpoint === 'GET /entries/:id')).toHaveLength(1);
  expect(container.querySelector('.chat-working')).toBeNull();
});

test('shared rooms mask access-request content and never fetch its private approval', async () => {
  const approval: Approval = {
    ...resource, id: 'access_private', entryId: 'entry_access', conversationId: conversation.id, botId: bot.id, runId: running.id,
    source: 'access_request', category: 'permissions', title: 'Private access title', description: 'Private machine access description', target: 'Terminal',
    inputs: { capability: 'terminal', capabilityIds: ['terminal', 'files'], level: 'read_interact', machineLabel: 'Studio', reason: 'Private reason' },
    policyMode: 'ask_first', review: 'ask', ruleId: null,
    scope: { kind: 'once', label: 'This Bot', machineId: machine.id, machineLabel: 'Studio', botId: bot.id, runId: running.id, origin: 'owner_chat', connectorId: null, consequences: [], expiresAtMs: Date.now() + 60_000 },
    gate: { id: 'gate_access', targetUserId: 'user_test', state: 'pending', expiresAtMs: Date.now() + 60_000, resolvedAtMs: null, resolvedByUserId: null, revision: 1 },
  };
  conversation.kind = 'group';
  transcriptEntries = [{ ...streaming, id: approval.entryId, kind: 'card', card: { type: 'access_request', approval } }];
  await act(async () => root.render(<App />));
  await waitFor(() => container.textContent!.includes('Sensitive requests must be reviewed in your authorized private task or DM'));
  expect(container.textContent).not.toContain(approval.title);
  expect(container.textContent).not.toContain(approval.description);
  expect(container.textContent).not.toContain('Private reason');
  expect(calls).not.toContain('GET /approvals/:id');
});
