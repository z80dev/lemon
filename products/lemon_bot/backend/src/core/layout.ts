import { dirname, resolve } from 'node:path';
import { realpathSync } from 'node:fs';

// The release compiler replaces this constant; source execution has no release layout.
declare const LEMON_BOT_PACKAGED: boolean;
export const packagedRuntime = typeof LEMON_BOT_PACKAGED !== 'undefined' && LEMON_BOT_PACKAGED;
export const executablePath = packagedRuntime ? realpathSync(process.execPath) : process.execPath;
export function defaultWebRoot(): string {
  return packagedRuntime
    ? resolve(dirname(executablePath), '../web')
    : resolve(import.meta.dir, '../../../web/dist');
}
