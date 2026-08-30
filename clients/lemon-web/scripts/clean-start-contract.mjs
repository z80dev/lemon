import { spawn, spawnSync } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { createServer } from 'node:net';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptsDir = dirname(fileURLToPath(import.meta.url));
const clientRoot = resolve(scriptsDir, '..');
const repoRoot = resolve(clientRoot, '..', '..');
const sharedDist = join(clientRoot, 'shared', 'dist');
const serverDist = join(clientRoot, 'server', 'dist');
const sharedEntrypoint = join(sharedDist, 'index.js');
const serverEntrypoint = join(serverDist, 'index.js');
const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm';

function cleanGeneratedEntrypoints() {
  rmSync(sharedDist, { recursive: true, force: true });
  rmSync(serverDist, { recursive: true, force: true });
}

function runNpm(args) {
  const result = spawnSync(npmCommand, args, {
    cwd: clientRoot,
    stdio: 'inherit',
    env: process.env,
  });

  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${npmCommand} ${args.join(' ')} exited with status ${result.status}`);
  }
}

function assertGenerated(path, command) {
  if (!existsSync(path)) {
    throw new Error(`${command} did not generate ${path}`);
  }
}

async function reservePort() {
  const probe = createServer();

  await new Promise((resolveListen, rejectListen) => {
    probe.once('error', rejectListen);
    probe.listen(0, '127.0.0.1', resolveListen);
  });

  const address = probe.address();
  const port = typeof address === 'object' && address ? address.port : null;

  await new Promise((resolveClose, rejectClose) => {
    probe.close((error) => (error ? rejectClose(error) : resolveClose()));
  });

  if (port === null) throw new Error('Could not reserve a loopback port');
  return port;
}

async function waitForServer(child, port) {
  const deadline = Date.now() + 15_000;
  let lastError = null;

  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`npm start exited before readiness with status ${child.exitCode}`);
    }

    try {
      const response = await fetch(`http://127.0.0.1:${port}`);
      if (response.ok && (await response.text()).length > 0) return;
    } catch (error) {
      lastError = error;
    }

    await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  }

  throw new Error(`npm start did not become ready: ${String(lastError)}`);
}

async function stopChild(child) {
  if (child.exitCode !== null) return;

  const signal = (name) => {
    if (process.platform === 'win32') {
      child.kill(name);
      return;
    }

    try {
      process.kill(-child.pid, name);
    } catch (error) {
      if (error?.code !== 'ESRCH') throw error;
    }
  };

  signal('SIGTERM');

  await Promise.race([
    new Promise((resolveClose) => child.once('close', resolveClose)),
    new Promise((resolveTimeout) => setTimeout(resolveTimeout, 5_000)),
  ]);

  if (child.exitCode === null) signal('SIGKILL');
}

cleanGeneratedEntrypoints();
runNpm(['run', 'predev']);
assertGenerated(sharedEntrypoint, 'npm run predev');

cleanGeneratedEntrypoints();

const port = await reservePort();
const child = spawn(npmCommand, ['start', '--', '--port', String(port), '--no-ui', '--lemon-path', repoRoot], {
  cwd: clientRoot,
  stdio: 'inherit',
  env: process.env,
  detached: process.platform !== 'win32',
});

try {
  await waitForServer(child, port);
  assertGenerated(sharedEntrypoint, 'npm start');
  assertGenerated(serverEntrypoint, 'npm start');
} finally {
  await stopChild(child);
}

console.log('Clean-artifact dev/start contract passed.');
