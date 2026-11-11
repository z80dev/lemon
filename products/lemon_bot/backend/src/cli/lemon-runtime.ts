import type { BackendConfiguration } from '../core/services';
import { controllerSettings, isLoopback, readControllerChoice, saveControllerChoice, validateControlUrl, type ControllerChoice, type ControllerSource, type PrivateCodec } from '../core/config';
import { createLemonService } from '../runtime/lemon';
import type { ConnectTerminal } from './connect';

export interface ControllerPreparation {
  terminal: ConnectTerminal;
  environment: Record<string, string | undefined>;
  /** Updated in place with the chosen controller before the backend is created. */
  config: BackendConfiguration;
  codec: PrivateCodec;
  source: ControllerSource;
  /** `--choose-lemon`: show the choice even when one is saved. */
  choose: boolean;
  fetch?: typeof fetch;
  /** Checks a remote controller and returns a problem, or null once it accepts the token; test seam. */
  verify?: (controlUrl: string, operatorToken: string, trustedOverlay: boolean) => Promise<string | null>;
}

/** Health as the Lemon launchers judge it: the control plane's documented `"ok": true` body, not just any 200. */
export async function localLemonRunning(controlUrl: string, fetcher: typeof fetch = fetch): Promise<boolean> {
  const url = new URL(controlUrl);
  if (!isLoopback(url.hostname)) return false;
  try {
    const response = await fetcher(`${url.protocol === 'wss:' ? 'https' : 'http'}://${url.host}/healthz`, { redirect: 'manual', signal: AbortSignal.timeout(1500) });
    if (!response.ok) return false;
    const body: unknown = await response.json();
    return typeof body === 'object' && body !== null && 'ok' in body && body.ok === true;
  } catch { return false; }
}

async function verifyController(controlUrl: string, operatorToken: string, trustedOverlay: boolean): Promise<string | null> {
  // A long reconnect delay turns the first failure into a stable answer instead of a retry loop.
  const link = createLemonService({ controlUrl, operatorToken, trustedOverlay }, { reconnectMinMs: 60_000 });
  const { promise, resolve } = Promise.withResolvers<string | null>();
  const deadline = setTimeout(() => resolve(link.controller.lastError?.message ?? 'The controller did not answer in time.'), 10_000);
  const poll = setInterval(() => {
    if (link.controller.state === 'rejected' || link.controller.state === 'reconnecting') resolve(link.controller.lastError?.message ?? 'The controller refused the connection.');
  }, 100);
  const removeConnected = link.onConnected(() => resolve(null));
  link.start();
  try { return await promise; } finally { clearTimeout(deadline); clearInterval(poll); removeConnected(); link.close(); }
}

const yes = (answer: string, fallback: boolean) => answer ? ['y', 'yes'].includes(answer.trim().toLowerCase()) : fallback;

async function askRemote(input: ControllerPreparation): Promise<ControllerChoice | null> {
  const { terminal: io, config } = input;
  const verify = input.verify ?? verifyController;
  for (let attempt = 0; attempt < 3; attempt++) {
    const address = (await io.read('Lemon controller address (wss://host/ws): ')).trim();
    let url: URL;
    try { url = validateControlUrl(address, config.trustedOverlay); } catch (error) { io.write(error instanceof Error ? error.message : 'That address is not valid.'); continue; }
    const token = (await io.read('Operator token (hidden; on that machine: cat ~/.lemon/run/control-plane-4040.token): ', true)).trim();
    if (!token) { io.write('An operator token is required.'); continue; }
    io.write('Checking the connection…');
    const problem = await verify(url.href, token, config.trustedOverlay);
    if (!problem) { io.write(`Connected to Lemon at ${url.href}.`); return { mode: 'remote', url: url.href, token }; }
    io.write(`Could not connect: ${problem}`);
    if (yes(await io.read('Save this Lemon anyway and keep retrying in the background? [y/N] '), false)) return { mode: 'remote', url: url.href, token };
  }
  return null;
}

/**
 * Interactive startup: choose this machine's Lemon or another machine's, save the choice in private DATA_DIR,
 * without starting processes; `lemon-bot up` owns setup and supervision.
 */
export async function prepareController(input: ControllerPreparation): Promise<void> {
  const { terminal: io, environment, config, codec, source } = input;
  const fetcher = input.fetch ?? fetch;
  if (source === 'environment') {
    if (input.choose) io.write('LEMON_BOT_CONTROL_URL or LEMON_BOT_OPERATOR_TOKEN is set, so Lemon Bot uses the environment. Unset them to choose here.');
    return;
  }
  const saved = source === 'saved' ? await readControllerChoice(config.dataDir, codec) : null;
  if (saved && !input.choose) {
    io.write(saved.mode === 'local' ? `Using Lemon on this machine (${config.controlUrl}).` : `Using Lemon at ${config.controlUrl}.`);
    io.write('To switch between this machine and another machine, run lemon-bot --choose-lemon.');
    return;
  }
  const local = await controllerSettings(environment, { mode: 'local' });
  const running = await localLemonRunning(local.controlUrl, fetcher);
  io.write(`Which Lemon should Lemon Bot use?\n  1) This machine (${running ? 'running' : local.runtimeLauncher ? 'installed, not running' : 'not installed'})\n  2) Another machine (needs its controller address and operator token)`);
  const fallback = saved?.mode === 'remote' ? '2' : '1';
  for (;;) {
    const answer = (await io.read(`Choose 1 or 2 [${fallback}]: `)).trim() || fallback;
    if (answer === '1') {
      await saveControllerChoice(config.dataDir, codec, { mode: 'local' });
      Object.assign(config, local);
      return;
    }
    if (answer === '2') {
      const remote = await askRemote(input);
      if (!remote) continue;
      await saveControllerChoice(config.dataDir, codec, remote);
      Object.assign(config, await controllerSettings(environment, remote));
      return;
    }
    io.write('Enter 1 or 2.');
  }
}
