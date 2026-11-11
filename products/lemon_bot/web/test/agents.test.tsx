import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act } from 'react';
import type { Root } from 'react-dom/client';
import { LemonBotClient, type AgentMessageReceipt } from '@lemon-bot/sdk';
import { app, bot, resetFixtures, useApp } from './fixtures/bots-machines';

const browser = new Window();
Object.assign(globalThis, { window: browser, document: browser.document, navigator: browser.navigator, sessionStorage: browser.sessionStorage, HTMLElement: browser.HTMLElement, HTMLInputElement: browser.HTMLInputElement, HTMLTextAreaElement: browser.HTMLTextAreaElement, Event: browser.Event, CustomEvent: browser.CustomEvent, IS_REACT_ACT_ENVIRONMENT: true });
// Controlled input events require React DOM to initialize after the DOM shim.
const { createRoot } = await import('react-dom/client');
mock.module('../src/app', () => ({ useApp }));
// Install the workspace context mock before loading the component's app dependency.
const { AgentControls } = await import('../src/features/bots/agents');
let root: Root;
let container: HTMLDivElement;
let requests: Request[];
let failRoster = false;
let sendMessage: (request: Request) => Promise<Response>;
let messageReceipt: AgentMessageReceipt;
beforeEach(() => {
  resetFixtures(); requests = []; failRoster = false;
  sendMessage = async () => { throw new Error('Unexpected agent-message POST'); };
  messageReceipt = { messageId: 'fixed-message', sourceId: 'bot://instance/source', targetId: 'bot://instance/target', status: 'accepted', runId: null, response: null };
  sessionStorage.clear();
  app.refresh = async () => {};
  app.client = new LemonBotClient({ baseUrl: 'https://bot.example', fetch: (async (url: RequestInfo | URL, init?: RequestInit) => {
    const request = new Request(url, init); requests.push(request);
    if (request.method === 'PATCH') return Response.json({ agent: { id: 'bot://instance/source', name: null, kind: 'bot', label: bot.name } });
    if (request.method === 'POST') return sendMessage(request);
    if (new URL(request.url).pathname.includes('/agent-messages/')) return Response.json(messageReceipt);
    if (request.url.endsWith('/agent-identity')) return Response.json({ agent: { id: 'bot://instance/source', name: 'research', kind: 'bot', label: bot.name } });
    if (failRoster) return Response.json({ error: { code: 'upstream_unavailable', message: 'Roster unavailable.', requestId: 'roster', retrySafe: true } }, { status: 503 });
    return Response.json({ agents: [{ id: 'bot://instance/<script>bad</script>', name: null, kind: 'bot', label: '<img src=x onerror=alert(1)>', status: 'offline' }] });
  }) as typeof fetch });
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
const button = (label: string) => {
  const found = [...container.querySelectorAll('button')].find(item => item.textContent === label);
  if (!found) throw new Error(`Button not found: ${label}`);
  return found;
};
const field = (label: string) => {
  const found = [...container.querySelectorAll('label')].find(item => item.querySelector('span')?.textContent === label)?.querySelector<HTMLInputElement | HTMLTextAreaElement>('input, textarea');
  if (!found) throw new Error(`Field not found: ${label}`);
  return found;
};
async function fill(label: string, value: string) {
  await act(async () => {
    const input = field(label);
    const prototype = input.tagName === 'TEXTAREA' ? browser.HTMLTextAreaElement.prototype : browser.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, 'value')!.set!.call(input, value);
    input.dispatchEvent(new browser.Event('input', { bubbles: true }));
  });
}
async function click(label: string) { await act(async () => button(label).click()); }
async function openMessages() {
  await act(async () => container.querySelector('summary')!.click());
  expect(container.querySelector('details')?.open).toBe(true);
}

test('handle is separate from display name; stable addresses and labels are inert text', async () => {
  await act(async () => root.render(<AgentControls bot={bot} />));
  expect(container.textContent).toContain('@research');
  expect(container.textContent).toContain('bot://instance/source');
  expect(container.textContent).toContain('<img src=x onerror=alert(1)>');
  expect(container.querySelector('script, img')).toBeNull();
  expect(button('Address this agent').disabled).toBe(true);
  await act(async () => button('Clear handle').click());
  const mutations = requests.filter(request => request.method !== 'GET');
  expect(mutations).toHaveLength(1);
  expect(new URL(mutations[0].url).pathname).toBe(`/v1/bots/${bot.id}/agent-identity`);
  expect(await mutations[0].json()).toMatchObject({ name: null });
  expect(bot.name).toBe('Research partner');
});

test('roster failure is not an empty roster, and offline handle edits are disabled', async () => {
  failRoster = true; app.online = false;
  await act(async () => root.render(<AgentControls bot={bot} />));
  expect(container.textContent).toContain('Roster unavailable.');
  expect(container.textContent).not.toContain('No matching agents.');
  expect(button('Clear handle').closest('fieldset')?.disabled).toBe(true);
  expect(requests.every(request => request.method === 'GET')).toBe(true);
});

test('a submitted message keeps its original conversation and receipt fence through a lost response and remount', async () => {
  const conversationId = 'owned-task';
  const key = `lemonbot.agent-message:${app.client.baseUrl}:${app.snapshot.workspace.id}:${app.snapshot.user.id}:${bot.id}:${conversationId}`;
  const delayed = Promise.withResolvers<Response>();
  let reservationAtDispatch: string | null = null;
  sendMessage = async () => {
    reservationAtDispatch = sessionStorage.getItem(key);
    return delayed.promise;
  };
  await act(async () => root.render(<AgentControls bot={bot} conversationId={conversationId} />));
  await openMessages();
  await fill('Target handle or stable ID', '@bob');
  await fill('Message to agent', 'Original question');
  expect(button('Send to agent').disabled).toBe(false);
  await click('Send to agent');

  const posts = requests.filter(request => request.method === 'POST');
  expect(posts).toHaveLength(1);
  expect(new URL(posts[0].url).pathname).toBe(`/v1/bots/${bot.id}/agent-messages`);
  const body = await posts[0].clone().json();
  const messageId = body.clientNonce;
  expect(typeof messageId).toBe('string');
  expect(messageId.length).toBeGreaterThan(0);
  expect(body.conversationId).toBe(conversationId);
  expect(body.conversationId).not.toBe(bot.mainConversationId);
  const intent = { messageId, target: '@bob', text: 'Original question' };
  expect(JSON.parse(reservationAtDispatch!)).toEqual(intent);
  expect(container.textContent).toContain(messageId);
  expect(container.textContent).toContain('Outcome unknown — do not resend.');
  expect(button('Send to agent').closest('fieldset')?.disabled).toBe(true);
  await click('Send to agent');
  expect(requests.filter(request => request.method === 'POST')).toHaveLength(1);

  // Reopen while the original acknowledgement is still in flight.
  await act(async () => root.render(null));
  await act(async () => root.render(<AgentControls bot={bot} conversationId={conversationId} />));
  await openMessages();
  expect(container.textContent).toContain(messageId);
  expect(container.textContent).toContain('Outcome unknown — do not resend.');
  expect(field('Target handle or stable ID').value).toBe('@bob');
  expect(field('Message to agent').value).toBe('Original question');
  expect(button('Send to agent').closest('fieldset')?.disabled).toBe(true);
  await click('Send to agent');

  // Losing the old request must not overwrite another conversation's composer.
  await act(async () => root.render(<AgentControls bot={bot} conversationId="another-owned-task" />));
  await openMessages();
  expect(field('Target handle or stable ID').value).toBe('');
  expect(field('Message to agent').value).toBe('');
  expect(container.textContent).not.toContain(messageId);
  await fill('Target handle or stable ID', '@carol');
  await fill('Message to agent', 'A separate unsent question');
  await act(async () => delayed.reject(new TypeError('Connection lost after dispatch')));
  expect(field('Target handle or stable ID').value).toBe('@carol');
  expect(field('Message to agent').value).toBe('A separate unsent question');
  expect(button('Send to agent').disabled).toBe(false);
  expect(container.textContent).not.toContain('Outcome unknown');
  expect(container.querySelector('[role="alert"]')).toBeNull();
  expect(JSON.parse(sessionStorage.getItem(key)!)).toEqual(intent);

  await act(async () => root.render(<AgentControls bot={bot} conversationId={conversationId} />));
  await openMessages();
  expect(container.textContent).toContain(messageId);
  expect(container.textContent).toContain('Outcome unknown — do not resend.');
  expect(requests.filter(request => new URL(request.url).pathname.includes('/agent-messages/'))).toHaveLength(0);
  messageReceipt = { ...messageReceipt, messageId };
  const beforeReconciliation = requests.length;
  await click('Check message status');
  expect(container.textContent).toContain('Accepted — waiting for an answer, not completed.');
  expect(button('Send to agent').closest('fieldset')?.disabled).toBe(true);
  messageReceipt = { ...messageReceipt, status: 'completed', response: 'Bob’s answer for the selected task.' };
  await click('Check message status');
  expect(container.querySelector('[role="status"]')?.textContent).toContain('Completed');
  expect(container.textContent).toContain('Bob’s answer for the selected task.');
  expect(requests.filter(request => new URL(request.url).pathname.includes('/agent-messages/')).map(request => [request.method, new URL(request.url).pathname])).toEqual([
    ['GET', `/v1/bots/${bot.id}/agent-messages/${messageId}`],
    ['GET', `/v1/bots/${bot.id}/agent-messages/${messageId}`],
  ]);
  expect(requests.slice(beforeReconciliation).every(request => request.method === 'GET')).toBe(true);
  expect(requests.filter(request => request.method === 'POST')).toHaveLength(1);
  expect(JSON.parse(sessionStorage.getItem(key)!)).toEqual(intent);
  await act(async () => root.render(<AgentControls bot={bot} conversationId="another-owned-task" />));
  expect(field('Message to agent').value).toBe('');
  expect(container.textContent).not.toContain(messageId);
  expect(container.textContent).not.toContain('Bob’s answer for the selected task.');
});
