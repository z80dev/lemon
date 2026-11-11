import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act, type ReactNode } from 'react';
import type { Root } from 'react-dom/client';
import { app, bot, calls, machine, resetFixtures, responses, template, useApp } from './fixtures/bots-machines';

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
const { ConversationScreen } = await import('../src/features/chat');

let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  resetFixtures();
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
  const snapshotWithMachines = app.snapshot;
  snapshotWithMachines.machines = [machine, machine2];

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

test('Empty conversation shows 3 clickable starter tasks and sends via existing send path', async () => {
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
      text: "What's this Mac's hostname and macOS version?",
      streaming: false,
      attachmentIds: [],
    }],
    runs: [],
    delivery: [],
  });

  await render(<ConversationScreen route={{ screen: 'conversation', id: 'conversation_empty' }} />);

  expect(container.querySelectorAll('.chat-starter-button')).toHaveLength(3);

  const starterBtn = [...container.querySelectorAll('.chat-starter-button')].find(b => b.textContent?.includes('hostname'));
  expect(starterBtn).toBeDefined();

  await act(async () => {
    starterBtn?.click();
  });

  const sendCall = calls.find(call => call.endpoint === 'POST /conversations/:id/messages');
  expect(sendCall).toBeDefined();
  const sendBody = extractBody(sendCall?.options);
  expect(sendBody.text).toBe("What's this Mac's hostname and macOS version?");
});
