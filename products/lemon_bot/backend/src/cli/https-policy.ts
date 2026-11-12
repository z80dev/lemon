import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Machine } from '../../../contracts/protocol';
import { baseBotMcpTemplate } from '../core/bots';
import { localSettings } from '../core/config';
import type { BackendServices } from '../core/services';
import { parseOperatorConfiguration } from '../integrations/config';

export interface HttpsPolicyCliDependencies {
  env: Record<string, string | undefined>;
  readConfig(path: string): Promise<string>;
  template: typeof baseBotMcpTemplate;
  stdout(value: string): void;
  stderr(value: string): void;
}
const defaults: HttpsPolicyCliDependencies = {
  env: process.env,
  readConfig: path => readFile(path, 'utf8'),
  template: baseBotMcpTemplate,
  stdout: value => { process.stdout.write(value); },
  stderr: value => { process.stderr.write(value); },
};

function httpsOrigin(value: string): string {
  if (value.length > 2048 || /[\u0000-\u0020\u007f]/.test(value)) throw new Error('Invalid origin.');
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash || url.origin.length > 2048) throw new Error('Invalid origin.');
  return url.origin;
}

/** Internal argv-only policy projection: no backend startup, key, Store, credential reads or writes. */
export async function runHttpsPolicyCli(args: string[], deps: HttpsPolicyCliDependencies = defaults): Promise<number> {
  let requested: string | undefined; let json = false;
  for (let index = 0; index < args.length; index++) {
    const arg = args[index];
    if (arg === '--origin' && requested === undefined && args[index + 1] && !args[index + 1]!.startsWith('--')) requested = args[++index];
    else if (arg === '--json' && !json) json = true;
    else {
      deps.stderr('Usage: lemon-bot https-policy --origin HTTPS_ORIGIN --json\n');
      return 2;
    }
  }
  if (!requested || !json) {
    deps.stderr('Usage: lemon-bot https-policy --origin HTTPS_ORIGIN --json\n');
    return 2;
  }
  try {
    const origin = httpsOrigin(requested);
    const { dataDir, publicUrl } = localSettings(deps.env);
    const configuredOrigin = httpsOrigin(publicUrl.href);
    if (origin !== configuredOrigin) throw new Error('Origin mismatch.');
    const raw: unknown = JSON.parse(await deps.readConfig(deps.env.LEMON_BOT_CONFIG_FILE ?? join(dataDir, 'config.json')));
    const operator = parseOperatorConfiguration(raw, { firstPartyOrigin: configuredOrigin });
    // The validated HTTPS remote path needs only configuration, never a Store or a real machine/user.
    const services = { config: { publicUrl: configuredOrigin, operator } } as BackendServices;
    const remoteMachine = { nodeId: null, link: { kind: 'direct' } } as Machine;
    const template = deps.template(services, remoteMachine);
    if (template.allowedOrigins?.length !== 1 || template.allowedOrigins[0] !== origin || template.approvedPrivateOrigins?.length !== 1 || template.approvedPrivateOrigins[0] !== origin) throw new Error('Origin is not explicitly approved.');
    deps.stdout(`${JSON.stringify({ origin, allowedOrigins: template.allowedOrigins, approvedPrivateOrigins: template.approvedPrivateOrigins })}\n`);
    return 0;
  } catch {
    deps.stderr('HTTPS policy unavailable: require an existing valid operator configuration, a matching public HTTPS origin and explicit private MCP approval.\n');
    return 1;
  }
}
