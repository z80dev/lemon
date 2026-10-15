import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function canonical(file: string): string {
  const absolute = path.resolve(file);
  try {
    return fs.realpathSync(absolute);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
    const parent = path.dirname(absolute);
    return parent === absolute ? absolute : path.join(canonical(parent), path.basename(absolute));
  }
}

export function validateManagedProfile(userDataDir: string, env: NodeJS.ProcessEnv = process.env): void {
  const home = env.HOME || env.USERPROFILE || os.homedir();
  const roots = [
    path.join(home, 'Library', 'Application Support'),
    path.join(home, '.config'),
    env.XDG_CONFIG_HOME,
    env.LOCALAPPDATA || path.join(home, 'AppData', 'Local'),
  ].filter((root): root is string => !!root);
  const defaults = [
    'Google/Chrome', 'Google/Chrome Beta', 'Google/Chrome Canary', 'Chromium',
    'Microsoft Edge', 'Microsoft Edge Beta', 'BraveSoftware/Brave-Browser',
    'google-chrome', 'google-chrome-beta', 'google-chrome-unstable', 'chromium',
    'microsoft-edge', 'microsoft-edge-beta', 'microsoft-edge-dev',
    'Google/Chrome/User Data', 'Chromium/User Data', 'Microsoft/Edge/User Data',
    'BraveSoftware/Brave-Browser/User Data',
  ];
  const resolved = canonical(userDataDir);
  if (roots.some((root) => defaults.some((dir) => canonical(path.join(root, dir)) === resolved))) {
    throw new Error('Refusing the default browser user-data directory: Chrome 136+ ignores remote debugging on the default data dir. Use the MV3 relay for your real logged-in browser, or copy the profile to a dedicated directory.');
  }

  for (const name of ['SingletonLock', 'SingletonSocket', 'lockfile']) {
    const lock = path.join(resolved, name);
    let stat: fs.Stats;
    try {
      stat = fs.lstatSync(lock);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue;
      throw error;
    }
    // Chromium's SingletonLock is a hostname-pid symlink. Unknown lock formats
    // and remote hosts cannot be proved idle, so leave them untouched and refuse.
    const owner = stat.isSymbolicLink() && name === 'SingletonLock'
      ? /^(.*)-(\d+)$/.exec(fs.readlinkSync(lock)) : null;
    if (owner && owner[1] === os.hostname()) {
      try {
        process.kill(Number(owner[2]), 0);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ESRCH') continue;
      }
    }
    throw new Error('Browser profile is in use (or its lock owner cannot be verified); close Chrome using this profile, or attach via LEMON_BROWSER_CDP_ENDPOINT / relay. Lemon will not remove profile locks.');
  }
}
