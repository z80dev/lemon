import { productVersion as version } from './core/version';
// One import per module: Bun 1.4.2 --compile emits an undefined `__promiseAll` helper
// when the same lazily initialized module is imported twice from an entry point.
import { runConnect, terminal } from './cli/connect';
import { foregroundStartup } from './cli/startup';
import { homedir } from 'node:os';
import { join } from 'node:path';

const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--version') {
  process.stdout.write(`lemon-bot ${version}\n`);
} else if (args.length === 1 && (args[0] === '--help' || args[0] === '-h')) {
  process.stdout.write(`Lemon Bot ${version}
Usage: lemon-bot [--choose-lemon] [--no-open] | --version | --help
       lemon-bot up [--json] [--no-open] [--no-worker] [--this-machine] [--name NAME] [--worker-wrapper PATH]
       lemon-bot open [--headless] [--no-wait]
       lemon-bot setup [--print-origin] [--same-machine]
       lemon-bot connect iphone --backend ORIGIN [--origin HTTPS_ORIGIN]

In a terminal, plain lemon-bot sets up background services, enrolls this machine,
opens the web app already signed in (see open), and exits. --choose-lemon asks
which controller to use again. The saved controller choice is encrypted privately.
up is resumable; --json emits NDJSON step events and one result, never credentials.
--this-machine uses this machine's Lemon without asking when no choice is saved
(lemon setup passes it after you choose Browser).
--no-worker leaves worker enrollment to a later up. --no-open skips browser sign-in.
Without a terminal, with --no-open, or in service mode, plain lemon-bot serves
the authenticated backend in the foreground at http://127.0.0.1:4100.
Private state defaults to ~/.lemon/lemon_bot.

open signs this computer's browser in as the workspace owner with a one-use link
(no password). It creates the owner on first use. --headless prints the link and
an ssh -L command on the terminal for use from another computer.

setup verifies the existing DATA_DIR instance at the configured HTTPS *.ts.net
origin. It never starts services or checks providers; it prints the verified
origin to stdout and an unconfigured owner's five-minute proof to /dev/tty only.
--print-origin is read-only. --same-machine permits literal loopback for local
development/release smoke, not physical-phone readiness.
Environment: LEMON_BOT_CONTROL_URL, LEMON_BOT_OPERATOR_TOKEN, LEMON_BOT_PUBLIC_URL,
LEMON_BOT_DATA_DIR, LEMON_BOT_HOST, LEMON_BOT_PORT, LEMON_BOT_RUNTIME_LAUNCHER.
Never share the controller operator token with clients.
`);
} else if (args[0] === 'up') {
  const { runUpCli } = await import('./cli/up');
  process.exitCode = await runUpCli(args.slice(1));
} else if (args[0] === 'open') {
  // Keep platform/private-storage modules out of help and version dispatch.
  const { runOpenCli } = await import('./cli/open');
  process.exitCode = await runOpenCli(args.slice(1));
} else if (args[0] === 'setup') {
  // Private-state and platform imports must remain lazy for help/version.
  const { runSetupCli } = await import('./setup-cli');
  process.exitCode = await runSetupCli(args.slice(1));
} else if (args[0] === 'connect') {
  process.exitCode = await runConnect(args.slice(1));
} else if (args.some(arg => arg !== '--choose-lemon' && arg !== '--no-open') || new Set(args).size !== args.length) {
  process.stderr.write('Unsupported argument. Use lemon-bot --help.\n');
  process.exitCode = 2;
} else if (!foregroundStartup(args, terminal().interactive, process.env.LEMON_SERVICE_ROLE)) {
  const launcher = process.env.LEMON_BOT_RUNTIME_LAUNCHER ?? join(process.env.HOME || homedir(), '.lemon/bin/lemon');
  if (await Bun.file(launcher).exists()) {
    // The bootstrap imports private configuration; help/version must not load it.
    const { runUpCli } = await import('./cli/up');
    process.exitCode = await runUpCli([], undefined, { chooseLemon: args.includes('--choose-lemon') });
  } else {
    process.stderr.write(`No runtime CLI: serving Lemon Bot in the foreground without persistent services.\nInstall background setup with: curl -fsSL https://github.com/z80dev/lemon/releases/download/v${version}/install.sh | sh -s -- --profile bot\n`);
    const { runBackend } = await import('./index');
    await runBackend({ chooseLemon: args.includes('--choose-lemon') });
  }
} else {
  // Native/private imports stay behind command dispatch.
  const { runBackend } = await import('./index');
  await runBackend({ chooseLemon: args.includes('--choose-lemon'), openBrowser: !args.includes('--no-open') });
}
