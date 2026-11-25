import { afterEach, describe, expect, test } from 'bun:test';
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { baseBotMcpTemplate } from '../../src/core/bots';
import { runHttpsCli, type HttpsCliDependencies } from '../../src/cli/https';
import type { LocalAdmissionSnapshot } from '../../src/cli/readdress';

const native = 'LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS';
const cron = 'LEMON_CRON_ADMISSION_ALLOWED_ORIGINS';
const origin = 'https://bot.example.test';
const loopback = 'http://127.0.0.1:4100';
const homes: string[] = [];
afterEach(async () => { for (const home of homes.splice(0)) await rm(home, { recursive: true, force: true }); });

interface Options {
  routes?: Routes;
  controllerAllows?: boolean;
  remoteInstance?: string;
  sourceMode?: boolean;
  publicUrl?: string;
  bots?: LocalAdmissionSnapshot;
}
interface Routes { Web?: Record<string, unknown>; TCP?: Record<string, unknown> }
async function harness(options: Options = {}) {
  const home = await mkdtemp(join(tmpdir(), 'bot-https-')); homes.push(home);
  const dataDir = join(home, '.lemon', 'lemon_bot');
  await mkdir(dataDir, { recursive: true });
  const configPath = join(dataDir, 'config.json');
  const calls: string[][] = [], environments: Record<string, string | undefined>[] = [], doctor: string[] = [];
  const stdout: string[] = [], stderr: string[] = [];
  let routes: Routes = options.routes ?? {};
  const running = { publicUrl: options.publicUrl ?? loopback, firstPartyMcpApproved: true };
  const approvals = async (): Promise<string[]> => {
    try {
      const config: unknown = JSON.parse(await readFile(configPath, 'utf8'));
      return config && typeof config === 'object' && 'approvedPrivateMcpOrigins' in config && Array.isArray(config.approvedPrivateMcpOrigins) ? config.approvedPrivateMcpOrigins : [];
    } catch { return []; }
  };
  const unit = (role: string) => JSON.stringify({ schema: 1, manager: 'launchd', persistence: 'login', linger: null, units: [{ role, name: null, state: 'ready', detail: null }] });
  const deps: HttpsCliDependencies = {
    env: { HOME: home },
    async spawn(executable, args, input = {}) {
      calls.push([executable, ...args]);
      if (executable === 'tailscale') {
        if (args[0] === 'status') return { exitCode: 0, stdout: JSON.stringify({ BackendState: 'Running', Self: { DNSName: 'Mac.Example.ts.net.' } }), stderr: '' };
        if (args.join(' ') === 'serve status --json') return { exitCode: 0, stdout: JSON.stringify(routes), stderr: '' };
        const port = args.find(arg => arg.startsWith('--https='))!.slice('--https='.length);
        const web = { ...routes.Web };
        if (args.at(-1) === 'off') delete web[`mac.example.ts.net:${port}`];
        else web[`mac.example.ts.net:${port}`] = { Handlers: { '/': { Proxy: args.at(-1) } } };
        routes = { ...routes, Web: web };
        return { exitCode: 0, stdout: '', stderr: '' };
      }
      environments.push({ ...input.environment });
      if (args[0] === 'restart') return { exitCode: 0, stdout: '', stderr: '' };
      const role = args[2]!;
      if (role === 'backend') {
        const publicUrl = input.environment?.LEMON_BOT_PUBLIC_URL ?? loopback;
        running.publicUrl = publicUrl;
        running.firstPartyMcpApproved = (await approvals()).includes(publicUrl) || publicUrl.startsWith('http://127.0.0.1');
      }
      return { exitCode: 0, stdout: unit(role), stderr: '' };
    },
    fetch: (async (input: string | URL | Request) => {
      const url = String(input);
      if (url === `${loopback}/v1/setup`) return Response.json({ product: 'lemon_bot', instanceId: 'instance', ...running });
      return Response.json({ product: 'lemon_bot', instanceId: options.remoteInstance ?? 'instance', ...running });
    }) as typeof fetch,
    resolve: async () => ['100.64.0.1'],
    async controllerDoctor(requested, controller) {
      expect(controller.controlUrl).toBe('ws://127.0.0.1:4040/ws');
      doctor.push(requested);
      return options.controllerAllows ?? true;
    },
    executable: async path => path === join(home, '.lemon', 'bin', 'lemon'),
    exists: async path => options.sourceMode === true && path.endsWith('mix.exs'),
    botPath: '/opt/lemon-bot',
    readLocal: () => options.bots ?? { bots: [], totalBots: 0, truncated: false },
    template: baseBotMcpTemplate,
    stdout(value) { stdout.push(value); }, stderr(value) { stderr.push(value); },
  };
  const run = (...args: string[]) => runHttpsCli(args, deps);
  const text = (path: string) => readFile(join(home, path), 'utf8');
  const exists = (path: string) => stat(join(home, path)).then(() => true, () => false);
  const receipt = async () => JSON.parse(await text('.lemon/bot-https.json')) as Record<string, unknown>;
  const launcherCalls = () => calls.filter(call => call[0] !== 'tailscale').map(call => call.slice(1).join(' '));
  /** The refusal message, plus proof that nothing was written or restarted. */
  const unchanged = async (message: string) => {
    expect(stderr.join('')).toContain(message);
    expect(stderr.join('')).toContain('No settings were changed.');
    expect(launcherCalls()).toEqual([]);
    expect(await exists('.lemon/bot-https.json')).toBe(false);
    expect(await exists('.lemon/lemon_bot/config.json')).toBe(false);
  };
  return { home, deps, run, calls, environments, doctor, stdout, stderr, text, exists, receipt, launcherCalls, unchanged, configPath, routes: () => routes };
}

describe('lemon-bot https enable --url', () => {
  test('records ownership, updates allowlists and MCP approval, restarts through the launcher and verifies', async () => {
    const h = await harness();
    expect(await h.run('enable', '--url', 'https://BOT.example.test:443/')).toBe(0);
    expect(await h.receipt()).toMatchObject({ schema: 2, phase: 'active', origin, mode: 'url', port: null, added: { [native]: [origin], [cron]: [origin] }, public_url: { original: null, owned: true }, private_mcp: { path: h.configPath, added: true, field_existed: false, file_existed: false } });
    expect(await h.text('.lemon/env')).toBe(`export ${native}='${loopback},${origin}'\nexport ${cron}='${loopback},${origin}'\n`);
    expect(JSON.parse(await readFile(h.configPath, 'utf8'))).toEqual({ version: 1, approvedPrivateMcpOrigins: [origin] });
    expect(h.launcherCalls()).toEqual(['service install controller --wait 120 --json', 'restart', 'service install backend --bot /opt/lemon-bot --restart-backend --wait 120 --json']);
    expect(h.environments.every(environment => environment.LEMON_BOT_PUBLIC_URL === origin && environment.LEMON_CONTROL_PLANE_PORT === '4040')).toBe(true);
    expect(h.doctor).toEqual([origin, origin]);
    expect(h.stdout.join('')).toContain(`Address: ${origin} (active)`);
    expect(h.stdout.join('')).toContain(`${native}: allowed`);

    h.calls.length = 0;
    expect(await h.run('enable', '--url', origin)).toBe(0);
    expect(h.launcherCalls()).toEqual([]);
  });

  test('disable removes only owned origins, restores loopback and preserves env permissions and other origins', async () => {
    const h = await harness();
    await mkdir(join(h.home, '.lemon'), { recursive: true });
    await writeFile(join(h.home, '.lemon/env'), `export OTHER=1\n${native}=https://kept.example.test\n`, { mode: 0o640 });
    expect(await h.run('enable', '--url', origin)).toBe(0);
    expect(await h.receipt()).toMatchObject({ added: { [native]: [origin], [cron]: [origin] } });
    expect(await h.run('disable')).toBe(0);
    expect(await h.text('.lemon/env')).toBe(`export OTHER=1\nexport ${native}='https://kept.example.test,${loopback}'\nexport ${cron}='${loopback}'\n`);
    expect((await stat(join(h.home, '.lemon/env'))).mode & 0o777).toBe(0o640);
    expect(await h.exists('.lemon/bot-https.json')).toBe(false);
    expect(await h.exists('.lemon/lemon_bot/config.json')).toBe(false);
    expect(h.environments.at(-1)!.LEMON_BOT_PUBLIC_URL).toBeUndefined();
    expect(h.stdout.at(-1)).toBeDefined();
    expect(h.stdout.join('')).toContain('Address: loopback only (unmanaged)');
  });

  test('disable without a receipt changes nothing', async () => {
    const h = await harness();
    expect(await h.run('disable')).toBe(0);
    expect(h.calls).toEqual([]);
    expect(await h.exists('.lemon/env')).toBe(false);
  });

  test('a failure after settings changed is reported as a partial change, never as "nothing changed"', async () => {
    const h = await harness({ controllerAllows: false });
    expect(await h.run('enable', '--url', origin)).toBe(1);
    const errors = h.stderr.join('');
    expect(errors).toContain('The controller has not confirmed both callback allowlists.');
    expect(errors).toContain('Some settings had already changed before this failure');
    expect(errors).not.toContain('No settings were changed');
    expect(errors).not.toContain('locked');
    expect(await h.receipt()).toMatchObject({ phase: 'pending', origin });
    expect(await h.exists('.lemon/run/bot-https.lock')).toBe(false);
  });

  test('a held lock refuses before any change', async () => {
    const h = await harness();
    await mkdir(join(h.home, '.lemon/run'), { recursive: true });
    await writeFile(join(h.home, '.lemon/run/bot-https.lock'), `${process.pid}\n`);
    expect(await h.run('enable', '--url', origin)).toBe(1);
    expect(h.stderr.join('')).toContain('Another lemon-bot https command is changing these settings. No settings were changed.');
    expect(h.calls).toEqual([]);
    expect(await h.exists('.lemon/bot-https.json')).toBe(false);
  });

  test('a stale lock left by an exited process is reclaimed', async () => {
    const h = await harness();
    await mkdir(join(h.home, '.lemon/run'), { recursive: true });
    await writeFile(join(h.home, '.lemon/run/bot-https.lock'), '999999999\n');
    expect(await h.run('enable', '--url', origin)).toBe(0);
  });

  test('identity mismatch fails after recording ownership', async () => {
    const h = await harness({ remoteInstance: 'other' });
    expect(await h.run('enable', '--url', origin)).toBe(1);
    expect(h.stderr.join('')).toContain('did not serve the same Lemon Bot instance');
    expect(h.stderr.join('')).toContain('Some settings had already changed');
  });
});

describe('refusals before any change', () => {
  for (const args of [['enable', '--url', 'http://bot.example.test'], ['enable', '--url', `${origin}/path`], ['enable'], ['enable', '--tailscale', '--url', origin], ['status', 'extra']]) {
    test(`usage error ${JSON.stringify(args)}`, async () => {
      const h = await harness();
      expect(await h.run(...args)).toBe(2);
      expect(h.calls).toEqual([]);
    });
  }
  test('source-mode startup points at the manual appendix', async () => {
    const h = await harness({ sourceMode: true });
    expect(await h.run('enable', '--url', origin)).toBe(1);
    await h.unchanged('appendix-manual-https-setup');
  });
  test('a saved remote controller is never configured from this machine', async () => {
    const h = await harness();
    await writeFile(join(h.home, '.lemon/lemon_bot/controller.json'), JSON.stringify({ version: 1, mode: 'remote', url: 'wss://remote.example/ws', token: 'PRIVATE' }));
    expect(await h.run('enable', '--url', origin)).toBe(1);
    await h.unchanged('remote controller');
    expect(h.stderr.join('')).not.toContain('PRIVATE');
  });
  test('a non-loopback Bot listener is refused', async () => {
    const h = await harness();
    h.deps.env.LEMON_BOT_HOST = '0.0.0.0'; h.deps.env.LEMON_BOT_PUBLIC_URL = origin;
    expect(await h.run('enable', '--url', origin)).toBe(1);
    await h.unchanged('bind 127.0.0.1');
  });
  test('duplicate or dynamic allowlists are resolved by the operator first', async () => {
    for (const env of [`${native}=a\nexport ${native}=b\n`, `export ${cron}="$OTHER"\n`]) {
      const h = await harness();
      await writeFile(join(h.home, '.lemon/env'), env);
      expect(await h.run('enable', '--url', origin)).toBe(1);
      await h.unchanged('~/.lemon/env');
      expect(await h.text('.lemon/env')).toBe(env);
    }
  });
  test('another configured public address is not replaced', async () => {
    const h = await harness({ publicUrl: 'https://manual.example.test' });
    expect(await h.run('enable', '--url', origin)).toBe(1);
    await h.unchanged('already has another public address');
  });
});

describe('lemon-bot https enable --tailscale', () => {
  test('selects a free port, routes it to loopback and disables only its exact owned route', async () => {
    const foreign = { 'mac.example.ts.net:8443': { Handlers: { '/': { Proxy: 'http://127.0.0.1:9000' } } } };
    const h = await harness({ routes: { Web: foreign } });
    expect(await h.run('enable', '--tailscale')).toBe(0);
    const tailnet = 'https://mac.example.ts.net:8444';
    expect(await h.receipt()).toMatchObject({ phase: 'active', origin: tailnet, mode: 'tailscale', port: 8444, target: loopback });
    expect(h.calls).toContainEqual(['tailscale', 'serve', '--bg', '--https=8444', loopback]);
    expect(h.stdout.join('')).toContain(`Tailscale: 8444 → ${loopback}`);
    expect(await h.run('disable')).toBe(0);
    expect(h.calls).toContainEqual(['tailscale', 'serve', '--https=8444', 'off']);
    expect(h.routes()).toEqual({ Web: foreign });
  });

  test('disable refuses a changed route without touching env or services', async () => {
    const h = await harness();
    expect(await h.run('enable', '--tailscale')).toBe(0);
    const env = await h.text('.lemon/env');
    h.calls.length = 0;
    h.routes().Web!['mac.example.ts.net:8443'] = { Handlers: { '/': { Proxy: 'http://127.0.0.1:9999' } } };
    expect(await h.run('disable')).toBe(1);
    expect(h.stderr.join('')).toContain('refusing to remove someone else\'s route');
    expect(h.stderr.join('')).toContain('No settings were changed.');
    expect(await h.text('.lemon/env')).toBe(env);
    expect(h.launcherCalls()).toEqual([]);
    expect(await h.receipt()).toMatchObject({ phase: 'active' });
  });
});

test('status is read-only and names Bots whose owners must update their address', async () => {
  const bots: LocalAdmissionSnapshot = { totalBots: 2, truncated: false, bots: [
    { id: 'bot_a', name: 'Atlas', profileId: 'p_a', issuer: { state: 'configured', url: `${loopback}/internal/runtime/followup/admission`, profileId: 'p_a' }, pendingIssuer: null, lifecycle: null, readdressTarget: false, addressStepsAcknowledged: false },
    { id: 'bot_b', name: 'Basil\u001b[31m', profileId: 'p_b', issuer: { state: 'configured', url: `${origin}/internal/runtime/followup/admission`, profileId: 'p_b' }, pendingIssuer: null, lifecycle: null, readdressTarget: false, addressStepsAcknowledged: false },
  ] };
  const h = await harness({ bots });
  expect(await h.run('enable', '--url', origin)).toBe(0);
  h.calls.length = 0; h.stdout.length = 0;
  const before = await h.text('.lemon/bot-https.json');
  expect(await h.run('status')).toBe(0);
  const output = h.stdout.join('');
  expect(output).toContain('Bot Atlas (bot_a): configured — Update address');
  expect(output).toMatch(/Bot Basil[^\n]* \(bot_b\): configured\n/);
  expect(output).toContain('ACTION REQUIRED: 1 listed Bot(s)');
  expect(output).not.toContain('\u001b');
  expect(h.launcherCalls()).toEqual([]);
  expect(await h.text('.lemon/bot-https.json')).toBe(before);
});
