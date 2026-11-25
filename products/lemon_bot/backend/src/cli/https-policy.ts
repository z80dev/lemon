import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Machine } from '../../../contracts/protocol';
import { baseBotMcpTemplate } from '../core/bots';
import { localSettings } from '../core/config';
import type { BackendServices } from '../core/services';
import { parseOperatorConfiguration } from '../integrations/config';

export interface HttpsPolicyDependencies {
  env: Record<string, string | undefined>;
  readConfig(path: string): Promise<string>;
  template: typeof baseBotMcpTemplate;
}
export const httpsPolicyDefaults: HttpsPolicyDependencies = {
  env: process.env,
  readConfig: path => readFile(path, 'utf8'),
  template: baseBotMcpTemplate,
};
export interface HttpsPolicy { origin: string; allowedOrigins: string[]; approvedPrivateOrigins: string[] }

/** Canonical credential-free HTTPS origin (scheme, host, optional port); throws on anything else. */
export function httpsOrigin(value: string): string {
  if (value.length > 2048 || /[\u0000-\u0020\u007f]/.test(value)) throw new Error('Invalid origin.');
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash || url.origin.length > 2048) throw new Error('Invalid origin.');
  return url.origin;
}

/**
 * The first-party MCP template a remote execution machine would receive at `requested`, projected to its origins.
 * Needs only the existing operator configuration: no backend startup, key, Store, credential reads or writes.
 * Returns null unless the configured public origin is `requested` and exactly that origin is approved for private MCP.
 */
export async function firstPartyHttpsPolicy(requested: string, deps: HttpsPolicyDependencies = httpsPolicyDefaults): Promise<HttpsPolicy | null> {
  try {
    const origin = httpsOrigin(requested);
    const { dataDir, publicUrl } = localSettings(deps.env);
    const configuredOrigin = httpsOrigin(publicUrl.href);
    if (origin !== configuredOrigin) return null;
    const raw: unknown = JSON.parse(await deps.readConfig(deps.env.LEMON_BOT_CONFIG_FILE ?? join(dataDir, 'config.json')));
    const operator = parseOperatorConfiguration(raw, { firstPartyOrigin: configuredOrigin });
    // The validated HTTPS remote path needs only configuration, never a Store or a real machine/user.
    const services = { config: { publicUrl: configuredOrigin, operator } } as BackendServices;
    const remoteMachine = { nodeId: null, link: { kind: 'direct' } } as Machine;
    const template = deps.template(services, remoteMachine);
    if (template.allowedOrigins?.length !== 1 || template.allowedOrigins[0] !== origin || template.approvedPrivateOrigins?.length !== 1 || template.approvedPrivateOrigins[0] !== origin) return null;
    return { origin, allowedOrigins: template.allowedOrigins, approvedPrivateOrigins: template.approvedPrivateOrigins };
  } catch { return null; }
}
