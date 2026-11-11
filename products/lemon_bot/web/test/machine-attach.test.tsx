import { afterEach, beforeEach, expect, mock, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act } from 'react';
import type { Root } from 'react-dom/client';
import type { MachineInvite } from '@lemon-bot/sdk';
import { calls, listeners, machine, navigations, resetFixtures, responses, useApp } from './fixtures/bots-machines';

const browser = new Window();
Object.assign(globalThis, { window: browser, document: browser.document, navigator: browser.navigator, sessionStorage: browser.sessionStorage, HTMLElement: browser.HTMLElement, HTMLInputElement: browser.HTMLInputElement, Event: browser.Event, CustomEvent: browser.CustomEvent, IS_REACT_ACT_ENVIRONMENT: true });
// React DOM must initialize after the DOM shim to support controlled input events.
const { createRoot } = await import('react-dom/client');
mock.module('../src/app', () => ({ useApp }));
mock.module('@xterm/xterm', () => ({ Terminal: class {} }));
mock.module('@xterm/addon-fit', () => ({ FitAddon: class {} }));
// Load the screen only after installing its workspace and terminal module mocks.
const { MachinesScreen } = await import('../src/features/machines');
const invite: MachineInvite = { id: 'invite_test', revision: 1, createdAtMs: Date.now(), updatedAtMs: Date.now(), machineId: machine.id, inviteCode: 'one-use-code', joinCommand: 'exact server command', expiresAtMs: Date.now() + 900000, status: 'pending', enrollment: 'waiting_for_join', lastError: null };
let container: HTMLDivElement;
let root: Root;
beforeEach(() => {
  resetFixtures();
  responses.set('GET /machines/enrollment-preview', { reachability: 'routable' });
  responses.set('GET /machines/:id', { ...machine, nodeId: null, status: 'pending' });
  responses.set('GET /machines/:id/invites', { items: [invite], nextCursor: null });
  responses.set('POST /machines', { machine: { ...machine, nodeId: null, status: 'pending' }, invite });
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
});
afterEach(async () => { await act(async () => root.unmount()); container.remove(); });
async function render() { await act(async () => root.render(<MachinesScreen route={{ screen: 'machine.attach' }} />)); }
function issue() { return [...container.querySelectorAll('button')].find(button => button.textContent === 'Issue one-use join command')!; }
async function setName(name: string) {
  await act(async () => {
    const input = container.querySelector<HTMLInputElement>('input[required]')!;
    Object.getOwnPropertyDescriptor(browser.HTMLInputElement.prototype, 'value')!.set!.call(input, name);
    input.dispatchEvent(new browser.Event('input', { bubbles: true }));
  });
}

test.each([
  ['--Ünïcode Host!', 'ncodehost'],
  ['!!!', 'lemon-host'],
  [' Build_Box-01.local ', 'build_box-01.local'],
  ['A'.repeat(100), 'a'.repeat(64)],
])('name %s derives the compatible durable ID and default invitation', async (name, nodeName) => {
  await render();
  expect(container.querySelectorAll('[required]')).toHaveLength(1);
  expect(container.querySelector('details')?.open).toBe(false);
  await setName(name);
  expect(issue().disabled).toBe(false);
  await act(async () => issue().click());
  expect(calls.find(call => call.endpoint === 'POST /machines')?.options).toMatchObject({ body: { name: name.trim(), nodeName, labels: {}, expiresInMs: 900000 } });
});

test('loopback blocks remote invites until the controller computer is explicitly selected', async () => {
  responses.set('GET /machines/enrollment-preview', { reachability: 'loopback_only' });
  await render(); await setName('Studio');
  expect(issue().disabled).toBe(true);
  expect(container.querySelector('a')?.href).toContain('/user-guide/attaching-a-bot-machine');
  expect(calls.every(call => call.endpoint.startsWith('GET '))).toBe(true);
  await act(async () => container.querySelector<HTMLInputElement>('input[value="this"]')!.click());
  expect(issue().disabled).toBe(false);
  await act(async () => issue().click());
  expect(calls.filter(call => call.endpoint === 'POST /machines')).toHaveLength(1);
});

test('a failed preview or a controller changed to loopback cannot issue an invite', async () => {
  responses.set('GET /machines/enrollment-preview', new Error('Unavailable'));
  await render(); await setName('Studio');
  expect(issue().disabled).toBe(true);
  responses.set('GET /machines/enrollment-preview', { reachability: 'routable' });
  await act(async () => [...container.querySelectorAll('button')].find(button => button.textContent === 'Check controller reachability')!.click());
  expect(issue().disabled).toBe(false);
  responses.set('GET /machines/enrollment-preview', { reachability: 'loopback_only' });
  await act(async () => issue().click());
  expect(calls.some(call => call.endpoint === 'POST /machines')).toBe(false);
  expect(issue().disabled).toBe(true);
});

test('only verified online enrollment offers creation on the exact machine', async () => {
  await render(); await setName('Studio');
  await act(async () => issue().click());
  expect(container.querySelector('textarea')?.value).toBe(invite.joinCommand);
  expect([...container.querySelectorAll('button')].some(button => button.textContent?.includes('Create a Bot here'))).toBe(false);
  responses.set('GET /machines/:id', machine);
  responses.set('GET /machines/:id/invites', { items: [{ ...invite, status: 'joined', enrollment: 'online' }], nextCursor: null });
  await act(async () => { for (const listener of listeners) listener({ type: 'event', event: 'machine.upserted', payload: machine, seq: '1', timestampMs: Date.now() }); });
  const create = [...container.querySelectorAll('button')].find(button => button.textContent?.includes('Create a Bot here'))!;
  expect(create).toBeDefined();
  await act(async () => create.click());
  expect(navigations).toEqual([{ screen: 'bot.create', machineId: machine.id }]);
});
