import { Database } from 'bun:sqlite';
import { join } from 'node:path';
import { BotPreflightError, preflightBotOrigin, requireBotSystemTLS, validateBotOrigin } from '../contracts/preflight';

// Output is an allowlist: never forward subprocess output, response bodies or errors.
export interface ServeRoute { origin: string; upstreamPort: number | null }
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === 'object' && !Array.isArray(value);
export function serveRoutes(value: unknown): ServeRoute[] {
  const routes: ServeRoute[] = [];
  const web = object(value) ? value.Web : undefined;
  if (!object(web)) return routes;
  for (const [host, config] of Object.entries(web)) {
    try {
      const origin = validateBotOrigin(`https://${host}`.replace(/:443$/, ''));
      if (!new URL(origin).hostname.endsWith('.ts.net')) continue;
      const handlers = object(config) && object(config.Handlers) ? config.Handlers : {};
      const root = handlers['/'];
      const proxy = object(root) ? root.Proxy : undefined;
      let upstreamPort: number | null = null;
      if (typeof proxy === 'string') {
        const url = new URL(proxy);
        if (['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) upstreamPort = Number(url.port || (url.protocol === 'https:' ? 443 : 80));
      }
      routes.push({ origin, upstreamPort });
    } catch { /* Malformed/untrusted metadata is not printable. */ }
  }
  return routes;
}
export async function checkOrigin(origin: string, instanceId: string, configured: boolean, use: 'phone' | 'same-machine', fetcher?: typeof fetch) {
  try {
    const result = await preflightBotOrigin({ origin, expectedInstanceId: instanceId, setup: configured ? 'configured' : 'required', use, fetch: fetcher });
    if (use === 'phone' && result.setup.publicUrl !== result.origin) return { status: 'advertised_origin_mismatch' };
    return { status: 'verified_product_api', setupRequired: result.setup.setupRequired };
  } catch (error) { return { status: error instanceof BotPreflightError ? error.code : 'unavailable' }; }
}
async function command(argv: string[]) {
  try {
    const child = Bun.spawn(argv, { stdout: 'pipe', stderr: 'ignore', env: { ...process.env, PAGER: 'cat' } });
    const timer = setTimeout(() => child.kill(), 10000);
    try { const text = await new Response(child.stdout).text(); return { code: await child.exited, text }; }
    finally { clearTimeout(timer); }
  } catch { return { code: -1, text: '' }; }
}
async function main(): Promise<number> {
  requireBotSystemTLS();
  const args = process.argv.slice(2);
  const options: Record<string, string> = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!['--data-dir', '--local-origin', '--origin'].includes(args[i]) || !args[i + 1] || options[args[i]]) throw new Error('arguments');
    options[args[i]] = args[i + 1];
  }
  const report: Record<string, unknown> = { physicalPhone: 'not_tested', providerLogin: 'not_tested', authenticatedWorkspace: 'operator_identity_check_required' };
  let instanceId: string | undefined; let workspaceId: string | null = null;
  try {
    const dir = options['--data-dir'] ?? process.env.LEMON_BOT_DATA_DIR;
    if (!dir) throw new Error();
    const db = new Database(join(dir, 'product.sqlite'), { readonly: true, strict: true });
    try {
      const metadata = (key: string) => { const row = db.query('SELECT value FROM metadata WHERE key=?').get(key) as { value: string } | null; return row ? JSON.parse(row.value) : null; };
      const instance = metadata('instanceId'); const workspace = metadata('workspaceId');
      const safe = (value: unknown): value is string => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value);
      if (!safe(instance) || (workspace !== null && !safe(workspace))) throw new Error();
      instanceId = instance; workspaceId = workspace;
      report.baseline = { instanceId, workspaceId, source: 'explicit_readonly_product_database' };
    } finally { db.close(); }
  } catch { report.baseline = 'missing_or_unreadable_explicit_product_database'; }
  let serve = await command(['tailscale', 'serve', 'status', '--json']);
  if (serve.code === -1 && process.platform === 'darwin') serve = await command(['/Applications/Tailscale.app/Contents/MacOS/Tailscale', 'serve', 'status', '--json']);
  let routes: ServeRoute[] = [];
  try { if (serve.code === 0) routes = serveRoutes(JSON.parse(serve.text)); } catch { /* No raw output. */ }
  report.serve = { exitCode: serve.code, routes, note: 'Read-only tailscale serve status; route metadata is not product verification. Lemon Bot defaults to port 4100; port 4080 is normally Lemon Web (Phoenix).' };
  const listener = await command(['lsof', '-nP', '-iTCP', '-sTCP:LISTEN', '-Fpcn']);
  // Only process names/PIDs for relevant ports, never argv/environment.
  const listeners: { pid: number; command: string; port: number }[] = [];
  let pid = 0; let name = '';
  for (const line of listener.text.split('\n')) {
    if (/^p\d+$/.test(line)) pid = Number(line.slice(1));
    if (/^c[a-zA-Z0-9_.-]+$/.test(line)) name = line.slice(1);
    const match = line.match(/^n.*:(\d+)$/);
    if (match && (['bun', 'lemon-bot', 'lemon_bot'].includes(name) || ['4100', '4080', '8448'].includes(match[1]))) listeners.push({ pid, command: name, port: Number(match[1]) });
  }
  report.listeners = { exitCode: listener.code, listeners };
  const xcode = await command(['xcodebuild', '-version']);
  const gen = await command(['xcodegen', '--version']);
  const sdk = await command(['xcrun', '--sdk', 'iphoneos', '--show-sdk-version']);
  const metal = await command(['xcrun', '--find', 'metal']);
  const signing = await command(['security', 'find-identity', '-v', '-p', 'codesigning']);
  report.build = { xcode: xcode.text.match(/Xcode [0-9.]+/)?.[0] ?? 'unavailable', xcodegen: gen.text.match(/[0-9]+\.[0-9]+\.[0-9]+/)?.[0] ?? 'unavailable', deviceSdk: sdk.code === 0 ? sdk.text.trim().match(/^[0-9.]+$/)?.[0] ?? 'unknown' : 'unavailable', metalAvailable: metal.code === 0, signingIdentities: Number(signing.text.match(/(\d+) valid identities found/)?.[1] ?? -1), signingNote: 'Metadata only; no private keys, profiles, devices or installation inspected. Team/profile/entitlement match remains operator-owned.' };
  report.local = await checkOrigin(options['--local-origin'] ?? 'http://127.0.0.1:4100', instanceId ?? 'untrusted-discovery-no-baseline', instanceId ? workspaceId !== null : true, 'same-machine');
  const discoveredServices = [];
  for (const port of new Set(listeners.filter(listener => ['bun', 'lemon-bot', 'lemon_bot'].includes(listener.command)).map(listener => listener.port))) {
    const result = await checkOrigin(`http://127.0.0.1:${port}`, instanceId ?? 'untrusted-discovery-no-baseline', instanceId ? workspaceId !== null : true, 'same-machine');
    discoveredServices.push({ port, ...result });
  }
  report.discoveredLocalServices = discoveredServices;
  const candidates = options['--origin'] ? [options['--origin']] : routes.map(route => route.origin);
  const origins = [];
  for (const candidate of candidates) {
    try {
      const origin = validateBotOrigin(candidate);
      if (!new URL(origin).hostname.endsWith('.ts.net')) throw new Error();
      const probe = await checkOrigin(origin, instanceId ?? 'untrusted-discovery-no-baseline', instanceId ? workspaceId !== null : true, 'phone');
      origins.push({ origin, ...(instanceId ? probe : { status: 'blocked_no_trusted_instance_baseline', unauthenticatedProbe: probe.status }) });
    } catch { origins.push({ status: 'invalid_tailnet_origin' }); }
  }
  report.origins = origins;
  console.log(JSON.stringify(report, null, 2));
  return instanceId && origins.some(origin => origin.status === 'verified_product_api') ? 0 : 1;
}
if (import.meta.main) main().then(code => { process.exitCode = code; }).catch(() => { console.error('Preflight refused: check arguments and system TLS settings. No secret or raw error emitted.'); process.exitCode = 2; });
