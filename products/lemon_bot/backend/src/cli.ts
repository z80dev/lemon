import { productVersion as version } from './core/version';
import { runBackend } from './index';

const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--version') {
  process.stdout.write(`lemon-bot ${version}\n`);
} else if (args.length === 1 && (args[0] === '--help' || args[0] === '-h')) {
  process.stdout.write(`Lemon Bot ${version}\nUsage: lemon-bot [--version | --help]\n\nWith no arguments, starts the authenticated product backend and serves its packaged web app.\nRequired private environment: LEMON_BOT_CONTROL_URL, LEMON_BOT_OPERATOR_TOKEN,\nLEMON_BOT_PUBLIC_URL, LEMON_BOT_DATA_DIR. Optional LEMON_BOT_HOST/PORT bind the listener.\nKeep product data outside the installation directory. First startup prints a one-use\nlocal operator setup code; never share the controller operator token with clients.\n`);
} else if (args.length !== 0) {
  process.stderr.write('Unsupported argument. Use lemon-bot --help.\n');
  process.exitCode = 2;
} else {
  await runBackend();
}
