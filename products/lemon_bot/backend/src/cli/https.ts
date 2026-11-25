import { randomBytes } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { constants } from 'node:fs';
import { access, chmod, lstat, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { basename, dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { baseBotMcpTemplate } from '../core/bots';
import { controllerSettings, isLoopback, localSettings, type ControllerSettings } from '../core/config';
import { createLemonService } from '../runtime/lemon';
import { firstPartyHttpsPolicy, httpsOrigin } from './https-policy';
import { service, spawn, type ServiceResult, type Spawn } from './lifecycle';
import { admissionStatus, readLocalAdmissions, type StatusResult } from './readdress';

/** Controller callback allowlists; the `lemon` launcher sources `~/.lemon/env` whenever it starts the controller. */
const allowlists = ['LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS', 'LEMON_CRON_ADMISSION_ALLOWED_ORIGINS'] as const;
type Allowlist = typeof allowlists[number];
/** Lemon's built-in same-machine admission origin, effective while neither `~/.lemon/env` nor the environment sets a list. */
const lemonDefaultAllowlist = 'http://127.0.0.1:4100';
const usage = 'Usage: lemon-bot https enable --tailscale | --url HTTPS_ORIGIN\n       lemon-bot https status\n       lemon-bot https disable\n';
const manualAppendix = 'docs/getting-started/lemon-bot.md#appendix-manual-https-setup';

export interface HttpsCliDependencies {
  env: Record<string, string | undefined>;
  spawn: Spawn;
  fetch: typeof fetch;
  /** Every address the origin's host resolves to. */
  resolve(host: string): Promise<string[]>;
  /** The running controller's own `bot.admission_origins` verdict for `origin` (shared `doctor.run`). */
  controllerDoctor(origin: string, controller: ControllerSettings, trustedOverlay: boolean): Promise<boolean>;
  executable(path: string): Promise<boolean>;
  exists(path: string): Promise<boolean>;
  botPath: string;
  readLocal: typeof readLocalAdmissions;
  template: typeof baseBotMcpTemplate;
  stdout(value: string): void;
  stderr(value: string): void;
}

/** Ownership receipt in `~/.lemon/bot-https.json`: every setting enable changed, so disable reverts only those. */
interface Receipt {
  schema: 2;
  phase: 'pending' | 'active';
  origin: string;
  mode: 'url' | 'tailscale';
  port: number | null;
  target?: string;
  added: Record<Allowlist, string[]>;
  public_url: { original: string | null; owned: boolean };
  private_mcp: { path: string; added: boolean; field_existed: boolean; file_existed: boolean };
}
type Operation = { kind: 'status' } | { kind: 'disable' } | { kind: 'enable'; mode: 'tailscale' } | { kind: 'enable'; mode: 'url'; origin: string };
interface Report {
  address: string | null;
  phase: 'pending' | 'active' | 'unmanaged';
  tailscale: string;
  allowlists: Record<Allowlist, boolean>;
  controller: 'allowed' | 'not confirmed';
  bots: StatusResult;
  changed?: boolean;
}
interface EnvFile { text: string; values: Partial<Record<Allowlist, string>> }
interface Operator { path: string; raw: Record<string, unknown>; origins: string[]; existed: boolean }
type Routes = Record<string, unknown>;

/** A refusal or failure with an operator-facing explanation. */
class HttpsError extends Error {}
class Locked extends Error {}
/** Tracks whether any setting, route or service actually changed, so a failure is never reported as "nothing changed". */
interface Progress { changed: boolean }
interface Paths { home: string; receipt: string; env: string; lock: string }

function object(value: unknown): Record<string, unknown> | null { return value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null; }
function code(error: unknown): unknown { return error instanceof Error && 'code' in error ? error.code : undefined; }

/** Canonical callback origin: HTTPS, or literal-loopback HTTP; no credentials, path, query or fragment. */
export function admissionOrigin(value: unknown): string | null {
  if (typeof value !== 'string' || !value || value.length > 2048 || /[\s\\\u0000-\u001f\u007f]/.test(value)) return null;
  try {
    const url = new URL(value);
    if (url.username || url.password || url.search || url.hash || url.pathname !== '/') return null;
    if (url.protocol === 'https:') return url.origin;
    return url.protocol === 'http:' && (url.hostname === '127.0.0.1' || url.hostname === '[::1]') ? url.origin : null;
  } catch { return null; }
}
const member = (entries: string[], origin: string | null) => origin !== null && entries.some(entry => admissionOrigin(entry) === origin);

function parse(args: string[]): Operation | 'help' | string {
  if (args.some(arg => arg === '--help' || arg === '-h' || arg === 'help')) return 'help';
  if (args.length === 1 && args[0] === 'status') return { kind: 'status' };
  if (args.length === 1 && args[0] === 'disable') return { kind: 'disable' };
  if (args.length === 2 && args[0] === 'enable' && args[1] === '--tailscale') return { kind: 'enable', mode: 'tailscale' };
  if (args.length === 3 && args[0] === 'enable' && args[1] === '--url') {
    try { return { kind: 'enable', mode: 'url', origin: httpsOrigin(args[2]!) }; }
    catch { return '--url must be an HTTPS origin without credentials, path, query, or fragment.'; }
  }
  return 'Use lemon-bot https enable --tailscale|--url HTTPS_ORIGIN, status, or disable.';
}

function paths(env: Record<string, string | undefined>): Paths {
  const home = env.HOME || homedir();
  return { home, receipt: join(home, '.lemon', 'bot-https.json'), env: join(home, '.lemon', 'env'), lock: join(home, '.lemon', 'run', 'bot-https.lock') };
}

async function readPrivate(path: string, limit: number): Promise<string | null> {
  let info;
  try { info = await lstat(path); } catch (error) { if (code(error) === 'ENOENT') return null; throw error; }
  if (!info.isFile() || info.size > limit) throw new HttpsError('HTTPS settings must be bounded regular files, not links or special files.');
  return readFile(path, 'utf8');
}

async function atomicWrite(path: string, contents: string, mode: number, progress: Progress): Promise<void> {
  if (await readPrivate(path, 4_194_304) === contents) return;
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = join(dirname(path), `.${basename(path)}.${randomBytes(6).toString('hex')}`);
  progress.changed = true;
  try {
    await writeFile(temporary, contents, { mode, flag: 'wx' });
    await chmod(temporary, mode);
    await rename(temporary, path);
  } finally { await rm(temporary, { force: true }); }
}

/** Replaces an existing regular file with its permissions, or creates a private one. */
async function atomicPreserving(path: string, contents: string, progress: Progress): Promise<void> {
  let mode = 0o600;
  try {
    const info = await lstat(path);
    if (!info.isFile()) throw new HttpsError('Refusing to replace a linked or non-regular configuration file.');
    mode = info.mode & 0o7777;
  } catch (error) { if (code(error) !== 'ENOENT') throw error; }
  await atomicWrite(path, contents, mode, progress);
}

const receiptSchema = z.object({
  schema: z.literal(2),
  phase: z.enum(['pending', 'active']),
  origin: z.string(),
  mode: z.enum(['url', 'tailscale']),
  port: z.number().int().min(1).max(65535).nullable().optional(),
  target: z.string().optional(),
  added: z.object({ LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS: z.array(z.string()), LEMON_CRON_ADMISSION_ALLOWED_ORIGINS: z.array(z.string()) }),
  // Receipts written by the former `lemon bot https` may record an empty original.
  public_url: z.object({ original: z.string().nullable().optional().transform(value => value || null), owned: z.boolean() }),
  private_mcp: z.object({ path: z.string(), added: z.boolean(), field_existed: z.boolean(), file_existed: z.boolean() }),
});

function validReceipt(value: unknown, loopback: string): Receipt | null {
  const parsed = receiptSchema.safeParse(value);
  if (!parsed.success) return null;
  const { phase, origin, mode, port, target, added, public_url: publicUrl, private_mcp: privateMcp } = parsed.data;
  let canonical: string;
  try { canonical = httpsOrigin(origin); } catch { return null; }
  if (canonical !== origin || publicUrl.owned !== (publicUrl.original === null)
      || (publicUrl.original !== null && admissionOrigin(publicUrl.original) !== origin)
      || !isAbsolute(privateMcp.path) || !allowlists.every(key => added[key].every(entry => entry === origin))) return null;
  if (mode === 'url') return { schema: 2, phase, origin, mode, port: null, added, public_url: publicUrl, private_mcp: privateMcp };
  if (typeof port !== 'number' || target !== loopback) return null;
  return { schema: 2, phase, origin, mode, port, target, added, public_url: publicUrl, private_mcp: privateMcp };
}

async function readReceipt(path: string, loopback: string): Promise<Receipt | null> {
  const text = await readPrivate(path, 65_536);
  if (text === null) return null;
  let receipt: Receipt | null = null;
  try { receipt = validReceipt(JSON.parse(text), loopback); } catch { /* reported below */ }
  if (!receipt) throw new HttpsError('The HTTPS ownership receipt is invalid; refusing to guess which settings or routes to remove.');
  return receipt;
}

const writeReceipt = (path: string, receipt: Receipt, progress: Progress) => atomicWrite(path, `${JSON.stringify(receipt)}\n`, 0o600, progress);

async function readEnv(path: string): Promise<EnvFile> {
  const text = await readPrivate(path, 1_048_576) ?? '';
  const values: EnvFile['values'] = {};
  for (const key of allowlists) {
    const matches = [...text.matchAll(new RegExp(`^[ \\t]*(?:export[ \\t]+)?${key}=(.*)$`, 'gm'))];
    if (matches.length > 1) throw new HttpsError('Duplicate admission allowlist assignments in ~/.lemon/env; consolidate them before continuing.');
    if (matches.length === 0) continue;
    const raw = matches[0]![1]!.trim();
    const quote = raw[0];
    const value = quote === '\'' || quote === '"' ? raw.length > 1 && raw.endsWith(quote) ? raw.slice(1, -1) : null : raw;
    if (value === null || /[\s'"$`\\\u0000-\u001f]/.test(value)) throw new HttpsError('An admission allowlist in ~/.lemon/env is not a literal comma-separated value; resolve it manually before continuing.');
    values[key] = value;
  }
  return { text, values };
}

function entries(file: EnvFile, key: Allowlist, env: Record<string, string | undefined>): string[] {
  return (file.values[key] ?? env[key] ?? lemonDefaultAllowlist).split(',').map(entry => entry.trim()).filter(Boolean);
}

function replaceEnv(text: string, values: Record<Allowlist, string>): string {
  let result = text;
  for (const key of allowlists) {
    const replacement = `export ${key}='${values[key]}'`;
    const pattern = new RegExp(`^[ \\t]*(?:export[ \\t]+)?${key}=.*$`, 'm');
    if (pattern.test(result)) result = result.replace(pattern, () => replacement);
    else result += `${result === '' || result.endsWith('\n') ? '' : '\n'}${replacement}\n`;
  }
  return result;
}

async function readOperator(path: string): Promise<Operator> {
  const failure = new HttpsError('The existing backend operator configuration cannot be updated safely.');
  if (!isAbsolute(path)) throw failure;
  const text = await readPrivate(path, 1_048_576);
  let raw: Record<string, unknown> | null;
  try { raw = text === null ? { version: 1 } : object(JSON.parse(text)); } catch { throw failure; }
  const origins = raw?.approvedPrivateMcpOrigins ?? [];
  if (!raw || !Array.isArray(origins) || !origins.every(origin => typeof origin === 'string')) throw failure;
  return { path, raw, origins, existed: text !== null };
}

async function commandJson(deps: HttpsCliDependencies, argv: string[]): Promise<Routes> {
  const result = await deps.spawn(argv[0]!, argv.slice(1));
  if (result.exitCode !== 0 || result.stdout.length > 262_144) throw new Error('command failed');
  const value = object(JSON.parse(result.stdout));
  if (!value) throw new Error('invalid output');
  return value;
}
const serveStatus = (deps: HttpsCliDependencies) => commandJson(deps, ['tailscale', 'serve', 'status', '--json']);
const routeKey = (receipt: Pick<Receipt, 'origin' | 'port'>) => `${new URL(receipt.origin).hostname}:${receipt.port}`;
const webKeys = (routes: Routes) => Object.keys(object(routes.Web) ?? {});
function routePortUsed(routes: Routes, port: number): boolean {
  return String(port) in (object(routes.TCP) ?? {}) || webKeys(routes).some(key => key.endsWith(`:${port}`));
}
function routeTarget(routes: Routes, receipt: Receipt): unknown {
  return object(object(object(object(object(routes.Web)?.[routeKey(receipt)])?.Handlers)?.['/']))?.Proxy;
}
function ownedRoute(routes: Routes, receipt: Receipt): boolean {
  const entry = object(object(routes.Web)?.[routeKey(receipt)]);
  const handlers = object(entry?.Handlers);
  return !!entry && Object.keys(entry).length === 1 && !!handlers && Object.keys(handlers).length === 1
    && Object.keys(object(handlers['/']) ?? {}).length === 1 && routeTarget(routes, receipt) === receipt.target
    && webKeys(routes).filter(key => key.endsWith(`:${receipt.port}`)).length === 1;
}

async function tailscaleAddress(deps: HttpsCliDependencies, loopback: string): Promise<Pick<Receipt, 'origin' | 'mode' | 'port' | 'target'>> {
  try {
    const node = await commandJson(deps, ['tailscale', 'status', '--json']);
    const dns = object(node.Self)?.DNSName;
    if (node.BackendState !== 'Running' || typeof dns !== 'string') throw new Error('not connected');
    const host = dns.replace(/\.$/, '').toLowerCase();
    httpsOrigin(`https://${host}`);
    const routes = await serveStatus(deps);
    for (let port = 8443; port <= 8543; port++) {
      if (!routePortUsed(routes, port)) return { origin: httpsOrigin(`https://${host}:${port}`), mode: 'tailscale', port, target: loopback };
    }
  } catch { /* reported below */ }
  throw new HttpsError('Tailscale is missing, signed out, or has no free HTTPS route (8443–8543). Install and sign in to Tailscale, enable HTTPS certificates, then retry.');
}

async function ensureRoute(deps: HttpsCliDependencies, receipt: Receipt, progress: Progress): Promise<void> {
  if (receipt.mode === 'url') return;
  const routes = await serveStatus(deps);
  if (ownedRoute(routes, receipt)) return;
  if (routePortUsed(routes, receipt.port!)) throw new HttpsError('The managed Tailscale port has been changed by another operator; refusing to overwrite it.');
  progress.changed = true;
  const result = await deps.spawn('tailscale', ['serve', '--bg', `--https=${receipt.port}`, receipt.target!]);
  if (result.exitCode !== 0) throw new HttpsError('Tailscale Serve could not be confirmed. Inspect lemon-bot https status; the command does not reset other routes.');
}

async function removeOwnedRoute(deps: HttpsCliDependencies, receipt: Receipt, progress: Progress): Promise<void> {
  if (receipt.mode === 'url') return;
  const routes = await serveStatus(deps);
  if (!routePortUsed(routes, receipt.port!)) return;
  if (!ownedRoute(routes, receipt)) throw new HttpsError('The managed Tailscale route changed; refusing to remove someone else\'s route.');
  progress.changed = true;
  const result = await deps.spawn('tailscale', ['serve', `--https=${receipt.port}`, 'off']);
  if (result.exitCode !== 0) throw new HttpsError('Could not disable the managed Tailscale route. Inspect its status before retrying.');
}

async function getJson(deps: HttpsCliDependencies, url: string): Promise<Record<string, unknown> | null> {
  try {
    const response = await deps.fetch(url, { headers: { Accept: 'application/json' }, redirect: 'manual', credentials: 'omit', cache: 'no-store', signal: AbortSignal.timeout(10_000) });
    if (response.status !== 200) { await response.body?.cancel(); return null; }
    const body = await response.arrayBuffer();
    return body.byteLength > 65_536 ? null : object(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body)));
  } catch { return null; }
}
const setup = (deps: HttpsCliDependencies, origin: string) => getJson(deps, `${origin}/v1/setup`);

/** The controller this backend actually uses must be this machine's; managed HTTPS never configures another controller. */
async function localController(deps: HttpsCliDependencies, dataDir: string): Promise<ControllerSettings> {
  const remote = new HttpsError(`The Bot uses a remote controller. Managed HTTPS cannot configure or verify it; follow ${manualAppendix} on the backend and its actual controller. No settings were changed.`);
  if (!deps.env.LEMON_BOT_CONTROL_URL && !deps.env.LEMON_BOT_OPERATOR_TOKEN) {
    let choice: Record<string, unknown> | null = null;
    try {
      const text = await readPrivate(join(dataDir, 'controller.json'), 65_536);
      choice = text === null ? { version: 1, mode: 'local' } : object(JSON.parse(text));
    } catch { choice = null; }
    if (choice?.mode === 'remote') throw remote;
    if (choice?.version !== 1 || choice.mode !== 'local') throw new HttpsError('The Bot\'s saved controller choice cannot be resolved safely; inspect it with lemon-bot --choose-lemon.');
  }
  let settings: ControllerSettings;
  try { settings = await controllerSettings(deps.env, null); } catch { throw remote; }
  if (!isLoopback(new URL(settings.controlUrl).hostname)) throw remote;
  return settings;
}

async function launcherFor(deps: HttpsCliDependencies, settings: ControllerSettings, home: string): Promise<string> {
  const launcher = settings.runtimeLauncher ?? join(home, '.lemon', 'bin', 'lemon');
  if (deps.env.LEMON_CLI_LAUNCHER === 'source' || await deps.exists(join(dirname(dirname(launcher)), 'mix.exs'))) {
    throw new HttpsError(`Managed HTTPS is not supported by source-mode startup. Follow ${manualAppendix} and configure the source controller's environment explicitly.`);
  }
  if (!await deps.executable(launcher)) throw new HttpsError('Managed HTTPS requires an installed Lemon runtime on this machine. Run lemon-bot up first.');
  return launcher;
}

function ready(result: ServiceResult): boolean {
  return result.exitCode === 0 && !!result.status && result.status.units.length > 0 && result.status.units.every(unit => unit.state === 'ready' || unit.state === 'online');
}

interface Context {
  deps: HttpsCliDependencies; paths: Paths; dataDir: string; port: number; loopback: string; operatorPath: string;
  controller: ControllerSettings; launcher: string; trustedOverlay: boolean; progress: Progress;
}

/** Reinstalls the controller (which re-reads `~/.lemon/env` on restart) and the backend with `publicUrl`, through the Lemon launcher. */
async function configureServices(context: Context, publicUrl: string | null): Promise<void> {
  const { deps, launcher, progress } = context;
  const environment = Object.fromEntries(Object.entries(deps.env).filter(([key]) => key.startsWith('LEMON_BOT_') && key !== 'LEMON_BOT_PUBLIC_URL'));
  if (publicUrl) environment.LEMON_BOT_PUBLIC_URL = publicUrl;
  environment.LEMON_CONTROL_PLANE_PORT = new URL(context.controller.controlUrl).port || '80';
  const stableBot = join(context.paths.home, '.local', 'bin', 'lemon-bot');
  const bot = await deps.executable(stableBot) ? stableBot : deps.botPath;
  const failure = new HttpsError('The controller or Lemon Bot service did not become ready. Run lemon service status; HTTPS ownership is retained for recovery or disable.');
  progress.changed = true;
  if (!ready(await service(launcher, ['install', 'controller', '--wait', '120'], deps.spawn, { environment }))) throw failure;
  try { if ((await deps.spawn(launcher, ['restart'], { environment })).exitCode !== 0) throw failure; } catch { throw failure; }
  if (!ready(await service(launcher, ['install', 'backend', '--bot', bot, '--restart-backend', '--wait', '120'], deps.spawn, { environment }))) throw failure;
}

async function verifyIdentity(context: Context, origin: string): Promise<void> {
  const local = await setup(context.deps, context.loopback);
  const remote = await setup(context.deps, origin);
  if (local?.product !== 'lemon_bot' || typeof local.instanceId !== 'string' || !local.instanceId || remote?.product !== 'lemon_bot' || remote.instanceId !== local.instanceId) {
    throw new HttpsError('The HTTPS address did not serve the same Lemon Bot instance as loopback. Check the proxy target and TLS certificate, then run enable again.');
  }
}

async function verifyRunningPolicy(context: Context, origin: string, approved: boolean): Promise<void> {
  const live = await setup(context.deps, context.loopback);
  if (live?.product !== 'lemon_bot' || admissionOrigin(live.publicUrl) !== origin || live.firstPartyMcpApproved !== approved) {
    throw new HttpsError('The running backend has not loaded the expected public URL and first-party MCP approval. Its HTTPS receipt remains pending; inspect the backend service restart before retrying.');
  }
}

/** Execution refuses unspecified, link-local (cloud metadata) and multicast destinations even for an approved private origin. */
function blockedAddress(address: string): boolean {
  const ipv4 = /^(?:::ffff:)?(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/i.exec(address);
  if (ipv4) { const a = Number(ipv4[1]), b = Number(ipv4[2]); return a === 0 || a === 169 && b === 254 || a >= 224; }
  const lower = address.toLowerCase();
  return lower === '::' || /^fe[89ab]/.test(lower) || lower.startsWith('ff');
}

async function verifyMcpPolicy(context: Context, origin: string): Promise<void> {
  const { deps } = context;
  const policy = await firstPartyHttpsPolicy(origin, { env: { ...deps.env, LEMON_BOT_PUBLIC_URL: origin }, readConfig: path => readFile(path, 'utf8'), template: deps.template });
  let addresses: string[] = [];
  try { addresses = await deps.resolve(new URL(origin).hostname); } catch { addresses = []; }
  if (!policy || addresses.length === 0 || addresses.some(blockedAddress)) {
    throw new HttpsError('The backend\'s first-party MCP policy did not permit execution at this HTTPS origin. Inspect its operator configuration and DNS before retrying.');
  }
}

async function controllerAllows(context: Pick<Context, 'deps' | 'controller' | 'trustedOverlay'>, origin: string): Promise<boolean> {
  try { return await context.deps.controllerDoctor(origin, context.controller, context.trustedOverlay); } catch { return false; }
}

async function approvePrivateMcp(receipt: Receipt, operator: Operator, progress: Progress): Promise<void> {
  if (receipt.private_mcp.path !== operator.path) throw new HttpsError('The backend operator configuration path changed; refusing to modify another file.');
  if (member(operator.origins, receipt.origin)) return;
  await atomicPreserving(operator.path, `${JSON.stringify({ ...operator.raw, approvedPrivateMcpOrigins: [...operator.origins, receipt.origin] })}\n`, progress);
}

async function removePrivateMcp(receipt: Receipt, operator: Operator, progress: Progress): Promise<void> {
  const ownership = receipt.private_mcp;
  if (ownership.path !== operator.path) throw new HttpsError('The backend operator configuration path changed; refusing to modify another file.');
  if (!ownership.added) return;
  const kept = operator.origins.filter(entry => admissionOrigin(entry) !== receipt.origin);
  const raw = { ...operator.raw, approvedPrivateMcpOrigins: kept };
  if (!ownership.field_existed && kept.length === 0) delete (raw as Record<string, unknown>).approvedPrivateMcpOrigins;
  if (!ownership.file_existed && JSON.stringify(raw) === JSON.stringify({ version: 1 })) {
    if (operator.existed) { progress.changed = true; await rm(operator.path); }
    return;
  }
  await atomicPreserving(operator.path, `${JSON.stringify(raw)}\n`, progress);
}

async function resolveContext(deps: HttpsCliDependencies, progress: Progress): Promise<Context> {
  const location = paths(deps.env);
  let settings;
  try { settings = localSettings(deps.env); } catch { throw new HttpsError('The Lemon Bot environment is invalid; check LEMON_BOT_HOST, LEMON_BOT_PORT and LEMON_BOT_PUBLIC_URL.'); }
  if (settings.host !== '127.0.0.1' && settings.host !== 'localhost') throw new HttpsError('Managed HTTPS requires the Bot service to bind 127.0.0.1. Restore its loopback listener before continuing.');
  const controller = await localController(deps, settings.dataDir);
  const launcher = await launcherFor(deps, controller, location.home);
  return {
    deps, paths: location, dataDir: settings.dataDir, port: settings.port, loopback: `http://127.0.0.1:${settings.port}`,
    operatorPath: deps.env.LEMON_BOT_CONFIG_FILE ?? join(settings.dataDir, 'config.json'),
    controller, launcher, trustedOverlay: deps.env.LEMON_BOT_TRUSTED_OVERLAY === 'true', progress,
  };
}

async function enable(deps: HttpsCliDependencies, operation: Extract<Operation, { kind: 'enable' }>, progress: Progress): Promise<Report> {
  const context = await resolveContext(deps, progress);
  const existing = await readReceipt(context.paths.receipt, context.loopback);
  const envFile = await readEnv(context.paths.env);
  const operator = await readOperator(context.operatorPath);
  const address = operation.mode === 'url' ? { origin: operation.origin, mode: 'url' as const, port: null }
    : existing?.mode === 'tailscale' ? { origin: existing.origin, mode: 'tailscale' as const, port: existing.port, target: existing.target }
      : await tailscaleAddress(deps, context.loopback);
  if (existing && (existing.origin !== address.origin || existing.mode !== address.mode || existing.port !== address.port)) {
    throw new HttpsError('Disable the current managed HTTPS address before choosing another address.');
  }
  const live = await setup(deps, context.loopback);
  let plan: Receipt;
  if (existing) plan = { ...existing, phase: 'pending' };
  else {
    if (live?.product !== 'lemon_bot') throw new HttpsError(`Lemon Bot is not answering at ${context.loopback}. Start it with lemon-bot up, then retry.`);
    const configured = [admissionOrigin(live.publicUrl), admissionOrigin(deps.env.LEMON_BOT_PUBLIC_URL)].find(origin => origin?.startsWith('https:')) ?? null;
    if (configured !== null && configured !== address.origin) {
      throw new HttpsError('The Bot service already has another public address. Remove its manual configuration before enabling managed HTTPS.');
    }
    plan = {
      schema: 2, phase: 'pending', ...address,
      added: Object.fromEntries(allowlists.map(key => [key, member(entries(envFile, key, deps.env), address.origin) ? [] : [address.origin]])) as Record<Allowlist, string[]>,
      public_url: { original: configured, owned: configured === null },
      private_mcp: { path: operator.path, added: !member(operator.origins, address.origin), field_existed: 'approvedPrivateMcpOrigins' in operator.raw, file_existed: operator.existed },
    };
  }
  const routeReady = plan.mode === 'url' || ownedRoute(await serveStatus(deps).catch(() => ({})), plan);
  const envText = replaceEnv(envFile.text, Object.fromEntries(allowlists.map(key => {
    const items = entries(envFile, key, deps.env);
    for (const origin of [context.loopback, plan.origin]) if (!member(items, origin)) items.push(origin);
    return [key, items.join(',')];
  })) as Record<Allowlist, string>);
  const same = existing?.phase === 'active' && envText === envFile.text && routeReady
    && admissionOrigin(live?.publicUrl) === plan.origin && member(operator.origins, plan.origin);
  if (!same) await writeReceipt(context.paths.receipt, plan, progress);
  await ensureRoute(deps, plan, progress);
  await atomicPreserving(context.paths.env, envText, progress);
  await approvePrivateMcp(plan, operator, progress);
  if (!same) await configureServices(context, plan.origin);
  await verifyIdentity(context, plan.origin);
  if (!await controllerAllows(context, plan.origin)) {
    throw new HttpsError('The controller has not confirmed both callback allowlists. Run lemon doctor and lemon service status; check environment overrides before retrying.');
  }
  await verifyMcpPolicy(context, plan.origin);
  await verifyRunningPolicy(context, plan.origin, true);
  await writeReceipt(context.paths.receipt, { ...plan, phase: 'active' }, progress);
  return { ...await report(deps), changed: !same };
}

async function disable(deps: HttpsCliDependencies, progress: Progress): Promise<Report> {
  const location = paths(deps.env);
  let loopbackPort = 4100;
  try { loopbackPort = localSettings(deps.env).port; } catch { /* resolveContext reports it */ }
  const receipt = await readReceipt(location.receipt, `http://127.0.0.1:${loopbackPort}`);
  if (!receipt) return { ...await report(deps), changed: false };
  const context = await resolveContext(deps, progress);
  const envFile = await readEnv(context.paths.env);
  const operator = await readOperator(context.operatorPath);
  await removeOwnedRoute(deps, receipt, progress);
  const envText = replaceEnv(envFile.text, Object.fromEntries(allowlists.map(key => {
    const kept = entries(envFile, key, deps.env).filter(entry => !receipt.added[key].includes(admissionOrigin(entry) ?? ''));
    if (!member(kept, context.loopback)) kept.push(context.loopback);
    return [key, kept.join(',')];
  })) as Record<Allowlist, string>);
  await atomicPreserving(context.paths.env, envText, progress);
  await removePrivateMcp(receipt, operator, progress);
  const restored = receipt.public_url.owned ? null : receipt.public_url.original;
  await configureServices(context, restored);
  const expected = restored ?? context.loopback;
  const after = await readOperator(context.operatorPath);
  await verifyRunningPolicy(context, expected, member(after.origins, expected) || expected.startsWith('http:'));
  progress.changed = true;
  await rm(context.paths.receipt);
  return { ...await report(deps), changed: true };
}

/** Read-only: the receipt, allowlists, owned route, controller admission and saved per-Bot admission snapshot. */
async function report(deps: HttpsCliDependencies): Promise<Report> {
  const location = paths(deps.env);
  let port = 4100, dataDir: string | null = null;
  try { const settings = localSettings(deps.env); port = settings.port; dataDir = settings.dataDir; } catch { /* reported as unavailable Bot status */ }
  const loopback = `http://127.0.0.1:${port}`;
  const receipt = await readReceipt(location.receipt, loopback);
  const envFile = await readEnv(location.env);
  const live = receipt ? null : await setup(deps, loopback);
  const address = receipt?.origin ?? (live?.product === 'lemon_bot' ? [admissionOrigin(live.publicUrl)].find(origin => origin?.startsWith('https:')) ?? null : null);
  let tailscale = 'not managed';
  if (receipt?.mode === 'tailscale') {
    try { tailscale = routeTarget(await serveStatus(deps), receipt) === receipt.target ? `${receipt.port} → ${receipt.target}` : 'missing or changed'; }
    catch { tailscale = 'unavailable'; }
  }
  let controller: Report['controller'] = 'not confirmed';
  if (address && dataDir) {
    try {
      const settings = await localController(deps, dataDir);
      if (await controllerAllows({ deps, controller: settings, trustedOverlay: deps.env.LEMON_BOT_TRUSTED_OVERLAY === 'true' }, address)) controller = 'allowed';
    } catch { controller = 'not confirmed'; }
  }
  const botEnv = { ...deps.env };
  if (address) botEnv.LEMON_BOT_PUBLIC_URL = address; else delete botEnv.LEMON_BOT_PUBLIC_URL;
  return {
    address, phase: receipt?.phase ?? 'unmanaged', tailscale, controller,
    allowlists: Object.fromEntries(allowlists.map(key => [key, member(entries(envFile, key, deps.env), address)])) as Record<Allowlist, boolean>,
    bots: admissionStatus(botEnv, deps.readLocal),
  };
}

function render(result: Report, write: (value: string) => void): void {
  const line = (value: string) => write(`${value}\n`);
  line(`Address: ${result.address ?? 'loopback only'} (${result.phase})`);
  line(`Tailscale: ${result.tailscale}`);
  line(`Controller admission: ${result.controller}`);
  for (const key of allowlists) line(`${key}: ${result.allowlists[key] ? 'allowed' : 'not allowed'}`);
  const bots = result.bots.bots.slice(0, 200);
  line('Bots (saved local admission snapshot):');
  for (const bot of bots) line(`Bot ${bot.name} (${bot.id}): ${bot.admissionState}${bot.nextAction === 'update_address' ? ' — Update address' : ''}`);
  const affected = bots.filter(bot => bot.nextAction === 'update_address');
  if (affected.length) {
    line(`ACTION REQUIRED: ${affected.length} listed Bot(s) cannot reply at the new address until their owners update them.`);
    line('For each named Bot above: sign in as its owner → open the Bot → Settings → lifecycle panel → Update address.');
  }
  if (bots.some(bot => bot.nextAction !== 'none' && bot.nextAction !== 'update_address')) {
    line('For interrupted or uncertain work: open the Bot → Settings → lifecycle panel → Check status (or Finish setup when offered). Never repeat an outcome_unknown mutation.');
  }
  if (result.bots.status === 'unavailable') line('Bot admission status unavailable; open Lemon Bot\'s Bots list and inspect Settings → lifecycle panel for each Bot.');
  if (result.bots.truncated) {
    const total = result.bots.totalBots;
    line(`${total !== null && total > bots.length ? total - bots.length : 'Additional'} more Bots may also need Update address; see the Bots list.`);
  }
}

async function acquireLock(path: string): Promise<boolean> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  for (let attempt = 0; attempt < 2; attempt++) {
    try { await writeFile(path, `${process.pid}\n`, { flag: 'wx', mode: 0o600 }); return true; }
    catch (error) {
      if (code(error) !== 'EEXIST') throw error;
      const owner = Number.parseInt(await readFile(path, 'utf8').catch(() => ''), 10);
      if (Number.isSafeInteger(owner) && owner > 0) {
        try { process.kill(owner, 0); return false; } catch (probe) { if (code(probe) === 'EPERM') return false; }
      }
      // The previous owner exited without releasing the lock.
      await rm(path, { force: true });
    }
  }
  return false;
}

async function controllerDoctor(origin: string, controller: ControllerSettings, trustedOverlay: boolean): Promise<boolean> {
  const link = createLemonService({ ...controller, trustedOverlay }, { reconnectMinMs: 60_000 });
  const { promise, resolve } = Promise.withResolvers<boolean>();
  const deadline = setTimeout(() => resolve(false), 10_000);
  const poll = setInterval(() => { if (link.controller.state === 'rejected' || link.controller.state === 'reconnecting') resolve(false); }, 100);
  const removeConnected = link.onConnected(() => resolve(true));
  link.start();
  try {
    if (!await promise) return false;
    const result = object(await link.call('doctor.run', { botPublicUrl: origin }, { timeoutMs: 30_000 }));
    const checks = Array.isArray(result?.checks) ? result.checks : [];
    return result?.botPublicOrigin === origin && checks.some(check => object(check)?.name === 'bot.admission_origins' && object(check)?.status === 'pass');
  } catch { return false; } finally { clearTimeout(deadline); clearInterval(poll); removeConnected(); link.close(); }
}

const sourceBot = fileURLToPath(new URL('../../bin/lemon-bot-source', import.meta.url));
const defaults: HttpsCliDependencies = {
  env: process.env, spawn, fetch,
  resolve: async host => (await lookup(host, { all: true, verbatim: true })).map(entry => entry.address),
  controllerDoctor,
  executable: async path => { try { await access(path, constants.X_OK); return true; } catch { return false; } },
  exists: async path => { try { await access(path); return true; } catch { return false; } },
  botPath: import.meta.path.includes('/$bunfs/') ? process.execPath : sourceBot,
  readLocal: readLocalAdmissions, template: baseBotMcpTemplate,
  stdout: value => { process.stdout.write(value); }, stderr: value => { process.stderr.write(value); },
};

/**
 * `lemon-bot https enable|status|disable`: the Bot's managed HTTPS address, its owned Tailscale route, the controller
 * callback allowlists in `~/.lemon/env` and the backend's first-party private MCP approval. Changes run under one lock and
 * record an ownership receipt first; a failure after any change says so instead of claiming nothing changed.
 */
export async function runHttpsCli(args: string[], deps: HttpsCliDependencies = defaults): Promise<number> {
  const operation = parse(args);
  if (operation === 'help') { deps.stdout(usage); return 0; }
  if (typeof operation === 'string') { deps.stderr(`Error: ${operation}\n${usage}`); return 2; }
  const progress: Progress = { changed: false };
  try {
    let result: Report;
    if (operation.kind === 'status') result = await report(deps);
    else {
      const lock = paths(deps.env).lock;
      if (!await acquireLock(lock)) throw new Locked();
      try { result = operation.kind === 'enable' ? await enable(deps, operation, progress) : await disable(deps, progress); }
      finally { await rm(lock, { force: true }); }
    }
    render(result, deps.stdout);
    return 0;
  } catch (error) {
    if (error instanceof Locked) { deps.stderr('Error: Another lemon-bot https command is changing these settings. No settings were changed.\n'); return 1; }
    deps.stderr(`Error: ${error instanceof HttpsError ? error.message : 'HTTPS settings could not be inspected or changed.'}\n`);
    if (operation.kind !== 'status') {
      deps.stderr(progress.changed
        ? 'Some settings had already changed before this failure; the HTTPS receipt keeps ownership of them. Inspect them with lemon-bot https status, then rerun enable or run disable.\n'
        : 'No settings were changed.\n');
    }
    return 1;
  }
}
