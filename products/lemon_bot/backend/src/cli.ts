import { productVersion as version } from './core/version';

const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--version') {
  process.stdout.write(`lemon-bot ${version}\n`);
} else if (args.length === 1 && (args[0] === '--help' || args[0] === '-h')) {
  process.stdout.write(`Lemon Bot ${version}\nUsage: lemon-bot [--version | --help]\n       lemon-bot setup [--print-origin] [--same-machine]\n\nWith no arguments, starts the authenticated product backend and serves its packaged web app.\nRequired private environment: LEMON_BOT_CONTROL_URL, LEMON_BOT_OPERATOR_TOKEN,\nLEMON_BOT_PUBLIC_URL, LEMON_BOT_DATA_DIR. Optional LEMON_BOT_HOST/PORT bind the listener.\nKeep product data outside the installation directory.\n\nsetup verifies the running backend against the existing DATA_DIR identity at the\nexact configured HTTPS *.ts.net origin. It never starts services or checks\nproviders. For an unconfigured workspace it prints the verified origin to stdout\nand a sensitive five-minute single-use owner proof to /dev/tty only.\nA controlling terminal is required; existing accounts and pairing are unchanged.\n--print-origin is read-only, needs no terminal, issues no proof and prints only\nthe verified origin, including for an already configured workspace.\n--same-machine permits literal 127.0.0.1 or [::1] for local development/release\nsmoke only; it does not establish physical-phone readiness.\nNever share the controller operator token with clients.\n`);
} else if (args[0] === 'setup') {
  // Private-state and platform imports must remain lazy for help/version.
  const { runSetupCli } = await import('./setup-cli');
  process.exitCode = await runSetupCli(args.slice(1));
} else if (args.length !== 0) {
  process.stderr.write('Unsupported argument. Use lemon-bot --help.\n');
  process.exitCode = 2;
} else {
  // Startup intentionally loads after argument dispatch: a static import would
  // load platform-specific native libraries even for version/help.
  const { runBackend } = await import('./index');
  await runBackend();
}
