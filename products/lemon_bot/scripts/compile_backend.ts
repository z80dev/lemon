import { resolve } from 'node:path';
import type { BunPlugin } from 'bun';

const [backend, version, platform, outfile] = process.argv.slice(2);
if (!backend || !version || !platform || !outfile) throw new Error('Usage: compile_backend.ts BACKEND VERSION PLATFORM OUTFILE');
const target = platform === 'linux-x86_64' ? 'bun-linux-x64'
  : platform === 'linux-arm64' ? 'bun-linux-arm64'
  : platform === 'darwin-arm64' ? 'bun-darwin-arm64' : null;
if (!target) throw new Error('Unsupported backend platform.');
const addonPlatform = platform === 'linux-x86_64' ? 'linux-x64' : platform;
const addonPath = `../node_modules/@img/sharp-${addonPlatform}/lib/sharp-${addonPlatform}.node`;
let replacedNativeLoader = false;
const nativeImage: BunPlugin = {
  name: 'lemon-bot-external-image-addon',
  setup(build) {
    build.onLoad({ filter: /[/\\]sharp[/\\]lib[/\\]sharp\.js$/ }, () => {
      replacedNativeLoader = true;
      // Bundle all Sharp JS/transitive dependencies normally. Only the native
      // addon is external: its disk location must retain the sibling libvips
      // layout. A dynamic absolute require keeps Bun from embedding/extracting
      // the addon somewhere its shared libraries cannot be found.
      return { loader: 'js', contents: `
        const { dirname, resolve } = require('node:path');
        const { realpathSync } = require('node:fs');
        try {
          const addon = require(resolve(dirname(realpathSync(process.execPath)), ${JSON.stringify(addonPath)}));
          ${addonPlatform === 'linux-x64' ? "if (!addon._isUsingX64V2()) throw new Error('Unsupported CPU');" : ''}
          module.exports = addon;
        } catch (error) {
          const message = error instanceof Error ? error.message : '';
          const classification = /Library not loaded|cannot open shared object|Incompatible library version/i.test(message)
            ? 'native-shared-library-unavailable'
            : /symbol not found|undefined symbol|CXXABI_/i.test(message) ? 'native-symbol-unavailable'
            : /Unsupported CPU/i.test(message) ? 'native-cpu-unsupported'
            : /Cannot find|Cannot resolve|MODULE_NOT_FOUND/i.test(message) ? 'runtime-dependency-unresolved'
            : 'native-addon-open-failed';
          process.stderr.write('LEMON_BOT_IMAGE_DIAGNOSTIC ' + JSON.stringify({phase:'load', classification, dependency:${JSON.stringify(`@img/sharp-${addonPlatform}`)}}) + '\\n');
          throw error;
        }
      ` };
    });
  },
};
const result = await Bun.build({
  entrypoints: [resolve(backend, 'src/cli.ts')],
  compile: { target, outfile: resolve(outfile) },
  define: { LEMON_BOT_PACKAGED: 'true', LEMON_BOT_VERSION: JSON.stringify(version) },
  plugins: [nativeImage],
});
if (!result.success) throw new AggregateError(result.logs, 'Backend compilation failed.');
if (!replacedNativeLoader) throw new Error('Sharp native loader was not included in the backend compilation.');
