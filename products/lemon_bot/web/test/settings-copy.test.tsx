import { afterAll, beforeEach, expect, mock, test } from 'bun:test';
import { renderToStaticMarkup } from 'react-dom/server';
import * as app from '../src/app';
import * as ui from '../src/ui';

const originalApp = { ...app };
const originalUi = { ...ui };
const originalWindow = globalThis.window;
const originalStorage = globalThis.localStorage;
const user = {
  id: 'owner', revision: 1,
  notifications: { enabled: true, sound: true, previews: true, completed: true, needsInput: true },
  preferences: { voice: { voiceId: 'default', speed: 1, language: null } },
};
const queries = new Map<string, { data?: unknown; error?: unknown; loading?: boolean }>();
let savedMicrophone = '';
const context = {
  client: { call: async () => { throw new Error('Rendering must not call the server'); } },
  snapshot: { workspace: { id: 'workspace', name: 'Test workspace', ownerUserId: 'owner' }, user, bots: [] },
  device: null, online: true, refresh: async () => undefined, navigate: () => undefined,
};
mock.module('../src/app', () => ({ ...originalApp, useApp: () => context }));
mock.module('../src/ui', () => ({ ...originalUi, useQuery: (key: string) => ({ loading: false, ...queries.get(key), reload: async () => undefined, setData: () => undefined }) }));
// Load the screens after replacing their context/query module boundaries; static
// imports would mount the real workspace hooks before this isolated render setup.
const { NotificationSettings } = await import('../src/features/settings/notifications');
const { VoiceSettingsScreen } = await import('../src/features/settings/voice');
const { OwnerControlsScreen } = await import('../src/features/enterprise');
const { UsageSettings } = await import('../src/features/settings/usage');
const { SpendScreen } = await import('../src/features/enterprise/spend');

beforeEach(() => {
  queries.clear();
  savedMicrophone = '';
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { isSecureContext: true, speechSynthesis: {}, SpeechRecognition: {} } });
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: () => savedMicrophone || null } });
});
afterAll(() => {
  mock.module('../src/app', () => originalApp);
  mock.module('../src/ui', () => originalUi);
  Object.defineProperty(globalThis, 'window', { configurable: true, value: originalWindow });
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: originalStorage });
});

test('notification setup names each destination and gives a nontechnical next step', () => {
  queries.set('settings:push-capabilities', { data: { webPush: false, apns: false } });
  queries.set('settings:push-device:none', { data: null });
  const markup = renderToStaticMarkup(<NotificationSettings />);
  expect(markup).toContain('Browser notifications (server)');
  expect(markup).toContain('iPhone notifications (server)');
  expect(markup).toContain('Ask your administrator to turn on browser notifications.');
  expect(markup).toContain('Ask your administrator to turn on iPhone notifications.');
  expect(markup).toContain('This browser isn’t registered yet. Reload the page.');
  expect(markup).toContain('Check browser status');
  expect(markup).toContain('The in-app inbox always keeps your alerts');
  expect(markup).toContain('Hidden Bots don’t send notifications, but they keep working.');
  expect(markup).not.toContain('operator must configure');
  expect(markup).not.toContain('APNs');
  expect(markup).not.toContain('not confirmed absent');
});

test('notification registration checks distinguish loading, failed reads and absence', () => {
  queries.set('settings:push-device:none', { loading: true });
  expect(renderToStaticMarkup(<NotificationSettings />)).toContain('Checking this browser’s registration…');
  queries.set('settings:push-device:none', { error: new Error('unavailable') });
  const failed = renderToStaticMarkup(<NotificationSettings />);
  expect(failed).toContain('Couldn’t check this browser’s registration. Try Reload.');
  expect(failed).not.toContain('This browser isn’t registered yet.');
  queries.set('settings:push-capabilities', { data: { webPush: true, apns: true } });
  expect(renderToStaticMarkup(<NotificationSettings />)).toContain('<dd>On</dd>');
});

test('voice settings distinguish server and browser voices without implying dictation is private', () => {
  queries.set('settings:voice-user', { data: user });
  queries.set('settings:voice-capabilities', { data: { tts: false, stt: false } });
  const markup = renderToStaticMarkup(<VoiceSettingsScreen />);
  expect(markup).toContain('Off — ask your administrator to turn on server voice.');
  expect(markup).toContain('Available on this device; it doesn’t use server voice.');
  expect(markup).toContain('some browsers send audio to their company.');
  expect(markup).toContain('Server voice ID');
  expect(markup).toContain('Play server voice sample');
  expect(markup).toContain('Play browser voice sample');
  expect(markup).toContain('This sample uses your browser’s voices, not the server voice ID.');
  expect(markup).not.toContain('Configured real provider');
  queries.set('settings:voice-capabilities', { data: { tts: true, stt: true } });
  expect(renderToStaticMarkup(<VoiceSettingsScreen />)).toContain('<dt>Server voice</dt><dd>On</dd>');
});

test('a saved microphone is not presented as an inspected connected device', () => {
  savedMicrophone = 'saved-input-id';
  const markup = renderToStaticMarkup(<VoiceSettingsScreen />);
  expect(markup).toContain('Previously selected microphone (not connected yet)');
  expect(markup).not.toContain('not yet inspected');
});

test('owner navigation and usage agree on simple settings names', () => {
  const navigation = renderToStaticMarkup(<OwnerControlsScreen route={{ screen: 'settings.unknown' }} />);
  expect(navigation).toContain('Network access');
  expect(navigation).toContain('Startup scripts');
  expect(navigation).toContain('Spend limits');
  expect(navigation).not.toMatch(/measured enforcement|Network &amp; egress|Reviewed host setup|Advanced owner settings/);
  expect(renderToStaticMarkup(<UsageSettings />)).toContain('>Spend limits</button>');
  expect(renderToStaticMarkup(<SpendScreen />)).toContain('<h2>Spend limits</h2>');
});
