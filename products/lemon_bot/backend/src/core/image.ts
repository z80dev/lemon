import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import type sharpModule from 'sharp';
import type { Sharp, SharpOptions } from 'sharp';
import { executablePath, packagedRuntime } from './layout';

// Bun's compiled module resolver does not search sibling node_modules for a
// bare external package name. Load the real on-disk entrypoint explicitly;
// sharp's own native-addon imports then resolve from its installed directory.
const requireImage = createRequire(packagedRuntime ? executablePath : import.meta.url);
let imageModule: typeof sharpModule | undefined;
export default function sharp(bytes: Uint8Array, options: SharpOptions): Sharp {
  const loaded: typeof sharpModule = imageModule ??= requireImage(packagedRuntime
    ? resolve(dirname(executablePath), '../node_modules/sharp/lib/index.js')
    : 'sharp');
  // Native image libraries are needed only for actual image decoding, never
  // for version/help or a backend with no image request.
  return loaded(bytes, options);
}
