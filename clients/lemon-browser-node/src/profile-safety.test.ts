import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { ChromeSession } from './chrome.js';
import { validateManagedProfile } from './profile-safety.js';
import { resolveLocalDriverConfig } from './local-driver.js';
import { parseCliArgs } from './cli-args.js';

vi.mock('node:child_process', () => ({ spawn: vi.fn(() => ({ kill: vi.fn() })) }));

let home: string;
let profile: string;
beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-profile-safety-'));
  profile = path.join(home, 'dedicated');
  vi.stubEnv('HOME', home);
  vi.stubEnv('XDG_CONFIG_HOME', path.join(home, '.config'));
  vi.stubEnv('LOCALAPPDATA', path.join(home, 'AppData', 'Local'));
  vi.clearAllMocks();
});
afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  fs.rmSync(home, { recursive: true, force: true });
});

function session(profileDirectory?: string) {
  // Exercise the private launch seam without starting Chrome/CDP.
  const chrome = new ChromeSession({
    cdpPort: 19999, userDataDir: profile, profileDirectory,
    executablePath: '/fake/chrome', headless: false, noSandbox: false, attachOnly: false,
  });
  return chrome as unknown as {
    launchChrome(): Promise<void>;
    stop(): Promise<void>;
    browser: { close(): Promise<void> };
    ownedBrowser: boolean;
  };
}

describe('managed user profiles', () => {
  it('keeps default configuration and accepts env and argument overrides', () => {
    const defaults = resolveLocalDriverConfig({ args: {}, env: { HOME: home, OPENCLAW_STATE_DIR: home } });
    expect(defaults.profileDirectory).toBeUndefined();
    expect(defaults.userProvidedProfile).toBe(false);
    const env = { LEMON_BROWSER_USER_DATA_DIR: profile, LEMON_BROWSER_PROFILE_DIRECTORY: 'Profile 1' };
    expect(resolveLocalDriverConfig({ args: {}, env })).toMatchObject({ userDataDir: profile, profileDirectory: 'Profile 1', userProvidedProfile: true });
    expect(resolveLocalDriverConfig({ args: parseCliArgs(['--profile-directory', 'Default']), env }).profileDirectory).toBe('Default');
  });

  it('refuses an occupied managed CDP port instead of silently attaching another profile', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: true }));
    const chrome = new ChromeSession({
      cdpPort: 19999, userDataDir: profile, userProvidedProfile: true,
      headless: false, noSandbox: false, attachOnly: false,
    });
    await expect(chrome.start()).rejects.toThrow('cannot verify the requested browser profile');
    expect(spawn).not.toHaveBeenCalled();
  });

  it('preserves launch arguments when unset and adds the selected profile flag', async () => {
    await session().launchChrome();
    const defaultArgs = vi.mocked(spawn).mock.calls[0][1] as string[];
    expect(defaultArgs).toContain(`--user-data-dir=${profile}`);
    expect(defaultArgs.some((arg) => arg.startsWith('--profile-directory'))).toBe(false);
    await session('Profile 1').launchChrome();
    const selectedArgs = vi.mocked(spawn).mock.calls[1][1] as string[];
    expect(selectedArgs.filter((arg) => !arg.startsWith('--profile-directory='))).toEqual(defaultArgs);
    expect(selectedArgs).toContain('--profile-directory=Profile 1');
  });

  it.each([
    'Library/Application Support/Google/Chrome', 'Library/Application Support/Chromium',
    'Library/Application Support/Microsoft Edge', 'Library/Application Support/BraveSoftware/Brave-Browser',
    '.config/google-chrome', '.config/chromium', '.config/microsoft-edge', '.config/BraveSoftware/Brave-Browser',
    'AppData/Local/Google/Chrome/User Data',
  ])('refuses default directory %s without touching it', async (relative) => {
    profile = path.join(home, relative);
    await expect(session().launchChrome()).rejects.toThrow('Chrome 136+');
    expect(spawn).not.toHaveBeenCalled();
    expect(fs.existsSync(profile)).toBe(false);
  });

  it('refuses symlink aliases of default directories', () => {
    const original = path.join(home, '.config', 'google-chrome');
    fs.mkdirSync(original, { recursive: true });
    fs.symlinkSync(original, profile);
    expect(() => validateManagedProfile(profile)).toThrow('MV3 relay');
  });

  it.each(['SingletonLock', 'SingletonSocket', 'lockfile'])('refuses a live or unverifiable %s without removing it', async (lock) => {
    fs.mkdirSync(profile);
    const file = path.join(profile, lock);
    if (lock === 'SingletonLock') fs.symlinkSync(`${os.hostname()}-${process.pid}`, file);
    else fs.writeFileSync(file, String(process.pid));
    await expect(session().launchChrome()).rejects.toThrow('close Chrome using this profile');
    expect(fs.lstatSync(file)).toBeDefined();
    expect(spawn).not.toHaveBeenCalled();
  });

  it('stopping closes only the owned browser and leaves profile files unchanged', async () => {
    fs.mkdirSync(profile);
    const cookie = path.join(profile, 'Cookies');
    fs.writeFileSync(cookie, 'signed-in fixture');
    const chrome = session('Default');
    const close = vi.fn().mockResolvedValue(undefined);
    chrome.browser = { close };
    chrome.ownedBrowser = true;
    await chrome.stop();
    expect(close).toHaveBeenCalledOnce();
    expect(fs.readFileSync(cookie, 'utf8')).toBe('signed-in fixture');
  });
});
