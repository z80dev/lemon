import { options } from '../src/cli/options.ts';
import { message } from '../src/domain/message.ts';
import { dispatch } from '../src/services/dispatch.ts';
try {
  const parsed = options(process.argv.slice(2));
  console.log(JSON.stringify(dispatch(parsed.config, [message('cli-1', parsed.recipient, parsed.text)])));
} catch (error) { console.error((error as Error).message); process.exitCode = 1; }
