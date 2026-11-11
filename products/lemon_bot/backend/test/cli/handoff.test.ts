import { describe, expect, spyOn, test } from 'bun:test';
import { mkdtemp, readFile, rm, stat, symlink, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { detectHeadless, headlessInstructions, openPath, writeHandoffFile } from '../../src/cli/handoff';

describe('private browser handoff', () => {
  test('opener argv contains only the private path and ignores every output stream', async () => {
    const spawn = spyOn(Bun, 'spawn').mockImplementation(() => ({ unref() {} }) as Bun.Subprocess);
    try {
      const path = '/private/mock/handoff/open-lst_random.html';
      expect(await openPath(path)).toBe(true);
      expect(spawn).toHaveBeenCalledWith([process.platform === 'darwin' ? 'open' : 'xdg-open', path], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' });
    } finally { spawn.mockRestore(); }
  });
  test('opener spawn failure is a nonsecret boolean', async () => {
    const spawn = spyOn(Bun, 'spawn').mockImplementation(() => { throw new Error('PRIVATE ERROR'); });
    try { expect(await openPath('/private/mock/handoff/open-lst_random.html')).toBe(false); }
    finally { spawn.mockRestore(); }
  });
  test('0600 exclusive file in 0700 directory; escaped script-free HTML', async () => {
    const root = await mkdtemp(join(tmpdir(), 'bot-handoff-'));
    try {
      const directory = join(root, 'handoff'); const path = join(directory, 'open-lst_test.html');
      const url = 'http://127.0.0.1:4100/#lemonbot-signin=MOCK<&"';
      await writeHandoffFile(path, url);
      expect((await stat(path)).mode & 0o777).toBe(0o600);
      expect((await stat(directory)).mode & 0o777).toBe(0o700);
      const html = await readFile(path, 'utf8');
      expect(html).toContain('MOCK&lt;&amp;&quot;'); expect(html).toContain('http-equiv="refresh"');
      expect(html).toContain('name="referrer" content="no-referrer"'); expect(html).toContain('rel="noreferrer"');
      expect(html).not.toContain('<script');
      await expect(writeHandoffFile(path, 'replacement')).rejects.toThrow();
      expect(await readFile(path, 'utf8')).toBe(html);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
  test('rejects symlink directories and existing symlink files', async () => {
    const root = await mkdtemp(join(tmpdir(), 'bot-handoff-'));
    try {
      await mkdir(join(root, 'real')); await symlink(join(root, 'real'), join(root, 'linked'));
      await expect(writeHandoffFile(join(root, 'linked', 'open-lst_x.html'), 'secret')).rejects.toThrow();
      await symlink(join(root, 'untouched'), join(root, 'real', 'open-lst_x.html'));
      await expect(writeHandoffFile(join(root, 'real', 'open-lst_x.html'), 'secret')).rejects.toThrow();
      expect(await Bun.file(join(root, 'untouched')).exists()).toBe(false);
    } finally { await rm(root, { recursive: true, force: true }); }
  });
  test('headless platform and environment matrix', () => {
    expect(detectHeadless({ SSH_CONNECTION: 'a b c d' }, 'darwin', true)).toBe(true);
    expect(detectHeadless({ SSH_TTY: '/dev/pts/0' }, 'darwin', true)).toBe(true);
    expect(detectHeadless({}, 'linux', true)).toBe(true);
    expect(detectHeadless({ DISPLAY: ':0' }, 'linux', true)).toBe(false);
    expect(detectHeadless({ WAYLAND_DISPLAY: 'wayland-0' }, 'linux', true)).toBe(false);
    expect(detectHeadless({}, 'darwin', false)).toBe(true);
    expect(detectHeadless({}, 'darwin', true)).toBe(false);
  });
  test('tunnel uses server SSH address, exact port, and IPv6 loopback forms', () => {
    expect(headlessInstructions({ origin: 'http://127.0.0.1:4100', url: 'MOCK-URL', env: { SSH_CONNECTION: '192.0.2.1 123 192.0.2.2 22' }, user: 'user', host: 'ignored' })).toContain('ssh -N -L 4100:127.0.0.1:4100 user@192.0.2.2');
    expect(headlessInstructions({ origin: 'http://[::1]:4210', url: 'MOCK-URL', env: {}, user: 'user', host: 'server' })).toContain('ssh -N -L 4210:[::1]:4210 user@server');
  });
});
