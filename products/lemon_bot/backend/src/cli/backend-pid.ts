import { chmodSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { productVersion } from '../core/version';

/** Written only after listen, so lifecycle takeover can bind a PID to this exact instance. */
export function recordBackendPid(dataDir: string, port: number, instanceId: string): () => void {
  const processInfo = Bun.spawnSync(['ps', '-o', 'lstart=', '-p', String(process.pid)], { stdout: 'pipe', stderr: 'ignore', env: { ...process.env, LC_ALL: 'C' } });
  const startedAt = processInfo.stdout.toString().trim();
  if (processInfo.exitCode !== 0 || !startedAt) throw new Error('Backend process identity is unavailable.');
  const directory = join(dataDir, 'run');
  mkdirSync(directory, { recursive: true, mode: 0o700 }); chmodSync(directory, 0o700);
  const path = join(directory, `lemon-bot-${port}.json`);
  const temporary = `${path}.${randomUUID()}`;
  const content = JSON.stringify({ pid: process.pid, startedAt, port, instanceId, version: productVersion });
  try { writeFileSync(temporary, content, { mode: 0o600, flag: 'wx' }); renameSync(temporary, path); }
  finally { try { unlinkSync(temporary); } catch (error) { if (!(error instanceof Error && 'code' in error && error.code === 'ENOENT')) throw error; } }
  return () => {
    try { if (readFileSync(path, 'utf8') === content) unlinkSync(path); }
    catch (error) { if (!(error instanceof Error && 'code' in error && error.code === 'ENOENT')) throw error; }
  };
}
