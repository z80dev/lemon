import { openSync, closeSync, writeSync } from 'node:fs';
import { preflightBotOrigin, validateBotOrigin } from '../../contracts/preflight';
import { localSettings } from './core/config';
import { openPrivateStore, readInstanceId } from './cli/local-store';
import { createMutationDigest } from './core/mutations';
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
  const { instanceId, configured } = readInstanceId(dataDir);
  return { origin, instanceId, configured, close() {}, async issue() {
    const { store, key, encrypt, decrypt } = await openPrivateStore(dataDir, instanceId);
    try {
      return issueOwnerSetupProof({ store, now: Date.now, encrypt, decrypt, mutations: { digest: createMutationDigest(key) } });
    } finally { store.close(); }
  } };
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
