import os from 'node:os';
import path from 'node:path';

export function resolveOpenClawStateDir(env: NodeJS.ProcessEnv = process.env): string {
  const override = (env.OPENCLAW_STATE_DIR || env.CLAWDBOT_STATE_DIR || '').trim();
  if (override) return expandUser(override);
  return path.join(os.homedir(), '.openclaw');
}

export function resolveOpenClawUserDataDir(profileName = 'openclaw', env: NodeJS.ProcessEnv = process.env): string {
  const base = resolveOpenClawStateDir(env);
  return path.join(base, 'browser', profileName, 'user-data');
}

function expandUser(p: string): string {
  if (!p) return p;
  if (p.startsWith('~')) return path.resolve(p.replace(/^~(?=$|[\\/])/, os.homedir()));
  return path.resolve(p);
}

