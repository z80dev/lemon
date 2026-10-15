import { afterEach, beforeEach, expect, mock, spyOn, test } from 'bun:test';
import { Window } from 'happy-dom';
import { act, type ReactNode } from 'react';
import { createRoot, type Root } from 'react-dom/client';
import { app, binding, bot, calls, host, listeners, machine, memory, navigations, operation, resetFixtures, responses, template, terminal, useApp, xProvider } from './fixtures/bots-machines';

const browser = new Window();
Object.assign(globalThis, { window: browser, document: browser.document, navigator: browser.navigator, HTMLElement: browser.HTMLElement, CustomEvent: browser.CustomEvent, ResizeObserver: browser.ResizeObserver, IS_REACT_ACT_ENVIRONMENT: true });
mock.module('../src/app', () => ({ useApp }));
// Xterm's canvas rendering is exercised in the browser review, not the DOM shim.
mock.module('@xterm/xterm', () => ({ Terminal: class {
  options = {}; cols = 100; rows = 30;
  loadAddon() {} open() {} dispose() {} reset() {} write() {} writeln() {}
  onData() { return { dispose() {} }; }
} }));
mock.module('@xterm/addon-fit', () => ({ FitAddon: class { fit() {} } }));
// Load after mock.module so the screens use this fixture context, never a live workspace.
const { MachinesScreen } = await import('../src/features/machines');
const { MachineTerminal } = await import('../src/features/machines/terminal');
const { HostOperations } = await import('../src/features/machines/operations');
const { MemoryPanel } = await import('../src/features/bots/memory');
const { TemplatesScreen } = await import('../src/features/bots/templates');
const { ChannelsScreen } = await import('../src/features/work/channels');
const { XScreen } = await import('../src/features/work/x');
const { formatTime } = await import('../src/ui');

let container: HTMLDivElement;
let root: Root;
const timers = new Map<number, { callback: () => void; delay: number }>();
let nextTimer = 0;
beforeEach(() => {
  resetFixtures(); timers.clear();
  container = document.createElement('div'); document.body.append(container); root = createRoot(container);
  spyOn(window, 'setInterval').mockImplementation((handler, delay) => {
    if (typeof handler !== 'function') throw new Error('Expected interval callback');
    const id = ++nextTimer; timers.set(id, { callback: () => handler(), delay: delay ?? 0 }); return id;
  });
  spyOn(window, 'clearInterval').mockImplementation(id => { if (id !== undefined) timers.delete(id); });
  spyOn(globalThis, 'clearInterval').mockImplementation(id => { if (id !== undefined) timers.delete(Number(id)); });
});
afterEach(async () => {
  try {
    await act(async () => root.unmount()); container.remove();
    expect(timers.size).toBe(0);
  } finally { mock.restore(); }
});
async function render(children: ReactNode) { await act(async () => root.render(children)); }
function button(text: string) {
  const found = [...container.querySelectorAll('button')].find(item => item.textContent === text);
  if (!found) throw new Error(`Button not found: ${text}`);
  return found;
}

test('measurements age on a 15-second clock without another server response, and the clock is cleaned up', async () => {
  const now = spyOn(Date, 'now').mockReturnValue(host.measuredAtMs + 29000);
  await render(<MachinesScreen route={{ screen: 'machine.detail', id: machine.id }} />);
  expect(container.textContent).toContain('Last updated');
  expect(container.textContent).not.toContain('may be out of date');
  const clock = [...timers.values()].find(timer => timer.delay === 15000);
  expect(clock).toBeDefined();
  const reads = calls.length;
  now.mockReturnValue(host.measuredAtMs + 44000);
  await act(async () => clock!.callback());
  expect(container.textContent).toContain('may be out of date');
  expect(calls).toHaveLength(reads);
});

test('offline measurements are labelled out of date immediately', async () => {
  responses.set('GET /machines/:id', { ...machine, status: 'offline' });
  spyOn(Date, 'now').mockReturnValue(host.measuredAtMs);
  await render(<MachinesScreen route={{ screen: 'machine.detail', id: machine.id }} />);
  expect(container.textContent).toContain('may be out of date');
});

test('memory source has descriptive visible and accessible text but retains exact-entry navigation', async () => {
  await render(<MemoryPanel bot={bot} />);
  const source = button('Open source conversation');
  expect(source.title).toBe(memory.sourceEntryId!);
  expect(source.getAttribute('aria-label')).toContain(formatTime(memory.createdAtMs));
  expect(source.textContent).not.toContain(memory.sourceEntryId!);
  await act(async () => source.click());
  expect(navigations).toEqual([{ screen: 'conversation', id: bot.mainConversationId, botId: bot.id, entryId: memory.sourceEntryId! }]);
  expect(calls.every(call => call.endpoint.startsWith('GET '))).toBe(true);
});

test('template identifiers are collapsed while third-party guidance and provenance links remain visible', async () => {
  await render(<TemplatesScreen id={template.id} />);
  const details = [...container.querySelectorAll('details')].find(item => item.textContent?.includes(template.id));
  expect(details?.open).toBe(false);
  expect(details?.querySelector('summary')?.textContent).toBe('Details');
  expect(details?.textContent).toContain(`revision ${template.revision}`);
  expect(container.textContent).toContain('Made by a third party. Read the instructions before using them.');
  expect(container.querySelector('a')?.getAttribute('rel')).toBe('noopener noreferrer');
});

test('channel states and asymmetric message capabilities are readable without empty event jargon', async () => {
  const states = { configured: 'Waiting for setup', connected: 'Connected', disconnected: 'Disconnected', blocked: 'Blocked', failed: 'Connection failed' } as const;
  for (const [state, label] of Object.entries(states)) {
    responses.set('GET /channels', { items: [{ ...binding, state }], nextCursor: null });
    await render(<ChannelsScreen key={state} route={{ screen: 'integrations.channels' }} />);
    expect([...container.querySelectorAll('.badge')].some(item => item.textContent === label)).toBe(true);
    expect(container.textContent).toContain('Can receive messages');
    expect(container.textContent).toContain('Send messages: Not supported');
    expect(container.textContent).not.toContain('Events: None advertised');
  }
});

test('X provider distinguishes setup from account authorization and names requested permissions', async () => {
  await render(<XScreen key="unconfigured" route={{ screen: 'integrations.x' }} />);
  expect(container.textContent).toContain('Not available on this server');
  expect(container.textContent).toContain('Ask your administrator to set up X.');
  expect(container.textContent).toContain('Permissions requested: None');
  expect(button('Connect my X account through OAuth').disabled).toBe(true);
  responses.set('GET /x/provider', { ...xProvider, configured: true, oauthScopes: ['tweet.read'] });
  await render(<XScreen key="configured" route={{ screen: 'integrations.x' }} />);
  expect(container.textContent).toContain('Ready to connect');
  expect(container.textContent).toContain('Permissions requested: tweet.read');
  expect(container.textContent).not.toContain('Ask your administrator');
  responses.set('GET /x/provider', null);
  await render(<XScreen key="absent" route={{ screen: 'integrations.x' }} />);
  expect(container.textContent).toContain('Ask your administrator to set up X.');
});

test('terminal explains full access before opening and keeps output sequences behind Details after a gap', async () => {
  await render(<MachineTerminal machine={machine} />);
  expect(container.textContent).toContain(`Open a terminal on ${machine.name}`);
  expect(container.textContent).toContain('Commands run as your user on that computer.');
  expect(container.textContent).toContain('I understand this terminal has full access to this computer.');
  expect(button('Open real host shell').disabled).toBe(true);
  await render(<MachineTerminal key="existing" machine={machine} terminalId={terminal.id} />);
  await act(async () => {
    for (const listener of listeners) listener({ type: 'terminal_gap', terminalId: terminal.id, earliestSeq: 12, latestSeq: 45 });
  });
  const alert = container.querySelector('[role="alert"]')!;
  expect(alert.querySelector('p')?.textContent).toBe('Some earlier output was not kept. Only available output is shown.');
  expect(alert.querySelector('details')?.open).toBe(false);
  expect(alert.querySelector('details')?.textContent).toContain('12–45');
  expect(calls.every(call => call.endpoint.startsWith('GET '))).toBe(true);
});

test('operation progress counts only succeeded, skipped and failed targets as finished', async () => {
  await render(<HostOperations />);
  expect(container.textContent).toContain('Only actions this computer supports are available.');
  expect(container.textContent).toContain('Queued means it hasn’t finished yet — not that it worked.');
  await act(async () => button(`Update Lemon worker · ${formatTime(operation.createdAtMs)}`).click());
  const progress = container.querySelector('progress')!;
  expect(progress.getAttribute('aria-label')).toBe('Finished: 3 of 6');
  expect(progress.value).toBe(3);
  expect(progress.max).toBe(6);
});

test('files use the real default directory boundary and a plain upload label', async () => {
  await render(<MachinesScreen route={{ screen: 'machine.files', id: machine.id }} />);
  expect(container.textContent).toContain(`Paths are relative to ${machine.name}’s default folder.`);
  expect(container.textContent).toContain('Symlinks that point outside allowed folders are blocked.');
  expect(button('Upload file').disabled).toBe(true);
  expect(container.textContent).not.toContain('Upload bounded chunks');
  expect(container.querySelectorAll('.machine-warning strong')).toHaveLength(1);
  expect(app.online).toBe(true);
});
