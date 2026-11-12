import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act, type ReactNode } from 'react';
import type { Root } from 'react-dom/client';
import { LemonBotError, type Bot } from '@lemon-bot/sdk';
import { app, bot, calls, machine, navigations, resetFixtures, responses, template, useApp } from './fixtures/bots-machines';

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
// React DOM must initialize after the DOM shim to exercise real input event handling.
const { createRoot } = await import('react-dom/client');
mock.module('../src/app', () => ({ useApp }));

// Loaded after mock.module so the screens bind this fixture context, not the real app context.
const { CreateBot } = await import('../src/features/bots/editor');
const { TemplatesScreen } = await import('../src/features/bots/templates');
const { SettingsPanel } = await import('../src/features/bots/settings');
const { BotOverview } = await import('../src/features/bots/overview');
const { BotRecovery } = await import('../src/features/bots/lifecycle');
const { ConversationScreen } = await import('../src/features/chat');

let container: HTMLDivElement;
let root: Root;
const originalRefresh = app.refresh;

beforeEach(() => {
  resetFixtures();
  sessionStorage.clear();
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
    app.refresh = originalRefresh;
  }
});

async function render(children: ReactNode) {
  await act(async () => root.render(children));
}

function extractBody(options: unknown): Record<string, unknown> {
  if (options && typeof options === 'object' && 'body' in options && options.body && typeof options.body === 'object') {
    return options.body as Record<string, unknown>;
  }
  return {};
}

test('CreateBot preselects sole online machine and defaults Access to standard', async () => {
  await render(<CreateBot />);
  const select = container.querySelector('select[required]') as HTMLSelectElement;
  expect(select.value).toBe(machine.id);

  const radioStandard = container.querySelector('input[type="radio"][value="standard"]') as HTMLInputElement;
  const radioNone = container.querySelector('input[type="radio"][value="none"]') as HTMLInputElement;
  expect(radioStandard.checked).toBe(true);
  expect(radioNone.checked).toBe(false);

});

test('CreateBot consumes route.machineId and prefers it over sole-online auto-select', async () => {
  const machine2 = { ...machine, id: 'machine_studio_2', name: 'Studio Mini', status: 'online' as const };
  responses.set('GET /machines', { items: [machine, machine2], nextCursor: null });

  await render(<CreateBot route={{ screen: 'bot.create', machineId: 'machine_studio_2' }} />);
  const select = container.querySelector('select[required]') as HTMLSelectElement;
  expect(select.value).toBe('machine_studio_2');
});

test('CreateBot collapses avatar, voice, skills, language, instructions under Customize and submits access', async () => {
  responses.set('POST /bots', { ...bot, id: 'bot_new', name: 'Alpha Bot' });
  await render(<CreateBot />);

  const customize = container.querySelector('.customize-disclosure') as HTMLDetailsElement;
  expect(customize).toBeDefined();
  expect(customize.open).toBe(false);

  const nameInput = container.querySelector('input[required]') as HTMLInputElement;
  await act(async () => {
    Object.getOwnPropertyDescriptor(browser.HTMLInputElement.prototype, 'value')!.set!.call(nameInput, 'Alpha Bot');
    nameInput.dispatchEvent(new browser.Event('input', { bubbles: true }));
    nameInput.dispatchEvent(new browser.Event('change', { bubbles: true }));
  });


  const form = container.querySelector('form')!;
  await act(async () => {
    form.dispatchEvent(new browser.Event('submit', { bubbles: true, cancelable: true }));
  });

  const createCall = calls.find(call => call.endpoint === 'POST /bots');
  expect(createCall).toBeDefined();
  const body = extractBody(createCall?.options);
  expect(body.name).toBe('Alpha Bot');
  expect(body.machineId).toBe(machine.id);
  expect(body.access).toBe('standard');
});

test('Template import renders AccessChoice, honors suggestedAccess, and sends access', async () => {
  const templateWithAccess = {
    ...template,
    content: {
      ...template.content,
      suggestedAccess: 'none' as const,
    },
  };
  responses.set('GET /templates/:id', templateWithAccess);
  responses.set('POST /templates/:id/import', { ...bot, id: 'bot_imported' });

  await render(<TemplatesScreen id={template.id} />);

  const radioNone = container.querySelector('input[type="radio"][value="none"]') as HTMLInputElement;
  expect(radioNone.checked).toBe(true);

  // Check terms and reviewed checkboxes to enable button
  const checkboxes = container.querySelectorAll('input[type="checkbox"]') as NodeListOf<HTMLInputElement>;
  for (const checkbox of checkboxes) {
    await act(async () => {
      checkbox.click();
    });
  }

  const importBtn = [...container.querySelectorAll('button')].find(b => b.textContent === 'Import reviewed own copy');
  expect(importBtn?.disabled).toBe(false);

  await act(async () => {
    importBtn?.click();
  });

  const importCall = calls.find(call => call.endpoint === 'POST /templates/:id/import');
  expect(importCall).toBeDefined();
  const body = extractBody(importCall?.options);
  expect(body.access).toBe('none');
});

test('Bot duplicate sends access and retains consent gate only for move', async () => {
  responses.set('POST /bots/:id/duplicate', { ...bot, id: 'bot_copy' });
  await render(<SettingsPanel bot={bot} reload={async () => {}} />);


  const duplicateBtn = [...container.querySelectorAll('button')].find(b => b.textContent === 'Create separate copy to rescope');
  expect(duplicateBtn?.disabled).toBe(false);

  await act(async () => {
    duplicateBtn?.click();
  });

  const duplicateCall = calls.find(call => call.endpoint === 'POST /bots/:id/duplicate');
  expect(duplicateCall).toBeDefined();
  const body = extractBody(duplicateCall?.options);
  expect(body.access).toBe('standard');

  // Switch to Move mode
  const operationSelect = container.querySelector('select') as HTMLSelectElement;
  await act(async () => {
    operationSelect.value = 'move';
    operationSelect.dispatchEvent(new browser.Event('change', { bubbles: true }));
  });

  // Move retains trust gate checkbox
  expect(container.textContent).toContain('I trust this host and explicitly accept its shared access.');
});

for (const uncertain of [false, true]) {
test(`Empty starter task uses composer delivery and ${uncertain ? 'retains uncertain nonce without resending' : 'sends immediately'}`, async () => {
  const conversation = {
    id: 'conversation_empty',
    revision: 1,
    createdAtMs: 1,
    updatedAtMs: 1,
    kind: 'dm' as const,
    name: 'Research partner',
    botIds: [bot.id],
    ownerUserId: 'owner',
    parentConversationId: null,
    leadBotId: bot.id,
    channelBindingId: null,
    lastEntryId: null,
    unreadCount: 0,
    lastReadSeq: 0,
    activity: [],
  };

  responses.set('GET /conversations/:id', conversation);
  responses.set('GET /conversations/:id/entries', { items: [], nextCursor: null });
  responses.set('GET /runs', { items: [], nextCursor: null });
  responses.set('POST /conversations/:id/messages', {
    status: 'delivered',
    entries: [{
      id: 'entry_starter',
      revision: 1,
      createdAtMs: 2,
      updatedAtMs: 2,
      conversationId: 'conversation_empty',
      seq: 1,
      timestampMs: 2,
      actor: { kind: 'user', id: 'owner', displayName: 'Owner' },
      clientNonce: 'test-nonce',
      batchId: null,
      replyToEntryId: null,
      runId: null,
      targetedUserId: null,
      reactions: [],
      kind: 'message',
      role: 'user',
      text: 'Submitted starter task',
      streaming: false,
      attachmentIds: [],
    }],
    runs: [],
    delivery: [],
  });
  if (uncertain) responses.set('POST /conversations/:id/messages', new Error('Connection lost after submission'));

  await render(<ConversationScreen route={{ screen: 'conversation', id: 'conversation_empty' }} />);

  expect(container.querySelectorAll('.chat-starter-button')).toHaveLength(3);

  const starterBtn = container.querySelector<HTMLButtonElement>('.chat-starter-button')!;
  const selectedTask = starterBtn.textContent;
  expect(selectedTask?.length).toBeGreaterThan(0);

  await act(async () => {
    starterBtn?.click();
  });

  const sendCall = calls.find(call => call.endpoint === 'POST /conversations/:id/messages');
  expect(sendCall).toBeDefined();
  const sendBody = extractBody(sendCall?.options);
  expect(sendBody.text).toBe(selectedTask);
  if (uncertain) {
    await act(async () => { starterBtn?.click(); });
    expect(calls.filter(call => call.endpoint === 'POST /conversations/:id/messages')).toHaveLength(1);
    const saved = JSON.parse(sessionStorage.getItem('lemonbot.composer:workspace_test:owner:conversation_empty')!);
    expect(saved.unknownNonce).toBe(sendBody.clientNonce);
  }
});
}

function failedSetup(action = 'create'): Bot {
  return { ...bot, activity: 'offline', lifecycle: { action, status: 'failed', step: 'Allow native follow-ups', message: 'Allow this server’s callback address before finishing setup.', canFinishSetup: true, canReaddress: false, canDelete: true } };
}

function button(label: string): HTMLButtonElement {
  const found = [...container.querySelectorAll('button')].find(item => item.textContent === label);
  expect(found).toBeDefined();
  return found!;
}

function mockOverview(value: Bot) {
  app.snapshot.user.preferences = { ...app.snapshot.user.preferences, celebrationsEnabled: false };
  responses.set('GET /bots/:id/overview', { bot: value, machine, presence: { botId: value.id, status: value.activity, summary: 'Setup has not finished.', measuredAtMs: value.updatedAtMs, stale: false } });
  responses.set('GET /bots/:id/ideas', []);
  for (const endpoint of ['GET /bots/:id/activity', 'GET /bots/:id/upcoming', 'GET /bots/:id/milestones']) responses.set(endpoint, { items: [], nextCursor: null });
}

test('Failed creation is discoverable in the overview with plain setup steps and recovery actions', async () => {
  const failed = failedSetup();
  mockOverview(failed);
  await render(<BotOverview id={failed.id} />);
  expect(container.textContent).toContain('Bot setup needs attention');
  expect(container.textContent).toContain(failed.lifecycle!.message);
  expect(container.textContent).toContain('Step: Allow native follow-ups');
  expect(button('Finish setup').disabled).toBe(false);
  expect(button('Delete').disabled).toBe(false);
  expect(calls.every(call => call.endpoint.startsWith('GET '))).toBe(true);
});

test('Failed import is discoverable in settings without duplicating the recovery panel', async () => {
  const failed = failedSetup('import');
  mockOverview(failed);
  await render(<BotOverview id={failed.id} tab="settings" />);
  expect(container.querySelectorAll('[aria-label="Bot setup status"]')).toHaveLength(1);
  expect(container.textContent).toContain(failed.lifecycle!.message);
  expect(button('Finish setup').disabled).toBe(false);
  expect(button('Delete').disabled).toBe(false);
});

test('Finish setup resumes the canonical Bot and refreshes its overview without creating a Bot or conversation', async () => {
  const failed = failedSetup();
  mockOverview(failed);
  responses.set('POST /bots/:id/finish-setup', bot);
  let refreshes = 0;
  app.refresh = async () => { refreshes++; };
  await render(<BotOverview id={failed.id} />);
  // The authoritative reload returns the same Bot and owner conversation, now ready.
  mockOverview(bot);
  await act(async () => button('Finish setup').click());
  const resume = calls.filter(call => call.endpoint === 'POST /bots/:id/finish-setup');
  expect(resume).toHaveLength(1);
  expect(resume[0].options).toMatchObject({ params: { id: bot.id }, body: { revision: failed.revision } });
  expect(typeof extractBody(resume[0].options).clientNonce).toBe('string');
  expect(refreshes).toBe(1);
  expect(calls.filter(call => call.endpoint === 'GET /bots/:id/overview')).toHaveLength(2);
  expect(calls.filter(call => !call.endpoint.startsWith('GET ')).map(call => call.endpoint)).toEqual(['POST /bots/:id/finish-setup']);
  expect(container.textContent).not.toContain('Bot setup needs attention');
  expect(navigations).toHaveLength(0);
  expect(bot.mainConversationId).toBe(failed.mainConversationId);
});

test('A stale callback address offers Update address and sends the revision-bound recovery request', async () => {
  const stale: Bot = { ...bot, lifecycle: { action: 'readdress', status: 'failed', step: 'Update callback address', message: 'The address changed from http://127.0.0.1:4100 to https://studio.example. Update address to continue.', canFinishSetup: false, canReaddress: true, canDelete: true } };
  responses.set('POST /bots/:id/readdress', bot);
  let reloads = 0;
  await render(<BotRecovery bot={stale} reload={async () => { reloads++; }} />);
  expect(container.textContent).toContain(stale.lifecycle!.message);
  expect(container.textContent).not.toContain('Finish setup');
  await act(async () => button('Update address').click());
  expect(calls.filter(call => !call.endpoint.startsWith('GET '))).toHaveLength(1);
  expect(calls[0]).toMatchObject({ endpoint: 'POST /bots/:id/readdress', options: { params: { id: bot.id }, body: { revision: bot.revision } } });
  expect(typeof extractBody(calls[0].options).clientNonce).toBe('string');
  expect(reloads).toBe(1);
});

test('An unresolved setup receipt stays visibly blocked; Check status never resends the change', async () => {
  const unresolved: Bot = { ...failedSetup(), lifecycle: { ...failedSetup().lifecycle!, status: 'outcome_unknown', step: 'Sync Bot to your machine', message: 'The machine has not confirmed the saved setup receipt.' } };
  responses.set('POST /bots/:id/finish-setup', unresolved);
  let checks = 0;
  await render(<BotRecovery bot={unresolved} reload={async () => { checks++; }} />);
  expect(container.textContent).toContain('Blocked: the previous step’s receipt is not confirmed.');
  await act(async () => button('Finish setup').click());
  expect(button('Finish setup').disabled).toBe(true);
  expect(button('Delete').disabled).toBe(true);
  await act(async () => { button('Finish setup').click(); button('Delete').click(); button('Check status').click(); });
  expect(checks).toBe(2);
  expect(calls.map(call => call.endpoint)).toEqual(['POST /bots/:id/finish-setup']);
  // A reviewed status may offer another explicit receipt-aware recovery, never an automatic replay.
  expect(button('Finish setup').disabled).toBe(false);
  expect(container.textContent).toContain('Blocked: the previous step’s receipt is not confirmed.');
});

test('A lost setup response retains the mutation reference and fences further setup and deletion', async () => {
  const failure = new LemonBotError({ code: 'outcome_unknown', message: 'The profile sync receipt could not be read.', requestId: 'request_setup', retrySafe: false }, { clientNonce: 'setup_nonce', resourceIds: [bot.id] });
  responses.set('POST /bots/:id/finish-setup', failure);
  let checks = 0;
  await render(<BotRecovery bot={failedSetup()} reload={async () => { checks++; }} />);
  await act(async () => button('Finish setup').click());
  expect(container.textContent).toContain('Couldn’t confirm');
  expect(container.textContent).toContain('setup_nonce');
  expect(button('Finish setup').disabled).toBe(true);
  expect(button('Delete').disabled).toBe(true);
  await act(async () => button('Check status').click());
  expect(checks).toBe(1);
  expect(calls.map(call => call.endpoint)).toEqual(['POST /bots/:id/finish-setup']);
});

function deletionPreview() {
  return { confirmationToken: 'confirmed_bot_delete', confirmName: bot.name, revision: bot.revision, expiresAtMs: Date.now() + 60_000, effects: ['Delete only this Bot and its private conversation. Machine files and logins remain.'], affected: [{ resourceType: 'bot', id: bot.id, operation: 'delete', explanation: 'Delete this Bot only.' }] };
}

test('Recovery Delete requires the exact server preview and typed confirmation; cancel does not delete', async () => {
  responses.set('POST /bots/:id/preview', deletionPreview());
  responses.set('DELETE /bots/:id', { ok: true });
  let refreshes = 0;
  app.refresh = async () => { refreshes++; };
  await render(<BotRecovery bot={failedSetup('import')} reload={async () => {}} />);
  await act(async () => button('Delete').click());
  expect(calls[0]).toMatchObject({ endpoint: 'POST /bots/:id/preview', options: { params: { id: bot.id }, body: { action: 'delete' } } });
  expect(container.querySelector('[role="dialog"]')?.textContent).toContain('Machine files and logins remain.');
  expect(button('Confirm').disabled).toBe(true);
  await act(async () => button('Cancel').click());
  expect(calls.filter(call => call.endpoint === 'DELETE /bots/:id')).toHaveLength(0);
  await act(async () => button('Delete').click());
  await act(async () => {
    const input = container.querySelector<HTMLInputElement>('[role="dialog"] input')!;
    const setter = Object.getOwnPropertyDescriptor(browser.HTMLInputElement.prototype, 'value')!.set!;
    setter.call(input, bot.name);
    input.dispatchEvent(new browser.Event('input', { bubbles: true }));
  });
  expect(button('Confirm').disabled).toBe(false);
  await act(async () => button('Confirm').click());
  const deletion = calls.find(call => call.endpoint === 'DELETE /bots/:id');
  expect(deletion?.options).toMatchObject({ params: { id: bot.id }, body: { confirmationToken: 'confirmed_bot_delete', confirmName: bot.name, revision: bot.revision } });
  expect(typeof extractBody(deletion?.options).clientNonce).toBe('string');
  expect(refreshes).toBe(1);
  expect(navigations).toEqual([{ screen: 'bot.create' }]);
});

test('Unknown deletion offers status checks only until the server advertises safe recovery', async () => {
  const blocked: Bot = { ...bot, lifecycle: { action: 'delete', status: 'outcome_unknown', step: 'Confirm Bot removal', message: 'Checking whether this Bot’s profile was removed.', canFinishSetup: false, canReaddress: false, canDelete: false } };
  mockOverview(blocked);
  await render(<BotOverview id={bot.id} tab="settings" />);
  expect([...container.querySelectorAll('button')].some(item => item.textContent === 'Delete')).toBe(false);
  expect(button('Check status').disabled).toBe(false);
  const reconciled: Bot = { ...blocked, lifecycle: { ...blocked.lifecycle!, status: 'failed', canDelete: true, message: 'The remaining Bot resources can now be deleted safely.' } };
  mockOverview(reconciled);
  await act(async () => button('Check status').click());
  expect(button('Delete').disabled).toBe(false);
  expect(calls.every(call => call.endpoint.startsWith('GET '))).toBe(true);
});

for (const unavailable of ['offline', 'not-owned'] as const) {
  test(`Lifecycle recovery cannot mutate when ${unavailable}`, async () => {
    app.online = unavailable !== 'offline';
    const failed = unavailable === 'not-owned' ? { ...failedSetup(), ownerUserId: 'another_owner' } : failedSetup();
    await render(<BotRecovery bot={failed} reload={async () => {}} />);
    expect(button('Finish setup').disabled).toBe(true);
    expect(button('Delete').disabled).toBe(true);
    await act(async () => { button('Finish setup').click(); button('Delete').click(); });
    expect(calls).toHaveLength(0);
  });
}

test('A saved Bot with definitely rejected setup opens its canonical overview and cannot retry creation', async () => {
  responses.set('POST /bots', new LemonBotError({ code: 'policy_denied', message: 'Callback origin must be allowed.', requestId: 'request_create', retrySafe: true, details: { resourceIds: [bot.id] } }));
  await render(<CreateBot />);
  await act(async () => container.querySelector('form')!.dispatchEvent(new browser.Event('submit', { bubbles: true, cancelable: true })));
  expect(container.textContent).toContain('Bot saved — finish its setup');
  expect(button('Create Bot').disabled).toBe(true);
  await act(async () => {
    container.querySelector('form')!.dispatchEvent(new browser.Event('submit', { bubbles: true, cancelable: true }));
    button('Open Bot setup').click();
  });
  expect(calls.filter(call => call.endpoint === 'POST /bots')).toHaveLength(1);
  expect(navigations).toEqual([{ screen: 'bot.overview', id: bot.id }]);
});

test('A saved template import with rejected setup cannot create a second copy', async () => {
  responses.set('POST /templates/:id/import', new LemonBotError({ code: 'policy_denied', message: 'Callback origin must be allowed.', requestId: 'request_import', retrySafe: true, details: { resourceIds: [bot.id] } }));
  await render(<TemplatesScreen id={template.id} />);
  await act(async () => {
    const section = [...container.querySelectorAll('section')].find(item => item.querySelector('h2')?.textContent === 'Create your own separate copy')!;
    section.querySelectorAll<HTMLInputElement>('input[type="checkbox"]').forEach(input => input.click());
  });
  expect(button('Import reviewed own copy').disabled).toBe(false);
  await act(async () => button('Import reviewed own copy').click());
  expect(button('Import reviewed own copy').disabled).toBe(true);
  expect(container.textContent).toContain('Bot saved — finish its setup');
  await act(async () => { button('Import reviewed own copy').click(); button('Open Bot setup').click(); });
  expect(calls.filter(call => call.endpoint === 'POST /templates/:id/import')).toHaveLength(1);
  expect(navigations).toEqual([{ screen: 'bot.overview', id: bot.id }]);
});
