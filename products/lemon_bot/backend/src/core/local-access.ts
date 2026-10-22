import { randomBytes, timingSafeEqual } from 'node:crypto';
import { chmod, rename, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { readManagedToken } from './config';
import { fail } from './errors';

/**
 * Same-OS-user proof for `POST /v1/auth/local`: a private 0600 file beside `master.key`.
 * Whoever can read it can already read this backend's key and database, so it grants
 * nothing that host access does not; the Mac app reads it directly and over SSH.
 */
export const localAccessFile = 'local-access.key';
export const localAccessPath = (dataDir: string): string => join(dataDir, localAccessFile);

/** Keeps a valid existing key; replaces a missing or unsafe one atomically. */
export async function ensureLocalAccessKey(dataDir: string): Promise<void> {
  if ('token' in readManagedToken(localAccessPath(dataDir))) return;
  const temporary = join(dataDir, `.${localAccessFile}.${randomBytes(6).toString('hex')}`);
  await writeFile(temporary, `${randomBytes(32).toString('hex')}\n`, { mode: 0o600, flag: 'wx' });
  await chmod(temporary, 0o600);
  await rename(temporary, localAccessPath(dataDir));
}

/** Re-read per request, so rewriting the file rotates access without a restart. */
export function requireLocalAccess(dataDir: string, request: Request): void {
  const supplied = /^Bearer ([0-9a-fA-F]{64})$/.exec(request.headers.get('authorization') ?? '')?.[1]?.toLowerCase();
  const expected = readManagedToken(localAccessPath(dataDir));
  if (!supplied || !('token' in expected) || !timingSafeEqual(Buffer.from(supplied), Buffer.from(expected.token.toLowerCase()))) {
    fail('unauthenticated', 'Local access needs this machine\'s private Lemon Bot key.');
  }
}
