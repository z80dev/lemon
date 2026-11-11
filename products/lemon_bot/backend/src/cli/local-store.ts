import { Database } from 'bun:sqlite';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createPrivateCodec, type PrivateCodec } from '../core/config';
import { Store } from '../core/store';

/** Read-only: a CLI must never create a new instance identity. */
export function readInstanceId(dataDir: string): { instanceId: string; configured: boolean } {
  const db = new Database(join(dataDir, 'product.sqlite'), { readonly: true, strict: true });
  try {
    const metadata = (name: string): unknown => {
      const row = db.query('SELECT value FROM metadata WHERE key=?').get(name) as { value: string } | null;
      return row ? JSON.parse(row.value) : null;
    };
    const instanceId = metadata('instanceId');
    if (typeof instanceId !== 'string' || !instanceId) throw new Error('Missing instance identity');
    return { instanceId, configured: !!metadata('workspaceId') };
  } finally { db.close(); }
}

export interface PrivateLocalStore extends PrivateCodec { store: Store; key: Uint8Array }
export async function openPrivateStore(dataDir: string, instanceId: string, environment: Record<string, string | undefined> = process.env): Promise<PrivateLocalStore> {
  const key = Buffer.from(environment.LEMON_BOT_ENCRYPTION_KEY ?? (await readFile(join(dataDir, 'master.key'), 'utf8')).trim(), 'base64');
  if (key.length !== 32) throw new Error('Invalid private key');
  const codec = createPrivateCodec(key);
  const db = new Database(join(dataDir, 'product.sqlite'), { readonly: true, strict: true });
  try {
    const row = db.query('SELECT value FROM metadata WHERE key=?').get('encryptionKeyCheck') as { value: string } | null;
    const sentinel: unknown = row ? JSON.parse(row.value) : null;
    if (typeof sentinel !== 'string' || codec.decrypt(sentinel) !== 'lemon_bot_private_key_v1') throw new Error('Invalid private key');
  } finally { db.close(); }
  const store = new Store(join(dataDir, 'product.sqlite'));
  try {
    if (store.metadata('instanceId') !== instanceId) throw new Error('Instance changed');
    return { store, key, ...codec };
  } catch (error) { store.close(); throw error; }
}
