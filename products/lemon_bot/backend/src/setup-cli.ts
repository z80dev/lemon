import { Database } from 'bun:sqlite';
import { openSync, closeSync, writeSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { preflightBotOrigin, validateBotOrigin } from '../../contracts/preflight';
import { createPrivateCodec, localSettings } from './core/config';
import { createMutationDigest } from './core/mutations';
import { Store } from './core/store';
import { issueOwnerSetupProof } from './core/setup';

interface LocalSetup { origin: string; instanceId: string; configured: boolean; issue(): Promise<{ code: string; expiresAtMs: number }>; close(): void }
interface SetupTerminal { write(value: string): void; close(): void }
/** Trusted injection seams for unit tests only; transports must preserve system TLS and refuse redirects. */
export interface SetupCliDependencies {
  readLocal(): Promise<LocalSetup>;
  openTerminal(): SetupTerminal;
  stdout(value: string): void;
  stderr(value: string): void;
  fetch?: typeof fetch;
}

async function readLocal(): Promise<LocalSetup> {
  const { dataDir, publicUrl } = localSettings();
  const origin = publicUrl.origin;
  // Read-only opening must fail for a missing database; never mint an identity here.
  const db = new Database(join(dataDir, 'product.sqlite'), { readonly: true, strict: true });
  try {
    const metadata = (name: string): unknown => {
      const row = db.query('SELECT value FROM metadata WHERE key=?').get(name) as { value: string } | null;
      return row ? JSON.parse(row.value) as unknown : null;
    };
    const instanceId = metadata('instanceId');
    if (typeof instanceId !== 'string' || !instanceId) throw new Error();
    const configured = !!metadata('workspaceId');
    return { origin, instanceId, configured, close() { db.close(); }, async issue() {
      const key = Buffer.from(process.env.LEMON_BOT_ENCRYPTION_KEY ?? (await readFile(join(dataDir, 'master.key'), 'utf8')).trim(), 'base64');
      if (key.length !== 32) throw new Error();
      const codec = createPrivateCodec(key);
      const sentinel = metadata('encryptionKeyCheck');
      if (typeof sentinel !== 'string' || codec.decrypt(sentinel) !== 'lemon_bot_private_key_v1') throw new Error();
      const store = new Store(join(dataDir, 'product.sqlite'));
      try {
        if (store.metadata('instanceId') !== instanceId) throw new Error();
        const services = { store, now: Date.now, ...codec };
        const mutations = { digest: createMutationDigest(key) };
        return issueOwnerSetupProof({ ...services, mutations });
      } finally { store.close(); }
    } };
  } catch (error) { db.close(); throw error; }
}
const defaults: SetupCliDependencies = {
  readLocal,
  openTerminal() {
    const fd = openSync('/dev/tty', 'w');
    return { write(value) { writeSync(fd, value); }, close() { closeSync(fd); } };
  },
  stdout(value) { process.stdout.write(value); },
  stderr(value) { process.stderr.write(value); },
};

export async function runSetupCli(args: string[], dependencies: SetupCliDependencies = defaults): Promise<number> {
  if (args.some(arg => arg !== '--print-origin' && arg !== '--same-machine') || new Set(args).size !== args.length) {
    dependencies.stderr('Unsupported setup argument. Use lemon-bot --help.\n'); return 2;
  }
  let local: LocalSetup | undefined;
  let terminal: SetupTerminal | undefined;
  try {
    const printOrigin = args.includes('--print-origin');
    const sameMachine = args.includes('--same-machine');
    local = await dependencies.readLocal();
    const origin = validateBotOrigin(local.origin, sameMachine ? 'same-machine' : 'phone');
    const url = new URL(origin);
    if (sameMachine) {
      if (!['127.0.0.1', '[::1]'].includes(url.hostname)) throw new Error();
    } else if (!/^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$/.test(url.hostname)) throw new Error();
    const result = await preflightBotOrigin({ origin, expectedInstanceId: local.instanceId,
      use: sameMachine ? 'same-machine' : 'phone', setup: local.configured ? 'configured' : 'required', fetch: dependencies.fetch });
    if (result.setup.publicUrl !== origin || result.setup.setupRequired === local.configured) throw new Error();
    if (printOrigin) { dependencies.stdout(`${origin}\n`); return 0; }
    if (local.configured) {
      dependencies.stderr('Owner setup is already complete. Existing accounts and pairing are unchanged.\n'); return 1;
    }
    // Refuse before issuance when there is no controlling terminal.
    terminal = dependencies.openTerminal();
    const proof = await local.issue();
    terminal.write(`Sensitive owner setup proof — do not share or record.\nLemon Bot one-use setup code: ${proof.code}\nExpires at ${new Date(proof.expiresAtMs).toISOString()} (at most five minutes; single use).\n${sameMachine ? 'Same-machine development only; this origin is not physical-phone ready.\n' : ''}`);
    dependencies.stdout(`${origin}\n`);
    return 0;
  } catch {
    dependencies.stderr('Owner setup unavailable. Check the local instance configuration, verified origin and controlling terminal.\n');
    return 1;
  } finally {
    try { terminal?.close(); } catch { /* Never expose terminal errors. */ }
    try { local?.close(); } catch { /* Never expose private storage errors. */ }
  }
}
