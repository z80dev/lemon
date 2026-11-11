import { afterAll, afterEach, beforeEach, expect, mock, spyOn, test } from 'bun:test';
import { act, StrictMode } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createRoot, type Root } from 'react-dom/client';
import { Window } from 'happy-dom';
import { LemonBotClient, type SignInMethods } from '@lemon-bot/sdk';
import * as app from '../src/app';
import * as ui from '../src/ui';

const originalApp = { ...app }, originalUi = { ...ui };
const globals = ['window', 'document', 'location', 'history', 'navigator', 'localStorage', 'sessionStorage', 'HTMLElement', 'IS_REACT_ACT_ENVIRONMENT'] as const;
const originals = new Map(globals.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
const queries = new Map<string, unknown>();
const call = mock(async (_route: string, _options?: unknown): Promise<unknown> => ({}));
const navigate = mock(() => undefined);
const context = {
  client: { baseUrl: 'http://127.0.0.1:4100/v1', call },
  snapshot: { workspace: { id: 'workspace', name: 'Workspace' }, user: { id: 'owner' }, bots: [] },
  online: true, refresh: async () => undefined, logout: async () => undefined, navigate,
};
mock.module('../src/app', () => ({ ...originalApp, useApp: () => context }));
mock.module('../src/ui', () => ({ ...originalUi, useQuery: (key: string) => ({ data: queries.get(key), loading: false, reload: async () => undefined, setData: () => undefined }) }));
// These screens must load after the context/query mocks replace their module boundaries.
const { AuthScreen } = await import('../src/auth');
const { takeSignInTicket, ticketErrorNotice, TicketSignIn, UnlockedNotice, unlockNoticeKey } = await import('../src/local-signin');
const { AccountSettings, AddPasswordForm } = await import('../src/features/settings/account');
const { PairingScreen } = await import('../src/features/pairing');
let browser: Window;
let root: Root | undefined;
const freshMethods = (): SignInMethods => ({ password: false, email: 'alex@lemon.local', emailIsPlaceholder: true, localOwner: { platform: 'macos', osUser: 'alex', hostName: 'Alex-Mac' }, localConfirmedUntilMs: Date.now() + 600_000 });
const methods = (value: SignInMethods) => { queries.set('settings:sign-in', value); queries.set('sign-in:unlock-notice', value); queries.set('pairing:sign-in', value); };
function parsed(markup: string) { const node = document.createElement('div'); node.innerHTML = markup; return node; }
async function mount(element: React.ReactNode) { const node = document.createElement('div'); document.body.append(node); root = createRoot(node); await act(async () => { root!.render(element); }); return node; }
async function click(button: Element | null) { expect(button).not.toBeNull(); await act(async () => { (button as HTMLButtonElement).click(); }); }

beforeEach(() => {
  browser = new Window({ url: 'http://127.0.0.1:4100/' });
  for (const key of globals) Object.defineProperty(globalThis, key, { configurable: true, writable: true, value: key === 'IS_REACT_ACT_ENVIRONMENT' ? true : key === 'window' ? browser : Reflect.get(browser, key) });
  queries.clear(); call.mockClear(); navigate.mockClear(); methods(freshMethods());
  queries.set('setup:http://127.0.0.1:4100/v1', { setupRequired: false });
});
afterEach(async () => { if (root) { await act(async () => root!.unmount()); root = undefined; } await browser.happyDOM.close(); });
afterAll(() => {
  mock.module('../src/app', () => originalApp); mock.module('../src/ui', () => originalUi);
  for (const key of globals) { const descriptor = originals.get(key); if (descriptor) Object.defineProperty(globalThis, key, descriptor); else Reflect.deleteProperty(globalThis, key); }
});

test('takes and strips valid and malformed sign-in fragments, preserving path and query', () => {
  const ticket = 'a'.repeat(43);
  history.replaceState(null, '', `/sign-in?source=terminal#lemonbot-signin=${ticket}`);
  expect(takeSignInTicket()).toBe(ticket);
  expect(location.href).toBe('http://127.0.0.1:4100/sign-in?source=terminal');
  for (const fragment of ['short', '', `${ticket}&screen=inbox`, '%61'.repeat(43)]) {
    location.hash = `lemonbot-signin=${fragment}`;
    expect(takeSignInTicket()).toBe('invalid'); expect(location.hash).toBe('');
  }
  location.hash = 'screen=inbox'; expect(takeSignInTicket()).toBeNull(); expect(location.hash).toBe('#screen=inbox');
});

test('maps every ticket error to its recovery action', () => {
  const notices = {
    expired: 'This sign-in link expired. Run `lemon-bot open` on this computer for a new one.',
    unauthenticated: "This sign-in link was already used or isn't valid. Run `lemon-bot open` on this computer for a new one.",
    invalid: "This sign-in link was already used or isn't valid. Run `lemon-bot open` on this computer for a new one.",
    forbidden: 'Open the sign-in link on the computer running Lemon Bot, or through its SSH tunnel.',
    capability_unavailable: "This Lemon Bot doesn't accept sign-in links. Sign in with your email and password.",
    rate_limited: 'Too many failed sign-in links. Wait a minute, then run `lemon-bot open` again.',
  };
  for (const [code, notice] of Object.entries(notices)) { expect(ticketErrorNotice({ code })).toBe(notice); expect(ticketErrorNotice(code)).toBe(notice); }
  expect(ticketErrorNotice(new Error('private detail'))).not.toContain('private detail');
});

test('loopback setup makes open primary and keeps the full setup form in a disclosure', () => {
  queries.set('setup:http://127.0.0.1:4100/v1', { setupRequired: true });
  const node = parsed(renderToStaticMarkup(<AuthScreen onAuth={() => undefined}/>));
  expect(node.textContent).toContain('Finish setting up Lemon Bot'); expect(node.textContent).toContain('no password needed');
  const details = [...node.querySelectorAll('details')].find(item => item.querySelector('summary')?.textContent === 'Use a one-time setup code instead');
  expect(details?.hasAttribute('open')).toBe(false); expect(details?.querySelectorAll('input').length).toBe(5);
  expect(node.textContent).toContain('lemon-bot open');
});

test('loopback login has the command hint, including IPv6, but published origins remain unchanged', () => {
  expect(renderToStaticMarkup(<AuthScreen onAuth={() => undefined}/>)).toContain('On this computer?');
  browser.happyDOM.setURL('http://[::1]:4100/'); queries.set('setup:http://[::1]:4100/v1', { setupRequired: false });
  expect(renderToStaticMarkup(<AuthScreen onAuth={() => undefined}/>)).toContain('On this computer?');
  browser.happyDOM.setURL('https://bot.example/');
  for (const setupRequired of [false, true]) {
    queries.set('setup:https://bot.example/v1', { setupRequired });
    const markup = renderToStaticMarkup(<AuthScreen onAuth={() => undefined}/>);
    expect(markup).not.toContain('lemon-bot open'); expect(markup).not.toContain('Use a one-time setup code instead');
  }
});

test('passwordless account identifies the Mac user, offers Add, and has no current-password field', () => {
  const node = parsed(renderToStaticMarkup(<AccountSettings/>));
  expect(node.textContent).toContain("This Mac's login"); expect(node.textContent).toContain('alex on Alex-Mac');
  expect(node.textContent).toContain('Add email and password'); expect(node.textContent).not.toContain('Current password');
  const confirm = [...node.querySelectorAll('button')].find(item => item.textContent === "Confirm with this Mac's login"); expect(confirm?.disabled).toBe(false);
  const form = parsed(renderToStaticMarkup(<AddPasswordForm methods={freshMethods()} disabled={false} onSave={async () => true}/>));
  expect(form.querySelector('fieldset')?.disabled).toBe(false); expect(form.querySelector('input[type=email]')?.getAttribute('value')).toBe('');
});

test('stale local confirmation disables adding a password and local deletion confirmation', () => {
  const stale = { ...freshMethods(), localConfirmedUntilMs: Date.now() - 1 }; methods(stale);
  const form = parsed(renderToStaticMarkup(<AddPasswordForm methods={stale} disabled={false} onSave={async () => true}/>));
  expect(form.querySelector('fieldset')?.disabled).toBe(true); expect(form.textContent).toContain('then add it in the window that opens');
  expect(form.textContent).toContain('lemon-bot open');
  const account = parsed(renderToStaticMarkup(<AccountSettings/>));
  expect([...account.querySelectorAll('button')].find(item => item.textContent === "Confirm with this Mac's login")?.disabled).toBe(true);
});

test('password users see the change form, not Add, and real emails prefill the Add form', () => {
  const value = { ...freshMethods(), password: true, email: 'alex@example.com', emailIsPlaceholder: false }; methods(value);
  const account = parsed(renderToStaticMarkup(<AccountSettings/>));
  expect(account.textContent).toContain('Set for alex@example.com.'); expect(account.textContent).toContain('Current password'); expect(account.textContent).not.toContain('Add email and password');
  const form = parsed(renderToStaticMarkup(<AddPasswordForm methods={value} disabled={false} onSave={async () => true}/>));
  expect(form.querySelector('input[type=email]')?.getAttribute('value')).toBe('alex@example.com');
});

test('Linux account and unlock copy use the host name rather than Mac', () => {
  const value = freshMethods(); value.localOwner!.platform = 'linux'; methods(value); sessionStorage.setItem('lemonbot.localSignIn', '1');
  const account = parsed(renderToStaticMarkup(<AccountSettings/>));
  expect(account.textContent).toContain('Your login on Alex-Mac'); expect(account.textContent).toContain('Confirm with your login on Alex-Mac'); expect(account.textContent).not.toContain("This Mac's login");
  expect(parsed(renderToStaticMarkup(<UnlockedNotice/>)).textContent).toContain('Unlocked by your login on Alex-Mac');
});

test('unlock notice requires local ticket session, passwordless owner, fresh proof, and no dismissal', () => {
  const render = () => parsed(renderToStaticMarkup(<UnlockedNotice/>)).textContent;
  expect(render()).toBe(''); sessionStorage.setItem('lemonbot.localSignIn', '1'); expect(render()).toContain('Unlocked by your Mac login');
  for (const override of [{ password: true }, { localOwner: null }, { localConfirmedUntilMs: null }, { localConfirmedUntilMs: Date.now() - 1 }]) { methods({ ...freshMethods(), ...override }); expect(render()).toBe(''); }
  methods(freshMethods()); localStorage.setItem(unlockNoticeKey('workspace', 'owner'), '1'); expect(render()).toBe('');
  localStorage.clear(); localStorage.setItem(unlockNoticeKey('another-workspace', 'owner'), '1'); expect(render()).toContain('Unlocked');
});

test('Not now persists notice dismissal for this workspace and user', async () => {
  sessionStorage.setItem('lemonbot.localSignIn', '1');
  const node = await mount(<UnlockedNotice/>);
  await click([...node.querySelectorAll('button')].find(item => item.textContent === 'Not now')!);
  expect(localStorage.getItem('lemonbot.unlockNotice.dismissed:workspace:owner')).toBe('1'); expect(node.textContent).toBe('');
  expect(renderToStaticMarkup(<UnlockedNotice/>)).toBe('');
});

test('local deletion confirmation uses local:true and retains the reauth result', async () => {
  call.mockImplementation(async () => ({ reauthToken: 'reauth', expiresAtMs: Date.now() + 60_000 }));
  const node = await mount(<AccountSettings/>);
  await click([...node.querySelectorAll('button')].find(item => item.textContent === "Confirm with this Mac's login")!);
  expect(call).toHaveBeenCalledWith('POST /auth/reauth', { body: { local: true } });
  expect(node.textContent).toContain('Identity confirmed until');
  expect([...node.querySelectorAll('button')].find(item => item.textContent === 'Review account deletion')?.disabled).toBe(false);
});

test('ticket redemption stays same-origin, runs once in Strict Mode, and saves the new tab session', async () => {
  const redeem = spyOn(LemonBotClient.prototype, 'call').mockResolvedValue({ token: 'new-session', user: { id: 'owner', email: 'alex@lemon.local' }, workspace: { id: 'workspace', name: 'Workspace' } } as never);
  try {
    const onAuth = mock(() => undefined), onFail = mock(() => undefined);
    sessionStorage.setItem('lemonbot.session', JSON.stringify({ token: 'old-session' }));
    await mount(<StrictMode><TicketSignIn ticket={'a'.repeat(43)} onAuth={onAuth} onFail={onFail}/></StrictMode>);
    expect(redeem).toHaveBeenCalledTimes(1); expect(redeem).toHaveBeenCalledWith('POST /auth/local/redeem', { body: { ticket: 'a'.repeat(43) } });
    expect(onAuth).toHaveBeenCalledTimes(1); expect(onFail).not.toHaveBeenCalled();
    expect(JSON.parse(sessionStorage.getItem('lemonbot.session')!)).toMatchObject({ baseUrl: 'http://127.0.0.1:4100/v1', token: 'new-session' });
    expect(sessionStorage.getItem('lemonbot.localSignIn')).toBe('1'); expect(location.hash).toBe('#screen=home');
    expect(localStorage.getItem('lemonbot.accounts')).not.toContain('new-session');
  } finally { redeem.mockRestore(); }
});

test('invalid tickets never make a redemption request', async () => {
  const redeem = spyOn(LemonBotClient.prototype, 'call');
  try { const failed = mock(() => undefined); await mount(<TicketSignIn ticket="invalid" onAuth={() => undefined} onFail={failed}/>); expect(redeem).not.toHaveBeenCalled(); expect(failed).toHaveBeenCalledWith('invalid'); } finally { redeem.mockRestore(); }
});

test('Connect iPhone explains passwordless pairing only when no password is set', () => {
  expect(parsed(renderToStaticMarkup(<PairingScreen/>)).textContent).toContain("Your iPhone doesn't need a password.");
  methods({ ...freshMethods(), password: true }); expect(parsed(renderToStaticMarkup(<PairingScreen/>)).textContent).not.toContain("Your iPhone doesn't need a password.");
});
