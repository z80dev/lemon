import { chmod, lstat, mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

type Environment = Record<string, string | undefined>;
export function detectHeadless(env: Environment, platform: string, openerAvailable: boolean): boolean {
  return !!(env.SSH_CONNECTION || env.SSH_TTY) || (platform === 'linux' && !env.DISPLAY && !env.WAYLAND_DISPLAY) || !openerAvailable;
}
const escapeHtml = (value: string) => value.replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!);
export async function writeHandoffFile(path: string, url: string): Promise<void> {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const info = await lstat(directory);
  if (!info.isDirectory() || info.isSymbolicLink() || (process.getuid && info.uid !== process.getuid())) throw new Error('Unsafe handoff directory');
  await chmod(directory, 0o700);
  const escaped = escapeHtml(url);
  await writeFile(path, `<!doctype html><meta name="referrer" content="no-referrer"><meta http-equiv="refresh" content="0;url=${escaped}"><title>Opening Lemon Bot…</title><a rel="noreferrer" href="${escaped}">Open Lemon Bot</a>\n`, { mode: 0o600, flag: 'wx' });
  await chmod(path, 0o600);
}
export function browserOpener(platform: string): string | null {
  return platform === 'darwin' ? 'open' : platform === 'linux' ? 'xdg-open' : null;
}
export async function openPath(path: string): Promise<boolean> {
  const opener = browserOpener(process.platform);
  if (!opener) return false;
  try {
    const child = Bun.spawn([opener, path], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
    // Some Linux openers remain alive with the browser. Delivery waits on the
    // ticket, not on that process; a later opener failure gets the 15-second hint.
    child.unref();
    return true;
  } catch { return false; }
}
function shellWord(value: string): string { return /^[A-Za-z0-9_.@:[\]-]+$/.test(value) ? value : `'${value.replace(/'/g, "'\\''")}'`; }
export function headlessInstructions({ origin, url, env, user, host }: { origin: string; url: string; env: Environment; user: string; host: string }): string {
  const parsed = new URL(origin);
  const port = parsed.port || '80';
  const server = env.SSH_CONNECTION?.trim().split(/\s+/)[2] || host;
  return `Sign in to Lemon Bot from your own computer (this link works once, for 5 minutes):\n  1. On your computer run:  ssh -N -L ${port}:${parsed.hostname}:${port} ${shellWord(`${user}@${server}`)}\n  2. Then open:             ${url}\nPort ${port} must be free on your computer. New link: lemon-bot open --headless\n`;
}
