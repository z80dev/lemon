import { expect, test } from 'bun:test';
import { renderToStaticMarkup } from 'react-dom/server';
import { type InstanceStatus, type RuntimeAction } from '@lemon-bot/sdk';
import fixture from '../../sdk/ts/test/fixtures/instance-status.json';
import { ChannelHealth, ProviderHealth } from '../src/features/settings/instance';
import { RuntimeActions, RuntimeConfirmation, RuntimeOperationView } from '../src/instance';

const status = fixture as InstanceStatus;
const onAction = (_action: RuntimeAction) => undefined;

test('lifecycle buttons follow only advertised actions in settings and connection recovery', () => {
  for (const recovery of [false, true]) {
    for (const actions of [[], ['start'], ['restart'], ['stop'], ['restart', 'stop'], ['start', 'restart', 'stop']] satisfies RuntimeAction[][]) {
      const markup = renderToStaticMarkup(<RuntimeActions runtime={{ ...status.runtime, actions }} owner available busy={false} recovery={recovery} onAction={onAction}/>);
      for (const action of ['start', 'restart', 'stop'] as const) {
        const label = action[0].toUpperCase() + action.slice(1) + (recovery ? ' Lemon' : '');
        expect(markup.includes(`>${label}</button>`)).toBe(actions.includes(action) && (!recovery || action !== 'stop'));
      }
    }
  }
});

test('lifecycle copy distinguishes launcher and remote controller, including missing-action reasons', () => {
  const remote = renderToStaticMarkup(<RuntimeActions runtime={status.runtime} owner available busy={false} onAction={onAction}/>);
  expect(remote).toContain('Restarts or stops Lemon remotely.');
  expect(remote).toContain('Start isn’t available while Lemon is down.');
  expect(remote).toContain(status.runtime.reason!);
  expect(remote).not.toContain('>Start</button>');
  const launcher = renderToStaticMarkup(<RuntimeActions runtime={{ actions: ['start'], via: 'launcher', reason: null, operation: null }} owner available busy={false} onAction={onAction}/>);
  expect(launcher).toContain('Runs the Lemon launcher on the service host');
  expect(launcher).not.toContain('remotely');
  const down = renderToStaticMarkup(<RuntimeActions runtime={{ actions: [], via: null, reason: 'Start Lemon on its host.', operation: null }} owner available busy={false} recovery onAction={onAction}/>);
  expect(down).toContain('Start Lemon on its host.');
  expect(down).not.toContain('<button');
});

test('lifecycle controls retain role, offline and operation fences', () => {
  const admin = renderToStaticMarkup(<RuntimeActions runtime={status.runtime} owner={false} available busy={false} onAction={onAction}/>);
  expect(admin).toContain('Only workspace owners');
  expect(admin).not.toContain('<button');
  for (const [available, busy] of [[false, false], [true, true]]) {
    const markup = renderToStaticMarkup(<RuntimeActions runtime={status.runtime} owner available={available} busy={busy} onAction={onAction}/>);
    expect(markup.match(/disabled=""/g)).toHaveLength(status.runtime.actions.length);
  }
});

test('stop confirmation does not promise remote start and keeps explicit confirmation', () => {
  for (const via of ['launcher', 'controller', null] as const) {
    const markup = renderToStaticMarkup(<RuntimeConfirmation action="stop" via={via} available busy={false} uncertain={false} error={undefined} onConfirm={async () => undefined} onCancel={() => undefined}/>);
    expect(markup).toContain('role="dialog"');
    expect(markup).toContain('>Cancel</button>');
    expect(markup).toContain('>Stop Lemon</button>');
    expect(markup.includes('so you can start it from here')).toBe(via === 'launcher');
    expect(markup.includes('you’ll need to start Lemon on its host')).toBe(via !== 'launcher');
  }
  const restart = renderToStaticMarkup(<RuntimeConfirmation action="restart" via="controller" available={false} busy={false} uncertain={false} error={undefined} onConfirm={async () => undefined} onCancel={() => undefined}/>);
  expect(restart).toContain('Restart Lemon?');
  expect(restart).toContain('disabled=""');
});

test('provider diagnostic history is distinct from management and effective default', () => {
  const providers = status.lemon!.providers!.map(provider => ({ ...provider, lastError: provider.lastError && { ...provider.lastError, atMs: Date.now() - 120000 } }));
  const markup = renderToStaticMarkup(<ProviderHealth providers={providers}/>);
  expect(markup).toContain('<h2>Provider diagnostic history</h2>');
  expect(markup).not.toContain('>Default<');
  expect(markup).toContain('badge good">Key available');
  expect(markup).toContain('badge warning">Key missing');
  expect(markup).toContain('Manage credentials in Settings → Providers.');
  expect(markup).not.toContain('lemon setup');
  expect(markup).toContain('badge muted">Key not required');
  expect(markup).not.toContain('not_required');
  expect(markup).toContain('Provider authentication failed.');
  expect(markup).toContain('2 minutes ago');
  expect(markup).toContain('<time');
  expect(markup.match(/Last error:/g)).toHaveLength(1);
  expect(renderToStaticMarkup(<ProviderHealth providers={null}/>)).toContain('Provider details are unavailable.');
  expect(renderToStaticMarkup(<ProviderHealth providers={[]}/>)).toContain('No providers configured.');
  expect(renderToStaticMarkup(<ProviderHealth providers={[{ id: 'local', credential: 'not_required', configured: false, isDefault: false, lastError: null }]}/>)).toContain('Not configured');
});

test('channel details replace chips with state rows and observed errors', () => {
  const channels = status.lemon!.channels!.details.map(channel => ({ ...channel, lastError: channel.lastError && { ...channel.lastError, atMs: Date.now() - 60000 } }));
  const markup = renderToStaticMarkup(<ChannelHealth channels={[...channels, { id: 'slack', state: 'configured', lastError: null }]}/>);
  expect(markup.match(/<li /g)).toHaveLength(3);
  expect(markup).toContain('badge good">Connected');
  expect(markup).toContain('badge danger">Error');
  expect(markup).toContain('badge muted">Configured');
  expect(markup).toContain('Channel connection failed.');
  expect(markup).toContain('1 minute ago');
  expect(markup.match(/Last error:/g)).toHaveLength(1);
  expect(renderToStaticMarkup(<ChannelHealth channels={[]}/>)).toContain('No channels configured.');
});

test('remote operations retain progress without inventing an exit code', () => {
  const markup = renderToStaticMarkup(<RuntimeOperationView operation={{ id: 'remote-restart', action: 'restart', state: 'running', startedAtMs: Date.now(), completedAtMs: null, exitCode: null, output: 'Waiting for Lemon to reconnect.' }}/>);
  expect(markup).toContain('Restarting Lemon');
  expect(markup).toContain('In progress');
  expect(markup).toContain('Waiting for Lemon to reconnect.');
  expect(markup).not.toContain('Exit code:');
});
